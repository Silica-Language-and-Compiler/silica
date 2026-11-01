#!/usr/bin/env python3
"""Generate the per-peripheral ESP32-S3 board-pack modules from ESP-IDF register headers.

Usage: gen_board_pack.py [--check] [--idf DIR] [--out DIR]
  default: write board_pack_<P>_values.silica and device_esp32s3_<tag>_registers.silica (--lookup-tables adds the old board_pack_<P> and _fields) into board/pack/,
           plus board_pack_gpio_signals.silica (GPIO-matrix signal indices of SIGNAL_PREFIXES).
  --check: regenerate into a temporary directory and diff against the tree (exit 1 on difference).

Add a peripheral by adding one PERIPHERALS entry.
"""
import argparse, filecmp, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET_DIR = os.path.normpath(os.path.join(HERE, "..", "pack"))
DEFAULT_IDF = "/Volumes/2T/silica-esp-idf"
REG_DIR = "components/soc/esp32s3/register/soc"

# name, header, base macro (reg_base.h), instance, register-name prefix, field-name prefix,
# macro_fields: also read unannotated NAME/NAME_S/NAME_V field macros (IO_MUX style),
# field_register: register name given to such fields (a family of pads),
# word_ram: a block of plain memory words inside the peripheral's window, described word by word as
#   read_write registers: (ld symbol of the block's address in esp32s3.peripherals.ld, soc_caps.h macro
#   of the words per channel, name of the register family whose count is the channel count,
#   register-name format with the channel and the word),
# families: (regex on the register name, family key with '#' for the index) rows that override the
#   digit-run family of the matching registers, when one digit pattern covers registers of different
#   layouts (RMT's TX and RX channels share CH<n>CONF0 and CH<n>STATUS names).
class P:
    def __init__(s, name, header, base, instance, prefix, macro_fields=False, field_register=None, word_ram=None, families=()):
        s.name, s.header, s.base, s.instance, s.prefix = name, header, base, instance, prefix
        s.macro_fields, s.field_register, s.word_ram, s.families = macro_fields, field_register, word_ram, families

PERIPHERALS = [
    P("gpio", "gpio_reg.h", "DR_REG_GPIO_BASE", None, "GPIO_"),
    P("io_mux", "io_mux_reg.h", "DR_REG_IO_MUX_BASE", None, "IO_MUX_", True, ":gpio"),
    P("uart0", "uart_reg.h", "DR_REG_UART_BASE", 0, "UART_"),
    P("spi2", "spi_reg.h", "DR_REG_SPI2_BASE", 2, "SPI_"),
    P("system", "system_reg.h", "DR_REG_SYSTEM_BASE", None, "SYSTEM_"),
    # RMT: the channel RAM (pulse memory) is in the same 4 KB window, at RMTMEM (esp32s3.peripherals.ld),
    # SOC_RMT_MEM_WORDS_PER_CHANNEL words per channel, one block per CH<n>DATA register (8 channels).
    # Channels 0-3 transmit, 4-7 receive: their CONF0 and STATUS registers have different fields.
    P("rmt", "rmt_reg.h", "DR_REG_RMT_BASE", None, "RMT_", word_ram=("RMTMEM", "SOC_RMT_MEM_WORDS_PER_CHANNEL", ":ch#data", "ch%d_ram_%d"),
      families=((r"^:ch[0-3]conf0$", ":ch#conf0_tx"), (r"^:ch[4-7]conf0$", ":ch#conf0_rx"), (r"^:ch[4-7]conf1$", ":ch#conf1_rx"),
                (r"^:ch[0-3]status$", ":ch#status_tx"), (r"^:ch[4-7]status$", ":ch#status_rx"))),
    P("ledc", "ledc_reg.h", "DR_REG_LEDC_BASE", None, "LEDC_"),
]

# GPIO-matrix signal indices (gpio_sig_map.h; not registers) emitted as constant functions into
# board_pack_gpio_signals.silica: every macro whose name starts with one of these prefixes.
SIGNAL_PREFIXES = ("RMT_SIG_", "LEDC_LS_SIG_", "SIG_GPIO_OUT_IDX")
LD_PERIPHERALS = "components/soc/esp32s3/ld/esp32s3.peripherals.ld"
SOC_CAPS = "components/soc/esp32s3/include/soc/soc_caps.h"
SIG_MAP = "components/soc/esp32s3/include/soc/gpio_sig_map.h"

HEXN = r"0[xX][0-9a-fA-F]+"
REG_RE = re.compile(r"^#define\s+(\w+_REG)(\(\s*i\s*\))?\s+\(\s*(\w+)(?:\(\s*i\s*\))?\s*\+\s*(" + HEXN + r")\s*\)")
ALIAS_RE = re.compile(r"^#define\s+(\w+_REG)\s+(PERIPHS_\w+)\s*$")
PERIPHS_RE = re.compile(r"^#define\s+(PERIPHS_\w+)\s+\(\s*REG_IO_MUX_BASE\s*\+\s*(" + HEXN + r")\s*\)")
# /* NAME : R/W ;bitpos:[h:l] ;default: ... */   and   /** NAME : R/W; bitpos: [h:l]; default: ...;
FIELD_RE = re.compile(r"^/\*\*?\s*(\w+)\s*:\s*([A-Za-z/]*)\s*;\s*bitpos:\s*\[(\d+)(?::(\d+))?\]")
DEF_RE = re.compile(r"^#define\s+(\w+)\s+(.*?)\s*(?://.*|/\*.*)?$")

def base_value(idf, macro):
    txt = open(os.path.join(idf, REG_DIR, "reg_base.h")).read()
    m = re.search(r"#define\s+" + macro + r"\s+(" + HEXN + ")", txt)
    if not m: sys.exit("no base " + macro)
    return int(m.group(1), 16)

def ld_symbol(idf, sym):
    txt = open(os.path.join(idf, LD_PERIPHERALS)).read()
    m = re.search(r"PROVIDE\s*\(\s*" + sym + r"\s*=\s*(" + HEXN + r")\s*\)", txt)
    if not m: sys.exit("no ld symbol " + sym)
    return int(m.group(1), 16)

def soc_cap(idf, macro):
    txt = open(os.path.join(idf, SOC_CAPS)).read()
    m = re.search(r"#define\s+" + macro + r"\s+(\d+)", txt)
    if not m: sys.exit("no soc cap " + macro)
    return int(m.group(1))

def signal_indices(idf):
    """(macro name, index) rows of gpio_sig_map.h whose name starts with one of SIGNAL_PREFIXES, header order."""
    out = []
    for ln in open(os.path.join(idf, SIG_MAP)).read().split("\n"):
        m = re.match(r"^#define\s+(\w+)\s+(\d+|" + HEXN + r")\s*$", ln)
        if m and m.group(1).startswith(SIGNAL_PREFIXES):
            out.append((m.group(1), int(m.group(2), 0)))
    if not out: sys.exit("no signal indices")
    return out

def word_ram_rows(idf, p, regrows):
    """The channel RAM words of p.word_ram as (name, offset, access) register rows."""
    sym, cap, fam, fmt = p.word_ram
    base = ld_symbol(idf, sym) - base_value(idf, p.base)
    words = soc_cap(idf, cap)
    chans = len([r for r in regrows if re.sub(r"\d+", "#", r[0]) == fam])
    if chans == 0: sys.exit("no channel family " + fam)
    return [(":" + fmt % (c, w), base + (c * words + w) * 4, "read_write") for c in range(chans) for w in range(words)], base, chans, words

def int_of(s):
    s = s.strip().rstrip("uUlL")
    return int(s, 0)

def access_of_tokens(tokens):
    """Register access from its fields' raw tokens."""
    if not tokens:
        return "read_write"
    def has(t, ks): return any(k in t.split("/") for k in ks)
    if all(t in ("RO", "R") for t in tokens):
        return "read_only"
    if all(t in ("WO", "WT", "WOD") for t in tokens):
        return "write_only"
    rw = any(("R/W" == t or "RW" == t or t.startswith("R/W/") and "WTC" not in t.split("/") and "WC" not in t.split("/")) for t in tokens)
    w1c = any(has(t, ("WTC", "WC")) for t in tokens)
    if w1c and not rw:
        return "write_one_to_clear"
    return "read_write"

def parse(idf, p, warn):
    path = os.path.join(idf, REG_DIR, p.header)
    lines = open(path, errors="replace").read().split("\n")
    periphs = {}
    for ln in lines:
        m = PERIPHS_RE.match(ln)
        if m: periphs[m.group(1)] = int(m.group(2), 16)
    regs = []        # (macro name, offset)
    fields = []      # (reg index, name, access, shift, width)
    cur = None
    seen_reg = set()
    for li, ln in enumerate(lines):
        m = REG_RE.match(ln)
        if m and m.group(1).startswith(p.prefix) and (m.group(3) == p.base or m.group(3).startswith("REG_")):
            cur = len(regs); regs.append((m.group(1), int(m.group(4), 16))); continue
        m = ALIAS_RE.match(ln)
        if m and m.group(1).startswith(p.prefix) and m.group(2) in periphs:
            cur = len(regs); regs.append((m.group(1), periphs[m.group(2)])); continue
        m = FIELD_RE.search(ln)
        if m and cur is not None:
            hi = int(m.group(3)); lo = int(m.group(4)) if m.group(4) is not None else hi
            fname = m.group(1)
            # the comment's name is sometimes copy-pasted (ENABLE1 says ENABLE_DATA); the macro is right
            for la in lines[li + 1:li + 8]:
                d = re.match(r"^#define\s+(\w+)\b", la)
                if d:
                    if d.group(1) != fname:
                        warn("field comment %s vs macro %s: macro used" % (fname, d.group(1)))
                    fname = d.group(1)
                    break
            fields.append((cur, fname, m.group(2), lo, hi - lo + 1))
    if p.name == "io_mux":
        # PIN_CTRL and DATE are registers of the header too
        for ln in lines:
            m = re.match(r"^#define\s+PIN_CTRL\s+\(\s*REG_IO_MUX_BASE\s*\+\s*(" + HEXN + r")\s*\)", ln)
            if m: regs.append(("IO_MUX_PIN_CTRL_REG", int(m.group(1), 16)))
    macro_fields = []
    if p.macro_fields:
        defs = {}
        for ln in lines:
            m = DEF_RE.match(ln)
            if m: defs[m.group(1)] = m.group(2)
        def val(x, depth=0):
            x = x.strip()
            if depth < 4 and x in defs: return val(defs[x], depth + 1)
            return int_of(x)
        for n in defs:
            if n + "_S" in defs and n + "_V" in defs and not n.endswith(("_S", "_V", "_M")):
                try:
                    sh = val(defs[n + "_S"]); v = val(defs[n + "_V"])
                except ValueError:
                    warn("unparsed macro field " + n); continue
                macro_fields.append((n, "R/W", sh, v.bit_length()))
    return regs, fields, macro_fields

# Access overrides: (peripheral, register) -> access. The header annotates only some fields of a register,
# and the derived access is then wrong for how the register is really used.
ACCESS_OVERRIDES = {
    # UART0 FIFO: the header marks only RXFIFO_RD_BYTE (RO), but TX writes the same register.
    ("uart0", ":fifo"): "read_write",
    # RMT CH<n>DATA: the header marks the one field RO, but the register is the APB FIFO write path too
    # ("read and write data ... via APB FIFO"; the TRM lists it R/W).
    **{("rmt", ":ch%ddata" % c): "read_write" for c in range(8)},
}

def lname(macro, prefix, suffix=""):
    n = macro
    if n.startswith(prefix): n = n[len(prefix):]
    if suffix and n.endswith(suffix): n = n[:-len(suffix)]
    return ":" + n.lower()

def build(idf, p, warn):
    regs, fields, macro_fields = parse(idf, p, warn)
    p.ram = None
    # register rows (header order, dedupe by name)
    rows, names = [], {}
    old2new = {}
    for i, (mn, off) in enumerate(regs):
        nm = lname(mn, p.prefix, "_REG")
        if nm in names:
            warn("duplicate register " + nm); old2new[i] = names[nm]; continue
        names[nm] = len(rows); old2new[i] = len(rows)
        rows.append([nm, off, []])
    for ri, fn, acc, sh, w in fields:
        rows[old2new[ri]][2].append(acc)
    # families: name with digit runs -> '#', >= 3 members
    fam_key = {}
    groups = {}
    for r in rows:
        k = next((key for rx, key in p.families if re.match(rx, r[0])), None) or re.sub(r"\d+", "#", r[0])
        groups.setdefault(k, []).append(r[0])
    for k, ms in groups.items():
        if "#" in k and len(ms) >= 3:
            for m in ms: fam_key[m] = k
    regrows = [(r[0], r[1], ACCESS_OVERRIDES.get((p.name, r[0]), access_of_tokens(r[2]))) for r in rows]
    if p.word_ram:
        ram, p.ram = word_ram_rows(idf, p, regrows)[0], word_ram_rows(idf, p, regrows)[1:]
        regrows += ram
    # fields
    frows, fseen = [], {}
    vrows = []   # every field (family-folded), duplicates by name kept, for the _values module
    reg_names = [r[0] for r in rows]
    for ri, fn, acc, sh, w in fields:
        rn = reg_names[old2new[ri]]
        fam = rn in fam_key
        regname = fam_key[rn].replace("#", "") if fam else rn
        nm = lname(fn, p.prefix)
        if fam:
            digs = re.findall(r"\d+", rn)
            for d in digs:
                nm = nm.replace(d, "", 1) if d in nm else nm
            nm = re.sub(r"__+", "_", nm).rstrip("_")
            # a per-channel field named FIELD_CH<n> in a ch<n> family is just FIELD
            if nm.endswith("_ch") and fam_key[rn].startswith(":ch#"): nm = nm[:-3]
        if (nm, regname, sh, w) not in vrows: vrows.append((nm, regname, sh, w))
        if nm in fseen:
            j = fseen[nm]
            if frows[j][1:5] != (regname, sh, w, acc) and not fam:
                warn("duplicate field name %s (%s vs %s): first kept" % (nm, frows[j][1], regname))
            elif fam and frows[j][1:5] != (regname, sh, w, acc):
                warn("family field %s differs between members of %s" % (nm, regname))
            continue
        fseen[nm] = len(frows)
        frows.append((nm, regname, sh, w, acc))
    for mn, acc, sh, w in macro_fields:
        nm = lname(mn, p.prefix)
        if nm in fseen:
            warn("duplicate macro field " + nm); continue
        vrows.append((nm, ":pin_ctrl" if mn.startswith("CLK_OUT") else p.field_register, sh, w))
        fseen[nm] = len(frows)
        frows.append((nm, ":pin_ctrl" if mn.startswith("CLK_OUT") else p.field_register, sh, w, acc))
    return regrows, frows, vrows

LICENSE = """{-

   Copyright 2026 Lee Scott Barney

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not USE this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-}
"""

def hexs(n): return "0x%X" % n

def case_fn(name, params, ret, scrut, arms, default):
    out = ["fn %s(%s) -> %s {" % (name, params, ret), "    case %s of {" % scrut]
    out += ["        %s -> %s;" % (a, b) for a, b in arms]
    out += ["        %s -> %s" % default, "    }", "}", ""]
    return "\n".join(out)

def first_by_name(rows, idx):
    seen, out = set(), []
    for r in rows:
        if r[0] not in seen:
            seen.add(r[0]); out.append(r)
    return out

def gen_regs(p, commit, regrows):
    n = p.name
    L = [LICENSE, "// Generated by board/tools/gen_board_pack.py from ESP-IDF %s %s; do not edit." % (commit, p.header),
         "//", "// Registers of %s, offsets relative to the peripheral base (%s%s)." % (n, p.base, "" if p.instance is None else ", instance %d" % p.instance),
         "// Access is derived from the fields: read_only, write_only, write_one_to_clear or read_write.", ""]
    for f, a in [("register_count/0", 0), ("register_name/1", 0), ("register_offset/1", 0), ("register_access/1", 0),
                 ("register_offset_of/1", 0), ("register_access_of/1", 0)]:
        L.append("export %s_%s;" % (n, f))
    L.append("")
    L.append("fn %s_register_count() -> uint32 {\n    %d\n}\n" % (n, len(regrows)))
    u, s = "uint32", "string"
    L.append(case_fn(n + "_register_name", "i: uint32", s, "i", [(str(i), '"%s"' % r[0]) for i, r in enumerate(regrows)], ("_: uint32", '""')))
    L.append(case_fn(n + "_register_offset", "i: uint32", u, "i", [(str(i), hexs(r[1])) for i, r in enumerate(regrows)], ("_: uint32", "0")))
    L.append(case_fn(n + "_register_access", "i: uint32", s, "i", [(str(i), '"%s"' % r[2]) for i, r in enumerate(regrows)], ("_: uint32", '""')))
    rr = first_by_name(regrows, 0)
    L.append(case_fn(n + "_register_offset_of", "name: string", ":none | (:found, uint32)", "name",
                     [('"%s"' % r[0], "(:found, %s)" % hexs(r[1])) for r in rr], ("_: string", ":none")))
    L.append(case_fn(n + "_register_access_of", "name: string", s, "name", [('"%s"' % r[0], '"%s"' % r[2]) for r in rr], ("_: string", '""')))
    return "\n".join(L).rstrip("\n") + "\n"

def gen_fields(p, commit, frows):
    n = p.name
    L = [LICENSE, "// Generated by board/tools/gen_board_pack.py from ESP-IDF %s %s; do not edit." % (commit, p.header),
         "//", "// Bit fields of %s. Shift and width are of the field in its register; the mask is already shifted." % n,
         "// Access is the raw token of the header (R/W, RO, WO, WT, R/WTC/SS, ...). An indexed family is one", "// row, registered under the family name.", ""]
    for f in ["field_count/0", "field_name/1", "field_register/1", "field_shift/1", "field_width/1", "field_access/1",
              "field_shift_of/1", "field_width_of/1", "field_mask_of/1", "field_access_of/1", "field_register_of/1"]:
        L.append("export %s_%s;" % (n, f))
    L.append("")
    u, s = "uint32", "string"
    L.append("fn %s_field_count() -> uint32 {\n    %d\n}\n" % (n, len(frows)))
    L.append(case_fn(n + "_field_name", "i: uint32", s, "i", [(str(i), '"%s"' % r[0]) for i, r in enumerate(frows)], ("_: uint32", '""')))
    L.append(case_fn(n + "_field_register", "i: uint32", s, "i", [(str(i), '"%s"' % r[1]) for i, r in enumerate(frows)], ("_: uint32", '""')))
    L.append(case_fn(n + "_field_shift", "i: uint32", u, "i", [(str(i), str(r[2])) for i, r in enumerate(frows)], ("_: uint32", "0")))
    L.append(case_fn(n + "_field_width", "i: uint32", u, "i", [(str(i), str(r[3])) for i, r in enumerate(frows)], ("_: uint32", "0")))
    L.append(case_fn(n + "_field_access", "i: uint32", s, "i", [(str(i), '"%s"' % r[4]) for i, r in enumerate(frows)], ("_: uint32", '""')))
    ret = ":none | (:found, uint32)"
    def mask(r): return ((1 << r[3]) - 1) << r[2]
    L.append(case_fn(n + "_field_shift_of", "name: string", ret, "name", [('"%s"' % r[0], "(:found, %d)" % r[2]) for r in frows], ("_: string", ":none")))
    L.append(case_fn(n + "_field_width_of", "name: string", ret, "name", [('"%s"' % r[0], "(:found, %d)" % r[3]) for r in frows], ("_: string", ":none")))
    L.append(case_fn(n + "_field_mask_of", "name: string", ret, "name", [('"%s"' % r[0], "(:found, %s)" % hexs(mask(r))) for r in frows], ("_: string", ":none")))
    L.append(case_fn(n + "_field_access_of", "name: string", s, "name", [('"%s"' % r[0], '"%s"' % r[4]) for r in frows], ("_: string", '""')))
    L.append(case_fn(n + "_field_register_of", "name: string", s, "name", [('"%s"' % r[0], '"%s"' % r[1]) for r in frows], ("_: string", '""')))
    return "\n".join(L).rstrip("\n") + "\n"

def fname_of(atom): return atom[1:].lower()

def value_fns(p, regrows, vrows):
    """(function name, hex literal) rows. Rule: a field function is P_F_x; when the field name F occurs in
    more than one register (family) with different placement, every such field is P_REG_F_x instead."""
    n = p.name
    out = [("%s_%s_offset" % (n, fname_of(r[0])), hexs(r[1])) for r in regrows]
    if p.ram:
        base, chans, words = p.ram
        out += [("%s_ram_offset" % n, hexs(base)), ("%s_ram_channels" % n, hexs(chans)),
                ("%s_ram_words_per_channel" % n, hexs(words)), ("%s_ram_channel_stride" % n, hexs(words * 4))]
    cnt = {}
    for v in vrows: cnt[v[0]] = cnt.get(v[0], 0) + 1
    prefixed = 0
    for nm, reg, sh, w in vrows:
        base = fname_of(nm)
        if cnt[nm] > 1:
            base = fname_of(reg) + "_" + base; prefixed += 1
        m = ((1 << w) - 1) << sh
        out += [("%s_%s_shift" % (n, base), hexs(sh)), ("%s_%s_width" % (n, base), hexs(w)), ("%s_%s_mask" % (n, base), hexs(m))]
    names = [o[0] for o in out]
    dup = sorted({x for x in names if names.count(x) > 1})
    if dup: sys.exit("%s: colliding value names %s" % (n, dup[:10]))
    return out, prefixed

def gen_values(p, commit, regrows, vrows):
    rows, prefixed = value_fns(p, regrows, vrows)
    L = [LICENSE, "// Generated by board/tools/gen_board_pack.py from ESP-IDF %s %s; do not edit." % (commit, p.header),
         "//", "// One tiny function per register offset and per field shift, width and mask (mask already shifted) of %s." % p.name,
         "// A program calls only the ones it needs. A field name that occurs in several registers is prefixed", "// with the register family."]
    if p.ram:
        L += ["// The channel RAM words are registers %s_ch<c>_ram_<w>_offset; %s_ram_offset, _ram_channels," % (p.name, p.name),
              "// _ram_words_per_channel and _ram_channel_stride (bytes) describe the block as a whole."]
    L.append("")
    L += ["export %s/0;" % r[0] for r in rows]
    L.append("")
    for nm, h in rows:
        L.append("fn %s() -> uint32 {\n    %s\n}\n" % (nm, h))
    return "\n".join(L).rstrip("\n") + "\n", len(rows), prefixed

# Device tag of each peripheral's description module (silica_device_actor_specification.md §4.9). The module
# name must start with device_ (E2210), so the file is device_esp32s3_<tag>_registers.silica.
DEVICE_TAGS = {"gpio": "gpio", "io_mux": "io_mux", "uart0": "uart", "spi2": "spi2", "system": "system", "rmt": "rmt", "ledc": "ledc"}

def desc_file(p): return "device_esp32s3_%s_registers.silica" % DEVICE_TAGS[p.name]

def gen_description(p, commit, regrows):
    tag = "esp32s3_" + DEVICE_TAGS[p.name]
    L = [LICENSE, "// Generated by board/tools/gen_board_pack.py from ESP-IDF %s %s; do not edit." % (commit, p.header),
         "//", "// Device description of %s (tag :%s): every register of the header, 32 bits wide, offsets relative" % (p.name, tag),
         "// to the peripheral base. Access is derived from the fields (with ACCESS_OVERRIDES applied)."]
    if p.ram:
        L += ["// The channel RAM (pulse memory) lies in the same window: :ch<c>_ram_<w> is word w of channel c,",
              "// %d channels of %d words from offset %s, read_write." % (p.ram[1], p.ram[2], hexs(p.ram[0]))]
    L += ["",
         "use DeviceDescription;", "", "export registers/1;", "",
         "impl fn registers(device: (:%s)) -> List[{ name: atom, offset: uint64, width: uint64, access: atom }, mem(normal)] {" % tag, "    ["]
    rows = ["        { name: %s, offset: %s, width: 32, access: :%s }" % (r[0], hexs(r[1]), r[2]) for r in regrows]
    L.append(",\n".join(rows))
    L += ["    ]", "}", ""]
    return "\n".join(L)

SIGNALS_FILE = "board_pack_gpio_signals.silica"

def gen_signals(idf, commit):
    rows = signal_indices(idf)
    L = [LICENSE, "// Generated by board/tools/gen_board_pack.py from ESP-IDF %s gpio_sig_map.h; do not edit." % commit,
         "//", "// GPIO-matrix signal indices (not registers): the value written to GPIO_FUNC<pin>_OUT_SEL_CFG's",
         "// OUT_SEL to route a peripheral output signal to a pin, or to GPIO_FUNC<signal>_IN_SEL_CFG's IN_SEL",
         "// to route a pin to a peripheral input. One tiny function per index, for the macros starting with",
         "// %s." % ", ".join(SIGNAL_PREFIXES), ""]
    names = [("gpio_signal_" + re.sub(r"_IDX$", "", n).lower(), v) for n, v in rows]
    L += ["export %s/0;" % n for n, v in names]
    L.append("")
    for n, v in names:
        L.append("fn %s() -> uint32 {\n    %s\n}\n" % (n, hexs(v)))
    return "\n".join(L).rstrip("\n") + "\n", len(names)

def generate(idf, outdir, warn, lookup=False):
    try:
        commit = subprocess.check_output(["git", "-C", idf, "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        commit = "unknown"
    counts = {}
    st, sn = gen_signals(idf, commit)
    open(os.path.join(outdir, SIGNALS_FILE), "w").write(st)
    print("gpio signals: %d functions" % sn, file=sys.stderr)
    for p in PERIPHERALS:
        regrows, frows, vrows = build(idf, p, warn)
        vt, vn, vp = gen_values(p, commit, regrows, vrows)
        open(os.path.join(outdir, "board_pack_%s_values.silica" % p.name), "w").write(vt)
        print("%s values: %d functions, %d field functions prefixed" % (p.name, vn, vp), file=sys.stderr)
        if lookup:
            open(os.path.join(outdir, "board_pack_%s.silica" % p.name), "w").write(gen_regs(p, commit, regrows))
            open(os.path.join(outdir, "board_pack_%s_fields.silica" % p.name), "w").write(gen_fields(p, commit, frows))
        open(os.path.join(outdir, desc_file(p)), "w").write(gen_description(p, commit, regrows))
        w1c = [r[0] for r in regrows if r[2] == "write_one_to_clear"]
        print("%s description: %d registers, write_one_to_clear: %d" % (p.name, len(regrows), len(w1c)), file=sys.stderr)
        counts[p.name] = (len(regrows), len(frows))
    return counts

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--lookup-tables", action="store_true", help="also write the compiler-side board_pack_<P>.silica and _fields lookup modules (no longer used)")
    ap.add_argument("--idf", default=DEFAULT_IDF)
    ap.add_argument("--out", default=TARGET_DIR)
    a = ap.parse_args()
    warn = lambda m: print("warning: " + m, file=sys.stderr)
    if a.check:
        with tempfile.TemporaryDirectory() as d:
            generate(a.idf, d, warn, a.lookup_tables)
            bad = 0
            for p in PERIPHERALS + [None]:
                fs = [SIGNALS_FILE] if p is None else ["board_pack_%s_values.silica" % p.name, desc_file(p)]
                if a.lookup_tables and p: fs += ["board_pack_%s.silica" % p.name, "board_pack_%s_fields.silica" % p.name]
                for f in fs:
                    t = os.path.join(a.out, f)
                    if not os.path.exists(t) or not filecmp.cmp(os.path.join(d, f), t, shallow=False):
                        print("differs: " + f); bad = 1
            print("check: " + ("DIFFERENCES" if bad else "clean"))
            sys.exit(bad)
    c = generate(a.idf, a.out, warn, a.lookup_tables)
    for k, (r, f) in c.items():
        print("%-7s registers %5d fields %5d" % (k, r, f))

if __name__ == "__main__":
    main()
