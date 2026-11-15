#!/usr/bin/env python3
"""Turns a Silica module whose state is one large record into a template and back.

Silica has no record update and no type alias, so a module whose actor state is a record of twenty
fields repeats the record's type in every signature and writes all twenty fields wherever one changes.
Such a module is kept here as a TEMPLATE in which

    @@ST@@                         stands for the record's type
    @@S(base){f=>v;;g=>w}@@        stands for a record literal: every field is `base.<field>` except
                                   those listed (base empty: every field is listed)

and the fields are named once, on the template's first line: `@@FIELDS name: type, name: type, ...@@`.

    record_template.py expand   TEMPLATE  MODULE.silica     write the module from its template
    record_template.py template MODULE.silica TEMPLATE FIELDS
                                                             make a template from a module; FIELDS is the
                                                             record's type text, `{ a: T, b: U }`
    record_template.py check    TEMPLATE  MODULE.silica     exit 1 unless the template expands to the module

Edit the template, expand it, and commit both."""
import re, sys

def fields_of(type_text):
    inner = type_text.strip()[1:-1].strip()
    out, depth, cur = [], 0, ""
    for ch in inner:
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip()); cur = ""
        else:
            cur += ch
    out.append(cur.strip())
    return [tuple(x.strip() for x in f.split(":", 1)) for f in out]

def expand(text):
    first, rest = text.split("\n", 1)
    m = re.fullmatch(r"@@FIELDS (.*)@@", first)
    if not m:
        sys.exit("record_template: the first line must be @@FIELDS ...@@")
    fields = fields_of("{ " + m.group(1) + " }")
    st = "{ " + ", ".join("%s: %s" % f for f in fields) + " }"
    def lit(mm):
        base, body = mm.group(1), mm.group(2)
        given = dict(kv.split("=>", 1) for kv in body.split(";;")) if body else {}
        return "{ " + ", ".join("%s: %s" % (n, given[n] if n in given else "%s.%s" % (base, n)) for n, _ in fields) + " }"
    rest = re.sub(r"@@S\(([A-Za-z0-9_]*)\)\{(.*?)\}@@", lit, rest, flags=re.S)
    return rest.replace("@@ST@@", st)

def literal_at(text, i, names):
    """A record literal of exactly these fields starting at text[i] ('{'); (values, end) or None."""
    pos = i + 1
    values = []
    for k, name in enumerate(names):
        head = " %s: " % name
        if not text.startswith(head, pos):
            return None
        pos += len(head)
        stop = (", %s: " % names[k + 1]) if k + 1 < len(names) else " }"
        depth, start = 0, pos
        while pos < len(text):
            if depth == 0 and text.startswith(stop, pos):
                break
            ch = text[pos]
            if ch in "({[":
                depth += 1
            elif ch in ")}]":
                if depth == 0:
                    return None
                depth -= 1
            pos += 1
        else:
            return None
        values.append(text[start:pos])
        pos += 1 if k + 1 < len(names) else 2
    return values, pos

def template(text, type_text):
    fields = fields_of(type_text)
    names = [n for n, _ in fields]
    st = "{ " + ", ".join("%s: %s" % f for f in fields) + " }"
    text = text.replace(st, "@@ST@@")
    out, i = "", 0
    while i < len(text):
        if text[i] == "{":
            got = literal_at(text, i, names)
            if got:
                values, end = got
                bases = {}
                for n, v in zip(names, values):
                    mm = re.fullmatch(r"([A-Za-z0-9_]+)\.%s" % re.escape(n), v)
                    if mm:
                        bases[mm.group(1)] = bases.get(mm.group(1), 0) + 1
                base = max(bases, key=bases.get) if bases else ""
                given = [(n, v) for n, v in zip(names, values) if not base or v != "%s.%s" % (base, n)]
                out += "@@S(%s){%s}@@" % (base, ";;".join("%s=>%s" % g for g in given))
                i = end
                continue
        out += text[i]
        i += 1
    return "@@FIELDS %s@@\n" % ", ".join("%s: %s" % f for f in fields) + out

if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    mode = sys.argv[1]
    if mode == "expand":
        open(sys.argv[3], "w").write(expand(open(sys.argv[2]).read()))
    elif mode == "check":
        sys.exit(0 if expand(open(sys.argv[2]).read()) == open(sys.argv[3]).read() else "record_template: %s does not expand to %s" % (sys.argv[2], sys.argv[3]))
    elif mode == "template":
        open(sys.argv[3], "w").write(template(open(sys.argv[2]).read(), sys.argv[4]))
    else:
        sys.exit(__doc__)
