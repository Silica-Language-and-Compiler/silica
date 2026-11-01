#!/usr/bin/env python3
"""Qualify calls to other modules' exported functions with `module@` (Silica cross-module call syntax).
usage: qualify.py <file> <module.silica>...   -- rewrites <file> in place."""
import re, sys, os
target = sys.argv[1]
exports = {}
for m in sys.argv[2:]:
    mod = os.path.basename(m)[:-len('.silica')]
    for name in re.findall(r'^export\s+([A-Za-z_][A-Za-z0-9_]*)/\d+;', open(m).read(), re.M):
        exports[name] = mod
src = open(target).read()
own = set(re.findall(r'^fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', src, re.M))
def fix(mt):
    name = mt.group(1)
    if name in exports and name not in own:
        return exports[name] + '@' + name + '('
    return mt.group(0)
new = re.sub(r'(?<![A-Za-z0-9_@])([A-Za-z_][A-Za-z0-9_]*)\(', fix, src)
# never touch `fn name(` definitions
open(target, 'w').write(new)
