#!/usr/bin/env python3
"""Probe: learn the exact value each form-C trial's `main` returns today (shape.py: a non-int64 type and
a computed result), which the converted main then ends with as a literal.

The exit status is only the value modulo 256 (an atom's is its index in the suite's atom table, a
float's is its truncation), and a .scout cannot tell it apart from output that lacks a final newline
("7" then status "0" reads "70"). The transformer needs the value itself, so this builds a probe copy
of the suite in a scratch mirror (mirror.sh) in which `main` is renamed `trial_main` and a new `main`
calls it, prints `@@M_PROBE <value>` on a line of its own, and returns the value. The suite's own
Makefile builds and runs it; each <trial>.sout then carries the original output, the probe line and
the real exit status.

    probe.py <mirror_trials_dir> <suite> <compiler> <out.json> [--skip-train]

out.json: { "<suite>/<rel>.silica": {"value": "...", "status": s, "baseline_ok": bool, "ret_type": T} }
baseline_ok: the trial's output (probe line removed) plus status equals its .scout (diff -Bw rules).
"""

import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inventory  # noqa: E402
import shape  # noqa: E402
import silica_scan as ss  # noqa: E402

PRINT_FN = {t: 'print_' + t for t in shape.INT_TYPES + shape.FLOAT_TYPES + ('uint8',)}
PRINT_FN['atom'] = 'print_atom'
PRINT_FN['boolean'] = 'print_boolean'
MARK = '@@M_PROBE '


def probe_main(ty):
    return ('\nfn main() -> %s {\n'
            '    sequence proc[device_io]\n'
            '        value: %s <- trial_main();\n'
            '        println("");\n'
            '        print_string("%s");\n'
            '        _: atom <- %s(value);\n'
            '        println("")\n'
            '    produces\n'
            '        pure value\n'
            '    end\n'
            '}\n') % (ty, ty, MARK, PRINT_FN[ty])


def norm(s):
    """diff -Bw equivalence: drop blank lines, drop all whitespace."""
    return [re.sub(r'\s+', '', ln) for ln in s.splitlines() if ln.strip()]


def make_probe(path):
    text = open(path, encoding='utf-8').read()
    m = ss.mask(text)
    pos, f = shape.locate_main(text, m)
    if f is None:
        return None
    ty = shape.binding_type(f.ret_type)
    if ty not in PRINT_FN:
        return None
    new = text[:pos] + 'trial_main' + text[pos + 4:]
    if not new.endswith('\n'):
        new += '\n'
    new += probe_main(ty)
    open(path, 'w', encoding='utf-8').write(new)
    return ty


def parse_sout(sout_path):
    raw = open(sout_path, encoding='utf-8', errors='surrogateescape').read()
    lines = raw.rstrip('\n').split('\n')
    status = lines[-1].strip()
    body = raw[:raw.rstrip('\n').rfind('\n') + 1] if len(lines) > 1 else ''
    k = body.rfind('\n' + MARK)
    if k < 0:
        return None
    value_line = body[k + 1 + len(MARK):].split('\n', 1)[0]
    original = body[:k]  # without the println("") we added before the marker
    return original, value_line.strip(), status


def main():
    mirror, suite, compiler, out = sys.argv[1:5]
    skip_train = '--skip-train' in sys.argv
    sdir = os.path.join(mirror, suite)
    rows = [inventory.classify(p) for p in inventory.walk(sdir)]
    probed = {}
    for r in rows:
        if r['role'] != 'run' or r['shape'] not in ('value', 'print', 'actors'):
            continue
        if skip_train and r['train']:
            continue
        try:
            if shape.choose_form(open(r['path'], encoding='utf-8').read())[0] != 'C':
                continue
        except shape.ShapeError:
            continue
        ty = make_probe(r['path'])
        if ty:
            probed[r['path']] = ty
    if not probed:
        json.dump({}, open(out, 'w'))
        print('%s: no form-C trials to probe' % suite)
        return
    env = dict(os.environ, SILICA_TARGET_PROMPT='0')
    log = os.path.join(mirror, suite.replace('/', '_') + '.probe.log')
    with open(log, 'w') as lf:
        subprocess.run(['make', 'integrate', 'TRIAL_TARGET=host', 'SILICA_COMPILER=' + compiler],
                       cwd=sdir, stdout=lf, stderr=subprocess.STDOUT, env=env)
    res = {}
    for path, ty in probed.items():
        base = path[:-len('.silica')]
        key = os.path.relpath(path, mirror)
        rec = {'ret_type': ty, 'value': None, 'status': None, 'baseline_ok': False}
        if os.path.exists(base + '.sout'):
            p = parse_sout(base + '.sout')
            if p:
                original, value, status = p
                rec['value'] = value
                rec['status'] = int(status) if status.isdigit() else status
                scout = open(base + '.scout', encoding='utf-8', errors='surrogateescape').read()
                rec['baseline_ok'] = norm(original + status + '\n') == norm(scout)
                if not rec['baseline_ok']:
                    # output without a final newline: the harness glued the status onto it
                    rec['baseline_ok'] = norm(original.rstrip('\n') + status + '\n') == norm(scout)
        res[key] = rec
    json.dump(res, open(out, 'w'), indent=1, sort_keys=True)
    ok = sum(1 for v in res.values() if v['baseline_ok'])
    print('%s: probed %d, baseline matches .scout %d, log %s' % (suite, len(res), ok, log))


if __name__ == '__main__':
    main()
