#!/usr/bin/env python3
"""Fix seed mis-emission of (Token, Lexer) tuple_proj second-element offset.

Seed computes the second field offset as sizeof(Token)==48 for record-typed
tuple heads, but construction stores two heap pointers at #0 and #8. Rewrite
destructure loads `#48` → `#8` in lexer assembly. Safe to re-run (idempotent).
"""
from __future__ import annotations

import pathlib
import re
import sys

LEXER_DIR = pathlib.Path(__file__).resolve().parent
LOAD48 = re.compile(r"LDR (X\d+), \[(X\d+), #48\]")


def fix_file(path: pathlib.Path) -> tuple[int, str]:
    text = path.read_text()
    new, n = LOAD48.subn(r"LDR \1, [\2, #8]", text)
    if n:
        path.write_text(new)
        return n, f"fixed: {path.name} ({n} site(s) #48 -> #8)"
    if "LDR " in text and "#8]" in text:
        return 0, f"ok: {path.name} (no #48 loads)"
    return 0, f"ok: {path.name} (no tuple_proj loads)"


def main() -> int:
    paths = sorted(LEXER_DIR.glob("*.sams"))
    if not paths:
        print(f"skip: no .sams in {LEXER_DIR}", file=sys.stderr)
        return 0
    total = 0
    for path in paths:
        n, msg = fix_file(path)
        total += n
        if n or path.name == "lexer_runner.sams":
            print(msg)
    if total == 0:
        print(f"ok: no #48 loads remaining under {LEXER_DIR.name}/")
    else:
        print(f"fixed: {total} load(s) total")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
