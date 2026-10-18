"""Generators for actors_addition, memory_region_addition, modules_addition,
traits_addition, supervisors_addition."""
import os
import random
from common import *
from data import s_lit, WORDS, L


def gen_all(rng, q):
    cases = []
    cases += gen_actors(rng, q(170))
    cases += gen_memory(rng, q(170))
    cases += gen_modules(rng, q(120))
    cases += gen_traits(rng, q(150))
    cases += gen_supervisors(rng, q(40))
    return cases


def ints(rng, n, lo=0, hi=40):
    return [rng.randint(lo, hi) for _ in range(n)]


# ---------------------------------------------------------------------------
# actors_addition (single file; only synchronous call patterns for determinism)
# ---------------------------------------------------------------------------

def gen_actors(rng, count):
    area = "actors_addition"
    makers = [t_act_counter, t_act_atom_protocol, t_act_cast_then_call, t_act_two_actors, t_act_string_reply, t_act_chain_calls, t_act_self_ref]
    cases = []
    for i in range(count):
        c = makers[i % len(makers)](rng, area)
        if c:
            c.info["runs"] = 3
            cases.append(c)
    return cases


def beh_reply(name, msg_ty, state_ty, reply_ty, expr_reply, expr_state, seq=None):
    return fn_decl(name, [("msg", msg_ty), ("state", state_ty)], f"(:reply, {reply_ty}, {state_ty})", [],
                   f"({':reply'}, {expr_reply}, {expr_state})" if seq is None else seq)


def t_act_counter(rng, area):
    init = rng.randint(0, 20)
    msgs = ints(rng, rng.randint(1, 4), 1, 20)
    f = beh_reply("acc", "int64", "int64", "int64", "msg + state", "msg + state")
    stmts = ["w: actor_ref <- spawn(%d, acc)" % init]
    total, outs = init, []
    for i, m in enumerate(msgs):
        total += m
        stmts.append(f"r{i}: int64 <- call(w, {m} impl ActorMessage {{}})")
        stmts.append(f"print_int64(r{i})")
        stmts.append('println("")')
        outs.append(str(total))
    body = seq_block(["concurrency", "device_io"], stmts, ":ok", 0)
    hdr = "// Spec §16.1.1: call(actor_ref, message) -> Reply; behavior returns (:reply, reply, new_state)"
    src = program(f, f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "counter", src, "\n".join(outs) + "\n", 2)
    c.info["names"] = ["w"] + [f"r{i}" for i in range(len(msgs))]
    c.info["fnames"] = ["acc"]
    c.info["has_seq"] = True
    c.add_fail("E2005", "message sent without the ActorMessage marker", rep(src, f"call(w, {msgs[0]} impl ActorMessage {{}})", f"call(w, {msgs[0]})", 1))
    c.add_fail("E3002", "spawn under a sequence that only declares device_io", rep(src, "proc[concurrency, device_io]", "proc[device_io]", 1))
    c.add_fail("E2005", "spawn called without a behavior function", rep(src, f"spawn({init}, acc)", f"spawn({init})", 1))
    return c


def t_act_atom_protocol(rng, area):
    init = rng.randint(0, 9)
    ops = [rng.choice(["peek", "bump", "bump", "reset"]) for _ in range(rng.randint(2, 5))]
    f = fn_decl("srv", [("msg", "atom"), ("state", "int64")], "(:reply, int64, int64)", [],
                "case msg of {\n        :peek -> (:reply, state, state);\n        :bump -> (:reply, state + 1, state + 1);\n        :reset -> (:reply, 0, 0);\n        _: atom -> (:reply, state, state)\n    }")
    stmts = [f"w: actor_ref <- spawn({init}, srv)"]
    st, outs = init, []
    for i, op in enumerate(ops):
        if op == "bump":
            st += 1
        elif op == "reset":
            st = 0
        stmts.append(f"p{i}: int64 <- call(w, (:{op}) impl ActorMessage {{}})")
        stmts.append(f"print_int64(p{i})")
        stmts.append('println("")')
        outs.append(str(st))
    body = seq_block(["concurrency", "device_io"], stmts, ":ok", 0)
    hdr = "// Atom-shaped messages dispatched by a case in the behavior (§15.1.2 call/reply)"
    src = program(f, f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "atomproto", src, "\n".join(outs) + "\n", 2)
    c.info["names"] = ["w"] + [f"p{i}" for i in range(len(ops))]
    c.info["fnames"] = ["srv"]
    c.info["has_seq"] = True
    c.add_fail("E2005", "string pattern against the atom message", rep(src, ":peek -> (:reply, state, state);", '"peek" -> (:reply, state, state);', 1))
    return c


def t_act_cast_then_call(rng, area):
    init = rng.randint(0, 9)
    k = rng.randint(1, 9)
    beh = fn_decl("sink", [("msg", "int64"), ("state", "int64")], "(:no_reply, int64)", [], "(:no_reply, state + msg)")
    stmts = [f"w: actor_ref <- spawn({init}, sink)", f"enqueued: boolean <- cast(w, {k} impl ActorMessage {{}})", "print_boolean(enqueued)", 'println("")']
    body = seq_block(["concurrency", "device_io"], stmts, ":ok", 0)
    hdr = "// Spec §16.1.2: cast enqueues asynchronously and returns boolean; behavior returns (:no_reply, new_state)"
    src = program(beh, f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "cast", src, "true\n", 2)
    c.info["names"] = ["w", "enqueued"]
    c.info["fnames"] = ["sink"]
    c.info["has_seq"] = True
    c.add_fail("E2005", "cast payload lacks the ActorMessage marker", rep(src, f"cast(w, {k} impl ActorMessage {{}})", f"cast(w, {k})", 1))
    c.add_fail("E3001", "spawn outside any sequence block", program(beh, f"fn main() -> atom {{\n    w: actor_ref <- spawn({init}, sink);\n    :ok\n}}", header=hdr))
    return c


def t_act_two_actors(rng, area):
    a0, b0 = ints(rng, 2, 0, 9)
    m1, m2 = ints(rng, 2, 1, 9)
    f = "\n\n".join([beh_reply("adder", "int64", "int64", "int64", "msg + state", "msg + state"),
                     beh_reply("doubler", "int64", "int64", "int64", "msg * 2", "state")])
    stmts = [f"a: actor_ref <- spawn({a0}, adder)", f"b: actor_ref <- spawn({b0}, doubler)",
             f"ra: int64 <- call(a, {m1} impl ActorMessage {{}})", f"rb: int64 <- call(b, {m2} impl ActorMessage {{}})",
             "print_int64(ra + rb)", 'println("")']
    body = seq_block(["concurrency", "device_io"], stmts, ":ok", 0)
    val = a0 + m1 + m2 * 2
    hdr = "// Spec §15.1.1: two actor_ref values from spawn; each replies independently"
    src = program(f, f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "twoactors", src, str(val) + "\n", 2)
    c.info["names"] = ["a", "b", "ra", "rb"]
    c.info["fnames"] = ["adder", "doubler"]
    c.info["has_seq"] = True
    c.add_fail("E2003", "reply bound to a string variable", rep(src, "ra: int64 <- call(a", "ra: string <- call(a", 1))
    return c


def t_act_record_state(rng, area):
    v0 = rng.randint(0, 9)
    ms = ints(rng, rng.randint(1, 3), 1, 9)
    f = fn_decl("tally", [("msg", "int64"), ("state", "{ v: int64, hits: int64 }")], "(:reply, int64, { v: int64, hits: int64 })", [],
                "(:reply, state.v + msg, { v: state.v + msg, hits: state.hits + 1 })")
    stmts = [f"w: actor_ref <- spawn({{ v: {v0}, hits: 0 }}, tally)"]
    tot, outs = v0, []
    for i, m in enumerate(ms):
        tot += m
        stmts.append(f"r{i}: int64 <- call(w, {m} impl ActorMessage {{}})")
        stmts.append(f"print_int64(r{i})")
        stmts.append('println("")')
        outs.append(str(tot))
    body = seq_block(["concurrency", "device_io"], stmts, ":ok", 0)
    hdr = "// Record-typed actor state updated on each call"
    src = program(f, f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "recstate", src, "\n".join(outs) + "\n", 2)
    c.info["names"] = ["w"] + [f"r{i}" for i in range(len(ms))]
    c.info["fnames"] = ["tally"]
    c.info["has_seq"] = True
    c.add_fail("E2005", "state field misspelled in the behavior", rep(src, "state.hits + 1", "state.hit + 1", 1))
    return c


def t_act_string_reply(rng, area):
    w = rng.choice(WORDS)
    f = fn_decl("echo", [("msg", "string"), ("state", "int64")], "(:reply, string, int64)", [], '(:reply, concatenate("echo: ", msg), state + 1)')
    stmts = ["e: actor_ref <- spawn(0, echo)", f"r: string <- call(e, {s_lit(w)} impl ActorMessage {{}})", "print_string(r)", 'println("")']
    body = seq_block(["concurrency", "device_io"], stmts, ":ok", 0)
    hdr = "// String message and string reply through call"
    src = program(f, f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "strreply", src, "echo: " + w + "\n", 2)
    c.info["names"] = ["e", "r"]
    c.info["fnames"] = ["echo"]
    c.info["has_seq"] = True
    c.add_fail("E2001", "integer message sent to a string-typed behavior", rep(src, f"{s_lit(w)} impl ActorMessage {{}}", "5 impl ActorMessage {}", 1))
    return c


def t_act_chain_calls(rng, area):
    n = rng.randint(2, 4)
    step = rng.randint(1, 5)
    f = beh_reply("step", "int64", "int64", "int64", "state + msg", "state + msg")
    stmts = ["w: actor_ref <- spawn(0, step)"]
    outs, st = [], 0
    for i in range(n):
        st += step
        stmts.append(f"v{i}: int64 <- call(w, {step} impl ActorMessage {{}})")
    stmts.append(f"print_int64(v{n - 1})")
    stmts.append('println("")')
    body = seq_block(["concurrency", "device_io"], stmts, ":ok", 0)
    hdr = "// Spec §16.1.3: repeated call() to the same actor preserves FIFO order"
    src = program(f, f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "chain", src, str(st) + "\n", 2)
    c.info["names"] = ["w"] + [f"v{i}" for i in range(n)]
    c.info["fnames"] = ["step"]
    c.info["has_seq"] = True
    c.add_fail("E2005", "behavior declared with a single parameter", rep(src, "fn step(msg: int64, state: int64)", "fn step(msg: int64)", 1).replace("(:reply, state + msg, state + msg)", "(:reply, msg, msg)", 1))
    return c


def t_act_self_ref(rng, area):
    k = rng.randint(1, 9)
    f = fn_decl("worker", [("msg", "int64"), ("state", "int64")], "(:reply, int64, int64)", [],
                f"sequence proc[device_io]\n        print_string(\"got \");\n        print_int64(msg);\n        println(\"\")\n    produces\n        pure (:reply, msg * {k}, state)\n    end")
    stmts = ["w: actor_ref <- spawn(0, worker)", "r: int64 <- call(w, 3 impl ActorMessage {})", "print_int64(r)", 'println("")']
    body = seq_block(["concurrency", "device_io"], stmts, ":ok", 0)
    hdr = "// Behavior prints inside its own sequence proc[device_io] before replying"
    src = program(f, f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "behio", src, f"got 3\n{3 * k}\n", 2)
    c.info["names"] = ["w", "r"]
    c.info["fnames"] = ["worker"]
    c.info["has_seq"] = True
    c.add_fail("E3001", "behavior prints without a sequence block",
               rep(src, f"sequence proc[device_io]\n        print_string(\"got \");\n        print_int64(msg);\n        println(\"\")\n    produces\n        pure (:reply, msg * {k}, state)\n    end",
                           f"print_int64(msg);\n    (:reply, msg * {k}, state)", 1))
    return c


# ---------------------------------------------------------------------------
# memory_region_addition
# ---------------------------------------------------------------------------

MEM_HDR = ("// Memory space S is explicit: `sequence proc[mem(S)]` matches `alloc_region(S)` and\n"
           "// `region(L1, S)` / `ref(L1, S, ...)` / `buf(...)` (same S throughout).")


def gen_memory(rng, count):
    area = "memory_region_addition"
    makers = [t_mem_ref_rw, t_mem_buf, t_mem_tuple_ref, t_mem_two_regions, t_mem_helper_region, t_mem_atomic, t_mem_ref_types, t_mem_loop]
    cases = []
    for i in range(count):
        c = makers[i % len(makers)](rng, area)
        if c:
            cases.append(c)
    return cases


def t_mem_ref_rw(rng, area):
    sp = rng.choice(["normal", "normal", "normal_writethrough", "normal_noncacheable", "normal_writeback"])
    v0, v1 = rng.randint(0, 100), rng.randint(0, 200)
    kind = rng.choice(["write", "read_only", "double_write"])
    stmts = ["L1: lifetime <- fresh_lifetime()", f"r: region(L1, {sp}) <- alloc_region({sp})", f"cell: ref(L1, {sp}, int64) <- alloc_ref(r, {v0})"]
    if kind == "write":
        stmts += [f"_: atom <- write_ref(cell, {v1})", "value: int64 <- read_ref(cell)"]
        val = v1
    elif kind == "read_only":
        stmts += ["value: int64 <- read_ref(cell)"]
        val = v0
    else:
        stmts += [f"_: atom <- write_ref(cell, {v1})", f"_: atom <- write_ref(cell, {v1 // 2})", "value: int64 <- read_ref(cell)"]
        val = v1 // 2
    body = seq_block([f"mem({sp})"], stmts, "value", 0)
    hdr = MEM_HDR + f"\n// Trial: {kind} on a ref in {sp}; expect {val}"
    src = program(f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "ref", src, "", val & 0xFF)
    c.info["names"] = ["r", "cell", "value"]
    c.info["fnames"] = ["alloc_ref", "read_ref", "write_ref", "alloc_region", "fresh_lifetime"]
    c.info["has_seq"] = True
    other = "normal" if sp != "normal" else "normal_writethrough"
    c.add_fail("E2003", "region declared in a different space than it is allocated in", rep(src, f"r: region(L1, {sp}) <- alloc_region({sp})", f"r: region(L1, {other}) <- alloc_region({sp})", 1))
    c.add_fail("E3002", "region operations under a device_io-only sequence", rep(src, f"proc[mem({sp})]", "proc[device_io]", 1))
    c.add_fail("E2001", "string written into an int64 ref", rep(src, f"alloc_ref(r, {v0})", f'alloc_ref(r, "{v0}")', 1))
    return c


def t_mem_buf(rng, area):
    cap = rng.randint(2, 16)
    idx = rng.randint(0, cap - 1)
    v = rng.randint(0, 200)
    runtime = rng.random() < 0.5
    if runtime:
        stmts = ["L1: lifetime <- fresh_lifetime()", "r: region(L1, normal) <- alloc_region(normal)", f"capacity: int64 <- {cap}", f"index: int64 <- {idx}",
                 "buf: buf(L1, normal, int64, capacity) <- alloc_buf(r, capacity)", f"_: atom <- write_buf(buf, index, {v})", "value: int64 <- read_buf(buf, index)"]
    else:
        stmts = ["L1: lifetime <- fresh_lifetime()", "r: region(L1, normal) <- alloc_region(normal)",
                 f"buf: buf(L1, normal, int64, {cap}) <- alloc_buf(r, {cap})", f"_: atom <- write_buf(buf, {idx}, {v})", f"value: int64 <- read_buf(buf, {idx})"]
    body = seq_block(["mem(normal)"], stmts, "value", 0)
    hdr = MEM_HDR + f"\n// Trial: alloc_buf with a {'runtime' if runtime else 'literal'} size, write/read round-trip at index {idx}"
    src = program(f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "buf", src, "", v & 0xFF)
    c.info["names"] = ["r", "buf", "value", "capacity", "index"]
    c.info["fnames"] = ["alloc_buf", "read_buf", "write_buf"]
    c.info["has_seq"] = True
    c.add_fail("E2001", "string index passed to write_buf", rep(src, f"write_buf(buf, index, {v})", f'write_buf(buf, "0", {v})', 1) if runtime else rep(src, f"write_buf(buf, {idx}, {v})", f'write_buf(buf, "{idx}", {v})', 1))
    return c


def t_mem_tuple_ref(rng, area):
    a, b, cc = ints(rng, 3, 0, 60)
    kind = rng.choice(["pair", "triple", "mixed"])
    if kind == "pair":
        tty, lit = "(int64, int64)", f"({a}, {b})"
        pat, expr, val = "(x: int64, y: int64) <- back", "x + y", a + b
    elif kind == "triple":
        tty, lit = "(int64, int64, int64)", f"({a}, {b}, {cc})"
        pat, expr, val = "(x: int64, y: int64, z: int64) <- back", "x + y + z", a + b + cc
    else:
        tty, lit = "(int64, boolean, float64)", f"({a}, true, 2.5)"
        pat, expr, val = "(x: int64, flag: boolean, f: float64) <- back", "case flag of { true -> x; false -> 0 }", a
    stmts = ["L1: lifetime <- fresh_lifetime()", "r: region(L1, normal) <- alloc_region(normal)", f"t: {tty} <- {lit}",
             f"cell: ref(L1, normal, {tty}) <- alloc_ref(r, t)", f"back: {tty} <- read_ref(cell)", pat]
    if kind == "mixed":
        stmts.append("_used_f: float64 <- f")
    stmts.append(f"value: int64 <- {expr}")
    body = seq_block(["mem(normal)"], stmts, "value", 0)
    hdr = MEM_HDR + f"\n// Trial: flat tuple stored in a ref and read back; expect {val}"
    src = program(f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "tupleref", src, "", val & 0xFF)
    c.info["names"] = ["r", "t", "cell", "back", "value", "x", "y"]
    c.info["fnames"] = ["alloc_ref", "read_ref"]
    c.info["has_seq"] = True
    c.add_fail("E2003", "ref declared with a different tuple shape than the value", rep(src, f"cell: ref(L1, normal, {tty})", "cell: ref(L1, normal, (int64, string))", 1))
    return c


def t_mem_two_regions(rng, area):
    a, b = ints(rng, 2, 0, 100)
    sp2 = rng.choice(["normal", "normal_writethrough"])
    effs = ["mem(normal)"] if sp2 == "normal" else ["mem(normal)", f"mem({sp2})"]
    stmts = ["L1: lifetime <- fresh_lifetime()", "L2: lifetime <- fresh_lifetime()",
             "r1: region(L1, normal) <- alloc_region(normal)", f"r2: region(L2, {sp2}) <- alloc_region({sp2})",
             f"c1: ref(L1, normal, int64) <- alloc_ref(r1, {a})", f"c2: ref(L2, {sp2}, int64) <- alloc_ref(r2, {b})",
             "v1: int64 <- read_ref(c1)", "v2: int64 <- read_ref(c2)"]
    body = seq_block(effs, stmts, "v1 + v2", 0)
    hdr = MEM_HDR + f"\n// Trial: two lifetimes and two regions; expect {a + b}"
    src = program(f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "tworegions", src, "", (a + b) & 0xFF)
    c.info["names"] = ["r1", "r2", "c1", "c2", "v1", "v2"]
    c.info["fnames"] = ["alloc_ref", "read_ref"]
    c.info["has_seq"] = True
    c.add_fail("E2003", "ref lifetime does not match its region", rep(src, "c2: ref(L2,", "c2: ref(L1,", 1))
    return c


def t_mem_helper_region(rng, area):
    n = rng.randint(1, 120)
    kind = rng.choice(["pass", "return"])
    if kind == "pass":
        f = fn_decl("consume", [("r", "region(L1, normal)"), ("n", "int64")], "int64", [],
                    "sequence proc[mem(normal)]\n        cell: ref(L1, normal, int64) <- alloc_ref(r, n)\n    produces\n        pure read_ref(cell)\n    end")
        stmts = ["L1: lifetime <- fresh_lifetime()", "r: region(L1, normal) <- alloc_region(normal)", f"v: int64 <- consume(r, {n})"]
    else:
        f = fn_decl("fill", [("r", "region(L1, normal)"), ("n", "int64")], "(region(L1, normal), ref(L1, normal, int64))", [],
                    "sequence proc[mem(normal)]\n        cell: ref(L1, normal, int64) <- alloc_ref(r, n)\n    produces\n        pure (r, cell)\n    end")
        stmts = ["L1: lifetime <- fresh_lifetime()", "r0: region(L1, normal) <- alloc_region(normal)", f"pair: (region(L1, normal), ref(L1, normal, int64)) <- fill(r0, {n})",
                 "(r1: region(L1, normal), cell: ref(L1, normal, int64)) <- pair", "_used_r1: region(L1, normal) <- r1", "v: int64 <- read_ref(cell)"]
    body = seq_block(["mem(normal)"], stmts, "v", 0)
    hdr = MEM_HDR + f"\n// NOTE: the lifetime is written L1, not a generic R -- the type checker compares type surfaces literally.\n// Trial: region handle {'moved into' if kind == 'pass' else 'passed to and returned from'} a helper; expect {n}"
    src = program(f, f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "helperregion", src, "", n)
    c.info["names"] = ["r", "v", "n", "cell"]
    c.info["fnames"] = ["consume", "fill"]
    c.info["calls"] = [("consume", 2), ("fill", 2)]
    c.info["has_seq"] = True
    c.add_fail("E2003", "helper parameter written with a generic lifetime R instead of L1", rep(src, "(r: region(L1, normal), n: int64)", "(r: region(R, normal), n: int64)", 1).replace("cell: ref(L1, normal, int64) <- alloc_ref(r, n)", "cell: ref(R, normal, int64) <- alloc_ref(r, n)", 1))
    return c


def t_mem_atomic(rng, area):
    v = rng.randint(0, 100)
    stmts = ["L1: lifetime <- fresh_lifetime()", "r: region(L1, atomic) <- alloc_region(atomic)", f"counter: ref(L1, atomic, int64) <- alloc_ref(r, {v})", "value: int64 <- read_ref(counter)"]
    body = seq_block(["mem(atomic)", "atomic"], stmts, "value", 0)
    hdr = MEM_HDR + "\n// Trial: atomic region needs both mem(atomic) and the atomic effect"
    src = program(f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "atomic", src, "", v)
    c.info["names"] = ["r", "counter", "value"]
    c.info["fnames"] = ["alloc_ref", "read_ref"]
    c.info["has_seq"] = True
    c.add_fail("E3010", "atomic effect declared on a block that only uses normal memory", rep(src, "region(L1, atomic) <- alloc_region(atomic)", "region(L1, normal) <- alloc_region(normal)", 1).replace("ref(L1, atomic, int64)", "ref(L1, normal, int64)", 1).replace("proc[mem(atomic), atomic]", "proc[mem(normal), atomic]", 1))
    return c


def t_mem_ref_types(rng, area):
    kind = rng.choice(["boolean", "atom", "float64", "unit"])
    if kind == "boolean":
        b = rng.choice([True, False])
        stmts = ["L1: lifetime <- fresh_lifetime()", "r: region(L1, normal) <- alloc_region(normal)", f"flag: ref(L1, normal, boolean) <- alloc_ref(r, {str(b).lower()})", "v: boolean <- read_ref(flag)"]
        tail = "case v of { true -> 1; false -> 0 }"
        val = 1 if b else 0
    elif kind == "atom":
        stmts = ["L1: lifetime <- fresh_lifetime()", "r: region(L1, normal) <- alloc_region(normal)", "tag: ref(L1, normal, atom) <- alloc_ref(r, :ok)", "v: atom <- read_ref(tag)"]
        tail = "case v == :ok of { true -> 1; false -> 0 }"
        val = 1
    elif kind == "float64":
        stmts = ["L1: lifetime <- fresh_lifetime()", "r: region(L1, normal) <- alloc_region(normal)", "f: ref(L1, normal, float64) <- alloc_ref(r, 2.5)", "v: float64 <- read_ref(f)"]
        tail = "case v == 2.5 of { true -> 1; false -> 0 }"
        val = 1
    else:
        stmts = ["L1: lifetime <- fresh_lifetime()", "r: region(L1, normal) <- alloc_region(normal)", "u: ref(L1, normal, unit) <- alloc_ref(r, ())", "_used_u: ref(L1, normal, unit) <- u"]
        tail = "0"
        val = 0
    body = seq_block(["mem(normal)"], stmts, tail, 0)
    hdr = MEM_HDR + f"\n// Trial: alloc_ref with element type {kind}"
    src = program(f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "reftypes", src, "", val)
    c.info["names"] = ["r", "v"]
    c.info["fnames"] = ["alloc_ref", "read_ref"]
    c.info["has_seq"] = True
    if kind == "boolean":
        c.add_fail("E2001", "integer stored in a boolean ref", rep(src, f"alloc_ref(r, {str(b).lower()})", "alloc_ref(r, 1)", 1))
    return c


def t_mem_loop(rng, area):
    n = rng.randint(2, 40)
    f = "\n\n".join([
        fn_decl("local_one", [("n", "int64")], "int64", [], "sequence proc[mem(normal)]\n        L1: lifetime <- fresh_lifetime();\n        r: region(L1, normal) <- alloc_region(normal);\n        cell: ref(L1, normal, int64) <- alloc_ref(r, n)\n    produces\n        pure read_ref(cell)\n    end"),
        fn_decl("loop_local", [("i", "int64"), ("acc", "int64")], "int64", [], "case i <= 0 of {\n        true -> acc;\n        false -> loop_local(i - 1, acc + local_one(i))\n    }")])
    total = n * (n + 1) // 2
    body = f"    sequence\n        total: int64 <- loop_local({n}, 0)\n    produces\n        pure case total == {total} of {{ true -> 0; false -> 1 }}\n    end"
    hdr = MEM_HDR + f"\n// Trial: a region allocated per call is released at scope exit; {n} iterations sum to {total}"
    src = program(f, f"fn main() -> int64 {{\n{body}\n}}", header=hdr)
    c = Case(area, "loop", src, "", 0)
    c.info["names"] = ["total", "i", "acc", "n"]
    c.info["fnames"] = ["local_one", "loop_local"]
    c.info["calls"] = [("local_one", 1), ("loop_local", 2)]
    c.info["has_seq"] = True
    c.add_fail("E3001", "region allocated outside any sequence block", rep(src, "sequence proc[mem(normal)]\n        L1: lifetime <- fresh_lifetime();\n        r: region(L1, normal) <- alloc_region(normal);\n        cell: ref(L1, normal, int64) <- alloc_ref(r, n)\n    produces\n        pure read_ref(cell)\n    end",
                                                                                     "L1: lifetime <- fresh_lifetime();\n    r: region(L1, normal) <- alloc_region(normal);\n    cell: ref(L1, normal, int64) <- alloc_ref(r, n);\n    read_ref(cell)", 1))
    return c


# ---------------------------------------------------------------------------
# modules_addition (multi-file: root programs using the existing lib modules,
# plus a few new train_lib_* libraries)
# ---------------------------------------------------------------------------

LIBS = {
    "lib_alpha": [("bump", 1, lambda a: a[0] + 1)],
    "lib_beta": [("twice", 1, lambda a: a[0] * 2)],
    "lib_base": [("seven", 0, lambda a: 7)],
    "lib_middle": [("ten", 0, lambda a: 10)],
    "lib_arity": [("add3", 3, lambda a: a[0] + a[1] + a[2])],
    "lib_math_utils_spec": [("add", 2, lambda a: a[0] + a[1]), ("multiply", 2, lambda a: a[0] * a[1])],
}


def gen_modules(rng, count):
    area = "modules_addition"
    makers = [t_mod_one_use, t_mod_two_uses, t_mod_nested_calls, t_mod_bind_and_print, t_mod_new_lib]
    cases = []
    for i in range(count):
        c = makers[i % len(makers)](rng, area)
        if c:
            c.info["multi"] = True
            cases.append(c)
    return cases


def lib_call(rng, lib):
    fname, ar, fn = rng.choice(LIBS[lib])
    args = ints(rng, ar, 0, 20)
    return f"{lib}@{fname}({', '.join(map(str, args))})", fn(args), fname, ar


def t_mod_one_use(rng, area):
    lib = rng.choice(list(LIBS))
    call, val, fname, ar = lib_call(rng, lib)
    if val > 255:
        return None
    hdr = f"// Spec §19.3: use {lib}; then a module-qualified call {call} = {val}"
    src = program(f"use {lib};", fn_decl("main", [], "int64", [], call), header=hdr)
    c = Case(area, "oneuse", src, "", val)
    c.info["fnames"] = []
    c.add_fail("E1010", f"module-qualified call without `use {lib}`", rep(src, f"use {lib};\n\n", "", 1))
    c.add_fail("E1009", "use names a module that does not exist", rep(src, f"use {lib};", f"use {lib}_missing;", 1))
    return c


def t_mod_two_uses(rng, area):
    l1, l2 = rng.sample(list(LIBS), 2)
    c1, v1, _, _ = lib_call(rng, l1)
    c2, v2, _, _ = lib_call(rng, l2)
    if v1 + v2 > 255:
        return None
    comma = rng.random() < 0.5
    uses = f"use {l1}, {l2};" if comma else f"use {l1};\nuse {l2};"
    hdr = f"// Spec §19.3.1/§19.3.3: two imports whose exports do not overlap; {c1} + {c2} = {v1 + v2}"
    src = program(uses, fn_decl("main", [], "int64", [], f"{c1} + {c2}"), header=hdr)
    c = Case(area, "twouses", src, "", v1 + v2)
    c.add_fail("E1010", f"second module used without being imported", rep(src, uses, f"use {l1};", 1))
    return c


def t_mod_nested_calls(rng, area):
    n = rng.randint(0, 30)
    combos = [("lib_beta@twice(lib_alpha@bump(%d))", lambda n: (n + 1) * 2, ["lib_alpha", "lib_beta"]),
              ("lib_alpha@bump(lib_beta@twice(%d))", lambda n: n * 2 + 1, ["lib_alpha", "lib_beta"]),
              ("lib_math_utils_spec@add(lib_base@seven(), %d)", lambda n: n + 7, ["lib_base", "lib_math_utils_spec"]),
              ("lib_math_utils_spec@multiply(lib_middle@ten(), %d)", lambda n: n * 10, ["lib_middle", "lib_math_utils_spec"])]
    tmpl, fn, libs = rng.choice(combos)
    val = fn(n)
    if val > 255:
        return None
    call = tmpl % n
    hdr = f"// nested module-qualified calls; {call} = {val}"
    src = program("use " + ", ".join(libs) + ";", fn_decl("main", [], "int64", [], call), header=hdr)
    c = Case(area, "nested", src, "", val)
    c.add_fail("E2001", "string literal passed through a qualified call", rep(src, f"{n})", f'"{n}")', 1))
    return c


def t_mod_bind_and_print(rng, area):
    lib = rng.choice(list(LIBS))
    call, val, fname, ar = lib_call(rng, lib)
    stmts = [f"v: int64 <- {call}", "result: atom <- print_int64(v)"]
    body = seq_block(["device_io"], stmts, "result", rng.randint(0, 2))
    hdr = f"// qualified call bound then printed; prints {val}"
    src = program(f"use {lib};", f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "bindprint", src, str(val), 0)
    c.info["names"] = ["v"]
    c.info["fnames"] = ["print_int64"]
    c.info["has_seq"] = True
    c.add_fail("E2003", "qualified call result bound as a string", rep(src, f"v: int64 <- {call}", f"v: string <- {call}", 1))
    return c


def t_mod_new_lib(rng, area):
    """A new library module (lib/train_lib_*.silica) plus a root program using it."""
    tag = rng.choice(["scale", "shift", "clamp", "square", "pair", "label"])
    k = rng.randint(1, 9)
    batch = os.environ.get("STEM_OFFSET", "0")
    lib = f"train_lib_{tag}{k}" if batch == "0" else f"train_lib_b{batch}_{tag}{k}"
    fname = f"{tag}{k}_apply"
    if tag == "square":
        lib_src = program(f"export {fname}/1;", fn_decl(fname, [("x", "int64")], "int64", [], "x * x"))
        n = rng.randint(0, 15); val = n * n; call = f"{lib}@{fname}({n})"
    elif tag == "pair":
        lib_src = program(f"export {fname}/2;", fn_decl(fname, [("a", "int64"), ("b", "int64")], "int64", [], f"a * {k} + b"))
        a, b = ints(rng, 2, 0, 20); val = a * k + b; call = f"{lib}@{fname}({a}, {b})"
    elif tag == "label":
        lib_src = program(f"export {fname}/1;", fn_decl(fname, [("s", "string")], "int64", [], f"length_chars(s) + {k}"))
        w = rng.choice(WORDS); val = len(w) + k; call = f"{lib}@{fname}({s_lit(w)})"
    else:
        lib_src = program(f"export {fname}/1;", fn_decl(fname, [("x", "int64")], "int64", [], f"x * {k}" if tag == "scale" else f"x + {k}" if tag == "shift" else f"case x > {k} of {{\n        true -> {k};\n        false -> x\n    }}"))
        n = rng.randint(0, 25); val = {"scale": n * k, "shift": n + k, "clamp": min(n, k)}[tag]; call = f"{lib}@{fname}({n})"
    if val > 255:
        return None
    hdr = f"// root program using the new library module {lib}; {call} = {val}"
    src = program(f"use {lib};", fn_decl("main", [], "int64", [], call), header=hdr)
    c = Case(area, "newlib", src, "", val)
    c.info["extra_files"] = {f"lib/{lib}.silica": lib_src}
    c.add_fail("E1009", "the imported library is not part of the compile set", rep(src, f"use {lib};", f"use {lib}_x;", 1).replace(f"{lib}@", f"{lib}_x@", 1))
    c.add_fail("E1010", "qualified call without a use declaration", rep(src, f"use {lib};\n\n", "", 1))
    return c


# ---------------------------------------------------------------------------
# traits_addition (multi-file: root programs over the existing traits)
# ---------------------------------------------------------------------------

TRAITS = {
    "Sizeable": ("size", "int64"), "Doubling": ("double", "int64"), "Labeled": ("code_of", "int64"),
    "Scalable": ("scale", "int64"), "ReportEcho": ("echo_code", "int64"),
    "UsesTraitsCombo": ("scale_twice", "int64"),
}
TRAIT_FN = {"Sizeable": lambda n: n, "Doubling": lambda n: 2 * n, "Labeled": lambda n: n + 1, "Scalable": lambda n: n,
            "ReportEcho": lambda n: n + 1, "UsesTraitsCombo": lambda n: 2 * n}


def gen_traits(rng, count):
    area = "traits_addition"
    makers = [t_tr_one, t_tr_sum_two, t_tr_shape, t_tr_print_many, t_tr_new_trait, t_tr_quad, t_tr_textstat, t_tr_compose]
    cases = []
    for i in range(count):
        c = makers[i % len(makers)](rng, area)
        if c:
            c.info["multi"] = True
            cases.append(c)
    return cases


def t_tr_one(rng, area):
    t = rng.choice(list(TRAITS))
    m, _ = TRAITS[t]
    n = rng.randint(0, 60)
    val = TRAIT_FN[t](n)
    if val > 255:
        return None
    hdr = f"// trait method call through the trait module; {t}@{m}({n}) = {val}"
    src = program(f"use {t};", fn_decl("main", [], "int64", [], f"{t}@{m}({n})"), header=hdr)
    c = Case(area, "one", src, "", val)
    c.add_fail("E1010", f"{t}@{m} called without `use {t}`", rep(src, f"use {t};\n\n", "", 1))
    c.add_fail("E2003", "trait method called with a string where only int64 is implemented", rep(src, f"{t}@{m}({n})", f'{t}@{m}("{n}")', 1))
    return c


def t_tr_sum_two(rng, area):
    t1, t2 = rng.sample(list(TRAITS), 2)
    n1, n2 = ints(rng, 2, 0, 40)
    v = TRAIT_FN[t1](n1) + TRAIT_FN[t2](n2)
    if v > 255:
        return None
    m1, m2 = TRAITS[t1][0], TRAITS[t2][0]
    hdr = f"// two traits used in one expression; {t1}@{m1}({n1}) + {t2}@{m2}({n2}) = {v}"
    src = program(f"use {t1};\nuse {t2};", fn_decl("main", [], "int64", [], f"{t1}@{m1}({n1}) + {t2}@{m2}({n2})"), header=hdr)
    c = Case(area, "sumtwo", src, "", v)
    c.add_fail("E1010", f"{t2} used without being imported", rep(src, f"use {t1};\nuse {t2};", f"use {t1};", 1))
    return c


def t_tr_shape(rng, area):
    side = rng.randint(1, 10)
    w, h = ints(rng, 2, 1, 10)
    kind = rng.choice(["side", "rect", "both"])
    if kind == "side":
        expr, val = f"Shape@area({side})", side * side
    elif kind == "rect":
        expr, val = f"Shape@area({{ width: {w}, length: {h} }})", w * h
    elif kind == "both":
        expr, val = f"Shape@area({side}) + Shape@area({{ width: {w}, length: {h} }})", side * side + w * h
    else:
        expr, val = f"Shape@double_area({{ width: {w}, length: {h} }})", 2 * w * h
    if val > 255:
        return None
    hdr = f"// Shape trait with two impl fn area overloads; {expr} = {val}"
    src = program("use Shape;", fn_decl("main", [], "int32", [], expr), header=hdr)
    c = Case(area, "shape", src, "", val)
    c.add_fail("E2003", "record argument shape has no matching impl", rep(src, f"{{ width: {w}, length: {h} }}", f"{{ width: {w}, height: {h} }}", 1) if kind != "side" else None)
    return c


def t_tr_print_many(rng, area):
    ts = rng.sample(list(TRAITS), rng.randint(2, 4))
    ns = ints(rng, len(ts), 0, 40)
    stmts, outs = [], []
    for i, (t, n) in enumerate(zip(ts, ns)):
        stmts.append(f"v{i}: int64 <- {t}@{TRAITS[t][0]}({n})")
        stmts.append(f"_: atom <- print_int64(v{i})")
        stmts.append('_: atom <- println("")')
        outs.append(str(TRAIT_FN[t](n)))
    stmts.append("result: atom <- :ok")
    body = seq_block(["device_io"], stmts, "result", 2)
    uses = "\n".join(f"use {t};" for t in ts)
    hdr = "// several trait calls printed in order"
    src = program(uses, f"fn main() -> atom {{\n{body}\n}}", header=hdr)
    c = Case(area, "printmany", src, "\n".join(outs) + "\n", 2)
    c.info["names"] = [f"v{i}" for i in range(len(ts))]
    c.info["fnames"] = ["print_int64"]
    c.info["has_seq"] = True
    c.add_fail("E2003", "trait result bound as a boolean", rep(src, "v0: int64 <-", "v0: boolean <-", 1))
    return c


def t_tr_new_trait(rng, area):
    """A brand new trait module under traits/ plus a root program using it."""
    tag = rng.choice(["Halving", "Tripling", "Offset", "Negating", "Squaring", "Capping"])
    k = rng.randint(1, 9)
    batch = os.environ.get("STEM_OFFSET", "0")
    name = f"Train{tag}{k}" if batch == "0" else f"TrainB{batch}{tag}{k}"
    m = f"{tag.lower()}{k}"
    if tag == "Halving":
        body, fn = "n / 2", lambda n: n // 2
    elif tag == "Tripling":
        body, fn = "n * 3", lambda n: n * 3
    elif tag == "Offset":
        body, fn = f"n + {k}", lambda n: n + k
    elif tag == "Negating":
        body, fn = "negate_int64(n) + 100", lambda n: 100 - n
    elif tag == "Squaring":
        body, fn = "n * n", lambda n: n * n
    else:
        body, fn = f"case n > {k * 10} of {{\n        true -> {k * 10};\n        false -> n\n    }}", lambda n: min(n, k * 10)
    trait_src = program(f"export trait {name};\nexport {m}/1;",
                        f"required {{\n    fn {m}(x: {name}) -> int64;\n}}",
                        fn_decl(f"{m}", [("n", "int64")], "int64", [], body).replace("fn ", "impl fn ", 1))
    n = rng.randint(0, 15)
    val = fn(n)
    if not (0 <= val <= 255):
        return None
    hdr = f"// root program over the new trait module {name}; {name}@{m}({n}) = {val}"
    src = program(f"use {name};", fn_decl("main", [], "int64", [], f"{name}@{m}({n})"), header=hdr)
    c = Case(area, "newtrait", src, "", val)
    c.info["extra_files"] = {f"traits/{name}.silica": trait_src}
    c.add_fail("E1009", "use names a trait module that is not in the compile set", rep(src, f"use {name};", f"use {name}X;", 1).replace(f"{name}@", f"{name}X@", 1))
    c.add_fail("E1010", "trait method called without importing the trait", rep(src, f"use {name};\n\n", "", 1))
    return c


def t_tr_quad(rng, area):
    a, b, cc, d = ints(rng, 4, 0, 30)
    val = a + b + cc + d
    hdr = f"// tuple argument to a trait method; QuadPack@corner_sum(({a}, {b}, {cc}, {d})) = {val}"
    src = program("use QuadPack;", fn_decl("main", [], "int64", [], f"QuadPack@corner_sum(({a}, {b}, {cc}, {d}))"), header=hdr)
    c = Case(area, "quad", src, "", val & 0xFF)
    c.add_fail("E2003", "triple passed where the impl takes a 4-tuple", rep(src, f"(({a}, {b}, {cc}, {d}))", f"(({a}, {b}, {cc}))", 1))
    return c


def t_tr_textstat(rng, area):
    w = rng.choice(WORDS + ["café", "世界", "🙂"])
    val = len(w)
    hdr = f"// string argument to a trait method; TextStat@char_len({s_lit(w)}) = {val}"
    src = program("use TextStat;", fn_decl("main", [], "int64", [], f"TextStat@char_len({s_lit(w)})"), header=hdr)
    c = Case(area, "textstat", src, "", val)
    c.add_fail("E2003", "integer passed where only a string impl exists", rep(src, f"TextStat@char_len({s_lit(w)})", f"TextStat@char_len({val})", 1))
    return c


def t_tr_compose(rng, area):
    n = rng.randint(0, 40)
    combos = [("Doubling@double(Sizeable@size(%d))", lambda n: 2 * n, ["Doubling", "Sizeable"]),
              ("Labeled@code_of(Doubling@double(%d))", lambda n: 2 * n + 1, ["Labeled", "Doubling"]),
              ("Sizeable@size(Labeled@code_of(%d)) * 2", lambda n: 2 * (n + 1), ["Sizeable", "Labeled"]),
              ("Doubling@double(Scalable@scale(%d))", lambda n: 2 * n, ["Doubling", "Scalable"])]
    tmpl, fn, ts = rng.choice(combos)
    val = fn(n)
    if val > 255:
        return None
    expr = tmpl % n
    hdr = f"// composed trait calls; {expr} = {val}"
    src = program("\n".join(f"use {t};" for t in ts), fn_decl("main", [], "int64", [], expr), header=hdr)
    c = Case(area, "compose", src, "", val)
    c.add_fail("E1010", f"inner trait {ts[1]} not imported", rep(src, f"\nuse {ts[1]};", "", 1))
    return c


# ---------------------------------------------------------------------------
# supervisors_addition: Supervisor.init/1 contract trials (type-checked, main returns 0)
# ---------------------------------------------------------------------------

FLAGS_T = "{ strategy: :one_for_one | :one_for_all | :rest_for_one, allowed_restart_count: int64, restarts_time_frame: int64 }"
CHILD_T = "{ id: atom, agent_type: :worker | :supervisor, initial_state: int64, behavior: fn(msg: int64, state: int64) -> (:reply, int64, int64), restart: :permanent | :temporary | :transient, shutdown: int64, flavor: :plain | :dangerous }"


def gen_supervisors(rng, count):
    area = "supervisors_addition"
    cases = []
    for i in range(count):
        c = t_sup_init(rng, area, i)
        if c:
            c.info["multi"] = True
            cases.append(c)
    return cases


def t_sup_init(rng, area, i):
    strategy = rng.choice(["one_for_one", "one_for_all", "rest_for_one"])
    restart = rng.choice(["permanent", "temporary", "transient"])
    nchild = rng.randint(0, 3)
    cnt, frame = rng.randint(0, 5), rng.randint(1, 10)
    name = f"TrainSup{i:03d}"
    worker = fn_decl("train_worker", [("msg", "int64"), ("state", "int64")], "(:reply, int64, int64)", [], "(:reply, msg + state, state)")
    children = ",\n".join(f"            {{ id: :train_child_{i:03d}_{j}, agent_type: :worker, initial_state: initial_state + {j}, behavior: train_worker, restart: :{restart}, shutdown: 0, flavor: :plain }}" for j in range(nchild))
    child_lit = f"[\n{children}\n        ]" if nchild else f"empty[{CHILD_T}, mem(normal)]()"
    init = (f"fn init(initial_state: int64) -> (\n    {FLAGS_T},\n    List[{CHILD_T}, mem(normal)]\n) {{\n    sequence proc[mem(normal)]\n"
            f"        flags: {FLAGS_T} <- {{ strategy: :{strategy}, allowed_restart_count: {cnt}, restarts_time_frame: {frame} }};\n"
            f"        children: List[{CHILD_T}, mem(normal)] <- {child_lit}\n    produces\n        pure (flags, children)\n    end\n}}")
    hdr = f"// Supervisor.init/1 contract: {strategy} strategy with {nchild} declarative :{restart} child spec(s)"
    src = program("use Supervisor;", f"impl {name} for Supervisor;", worker, init, fn_decl("main", [], "int64", [], "0"), header=hdr)
    c = Case(area, "init", src, "", 0)
    c.info["names"] = ["flags", "children", "initial_state"]
    c.add_fail("E1009", "Supervisor trait used but not imported", rep(src, "use Supervisor;\n\n", "", 1).replace("use Supervisor;", "use Supervisorr;", 1) if False else rep(src, "use Supervisor;", "use SupervisorTrait;", 1))
    c.add_fail("E2003", "flags record missing a field", rep(src, f", restarts_time_frame: {frame} }}", " }", 1))
    c.add_fail("E2001", "string in the int64 restart count", rep(src, f"allowed_restart_count: {cnt},", f'allowed_restart_count: "{cnt}",', 1))
    return c
