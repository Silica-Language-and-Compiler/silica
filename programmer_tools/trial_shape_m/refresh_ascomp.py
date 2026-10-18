#!/usr/bin/env python3
"""Refresh .ascomp goldens of one suite after `make integrate`, only where the run matched .scout.

    refresh_ascomp.py <suite_dir> [--ext .ascomp|.linux_aarch64.ascomp|.linux_x86_64.ascomp] [--dry]

Lee's rule (2026-10-07): an .ascomp may be updated without asking as long as the trial's .sout
matches its .scout. The integrate log is the evidence: a trial is refreshed only when the suite's
.integrate_log (or, for nested suites, the log next to the trial) says
`<prefix><stem> output matches .scout` / `output multiset-matches .scout`, and only when its .sams
differs from the golden. Prints what it copied and what it refused.
"""

import os
import re
import shutil
import sys

OK_RE = re.compile(r'✅✅ (\S+) output (?:multiset-)?matches \.scout')


def main():
    args = sys.argv[1:]
    dry = '--dry' in args
    ext = '.ascomp'
    if '--ext' in args:
        ext = args[args.index('--ext') + 1]
    sdir = os.path.abspath(args[0])
    matched = set()
    for d, dirs, files in os.walk(sdir):
        if '.integrate_log' in files:
            for ln in open(os.path.join(d, '.integrate_log'), encoding='utf-8', errors='replace'):
                mo = OK_RE.search(ln)
                if mo:
                    matched.add(mo.group(1).split('/')[-1])
    copied, refused = [], []
    for d, dirs, files in os.walk(sdir):
        dirs[:] = [x for x in dirs if x not in ('.trial_stdlib', '.target')]
        for f in files:
            if not f.endswith('.sams') or f == '__silica_runtime.sams':
                continue
            stem = f[:-5]
            sams = os.path.join(d, f)
            gold = os.path.join(d, stem + ext)
            if os.path.exists(gold) and open(sams, 'rb').read() == open(gold, 'rb').read():
                continue
            if stem not in matched:
                refused.append(os.path.relpath(sams, sdir))
                continue
            if not os.path.exists(gold) and not os.path.exists(os.path.join(d, stem + '.scout')):
                continue  # a helper unit without goldens
            if not dry:
                shutil.copyfile(sams, gold)
            copied.append(os.path.relpath(gold, sdir))
    print('refreshed %d %s goldens; refused %d (run did not match .scout)' % (len(copied), ext, len(refused)))
    for r in refused:
        print('  refused', r)


if __name__ == '__main__':
    main()
