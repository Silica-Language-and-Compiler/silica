#!/bin/sh
# Usage: ./run.sh [process_count] [--send]   (default 1,000,000)
set -e
cd "$(dirname "$0")"
# Args: [process_count] [--send], in any order.
N=1000000
for a in "$@"; do
  case "$a" in --*) ;; *) N="$a" ;; esac
done
erlc spawn_bench.erl
# +P raises the VM's max process limit (default is only 262,144).
erl +P $((N * 2)) -noshell -s spawn_bench main -s init stop -extra "$@"
