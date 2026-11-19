#!/bin/bash
# Install one compiler artifact from a Compiler workflow run.
# Host targets replace binaries/silica-compiler. ESP32-S3_raw replaces
# binaries/silica-compiler-ESP32-S3_raw and leaves the host link alone.

set -euo pipefail

run_id="${1:?compiler run id}"
target="${2:?emit target}"
dest="${RUNNER_TEMP:?}/compiler-artifact"
rm -rf "$dest"
mkdir -p "$dest"
gh run download "$run_id" --name "$target" --dir "$dest"

files=()
while IFS= read -r file; do
    files+=("$file")
done < <(find "$dest" -type f)
if [ "${#files[@]}" -ne 1 ]; then
    echo "artifact ${target} from run ${run_id} should be one compiler file, found ${#files[@]}" >&2
    find "$dest" -print >&2
    exit 1
fi

name=$(basename "${files[0]}")
mkdir -p binaries
cp -p "${files[0]}" "binaries/${name}"
chmod +x "binaries/${name}"
case "$target" in
    ESP32-S3_raw) link="silica-compiler-ESP32-S3_raw" ;;
    *) link="silica-compiler" ;;
esac
ln -sfn "$name" "binaries/${link}"
echo "installed binaries/${link} -> ${name}"
