#!/usr/bin/env python3
"""Add `, world: ListNamedProgram` to fn signatures whose bodies contain `, world)` from check_expr calls."""
from pathlib import Path
import re
import sys

def main():
    path = Path(sys.argv[1])
    lines = path.read_text().splitlines(keepends=True)
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.match(r"^fn \w+\(", line):
            # collect function until next `fn ` at start or EOF
            block = [line]
            j = i + 1
            while j < len(lines) and not re.match(r"^fn \w+\(", lines[j]):
                block.append(lines[j])
                j += 1
            body = "".join(block)
            needs = "check_expr(" in body and ", world)" in body and "world: ListNamedProgram" not in block[0]
            if needs:
                # insert before ) -> or ) proc[ on first line of fn (signature may span lines - assume single line for params)
                first = block[0]
                if "world: ListNamedProgram" in first:
                    out.extend(block)
                else:
                    # multi-line signature: rare - only first line
                    m = re.search(r"\)(\s*->|\s*proc\[)", first)
                    if m:
                        idx = m.start()
                        new_first = first[:idx] + ", world: ListNamedProgram" + first[idx:]
                        block[0] = new_first
                    out.extend(block)
            else:
                out.extend(block)
            i = j
        else:
            out.append(line)
            i += 1
    path.write_text("".join(out))
    print("done", path)

if __name__ == "__main__":
    main()
