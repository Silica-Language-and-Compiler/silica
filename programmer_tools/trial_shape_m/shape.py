"""Item M: put a trial program in the supervisor-actor shape (design of 2026-10-08).

`main` keeps its name and header. Its old body travels, verbatim and indented by 8 spaces, as a
function literal in the message main casts to a shared worker (trials/lib_trial_support/, written by
gen_support.py). main itself only starts the supervisor, casts and waits:

    fn main() -> int64 {                 fn main() -> int64 {
        2 + 3 * 4                ==>         sequence proc[concurrency, device_io]
    }                                            _: supervisor_ref <- trial_support_int64@start();
                                                 _: boolean <- trial_support_int64@run(fn() -> int64 {
                                                     2 + 3 * 4
                                                 });
                                                 code: int64 <- wait_for_exit()
                                             produces
                                                 pure code
                                             end
                                         }

Forms (choose_form):
  A  int64 result: trial_support_int64; the worker's cast_exit carries the value; main returns `code`.
  B  any other type whose result is a literal (`pure :ok`, `0`, `true`): trial_support_<T>; the worker
     ends the wait with cast_exit(0); main ends with the original literal.
  C  any other type whose result is computed: as B, and main ends with the value the trial's run
     produces today, written as a literal (probe.py finds it; an error trial takes a placeholder).
     A non-int64 value cannot travel through cast_exit and Silica has no conversions, so the
     returned value is no longer checked (Lee, 2026-10-08); the .scout is unchanged.
  W  main already ended in `_: int64 <- wait_for_exit()`: that statement leaves the work;
     trial_wait_<T> runs the work; main waits for the `exit` line (the trial's .wait_for_exit
     marker) and ends with its original literal result.

Only insertions are made (plus the removed wait_for_exit statement in W), so every original
position moves by a computable amount (map_position); error-trial goldens are checked with it.
"""

import re

import silica_scan as ss

INT_TYPES = ('int8', 'int16', 'int32', 'int64', 'uint8', 'uint16', 'uint32', 'uint64')
FLOAT_TYPES = ('float16', 'float32', 'float64')
SUPPORTED = INT_TYPES + FLOAT_TYPES + ('atom', 'boolean', 'string')
LITERAL_RE = re.compile(r'(:[A-Za-z_][A-Za-z0-9_]*|-?\d+(\.\d+)?|true|false)')
WFE_STMT_RE = re.compile(r';(\s*)_\s*:\s*int64\s*<-\s*wait_for_exit\s*\(\s*\)(\s*)(?=produces\b)')
IND = ' ' * 8


class ShapeError(Exception):
    pass


class Edit:
    """Replace text[pos:pos+dele] with ins (positions in the ORIGINAL text)."""

    def __init__(self, pos, dele, ins):
        self.pos, self.dele, self.ins = pos, dele, ins


def apply_edits(text, edits):
    out, last = [], 0
    for e in sorted(edits, key=lambda e: (e.pos, e.dele)):
        out.append(text[last:e.pos])
        out.append(e.ins)
        last = e.pos + e.dele
    out.append(text[last:])
    return ''.join(out)


def map_char_pos(edits, p):
    """New index of original index p. An insertion exactly at p lands before p."""
    d = 0
    for e in edits:
        if e.pos < p or (e.pos == p and e.dele == 0):
            if e.pos + e.dele <= p:
                d += len(e.ins) - e.dele
            else:
                return None
    return p + d


def binding_type(ret_type):
    """main's declared return type without a misplaced function-level `proc[...]` (E3009 trials)."""
    if ret_type is None:
        return None
    t = re.sub(r'\s+proc\s*\[.*$', '', ret_type.strip(), flags=re.S).strip()
    return t or None


def locate_main(text, m):
    """(name_index, Fn or None) for main's declaration; a missing `fn` (E1045) is tolerated by
    parsing as if it were there."""
    for f in ss.top_level_fns(text, m):
        if f.name == 'main':
            return m.index('main', f.start + 2), f
    mo = re.search(r'(?m)^[ \t]*(main)[ \t]*\(', m)
    if mo:
        p = mo.start(1)
        t2 = text[:p] + 'fn ' + text[p:]
        for f in ss.top_level_fns(t2):
            if f.name == 'main' and f.start == p:
                return p, ss.Fn('main', p, f.params_open - 3, f.params_close - 3, f.body_open - 3,
                                f.body_close - 3, f.ret_type)
        return p, None
    mo = re.search(r'(?m)^[ \t]*fn[ \t]+(main)[ \t]*\(', m)
    if mo:
        # something earlier is unbalanced (e.g. an unclosed parameter list, E1065): parse main alone
        ls = m.rfind('\n', 0, mo.start()) + 1
        for f in ss.top_level_fns(text[ls:]):
            if f.name == 'main' and f.start == mo.start() - ls:
                return mo.start(1), ss.Fn('main', f.start + ls, f.params_open + ls, f.params_close + ls,
                                          f.body_open + ls, f.body_close + ls, f.ret_type)
        # `fn main() -> {` (E1042: the arrow without a type): the brace opens the body
        mm = re.compile(r'\(\s*\)\s*->\s*\{').match(m, mo.end() - 1)
        if mm:
            bo = mm.end() - 1
            bc = ss.match_close(m, bo)
            if bc >= 0:
                return mo.start(1), ss.Fn('main', mo.start(1) - 3, mo.end() - 1, mo.end(), bo, bc, None)
        return mo.start(1), None
    return None, None


def result_expr(text, m, f):
    """Source of main's result: the `pure X` of a single outer sequence, or the whole body."""
    seq = ss.outer_sequence(text, f, m)
    if seq:
        return re.sub(r'^\s*produces\s*pure\s*', '', text[seq[1]:seq[2]]).strip()
    if ';' in m[f.body_open + 1:f.body_close]:
        return None
    return text[f.body_open + 1:f.body_close].strip()


def choose_form(text, wait_shape=False):
    """(form, T, literal) for main; raises ShapeError when no form fits."""
    m = ss.mask(text)
    _, f = locate_main(text, m)
    if f is None:
        raise ShapeError('main declaration not parsable')
    t = binding_type(f.ret_type) or 'int64'  # E1042 (no return type): the header error comes first
    if t not in SUPPORTED:
        raise ShapeError('main returns %s' % t)
    res = result_expr(text, m, f)
    lit = res if res is not None and LITERAL_RE.fullmatch(res) else None
    if wait_shape:
        if lit is None:
            raise ShapeError('waiting main ends with a computed result')
        return 'W', t, lit
    if t == 'int64':
        return 'A', t, None
    if lit is not None:
        return 'B', t, lit
    return 'C', t, None


def module_for(form, t):
    return {'A': 'trial_support_int64', 'B': 'trial_support_' + t,
            'C': 'trial_support_' + t, 'W': 'trial_wait_' + t}[form]


def use_insertion(text, m, mod):
    dm = ss.depth_map(m)
    uses = [u for u in ss.USE_RE.finditer(m) if dm[u.start()] == 0]
    if uses:
        nl = text.find('\n', uses[-1].end())
        return (len(text) if nl < 0 else nl + 1), 'use %s;\n' % mod
    pos = 0
    for line in m.splitlines(True):
        if line.strip():
            break
        pos += len(line)
    return pos, 'use %s;\n\n' % mod


def reshape(text, form, t, lit=None):
    """Return (new_text, edits)."""
    m = ss.mask(text)
    if re.search(r'(?m)^\s*use\s+trial_(support|call|wait)_', m):
        raise ShapeError('already in the shape')
    _, f = locate_main(text, m)
    if f is None:
        raise ShapeError('main declaration not parsable')
    mod = module_for(form, t)
    upos, uins = use_insertion(text, m, mod)
    if upos > f.start:
        raise ShapeError('`use` would follow main')
    edits = [Edit(upos, 0, uins)]
    bo, bc = f.body_open + 1, f.body_close
    body = text[bo:bc]
    one_line = '\n' not in body
    if form == 'C' and lit is None:
        raise ShapeError('form C needs the literal the trial returns today')
    si, bi = IND, IND + '    '   # statement indent in main, literal body indent
    head = '\n    sequence proc[concurrency, device_io]\n%s_: supervisor_ref <- %s@start();\n' % (si, mod)
    head += '%s_: boolean <- %s@run(fn() -> %s {' % (si, mod, t)
    if one_line:
        head += '\n' + bi[:-1]
    edits.append(Edit(bo, 0, head))
    # indent each body line by 8, except a line that starts inside a multi-line string literal
    strs = ss.string_spans(text)
    k = text.find('\n', bo)
    while 0 <= k < bc:
        p = k + 1
        nxt = text.find('\n', p)
        line = text[p:nxt if 0 <= nxt < bc else bc]
        if line.strip() and not any(a <= p < b for a, b in strs):
            edits.append(Edit(p, 0, bi[4:]))
        k = nxt
    if form == 'W':
        body_m = m[f.body_open:f.end]
        mo = WFE_STMT_RE.search(body_m)
        if not mo:
            raise ShapeError('main does not end in `_: int64 <- wait_for_exit()`')
        a = f.body_open + mo.start()
        b = f.body_open + mo.end(2)
        # the removed range ends with the indent of the `produces` line, so the replacement carries
        # that line's extra indent
        edits.append(Edit(a, b - a, mo.group(2) + bi[4:] if '\n' in mo.group(2) else ' '))
        if not re.search(r'\b(print\w*|println|read\w*)\s*\(', body_m[:mo.start()]):
            pm = re.search(r'proc\[([^\]]*)\]', body_m)
            if pm and 'device_io' in pm.group(1):
                effs = [x.strip() for x in pm.group(1).split(',') if x.strip() != 'device_io']
                if effs:
                    edits.append(Edit(f.body_open + pm.start(), pm.end() - pm.start(),
                                      'proc[%s]' % ', '.join(effs)))
    # the tail goes at the start of the closing `}` line (or after a one-line body)
    stripped = body.rstrip(' \t')
    if not one_line and stripped.endswith('\n'):
        tpos, tail = bo + len(stripped), ''
    else:
        tpos, tail = bc, '\n'
    tail += si + '});\n'
    if form == 'A':
        tail += IND + 'code: int64 <- wait_for_exit()\n    produces\n' + IND + 'pure code\n    end\n'
    else:
        tail += IND + '_: int64 <- wait_for_exit()\n    produces\n' + IND + 'pure %s\n    end\n' % lit
    edits.append(Edit(tpos, 0, tail))
    # an insertion inside a deleted range (the indent of the removed wait_for_exit line) is dropped
    dels = [(e.pos, e.pos + e.dele) for e in edits if e.dele]
    edits = [e for e in edits if e.dele or not any(a < e.pos < b for a, b in dels)]
    edits.sort(key=lambda e: (e.pos, e.dele))
    return apply_edits(text, edits), edits


def map_position(old_text, new_text, edits, line, col, offset):
    """Map an error position (1-based line/col, UTF-8 byte offset) from old_text to new_text."""
    ob = old_text.encode('utf-8')
    if offset > len(ob):
        return None
    p = len(ob[:offset].decode('utf-8', errors='ignore'))
    np_ = map_char_pos(edits, p)
    if np_ is None:
        return None
    nb = len(new_text[:np_].encode('utf-8'))
    new_line = new_text.count('\n', 0, np_) + 1
    old_ls = old_text.rfind('\n', 0, p) + 1
    new_ls = new_text.rfind('\n', 0, np_) + 1
    return new_line, col + ((np_ - new_ls) - (p - old_ls)), nb


# ---- renames applied with the shape (Lee 2026-10-09) ----
RENAMES = (('print_bool', 'print_boolean'),)


def rename_builtins(text):
    """(new_text, edits): every `print_bool` call name becomes `print_boolean` (word match, outside
    string literals; comments are renamed too). Insert-only edits, so positions stay mappable."""
    strs = ss.string_spans(text)
    edits = []
    for old, new in RENAMES:
        assert new.startswith(old)
        for mo in re.finditer(r'\b%s\b' % re.escape(old), text):
            if any(a <= mo.start() < b for a, b in strs):
                continue
            edits.append(Edit(mo.end(), 0, new[len(old):]))
    edits.sort(key=lambda e: (e.pos, e.dele))
    return apply_edits(text, edits), edits


def map_through(stages, line, col, offset):
    """Map a position through successive (old_text, new_text, edits) stages."""
    for old, new, edits in stages:
        r = map_position(old, new, edits, line, col, offset)
        if r is None:
            return None
        line, col, offset = r
    return line, col, offset
