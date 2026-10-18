#!/usr/bin/env python3
"""Put back the old shape of converted trials whose run no longer matches their .scout.

    revert_failed.py <suite_dir> [--dry]

Reads the suite's .integrate_log files for `<stem> .sout differs from .scout` (and `missing
executable`) lines. For each such trial that is in the shape (`use trial_...`), the source in git
HEAD is taken as the old program, but only when reshaping it (rename + the same form, type and
literal as the current file) reproduces the current file byte for byte: then the current file is
known to be exactly the conversion of HEAD, and HEAD (with the print_bool rename) is written back.
Anything else is listed and left alone. Prints `reverted <path>` / `kept <path>: <why>`.

Typical cause: the exit status of a main returning a non-predefined atom is that atom's index in the
suite's atom table, and the trial-support module adds atoms (:trial_worker, :trial_supervisor, ...)
ahead of the trials' own, so the status moves although the program is unchanged.
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shape  # noqa: E402

FAIL_RE = re.compile(r'❌❌ (\S+) (?:\.sout differs from \.scout|missing executable)')


def head_text(path):
    root = subprocess.run(['git', '-C', os.path.dirname(path), 'rev-parse', '--show-toplevel'],
                          stdout=subprocess.PIPE, text=True).stdout.strip()
    rel = os.path.relpath(os.path.realpath(path), os.path.realpath(root))
    p = subprocess.run(['git', '-C', root, 'show', 'HEAD:' + rel], stdout=subprocess.PIPE)
    return p.stdout.decode('utf-8') if p.returncode == 0 else None


def main():
    sdir = os.path.abspath(sys.argv[1])
    dry = '--dry' in sys.argv
    stems = set()
    for d, dirs, files in os.walk(sdir):
        if '.integrate_log' in files:
            for ln in open(os.path.join(d, '.integrate_log'), encoding='utf-8', errors='replace'):
                mo = FAIL_RE.search(ln)
                if mo:
                    stems.add(mo.group(1).split('/')[-1])
    for d, dirs, files in os.walk(sdir):
        dirs[:] = [x for x in dirs if x not in ('.trial_stdlib', '.target')]
        for f in files:
            if not f.endswith('.silica') or f[:-7] not in stems:
                continue
            path = os.path.join(d, f)
            cur = open(path, encoding='utf-8').read()
            mo = re.search(r'(?m)^use (trial_(support|wait)_([a-z0-9]+));', cur)
            if not mo:
                print('kept %s: not in the shape' % path)
                continue
            old = head_text(path)
            if old is None:
                print('kept %s: not in git HEAD' % path)
                continue
            renamed, _ = shape.rename_builtins(old)
            t = mo.group(3)
            lit = re.findall(r'(?m)^        pure (\S+)\n    end\n}\s*$', cur)
            ok = False
            for form in ('A', 'B', 'C', 'W'):
                try:
                    if shape.module_for(form, t) != mo.group(1):
                        continue
                    if shape.reshape(renamed, form, t, lit[0] if lit else None)[0] == cur:
                        ok = True
                        break
                except shape.ShapeError:
                    continue
            if not ok:
                print('kept %s: current file is not the plain conversion of HEAD' % path)
                continue
            if not dry:
                open(path, 'w', encoding='utf-8').write(renamed)
            print('reverted %s' % path)


if __name__ == '__main__':
    main()
