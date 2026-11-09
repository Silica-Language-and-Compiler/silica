#!/bin/sh
# Copyright 2026 Lee Scott Barney
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Compare a board run with an app's expected.scout the way the trial harness compares a .sout with its
# .scout: byte for byte except the process-fatal report lines of spec §15.4.5.5, whose addresses (and,
# on the host, the symbol and actor fields) differ between runs and targets. Both files go through
# trials/normalize_fatal_reports.awk, which folds such a line to "[silica] fault at <PTR>" or
# "[silica] abort: <reason> at <PTR>", and are then compared with diff. Exit status: diff's.
#
#   compare_sout.sh <board.sout> <apps/silica_NN_name/expected.scout>
#
# (run_on_board.py prints the .sout form: redirect its standard output to a file first.)

set -eu
if [ "$#" -ne 2 ]; then
    echo "usage: $0 <actual.sout> <expected.scout>" >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
normalizer=$(cd "$here/../../../../../.." && pwd)/trials/normalize_fatal_reports.awk
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
awk -f "$normalizer" "$1" > "$tmp/actual"
awk -f "$normalizer" "$2" > "$tmp/expected"
diff "$tmp/actual" "$tmp/expected"
