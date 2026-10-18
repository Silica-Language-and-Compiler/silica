#!/usr/bin/env python3
"""Register a FailureReporter first in every trial whose main starts actors (spec §15.4.13.4, E2236).

    e2236_convert.py scan  [TRIALS_DIR] [--tsv OUT]   list the trials whose main can start an actor
                                                      or supervisor before any registration
    e2236_convert.py apply [TRIALS_DIR] [--only PATH_PREFIX ...] [--exclude-file F]
                                                      convert them
    --lib DIR      another tree to find used modules in (board apps: the emitter's board pack)
    --stdlib DIR   compiler/stdlib, when TRIALS_DIR is not trials/
    apply on trials/ skips the paths in e2236_exclusions.txt unless --exclude-file names another list

E2236 (Lee, 2026-10-11): in main's order of execution register_failure_reporter must run before any
spawn* start, in main or in a function main calls (transitively, across modules). The conversion is
two insertions:

    _: atom <- start_reporter();       main's first statement
    <the reporter>                     appended after the last declaration: region_dump_limit,
                                       report_is_from_root_supervisor, reporter, start_reporter,
                                       the same text gen_support.py writes into the trial-support
                                       modules (gen_support.REPORTER + START_REPORTER)

The reporter writes every unwind report to stderr, as the runtime does when no reporter is
registered, so a .scout that holds a failure banner still matches; the root supervisor's report
ends the program with cast_exit(70). It is written into the trial rather than into a shared module
on purpose: a used module is a dependency, which moves the trial later in the compiler's compile
order (main_topo takes the first ready unit in config order) and renumbers the suite's atoms,
changing every .ascomp in the suite. Written into the trial, the compile order is unchanged, and the
reporter names only atoms the trial already names where it can (reporter_block): its reply form
and its stack policy follow the trial's.

The analysis is textual (silica_scan masks comments and strings): a start is a `spawn*(` call
outside function literals; local calls and qualified calls into modules found under trials/ (or
compiler/stdlib) are followed transitively; behaviours and init functions passed by name are not
calls and are not followed. A registration is `register_failure_reporter(` or a call to
trial_{support,wait}_<T>@start(), which registers first. main's statements are taken in source
order; the first event decides. Generated copies (.target/, .trial_stdlib/, .stdlib_cache/) and
symlinks are skipped.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import silica_scan as ss  # noqa: E402
import gen_support  # noqa: E402

SPAWN_RE = re.compile(r'\bspawn[a-z_]*\s*\(')
REG_RE = re.compile(r'\bregister_failure_reporter\s*\(')
QCALL_RE = re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)@([A-Za-z_][A-Za-z0-9_]*)\s*\(')
CALL_RE = re.compile(r'(?<![@A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)\s*\(')
FNLIT_RE = re.compile(r'\bfn\s*\(')
SUPPORT_START_RE = re.compile(r'^trial_(support|wait|call)_[a-z0-9_]+$')
SKIP_DIRS = {'.target', '.trial_stdlib', '.stdlib_cache', '.git'}
STMT = '_: atom <- start_reporter();'
BLOCK = gen_support.REPORTER + gen_support.START_REPORTER
POLICY_RE = re.compile(r'\bstack_policy\s*\([^,()]*,\s*(:[A-Za-z_][A-Za-z0-9_]*)\s*\)')


def reporter_block(m):
    """The reporter for a trial whose masked text is m, written with atoms the trial already names
    where it can. A unit's atoms join the application's table when the unit compiles; an atom the
    trial did not name before would join earlier than it used to and renumber the suite.
      - a trial with :reply and no :no_reply gets a reply-form reporter, (:reply, 0, state): the
        runtime casts each report to it, and a cast's reply is dropped;
      - the reporter's stack policy is the first release algorithm the trial already names."""
    block = BLOCK
    if re.search(r':reply\b', m) and not re.search(r':no_reply\b', m):
        block = block.replace('fn reporter(report: string, state: int64) -> (:no_reply, int64) {',
                              'fn reporter(report: string, state: int64) -> (:reply, int64, int64) {')
        block = block.replace('        pure (:no_reply, state)\n    end\n}\n\n// Spawns',
                              '        pure (:reply, 0, state)\n    end\n}\n\n// Spawns')
    pm = POLICY_RE.search(m)
    if pm and pm.group(1) != ':keep_last_message':
        block = block.replace('stack_policy(0, :keep_last_message)', 'stack_policy(0, %s)' % pm.group(1))
    return block


def mask_all(text):
    """silica_scan.mask plus `{- ... -}` block comments (same length, newlines kept)."""
    out = list(text)
    i = 0
    while True:
        i = text.find('{-', i)
        if i < 0:
            break
        j = text.find('-}', i + 2)
        j = len(text) if j < 0 else j + 2
        for k in range(i, j):
            if out[k] != '\n':
                out[k] = ' '
        i = j
    return ss.mask(''.join(out))


def blank_fn_literals(m):
    """m with every function literal's whole text (header and body) blanked: its body runs in an
    actor or later, never as part of the enclosing function's order (spec: not followed)."""
    out = list(m)
    for mo in FNLIT_RE.finditer(m):
        po = mo.end() - 1
        pc = ss.match_close(m, po, '(', ')')
        if pc < 0:
            continue
        # skip `-> type` to the body brace, as silica_scan.top_level_fns does
        j = pc + 1
        arrow = m.find('->', j)
        brace = m.find('{', j)
        if brace < 0:
            continue
        if arrow >= 0 and arrow < brace:
            k = arrow + 2
            depth = 0
            body = -1
            while k < len(m):
                ch = m[k]
                if ch in '([':
                    depth += 1
                elif ch in ')]':
                    depth -= 1
                elif ch == '{':
                    if depth == 0:
                        prev = m[arrow + 2:k].strip()
                        if prev == '' or prev.endswith('|') or prev.endswith(':') or prev.endswith(','):
                            depth += 1
                        else:
                            body = k
                            break
                    else:
                        depth += 1
                elif ch == '}':
                    depth -= 1
                k += 1
            if body < 0:
                continue
        else:
            # a function TYPE (`fn(int64) -> int64` without a body) is not a literal
            continue
        bc = ss.match_close(m, body)
        if bc < 0:
            continue
        for k in range(mo.start(), bc + 1):
            if out[k] != '\n':
                out[k] = ' '
    return ''.join(out)


class Unit:
    def __init__(self, path):
        self.path = path
        self.text = open(path, encoding='utf-8', errors='replace').read()
        self.m = mask_all(self.text)
        self.fns = {}
        try:
            for f in ss.top_level_fns(self.text, self.m):
                self.fns.setdefault(f.name, f)
        except Exception:
            pass

    def body(self, name):
        f = self.fns.get(name)
        if f is None:
            return None
        return blank_fn_literals(self.m[f.body_open + 1:f.body_close])


class Index:
    def __init__(self, trials, stdlib, libs=()):
        self.trials = trials
        self.by_name = {}
        for top in (trials,) + tuple(libs):
            for root, dirs, files in os.walk(top):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
                for fn in files:
                    if fn.endswith('.silica'):
                        self.by_name.setdefault(fn[:-7], []).append(os.path.join(root, fn))
        for fn in os.listdir(stdlib):
            if fn.endswith('.silica'):
                self.by_name.setdefault(fn[:-7], []).append(os.path.join(stdlib, fn))
        self.units = {}
        self.memo = {}

    def unit(self, path):
        u = self.units.get(path)
        if u is None:
            u = self.units[path] = Unit(path)
        return u

    def resolve(self, mod, near):
        """Path of module `mod` used from the file `near`: same directory, its lib/, then the
        nearest ancestor directory up to trials/, then anywhere."""
        cands = self.by_name.get(mod, [])
        if not cands:
            return None
        d = os.path.dirname(os.path.abspath(near))
        top = os.path.abspath(self.trials)
        while True:
            for c in cands:
                cd = os.path.dirname(os.path.abspath(c))
                if cd == d or cd == os.path.join(d, 'lib'):
                    return c
            if d == top or len(d) <= len(top):
                break
            d = os.path.dirname(d)
        for c in cands:
            if c.startswith(top + os.sep):
                cdir = os.path.dirname(c)
                if os.path.commonpath([cdir, os.path.dirname(os.path.abspath(near))]) != top:
                    return c
        return cands[0]

    def events(self, path, name, stack=()):
        """Ordered list of (offset, kind, detail) in function `name` of `path`; kind is 'start' or
        'register'. Calls that reach a start (and do not register first) count as a start."""
        u = self.unit(path)
        body = u.body(name)
        if body is None:
            return None
        base = u.fns[name].body_open + 1
        ev = []
        for mo in SPAWN_RE.finditer(body):
            ev.append((mo.start(), 'start', 'spawn'))
        for mo in REG_RE.finditer(body):
            ev.append((mo.start(), 'register', 'register_failure_reporter'))
        for mo in QCALL_RE.finditer(body):
            mod, fn = mo.group(1), mo.group(2)
            if SUPPORT_START_RE.match(mod):
                if fn == 'start':
                    ev.append((mo.start(), 'register', '%s@start' % mod))
                continue
            p = self.resolve(mod, path)
            if p is None:
                continue
            r = self.first_event(p, fn, stack)
            if r == 'start':
                ev.append((mo.start(), 'start', '%s@%s' % (mod, fn)))
            elif r == 'register':
                ev.append((mo.start(), 'register', '%s@%s' % (mod, fn)))
        for mo in CALL_RE.finditer(body):
            fn = mo.group(1)
            if fn in ('fn', 'spawn') or fn.startswith('spawn') or fn not in u.fns or fn == name:
                continue
            r = self.first_event(path, fn, stack)
            if r == 'start':
                ev.append((mo.start(), 'start', fn))
            elif r == 'register':
                ev.append((mo.start(), 'register', fn))
        ev.sort()
        # the reporter's own spawn: bound and registered in the same function, or inline
        out = []
        for off, kind, det in ev:
            if kind == 'start' and det == 'spawn':
                line_start = body.rfind('\n', 0, off) + 1
                line = body[line_start:body.find('\n', off) if body.find('\n', off) >= 0 else len(body)]
                if REG_RE.search(body[max(0, off - 40):off]):
                    continue  # register_failure_reporter(spawn(...))
                mb = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*actor_ref\s*<-\s*spawn\s*\(', line)
                if mb and re.search(r'\bregister_failure_reporter\s*\(\s*%s\s*\)' % re.escape(mb.group(1)),
                                    body[off:]):
                    continue
            out.append((off + base, kind, det))
        return out

    def first_event(self, path, name, stack=()):
        key = (path, name)
        if key in self.memo:
            return self.memo[key]
        if key in stack:
            return None
        ev = self.events(path, name, stack + (key,))
        r = ev[0][1] if ev else None
        self.memo[key] = r
        return r


def trial_files(trials):
    for root, dirs, files in os.walk(trials):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and d != 'lib_trial_support')
        for fn in sorted(files):
            p = os.path.join(root, fn)
            if fn.endswith('.silica') and not os.path.islink(p):
                yield p


def needs(idx, path):
    """(True, detail) when main's first event is a start."""
    u = idx.unit(path)
    if 'main' not in u.fns:
        return False, None
    ev = idx.events(path, 'main')
    if not ev:
        return False, None
    off, kind, det = ev[0]
    if kind == 'start':
        line = u.text.count('\n', 0, off) + 1
        return True, '%s line %d' % (det, line)
    return False, None


def convert_text(text):
    """Insert main's first statement and append the reporter; return (new_text, (stmt_pos,
    stmt_ins)) or raise ValueError."""
    m = mask_all(text)
    fns = [f for f in ss.top_level_fns(text, m) if f.name == 'main']
    if not fns:
        raise ValueError('main not found')
    f = fns[0]
    inner = m[f.body_open + 1:f.body_close]
    seq = re.match(r'\s*sequence\b[^\n]*\n', inner)
    if seq:
        pos = f.body_open + 1 + seq.end()
    else:
        nl = inner.find('\n')
        if nl < 0 or inner[:nl].strip():
            raise ValueError('main body is not on its own lines')
        pos = f.body_open + 1 + nl + 1
    # indentation of the next non-blank line
    rest = text[pos:]
    mi = re.match(r'(?:[ \t]*\n)*([ \t]*)', rest)
    indent = mi.group(1)
    stmt = indent + STMT + '\n'
    tail = text.rstrip('\n')
    new = text[:pos] + stmt + tail[pos:] + '\n\n' + reporter_block(m)
    return new, (pos, stmt)


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ('scan', 'apply'):
        print(__doc__)
        sys.exit(2)
    mode = args[0]
    rest = []
    k = 1
    while k < len(args):
        if args[k] in ('--tsv', '--only', '--exclude-file', '--lib', '--stdlib'):
            k += 2
            continue
        rest.append(args[k])
        k += 1
    here = os.path.dirname(os.path.abspath(__file__))
    trials = rest[0] if rest else os.path.normpath(os.path.join(here, '..', '..', 'trials'))
    stdlib = os.path.normpath(os.path.join(trials, '..', 'compiler', 'stdlib'))
    tsv = None
    libs = []
    only = []
    exclude = set()
    i = 1
    while i < len(args):
        if args[i] == '--tsv':
            tsv = args[i + 1]; i += 2; continue
        if args[i] == '--lib':
            libs.append(args[i + 1]); i += 2; continue
        if args[i] == '--stdlib':
            stdlib = args[i + 1]; i += 2; continue
        if args[i] == '--only':
            only.append(args[i + 1]); i += 2; continue
        if args[i] == '--exclude-file':
            for line in open(args[i + 1]):
                line = line.strip()
                if line and not line.startswith('#'):
                    exclude.add(line)
            i += 2; continue
        i += 1
    if mode == 'apply' and not exclude and os.path.abspath(trials) == os.path.normpath(os.path.join(here, '..', '..', 'trials')):
        for line in open(os.path.join(here, 'e2236_exclusions.txt')):
            line = line.strip()
            if line and not line.startswith('#'):
                exclude.add(line)
    idx = Index(trials, stdlib, libs)
    rows = []
    for p in trial_files(trials):
        rel = os.path.relpath(p, trials)
        if only and not any(rel.startswith(o) for o in only):
            continue
        try:
            n, det = needs(idx, p)
        except RecursionError:
            n, det = False, 'recursion'
        if n:
            rows.append((rel, det))
    if tsv:
        with open(tsv, 'w') as fh:
            for rel, det in rows:
                fh.write('%s\t%s\n' % (rel, det))
    if mode == 'scan':
        counts = {}
        for rel, _ in rows:
            counts[rel.split('/')[0]] = counts.get(rel.split('/')[0], 0) + 1
        for k in sorted(counts):
            print('%5d  %s' % (counts[k], k))
        print('%5d  total' % len(rows))
        return
    done, failed = 0, []
    for rel, det in rows:
        if rel in exclude:
            continue
        p = os.path.join(trials, rel)
        text = open(p, encoding='utf-8').read()
        if 'fn start_reporter(' in text:
            continue
        try:
            new, _ = convert_text(text)
        except ValueError as e:
            failed.append((rel, str(e)))
            continue
        open(p, 'w', encoding='utf-8').write(new)
        done += 1
    print('converted %d' % done)
    for rel, why in failed:
        print('left %s: %s' % (rel, why))


if __name__ == '__main__':
    main()
