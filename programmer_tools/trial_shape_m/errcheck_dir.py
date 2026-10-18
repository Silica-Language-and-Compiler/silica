#!/usr/bin/env python3
"""Convert the multi-file error trials of error_enforcement_addition (one directory per trial, each
with its own Makefile and `check` target) and re-derive their .golden_fail from the real compiler.

    errcheck_dir.py <error_enforcement_dir> <compiler> [--install] [--only DIR,...]

Per trial directory:
  1. the unit holding `main` gets shape.rename_builtins + shape.reshape (forms as for any error
     trial; an excluded or unparsable main is left), the other units the rename only;
  2. the Makefile gets the trial-support hook (patch_makefile.py);
  3. `make check` writes the directory's .cur_fail with this compiler;
  4. the new output must report the same errorCode as the golden, at the old position carried through
     the edits when the error is in the main unit, and at the very same position when it is in
     another unit (same construct). Then (--install) .cur_fail becomes .golden_fail; otherwise the
     sources and Makefile are restored.
Platform goldens (<stem>.linux_*.golden_fail) are re-derived on those hosts.
"""
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import convert  # noqa: E402
import errcheck  # noqa: E402
import patch_makefile  # noqa: E402
import shape  # noqa: E402

PLACEHOLDER = convert.PLACEHOLDER


def one_dir(d, compiler, pats, install):
    name = os.path.basename(d.rstrip('/'))
    golds = [f for f in os.listdir(d) if f.endswith('.golden_fail') and '.linux_' not in f and '..golden' not in f]
    if len(golds) != 1:
        return name, 'left', 'golden files: %r' % golds
    gold = os.path.join(d, golds[0])
    cur = gold[:-len('.golden_fail')] + '.cur_fail'
    old_gold = open(gold, encoding='utf-8', errors='replace').read()
    srcs = sorted(f for f in os.listdir(d) if f.endswith('.silica'))
    texts = {f: open(os.path.join(d, f), encoding='utf-8').read() for f in srcs}
    mains = [f for f in srcs if re.search(r'(?m)^\s*(fn\s+)?main\s*\(', shape.ss.mask(texts[f]))]
    new = {}
    stages = {}
    why = ''
    for f in srcs:
        t1, e1 = shape.rename_builtins(texts[f])
        new[f] = t1
        stages[f] = [(texts[f], t1, e1)]
    form = '-'
    if len(mains) == 1:
        f = mains[0]
        key = 'error_enforcement_addition/%s/%s' % (name, f)
        try:
            if convert.excluded(key, pats) or convert.excluded('error_enforcement_addition/%s' % name, pats):
                raise shape.ShapeError('excluded')
            if re.search(r'(?m)^\s*impl\s+\w+\s+for\s+Supervisor\s*;', texts[f]):
                raise shape.ShapeError('implements Supervisor itself')
            m = shape.ss.mask(new[f])
            wait = bool(re.search(r'\bwait_for_exit\s*\(', m))
            form, t, lit = shape.choose_form(new[f], wait_shape=wait)
            if form in ('B', 'C', 'W'):
                lit = PLACEHOLDER.get(t, lit)
            t2, e2 = shape.reshape(new[f], form, t, lit)
            stages[f].append((new[f], t2, e2))
            new[f] = t2
        except shape.ShapeError as e:
            why = str(e)
    else:
        why = '%d units with main' % len(mains)
    if all(new[f] == texts[f] for f in srcs):
        return name, 'left', why or 'nothing to change'
    mk = os.path.join(d, 'Makefile')
    mk_old = open(mk).read()
    mk_new, _ = patch_makefile.patch(mk_old)
    for f in srcs:
        open(os.path.join(d, f), 'w', encoding='utf-8').write(new[f])
    open(mk, 'w').write(mk_new)
    subprocess.run(['make', '-C', d, 'check', 'SILICA_COMPILER=' + compiler, 'COMPILER=' + compiler],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    new_gold = open(cur, encoding='utf-8', errors='replace').read() if os.path.exists(cur) else ''
    om, nm = errcheck.meta(old_gold), errcheck.meta(new_gold)
    status, detail = 'moved', ''
    if new_gold == old_gold:
        status = 'same'   # the output does not mention the edited unit at all (a module-level error)
    elif not om or not nm:
        status = 'nometa'
    elif om.get('errorCode') != nm.get('errorCode'):
        status, detail = 'code', '%s -> %s' % (om.get('errorCode'), nm.get('errorCode'))
    elif status != 'same':
        ef = om.get('file', '')
        st = stages.get(ef)
        try:
            exp = shape.map_through(st, int(om['line']), int(om['column']), int(om['offset'])) if st else \
                (int(om['line']), int(om['column']), int(om['offset']))
        except (KeyError, ValueError):
            exp = None
        got = (int(nm['line']), int(nm['column']), int(nm['offset'])) if nm.get('offset', '').isdigit() else None
        detail = '%s %s old %s:%s@%s exp %s got %s' % (form, ef, om.get('line'), om.get('column'), om.get('offset'), exp, got)
        if exp is not None and got == tuple(exp) and nm.get('file') == ef:
            status = 'same' if errcheck.message(old_gold) == errcheck.message(new_gold) else 'same_msgdiff'
    if status in ('same', 'same_msgdiff') and install:
        shutil.copyfile(cur, gold)
    elif status not in ('same', 'same_msgdiff') or not install:
        for f in srcs:
            open(os.path.join(d, f), 'w', encoding='utf-8').write(texts[f])
        open(mk, 'w').write(mk_old)
    return name, status, detail + ((' [' + why + ']') if why else '')


def main():
    args = sys.argv[1:]
    edir, compiler = args[0], args[1]
    install = '--install' in args
    only = args[args.index('--only') + 1].split(',') if '--only' in args else None
    pats = convert.exclusions()
    for d in sorted(os.listdir(edir)):
        p = os.path.join(edir, d)
        if not os.path.isdir(p) or not os.path.exists(os.path.join(p, 'Makefile')):
            continue
        if only and d not in only:
            continue
        if not re.search(r'(?m)^check:', open(os.path.join(p, 'Makefile')).read()):
            continue
        print('\t'.join(one_dir(p, compiler, pats, install)), flush=True)


if __name__ == '__main__':
    main()
