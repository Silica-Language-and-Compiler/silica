#!/usr/bin/env python3
"""Inventory every trial program under trials/ by the shape item M must convert.

Usage:  inventory.py [TRIALS_DIR] [--tsv OUT.tsv]

One row per .silica file (except trials/**/.target/ copies), with:
  path, role, shape, ret_type, body, actors, supervisor, marker, collisions

role   helper     no `fn main` (a module a trial uses; not converted)
       error      a sibling .golden_fail exists (compile-error trial)
       run        a sibling .scout exists (compiled and run)
       other      main but neither golden
shape  (for run and error)
       already    main already ends in wait_for_exit, or spawns a supervisor
       actors     main spawns/casts/calls actors but does not wait
       value      main computes and returns a value, prints nothing
       print      main prints (device_io) and returns a value
ret_type, body: main's return type; `expr` or `seq` or `other`
"""

import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import silica_scan as ss  # noqa: E402

ACTOR_RE = re.compile(r'\b(spawn[a-z_]*|cast[a-z_]*|call[a-z_]*|wait_for_exit|self|recv|migrate_actor|link|monitor)\s*\(')
SUP_RE = re.compile(r'\bspawn_registered_supervisor\b')
WFE_RE = re.compile(r'\bwait_for_exit\s*\(')
PRINT_RE = re.compile(r'\b(print[a-z0-9_]*|println)\s*\(')
RESERVED = ('trial_main', 'trial_worker', 'init', 'TrialSupervisor')


def classify(path):
    text = open(path, encoding='utf-8', errors='surrogateescape').read()
    m = ss.mask(text)
    fns = ss.top_level_fns(text, m)
    names = [f.name for f in fns]
    mains = [f for f in fns if f.name == 'main']
    base = path[:-len('.silica')]
    if os.path.exists(base + '.golden_fail'):
        role = 'error'
    elif not mains:
        role = 'helper'
    elif os.path.exists(base + '.scout'):
        role = 'run'
    else:
        role = 'other'
    row = {
        'path': path, 'role': role, 'shape': '', 'ret_type': '', 'body': '',
        'actors': 0, 'supervisor': 0,
        'marker': int(os.path.exists(base + '.wait_for_exit')),
        'impl_sup': int(bool(ss.IMPL_SUP_RE.search(m))),
        'collisions': ','.join(r for r in RESERVED if r in names or (r == 'TrialSupervisor' and 'TrialSupervisor' in m)),
        'train': int(os.path.basename(path).startswith('train_')),
        'has_main': int(bool(mains)),
    }
    if not mains:
        return row
    f = mains[0]
    row['ret_type'] = f.ret_type or ''
    body_m = m[f.body_open:f.end]
    seq = ss.outer_sequence(text, f, m)
    row['body'] = 'seq' if seq else ('expr' if not re.match(r'\s*sequence\b', body_m[1:]) else 'other')
    row['actors'] = int(bool(ACTOR_RE.search(body_m)))
    row['supervisor'] = int(bool(SUP_RE.search(body_m)))
    wfe = bool(WFE_RE.search(body_m))
    if wfe or row['supervisor']:
        row['shape'] = 'already'
    elif row['actors']:
        row['shape'] = 'actors'
    elif PRINT_RE.search(body_m):
        row['shape'] = 'print'
    else:
        row['shape'] = 'value'
    return row


def walk(root):
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in ('.target', '.trial_stdlib'))
        for fn in sorted(files):
            if fn.endswith('.silica'):
                yield os.path.join(d, fn)


def main():
    args = sys.argv[1:]
    tsv = None
    if '--tsv' in args:
        i = args.index('--tsv')
        tsv = args[i + 1]
        del args[i:i + 2]
    root = args[0] if args else os.path.join(os.path.dirname(__file__), '..', '..', 'trials')
    root = os.path.normpath(root)
    rows = [classify(p) for p in walk(root)]
    cols = ['path', 'role', 'shape', 'train', 'ret_type', 'body', 'actors', 'supervisor', 'marker',
            'impl_sup', 'collisions']
    if tsv:
        with open(tsv, 'w') as o:
            o.write('\t'.join(cols) + '\n')
            for r in rows:
                o.write('\t'.join(str(r[c]) for c in cols) + '\n')
    c = Counter((r['role'], r['shape'], r['train']) for r in rows)
    print('files: %d' % len(rows))
    print('%-8s %-8s %-6s %s' % ('role', 'shape', 'train', 'count'))
    for k in sorted(c):
        print('%-8s %-8s %-6s %d' % (k[0], k[1], k[2], c[k]))
    print()
    print('main return types (run+error):')
    for k, v in Counter(r['ret_type'] for r in rows if r['has_main']).most_common():
        print('  %-20s %d' % (k, v))
    print('main body forms:', dict(Counter(r['body'] for r in rows if r['has_main'])))
    print('.wait_for_exit markers:', sum(r['marker'] for r in rows))
    print('impl ... for Supervisor in a main unit:', sum(r['impl_sup'] for r in rows if r['has_main']))
    print('name collisions:', dict(Counter(r['collisions'] for r in rows if r['collisions'])))


if __name__ == '__main__':
    main()
