#!/usr/bin/env python3
"""Remove seed mis-emission around tuple (pair) returns in lexer assembly.

Safe patterns only — do not strip legitimate stack-pair heapification
(`MOV X0, SP` then SUB/STR/alloc), which shares a suffix with re-box.
"""
from __future__ import annotations

import pathlib
import re
import sys

LEXER_DIR = pathlib.Path(__file__).resolve().parent

REBOX_BODY = (
    r"    SUB SP, SP, #16\n"
    r"    STR X0, \[SP, #8\]\n"
    r"    MOV X0, #16\n"
    r"    BL _silica_rt_region_alloc\n"
    r"    MOV X4, X0\n"
    r"    LDR X1, \[SP, #8\]\n"
    r"    LDR X3, \[X1, #0\]\n"
    r"    STR X3, \[X4, #0\]\n"
    r"    LDR X3, \[X1, #8\]\n"
    r"    STR X3, \[X4, #8\]\n"
    r"    MOV X0, X4\n"
    r"    ADD SP, SP, #16\n"
    r"    ADD SP, SP, #16\n"
)

# Re-box at case_done (X0 already a heap pair).
REBOX_AT_CASE_DONE = re.compile(
    r"(L_case_\w+_done:\n)"
    r"\n"
    + REBOX_BODY
)

# Re-box immediately after indirect call through X9 (pair already in X0).
REBOX_AFTER_BLR = re.compile(
    r"(    BLR X9\n)"
    r"\n"
    + REBOX_BODY
)

SRET_LEAK = re.compile(
    r"    SUB SP, SP, #16\n"
    r"    MOV X8, SP\n"
)

# After sret SUB stripped, leftover ADD after a balanced pair heapify (ADD ADD).
ORPHAN_AFTER_PAIR = re.compile(
    r"(    ADD SP, SP, #16\n"
    r"    ADD SP, SP, #16\n)"
    r"\n"
    r"    ADD SP, SP, #16\n"
    r"\n"
    r"(    LDP X\d+, X\d+, \[SP\], #16\n)"
)


def main() -> int:
    total_rebox = 0
    total_sret = 0
    total_orphan = 0
    for path in sorted(LEXER_DIR.glob("*.sams")):
        text = path.read_text()
        new, n1 = REBOX_AT_CASE_DONE.subn(r"\1\n", text)
        new, n2 = REBOX_AFTER_BLR.subn(r"\1\n", new)
        new, n_sret = SRET_LEAK.subn("", new)
        new, n_orphan = ORPHAN_AFTER_PAIR.subn(r"\1\n\2", new)
        n_rebox = n1 + n2
        if n_rebox or n_sret or n_orphan:
            path.write_text(new)
            total_rebox += n_rebox
            total_sret += n_sret
            total_orphan += n_orphan
            parts = []
            if n_rebox:
                parts.append(f"{n_rebox} re-box(es)")
            if n_sret:
                parts.append(f"{n_sret} X8 sret leak(s)")
            if n_orphan:
                parts.append(f"{n_orphan} orphan ADD(s)")
            print(f"fixed: {path.name} ({', '.join(parts)})")
    if total_rebox == total_sret == total_orphan == 0:
        print("ok: no pair re-boxes / sret leaks / orphan ADDs under lexer/")
    else:
        print(
            f"fixed: {total_rebox} re-box(es), {total_sret} sret leak(s), "
            f"{total_orphan} orphan ADD(s) total"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
