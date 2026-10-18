#!/usr/bin/env python3
"""After `make integrate` of the whole tree on a Linux host: capture that host's goldens.

    linux_goldens.py <trials_dir> <emit_target> [--dry]        (emit_target: linux_aarch64 | linux_x86_64)

1. .<target>.ascomp: per suite, refresh_ascomp.py's rule (the integrate log says the trial's run
   matched .scout) with --ext .<target>.ascomp.
2. .<target>.golden_fail: for every <stem>.<target>.golden_fail next to a <stem>.cur_fail written by
   this run, the new output becomes the golden when it reports the same errorCode, file, line, column
   and offset as the (already re-derived and checked) macOS <stem>.golden_fail.
Prints what it copied and what it refused.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import errcheck  # noqa: E402


def main():
    root, target = sys.argv[1], sys.argv[2]
    dry = '--dry' in sys.argv
    ext = '.' + target + '.ascomp'
    for s in sorted(os.listdir(root)):
        p = os.path.join(root, s)
        if os.path.isdir(p) and not s.startswith('.') and (
                os.path.exists(os.path.join(p, 'Makefile')) or os.path.exists(os.path.join(p, 'makefile'))):
            args = [sys.executable, os.path.join(HERE, 'refresh_ascomp.py'), p, '--ext', ext] + (['--dry'] if dry else [])
            out = subprocess.run(args, stdout=subprocess.PIPE, text=True).stdout
            print('%s: %s' % (s, out.splitlines()[0] if out else ''))
            for ln in out.splitlines()[1:]:
                print('   ' + ln)
    gext = '.' + target + '.golden_fail'
    for d, dn, fn in os.walk(root):
        dn[:] = [x for x in dn if x not in ('.trial_stdlib', '.target')]
        for f in fn:
            if not f.endswith(gext):
                continue
            stem = f[:-len(gext)]
            cur = os.path.join(d, stem + '.cur_fail')
            mac = os.path.join(d, stem + '.golden_fail')
            if not (os.path.exists(cur) and os.path.exists(mac)):
                continue
            ng = open(cur, errors='replace').read()
            old = open(os.path.join(d, f), errors='replace').read()
            if ng == old:
                continue
            nm, mm = errcheck.meta(ng), errcheck.meta(open(mac, errors='replace').read())
            keys = ('errorCode', 'file', 'line', 'column', 'offset')
            if nm and mm and all(nm.get(k) == mm.get(k) for k in keys):
                if not dry:
                    shutil.copyfile(cur, os.path.join(d, f))
                print('golden_fail refreshed %s' % os.path.join(d, f))
            else:
                print('golden_fail refused %s: %s vs macOS %s' % (
                    os.path.join(d, f), nm and [nm.get(k) for k in keys], mm and [mm.get(k) for k in keys]))


if __name__ == '__main__':
    main()
