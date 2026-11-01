#!/usr/bin/env bash
set -euo pipefail

root="${1:-.}"
# Build outputs live in ../build/<emit target>/ (src/Makefile), not beside the sources.
build="${2:-$root/../build}"

with_iface=0
without_iface=0

while IFS= read -r -d '' silica_file; do
  base="$(basename "$silica_file" .silica)"

  if find "$build" -type f -name "$base.iface" -print -quit | grep -q .; then
    ((with_iface++))
  else
    ((without_iface++))
  fi
done < <(find "$root" -type f -name '*.silica' -print0)

echo "Silica files with corresponding .iface:    $with_iface"
echo "Silica files without corresponding .iface: $without_iface"
