#!/usr/bin/env python3
"""Convert one suite's trial programs to the supervisor-actor shape (item M, design of 2026-10-08).

    convert.py <trials_root> <suite> [--probe probe.json] [--skip-train | --only-train] [--dry]
               [--report out.tsv] [--with-error]

Form C (a non-int64 main with a computed result) ends with the value the trial returns today, as a
literal; probe.py records it, and --probe passes it in.

Rewrites run trials (sibling .scout) in place with shape.reshape. Error trials (sibling
.golden_fail) need their golden re-derived, which errcheck.py does; convert.py skips them unless
--with-error is given (then it only rewrites the source).

Left unconverted, each with its reason in the report:
  - helpers (no main) and units with neither golden;
  - trials that implement Supervisor themselves (init/1 would collide);
  - trials named in exclusions.txt (trials about main itself, item K trials, defect repros);
  - run trials whose .scout carries a fatal banner from main itself (`[silica] fault` /
    `[silica] abort`) while main starts no actor: in a worker the failure would go to the supervisor;
  - a main no form fits (shape.ShapeError says why).
"""

import fnmatch
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inventory  # noqa: E402
import shape  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PLACEHOLDER = dict([(x, '0') for x in shape.INT_TYPES] + [(x, '0.0') for x in shape.FLOAT_TYPES]
                   + [('atom', ':ok'), ('boolean', 'true'), ('string', '""')])
BANNER_RE = re.compile(r'^\[silica\] (fault|abort)', re.M)
# a failure raised in main itself prints its reason and ends the process (status 1); in the worker
# the same failure goes to the supervisor and the program would wait forever
MAIN_FAILURE_RE = re.compile(r'^(language_error|badarith|case_clause|badmatch|function_clause)\s*$', re.M)


def exclusions():
    pats = []
    for ln in open(os.path.join(HERE, 'exclusions.txt')):
        ln = ln.split('#', 1)[0].strip()
        if ln:
            pats.append(ln)
    return pats


def excluded(key, pats):
    return next((p for p in pats if fnmatch.fnmatch(key, p)), None)


def plan(row, key, pats, probe=None):
    """(form, T, literal), or raises shape.ShapeError with the reason."""
    if row['role'] not in ('run', 'error'):
        raise shape.ShapeError('role %s' % row['role'])
    pat = excluded(key, pats)
    if pat:
        raise shape.ShapeError('excluded (%s)' % pat)
    if row['impl_sup']:
        raise shape.ShapeError('implements Supervisor itself')
    text = open(row['path'], encoding='utf-8').read()
    if row['role'] == 'run' and not row['actors']:
        scout = open(row['path'][:-len('.silica')] + '.scout', encoding='utf-8', errors='replace').read()
        if BANNER_RE.search(scout):
            raise shape.ShapeError("expects main's own fatal banner")
    if row['role'] == 'run':
        scout = open(row['path'][:-len('.silica')] + '.scout', encoding='utf-8', errors='replace').read()
        if MAIN_FAILURE_RE.search(scout) and scout.rstrip().endswith('\n1'):
            raise shape.ShapeError("expects a failure raised in main (status 1)")
    wait = row['shape'] == 'already'
    if wait and row['role'] == 'run' and not row['marker']:
        raise shape.ShapeError('main waits but the trial has no .wait_for_exit marker')
    form, t, lit = shape.choose_form(text, wait_shape=wait)
    if form == 'C' and row['role'] == 'run':
        rec = (probe or {}).get(key)
        if not rec or rec.get('value') is None:
            raise shape.ShapeError('form C needs a probe value (probe.py)')
        # a probe run that does not match the .scout means the .scout is already stale with this
        # compiler; the converted trial keeps the program's behaviour (reported by main())
        lit = rec['value']
        if not shape.LITERAL_RE.fullmatch(lit):
            raise shape.ShapeError('probe value %r is not a literal' % lit)
    if row['role'] == 'error' and form in ('B', 'C', 'W'):
        # an error trial never runs, and its own result may be the error (E2001): main ends with a
        # placeholder of its type instead of a copy of the original result
        lit = PLACEHOLDER.get(t, lit)
    return form, t, lit


def main():
    args = sys.argv[1:]
    report_path = None
    if '--report' in args:
        i = args.index('--report')
        report_path = args[i + 1]
        del args[i:i + 2]
    probe = {}
    if '--probe' in args:
        i = args.index('--probe')
        probe = json.load(open(args[i + 1]))
        del args[i:i + 2]
    flags = {a for a in args if a.startswith('--')}
    args = [a for a in args if not a.startswith('--')]
    root, suite = args[0], args[1]
    pats = exclusions()
    report, counts = [], {}
    for path in inventory.walk(os.path.join(root, suite)):
        row = inventory.classify(path)
        key = os.path.relpath(path, root)
        if row['train'] and '--skip-train' in flags:
            continue
        if not row['train'] and '--only-train' in flags:
            continue
        if row['role'] == 'error' and '--with-error' not in flags:
            continue
        original = open(path, encoding='utf-8').read()
        renamed, _ = shape.rename_builtins(original)
        if row['role'] == 'helper':
            if renamed != original and '--dry' not in flags:
                open(path, 'w', encoding='utf-8').write(renamed)
                report.append((key, 'renamed', 'helper'))
            continue
        try:
            form, t, lit = plan(row, key, pats, probe)
            new, _ = shape.reshape(renamed, form, t, lit)
        except shape.ShapeError as e:
            if renamed != original and '--dry' not in flags:
                open(path, 'w', encoding='utf-8').write(renamed)
            report.append((key, 'left', str(e)))
            counts['left'] = counts.get('left', 0) + 1
            continue
        if '--dry' not in flags:
            open(path, 'w', encoding='utf-8').write(new)
        stale = form == 'C' and not (probe.get(key) or {}).get('baseline_ok', True)
        report.append((key, form, '%s %s%s' % (t, lit or '', ' (stale .scout: probe run differs)' if stale else '')))
        counts[form] = counts.get(form, 0) + 1
    if report_path:
        with open(report_path, 'w') as o:
            for r in report:
                o.write('\t'.join(r) + '\n')
    print(suite, counts)
    for r in report:
        if r[1] == 'left':
            print('  left %s: %s' % (r[0], r[2]))


if __name__ == '__main__':
    main()
