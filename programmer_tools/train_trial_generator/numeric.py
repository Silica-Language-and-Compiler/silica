"""Generators for the numeric trial areas: intN/uintN, floatN, negation,
bitwise, boolean, atoms."""
import random
from fractions import Fraction
from common import *

PREC = {"*": 3, "/": 3, "%": 3, "+": 2, "-": 2}


class E:
    """Expression node with text, value and precedence."""
    def __init__(self, text, val, prec=9):
        self.text, self.val, self.prec = text, val, prec

    def wrap(self, need):
        return f"({self.text})" if self.prec < need else self.text


def lit_int(rng, lo, hi):
    v = rng.randint(lo, hi)
    return E(str(v), v)


def int_expr(rng, ty, depth, env, want_nonneg=True):
    """Random arithmetic expression of type ty; env: list of (name, value)."""
    lo, hi = INT_RANGE[ty]
    for _ in range(60):
        e = _int_expr(rng, ty, depth, env)
        if e is None:
            continue
        if want_nonneg and e.val < 0:
            continue
        if lo <= e.val <= hi:
            return e
    v = rng.randint(1, 40)
    return E(str(v), v)


def _int_expr(rng, ty, depth, env):
    lo, hi = INT_RANGE[ty]
    small = min(hi, 60)
    if depth == 0 or rng.random() < 0.25:
        if env and rng.random() < 0.5:
            n, v = rng.choice(env)
            return E(n, v)
        return lit_int(rng, 0, small)
    op = rng.choice(["+", "+", "-", "*", "/", "%"])
    a = _int_expr(rng, ty, depth - 1, env)
    b = _int_expr(rng, ty, depth - 1, env)
    if a is None or b is None:
        return None
    if op in ("/", "%"):
        if b.val <= 0 or a.val < 0:
            return None
        val = a.val // b.val if op == "/" else a.val % b.val
    elif op == "+":
        val = a.val + b.val
    elif op == "-":
        val = a.val - b.val
        if val < 0 and ty.startswith("uint"):
            return None
    else:
        val = a.val * b.val
    if not (lo <= val <= hi):
        return None
    p = PREC[op]
    # left operand: same precedence ok (left assoc); right operand needs strictly higher for - / %
    lt = a.wrap(p)
    rt = b.wrap(p + 1)
    if rng.random() < 0.12:
        return E(f"({lt} {op} {rt})", val, 9)
    return E(f"{lt} {op} {rt}", val, p)


def pr(ty):
    return "print_" + ty


# ---------------------------------------------------------------------------
# integer programs
# ---------------------------------------------------------------------------

def gen_int_area(rng, ty, count):
    area = f"{ty}_addition"
    cases = []
    makers = [t_int_pure, t_int_bind, t_int_print, t_int_compare, t_int_helper,
              t_int_case, t_int_recursive, t_int_chain_print, t_int_pure, t_int_print]
    for i in range(count):
        mk = makers[i % len(makers)]
        c = mk(rng, ty, area)
        if c:
            cases.append(c)
    return cases


def t_int_pure(rng, ty, area):
    e = int_expr(rng, ty, rng.randint(1, 3), [])
    if not (0 <= e.val <= 255):
        e = int_expr(rng, ty, 2, [])
        if not (0 <= e.val <= 255):
            return None
    hdr = f"// {ty} arithmetic: {e.text} = {e.val}"
    src = program(fn_decl("main", [], ty, [], e.text), header=hdr)
    c = Case(area, "arith", src, "", e.val & 0xFF)
    c.info["ret"] = ty
    # literal-type failures
    bad = rng.choice([("true", "boolean"), ('"forty-two"', "string"), (":done", "atom")])
    c.add_fail("E2001", f"{bad[1]} literal returned from a {ty} function",
               rep(src, e.text + "\n}", bad[0] + "\n}"))
    return c


def t_int_bind(rng, ty, area):
    n = rng.randint(2, 4)
    names = rng.sample(["a", "b", "c", "d", "base", "step", "count", "width", "height", "total", "k", "m"], n)
    env = []
    lines = []
    for nm in names:
        e = int_expr(rng, ty, rng.randint(0, 2), env)
        env.append((nm, e.val))
        lines.append(f"{nm}: {ty} <- {e.text};")
    tail = int_expr(rng, ty, 2, env)
    tries = 0
    while not (0 <= tail.val <= 255) and tries < 20:
        tail = int_expr(rng, ty, 2, env)
        tries += 1
    if not (0 <= tail.val <= 255):
        return None
    rhs_later = {n: " ".join(l.split("<-", 1)[1] for l in lines[i + 1:]) for i, (n, _) in enumerate(env)}
    used = {n for n, _ in env if re.search(r"\b" + n + r"\b", tail.text + " " + rhs_later[n])}
    # make sure every binding is used: fold unused ones into the tail
    for nm, v in env:
        if nm not in used:
            tail = E(f"{tail.text} + {nm} - {nm}", tail.val, 2)
    hdr = f"// {ty} bindings then expression; expect {tail.val}"
    src = program(fn_decl("main", [], ty, lines, tail.text), header=hdr)
    c = Case(area, "bind", src, "", tail.val & 0xFF)
    c.info["names"] = [n for n, _ in env]
    c.info["ret"] = ty
    # width mismatch: retype the first binding
    other = rng.choice([t for t in INT_TYPES if t != ty])
    c.add_fail("E2003", f"binding {names[0]} declared {other} but used as {ty}",
               rep(src, f"{names[0]}: {ty} <-", f"{names[0]}: {other} <-", 1))
    c.add_fail("E2013", "unary minus on a variable instead of negate_" + ty,
               rep(src, f"\n    {tail.text}\n}}", f"\n    -{names[0]} + {tail.text}\n}}"))
    return c


def t_int_print(rng, ty, area):
    style = rng.randint(0, 2)
    kind = rng.choice(["literal", "expr", "var", "ignore", "two"])
    stmts, out, prod, names = [], "", "result", []
    if kind == "literal":
        e = int_expr(rng, ty, 0, [])
        stmts.append(f"result: atom <- {pr(ty)}({e.text})")
        out = str(e.val)
    elif kind == "expr":
        e = int_expr(rng, ty, 2, [])
        stmts.append(f"result: atom <- {pr(ty)}({e.text})")
        out = str(e.val)
    elif kind == "var":
        e = int_expr(rng, ty, 1, [])
        nm = rng.choice(["x", "value", "n", "amount"])
        names = [nm]
        stmts.append(f"{nm}: {ty} <- {e.text}")
        e2 = int_expr(rng, ty, 1, [(nm, e.val)])
        if not re.search(r"\b" + nm + r"\b", e2.text):
            e2 = E(nm, e.val) if rng.random() < 0.5 else E(f"{nm} + {e2.text}", e.val + e2.val, 2)
        stmts.append(f"result: atom <- {pr(ty)}({e2.text})")
        out = str(e2.val)
    elif kind == "ignore":
        e = int_expr(rng, ty, 1, [])
        stmts.append(f"_: atom <- {pr(ty)}({e.text})")
        out = str(e.val)
        prod = ":ok"
    else:
        a = int_expr(rng, ty, 1, [])
        b = int_expr(rng, ty, 1, [])
        names = ["a", "b"]
        stmts.append(f"a: {ty} <- {a.text}")
        stmts.append(f"b: {ty} <- {b.text}")
        stmts.append(f"_: atom <- {pr(ty)}(a)")
        stmts.append("println(\"\")")
        stmts.append(f"result: atom <- {pr(ty)}(b)")
        out = f"{a.val}\n{b.val}"
    body = seq_block(["device_io"], stmts, prod, style)
    hdr = f"// {pr(ty)} {kind}; prints {out.replace(chr(10), ' then ')}"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    exit_code = 2 if prod == ":ok" else 0
    c = Case(area, "print", src, out, exit_code)
    c.info["names"] = names
    c.info["fnames"] = [pr(ty)]
    c.info["has_seq"] = True
    # print outside a sequence (E3001)
    inner = stmts[-1].split("<- ", 1)[1]
    if kind in ("literal", "expr", "ignore"):
        c.add_fail("E3001", f"{pr(ty)} called outside any sequence block",
                   program(f"fn main() -> atom {{\n    {inner}\n}}", header=hdr))
    # wrong print width
    other = rng.choice([t for t in INT_TYPES if t != ty])
    if kind == "var":
        c.add_fail("E2003", f"{nm} is {ty} but passed to {pr(other)}",
                   rep(src, f"{pr(ty)}({e2.text})", f"{pr(other)}({e2.text})") if e2.text == nm else None)
    c.add_fail("E2001", f"string literal passed to {pr(ty)}",
               rep(src, f"{pr(ty)}({e.text})", f'{pr(ty)}("{e.val}")', 1) if kind in ("literal", "expr", "ignore") else None)
    return c


def t_int_compare(rng, ty, area):
    ops = ["<", "<=", ">", ">=", "==", "!="]
    n = rng.randint(2, 5)
    stmts, outs = [], []
    for i in range(n):
        a = int_expr(rng, ty, 1, [])
        b = int_expr(rng, ty, 1, [])
        op = rng.choice(ops)
        val = eval(f"{a.val} {op} {b.val}")
        stmts.append(f"_: atom <- print_boolean({a.wrap(3)} {op} {b.wrap(3)})")
        stmts.append('println("")')
        outs.append("true" if val else "false")
    stmts[-2] = stmts[-2].replace("_: atom", "result: atom")
    stmts.pop()
    body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
    out = "\n".join(outs)
    hdr = f"// {ty} comparisons printed with print_boolean"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "compare", src, out, 0)
    c.info["fnames"] = ["print_boolean"]
    c.info["has_seq"] = True
    # chained comparison is non-associative
    c.add_fail("E2003", "comparison against a string binding",
               rep(src, "sequence proc[device_io]", "sequence proc[device_io]\n        label: string <- \"x\";", 1).replace("print_boolean(", "print_boolean(label == ", 1))
    return c


def t_int_helper(rng, ty, area):
    nparams = rng.randint(1, 3)
    pnames = ["x", "y", "z"][:nparams]
    fname = rng.choice(["combine", "scale", "mix", "compute", "adjust", "blend"])
    vals = [rng.randint(1, 20) for _ in range(nparams)]
    env = list(zip(pnames, vals))
    body = int_expr(rng, ty, 2, env)
    tries = 0
    while not (0 <= body.val <= 255 and all(re.search(r"\b" + p + r"\b", body.text) for p in pnames)) and tries < 40:
        body = int_expr(rng, ty, 2, env)
        tries += 1
    if tries >= 40:
        return None
    helper = fn_decl(fname, [(p, ty) for p in pnames], ty, [], body.text)
    call = f"{fname}({', '.join(str(v) for v in vals)})"
    hdr = f"// helper {fname}/{nparams} on {ty}; {call} = {body.val}"
    src = program(helper, fn_decl("main", [], ty, [], call), header=hdr)
    c = Case(area, "helper", src, "", body.val & 0xFF)
    c.info["fnames"] = [fname]
    c.info["calls"] = [(fname, nparams)]
    c.info["names"] = pnames
    c.info["ret"] = ty
    other = rng.choice([t for t in INT_TYPES if t != ty])
    c.add_fail("E2003", f"parameter {pnames[0]} declared {other} in a {ty} helper",
               rep(src, f"{pnames[0]}: {ty}", f"{pnames[0]}: {other}", 1))
    c.add_fail("E2001", "string literal passed where an integer parameter is expected",
               rep(src, call, call.replace(str(vals[0]), f'"{vals[0]}"', 1), 1))
    c.add_fail("E3010", f"{fname} given nine parameters", m_nine_params(src, rng, fname))
    return c


def t_int_case(rng, ty, area):
    x = rng.randint(0, 40)
    k = rng.randint(1, 4)
    lits = rng.sample(range(0, 45), k)
    results = [rng.randint(0, 200) for _ in lits]
    default = rng.randint(0, 200)
    clauses = [f"{l} -> {r}" for l, r in zip(lits, results)]
    use_guard = rng.random() < 0.5
    if use_guard:
        g = rng.randint(1, 40)
        gr = rng.randint(0, 200)
        clauses.append(f"n: {ty} if n > {g} -> {gr}")
    clauses.append(f"_: {ty} -> {default}")
    if x in lits:
        val = results[lits.index(x)]
    elif use_guard and x > g:
        val = gr
    else:
        val = default
    body = ["v: " + ty + f" <- {x};"]
    tail = "case v of {\n        " + ";\n        ".join(clauses) + "\n    }"
    hdr = f"// case on {ty} value {x}; expect {val}"
    src = program(fn_decl("main", [], ty, body, tail), header=hdr)
    c = Case(area, "case", src, "", val & 0xFF)
    c.info["names"] = ["v"]
    c.info["case_scrut"] = ty
    c.add_fail("E2005", "string literal pattern against an integer scrutinee", m_case_bad_pattern(src, rng, ty))
    c.add_fail("E2001", "string literal in one case arm of an integer case",
               rep(src, f"{lits[0]} -> {results[0]}", f'{lits[0]} -> "{results[0]}"', 1))
    return c


def t_int_recursive(rng, ty, area):
    kind = rng.choice(["sum_to", "count_down", "power2", "triangular_acc", "digits"])
    fname = {"sum_to": "sum_to", "count_down": "steps", "power2": "pow2", "triangular_acc": "tri_acc", "digits": "digit_count"}[kind]
    if kind == "sum_to":
        n = rng.randint(1, 20)
        val = n * (n + 1) // 2
        f = fn_decl(fname, [("n", ty)], ty, [], f"case n == 0 of {{\n        true -> 0;\n        false -> n + {fname}(n - 1)\n    }}")
        call = f"{fname}({n})"
    elif kind == "count_down":
        n = rng.randint(1, 60)
        val = n
        f = fn_decl(fname, [("n", ty), ("acc", ty)], ty, [], f"case n == 0 of {{\n        true -> acc;\n        false -> {fname}(n - 1, acc + 1)\n    }}")
        call = f"{fname}({n}, 0)"
    elif kind == "power2":
        n = rng.randint(0, 6)
        val = 2 ** n
        f = fn_decl(fname, [("n", ty)], ty, [], f"case n == 0 of {{\n        true -> 1;\n        false -> 2 * {fname}(n - 1)\n    }}")
        call = f"{fname}({n})"
    elif kind == "triangular_acc":
        n = rng.randint(1, 20)
        val = n * (n + 1) // 2
        f = fn_decl(fname, [("n", ty), ("acc", ty)], ty, [], f"case n == 0 of {{\n        true -> acc;\n        false -> {fname}(n - 1, acc + n)\n    }}")
        call = f"{fname}({n}, 0)"
    else:
        n = rng.randint(1, 120)
        val = len(str(n))
        f = fn_decl(fname, [("n", ty)], ty, [], f"case n < 10 of {{\n        true -> 1;\n        false -> 1 + {fname}(n / 10)\n    }}")
        call = f"{fname}({n})"
    if not (INT_RANGE[ty][0] <= val <= INT_RANGE[ty][1]) or val > 255:
        return None
    hdr = f"// recursive {fname} on {ty}; {call} = {val}"
    src = program(f, fn_decl("main", [], ty, [], call), header=hdr)
    c = Case(area, "recur", src, "", val & 0xFF)
    c.info["fnames"] = [fname]
    c.info["calls"] = [(fname, call.count(",") + 1)]
    c.info["names"] = ["n", "acc"] if "acc" in f else ["n"]
    c.add_fail("E2005", "boolean case missing its false branch", m_case_drop_false(src, rng))
    c.add_fail("E2001", "atom literal returned from the recursion base case",
               rep(src, "true -> 0;", "true -> :zero;", 1).replace("true -> 1;", "true -> :one;", 1).replace("true -> acc;", "true -> :done;", 1))
    return c


def t_int_chain_print(rng, ty, area):
    n = rng.randint(2, 4)
    stmts, outs = [], []
    for i in range(n):
        e = int_expr(rng, ty, rng.randint(0, 2), [])
        if i == n - 1:
            stmts.append(f"result: atom <- {pr(ty)}({e.text})")
        else:
            stmts.append(f"_: atom <- {pr(ty)}({e.text})")
            stmts.append('println("")')
        outs.append(str(e.val))
    body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
    hdr = f"// chained {pr(ty)} calls separated by println"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "chain", src, "\n".join(outs), 0)
    c.info["fnames"] = [pr(ty), "println"]
    c.info["has_seq"] = True
    c.add_fail("E2003", f"{pr(ty)} result bound as int64 instead of atom", m_bind_print_result_int(src, rng))
    return c


# ---------------------------------------------------------------------------
# floats
# ---------------------------------------------------------------------------

def frac_lit(rng, ty, mag=40):
    steps = [Fraction(1, 2), Fraction(1, 4), Fraction(1, 8)] if ty != "float16" else [Fraction(1, 2), Fraction(1, 4)]
    for _ in range(50):
        ip = rng.randint(0, mag)
        fp = rng.choice(steps) * rng.randint(0, 3)
        v = ip + fp
        if float_exact(v, ty):
            return v
    return Fraction(1, 2)


def float_expr(rng, ty, depth):
    for _ in range(80):
        e = _float_expr(rng, ty, depth)
        if e is not None:
            return e
    v = frac_lit(rng, ty)
    return E(flit(v), v)


def _float_expr(rng, ty, depth):
    if depth == 0 or rng.random() < 0.3:
        v = frac_lit(rng, ty)
        return E(flit(v), v)
    op = rng.choice(["+", "+", "-", "*", "/"])
    a = _float_expr(rng, ty, depth - 1)
    b = _float_expr(rng, ty, depth - 1)
    if a is None or b is None:
        return None
    if op == "+":
        val = a.val + b.val
    elif op == "-":
        val = a.val - b.val
    elif op == "*":
        val = a.val * b.val
    else:
        if b.val == 0:
            return None
        val = a.val / b.val
    if not float_exact(val, ty):
        return None
    p = PREC[op]
    lt = a.wrap(p)
    rt = b.wrap(p + 1)
    return E(f"{lt} {op} {rt}", val, p)


def gen_float_area(rng, ty, count):
    area = f"{ty}_addition"
    cases = []
    makers = [t_float_print, t_float_bind_print, t_float_exit, t_float_compare, t_float_helper, t_float_negate]
    for i in range(count):
        c = makers[i % len(makers)](rng, ty, area)
        if c:
            cases.append(c)
    return cases


def t_float_print(rng, ty, area):
    e = float_expr(rng, ty, rng.randint(0, 2))
    out = fmt_float(e.val, ty)
    style = rng.randint(0, 2)
    ignore = rng.random() < 0.3
    if ignore:
        stmts = [f"_: atom <- {pr(ty)}({e.text})"]
        prod, ex = ":ok", 2
    else:
        stmts = [f"result: atom <- {pr(ty)}({e.text})"]
        prod, ex = "result", 0
    body = seq_block(["device_io"], stmts, prod, style)
    hdr = f"// {pr(ty)} of {e.text}; prints {out}"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "print", src, out, ex)
    c.info["fnames"] = [pr(ty)]
    c.info["has_seq"] = True
    c.add_fail("E3001", f"{pr(ty)} called outside a sequence block",
               program(f"fn main() -> atom {{\n    {pr(ty)}({e.text})\n}}", header=hdr))
    c.add_fail("E2001", f"boolean literal passed to {pr(ty)}", rep(src, f"{pr(ty)}({e.text})", f"{pr(ty)}(true)", 1))
    return c


def t_float_bind_print(rng, ty, area):
    a = frac_lit(rng, ty)
    b = frac_lit(rng, ty)
    op = rng.choice(["+", "-", "*"])
    val = {"+": a + b, "-": a - b, "*": a * b}[op]
    if not float_exact(val, ty):
        return None
    out = fmt_float(val, ty)
    stmts = [f"a: {ty} <- {flit(a)}", f"b: {ty} <- {flit(b)}", f"result: atom <- {pr(ty)}(a {op} b)"]
    body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
    hdr = f"// {ty} bindings {flit(a)} {op} {flit(b)} printed as {out}"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "bind", src, out, 0)
    c.info["names"] = ["a", "b"]
    c.info["fnames"] = [pr(ty)]
    c.info["has_seq"] = True
    other = rng.choice([t for t in FLOAT_TYPES if t != ty])
    c.add_fail("E2003", f"a declared {other} but combined with a {ty} value",
               rep(src, f"a: {ty} <-", f"a: {other} <-", 1))
    c.add_fail("E2003", "integer binding mixed into float arithmetic",
               rep(src, f"b: {ty} <- {flit(b)}", f"b: int64 <- {int(b)}", 1))
    return c


def t_float_exit(rng, ty, area):
    e = float_expr(rng, ty, rng.randint(1, 2))
    if not (0 <= e.val < 200):
        return None
    hdr = f"// main returns {ty}; exit code is trunc({e.text}) = {int(e.val)}"
    src = program(fn_decl("main", [], ty, [], e.text), header=hdr)
    c = Case(area, "exit", src, "", int(e.val) & 0xFF)
    c.add_fail("E2001", f"atom literal returned from a {ty} function", rep(src, e.text + "\n}", ":done\n}"))
    return c


def t_float_compare(rng, ty, area):
    n = rng.randint(2, 4)
    stmts, outs = [], []
    for i in range(n):
        a = float_expr(rng, ty, 1)
        b = float_expr(rng, ty, 1)
        op = rng.choice(["<", "<=", ">", ">=", "==", "!="])
        val = eval(f"a.val {op} b.val")
        stmts.append(f"_: atom <- print_boolean({a.wrap(3)} {op} {b.wrap(3)})")
        stmts.append('println("")')
        outs.append("true" if val else "false")
    stmts[-2] = stmts[-2].replace("_: atom", "done: atom")
    stmts.pop()
    body = seq_block(["device_io"], stmts, "done", rng.randint(0, 2))
    hdr = f"// {ty} comparisons"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "compare", src, "\n".join(outs), 0)
    c.info["fnames"] = ["print_boolean"]
    c.info["has_seq"] = True
    return c


def t_float_helper(rng, ty, area):
    fname = rng.choice(["half_sum", "scale", "shift", "blend", "combine"])
    a = frac_lit(rng, ty)
    b = frac_lit(rng, ty)
    k = frac_lit(rng, ty, 4)
    op = rng.choice(["+", "-", "*"])
    val = {"+": a + b, "-": a - b, "*": a * b}[op]
    val2 = val + k
    if not (float_exact(val, ty) and float_exact(val2, ty)):
        return None
    helper = fn_decl(fname, [("x", ty)], ty, [], f"x {op} {flit(b)} + {flit(k)}")
    out = fmt_float(val2, ty)
    stmts = [f"result: atom <- {pr(ty)}({fname}({flit(a)}))"]
    body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
    hdr = f"// {ty} helper {fname}; prints {out}"
    src = program(helper, f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "helper", src, out, 0)
    c.info["fnames"] = [fname, pr(ty)]
    c.info["calls"] = [(fname, 1)]
    c.info["names"] = ["x"]
    c.info["has_seq"] = True
    other = rng.choice([t for t in FLOAT_TYPES if t != ty])
    c.add_fail("E2003", f"{fname} returns {other} but its result feeds {pr(ty)}",
               rep(src, f") -> {ty} {{", f") -> {other} {{", 1))
    return c


def t_float_negate(rng, ty, area):
    v = frac_lit(rng, ty)
    depth = rng.choice([1, 2, 3])
    text = flit(v)
    val = v
    for _ in range(depth):
        text = f"negate_{ty}({text})"
        val = -val
    out = fmt_float(val, ty)
    stmts = [f"result: atom <- {pr(ty)}({text})"]
    body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
    hdr = f"// negate_{ty} applied {depth} time(s); prints {out}"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "negate", src, out, 0)
    c.info["fnames"] = [f"negate_{ty}", pr(ty)]
    c.info["has_seq"] = True
    c.add_fail("E2013", "unary minus written instead of negate_" + ty,
               rep(src, text, "-(" + flit(v) + ")", 1) if depth == 1 else None)
    return c


# ---------------------------------------------------------------------------
# negation_addition
# ---------------------------------------------------------------------------

def gen_negation(rng, count):
    area = "negation_addition"
    cases = []
    for i in range(count):
        ty = rng.choice(["int8", "int16", "int32", "int64"] + FLOAT_TYPES)
        if ty in FLOAT_TYPES:
            c = t_float_negate(rng, ty, area)
        else:
            c = t_int_negate(rng, ty, area)
        if c:
            cases.append(c)
    return cases


def t_int_negate(rng, ty, area):
    kind = rng.choice(["literal", "variable", "double", "triple", "compare", "exit"])
    lo, hi = INT_RANGE[ty]
    v = rng.randint(1, min(100, hi))
    neg = rng.random() < 0.4
    if neg:
        v = -v
    nf = f"negate_{ty}"
    if kind == "exit":
        vv = -v if v < 0 else v
        # negate a negative literal via binding so that main's exit is positive
        lines = [f"x: {ty} <- {-vv};"]
        hdr = f"// {nf} of a negative binding gives exit code {vv}"
        src = program(fn_decl("main", [], ty, lines, f"{nf}(x)"), header=hdr)
        c = Case(area, "negexit", src, "", vv & 0xFF)
        c.info["names"] = ["x"]
        c.info["fnames"] = [nf]
        c.add_fail("E2013", "unary minus used instead of " + nf, rep(src, f"{nf}(x)", "-x", 1))
        c.add_fail("E2005", f"{nf} misspelled", rep(src, f"{nf}(x)", f"{nf}_value(x)", 1))
        return c
    if kind == "literal":
        expr, val = f"{nf}({v})", -v
    elif kind == "variable":
        expr, val = f"{nf}(x)", -v
    elif kind == "double":
        expr, val = f"{nf}({nf}({v}))", v
    elif kind == "triple":
        expr, val = f"{nf}({nf}({nf}({v})))", -v
    else:
        expr, val = f"print_boolean({nf}({nf}({v})) == {v})", None
    stmts = []
    if kind == "variable":
        stmts.append(f"x: {ty} <- {v}")
    if kind == "compare":
        stmts.append(f"result: atom <- {expr}")
        out = "true"
    else:
        stmts.append(f"result: atom <- {pr(ty)}({expr})")
        out = str(val)
    body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
    hdr = f"// {nf} {kind}; prints {out}"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "neg" + kind, src, out, 0)
    c.info["names"] = ["x"] if kind == "variable" else []
    c.info["fnames"] = [nf, pr(ty)]
    c.info["has_seq"] = True
    if kind == "variable":
        c.add_fail("E2013", "unary minus used instead of " + nf, rep(src, f"{nf}(x)", "-x", 1))
    uty = rng.choice(["uint8", "uint16", "uint32", "uint64"])
    c.add_fail("E2005", f"negate_{uty} does not exist", rep(src, nf + "(", f"negate_{uty}(", 1).replace(pr(ty), pr(uty)))
    return c


# ---------------------------------------------------------------------------
# bitwise_addition
# ---------------------------------------------------------------------------

M64 = (1 << 64) - 1


def gen_bitwise(rng, count):
    area = "bitwise_addition"
    cases = []
    for i in range(count):
        c = [t_bit_expr, t_bit_shift, t_bit_mask, t_bit_print][i % 4](rng, area)
        if c:
            cases.append(c)
    return cases


def t_bit_expr(rng, area):
    names = rng.sample(["one", "two", "three", "five", "seven", "mask", "bits", "flags", "lo", "hi"], 3)
    vals = [rng.randint(1, 15) for _ in names]
    lines = [f"{n}: uint64 <- {v};" for n, v in zip(names, vals)]
    op1, op2 = rng.choice(["bor", "band"]), rng.choice(["bor", "band", "+"])
    a, b, cc = names
    av, bv, cv = vals
    useneg = rng.random() < 0.4
    if useneg:
        left = f"((bnot {a}) band {b})"
        lv = (~av & M64) & bv
    else:
        left = f"({a} {op1} {b})"
        lv = (av | bv) if op1 == "bor" else (av & bv)
    if op2 == "+":
        text, val = f"({left} + {cc})", lv + cv
    elif op2 == "bor":
        text, val = f"{left} bor {cc}", lv | cv
    else:
        text, val = f"{left} band {cc}", lv & cv
    if val > 255:
        return None
    hdr = f"// uint64 bitwise: {text} = {val}"
    src = program(fn_decl("main", [], "uint64", lines, text), header=hdr)
    c = Case(area, "bitexpr", src, "", val)
    c.info["names"] = names
    c.add_fail("E2001", "boolean literal used as a bitwise operand", rep(src, f"{a}: uint64 <- {av}", f"{a}: uint64 <- true", 1))
    return c


def t_bit_shift(rng, area):
    one = rng.randint(1, 7)
    s1 = rng.randint(0, 5)
    big = rng.randint(16, 200)
    s2 = rng.randint(1, 4)
    val = (one << s1) + (big >> s2)
    if val > 255:
        return None
    lines = [f"seed: uint64 <- {one};", f"wide: uint64 <- {big};"]
    text = f"(seed shl {s1}) + (wide shr {s2})"
    hdr = f"// shifts: {text} = {val}"
    src = program(fn_decl("main", [], "uint64", lines, text), header=hdr)
    c = Case(area, "shift", src, "", val)
    c.info["names"] = ["seed", "wide"]
    bad = rng.choice([64, 65, 100])
    c.add_fail("E2003", f"shift amount literal {bad} is out of range 0..63", rep(src, f"shl {s1}", f"shl {bad}", 1))
    return c


def t_bit_mask(rng, area):
    idx = rng.randint(0, 20)
    lines = ["one: uint64 <- 1;", "zero: uint64 <- 0;", f"bit_index: int64 <- {idx};",
             "mask: uint64 <- one shl bit_index;", "word: uint64 <- zero bor mask;",
             "present: uint64 <- (word band mask) shr bit_index;", "cleared: uint64 <- word band (bnot mask);"]
    hdr = f"// set, test and clear bit {idx} of a uint64 word; expect 1"
    src = program(fn_decl("main", [], "uint64", lines, "present + cleared"), header=hdr)
    c = Case(area, "mask", src, "", 1)
    c.info["names"] = ["one", "zero", "bit_index", "mask", "word", "present", "cleared"]
    c.add_fail("E2003", "shift amount taken from a boolean binding", rep(src, f"bit_index: int64 <- {idx}", "bit_index: boolean <- true", 1))
    return c


def t_bit_print(rng, area):
    a, b = rng.randint(1, 60), rng.randint(1, 60)
    op = rng.choice(["bor", "band"])
    val = (a | b) if op == "bor" else (a & b)
    stmts = [f"a: uint64 <- {a}", f"b: uint64 <- {b}", f"result: atom <- print_uint64(a {op} b)"]
    body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
    hdr = f"// print_uint64 of {a} {op} {b} = {val}"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "bitprint", src, str(val), 0)
    c.info["names"] = ["a", "b"]
    c.info["fnames"] = ["print_uint64"]
    c.info["has_seq"] = True
    c.add_fail("E2001", "boolean literal bound to a uint64 operand", rep(src, f"a: uint64 <- {a}", "a: uint64 <- true", 1))
    return c


# ---------------------------------------------------------------------------
# boolean_addition
# ---------------------------------------------------------------------------

def gen_boolean(rng, count):
    area = "boolean_addition"
    cases = []
    for i in range(count):
        c = [t_bool_logic, t_bool_exit, t_bool_case, t_bool_compare][i % 4](rng, area)
        if c:
            cases.append(c)
    return cases


def t_bool_logic(rng, area):
    a, b = rng.choice([True, False]), rng.choice([True, False])
    op = rng.choice(["and", "or"])
    val = (a and b) if op == "and" else (a or b)
    lit = lambda x: "true" if x else "false"
    kind = rng.choice(["vars", "literals"])
    if kind == "vars":
        stmts = [f"b: boolean <- {lit(a)}", f"a: boolean <- {lit(b)}", f"result: boolean <- b {op} a", "outcome: atom <- print_boolean(result)"]
        names = ["a", "b", "result"]
    else:
        stmts = [f"result: boolean <- {lit(a)} {op} {lit(b)}", "outcome: atom <- print_boolean(result)"]
        names = ["result"]
    body = seq_block(["device_io"], stmts, "outcome", rng.randint(0, 2))
    hdr = f"// {lit(a)} {op} {lit(b)} printed"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "logic", src, lit(val), 0)
    c.info["names"] = names
    c.info["fnames"] = ["print_boolean"]
    c.info["has_seq"] = True
    c.add_fail("E2001", "integer literal bound to a boolean", rep(src, f"result: boolean <- ", "result: boolean <- 1 + 0 * 1 and ", 1) if kind == "literals" else rep(src, f"b: boolean <- {lit(a)}", "b: boolean <- 1", 1))
    return c


def t_bool_exit(rng, area):
    v = rng.choice([True, False])
    e = rng.choice([("true", True), ("false", False), ("3 < 5", True), ("7 == 8", False), ("true and false", False), ("false or true", True), ("10 >= 10", True)])
    hdr = f"// main returns boolean {e[0]}; exit code {int(e[1])}"
    src = program(fn_decl("main", [], "boolean", [], e[0]), header=hdr)
    c = Case(area, "boolexit", src, "", 1 if e[1] else 0)
    c.add_fail("E2001", "integer literal returned from a boolean function", rep(src, e[0] + "\n}", "1\n}"))
    return c


def t_bool_case(rng, area):
    v = rng.choice([True, False])
    t, f = rng.randint(0, 100), rng.randint(0, 100)
    lit = "true" if v else "false"
    lines = [f"flag: boolean <- {lit};"]
    tail = f"case flag of {{\n        true -> {t};\n        false -> {f}\n    }}"
    hdr = f"// case on a boolean binding; expect {t if v else f}"
    src = program(fn_decl("main", [], "int64", lines, tail), header=hdr)
    c = Case(area, "boolcase", src, "", (t if v else f) & 0xFF)
    c.info["names"] = ["flag"]
    c.add_fail("E2005", "boolean case covers only true", m_case_drop_false(src, rng))
    c.add_fail("E2005", "integer pattern against a boolean scrutinee", rep(src, "true ->", "1 ->", 1))
    return c


def t_bool_compare(rng, area):
    a, b = rng.randint(0, 30), rng.randint(0, 30)
    op = rng.choice(["<", "<=", ">", ">=", "==", "!="])
    val = eval(f"{a} {op} {b}")
    stmts = [f"result: atom <- print_boolean({a} {op} {b})"]
    body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
    hdr = f"// print_boolean({a} {op} {b})"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "boolcmp", src, "true" if val else "false", 0)
    c.info["fnames"] = ["print_boolean"]
    c.info["has_seq"] = True
    return c


# ---------------------------------------------------------------------------
# atoms_addition
# ---------------------------------------------------------------------------

SEEDED = ["efficiency", "performance", "ok", "normal", "language_error", "memory_fault", "explicit", "unknown",
          "noproc", "permanent", "transient", "temporary", "one_for_one", "one_for_all", "rest_for_one", "insert",
          "lookup", "delete", "found", "not_found", "unknown_op", "plain", "dangerous"]
USER_ATOMS = ["red", "green", "blue", "ready", "pending", "done", "start", "stop", "alpha", "beta", "gamma",
              "left", "right", "up", "down", "fail", "retry", "idle", "busy", "cold", "warm", "hot"]


def gen_atoms(rng, count):
    area = "atoms_addition"
    cases = []
    for i in range(count):
        c = [t_atom_print, t_atom_case, t_atom_eq, t_atom_return][i % 4](rng, area)
        if c:
            cases.append(c)
    return cases


def t_atom_print(rng, area):
    a = rng.choice(USER_ATOMS)
    kind = rng.choice(["direct", "bound"])
    if kind == "direct":
        stmts = [f"result: atom <- print_atom(:{a})"]
        names = []
    else:
        stmts = [f"state: atom <- :{a}", "result: atom <- print_atom(state)"]
        names = ["state"]
    body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
    hdr = f"// print_atom prints the atom with its colon: :{a}"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "atomprint", src, f":{a}", 0)
    c.info["names"] = names
    c.info["fnames"] = ["print_atom"]
    c.info["has_seq"] = True
    c.add_fail("E2001", "string literal passed to print_atom", rep(src, f"print_atom(:{a})", f'print_atom("{a}")', 1) if kind == "direct" else None)
    c.add_fail("E2001", "string bound to an atom binding", rep(src, f"state: atom <- :{a}", f'state: atom <- "{a}"', 1) if kind == "bound" else None)
    return c


def t_atom_case(rng, area):
    atoms = rng.sample(USER_ATOMS, 3)
    pick = rng.choice(atoms)
    results = [rng.randint(0, 100) for _ in atoms]
    default = rng.randint(0, 100)
    val = results[atoms.index(pick)]
    clauses = [f":{a} -> {r}" for a, r in zip(atoms, results)] + [f"_: atom -> {default}"]
    lines = [f"mode: atom <- :{pick};"]
    tail = "case mode of {\n        " + ";\n        ".join(clauses) + "\n    }"
    hdr = f"// case over atoms; :{pick} selects {val}"
    src = program(fn_decl("main", [], "int64", lines, tail), header=hdr)
    c = Case(area, "atomcase", src, "", val & 0xFF)
    c.info["names"] = ["mode"]
    c.info["case_scrut"] = "atom"
    c.add_fail("E2005", "integer pattern against an atom scrutinee", m_case_bad_pattern(src, rng, "atom"))
    return c


def t_atom_eq(rng, area):
    a, b = rng.sample(USER_ATOMS, 2)
    same = rng.random() < 0.5
    rhs = a if same else b
    op = rng.choice(["==", "!="])
    val = (a == rhs) if op == "==" else (a != rhs)
    stmts = [f"left: atom <- :{a}", f"result: atom <- print_boolean(left {op} :{rhs})"]
    body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
    hdr = f"// atom identity: :{a} {op} :{rhs} is {str(val).lower()}"
    src = program(f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "atomeq", src, "true" if val else "false", 0)
    c.info["names"] = ["left"]
    c.info["fnames"] = ["print_boolean"]
    c.info["has_seq"] = True
    c.add_fail("E2003", "atom compared against an integer binding", rep(src, f"left: atom <- :{a}", "left: int64 <- 3", 1))
    return c


def t_atom_return(rng, area):
    kind = rng.choice(["ok", "seeded", "helper"])
    if kind == "ok":
        src = program(fn_decl("main", [], "atom", [], ":ok"), header="// main returns :ok; exit code is its atom index 2")
        c = Case(area, "atomret", src, "", 2)
        c.add_fail("E1044", "space between ':' and the atom name", rep(src, ":ok", ": ok"))
        return c
    if kind == "seeded":
        a = rng.choice(SEEDED[:23])
        idx = SEEDED.index(a)
        src = program(fn_decl("main", [], "atom", [], f":{a}"), header=f"// main returns the runtime-seeded atom :{a}; exit code {idx}")
        c = Case(area, "atomret", src, "", idx)
        c.add_fail("E2001", "integer literal returned from an atom function", rep(src, f":{a}\n}}", f"{idx}\n}}"))
        return c
    a = rng.choice(USER_ATOMS)
    f = fn_decl("status", [("n", "int64")], "atom", [], f"case n > 0 of {{\n        true -> :ok;\n        false -> :{a}\n    }}")
    n = rng.randint(1, 9)
    src = program(f, fn_decl("main", [], "atom", [], f"status({n})"), header="// helper returning :ok for positive input")
    c = Case(area, "atomhelper", src, "", 2)
    c.info["fnames"] = ["status"]
    c.info["calls"] = [("status", 1)]
    c.info["names"] = ["n"]
    c.add_fail("E2001", "integer returned from an atom-typed helper arm", rep(src, f"false -> :{a}", "false -> 0", 1))
    return c
