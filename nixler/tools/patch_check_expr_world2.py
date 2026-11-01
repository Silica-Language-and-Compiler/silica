#!/usr/bin/env python3
"""Append `, world` before the closing `)` of each check_expr(...) call."""
from pathlib import Path
import re
import sys

def patch_calls(text: str) -> str:
    needle = "check_expr("
    out = []
    i = 0
    n = len(text)
    while i < n:
        j = text.find(needle, i)
        if j < 0:
            out.append(text[i:])
            break
        line_start = text.rfind("\n", 0, j) + 1
        head = text[line_start : j + len(needle)]
        # Skip function signature: `fn check_expr(...`
        if re.search(r"\bfn\s+check_expr\s*\(", head):
            out.append(text[i : j + len(needle)])
            i = j + len(needle)
            continue
        out.append(text[i:j])
        k = j + len(needle)
        depth = 1
        start = k
        while k < n and depth > 0:
            c = text[k]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    inner = text[start:k].rstrip()
                    if inner.endswith("world") or ", world" in inner:
                        out.append(text[j : k + 1])
                    else:
                        out.append(text[j:k] + ", world)")
                    k += 1
                    i = k
                    break
            k += 1
        else:
            out.append(text[j:])
            break
    return "".join(out)

if __name__ == "__main__":
    p = Path(sys.argv[1])
    t = p.read_text()
    p.write_text(patch_calls(t))
    print("patched calls in", p)
