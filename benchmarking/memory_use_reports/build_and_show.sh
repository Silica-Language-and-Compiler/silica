#!/usr/bin/env bash
# build_and_show.sh - build the memory-use page and open it unless already displayed.
#
# Usage: build_and_show.sh [--view dev|published] [--port N] [--watch]
#   --view V   dev (default) or published
#   --port N   server port on 127.0.0.1 (default 19912)
#   --watch    after opening, follow the server log until Ctrl-C (server keeps running)
# Starts build_display.py --serve in the background if nothing listens on the port; it pushes
# updates to the open page. Never stops a running server, never builds the compiler.
# macOS: checks Safari/Chrome tabs; Linux: marker file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEW=dev; WATCH=0; PORT=19912

while [ $# -gt 0 ]; do
  case "$1" in
    --watch)   WATCH=1 ;;
    --port)    shift; PORT="${1:-}"
               case "$PORT" in ''|*[!0-9]*) echo "bad --port: $PORT" >&2; exit 2 ;; esac ;;
    --view)    shift; VIEW="${1:-}"
               case "$VIEW" in dev|published) ;;
                 *) echo "bad --view: $VIEW" >&2; exit 2 ;; esac ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# Step 1: build the page.
rc=0
python3 "$HERE/build_display.py" --view "$VIEW" || rc=$?
if [ "$rc" -ne 0 ]; then echo "display: build failed, exit code $rc" >&2; exit "$rc"; fi
PAGE="$HERE/display/index-$VIEW.html"
echo "display: wrote $PAGE"


# Step 2: make sure the server is running (never stop or restart a running one).
listening() {
  python3 - "$PORT" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", int(sys.argv[1]))); sys.exit(0)
except OSError:
    sys.exit(1)
PY
}

LOG="$HERE/display/serve-$PORT.log"; PIDF="$HERE/display/serve-$PORT.pid"
if listening; then
  echo "server: already listening on 127.0.0.1:$PORT (left running)"
else
  nohup python3 "$HERE/build_display.py" --serve --view "$VIEW" --port "$PORT" >"$LOG" 2>&1 &
  echo $! >"$PIDF"
  up=0
  for _ in $(seq 1 120); do
    if listening; then up=1; break; fi
    sleep 0.5
  done
  if [ "$up" -ne 1 ]; then echo "server: still not answering on 127.0.0.1:$PORT after 60 s; see $LOG (pid file $PIDF)" >&2; exit 1; fi
  echo "server: started on 127.0.0.1:$PORT (log $LOG)"
fi
echo "server: to stop it run: kill \$(cat display/serve-$PORT.pid)"

# Step 3: open the page only if not already displayed.
URL="http://127.0.0.1:$PORT/index-$VIEW.html"
default_browser() {  # prints the https handler's bundle id, or nothing
  python3 - <<'PY' 2>/dev/null || true
import plistlib, os
p = os.path.expanduser("~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist")
for h in plistlib.load(open(p, "rb")).get("LSHandlers", []):
    if h.get("LSHandlerURLScheme") == "https":
        print(h.get("LSHandlerRoleAll", "")); break
PY
}

tab_open() {  # $1 = browser app name; true if a tab URL contains 127.0.0.1:$PORT/index-$VIEW.html
  local app="$1" script out
  if [ "$app" = Safari ]; then
    script='tell application "Safari" to get URL of every tab of every window'
  else
    script='tell application "Google Chrome" to get URL of every tab of every window'
  fi
  # do not launch a browser just to ask it
  pgrep -x "$app" >/dev/null 2>&1 || return 1
  out="$(osascript -e "$script" 2>/dev/null)" || return 1
  case "$out" in *"127.0.0.1:$PORT/index-$VIEW.html"*) return 0 ;; *) return 1 ;; esac
}

if [ "$(uname -s)" = Darwin ]; then
  bid="$(default_browser)"
  case "$bid" in
    com.apple.safari|com.apple.Safari) name=Safari; app=Safari ;;
    com.google.chrome|com.google.Chrome) name="Google Chrome"; app="Google Chrome" ;;
    *) name=""; app="" ;;
  esac
  if [ -n "$app" ] && tab_open "$app"; then
    echo "opened: already displayed in $name"
  else
    open "$URL"
    if [ -n "$app" ]; then echo "opened: $URL in $name (not found in open tabs)"
    else echo "opened: $URL (default browser '${bid:-unknown}': open tabs cannot be checked)"; fi
  fi
else
  MARK="$HERE/display/.opened-$VIEW-$PORT"
  if [ -e "$MARK" ]; then
    echo "opened: marker says already open (delete display/.opened-$VIEW-$PORT to reopen)"
  else
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$URL" >/dev/null 2>&1 || true
      echo "opened: $URL"
    else
      echo "opened: no xdg-open; open this yourself: $URL"
    fi
    touch "$MARK"
  fi
fi

if [ "$WATCH" -eq 1 ]; then
  echo "watch: following $LOG (Ctrl-C stops following; the server keeps running)"
  exec tail -f "$LOG"
fi
