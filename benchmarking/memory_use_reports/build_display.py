#!/usr/bin/env python3
"""Build the memory-use display (one self-contained HTML file) from data/.

  build_display.py [--view dev|published] [--watch] [--serve [--port N]]

dev        every parsable data file in data/
published  only the data files tracked by git (what programmer users see)
Output: display/index-dev.html or display/index-published.html.
Parsers: .tsv, .csv ('# key: value' header metadata, first other line = columns).
Other extensions are skipped with a warning; a file that fails to parse is
skipped with a warning. Data lives apart from the display and is never embedded
from outside data/.
Each loaded file also gets a section with its format, metadata, row count and
full table; skipped files are listed with the reason.
--watch  keep running; watch data/ with kqueue/inotify (2 s poll fallback) (names, mtimes, sizes, git-tracked
         set) and rebuild both views on any change. Ctrl-C stops.
--serve  watch (as --watch) and serve display/ on 127.0.0.1:PORT (default 19912); GET /events is a
         Server-Sent Events stream that pushes 'rebuilt <view> <time>' after each rebuild, and
         the page (checkbox 'auto-update', default on) reloads when it arrives. No timer.
"""
import argparse, csv, datetime, json, mimetypes, os, queue, signal, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "display")


_warned = set()


def warn(msg):
    # once per distinct message, so --watch does not repeat itself every rebuild
    if msg in _warned:
        return
    _warned.add(msg)
    print("build_display: warning: " + msg, file=sys.stderr)


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def parse(path, delim):
    meta, header, rows = {}, None, []
    with open(path, newline="", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\r\n")
            if not line.strip():
                continue
            if line.startswith("#"):
                k, sep, v = line[1:].partition(":")
                if sep:
                    meta[k.strip()] = v.strip()
                continue
            fields = next(csv.reader([line], delimiter=delim))
            if header is None:
                header = [h.strip() for h in fields]
            else:
                rows.append(fields)
    if not header:
        raise ValueError("no column header")
    return meta, header, rows


def summarize(name, meta, header, rows):
    def col(n):
        return header.index(n) if n in header else None
    iu, ip, isec, iex = col("unit"), col("peak_footprint_MB"), col("seconds"), col("exit")
    il, ib = col("lines"), col("bytes")
    if ip is None:
        raise ValueError("no peak_footprint_MB column")
    units = []
    for r in rows:
        if len(r) <= ip:
            continue
        p = num(r[ip])
        if p is None:
            continue
        units.append({"unit": r[iu] if iu is not None and iu < len(r) else "?",
                      "peak": p,
                      "lines": num(r[il]) if il is not None and il < len(r) else None,
                      "bytes": num(r[ib]) if ib is not None and ib < len(r) else None,
                      "seconds": num(r[isec]) if isec is not None and isec < len(r) else None,
                      "exit": r[iex] if iex is not None and iex < len(r) else None})
    if not units:
        raise ValueError("no numeric peak rows")
    big = max(units, key=lambda u: u["peak"])
    peak = num(meta.get("peak_MB")) if "peak_MB" in meta else None
    base = os.path.splitext(name)[0]
    ts, _, comp = base.partition("_")
    return {"file": name, "label": ts + " " + comp, "timestamp": ts, "compiler": comp,
            "meta": meta, "peak_MB": peak if peak is not None else big["peak"],
            "total_seconds": sum(u["seconds"] for u in units if u["seconds"] is not None),
            "largest_unit": big["unit"], "largest_peak": big["peak"],
            "over_1024": sum(1 for u in units if u["peak"] > 1024),
            "over_2048": sum(1 for u in units if u["peak"] > 2048),
            "unit_count": len(units),
            "units": {u["unit"]: u["peak"] for u in units},
            "unit_rows": units,
            "format": os.path.splitext(name)[1].lower().lstrip("."),
            "header": header, "rows": rows, "row_count": len(rows)}


def tracked(files):
    """Subset of data files (basenames) tracked by git."""
    try:
        root = subprocess.check_output(["git", "-C", HERE, "rev-parse", "--show-toplevel"],
                                       text=True, stderr=subprocess.DEVNULL).strip()
        out = subprocess.check_output(["git", "-C", root, "ls-files", "-z", "--",
                                       os.path.relpath(DATA, root)],
                                      text=True, stderr=subprocess.DEVNULL)
    except Exception as e:
        warn("git unavailable (%s); published view will be empty" % e)
        return set()
    return {os.path.basename(p) for p in out.split("\0") if p}


PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Silica compiler memory use (__VIEW__)</title><style>
:root{--bg:#fff;--fg:#1d2330;--mut:#5b6475;--bar:#2a6fdb;--grid:#d9dde5}
@media (prefers-color-scheme:dark){:root{--bg:#14171d;--fg:#e6e9ef;--mut:#9aa3b2;--bar:#6aa3ff;--grid:#323845}}
body{background:var(--bg);color:var(--fg);font:14px/1.4 system-ui,sans-serif;margin:0 auto;max-width:960px;padding:16px}
h1{font-size:20px;margin:0 0 4px}.mut{color:var(--mut)}label{margin-right:12px}
#type{display:flex;flex-wrap:wrap;gap:6px;margin:12px 0}
#type button{font:inherit;padding:4px 10px;border:1px solid var(--grid);border-radius:4px;background:var(--bg);color:var(--fg);cursor:pointer}
#type button.sel{background:var(--bar);color:var(--bg);border-color:var(--bar);font-weight:600}
svg text{fill:var(--mut);font-size:11px}
#cw{display:flex;align-items:flex-start}#cw svg{flex:none}
#cs{overflow-x:auto;flex:1 1 auto;min-width:0}
.leg{display:flex;flex-wrap:wrap;gap:2px 14px;margin:6px 0;font-size:12px}
.leg i{display:inline-block;width:12px;height:12px;margin-right:4px;vertical-align:-2px;border-radius:50%}
#pop{position:fixed;z-index:10;display:none;pointer-events:none;max-width:90vw;background:var(--bg);color:var(--fg);border:1px solid var(--bar);border-radius:4px;padding:6px 8px;font-size:11px;line-height:1.4;box-shadow:0 2px 8px rgba(0,0,0,.3);word-break:break-all}
#pop b{color:var(--mut);font-weight:600}
</style></head><body>
<h1>Silica compiler memory use</h1>
<div class="mut">View: __VIEW__ &middot; <span id="cnt"></span> &middot; last built __BUILT__
&middot; <label><input type="checkbox" id="auto" checked> auto-update</label></div>
<div id="type" role="group" aria-label="Metric"></div>
<div id="leg" class="leg"></div><div id="chart"></div><div id="note" class="mut"></div>
<div id="skipped" class="mut"></div>
<script type="application/json" id="data">__DATA__</script>
<script>
var D=JSON.parse(document.getElementById('data').textContent),R=D.runs||[];
var P=['#2a6fdb','#d9480f','#2f9e44','#9c36b5','#e8a200','#0ca5a5','#c2255c','#6c757d'];
var MT=[["peak","RAM used to compile each unit (MB)"],["seconds","Compile time for each unit (seconds)"]];
var metric='peak';
function g(i){return document.getElementById(i)}
function esc(s){return String(s).replace(/[&<>"]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
function ucmp(a,b){var x=a.lastIndexOf('/'),y=b.lastIndexOf('/'),fa=x<0?'':a.slice(0,x),fb=y<0?'':b.slice(0,y);if(fa!==fb)return fa<fb?-1:1;var na=a.slice(x+1),nb=b.slice(y+1);return na<nb?-1:na>nb?1:0}
function nf(v,d){return (+v).toFixed(d)}
g('cnt').textContent=R.length+' run(s)';
R.forEach(function(r){r.umap={};r.unit_rows.forEach(function(u){r.umap[u.unit]=u})});
try{var m0=window.localStorage.getItem('ram-report-metric');if(m0==='peak'||m0==='seconds')metric=m0}catch(e){}
function msave(){try{window.localStorage.setItem('ram-report-metric',metric)}catch(e){}}
var tb=g('type');
MT.forEach(function(t){var b=document.createElement('button');b.type='button';b.setAttribute('data-k',t[0]);b.textContent=t[1];
 b.onclick=function(){metric=t[0];msave();sync();draw()};tb.appendChild(b)});
function sync(){Array.prototype.forEach.call(tb.children,function(b){b.className=b.getAttribute('data-k')===metric?'sel':''})}
function draw(){
 var el=g('chart'),title='';MT.forEach(function(t){if(t[0]===metric)title=t[1]});
 var lg='';R.forEach(function(r,i){lg+='<span><i style="background:'+P[i%P.length]+'"></i>'+esc(r.label)+'</span>'});
 g('leg').innerHTML=lg;
 if(!R.length){el.innerHTML='<p class="mut">No data files.</p>';g('note').textContent='';return}
 var seen={},names=[];R.forEach(function(r){r.unit_rows.forEach(function(u){if(!seen[u.unit]){seen[u.unit]=1;names.push(u.unit)}})});
 names.sort(ucmp);
 var mx=1,H=360,T0=12,B=12,CW=5,AW=56,PH=H-T0-B,W=names.length*CW,a='',p='';
 var mv=0;R.forEach(function(r){r.unit_rows.forEach(function(u){var v=u[metric];if(v!=null&&v>mv)mv=v})});
 mx=1;var NS=[1,2,5,10,20,50,100,200,500,1000,2000,5000,10000,20000,50000,100000];for(var k=0;k<NS.length;k++){mx=NS[k];if(mx>=mv)break}if(mx<mv)mx=Math.ceil(mv/100000)*100000;
 for(var i=0;i<=5;i++){var y=T0+PH-PH*i/5;
  a+='<text x="'+(AW-6)+'" y="'+(y+4)+'" text-anchor="end">'+(i===0?'0':+(mx*i/5).toFixed(1))+'</text>';
  p+='<line x1="0" x2="'+W+'" y1="'+y+'" y2="'+y+'" stroke="var(--grid)"/>'}
 p+='<line x1="0" x2="'+W+'" y1="'+(T0+PH)+'" y2="'+(T0+PH)+'" stroke="var(--fg)" stroke-width="1.5"/>';
 a+='<text transform="translate(12,'+(T0+PH/2)+') rotate(-90)" text-anchor="middle">'+esc(title)+'</text>';
 names.forEach(function(n,i){R.forEach(function(r,ri){var u=r.umap[n];if(!u||u[metric]==null)return;
  p+='<circle cx="'+(CW/2+i*CW)+'" cy="'+(T0+PH-PH*u[metric]/mx)+'" r="2.5" fill="'+P[ri%P.length]+'" fill-opacity="0.85" data-ri="'+ri+'" data-u="'+esc(n)+'"/>'})});
 el.innerHTML='<div id="cw"><svg width="'+AW+'" height="'+H+'" role="img" aria-label="axis">'+a+'</svg><div id="cs"><svg width="'+W+'" height="'+H+'" role="img" aria-label="'+esc(title)+' per compilation unit, one dot per run">'+p+'</svg></div></div>';
 g('note').textContent=names.length+' unit(s), one column per unit in folder-then-name order; scroll sideways; hover a dot for details.'}
sync();draw();
(function(){
 var sk=D.skipped||[];
 if(sk.length)g('skipped').innerHTML='<p>Skipped: '+sk.map(function(k){return esc(k.file)+' ('+esc(k.reason)+')'}).join('; ')+'</p>';
 var cb=g('auto');
 try{if(sessionStorage.getItem('autorefresh')==='off')cb.checked=false}catch(e){}
 var es=null;
 function on(){
  if(es||!cb.checked||location.protocol!=='http:'||typeof EventSource==='undefined')return;
  es=new EventSource('/events');
  es.onmessage=function(){location.reload()};
 }
 function off(){if(es){es.close();es=null}}
 cb.onchange=function(){try{sessionStorage.setItem('autorefresh',cb.checked?'on':'off')}catch(e){}
  if(cb.checked)on();else off()};
 on();
})();
(function(){
var PS={d:11,min:8,max:32,step:2,v:11},pop=g('pop'),hov=null;
function psave(){try{window.localStorage.setItem('ram-report-popup',String(PS.v))}catch(e){}}
function pload(){try{var v=parseInt(window.localStorage.getItem('ram-report-popup'),10);if(isFinite(v)&&v>=PS.min&&v<=PS.max)PS.v=v}catch(e){}}
function ph(c){var r=R[+c.getAttribute('data-ri')],u=r&&r.umap[c.getAttribute('data-u')];if(!u)return '';
 function row(a,b){return '<div><b>'+a+'</b> '+esc(b)+'</div>'}
 return row('data file','data/'+r.file)+row('unit',u.unit)+row('run',r.label)+row('RAM used (MB)',u.peak)+(u.seconds!=null?row('compile seconds',nf(u.seconds,1)):'')+row('total seconds',nf(r.total_seconds,1))+row('exit',u.exit==null?'n/a':u.exit)
  +(u.lines!=null?row('source lines',u.lines):'')+(u.bytes!=null?row('source bytes',u.bytes):'')}
function pmove(e){var w=pop.offsetWidth,h=pop.offsetHeight,x=e.clientX+14,y=e.clientY+14;
 if(x+w>window.innerWidth-4)x=Math.max(4,e.clientX-w-14);if(y+h>window.innerHeight-4)y=Math.max(4,e.clientY-h-14);
 pop.style.left=x+'px';pop.style.top=y+'px'}
function pshow(c,e){hov=c;pop.innerHTML=ph(c);pop.style.fontSize=PS.v+'px';pop.style.display='block';pmove(e)}
function phide(){hov=null;pop.style.display='none'}
var dc=g('chart');
dc.addEventListener('mousemove',function(e){var c=e.target.closest?e.target.closest('circle[data-ri]'):null;if(!c)return phide();if(c!==hov)pshow(c,e);else pmove(e)});
dc.addEventListener('mouseleave',phide);
document.addEventListener('keydown',function(e){
 if(!e.shiftKey||e.ctrlKey||e.metaKey||e.altKey)return;
 var t=e.target,tn=t&&t.tagName;if(tn==='INPUT'||tn==='TEXTAREA'||tn==='SELECT'||(t&&t.isContentEditable))return;
 var d=0,k=e.key,c=e.code;
 if(k==='+'||k==='='||c==='Equal'||c==='NumpadAdd')d=PS.step;
 else if(k==='-'||k==='_'||c==='Minus'||c==='NumpadSubtract')d=-PS.step;
 else if(k===')'||k==='0'||c==='Digit0'){PS.v=PS.d}
 else return;
 if(d)PS.v=Math.min(PS.max,Math.max(PS.min,PS.v+d));
 e.preventDefault();psave();pop.style.fontSize=PS.v+'px'});
pload();
})();
</script>
<div id="pop" role="tooltip"></div>
</body></html>
"""


def build(view):
    names = sorted(os.listdir(DATA)) if os.path.isdir(DATA) else []
    names = [n for n in names if os.path.isfile(os.path.join(DATA, n)) and not n.startswith(".")]
    if view == "published":
        ok = tracked(names)
        names = [n for n in names if n in ok]
    runs, skipped = [], []

    def skip(n, reason):
        warn("%s: %s; skipped" % (n, reason))
        skipped.append({"file": n, "reason": reason})

    for n in names:
        path = os.path.realpath(os.path.join(DATA, n))
        if os.path.dirname(path) != os.path.realpath(DATA):
            skip(n, "resolves outside data/")
            continue
        ext = os.path.splitext(n)[1].lower()
        if ext not in (".tsv", ".csv"):
            skip(n, "unsupported extension %r" % ext)
            continue
        try:
            meta, header, rows = parse(path, "\t" if ext == ".tsv" else ",")
            runs.append(summarize(n, meta, header, rows))
        except Exception as e:
            skip(n, "cannot parse (%s)" % e)
    runs.sort(key=lambda r: r["file"])
    os.makedirs(OUT, exist_ok=True)
    built = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    data = json.dumps({"view": view, "runs": runs, "skipped": skipped, "built": built}).replace("</", "<\\/")
    html = PAGE.replace("__VIEW__", view).replace("__BUILT__", built).replace("__DATA__", data)
    out = os.path.join(OUT, "index-%s.html" % view)
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(html)
    os.replace(tmp, out)  # atomic: an open page never reloads a half-written file
    print("%s: %d run(s) -> %s" % (view, len(runs), out), flush=True)


def snapshot():
    """(file -> (mtime_ns, size), git-tracked names) for change detection."""
    snap = {}
    if os.path.isdir(DATA):
        for n in os.listdir(DATA):
            if n.startswith("."):
                continue
            try:
                st = os.stat(os.path.join(DATA, n))
                snap[n] = (st.st_mtime_ns, st.st_size)
            except OSError:
                pass
    return snap, frozenset(tracked(list(snap)))


class _Stop(Exception):
    pass


def _make_kqueue_waiter():
    """Block on kqueue vnode events for DATA and each data file."""
    import select
    kq = select.kqueue()
    dfd = os.open(DATA, os.O_RDONLY)
    fflags = (select.KQ_NOTE_WRITE | select.KQ_NOTE_RENAME | select.KQ_NOTE_DELETE
              | select.KQ_NOTE_EXTEND | select.KQ_NOTE_ATTRIB)
    kq.control([select.kevent(dfd, select.KQ_FILTER_VNODE,
                              select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags)], 0, 0)
    files = {}  # name -> fd

    def watch_files(names):
        for n in list(files):
            if n not in names:
                try:
                    os.close(files.pop(n))  # closing removes its kevent
                except OSError:
                    pass
        for n in names:
            if n in files:
                continue
            try:
                fd = os.open(os.path.join(DATA, n), os.O_RDONLY)
            except OSError:
                continue
            ff = (select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND | select.KQ_NOTE_ATTRIB
                  | select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME)
            try:
                kq.control([select.kevent(fd, select.KQ_FILTER_VNODE,
                                          select.KQ_EV_ADD | select.KQ_EV_CLEAR, ff)], 0, 0)
                files[n] = fd
            except OSError:
                os.close(fd)

    def wait():
        kq.control(None, 64, 3600)  # long timeout only; wakes on any vnode event
        time.sleep(0.2)             # debounce: let a burst finish
        kq.control(None, 64, 0)     # drain what arrived meanwhile (one rescan per wakeup)

    return watch_files, wait


def _make_inotify_waiter():
    import ctypes, ctypes.util
    libc = ctypes.CDLL(ctypes.util.find_library("c") or None, use_errno=True)
    init1 = libc.inotify_init1
    add = libc.inotify_add_watch
    IN_NONBLOCK, IN_CLOEXEC = 0o4000, 0o2000000
    mask = 0x100 | 0x2 | 0x8 | 0x80 | 0x200 | 0x40  # CREATE MODIFY CLOSE_WRITE MOVED_TO DELETE MOVED_FROM
    fd = init1(IN_CLOEXEC)
    if fd < 0:
        raise OSError(ctypes.get_errno(), "inotify_init1")
    add.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    if add(fd, DATA.encode(), mask) < 0:
        raise OSError(ctypes.get_errno(), "inotify_add_watch")

    def watch_files(names):
        pass  # the directory watch reports in-place modifications (IN_MODIFY, IN_CLOSE_WRITE)

    def wait():
        os.read(fd, 65536)          # blocks until an event
        time.sleep(0.2)             # debounce
        import fcntl, termios, array
        buf = array.array("i", [0])
        fcntl.ioctl(fd, termios.FIONREAD, buf)
        if buf[0]:
            os.read(fd, buf[0])     # drain the burst

    return watch_files, wait


_clients = []
_clients_lock = threading.Lock()


def push(line):
    """Queue one SSE message on every connected client."""
    with _clients_lock:
        for q in _clients:
            q.put(line)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "build_display"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", head_only=False):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        if not head_only:
            self.wfile.write(body)
        self.close_connection = True

    def _other(self):
        self._send(405 if self.command in ("POST", "PUT", "DELETE", "PATCH", "OPTIONS") else 404,
                   b"not found\n")

    do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = _other

    def do_GET(self):
        try:
            path = self.path.split("?", 1)[0].split("#", 1)[0]
            if path == "/events":
                return self._events()
            from urllib.parse import unquote
            path = unquote(path)
            if path in ("", "/"):
                path = "/index-dev.html"
            root = os.path.realpath(OUT)
            full = os.path.realpath(os.path.join(root, path.lstrip("/")))
            if "\0" in full or not full.startswith(root + os.sep):
                return self._send(404, b"not found\n")
            if not os.path.isfile(full):
                return self._send(404, b"not found\n")
            ext = os.path.splitext(full)[1].lower()
            ctype = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
                     ".css": "text/css; charset=utf-8", ".json": "application/json"}.get(
                         ext, mimetypes.guess_type(full)[0] or "application/octet-stream")
            with open(full, "rb") as f:
                body = f.read()
            self._send(200, body, ctype)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            try:
                self._send(404, b"not found\n")
            except Exception:
                pass

    def _events(self):
        q = queue.Queue()
        with _clients_lock:
            _clients.append(q)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            self.wfile.write(b": connected\n\n")
            self.wfile.flush()
            while True:
                try:
                    line = q.get(timeout=15)
                except queue.Empty:
                    self.wfile.write(b": keep-alive\n\n")
                    self.wfile.flush()
                    continue
                if line is None:  # server stopping
                    break
                self.wfile.write(("data: %s\n\n" % line).encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            with _clients_lock:
                if q in _clients:
                    _clients.remove(q)
            self.close_connection = True


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def watch(port=None, view="dev", initial=False):
    stop = []
    waiting = []

    def on_signal(signum, frame):
        stop.append(signum)
        if waiting:  # interrupt the blocking wait; never interrupt a build midway
            raise _Stop()

    # SIGINT is ignored by background jobs of non-interactive shells; SIGTERM is the reliable stop.
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    watch_files = wait = None
    try:
        if hasattr(__import__("select"), "kqueue"):
            watch_files, wait = _make_kqueue_waiter()
        elif sys.platform.startswith("linux"):
            watch_files, wait = _make_inotify_waiter()
    except Exception:
        watch_files = wait = None
    polling = wait is None
    if polling:
        print("build_display: no file-event API; falling back to a 2-second check", flush=True)
        def wait():
            time.sleep(2)
        watch_files = lambda names: None

    prev = snapshot()
    watch_files(set(prev[0]))
    how = "polling every 2 s" if polling else "on file-change events"
    httpd = None
    if port is not None:
        os.makedirs(OUT, exist_ok=True)
        httpd = Server(("127.0.0.1", port), Handler)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        print("build_display: serving http://127.0.0.1:%d/index-%s.html (Ctrl-C or SIGTERM stops)"
              % (port, view), flush=True)
    else:
        print("build_display: watching %s %s (Ctrl-C or SIGTERM stops)" % (DATA, how), flush=True)
    if initial:  # after the server is up, so the port answers while the first build runs
        for v in ("dev", "published"):
            build(v)
        for v in ("dev", "published"):
            push("rebuilt %s %s" % (v, time.strftime("%H:%M:%S")))
    while not stop:
        try:
            waiting.append(1)
            try:
                if stop:
                    break
                wait()
            finally:
                waiting.clear()
        except _Stop:
            break
        if stop:
            break
        cur = snapshot()
        watch_files(set(cur[0]))
        if cur == prev:
            continue
        ch = sorted({n for n in set(prev[0]) | set(cur[0]) if prev[0].get(n) != cur[0].get(n)}
                    | (prev[1] ^ cur[1]))
        print("%s rebuild: %s" % (time.strftime("%H:%M:%S"), ", ".join(ch) or "(unknown)"), flush=True)
        for v in ("dev", "published"):
            build(v)
        for v in ("dev", "published"):
            push("rebuilt %s %s" % (v, time.strftime("%H:%M:%S")))
        prev = cur
    if httpd is not None:
        with _clients_lock:
            for q in _clients:
                q.put(None)
        httpd.shutdown()
        httpd.server_close()
    print("build_display: stopped", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--view", choices=["dev", "published"], default="dev")
    ap.add_argument("--watch", action="store_true",
                    help="watch data/ for file-change events and rebuild both views on change")
    ap.add_argument("--serve", action="store_true",
                    help="watch (as --watch) and serve display/ with a /events push stream")
    ap.add_argument("--port", type=int, default=19912, help="--serve port on 127.0.0.1 (default 19912)")
    a = ap.parse_args()
    if a.serve:
        watch(a.port, a.view, initial=True)
    elif a.watch:
        for v in ("dev", "published"):
            build(v)
        watch()
    else:
        build(a.view)


if __name__ == "__main__":
    main()
