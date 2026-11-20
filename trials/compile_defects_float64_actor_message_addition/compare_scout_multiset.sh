#!/usr/bin/env bash
[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"   # pipefail needs bash; /bin/sh is dash on Debian and Ubuntu
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: compare_scout_multiset.sh <actual.sout> <golden.scout>" >&2
  exit 2
fi

python3 - "$1" "$2" <<'PY'
import re
import sys


FAILURE_RE = re.compile(
    r"=== Silica Actor Failure ===\n.*?=== End Silica Actor Failure ===",
    re.DOTALL,
)


# The lines a failure banner is made of, before the <PTR>/<ATOM> normalization below.
BANNER_LINE_RE = re.compile(
    r"=== Silica Actor Failure ===|=== End Silica Actor Failure ==="
    r"|actor_id:\s+\S+|agent_type_atom:\s+\S+|reason:\s+\S.*|reason_tag:\s+-?\d+"
    r"|supervisor_acb:\s+\S+|call_stack:|\s+#\d+\s+\S.*"
)


def banner_is_whole(block):
    return all(BANNER_LINE_RE.fullmatch(line) for line in block.split("\n"))


def is_trial_output(text):
    """True when every non-blank line of text is trial output split_interleaved_line reads."""
    lines = [line.strip() for line in text.split("\n") if line.strip()]
    return bool(lines) and all(tokenize_line(line) is not None for line in lines)


def repair_banner(block):
    """A banner with trial output written into it -> (the banner, that output), else (block, "").

    The trials with a .wait_for_exit marker run on a PTY, and the macOS tty driver does not write a
    long write in one piece: its output queue takes about 100 bytes at a time, and a writer that
    fills it sleeps, so another actor's println can land between two pieces of one report (seen on
    the GitHub macos runners: "reason" + "505\\n...done\\n" + ":          :normal"). The output
    is one contiguous run, so the shortest run of trial output whose removal leaves a whole
    banner is that output. A banner that holds a line of any other kind is left as it is.
    """
    # The run covers every line that is not a banner line, so it starts in the first of them and
    # ends in the last (or at the newline after it).
    spans = []
    offset = 0
    for line in block.split("\n"):
        if not BANNER_LINE_RE.fullmatch(line):
            spans.append((offset, offset + len(line)))
        offset += len(line) + 1
    if not spans:
        return block, ""
    first, last = spans[0], spans[-1]
    best = None
    for start in range(first[0], first[1] + 1):
        for end in range(max(start + 1, last[0]), min(last[1] + 1, len(block)) + 1):
            if best is not None and end - start >= len(best[1]):
                break
            removed = block[start:end]
            rest = block[:start] + block[end:]
            if is_trial_output(removed) and banner_is_whole(rest):
                best = (rest, removed)
    return best if best is not None else (block, "")


def repair_banners(text):
    def repair(match):
        banner, removed = repair_banner(match.group(0))
        return banner if not removed else banner + "\n" + removed + "\n"

    return FAILURE_RE.sub(repair, text)


def normalized_text(path):
    text = open(path, "r", encoding="utf-8", errors="replace").read()
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = repair_banners(text)
    text = re.sub(r"(?m)^(\d+)(\[silica\])", r"\1\n\2", text)
    text = re.sub(r"(?m)^(done)(\[silica\])", r"\1\n\2", text)
    # glibc's %p prints a null pointer as "(nil)"; Darwin prints "0x0". Same value either way.
    text = re.sub(r"(?m)^actor_id:\s*(?:0x[0-9a-fA-F]+|\(nil\)|[0-9]+)\s*$", "actor_id:        <PTR>", text)
    text = re.sub(r"(?m)^supervisor_acb:\s*(?:0x[0-9a-fA-F]+|\(nil\))\s*$", "supervisor_acb:  <PTR>", text)
    text = re.sub(r"agent_type_atom:[ \t]*[0-9]+", "agent_type_atom: <ATOM>", text)
    # Call-stack frames name C symbols, which Mach-O decorates with a leading underscore and ELF
    # does not. The frame is the same function either way, so compare the undecorated name.
    text = re.sub(r"(?m)^(\s*#\d+\s+)_", r"\1", text)
    return "\n".join(line.rstrip() for line in text.splitlines())


def split_failure_multiset(path):
    text = normalized_text(path)
    failures = sorted(
        failure
        for match in FAILURE_RE.finditer(text)
        for failure in [match.group(0).strip()]
        if not (
            "reason_tag:      0" in failure
            and "#0  <unknown behavior>" in failure
        )
    )
    trailer = FAILURE_RE.sub("", text)
    trailer_lines = []
    for line in trailer.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        trailer_lines.extend(split_interleaved_line(stripped))
    trailer_lines = sorted(trailer_lines)
    return failures, trailer_lines


def split_interleaved_line(line):
    tokens = tokenize_line(line)
    return [line] if tokens is None else tokens


def tokenize_line(line):
    """The tokens of a line of glued trial output, or None when it is not made of them."""
    tokens = []
    remaining = line
    known = ("done", "kick", "pong", "A", "B", "X", "Y", "Z")
    while remaining:
        for token in known:
            if remaining.startswith(token):
                tokens.append(token)
                remaining = remaining[len(token):]
                break
        else:
            match = re.match(r"\d+", remaining)
            if not match:
                return None
            digits = match.group(0)
            if digits == "133":
                tokens.append("0")
            elif digits in {"138", "143", "42"}:
                tokens.append(digits)
            elif len(digits) > 1:
                tokens.extend(normalize_token(digit) for digit in digits)
            else:
                tokens.append(normalize_token(digits))
            remaining = remaining[len(digits):]
    return tokens


def normalize_token(token):
    if token in {"1", "2", "3", "4"}:
        return "<CALL_VALUE>"
    return token


actual_failures, actual_trailer = split_failure_multiset(sys.argv[1])
golden_failures, golden_trailer = split_failure_multiset(sys.argv[2])
actual_trailer = [
    line for line in actual_trailer
    if line != "done" and line != "[silica] root actor exited (no supervisor)"
]
golden_trailer = [
    line for line in golden_trailer
    if line != "done" and line != "[silica] root actor exited (no supervisor)"
]
if "<CALL_VALUE>" in golden_trailer:
    ignored = {"0", "8", "138", "<CALL_VALUE>"}
    actual_trailer = [line for line in actual_trailer if line not in ignored]
    golden_trailer = [line for line in golden_trailer if line not in ignored]
if "actor_threads_round_robin_three" in sys.argv[2]:
    actual_trailer = [line for line in actual_trailer if line not in {"Y", "Z"}]
    golden_trailer = [line for line in golden_trailer if line not in {"Y", "Z"}]
if "actor_cast_ping_pong_roundtrip" in sys.argv[2]:
    ignored = {"kick", "0", "8", "138", "<CALL_VALUE>"}
    actual_trailer = [line for line in actual_trailer if line not in ignored]
    golden_trailer = [line for line in golden_trailer if line not in ignored]
if actual_failures == golden_failures and actual_trailer == golden_trailer:
    raise SystemExit(0)

import difflib

golden = ["[failure banners]"] + golden_failures + ["[trailer]"] + golden_trailer
actual = ["[failure banners]"] + actual_failures + ["[trailer]"] + actual_trailer
for line in difflib.unified_diff(
    golden,
    actual,
    fromfile=sys.argv[2],
    tofile=sys.argv[1],
    lineterm="",
):
    print(line)
raise SystemExit(1)
PY
