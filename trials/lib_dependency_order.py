#!/usr/bin/env python3
# Print the .silica files of a trial's lib/ directory in dependency order: a file is printed
# after every lib file it names in a `use` line. Ties keep the alphabetical order of the
# previous `find | sort` list, so a lib with no lib-to-lib `use` lines prints exactly as before.
#
#   lib_dependency_order.py <lib-dir>
#
# A cycle is reported on stderr and the remaining files are printed alphabetically.
import os, re, sys

lib = sys.argv[1]
files = sorted(os.path.join(lib, f) for f in os.listdir(lib) if f.endswith('.silica'))
mod_of = {os.path.basename(f)[:-len('.silica')]: f for f in files}
# Same `use` reading as compiler/src/topo_silica_config.sh: optional indent, comma-separated names.
use_re = re.compile(r'^[ \t]*use[ \t]+([^;\n]*);', re.M)

deps = {}
for f in files:
    with open(os.path.realpath(f), encoding='utf-8', errors='replace') as fh:
        text = fh.read()
    names = [m.strip() for line in use_re.findall(text) for m in line.split(',')]
    deps[f] = {mod_of[m] for m in names if m in mod_of and mod_of[m] != f}

done, order = set(), []
pending = list(files)
while pending:
    ready = [f for f in pending if deps[f] <= done]
    if not ready:
        sys.stderr.write('lib_dependency_order: cycle among %s; printing the rest alphabetically\n'
                         % ', '.join(os.path.basename(f) for f in pending))
        ready = pending[:1]
    f = ready[0]
    order.append(f); done.add(f); pending.remove(f)
for f in order:
    print(f)
