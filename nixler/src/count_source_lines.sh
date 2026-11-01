#!/usr/bin/env bash
set -euo pipefail

root="${1:-.}"
total=0

while IFS= read -r -d '' file; do
    count="$(
        awk '
{
    cleaned = ""

    for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        nextc = substr($0, i + 1, 1)

        if (in_block) {
            if (c == "-" && nextc == "}") {
                in_block = 0
                i++
            }
            continue
        }

        if (c == "/" && nextc == "/") {
            break
        }

        if (c == "{" && nextc == "-") {
            in_block = 1
            i++
            continue
        }

        cleaned = cleaned c
    }

    if (cleaned ~ /[^[:space:]]/) {
        total++
    }
}

END {
    printf "%d\n", total
}
' "$file"
    )"
    total=$((total + count))
done < <(find "$root" -type f -name '*.silica' -print0)

printf "%d\n" "$total"
