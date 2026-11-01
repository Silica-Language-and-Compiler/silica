#!/usr/bin/env python3
"""Insert `, world` before the closing `)` of each call to check_expr(...) in type_checker_expressions.silica.
Skips the function signature line containing `fn check_expr(...)`."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
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
    line_snip = text[line_start : j + len(needle)]
    # Skip the exported function definition header (single line)
    if "fn check_expr(" in line_snip:
        out.append(text[i : j + len(needle)])
        # copy rest of line through first `)` at depth 0 from j - actually signature may have `proc[DeviceIO]` after )
        # copy until past `->` and `{` or just to end of line - simpler: copy line by line
        nl = text.find("\n", j)
        if nl < 0:
            out.append(text[j + len(needle) :])
            break
        out.append(text[j + len(needle) : nl + 1])
        i = nl + 1
        continue
    out.append(text[i:j])
    # parse balanced parens for call
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
                args = text[start:k]
                if args.rstrip().endswith("world") or ", world" in args:
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

path.write_text("".join(out))
print("done", path)
