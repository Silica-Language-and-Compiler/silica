"""Generators for string_addition, list_addition, tuples_addition, records_addition."""
import random
from common import *

WORDS = ["hello", "world", "silica", "actor", "region", "alpha", "beta", "gamma", "delta", "omega",
         "north", "south", "apple", "banana", "cherry", "table", "chair", "river", "stone", "cloud"]
UNI = ["café", "naïve", "世界", "αβγ", "🙂", "🎉", "über", "Zürich", "ñandú", "日本語"]


def s_lit(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def gen_all(rng, q):
    cases = []
    cases += gen_strings(rng, q(300))
    cases += gen_lists(rng, q(220))
    cases += gen_tuples(rng, q(260))
    cases += gen_records(rng, q(220))
    return cases


# ---------------------------------------------------------------------------
# strings
# ---------------------------------------------------------------------------

def gen_strings(rng, count):
    area = "string_addition"
    makers = [t_str_concat, t_str_length, t_str_substring, t_str_until, t_str_predicate, t_str_eq_case,
              t_str_helper, t_str_escape, t_str_concat, t_str_length]
    cases = []
    for i in range(count):
        c = makers[i % len(makers)](rng, area)
        if c:
            cases.append(c)
    return cases


def t_str_concat(rng, area):
    n = rng.randint(2, 4)
    parts = [rng.choice(WORDS + UNI) for _ in range(n)]
    fn = rng.choice(["concatenate", "concat"])
    kind = rng.choice(["nested", "series"])
    if kind == "nested":
        expr = s_lit(parts[0])
        for p in parts[1:]:
            expr = f"{fn}({expr}, {s_lit(p)})"
        stmts = [f"s: string <- {expr}"]
        names = ["s"]
    else:
        stmts = [f"a: string <- {s_lit(parts[0])}", f"b: string <- {s_lit(parts[1])}", f"s: string <- {fn}(a, b)"]
        prev = "s"
        for i, p in enumerate(parts[2:]):
            stmts.append(f"s{i}: string <- {fn}({prev}, {s_lit(p)})")
            prev = f"s{i}"
        names = ["a", "b", "s"]
    final = "s" if kind == "nested" or n == 2 else f"s{n - 3}"
    result = "".join(parts) + "\n"
    stmts += [f"print_string({final})", 'println("")']
    body = seq_block(["device_io"], stmts, ":ok", rng.randint(0, 2))
    hdr = f"// {fn} of {n} pieces prints {result}"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "concat", src, result, 2)
    c.info["names"] = names
    c.info["fnames"] = [fn, "print_string"]
    c.info["calls"] = [(fn, 2)]
    c.info["has_seq"] = True
    c.add_fail("E2001", f"integer literal passed to {fn}", rep(src, s_lit(parts[-1]), str(len(parts[-1])), 1))
    c.add_fail("E2003", "string binding used where an integer is expected",
               rep(src, f"print_string({final})", f"print_int64({final})", 1))
    return c


def t_str_length(rng, area):
    s = rng.choice(WORDS + UNI + ["", "a b c", "👨‍👩‍👧‍👦"])
    fn = rng.choice(["length_bytes", "length_chars"])
    val = len(s.encode()) if fn == "length_bytes" else len(s)
    kind = rng.choice(["exit", "print"])
    if kind == "exit":
        hdr = f"// {fn}({s_lit(s)}) = {val}"
        src = program(fn_decl("main", [], "int64", [], f"{fn}({s_lit(s)})"), header=hdr)
        c = Case(area, "length", src, "", val & 0xFF)
        c.info["fnames"] = [fn]
        return c
    stmts = [f"text: string <- {s_lit(s)}", f"result: atom <- print_int64({fn}(text))"]
    body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
    hdr = f"// {fn} of a bound string prints {val}"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "length", src, str(val), 0)
    c.info["names"] = ["text"]
    c.info["fnames"] = [fn, "print_int64"]
    c.info["has_seq"] = True
    c.add_fail("E2003", f"{fn} result printed with print_string", rep(src, f"print_int64({fn}(text))", f"print_string({fn}(text))", 1))
    return c


def t_str_substring(rng, area):
    s = rng.choice(WORDS + UNI + ["hello world", "abcdefgh"])
    n = len(s)
    a = rng.randint(0, n)
    b = rng.randint(a, n)
    val = s[a:b]
    kind = rng.choice(["literal", "var"])
    if kind == "literal":
        stmts = [f"s: string <- substring({s_lit(s)}, {a}, {b})"]
        names = ["s"]
    else:
        stmts = [f"text: string <- {s_lit(s)}", f"s: string <- substring(text, {a}, {b})"]
        names = ["text", "s"]
    stmts += ["print_string(s)", 'println("")']
    body = seq_block(["device_io"], stmts, ":ok", rng.randint(0, 2))
    hdr = f"// substring uses character indices [{a}, {b}) of {s_lit(s)}"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "substring", src, val + "\n", 2)
    c.info["names"] = names
    c.info["fnames"] = ["substring", "print_string"]
    c.info["calls"] = [("substring", 3)]
    c.info["has_seq"] = True
    c.add_fail("E2001", "string literal used as a substring index", rep(src, f", {a}, {b})", f', "{a}", {b})', 1))
    return c


def t_str_until(rng, area):
    words = [rng.choice(WORDS) for _ in range(rng.randint(2, 4))]
    sep = rng.choice([",", ";", "/", " ", "|"])
    s = sep.join(words)
    start = 0 if rng.random() < 0.6 else len(words[0]) + 1
    val = s[start:].split(sep, 1)[0]
    stmts = [f"s: string <- substring_until_char({s_lit(s)}, {start}, '{sep}')", "print_string(s)", 'println("")']
    body = seq_block(["device_io"], stmts, ":ok", rng.randint(0, 2))
    hdr = f"// substring_until_char from {start} up to '{sep}'"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "until", src, val + "\n", 2)
    c.info["names"] = ["s"]
    c.info["fnames"] = ["substring_until_char", "print_string"]
    c.info["calls"] = [("substring_until_char", 3)]
    c.info["has_seq"] = True
    c.add_fail("E2001", "string literal used where a char terminator is expected", rep(src, f"'{sep}')", f'"{sep}")', 1))
    return c


def t_str_predicate(rng, area):
    fn = rng.choice(["contains", "starts_with", "ends_with"])
    s = rng.choice(["hello world", "path/to/file.silica", "silica compiler", "abcdef", "北京市"])
    if fn == "contains":
        needle = rng.choice([s[1:3], "zzz", s[-2:], "", "lo w"])
        val = needle in s
    elif fn == "starts_with":
        needle = rng.choice([s[:2], "xx", s[:4], ""])
        val = s.startswith(needle)
    else:
        needle = rng.choice([s[-3:], "qq", s[-1:], ""])
        val = s.endswith(needle)
    kind = rng.choice(["print", "case"])
    if kind == "print":
        stmts = [f"s: string <- {s_lit(s)}", f"result: atom <- print_boolean({fn}(s, {s_lit(needle)}))"]
        body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
        hdr = f"// {fn} prints {str(val).lower()}"
        src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
        c = Case(area, "pred", src, "true" if val else "false", 0)
        c.info["has_seq"] = True
    else:
        t, f = rng.randint(0, 100), rng.randint(0, 100)
        lines = [f"s: string <- {s_lit(s)};", f"suf: string <- {s_lit(needle)};"]
        tail = f"case {fn}(s, suf) of {{\n        true -> {t};\n        false -> {f}\n    }}"
        hdr = f"// case on {fn}; expect {t if val else f}"
        src = program(fn_decl("main", [], "int64", lines, tail), header=hdr)
        c = Case(area, "pred", src, "", (t if val else f) & 0xFF)
        c.add_fail("E2005", "boolean case missing its false arm", m_case_drop_false(src, rng))
    c.info["names"] = ["s"]
    c.info["fnames"] = [fn]
    c.info["calls"] = [(fn, 2)]
    c.add_fail("E2001", f"integer literal passed to {fn}", rep(src, s_lit(needle), "7", 1))
    return c


def t_str_eq_case(rng, area):
    opts = rng.sample(WORDS, 3)
    pick = rng.choice(opts + ["other"])
    vals = [rng.randint(0, 100) for _ in opts]
    default = rng.randint(0, 100)
    val = vals[opts.index(pick)] if pick in opts else default
    clauses = [f"{s_lit(o)} -> {v}" for o, v in zip(opts, vals)] + [f"_: string -> {default}"]
    lines = [f"mode: string <- {s_lit(pick)};"]
    tail = "case mode of {\n        " + ";\n        ".join(clauses) + "\n    }"
    hdr = f"// case on string literals; {s_lit(pick)} gives {val}"
    src = program(fn_decl("main", [], "int64", lines, tail), header=hdr)
    c = Case(area, "strcase", src, "", val & 0xFF)
    c.info["names"] = ["mode"]
    c.info["case_scrut"] = "string"
    c.add_fail("E2005", "integer pattern against a string scrutinee", m_case_bad_pattern(src, rng, "string"))
    c.add_fail("E2001", "string result in an integer case arm", rep(src, f"{s_lit(opts[0])} -> {vals[0]}", f"{s_lit(opts[0])} -> {s_lit(opts[0])}", 1))
    return c


def t_str_helper(rng, area):
    kind = rng.choice(["wrap", "count_a", "shout"])
    if kind == "wrap":
        w = rng.choice(WORDS)
        f = fn_decl("wrap", [("s", "string")], "string", [], 'concatenate("[", concatenate(s, "]"))')
        stmts = ["print_string(wrap(" + s_lit(w) + "))", 'println("")']
        out = f"[{w}]\n"
        fname, calls = "wrap", [("wrap", 1)]
    elif kind == "count_a":
        w = rng.choice(["banana", "alpha", "silica", "zzz", "cascade"])
        f = "\n\n".join([
            fn_decl("count_a_rec", [("s", "string")], "int64", [], 'case length_chars(s) == 0 of {\n        true -> 0;\n        false -> count_a_step(s)\n    }'),
            fn_decl("count_a_step", [("s", "string")], "int64", ["head: string <- substring(s, 0, 1);", "rest: string <- substring(s, 1, length_chars(s));"],
                    'case head == "a" of {\n        true -> 1 + count_a_rec(rest);\n        false -> count_a_rec(rest)\n    }')])
        stmts = ["result: atom <- print_int64(count_a_rec(" + s_lit(w) + "))"]
        out = str(w.count("a"))
        fname, calls = "count_a_rec", [("count_a_rec", 1), ("count_a_step", 1)]
    else:
        w = rng.choice(WORDS)
        n = rng.randint(1, 3)
        f = fn_decl("shout", [("s", "string"), ("n", "int64")], "string", [],
                    'case n == 0 of {\n        true -> s;\n        false -> concatenate(shout(s, n - 1), "!")\n    }')
        stmts = [f"print_string(shout({s_lit(w)}, {n}))", 'println("")']
        out = w + "!" * n + "\n"
        fname, calls = "shout", [("shout", 2)]
    prod = "result" if kind == "count_a" else ":ok"
    body = seq_block(["device_io"], stmts, prod, rng.randint(0, 2))
    hdr = f"// string helper {fname}; prints {out}"
    src = program(f, f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "strhelper", src, out, 0 if prod == "result" else 2)
    c.info["fnames"] = [fname]
    c.info["calls"] = calls
    c.info["names"] = ["s"]
    c.info["has_seq"] = True
    c.add_fail("E2001", "integer literal returned from a string-typed arm", rep(src, "true -> s;", "true -> 0;", 1) if kind == "shout" else rep(src, 'true -> 0;', 'true -> "0";', 1) if kind == "count_a" else rep(src, '"]"', "1", 1))
    return c


def t_str_escape(rng, area):
    kind = rng.choice(["newline", "tab_bytes", "quote", "hex"])
    if kind == "newline":
        a, b = rng.choice(WORDS), rng.choice(WORDS)
        stmts = [f"print_string({s_lit(a)}\\n{s_lit(b)})".replace(f'{s_lit(a)}\\n{s_lit(b)}', f'"{a}\\n{b}"'), 'println("")']
        out = f"{a}\n{b}\n"
    elif kind == "tab_bytes":
        stmts = ['t: string <- "a\\tb"', "result: atom <- print_int64(length_bytes(t))"]
        out = "3"
    elif kind == "quote":
        stmts = ['q: string <- "say \\"hi\\""', "print_string(q)", 'println("")']
        out = 'say "hi"\n'
    else:
        stmts = ['h: string <- "\\x41\\x42"', "print_string(h)", 'println("")']
        out = "AB\n"
    prod = "result" if kind == "tab_bytes" else ":ok"
    body = seq_block(["device_io"], stmts, prod, rng.randint(0, 2))
    hdr = f"// string escape {kind}"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "escape", src, out, 0 if prod == "result" else 2)
    c.info["names"] = {"tab_bytes": ["t"], "quote": ["q"], "hex": ["h"]}.get(kind, [])
    c.info["fnames"] = ["print_string", "length_bytes"]
    c.info["has_seq"] = True
    return c


# ---------------------------------------------------------------------------
# lists
# ---------------------------------------------------------------------------

def L(ty, space="normal"):
    return f"List[{ty}, mem({space})]"


def gen_lists(rng, count):
    area = "list_addition"
    makers = [t_list_length, t_list_head, t_list_sum, t_list_prepend, t_list_at, t_list_fold_max, t_list_empty_case, t_list_string]
    cases = []
    for i in range(count):
        c = makers[i % len(makers)](rng, area)
        if c:
            cases.append(c)
    return cases


def ints(rng, n, lo=0, hi=40):
    return [rng.randint(lo, hi) for _ in range(n)]


def t_list_length(rng, area):
    ty = rng.choice(["int64", "int64", "uint32", "int32", "uint8"])
    sp = rng.choice(["normal", "normal", "normal_writethrough"])
    xs = ints(rng, rng.randint(1, 6))
    stmts = [f"xs: {L(ty, sp)} <- [{', '.join(map(str, xs))}]", f"n: int64 <- length[{ty}, mem({sp})](xs)"]
    body = seq_block([f"mem({sp})"], stmts, "n", rng.randint(0, 2))
    hdr = f"// list literal of {len(xs)} {ty} elements; length is {len(xs)}"
    src = program(f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "length", src, "", len(xs))
    c.info["names"] = ["xs", "n"]
    c.info["fnames"] = ["length"]
    c.info["has_seq"] = True
    c.info["has_list"] = True
    c.add_fail("E3001", "list literal built outside any sequence block",
               program(f"fn main() -> int64 {{\n    xs: {L(ty, sp)} <- [{', '.join(map(str, xs))}];\n    length[{ty}, mem({sp})](xs)\n}}", header=hdr))
    c.add_fail("E2001", "string element inside an integer list literal", rep(src, f"[{', '.join(map(str, xs))}]", "[" + ", ".join([f'"{xs[0]}"'] + list(map(str, xs[1:]))) + "]", 1))
    other = "normal_writethrough" if sp == "normal" else "normal"
    c.add_fail("E3010", "list space does not match the sequence's mem effect", rep(src, f"proc[mem({sp})]", f"proc[mem({other})]", 1))
    return c


def t_list_head(rng, area):
    xs = ints(rng, rng.randint(2, 5))
    kind = rng.choice(["head", "remove_head", "second"])
    stmts = [f"xs: {L('int64')} <- [{', '.join(map(str, xs))}]"]
    if kind == "head":
        stmts.append("first: int64 <- head[int64, mem(normal)](xs)")
        val, prod = xs[0], "first"
    elif kind == "remove_head":
        stmts.append("rest: List[int64, mem(normal)] <- remove_head[int64, mem(normal)](xs)")
        stmts.append("n: int64 <- length[int64, mem(normal)](rest)")
        val, prod = len(xs) - 1, "n"
    else:
        stmts.append("rest: List[int64, mem(normal)] <- remove_head[int64, mem(normal)](xs)")
        stmts.append("second: int64 <- head[int64, mem(normal)](rest)")
        val, prod = xs[1], "second"
    body = seq_block(["mem(normal)"], stmts, prod, rng.randint(0, 2))
    hdr = f"// {kind} on [{', '.join(map(str, xs))}] gives {val}"
    src = program(f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "head", src, "", val & 0xFF)
    c.info["names"] = ["xs", "rest", "first", "second", "n"]
    c.info["fnames"] = ["head", "remove_head", "length"]
    c.info["has_seq"] = True
    c.info["has_list"] = True
    c.add_fail("E2003", "list operation instantiated with the wrong element type", rep(src, "head[int64, mem(normal)](xs)", "head[string, mem(normal)](xs)", 1) if kind == "head" else rep(src, "remove_head[int64, mem(normal)](xs)", "remove_head[uint8, mem(normal)](xs)", 1))
    return c


def sum_fn(name, ty="int64", acc=False):
    if acc:
        return fn_decl(name, [("xs", L(ty)), ("acc", ty)], ty, [],
                       f"case xs of {{\n        []: {L(ty)} -> acc;\n        [h: {ty}, t: {L(ty)}] -> {name}(t, acc + h);\n        _: {L(ty)} -> acc\n    }}")
    return fn_decl(name, [("xs", L(ty))], ty, [],
                   f"case xs of {{\n        []: {L(ty)} -> 0;\n        [h: {ty}, t: {L(ty)}] -> h + {name}(t);\n        _: {L(ty)} -> 0\n    }}")


def t_list_sum(rng, area):
    xs = ints(rng, rng.randint(1, 6), 0, 30)
    acc = rng.random() < 0.5
    name = "sum_acc" if acc else "sum_list"
    f = sum_fn(name, acc=acc)
    call = f"{name}(xs, 0)" if acc else f"{name}(xs)"
    stmts = [f"xs: {L('int64')} <- [{', '.join(map(str, xs))}]", f"total: int64 <- {call}"]
    body = seq_block(["mem(normal)"], stmts, "total", rng.randint(0, 2))
    val = sum(xs)
    hdr = f"// recursive {name} over a list; total {val}"
    src = program(f, f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "sum", src, "", val & 0xFF)
    c.info["names"] = ["xs", "total", "h", "t"]
    c.info["fnames"] = [name]
    c.info["calls"] = [(name, 2 if acc else 1)]
    c.info["has_seq"] = True
    c.info["has_list"] = True
    c.add_fail("E2001", "string literal in an integer list arm", rep(src, "-> 0;", '-> "0";', 1) if not acc else rep(src, "-> acc;", '-> "acc";', 1))
    return c


def t_list_prepend(rng, area):
    ty = rng.choice(["int64", "uint32", "int32"])
    n = rng.randint(1, 5)
    vals = ints(rng, n)
    stmts = [f"xs0: {L(ty)} <- empty[{ty}, mem(normal)]()"]
    for i, v in enumerate(vals):
        stmts.append(f"xs{i + 1}: {L(ty)} <- prepend[{ty}, mem(normal)]({v}, xs{i})")
    kind = rng.choice(["length", "head"])
    if kind == "length":
        stmts.append(f"n: int64 <- length[{ty}, mem(normal)](xs{n})")
        val, prod = n, "n"
    else:
        stmts.append(f"h: {ty} <- head[{ty}, mem(normal)](xs{n})")
        val, prod = vals[-1], "h"
    body = seq_block(["mem(normal)"], stmts, prod, rng.randint(0, 2))
    hdr = f"// {n} prepends after empty; {kind} is {val}"
    ret = "int64" if kind == "length" else ty
    src = program(f"fn main() -> {ret} {{\n{body}\n}}", header=hdr)
    c = Case(area, "prepend", src, "", val & 0xFF)
    c.info["names"] = [f"xs{i}" for i in range(n + 1)]
    c.info["fnames"] = ["prepend", "empty", "length", "head"]
    c.info["has_seq"] = True
    c.info["has_list"] = True
    c.add_fail("E2001", "string element prepended to an integer list", rep(src, f"prepend[{ty}, mem(normal)]({vals[0]}, xs0)", f'prepend[{ty}, mem(normal)]("{vals[0]}", xs0)', 1))
    c.add_fail("E2003", "prepend called with its arguments swapped", rep(src, f"prepend[{ty}, mem(normal)]({vals[0]}, xs0)", f"prepend[{ty}, mem(normal)](xs0, {vals[0]})", 1))
    return c


def t_list_at(rng, area):
    xs = ints(rng, rng.randint(2, 7))
    i = rng.randint(0, len(xs) - 1)
    stmts = [f"xs: {L('int64')} <- [{', '.join(map(str, xs))}]", f"v: int64 <- list_at[int64, mem(normal)](xs, {i})"]
    body = seq_block(["mem(normal)"], stmts, "v", rng.randint(0, 2))
    hdr = f"// list_at index {i} of [{', '.join(map(str, xs))}] is {xs[i]}"
    src = program(f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "at", src, "", xs[i] & 0xFF)
    c.info["names"] = ["xs", "v"]
    c.info["fnames"] = ["list_at"]
    c.info["has_seq"] = True
    c.info["has_list"] = True
    c.add_fail("E2001", "string literal used as a list index", rep(src, f"(xs, {i})", f'(xs, "{i}")', 1))
    return c


def t_list_fold_max(rng, area):
    xs = ints(rng, rng.randint(1, 6), 0, 60)
    kind = rng.choice(["max", "count_even", "count"])
    if kind == "max":
        f = fn_decl("max_acc", [("xs", L("int64")), ("best", "int64")], "int64", [],
                    f"case xs of {{\n        []: {L('int64')} -> best;\n        [h: int64, t: {L('int64')}] -> case h > best of {{\n            true -> max_acc(t, h);\n            false -> max_acc(t, best)\n        }};\n        _: {L('int64')} -> best\n    }}")
        call, val, fname = "max_acc(xs, 0)", max(xs), "max_acc"
    elif kind == "count_even":
        f = fn_decl("count_even", [("xs", L("int64"))], "int64", [],
                    f"case xs of {{\n        []: {L('int64')} -> 0;\n        [h: int64, t: {L('int64')}] -> case h % 2 == 0 of {{\n            true -> 1 + count_even(t);\n            false -> count_even(t)\n        }};\n        _: {L('int64')} -> 0\n    }}")
        call, val, fname = "count_even(xs)", sum(1 for x in xs if x % 2 == 0), "count_even"
    else:
        f = fn_decl("count", [("xs", L("int64"))], "int64", [],
                    f"case xs of {{\n        []: {L('int64')} -> 0;\n        [_: int64, t: {L('int64')}] -> 1 + count(t);\n        _: {L('int64')} -> 0\n    }}")
        call, val, fname = "count(xs)", len(xs), "count"
    stmts = [f"xs: {L('int64')} <- [{', '.join(map(str, xs))}]", f"r: int64 <- {call}"]
    body = seq_block(["mem(normal)"], stmts, "r", rng.randint(0, 2))
    hdr = f"// {fname} over [{', '.join(map(str, xs))}] = {val}"
    src = program(f, f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "fold", src, "", val & 0xFF)
    c.info["names"] = ["xs", "r", "best", "h", "t"]
    c.info["fnames"] = [fname]
    c.info["calls"] = [(fname, call.count(",") + 1)]
    c.info["has_seq"] = True
    c.info["has_list"] = True
    c.add_fail("E2005", "list case pattern typed with the wrong element type", rep(src, "[h: int64, t:", "[h: string, t:", 1) if kind != "count" else rep(src, "[_: int64, t:", "[_: string, t:", 1))
    return c


def t_list_empty_case(rng, area):
    empty = rng.random() < 0.5
    xs = [] if empty else ints(rng, rng.randint(1, 4))
    e_val, ne_val = rng.randint(0, 100), rng.randint(0, 100)
    lit = f"empty[int64, mem(normal)]()" if empty else f"[{', '.join(map(str, xs))}]"
    stmts = [f"xs: {L('int64')} <- {lit}",
             f"r: int64 <- case xs of {{\n            []: {L('int64')} -> {e_val};\n            [h: int64, _: {L('int64')}] -> h + {ne_val};\n            _: {L('int64')} -> {e_val}\n        }}"]
    body = seq_block(["mem(normal)"], stmts, "r", 0)
    val = e_val if empty else xs[0] + ne_val
    hdr = f"// case on {'an empty' if empty else 'a non-empty'} list; expect {val}"
    src = program(f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "emptycase", src, "", val & 0xFF)
    c.info["names"] = ["xs", "r"]
    c.info["fnames"] = ["empty"]
    c.info["has_seq"] = True
    c.info["has_list"] = True
    c.add_fail("E2015", "list pattern without its mem(Space)", rep(src, f"[]: {L('int64')} ->", "[]: List[int64] ->", 1))
    return c


def t_list_string(rng, area):
    words = [rng.choice(WORDS) for _ in range(rng.randint(1, 4))]
    kind = rng.choice(["join", "count_len"])
    if kind == "join":
        f = fn_decl("join_all", [("xs", L("string"))], "string", [],
                    f"case xs of {{\n        []: {L('string')} -> \"\";\n        [h: string, t: {L('string')}] -> concatenate(h, join_all(t));\n        _: {L('string')} -> \"\"\n    }}")
        stmts = [f"xs: {L('string')} <- [{', '.join(s_lit(w) for w in words)}]", "s: string <- join_all(xs)", "print_string(s)", 'println("")']
        body = seq_block(["mem(normal)", "device_io"], stmts, ":ok", 0)
        out, ex, fname = "".join(words) + "\n", 2, "join_all"
    else:
        f = fn_decl("total_len", [("xs", L("string"))], "int64", [],
                    f"case xs of {{\n        []: {L('string')} -> 0;\n        [h: string, t: {L('string')}] -> length_chars(h) + total_len(t);\n        _: {L('string')} -> 0\n    }}")
        stmts = [f"xs: {L('string')} <- [{', '.join(s_lit(w) for w in words)}]", "n: int64 <- total_len(xs)"]
        body = seq_block(["mem(normal)"], stmts, "n", 0)
        out, ex, fname = "", sum(len(w) for w in words) & 0xFF, "total_len"
    hdr = f"// {fname} over a list of strings"
    ret = "atom" if kind == "join" else "int64"
    src = program(f, f"fn main() -> {ret} {{\n{body}\n}}", header=hdr)
    c = Case(area, "strlist", src, out, ex)
    c.info["names"] = ["xs", "h", "t"]
    c.info["fnames"] = [fname]
    c.info["calls"] = [(fname, 1)]
    c.info["has_seq"] = True
    c.info["has_list"] = True
    c.add_fail("E2001", "integer element in a string list literal", rep(src, s_lit(words[0]), "1", 1))
    if kind == "join":
        c.add_fail("E3002", "device_io used but only mem(normal) declared", rep(src, "proc[mem(normal), device_io]", "proc[mem(normal)]", 1))
    return c


# ---------------------------------------------------------------------------
# tuples
# ---------------------------------------------------------------------------

def gen_tuples(rng, count):
    area = "tuples_addition"
    makers = [t_tuple_decompose, t_tuple_return, t_tuple_nested, t_tuple_mixed_print, t_tuple_param, t_tuple_swap, t_tuple_atom_tag]
    cases = []
    for i in range(count):
        c = makers[i % len(makers)](rng, area)
        if c:
            cases.append(c)
    return cases


def t_tuple_decompose(rng, area):
    n = rng.randint(2, 4)
    vals = ints(rng, n, 0, 60)
    names = ["a", "b", "c", "d"][:n]
    from_literal = rng.random() < 0.5
    lines = []
    tup = "(" + ", ".join(map(str, vals)) + ")"
    tty = "(" + ", ".join(["int64"] * n) + ")"
    pat = "(" + ", ".join(f"{nm}: int64" for nm in names) + ")"
    if from_literal:
        lines.append(f"{pat} <- {tup};")
    else:
        lines.append(f"t: {tty} <- {tup};")
        lines.append(f"{pat} <- t;")
    op = rng.choice(["+", "*"])
    if op == "+":
        expr, val = " + ".join(names), sum(vals)
    else:
        expr, val = names[0] + " * " + names[1] + ("" if n == 2 else " + " + " + ".join(names[2:])), vals[0] * vals[1] + sum(vals[2:])
    if val > 255:
        return None
    hdr = f"// decompose a {n}-tuple {'from a literal' if from_literal else 'from a binding'}; {expr} = {val}"
    src = program(fn_decl("main", [], "int64", lines, expr), header=hdr)
    c = Case(area, "decompose", src, "", val)
    c.info["names"] = names + ([] if from_literal else ["t"])
    c.add_fail("E2005", "decomposition pattern with the wrong element count",
               rep(src, pat, "(" + ", ".join(f"{nm}: int64" for nm in names + ["extra"]) + ")", 1) if not from_literal else None)
    c.add_fail("E2005", "tuple literal element count differs from the declared tuple type",
               rep(src, f"t: {tty} <- {tup}", f"t: {tty} <- (" + ", ".join(map(str, vals + [1])) + ")", 1) if not from_literal else None)
    c.add_fail("E2005", "decomposition element typed as string against an int64 slot",
               rep(src, f"{names[-1]}: int64)", f"{names[-1]}: string)", 1) if not from_literal else None)
    return c


def t_tuple_return(rng, area):
    a, b = rng.randint(0, 50), rng.randint(0, 50)
    kind = rng.choice(["pair", "minmax", "divmod"])
    if kind == "pair":
        f = fn_decl("pair", [("x", "int64"), ("y", "int64")], "(int64, int64)", [], "(x + 1, y * 2)")
        call, ra, rb = f"pair({a}, {b})", a + 1, b * 2
    elif kind == "minmax":
        f = fn_decl("minmax", [("x", "int64"), ("y", "int64")], "(int64, int64)", [],
                    "case x < y of {\n        true -> (x, y);\n        false -> (y, x)\n    }")
        call, ra, rb = f"minmax({a}, {b})", min(a, b), max(a, b)
    else:
        b = rng.randint(1, 9)
        f = fn_decl("divmod", [("x", "int64"), ("y", "int64")], "(int64, int64)", [], "(x / y, x % y)")
        call, ra, rb = f"divmod({a}, {b})", a // b, a % b
    if ra + rb > 255:
        return None
    lines = [f"(p: int64, q: int64) <- {call};"]
    hdr = f"// {kind} returns a pair; p + q = {ra + rb}"
    src = program(f, fn_decl("main", [], "int64", lines, "p + q"), header=hdr)
    c = Case(area, "tupret", src, "", ra + rb)
    c.info["names"] = ["p", "q", "x", "y"]
    c.info["fnames"] = [kind]
    c.info["calls"] = [(kind, 2)]
    c.add_fail("E2001", "string element in the returned tuple", rep(src, "(x + 1, y * 2)", '(x + 1, "y")', 1) if kind == "pair" else rep(src, "(x / y, x % y)", '("x", x % y)', 1) if kind == "divmod" else rep(src, "true -> (x, y);", 'true -> (x, "y");', 1))
    c.add_fail("E2005", "decomposition of a pair into three names", rep(src, "(p: int64, q: int64) <-", "(p: int64, q: int64, r: int64) <-", 1))
    return c


def t_tuple_nested(rng, area):
    a, b, cc = ints(rng, 3, 0, 40)
    style = rng.choice(["inner_first", "outer_first"])
    if style == "inner_first":
        lines = [f"t: (int64, (int64, int64)) <- ({a}, ({b}, {cc}));", "(x: int64, inner: (int64, int64)) <- t;", "(y: int64, z: int64) <- inner;"]
    else:
        lines = [f"t: ((int64, int64), int64) <- (({a}, {b}), {cc});", "(inner: (int64, int64), z: int64) <- t;", "(x: int64, y: int64) <- inner;"]
    val = a + b + cc
    hdr = f"// nested tuple decomposition; x + y + z = {val}"
    src = program(fn_decl("main", [], "int64", lines, "x + y + z"), header=hdr)
    c = Case(area, "nested", src, "", val & 0xFF)
    c.info["names"] = ["t", "inner", "x", "y", "z"]
    c.add_fail("E2005", "inner tuple decomposed against a mismatched declared type",
               rep(src, "inner: (int64, int64)) <- t;", "inner: (int64, string)) <- t;", 1) if style == "inner_first" else rep(src, "(inner: (int64, int64), z: int64) <- t;", "(inner: (int64, int64, int64), z: int64) <- t;", 1))
    return c


def t_tuple_mixed_print(rng, area):
    n = rng.randint(0, 99)
    s = rng.choice(WORDS)
    b = rng.choice([True, False])
    at = rng.choice(["ok", "ready", "done"])
    order = rng.choice(["nsb", "sna", "bns"])
    if order == "nsb":
        tty, tup, pat = "(int64, string, boolean)", f"({n}, {s_lit(s)}, {str(b).lower()})", "(k: int64, name: string, flag: boolean)"
        prints = ["print_int64(k)", "print_string(name)", "print_boolean(flag)"]
        out = f"{n}\n{s}\n{str(b).lower()}\n"
    elif order == "sna":
        tty, tup, pat = "(string, int64, atom)", f"({s_lit(s)}, {n}, :{at})", "(name: string, k: int64, tag: atom)"
        prints = ["print_string(name)", "print_int64(k)", "print_atom(tag)"]
        out = f"{s}\n{n}\n:{at}\n"
    else:
        tty, tup, pat = "(boolean, int64, string)", f"({str(b).lower()}, {n}, {s_lit(s)})", "(flag: boolean, k: int64, name: string)"
        prints = ["print_boolean(flag)", "print_int64(k)", "print_string(name)"]
        out = f"{str(b).lower()}\n{n}\n{s}\n"
    stmts = [f"t: {tty} <- {tup}", f"{pat} <- t"]
    for p in prints:
        stmts += [p, 'println("")']
    body = seq_block(["device_io"], stmts, ":ok", rng.randint(0, 2))
    hdr = "// decompose a mixed tuple and print each element"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "mixed", src, out, 2)
    c.info["names"] = ["t", "k", "name", "flag", "tag"]
    c.info["fnames"] = ["print_int64", "print_string", "print_boolean", "print_atom"]
    c.info["has_seq"] = True
    c.add_fail("E2003", "string element printed with print_int64", rep(src, "print_string(name)", "print_int64(name)", 1))
    c.add_fail("E2005", "decomposition pattern element types in the wrong order",
               rep(src, pat, pat.replace("k: int64", "k: string", 1).replace("name: string", "name: int64", 1), 1) if "name" in pat else None)
    return c


def t_tuple_param(rng, area):
    a, b = ints(rng, 2, 0, 60)
    style = rng.choice(["pattern_param", "typed_param"])
    if style == "pattern_param":
        f = fn_decl("add_pair", ["(a: int64, b: int64)"], "int64", [], "a + b")
        call = f"add_pair(({a}, {b}))"
    else:
        f = fn_decl("add_pair", [("p", "(int64, int64)")], "int64", ["(a: int64, b: int64) <- p;"], "a + b")
        call = f"add_pair(({a}, {b}))"
    val = a + b
    if val > 255:
        return None
    hdr = f"// tuple parameter {style}; add_pair(({a}, {b})) = {val}"
    src = program(f, fn_decl("main", [], "int64", [], call), header=hdr)
    c = Case(area, "tupparam", src, "", val)
    c.info["names"] = ["a", "b", "p"]
    c.info["fnames"] = ["add_pair"]
    c.info["calls"] = [("add_pair", 1)]
    c.add_fail("E2005", "tuple argument with three elements against a pair parameter", rep(src, f"add_pair(({a}, {b}))", f"add_pair(({a}, {b}, 1))", 1))
    return c


def t_tuple_swap(rng, area):
    a, b = ints(rng, 2, 0, 60)
    f = fn_decl("swap", [("p", "(int64, int64)")], "(int64, int64)", ["(x: int64, y: int64) <- p;"], "(y, x)")
    lines = [f"(first: int64, second: int64) <- swap(({a}, {b}));"]
    expr = rng.choice(["first", "second", "first * 2 + second"])
    val = {"first": b, "second": a, "first * 2 + second": b * 2 + a}[expr]
    if val > 255:
        return None
    hdr = f"// swap(({a}, {b})); {expr} = {val}"
    src = program(f, fn_decl("main", [], "int64", lines, expr), header=hdr)
    c = Case(area, "swap", src, "", val)
    c.info["names"] = ["first", "second", "x", "y", "p"]
    c.info["fnames"] = ["swap"]
    c.info["calls"] = [("swap", 1)]
    c.add_fail("E2005", "swap returns a pair but is decomposed as a triple", rep(src, "(first: int64, second: int64) <-", "(first: int64, second: int64, third: int64) <-", 1))
    return c


def t_tuple_atom_tag(rng, area):
    a, b = rng.randint(1, 40), rng.randint(0, 9)
    ok = b != 0
    f = fn_decl("safe_div", [("x", "int64"), ("y", "int64")], "(atom, int64)", [],
                "case y == 0 of {\n        true -> (:error, 0);\n        false -> (:ok, x / y)\n    }")
    lines = [f"r: (atom, int64) <- safe_div({a}, {b});", "(tag: atom, v: int64) <- r;"]
    tail = "case tag of {\n        :ok -> v;\n        _: atom -> 200\n    }"
    val = a // b if ok else 200
    hdr = f"// tagged tuple (atom, int64) from safe_div({a}, {b}); expect {val}"
    src = program(f, fn_decl("main", [], "int64", lines, tail), header=hdr)
    c = Case(area, "tagged", src, "", val & 0xFF)
    c.info["names"] = ["r", "tag", "v", "x", "y"]
    c.info["fnames"] = ["safe_div"]
    c.info["calls"] = [("safe_div", 2)]
    c.info["case_scrut"] = "atom"
    c.add_fail("E2005", "integer pattern against an atom scrutinee", rep(src, ":ok -> v;", "1 -> v;", 1))
    c.add_fail("E2001", "string literal in the int64 slot of the tuple", rep(src, "(:error, 0)", '(:error, "0")', 1))
    return c


# ---------------------------------------------------------------------------
# records
# ---------------------------------------------------------------------------

def gen_records(rng, count):
    area = "records_addition"
    makers = [t_rec_fields, t_rec_nested, t_rec_fn_param, t_rec_case, t_rec_update, t_rec_list, t_rec_mixed_print]
    cases = []
    for i in range(count):
        c = makers[i % len(makers)](rng, area)
        if c:
            cases.append(c)
    return cases


PT = "{ x: int64, y: int64 }"


def t_rec_fields(rng, area):
    x, y = ints(rng, 2, 0, 60)
    op = rng.choice(["+", "*", "-"])
    if op == "-" and x < y:
        x, y = y, x
    val = eval(f"{x} {op} {y}")
    if val > 255:
        return None
    kind = rng.choice(["direct", "bound"])
    if kind == "direct":
        lines = [f"p: {PT} <- {{ x: {x}, y: {y} }};"]
        tail = f"p.x {op} p.y"
    else:
        lines = [f"p: {PT} <- {{ x: {x}, y: {y} }};", "xv: int64 <- p.x;", "yv: int64 <- p.y;"]
        tail = f"xv {op} yv"
    hdr = f"// inline record field access; x {op} y = {val}"
    src = program(fn_decl("main", [], "int64", lines, tail), header=hdr)
    c = Case(area, "fields", src, "", val)
    c.info["names"] = ["p", "xv", "yv"]
    c.info["has_record"] = True
    c.add_fail("E2005", "access to a field the record does not have", rep(src, "p.y", "p.z", 1))
    c.add_fail("E2003", "record literal missing a declared field", rep(src, f"{{ x: {x}, y: {y} }}", f"{{ x: {x} }}", 1))
    c.add_fail("E2001", "string literal in an int64 record field", rep(src, f"y: {y} }}", f'y: "{y}" }}', 1))
    return c


def t_rec_nested(rng, area):
    x0, y0, x1, y1 = ints(rng, 4, 0, 30)
    RT = f"{{ top_left: {PT}, bottom_right: {PT} }}"
    lines = [f"rect: {RT} <- {{\n        top_left: {{ x: {x0}, y: {y0} }},\n        bottom_right: {{ x: {x1}, y: {y1} }}\n    }};"]
    kind = rng.choice(["width", "sum"])
    if kind == "width":
        tail = "rect.bottom_right.x - rect.top_left.x"
        val = x1 - x0
        if val < 0:
            tail = "rect.top_left.x - rect.bottom_right.x"
            val = -val
    else:
        tail = "rect.top_left.x + rect.top_left.y + rect.bottom_right.x + rect.bottom_right.y"
        val = x0 + y0 + x1 + y1
    hdr = f"// nested inline records; {kind} = {val}"
    src = program(fn_decl("main", [], "int64", lines, tail), header=hdr)
    c = Case(area, "nested", src, "", val & 0xFF)
    c.info["names"] = ["rect"]
    c.info["has_record"] = True
    c.add_fail("E2005", "nested field access with a misspelled inner field", rep(src, "rect.top_left.x", "rect.top_left.z", 1))
    return c


def t_rec_fn_param(rng, area):
    w, h = ints(rng, 2, 1, 15)
    kind = rng.choice(["area", "perimeter", "make"])
    RT = "{ width: int64, height: int64 }"
    if kind == "area":
        f = fn_decl("area", [("r", RT)], "int64", [], "r.width * r.height")
        call, val = f"area({{ width: {w}, height: {h} }})", w * h
    elif kind == "perimeter":
        f = fn_decl("perimeter", [("r", RT)], "int64", [], "2 * (r.width + r.height)")
        call, val = f"perimeter({{ width: {w}, height: {h} }})", 2 * (w + h)
    else:
        f = "\n\n".join([fn_decl("make_rect", [("w", "int64"), ("h", "int64")], RT, [], "{ width: w, height: h }"),
                         fn_decl("area", [("r", RT)], "int64", [], "r.width * r.height")])
        call, val = f"area(make_rect({w}, {h}))", w * h
    if val > 255:
        return None
    hdr = f"// record passed to a function; {call} = {val}"
    src = program(f, fn_decl("main", [], "int64", [], call), header=hdr)
    c = Case(area, "recparam", src, "", val)
    c.info["names"] = ["r", "w", "h"]
    c.info["fnames"] = ["area", "perimeter", "make_rect"]
    c.info["calls"] = [("area", 1), ("perimeter", 1), ("make_rect", 2)]
    c.info["has_record"] = True
    c.add_fail("E2003", "record argument with a missing field", rep(src, f"{{ width: {w}, height: {h} }}", f"{{ width: {w} }}", 1) if kind != "make" else rep(src, "{ width: w, height: h }", "{ width: w }", 1))
    c.add_fail("E2005", "field name misspelled in the function body", rep(src, "r.height", "r.heigth", 1))
    return c


def t_rec_case(rng, area):
    x, y = rng.choice([(0, 0), (0, 5), (7, 0), (3, 4), (0, 0), (2, 9)])
    if rng.random() < 0.5:
        x, y = rng.randint(0, 9), rng.randint(0, 9)
    kind = rng.choice(["axis", "guard"])
    if kind == "axis":
        f = fn_decl("classify", [("p", PT)], "int64", [],
                    "case p of {\n        { x: 0, y: 0 } -> 0;\n        { x: 0, y: _ } -> 1;\n        { x: _, y: 0 } -> 2;\n        _ -> 3\n    }")
        val = 0 if (x, y) == (0, 0) else 1 if x == 0 else 2 if y == 0 else 3
    else:
        f = fn_decl("score", [("p", PT)], "int64", [],
                    "case p of {\n        { x: xv, y: yv } if xv > yv -> xv - yv;\n        { x: xv, y: yv } if yv > xv -> yv - xv;\n        { x: xv, y: yv } -> xv + yv\n    }")
        val = x - y if x > y else y - x if y > x else x + y
    fname = "classify" if kind == "axis" else "score"
    lines = [f"p: {PT} <- {{ x: {x}, y: {y} }};"]
    hdr = f"// record pattern matching ({kind}); expect {val}"
    src = program(f, fn_decl("main", [], "int64", lines, f"{fname}(p)"), header=hdr)
    c = Case(area, "reccase", src, "", val & 0xFF)
    c.info["names"] = ["p"]
    c.info["fnames"] = [fname]
    c.info["calls"] = [(fname, 1)]
    c.info["has_record"] = True
    c.add_fail("E2005", "record pattern naming a field the type lacks", rep(src, "{ x: 0, y: 0 } -> 0;", "{ x: 0, z: 0 } -> 0;", 1) if kind == "axis" else rep(src, "{ x: xv, y: yv } if xv > yv", "{ x: xv, w: yv } if xv > yv", 1))
    return c


def t_rec_update(rng, area):
    cnt, delta = rng.randint(0, 50), rng.randint(1, 30)
    RT = "{ counter: int64, label: string }"
    f = fn_decl("bump", [("s", RT), ("by", "int64")], RT, [], "{ counter: s.counter + by, label: s.label }")
    lines = [f"s0: {RT} <- {{ counter: {cnt}, label: \"count\" }};", f"s1: {RT} <- bump(s0, {delta});", "s2: " + RT + f" <- bump(s1, {delta});"]
    val = cnt + 2 * delta
    if val > 255:
        return None
    hdr = f"// functional record update through bump; counter ends at {val}"
    src = program(f, fn_decl("main", [], "int64", lines, "s2.counter"), header=hdr)
    c = Case(area, "update", src, "", val)
    c.info["names"] = ["s0", "s1", "s2", "by"]
    c.info["fnames"] = ["bump"]
    c.info["calls"] = [("bump", 2)]
    c.info["has_record"] = True
    c.add_fail("E2001", "integer written into the string label field", rep(src, 'label: "count"', "label: 7", 1))
    c.add_fail("E2005", "reading a field that the record type does not declare", rep(src, "s2.counter", "s2.total", 1))
    return c


def t_rec_list(rng, area):
    KV = "{ k: int64, v: int64 }"
    n = rng.randint(1, 4)
    items = [(i + 1, rng.randint(0, 40)) for i in range(n)]
    f = fn_decl("sum_v", [("xs", L(KV))], "int64", [],
                f"case xs of {{\n        []: {L(KV)} -> 0;\n        [h: {KV}, t: {L(KV)}] -> h.v + sum_v(t);\n        _: {L(KV)} -> 0\n    }}")
    lit = "[" + ", ".join(f"{{ k: {k}, v: {v} }}" for k, v in items) + "]"
    stmts = [f"xs: {L(KV)} <- {lit}", "total: int64 <- sum_v(xs)"]
    body = seq_block(["mem(normal)"], stmts, "total", 0)
    val = sum(v for _, v in items)
    hdr = f"// list of inline records folded by sum_v = {val}"
    src = program(f, f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "reclist", src, "", val & 0xFF)
    c.info["names"] = ["xs", "total", "h", "t"]
    c.info["fnames"] = ["sum_v"]
    c.info["calls"] = [("sum_v", 1)]
    c.info["has_seq"] = True
    c.info["has_list"] = True
    c.info["has_record"] = True
    c.add_fail("E2005", "field v misspelled on the list element", rep(src, "h.v + sum_v(t)", "h.val + sum_v(t)", 1))
    return c


def t_rec_mixed_print(rng, area):
    name = rng.choice(WORDS)
    age = rng.randint(1, 99)
    active = rng.choice([True, False])
    RT = "{ name: string, age: int64, active: boolean }"
    stmts = [f"person: {RT} <- {{ name: {s_lit(name)}, age: {age}, active: {str(active).lower()} }}",
             "print_string(person.name)", 'println("")', "print_int64(person.age)", 'println("")', "print_boolean(person.active)", 'println("")']
    body = seq_block(["device_io"], stmts, ":ok", rng.randint(0, 2))
    hdr = "// print each field of a mixed record"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "recprint", src, f"{name}\n{age}\n{str(active).lower()}\n", 2)
    c.info["names"] = ["person"]
    c.info["fnames"] = ["print_string", "print_int64", "print_boolean"]
    c.info["has_seq"] = True
    c.info["has_record"] = True
    c.add_fail("E2003", "string field printed with print_int64", rep(src, "print_string(person.name)", "print_int64(person.name)", 1))
    c.add_fail("E2001", "boolean field initialised with an integer", rep(src, f"active: {str(active).lower()} }}", "active: 1 }", 1))
    return c
