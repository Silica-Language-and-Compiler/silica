#!/usr/bin/env bash
[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"   # pipefail needs bash; /bin/sh is dash on Debian and Ubuntu
set -euo pipefail

# Order-free golden comparison for trials whose output holds actor failure reports
# (Lee, 2026-10-12): a failure report is printed asynchronously by the registered FailureReporter
# actor, so where a report banner lands among the program's other lines, and against the runtime's
# synchronous "[silica] root actor exited (no supervisor)" note, is not defined.
#
#   compare_scout_unordered.sh <actual.sout> <golden.scout>
#
# Reached through a suite's compare_scout_multiset.sh (marker <stem>.scout.multiset) or
# ffi_addition/compare_scout_sorted.sh (marker <stem>.scout.sorted); used by the suite Makefiles and by
# trials/targets/board_suite.sh. The golden is never rewritten. Both files are read the same way:
#   - carriage returns dropped; run- and target-dependent fields folded: actor_id, supervisor_acb and
#     epc pointers (0x.., (nil)) -> <PTR>, agent_type_atom -> <ATOM>, the Mach-O leading underscore of
#     call-stack frames, and the process-fatal report lines (../normalize_fatal_reports.awk);
#   - each "=== Silica Actor Failure ===" ... "=== End Silica Actor Failure ===" block is one item: the
#     reporter is one actor and writes each report with one write, so a report never interleaves with
#     another report or other output; the blocks are compared as a multiset;
#   - the root-exit note is split from any output it was glued to (stdout and stderr share the capture);
#   - blank lines are ignored (println_stderr(report) adds one), and whitespace runs count as one space;
#   - the last remaining line is the exit status the harness appends: it is compared exactly, and must
#     be the last line of both;
#   - every other line is compared as a multiset: the same lines, as many times each, in any order.

if [ "$#" -ne 2 ]; then
  echo "usage: compare_scout_unordered.sh <actual.sout> <golden.scout>" >&2
  exit 2
fi

AWK_FOLD="$(cd "$(dirname "$0")" && pwd)/normalize_fatal_reports.awk"

python3 - "$1" "$2" "$AWK_FOLD" <<'PY'
import collections
import difflib
import re
import subprocess
import sys

FAILURE_RE = re.compile(
    r"=== Silica Actor Failure ===\n.*?=== End Silica Actor Failure ===",
    re.DOTALL,
)
ROOT_EXIT = "[silica] root actor exited (no supervisor)"
AWK_FOLD = sys.argv[3]


def folded_text(path):
    raw = open(path, "r", encoding="utf-8", errors="replace").read()
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    text = subprocess.run(
        ["awk", "-f", AWK_FOLD], input=raw, capture_output=True, text=True, check=True
    ).stdout
    ptr = r"(?:0x[0-9a-fA-F]+|\(nil\)|<PTR>)"
    # actor_id prints the actor's 64-bit identity in decimal (spec §15.1.4); older runtimes printed
    # the control block's address. Either way it is run-dependent, so it folds like a pointer.
    aid = r"(?:0x[0-9a-fA-F]+|\(nil\)|<PTR>|[0-9]+)"
    text = re.sub(r"(?m)^[ \t]*actor_id:[ \t]*" + aid + r"[ \t]*$", "actor_id:        <PTR>", text)
    text = re.sub(r"(?m)^[ \t]*supervisor_acb:[ \t]*" + ptr + r"[ \t]*$", "supervisor_acb:  <PTR>", text)
    text = re.sub(r"(?m)^[ \t]*epc:[ \t]*" + ptr + r"[ \t]*$", "epc:             <PTR>", text)
    text = re.sub(r"agent_type_atom:[ \t]*[0-9]+", "agent_type_atom: <ATOM>", text)
    # Call-stack frames name C symbols, which Mach-O decorates with a leading underscore and ELF
    # does not. The frame is the same function either way, so compare the undecorated name.
    text = re.sub(r"(?m)^([ \t]*#\d+[ \t]+)_", r"\1", text)
    return text


def squeeze(line):
    return re.sub(r"\s+", " ", line).strip()


def read_items(path):
    text = folded_text(path)
    reports = sorted(
        "\n".join(squeeze(l) for l in m.group(0).splitlines() if l.strip())
        for m in FAILURE_RE.finditer(text)
    )
    rest = FAILURE_RE.sub("\n", text)
    lines = []
    for raw in rest.splitlines():
        parts = raw.split(ROOT_EXIT)
        for i, part in enumerate(parts):
            if i > 0:
                lines.append(ROOT_EXIT)
            part = squeeze(part)
            if part:
                lines.append(part)
    status = lines.pop() if lines else "<no exit status line>"
    return reports, status, lines


a_reports, a_status, a_lines = read_items(sys.argv[1])
g_reports, g_status, g_lines = read_items(sys.argv[2])

ok = True
if a_status != g_status:
    ok = False
    print(f"exit status (last line): golden {g_status!r}, actual {a_status!r}")
if a_reports != g_reports:
    ok = False
    print("failure reports differ (compared as a multiset):")
    for line in difflib.unified_diff(
        "\n---\n".join(g_reports).splitlines(),
        "\n---\n".join(a_reports).splitlines(),
        fromfile=sys.argv[2],
        tofile=sys.argv[1],
        lineterm="",
    ):
        print(line)
if collections.Counter(a_lines) != collections.Counter(g_lines):
    ok = False
    print("other lines differ (compared as a multiset, shown sorted):")
    for line in difflib.unified_diff(
        sorted(g_lines), sorted(a_lines), fromfile=sys.argv[2], tofile=sys.argv[1], lineterm=""
    ):
        print(line)
raise SystemExit(0 if ok else 1)
PY
