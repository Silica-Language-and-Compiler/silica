#!/usr/bin/env bash
# Build (or refresh) a scratch mirror of the trials tree in which suites can be run with their own
# Makefiles without touching trials/ or its integrate lock.
#
#   mirror.sh <work_dir> <suite> [<suite> ...]
#
# Layout: <work_dir>/{binaries,compiler,project_makefiles,docs} -> the real tree (symlinks);
#         <work_dir>/trials/<shared scaffolding> copied; <work_dir>/trials/<suite> copied (sources,
#         goldens, Makefiles, helper scripts; never build artefacts).
# A suite already in the mirror is replaced.
set -euo pipefail
W="$1"; shift
ROOT="${SILICA_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
mkdir -p "$W/trials"
for d in binaries compiler project_makefiles docs; do
  [ -e "$W/$d" ] || ln -s "$ROOT/$d" "$W/$d"
done
for f in "$ROOT"/trials/*; do
  b=$(basename "$f")
  [ -f "$f" ] && cp -p "$f" "$W/trials/$b"
done
for d in platform targets lib_trial_support; do
  rm -rf "$W/trials/$d"; cp -Rp "$ROOT/trials/$d" "$W/trials/$d"
done
for suite in "$@"; do
  dst="$W/trials/$suite"
  rm -rf "$dst"; mkdir -p "$dst"
  (cd "$ROOT/trials/$suite" && find . \( \( -name .target -o -name .trial_stdlib \) -prune \) -o \( -type f -o -type l \) \
     ! -name '*.sams' ! -name '*.o' ! -name '*.iface' ! -name '*.sout' ! -name '*.cur_fail' \
     ! -name 'silica.config' ! -name 'silica.atoms' ! -name 'silica.shapes' ! -name '.integrate_*' \
     -print0) | while IFS= read -r -d '' f; do
       src="$ROOT/trials/$suite/$f"
       # skip linked executables (no extension, executable bit, Mach-O/ELF)
       if [ -f "$src" ] && [ -x "$src" ] && [ "${f##*/}" = "${f##*/}" ] && ! [[ "${f##*/}" == *.* ]]; then
         if head -c 4 "$src" | LC_ALL=C grep -q $'\xcf\xfa\xed\xfe\|\x7fELF' 2>/dev/null; then continue; fi
       fi
       mkdir -p "$dst/$(dirname "$f")"
       cp -P "$src" "$dst/$f"
     done
done
