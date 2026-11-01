#!/usr/bin/env bash
set -euo pipefail

root="${1:-.}"
# Build outputs live in ../build/<emit target>/ (src/Makefile), not beside the sources.
build="${2:-$root/../build}"

with_sam=0
without_sam=0

while IFS= read -r -d '' silica_file; do
  base="$(basename "$silica_file" .silica)"

  if find "$build" -type f -name "$base.sams" -print -quit | grep -q .; then
    ((++with_sam))
  else
    ((++without_sam))
  fi
done < <(find "$root" -type f -name '*.silica' -print0)

echo "Silica files with corresponding .sams:    $with_sam"
echo "Silica files without corresponding .sams: $without_sam"
