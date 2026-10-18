#!/usr/bin/env bash
# Refresh .ascomp goldens for a suite whose harness does not run a trial once its assembly differs
# from the golden (ffi_addition's app Makefiles stop before linking): in a scratch mirror, run the
# suite, adopt every .sams as .ascomp there, run again, and copy back into trials/ only the .sams of
# trials whose run then matched .scout (Lee's rule) -- via refresh_ascomp.py on the mirror's logs.
#
#   refresh_via_mirror.sh <suite> [--ext .ascomp]
# Env: SILICA_COMPILER, MASS_WORK.
set -uo pipefail
S="$1"; shift
EXT=.ascomp
[ "${1:-}" = "--ext" ] && EXT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
C="${SILICA_COMPILER:?}"; W="${MASS_WORK:?}"
M="$W/refresh_mirror_${S//\//_}"
rm -rf "$M"
bash "$HERE/mirror.sh" "$M" "$S"
# MIRROR_DROP: space-separated trial stems to leave out of the mirror (a pre-existing compile error
# in one unit stops the whole suite's batch compile)
for x in ${MIRROR_DROP:-}; do rm -f "$M/trials/$S/$x.silica"; done
(cd "$M/trials/$S" && make integrate TRIAL_TARGET=host SILICA_COMPILER="$C" SILICA_TARGET_PROMPT=0 > "$M/run1.log" 2>&1)
find "$M/trials/$S" -name '*.sams' ! -name '__silica_runtime.sams' ! -path '*/.trial_stdlib/*' | while read -r s; do
  b="${s%.sams}"; [ -f "$b$EXT" ] && cp "$s" "$b$EXT"
done
(cd "$M/trials/$S" && make integrate TRIAL_TARGET=host SILICA_COMPILER="$C" SILICA_TARGET_PROMPT=0 > "$M/run2.log" 2>&1)
echo "mirror run2: $(cat "$M/trials/$S/.integrate_counts" 2>/dev/null)"
# trials whose run matched: copy the mirror's .sams (same compiler, same sources) over the tree's golden
python3 - "$M/trials/$S" "$ROOT/trials/$S" "$EXT" <<'EOF'
import os, re, shutil, sys
m, t, ext = sys.argv[1:4]
ok = set()
for d, dn, fn in os.walk(m):
    if '.integrate_log' in fn:
        for ln in open(os.path.join(d, '.integrate_log'), errors='replace'):
            mo = re.search(r'✅✅ (\S+) output (?:multiset-)?matches \.scout', ln)
            if mo:
                ok.add(mo.group(1))
n = 0
for d, dn, fn in os.walk(m):
    dn[:] = [x for x in dn if x != '.trial_stdlib']
    for f in fn:
        if not f.endswith('.sams') or f == '__silica_runtime.sams':
            continue
        rel = os.path.relpath(os.path.join(d, f), m)
        stem = rel[:-5]
        if not any(k.endswith(os.path.basename(stem)) for k in ok):
            continue
        gold = os.path.join(t, stem + ext)
        if os.path.exists(gold) and open(gold, 'rb').read() != open(os.path.join(d, f), 'rb').read():
            shutil.copyfile(os.path.join(d, f), gold)
            print('refreshed', rel)
            n += 1
print('refreshed %d' % n)
EOF
