#!/usr/bin/env python3
"""Generate a hardware self-test for the ESP32-S3 emitter's Xtensa helpers (xt_vr / xt_isa / xt_mem).

Writes:
  xt_selftest.silica  -- Silica program; main() prints, via the real helpers, one Xtensa function per case
  header.S            -- .set block for the frame-home symbols + data used by the tests
  footer.S            -- main: runs every case, prints failures, exit status = number of failures
Expected values are computed here with exact 64-bit two's-complement arithmetic.
"""
import os, sys

M64 = (1 << 64) - 1
def s64(x):
    x &= M64
    return x - (1 << 64) if x >> 63 else x
def u64(x): return x & M64
def lo32(x): return s32(x & 0xFFFFFFFF)
def hi32(x): return s32((x >> 32) & 0xFFFFFFFF)
def s32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x >> 31 else x

cases = []   # (silica_expr_for_code, dst, exp_value, kind)   kind: 'X' check 64 / 'W' check lo + hi==0

def lit(v):
    v = s64(v)
    if v == -(1 << 63):
        return "(0 - 9223372036854775807 - 1)"
    return str(v)

def setv(vr, v):
    return f'xt_movi("{vr}", {lit(v)})'

def add_case(code_parts, dst, exp, kind='X'):
    cases.append((code_parts, dst, s64(exp), kind))

# register triples: (dst, a, b) mixing phys (X0-X2, X9, X10) and frame homes, with aliasing
TRIPLES = [("X0", "X19", "X9"), ("X19", "X1", "X20"), ("X9", "X9", "X10"), ("X20", "X3", "X0"),
           ("X1", "X21", "X1"), ("X4", "X10", "X22"), ("X10", "X16", "X17")]
WTRIPLES = [("W0", "W19", "W9"), ("W19", "W1", "W20"), ("W9", "W9", "W10"), ("W20", "W3", "W0")]

def binop(opname, fn, vals, triples=TRIPLES, width=64):
    for i, (a, b) in enumerate(vals):
        d, ra, rb = triples[i % len(triples)]
        if ra == rb:
            b = a
        code = [setv(ra, a)]
        if rb != ra:
            code.append(setv(rb, b))
        code.append(f'{opname}("{d}", "{ra}", "{rb}")')
        if width == 64:
            add_case(code, d, fn(a, b), 'X')
        else:
            add_case(code, d, fn(a & 0xFFFFFFFF, b & 0xFFFFFFFF) & 0xFFFFFFFF, 'W')
        # immediate second operand form
    return

V64 = [(0x1FFFFFFFF, 1), (0x100000000, 1), (-1, 1), (5, -7), (0x7FFFFFFFFFFFFFFF, 1),
       (-(1 << 63), -1), (0xFFFFFFFF, 0xFFFFFFFF), (123456789012345, -987654321), (0, 0)]

binop("xt_add", lambda a, b: a + b, V64)
binop("xt_sub", lambda a, b: a - b, V64)
binop("xt_mul", lambda a, b: a * b, V64 + [(3000000000, 3), (-123456789, 987654)])
BITV = [(0x123456789ABCDEF0, 0x0FF00FF00FF00FF0), (-1, 0x5555555555555555), (0, -1)]
binop("xt_and", lambda a, b: a & b, BITV)
binop("xt_orr", lambda a, b: a | b, BITV)
binop("xt_eor", lambda a, b: a ^ b, BITV)
binop("xt_bic", lambda a, b: a & ~b, BITV)

# immediates as second operand
for (d, ra, _), (a, k) in zip(TRIPLES, [(0xFFFFFFFF, 1), (0x100000000, 5), (7, 4095), (-5, 3)]):
    add_case([setv(ra, a), f'xt_add("{d}", "{ra}", "#{k}")'], d, a + k)
    add_case([setv(ra, a), f'xt_sub("{d}", "{ra}", "#{k}")'], d, a - k)

# 32-bit (W): result zero-extended, high word must read 0
V32 = [(0x7FFFFFFF, 1), (0xFFFFFFFF, 2), (5, -7), (100000, 100000)]
binop("xt_add", lambda a, b: a + b, V32, WTRIPLES, 32)
binop("xt_sub", lambda a, b: a - b, V32, WTRIPLES, 32)
binop("xt_mul", lambda a, b: a * b, V32, WTRIPLES, 32)
binop("xt_eor", lambda a, b: a ^ b, V32, WTRIPLES, 32)
# W write clears a previously set high word
add_case([setv("X19", -1), 'xt_movi("W19", 5)'], "X19", 5)
add_case([setv("X0", -1), 'xt_movi("W0", 5)'], "X0", 5)
add_case([setv("X20", -1), setv("X9", 0x1234), 'xt_add("W20", "W9", "#1")'], "X20", 0x1235)

# neg / mvn / mov
for d, a, v in [("X0", "X19", 5), ("X19", "X0", 0), ("X9", "X9", 0x100000000), ("X20", "X1", -(1 << 63)), ("X3", "X10", 1)]:
    add_case([setv(a, v), f'xt_neg("{d}", "{a}")'], d, -v)
    add_case([setv(a, v), f'xt_mvn("{d}", "{a}")'], d, ~v)
    add_case([setv(a, v), f'xt_mov("{d}", "{a}")'], d, v)
add_case([setv("W9", -5), 'xt_neg("W0", "W9")'], "X0", 5)

# shifts by immediate and by register
SV = [0x8123456789ABCDEF, 0x0000000180000001, -2]
for k in [0, 1, 4, 31, 32, 33, 63]:
    for v in SV:
        uv = u64(v)
        add_case([setv("X19", v), f'xt_lsl("X0", "X19", "#{k}")'], "X0", uv << k)
        add_case([setv("X9", v), f'xt_lsr("X20", "X9", "#{k}")'], "X20", uv >> k)
        add_case([setv("X1", v), f'xt_asr("X9", "X1", "#{k}")'], "X9", s64(v) >> k)
for k in [0, 1, 7, 31, 32, 40, 63, 64 + 3]:
    v = SV[0]; uv = u64(v); kk = k & 63
    add_case([setv("X19", v), setv("X10", k), 'xt_lsl("X0", "X19", "X10")'], "X0", uv << kk)
    add_case([setv("X0", v), setv("X20", k), 'xt_lsr("X19", "X0", "X20")'], "X19", uv >> kk)
    add_case([setv("X9", v), setv("X1", k), 'xt_asr("X9", "X9", "X1")'], "X9", s64(v) >> kk)
for k in [0, 1, 5, 16, 31]:
    add_case([setv("W9", 0x80000001), f'xt_lsl("W0", "W9", "#{k}")'], "X0", (0x80000001 << k) & 0xFFFFFFFF)
    add_case([setv("W9", 0x80000001), f'xt_lsr("W0", "W9", "#{k}")'], "X0", 0x80000001 >> k)
    add_case([setv("W9", 0x80000001), f'xt_asr("W0", "W9", "#{k}")'], "X0", (s32(0x80000001) >> k) & 0xFFFFFFFF)
    add_case([setv("W9", 0x80000001), setv("W10", k), 'xt_lsl("W19", "W9", "W10")'], "X19", (0x80000001 << k) & 0xFFFFFFFF)

# division (libgcc for X, quos/quou/rems/remu for W), including zero divisors
def tdiv(a, b):
    if b == 0: return 0
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q
def tmod(a, b):
    if b == 0: return 0
    return a - tdiv(a, b) * b
DV = [(9000000000, 7), (-9000000000, 7), (9000000000, -7), (7, 9000000000), (5, 0), (-(1 << 63), -1), (-1, 2)]
for i, (a, b) in enumerate(DV):
    d, ra, rb = TRIPLES[i % len(TRIPLES)]
    if ra == rb: continue
    add_case([setv(ra, a), setv(rb, b), f'xt_sdiv("{d}", "{ra}", "{rb}")'], d, s64(tdiv(a, b)) if not (a == -(1 << 63) and b == -1) else a)
    add_case([setv(ra, a), setv(rb, b), f'xt_srem("{d}", "{ra}", "{rb}")'], d, tmod(a, b) if not (a == -(1 << 63) and b == -1) else 0)
    ua, ub = u64(a), u64(b)
    add_case([setv(ra, a), setv(rb, b), f'xt_udiv("{d}", "{ra}", "{rb}")'], d, (ua // ub) if ub else 0)
    add_case([setv(ra, a), setv(rb, b), f'xt_urem("{d}", "{ra}", "{rb}")'], d, (ua % ub) if ub else 0)
for a, b in [(-7, 2), (7, -2), (100, 0), (0xFFFFFFFF, 16)]:
    add_case([setv("W19", a), setv("W9", b), 'xt_sdiv("W0", "W19", "W9")'], "X0", (tdiv(s32(a), s32(b))) & 0xFFFFFFFF)
    add_case([setv("W19", a), setv("W9", b), 'xt_srem("W0", "W19", "W9")'], "X0", (tmod(s32(a), s32(b))) & 0xFFFFFFFF)
    ua, ub = a & 0xFFFFFFFF, b & 0xFFFFFFFF
    add_case([setv("W19", a), setv("W9", b), 'xt_udiv("W0", "W19", "W9")'], "X0", (ua // ub) if ub else 0)
# a libcall must leave X0-X2 alone when they are not the destination
add_case([setv("X0", 0x1111111122222222), setv("X1", 0x3333333344444444), setv("X2", 0x5555555566666666),
          setv("X19", 100), setv("X20", 7), 'xt_sdiv("X21", "X19", "X20")', 'xt_add("X21", "X21", "X0")',
          'xt_add("X21", "X21", "X1")', 'xt_add("X21", "X21", "X2")'], "X21",
         14 + 0x1111111122222222 + 0x3333333344444444 + 0x5555555566666666)

# compares: all conditions, values differing only in hi, only in lo, sign
CONDS = {"EQ": lambda a, b: a == b, "NE": lambda a, b: a != b,
         "LT": lambda a, b: a < b, "LE": lambda a, b: a <= b, "GT": lambda a, b: a > b, "GE": lambda a, b: a >= b,
         "LO": lambda a, b: u64(a) < u64(b), "LS": lambda a, b: u64(a) <= u64(b),
         "HI": lambda a, b: u64(a) > u64(b), "HS": lambda a, b: u64(a) >= u64(b)}
CV = [(1, 2), (2, 1), (5, 5), (-1, 1), (1, -1), (0x100000000, 0x1FFFFFFFF), (0x200000000, 0x1FFFFFFFF),
      (0x100000005, 0x200000005), (-(1 << 63), 0x7FFFFFFFFFFFFFFF)]
pairs = [("X19", "X9"), ("X0", "X20"), ("X10", "X1"), ("X3", "X3")]
for ci, (cond, f) in enumerate(CONDS.items()):
    for vi, (a, b) in enumerate(CV):
        ra, rb = pairs[(ci + vi) % len(pairs)]
        if ra == rb: b = a
        code = [setv(ra, a)] + ([setv(rb, b)] if rb != ra else []) + [f'xt_cmp_set("X21", "{cond}", "{ra}", "{rb}")']
        add_case(code, "X21", 1 if f(a, b) else 0)
    # 32-bit compares
    for a, b in [(1, 2), (-1, 1), (7, 7), (0x80000000, 1)]:
        sa, sb = s32(a), s32(b)
        r = {"EQ": sa == sb, "NE": sa != sb, "LT": sa < sb, "LE": sa <= sb, "GT": sa > sb, "GE": sa >= sb,
             "LO": (a & 0xFFFFFFFF) < (b & 0xFFFFFFFF), "LS": (a & 0xFFFFFFFF) <= (b & 0xFFFFFFFF),
             "HI": (a & 0xFFFFFFFF) > (b & 0xFFFFFFFF), "HS": (a & 0xFFFFFFFF) >= (b & 0xFFFFFFFF)}[cond]
        add_case([setv("W19", a), setv("W9", b), f'xt_cmp_set("W0", "{cond}", "W19", "W9")'], "X0", 1 if r else 0)
    # compare against an immediate
    add_case([setv("X19", 0x100000000), f'xt_cmp_set("X0", "{cond}", "X19", "#1")'], "X0", 1 if f(0x100000000, 1) else 0)

# select
for cond, a, b in [("LT", 1, 2), ("LT", 2, 1), ("EQ", 0x100000000, 0x100000000), ("HI", -1, 1)]:
    t, f_ = 0x1111111122222222, 0x3333333344444444
    exp = t if CONDS[cond](a, b) else f_
    add_case([setv("X19", a), setv("X9", b), setv("X20", t), setv("X1", f_),
              f'xt_cmp_select("X0", "X20", "X1", "{cond}", "X19", "X9")'], "X0", exp)
    add_case([setv("X19", a), setv("X9", b), setv("X0", t), setv("X10", f_),
              f'xt_cmp_select("X0", "X0", "X10", "{cond}", "X19", "X9")'], "X0", exp)

# cbz / cbnz: 1 when the branch was NOT taken
for v in [0, 1, 0x100000000, -1]:
    add_case([setv("X19", v), 'xt_movi("X20", 0)', 'xt_cbz("X19", "98f")', 'xt_movi("X20", 1)', '"98:\\n"'], "X20", 0 if v == 0 else 1)
    add_case([setv("X0", v), 'xt_movi("X20", 0)', 'xt_cbnz("X0", "98f")', 'xt_movi("X20", 1)', '"98:\\n"'], "X20", 1 if v == 0 else 0)
add_case([setv("X19", 0x100000000), 'xt_movi("X20", 0)', 'xt_cbz("W19", "98f")', 'xt_movi("X20", 1)', '"98:\\n"'], "X20", 0)

# memory: tbuf is a 256-byte .bss buffer; frame slots [X29, #-N]; aux stack pushes
V = 0x0123456789ABCDEF
add_case([setv("X0", V), 'xt_adr("X19", "tbuf")', 'xt_str("X0", "[X19, #8]")', 'xt_ldr("X20", "[X19, #8]")'], "X20", V)
add_case([setv("X9", V), 'xt_adr("X1", "tbuf")', 'xt_str("X9", "[X1]")', 'xt_ldr("X9", "[X1]")'], "X9", V)
add_case([setv("X9", V), 'xt_adr("X19", "tbuf")', 'xt_str("X9", "[X19, #1016]")', 'xt_ldr("X0", "[X19, #1016]")'], "X0", V)
add_case([setv("X9", V), 'xt_adr("X19", "tbuf")', 'xt_str("X9", "[X19, #2000]")', 'xt_ldr("X0", "[X19, #2000]")'], "X0", V)
add_case([setv("X20", V), 'xt_str("X20", "[X29, #-16]")', 'xt_ldr("X0", "[X29, #-16]")'], "X0", V)
add_case([setv("X0", V), 'xt_str("X0", "[X29, #-48]")', 'xt_ldr("X21", "[X29, #-48]")'], "X21", V)
add_case([setv("W0", 0x89ABCDEF), 'xt_adr("X19", "tbuf")', 'xt_str("XZR", "[X19]")', 'xt_str("W0", "[X19, #4]")', 'xt_ldr("X20", "[X19]")'], "X20", 0x89ABCDEF << 32)
add_case([setv("X0", 0x1FF), 'xt_adr("X19", "tbuf")', 'xt_strb("W0", "[X19, #3]")', 'xt_ldrb("W20", "[X19, #3]")'], "X20", 0xFF)
add_case([setv("X0", 0x1FF), 'xt_adr("X19", "tbuf")', 'xt_strb("W0", "[X19, #3]")', 'xt_ldrsb("X20", "[X19, #3]")'], "X20", -1)
add_case([setv("X0", 0x1FF), 'xt_adr("X19", "tbuf")', 'xt_strb("W0", "[X19, #3]")', 'xt_ldrsb("W20", "[X19, #3]")'], "X20", 0xFFFFFFFF)
add_case([setv("X0", 0x18001), 'xt_adr("X19", "tbuf")', 'xt_strh("W0", "[X19, #6]")', 'xt_ldrh("W20", "[X19, #6]")'], "X20", 0x8001)
add_case([setv("X0", 0x18001), 'xt_adr("X19", "tbuf")', 'xt_strh("W0", "[X19, #6]")', 'xt_ldrsh("X20", "[X19, #6]")'], "X20", s64(-0x7FFF))
add_case([setv("W0", 0x80000000), 'xt_adr("X19", "tbuf")', 'xt_str("W0", "[X19, #12]")', 'xt_ldrsw("X20", "[X19, #12]")'], "X20", -(1 << 31))
add_case([setv("X0", 5), setv("X1", 7), 'xt_adr("X19", "tbuf")', 'xt_stp("X0", "X1", "[X19, #16]")',
          'xt_ldp("X20", "X21", "[X19, #16]")', 'xt_sub("X20", "X21", "X20")'], "X20", 2)
add_case([setv("X9", 11), 'xt_adr("X19", "tbuf")', 'xt_movi("X20", 24)', 'xt_str("X9", "[X19, X20]")', 'xt_ldr("X0", "[X19, #24]")'], "X0", 11)
add_case([setv("X9", 0x0102030405060708), 'xt_adr("X19", "tbuf")', 'xt_str("X9", "[X19]")',
          'xt_ldrb("W20", "[X19], #1")', 'xt_ldrb("W21", "[X19], #1")', 'xt_adr("X22", "tbuf")', 'xt_sub("X0", "X19", "X22")',
          'xt_lsl("X0", "X0", "#16")', 'xt_orr("X0", "X0", "X21")', 'xt_lsl("X0", "X0", "#8")', 'xt_orr("X0", "X0", "X20")'],
         "X0", (2 << 24) | (0x07 << 8) | 0x08)
# aux stack: push two, push one, pop in reverse, [SP, #k] addressing, MOV from SP
add_case([setv("X0", 1), setv("X1", 2), setv("X19", 3), 'xt_stp("X0", "X1", "[SP, #-16]!")', 'xt_str("X19", "[SP, #-16]!")',
          'xt_ldr("X20", "[SP, #16]")', 'xt_ldr("X21", "[SP], #16")', 'xt_ldp("X9", "X10", "[SP], #16")',
          'xt_lsl("X20", "X20", "#8")', 'xt_orr("X20", "X20", "X21")', 'xt_lsl("X20", "X20", "#8")', 'xt_orr("X20", "X20", "X9")',
          'xt_lsl("X20", "X20", "#8")', 'xt_orr("X20", "X20", "X10")'], "X20", (1 << 24) | (3 << 16) | (1 << 8) | 2)
add_case([ 'xt_mov("X19", "SP")', 'xt_stp("X0", "X1", "[SP, #-16]!")', 'xt_mov("X20", "SP")', 'xt_ldp("X0", "X1", "[SP], #16")',
           'xt_sub("X0", "X19", "X20")'], "X0", 16)
# frame pointer value: X29 - 16 must equal the address the [X29, #-16] access used
add_case([setv("X0", 77), 'xt_str("X0", "[X29, #-16]")', 'xt_sub("X19", "X29", "#16")', 'xt_ldr("X20", "[X19]")'], "X20", 77)

print(f"{len(cases)} cases", file=sys.stderr)

# ---------------- Silica program ----------------
out = []
out.append("// Generated by gen_selftest.py -- hardware self-test for the Xtensa helpers.\nuse xt_vr;\nuse xt_isa;\nuse xt_mem;\n")
out.append('''
fn check_word(reg: string, exp: int64) -> string {
    concat(xt_ins("movi", concat("a2, ", xt_itos(exp))), xt_ins("bne", concat(reg, ", a2, 99f")))
}

fn check_dst(dst: string, exp_lo: int64, exp_hi: int64) -> string {
    lo: string <- concat(vr_lo_load(dst, "a8"), check_word(vr_lo_reg(dst, "a8"), exp_lo));
    hi: string <- concat(vr_hi_load(dst, "a9"), check_word(vr_hi_reg(dst, "a9"), exp_hi));
    concat(lo, hi)
}

fn tcase(id: int64, code: string, dst: string, exp_lo: int64, exp_hi: int64) -> string {
    head: string <- concat("    .align 4\\n    .global t_", concat(xt_itos(id), concat("\\nt_", concat(xt_itos(id), ":\\n    entry a1, 1024\\n"))));
    tail: string <- "    movi a2, 0\\n    retw\\n99:\\n    movi a2, 1\\n    retw\\n";
    concat(concat(head, code), concat(check_dst(dst, exp_lo, exp_hi), tail))
}
''')
CHUNK = 25
chunks = [cases[i:i + CHUNK] for i in range(0, len(cases), CHUNK)]
for ci, ch in enumerate(chunks):
    lines = []
    for k, (code, dst, exp, kind) in enumerate(ch):
        cid = ci * CHUNK + k
        expr = code[0]
        for c in code[1:]:
            expr = f"concat({expr}, {c})"
        dstcheck = "X" + dst[1:] if dst[0] in "WX" else dst
        lines.append(f'        print_string(tcase({cid}, {expr}, "{dstcheck}", {lo32(exp)}, {hi32(exp)}))')
    # the last statement of a sequence block takes no ';'
    out.append(f"fn chunk_{ci}() -> atom {{\n    sequence proc[device_io]\n" + ";\n".join(lines) + "\n    produces pure :ok end\n}\n")
out.append("fn main() -> atom {\n    sequence proc[device_io]\n        print_string(xt_prelude_macros());\n        print_string(\"    .text\\n\");\n")
out.append("".join(f"        c{ci}: atom <- chunk_{ci}();\n" for ci in range(len(chunks) - 1)))
out.append(f"        chunk_{len(chunks) - 1}()")
out.append("\n    produces pure :ok end\n}\n")
open("xt_selftest.silica", "w").write("".join(out))

# ---------------- assembly header / footer ----------------
hdr = []
fixed = {}
off = 0
for n in list(range(11, 29)):
    fixed[f"SVR_X{n:02d}"] = off; off += 8
for n in range(8, 32):
    fixed[f"SVR_D{n:02d}"] = off; off += 8
fixed["SVR_LC"] = off; off += 32
SFP = ((off + 64 + 15) // 16) * 16          # X29 area: [SFP-64, SFP)
assert SFP + 32 <= 1024, SFP
for k, v in fixed.items():
    hdr.append(f"    .set {k}, {v}")
hdr.append(f"    .set SFP, {SFP}")
hdr.append("""    .section .bss.selftest, "aw", @nobits
    .align 8
    .global tbuf
tbuf: .space 2048
""")
open("header.S", "w").write("\n".join(hdr) + "\n")

ftr = ["""    .section .text.selftest_main, "ax"
    .align 4
report_fail:                      // report_fail(id)
    entry a1, 32
    mov a6, a2
    movi a10, msg_fail
    call8 silica_rt_puts
    mov a10, a6
    call8 silica_rt_print_u32
    movi a10, 10
    call8 silica_rt_putc
    retw
    .align 4
    .global main
main:
    entry a1, 32
    movi a2, 0                    // failures
"""]
for i in range(len(cases)):
    ftr.append(f"    call8 t_{i}\n    beqz a10, 1f\n    addi a2, a2, 1\n    movi a10, {i}\n    call8 report_fail\n1:")
ftr.append(f"""    movi a10, msg_total
    call8 silica_rt_puts
    movi a10, {len(cases)}
    call8 silica_rt_print_u32
    movi a10, msg_fails
    call8 silica_rt_puts
    mov a10, a2
    call8 silica_rt_print_u32
    movi a10, 10
    call8 silica_rt_putc
    mov a2, a2
    movi a3, 0
    retw
    .section .rodata.selftest, "a"
msg_fail:  .asciz "FAIL case "
msg_total: .asciz "cases "
msg_fails: .asciz " failures "
""")
open("footer.S", "w").write("\n".join(ftr))
