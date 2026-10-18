#!/usr/bin/env python3
"""Convert error_enforcement_addition/ffi_addition's compile-fail cases (FAIL_CASES in its Makefile)
and re-derive their .golden_fail with that Makefile's own `compile-fail-goldens` rule.

    errcheck_ffi.py <error_ffi_dir> <compiler> [--install]

Cases about main itself (their name says `main`) are left. Each other case: rename + reshape
(placeholder result), all cases compiled by `make compile-fail-goldens`, and a case is kept only
when its new .cur_fail reports the same errorCode at the old position carried through the edits
(or the identical output); otherwise its source is put back.
"""
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import convert  # noqa: E402
import errcheck  # noqa: E402
import shape  # noqa: E402


def main():
    d, compiler = sys.argv[1], sys.argv[2]
    install = '--install' in sys.argv
    mk = open(os.path.join(d, 'Makefile')).read()
    block = re.search(r'FAIL_CASES := \\\n(.*?)\n\n', mk, re.S).group(1)
    cases = [ln.strip().rstrip('\\').strip() for ln in block.splitlines() if ln.strip()]
    state = {}
    for case in cases:
        src = os.path.join(d, case + '.silica')
        old = open(src, encoding='utf-8').read()
        if 'main' in os.path.basename(case):
            print('%s\tleft\tabout main itself' % case)
            continue
        t1, e1 = shape.rename_builtins(old)
        stages = [(old, t1, e1)]
        try:
            m = shape.ss.mask(t1)
            wait = bool(re.search(r'\bwait_for_exit\s*\(', m))
            form, t, lit = shape.choose_form(t1, wait_shape=wait)
            if form in ('B', 'C', 'W'):
                lit = convert.PLACEHOLDER.get(t, lit)
            t2, e2 = shape.reshape(t1, form, t, lit)
            stages.append((t1, t2, e2))
        except shape.ShapeError as e:
            print('%s\tleft\t%s' % (case, e))
            continue
        open(src, 'w', encoding='utf-8').write(t2)
        state[case] = (old, t2, stages, form)
    subprocess.run(['make', '-C', d, 'compile-fail-goldens', 'SILICA_COMPILER=' + compiler],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for case, (old, new, stages, form) in state.items():
        gold = os.path.join(d, case + '.golden_fail')
        cur = os.path.join(d, case + '.cur_fail')
        og = open(gold, encoding='utf-8', errors='replace').read()
        ng = open(cur, encoding='utf-8', errors='replace').read() if os.path.exists(cur) else ''
        om, nm = errcheck.meta(og), errcheck.meta(ng)
        status = 'moved'
        detail = ''
        if ng == og:
            status = 'same'
        elif not om or not nm:
            status = 'nometa'
        elif om.get('errorCode') != nm.get('errorCode'):
            status, detail = 'code', '%s -> %s' % (om.get('errorCode'), nm.get('errorCode'))
        else:
            same_file = os.path.basename(case) + '.silica' == om.get('file')
            try:
                exp = shape.map_through(stages, int(om['line']), int(om['column']), int(om['offset'])) \
                    if same_file else (int(om['line']), int(om['column']), int(om['offset']))
            except (KeyError, ValueError):
                exp = None
            got = (int(nm['line']), int(nm['column']), int(nm['offset']))
            detail = '%s old %s:%s@%s exp %s got %s' % (form, om['line'], om['column'], om['offset'], exp, got)
            if exp is not None and tuple(exp) == got:
                status = 'same' if errcheck.message(og) == errcheck.message(ng) else 'same_msgdiff'
        if status in ('same', 'same_msgdiff') and install:
            shutil.copyfile(cur, gold)
        else:
            open(os.path.join(d, case + '.silica'), 'w', encoding='utf-8').write(old)
        print('%s\t%s\t%s' % (case, status, detail))


if __name__ == '__main__':
    main()
