#!/usr/bin/env bash
# Size of a built compiler. Builds live in build/<emit target>/ (see src/Makefile); pass a path, or
# a target name, to pick one. With no argument the most recently linked one is measured.

cd "$(dirname "$0")" || exit 1
arg="${1:-}"
if [ -z "$arg" ]; then
    file=$(ls -t build/*/silica-compiler 2>/dev/null | head -1)
elif [ -f "$arg" ]; then
    file="$arg"
else
    file="build/$arg/silica-compiler"
fi
[ -f "$file" ] || { echo "no built compiler found (looked for build/*/silica-compiler)" >&2; exit 1; }

bytes=$(stat -f '%z' "$file" 2>/dev/null || stat -c '%s' "$file")
megabytes=$(awk -v b="$bytes" 'BEGIN { printf "%.2f MB", b / 1024 / 1024 }')

printf "%s %s\n" "$file" "$megabytes"
