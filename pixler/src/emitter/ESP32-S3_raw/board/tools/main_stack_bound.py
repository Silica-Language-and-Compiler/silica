#!/usr/bin/env python3
# Copyright 2026 Lee Scott Barney
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Static stack bounds for one linked ESP32-S3 image (actor_memory_budget_plan.md §4.1, item D).

    main_stack_bound.py [--objdump PATH] [--runtime-syms FILE] [--root SYM] [--report] IMAGE.elf

Walks the image's call graph from `_start` and reports what `main`'s two stacks need:

  machine  the windowed frames: `entry a1, N` summed along CALL8/CALL0 edges and tail jumps,
           the maximum over branches (the walk follows the linked code, so the hand-written
           runtime, libgcc and every compiled unit are covered, whatever `--gc-sections` kept);
  aux      the emitter's auxiliary stack (the word at THREADPTR+112): every reservation a
           function makes (`l32i aN, aT, 112 / addi aN, aN, -K / s32i aN, aT, 112`, in the
           instruction forms xt_mem.silica's vsp_adjust and xt_vr.silica's vr_put emit) is added
           up per function, and the sums are accumulated along the same edges. The hand-written
           runtime never reserves on that stack: a store to the word inside a runtime function is
           a context switch and is ignored.

Only instructions reachable by control flow from a function's start are read (libgcc keeps
jump tables and literal pools inside its functions; a linear decode of those is noise), and a
branch into code the linear decode misaligned is decoded again from the branch target.

A root is UNBOUNDED when recursion is reachable from it, or when a CALLX8 whose target cannot be
read is reachable (a function value or closure called from `main`). Two CALLX8 forms are read:
a register loaded by L32R from a literal in the image (the linker's longcall form; the target is
then followed), and a ROM function (an address in the ROM window), charged ROM_CALL_DEPTH.
build_image.sh keeps the documented defaults for an unbounded `main`.

Emitted code checks its stack against a per-context limit in every prologue (control.silica
function_prologue), `limit = guard top + _silica_rt_depth_reserve`, so that a runtime chain called
from the deepest emitted frame cannot pass the 64-byte guard band unseen (the band is watched for
stores; a frame larger than it can straddle it without storing into it, plan §8.2). The reserve is
the deepest bounded runtime chain any emitted function calls, measured here (`rt_depth`), and the
`machine` bound already includes it under every emitted frame, so a correctly sized `main` never
trips its own check.

Emitted code grows its stacks instead of failing (actor_memory_budget_plan.md item F): below the
limit a prologue parks its frame 32 bytes under it and calls silica_rt_stack_grow, whose chain runs
inside the reserve; the runtime declares those 32 bytes as silica_rt_stack_grow__stack_extra (an
absolute symbol <name>__stack_extra adds to a block's own frame), and the chain itself is walked
like any other, so `rt_depth` covers growth. A `<name>__stack_bound` symbol declares a block's whole
depth instead (bounded recursion, a trampoline that runs on another stack).

Output (key value per line): status, machine, aux, rt_depth, and with --report the deepest chain.
Exit status 0 even when unbounded (the caller decides); 2 on a usage or tool error.
"""

import argparse
import os
import re
import subprocess
import sys

ROM_LOW, ROM_HIGH = 0x40000000, 0x40060000   # the ESP32-S3 ROM's code window
ROM_CALL_DEPTH = 256                           # allowance for one ROM call (ets_delay_us, ets_set_appcpu_boot_addr: shallow C)
VSP_OFFSET = 112                               # VRG_VSP: the auxiliary stack pointer in the per-core register block

RETURNS = {"retw", "retw.n", "ret", "ret.n", "rfi", "rfe", "rfde", "rfwo", "rfwu", "rfdo", "rfdd", "ill", "ill.n"}
CALLS = {"call8", "call4", "call12", "call0"}
XCALLS = {"callx8", "callx4", "callx12", "callx0"}
LOOPS = {"loop", "loopnez", "loopgtz"}
NO_REG_WRITE = {"s32i", "s32i.n", "s16i", "s8i", "s32e", "s32c1i", "memw", "nop", "nop.n", "isync", "rsync",
                "dsync", "esync", "wsr", "wur", "ssr", "ssl", "ssa8l", "ssa8b", "ssai", "entry", "break", "break.n"}

SYM_RE = re.compile(r"^([0-9a-f]+) <([^>]+)>:\s*$")
INSN_RE = re.compile(r"^\s*([0-9a-f]+):\t((?:[0-9a-f]{2} ?)+)\s*\t(\S+)\s*(.*?)\s*$")
HEX_RE = re.compile(r"^([0-9a-f]+)(?:\s+<.*>)?$")
LAST_HEX_RE = re.compile(r"([0-9a-f]+)(?:\s+<[^>]*>)?$")


class Insn:
    __slots__ = ("addr", "size", "op", "args")

    def __init__(self, addr, size, op, args):
        self.addr, self.size, self.op, self.args = addr, size, op, args


class Block:
    """One function: from a symbol or a call target to the next such start."""
    __slots__ = ("start", "end", "name", "frame", "reached", "edges", "unknown", "rom_calls", "aux", "aux_unknown")

    def __init__(self, start, name):
        self.start, self.end, self.name = start, None, name
        self.frame = 0
        self.reached = []        # reachable instructions, in address order
        self.edges = []          # (target start, label): call8/call4/call12/call0/callx/j/entry
        self.unknown = None      # why the block is unbounded on its own
        self.rom_calls = 0
        self.aux = 0
        self.aux_unknown = None


class Image:
    def __init__(self, objdump, elf):
        self.objdump, self.elf = objdump, elf
        self.insns = {}
        self.syms = {}
        self.text_lo, self.text_hi = None, None
        self.words = {}
        self.bounds = {}         # function name -> declared bound (an absolute symbol <name>__stack_bound)
        self.extras = {}         # function name -> bytes added to its frame (<name>__stack_extra)
        self.decoded_from = set()
        self.load()

    def run(self, cmd):
        try:
            return subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode(errors="replace")
        except (OSError, subprocess.CalledProcessError) as e:
            err = getattr(e, "stderr", b"")
            sys.stderr.write("main_stack_bound: %s: %s\n" % (" ".join(cmd), err.decode(errors="replace") if err else e))
            sys.exit(2)

    def load(self):
        self.parse(self.run([self.objdump, "-d", "-j", ".iram0.text", self.elf]), keep_syms=True)
        self.load_bounds()
        for line in self.run([self.objdump, "-h", self.elf]).splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[1] == ".iram0.text":
                self.text_lo = int(parts[3], 16)
                self.text_hi = self.text_lo + int(parts[2], 16)
        if self.text_lo is None:
            sys.stderr.write("main_stack_bound: no .iram0.text in %s\n" % self.elf)
            sys.exit(2)
        for line in self.run([self.objdump, "-s", "-j", ".iram0.text", self.elf]).splitlines():
            parts = line.split()
            if len(parts) < 2 or not line.startswith(" "):
                continue
            try:
                base = int(parts[0], 16)
            except ValueError:
                continue
            raw = bytes.fromhex("".join(p for p in parts[1:5] if re.fullmatch(r"[0-9a-f]+", p)))
            for i in range(0, len(raw) - 3, 4):
                self.words[base + i] = int.from_bytes(raw[i:i + 4], "little")

    def load_bounds(self):
        for line in self.run([self.objdump, "-t", self.elf]).splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[-1].endswith("__stack_bound") and "*ABS*" in parts:
                self.bounds[parts[-1][:-len("__stack_bound")]] = int(parts[0], 16)
            if len(parts) >= 4 and parts[-1].endswith("__stack_extra") and "*ABS*" in parts:
                self.extras[parts[-1][:-len("__stack_extra")]] = int(parts[0], 16)

    def parse(self, text, keep_syms):
        for line in text.splitlines():
            m = SYM_RE.match(line)
            if m:
                if keep_syms:
                    self.syms.setdefault(int(m.group(1), 16), m.group(2))
                continue
            m = INSN_RE.match(line)
            if m:
                a = int(m.group(1), 16)
                size = len(m.group(2).replace(" ", "")) // 2
                self.insns[a] = Insn(a, size, m.group(3), m.group(4))

    def insn_at(self, addr, stop):
        """The instruction at addr; decoded afresh from addr when the linear decode skipped it."""
        ins = self.insns.get(addr)
        if ins is not None:
            return ins
        if addr in self.decoded_from or not (self.text_lo <= addr < self.text_hi):
            return None
        self.decoded_from.add(addr)
        self.parse(self.run([self.objdump, "-d", "--start-address=0x%x" % addr, "--stop-address=0x%x" % stop, self.elf]), keep_syms=False)
        return self.insns.get(addr)


def branch_target(ins):
    m = LAST_HEX_RE.search(ins.args)
    return int(m.group(1), 16) if m else None


def walk(img, b, starts):
    """Control-flow reachability inside [b.start, b.end): fills b.reached, b.edges, b.unknown, b.rom_calls.
    Returns the addresses outside the block that the walk discovered as function starts."""
    b.reached, b.edges, b.unknown, b.rom_calls = [], [], None, 0
    seen = set()
    todo = [b.start]
    found = set()
    last_l32r = {}
    while todo:
        a = todo.pop()
        if a in seen:
            continue
        if not (b.start <= a < b.end):
            # control flows into the next block (a label that is a symbol, such as the emitter's
            # L_case_* labels, starts one): the same frame continues there
            if img.text_lo <= a < img.text_hi and a not in (t for t, _ in b.edges):
                b.edges.append((a, "j"))
                found.add(a)
            continue
        ins = img.insn_at(a, b.end)
        if ins is None:
            b.unknown = b.unknown or "undecodable code at 0x%x in %s" % (a, b.name)
            continue
        seen.add(a)
        op, args = ins.op, ins.args
        nxt = a + ins.size
        if op == "entry" and a != b.start:
            b.edges.append((a, "entry"))
            found.add(a)
            continue
        if op in CALLS:
            t = branch_target(ins)
            if t is not None:
                b.edges.append((t, op))
                found.add(t)
            todo.append(nxt)
            continue
        if op in XCALLS:
            r = args.split(",")[0].strip()
            lit = last_l32r.get(r)
            target = img.words.get(lit) if lit is not None else None
            if target is not None and img.text_lo <= target < img.text_hi:
                b.edges.append((target, op))
                found.add(target)
            elif target is not None and ROM_LOW <= target < ROM_HIGH:
                b.rom_calls += 1
            else:
                b.unknown = b.unknown or "%s at 0x%x (%s) calls a function value" % (op, a, b.name)
            todo.append(nxt)
            continue
        if op == "l32r":
            m = re.match(r"(a\d+),\s*([0-9a-f]+)", args)
            if m:
                last_l32r[m.group(1)] = int(m.group(2), 16)
            todo.append(nxt)
            continue
        if op in ("j", "j.l"):
            t = branch_target(ins)
            if t is not None:
                if b.start <= t < b.end:
                    todo.append(t)
                else:
                    b.edges.append((t, "j"))
                    found.add(t)
            continue
        if op == "jx":
            b.unknown = b.unknown or "jx at 0x%x (%s): a jump through a register" % (a, b.name)
            continue
        if op in RETURNS:
            continue
        if op in LOOPS or (op.startswith("b") and op not in ("break", "break.n")):
            t = branch_target(ins)
            if t is not None:
                if b.start <= t < b.end:
                    todo.append(t)
                else:
                    b.edges.append((t, "j"))
                    found.add(t)
            todo.append(nxt)
            continue
        todo.append(nxt)
    b.reached = [img.insns[a] for a in sorted(seen) if a in img.insns]
    first = img.insns.get(b.start)
    if first is not None and first.op == "entry":
        m = re.match(r"a1,\s*(0x[0-9a-f]+|\d+)", first.args)
        b.frame = int(m.group(1), 0) if m else 0
    else:
        b.frame = 0
    return found


def aux_usage(b, is_runtime):
    """Sum of the reservations the block makes on the auxiliary stack (the emitter's SP)."""
    b.aux, b.aux_unknown = 0, None
    if is_runtime(b.name):
        return
    sym = {}                # register -> ("vsp", delta) | ("const", value)
    tp = set()              # registers holding the per-core register block (rur.threadptr)
    prev_end = None
    for ins in b.reached:
        op, args = ins.op, ins.args
        if prev_end is not None and ins.addr != prev_end:
            sym.clear(); tp.clear()           # a gap: the straight line was broken
        prev_end = ins.addr + ins.size
        if op in CALLS or op in XCALLS or op in ("j", "jx") or op in RETURNS or op in LOOPS or (op.startswith("b") and op not in ("break", "break.n")):
            sym.clear(); tp.clear()
            continue
        if op == "rur.threadptr":
            r = args.strip()
            tp.add(r); sym.pop(r, None)
            continue
        m = re.match(r"(a\d+),\s*(a\d+),\s*(-?\d+|-?0x[0-9a-f]+)$", args)
        if op in ("l32i", "l32i.n") and m and m.group(2) in tp and int(m.group(3), 0) == VSP_OFFSET:
            sym[m.group(1)] = ("vsp", 0); tp.discard(m.group(1))
            continue
        if op in ("s32i", "s32i.n") and m and m.group(2) in tp and int(m.group(3), 0) == VSP_OFFSET:
            v = sym.get(m.group(1))
            if v is None or v[0] != "vsp":
                b.aux_unknown = b.aux_unknown or "store to the auxiliary stack pointer at 0x%x (%s) with an untracked value" % (ins.addr, b.name)
            elif v[1] < 0:
                b.aux += -v[1]
            continue
        if op in ("movi", "movi.n"):
            m2 = re.match(r"(a\d+),\s*(-?\d+|-?0x[0-9a-f]+)$", args)
            if m2:
                sym[m2.group(1)] = ("const", int(m2.group(2), 0)); tp.discard(m2.group(1))
            continue
        if op in ("addi", "addi.n", "addmi") and m:
            d, s, k = m.group(1), m.group(2), int(m.group(3), 0)
            if op == "addmi":
                k <<= 8
            v = sym.get(s)
            if v:
                sym[d] = (v[0], v[1] + k)
            else:
                sym.pop(d, None)
            tp.discard(d)
            continue
        m3 = re.match(r"(a\d+),\s*(a\d+),\s*(a\d+)$", args)
        if op in ("add", "add.n", "sub") and m3:
            d, x, y = m3.groups()
            vx, vy = sym.get(x), sym.get(y)
            r = None
            if vx and vy:
                if vx[0] == "vsp" and vy[0] == "const":
                    r = ("vsp", vx[1] + vy[1] if op != "sub" else vx[1] - vy[1])
                elif vx[0] == "const" and vy[0] == "vsp" and op != "sub":
                    r = ("vsp", vy[1] + vx[1])
                elif vx[0] == "const" and vy[0] == "const":
                    r = ("const", vx[1] + vy[1] if op != "sub" else vx[1] - vy[1])
            if r is None:
                sym.pop(d, None)
            else:
                sym[d] = r
            tp.discard(d)
            continue
        if op in ("mov", "mov.n"):
            m4 = re.match(r"(a\d+),\s*(a\d+)$", args)
            if m4:
                d, s = m4.groups()
                if s in tp:
                    tp.add(d)
                else:
                    tp.discard(d)
                if s in sym:
                    sym[d] = sym[s]
                else:
                    sym.pop(d, None)
            continue
        m5 = re.match(r"(a\d+)", args)
        if m5 and op not in NO_REG_WRITE:
            sym.pop(m5.group(1), None); tp.discard(m5.group(1))


def build(img):
    """Blocks at every symbol and every discovered call target, walked to a fixed point."""
    starts = set(a for a in img.syms if img.text_lo <= a < img.text_hi)
    while True:
        order = sorted(starts)
        blocks = {}
        for i, s in enumerate(order):
            name = img.syms.get(s)
            if name is None:
                prev = max((x for x in img.syms if x < s), default=None)
                name = "%s+0x%x" % (img.syms[prev], s - prev) if prev is not None else "0x%x" % s
            b = Block(s, name)
            b.end = order[i + 1] if i + 1 < len(order) else img.text_hi
            blocks[s] = b
        found = set()
        for b in blocks.values():
            found |= walk(img, b, starts)
        new = {t for t in found if img.text_lo <= t < img.text_hi} - starts
        if not new:
            return blocks
        starts |= new


def continuation(blocks, s):
    """Blocks reached from s through jumps into code that has no `entry` of its own: the same frame
    continues there (libgcc's shared tails, a runtime function falling into its successor's body)."""
    seen = {s}
    todo = [s]
    while todo:
        x = todo.pop()
        for t, label in blocks[x].edges:
            if label == "j" and t in blocks and blocks[t].frame == 0 and t not in seen:
                seen.add(t)
                todo.append(t)
    return seen


def solve(blocks, is_emitted, rt_depth, ignore_callx, declared=None, exclude=None, extras=None):
    """Longest-path depths over call edges with cycle detection. A jump into a block that starts
    with `entry` (and an `entry` met inside a block) is a call: the frame is made again.
    Returns (machine depth, aux depth, reason when unbounded, deepest callee) per block start."""
    WHITE, GREY, BLACK = 0, 1, 2
    color = {s: WHITE for s in blocks}
    depth, aux, why, chain = {}, {}, {}, {}
    cont = {s: continuation(blocks, s) for s in blocks}
    declared = declared or {}
    extras = extras or {}
    exclude = exclude or set()

    def callees(s):
        out = []
        for x in cont[s]:
            for t, label in blocks[x].edges:
                if t not in blocks or blocks[t].name in exclude:
                    continue
                if label == "j" and blocks[t].frame == 0:
                    continue
                out.append(t)
        return out

    sys.setrecursionlimit(200000)

    def visit(s):
        if color[s] == BLACK:
            return
        if color[s] == GREY:
            raise RecursionError(blocks[s].name)
        color[s] = GREY
        if blocks[s].name in declared:
            # a function whose depth is declared at its definition (<name>__stack_bound in its
            # source): bounded recursion such as rt_heap.S silica_rt_heap_reaches
            depth[s], aux[s], why[s], chain[s] = declared[blocks[s].name], 0, None, None
            color[s] = BLACK
            return
        best, best_aux, best_edge = 0, 0, None
        reason = None
        rom = False
        own_aux = 0
        for x in cont[s]:
            b = blocks[x]
            if b.unknown and not ignore_callx:
                reason = reason or b.unknown
            rom = rom or b.rom_calls > 0
            own_aux += b.aux
        for t in callees(s):
            try:
                visit(t)
            except RecursionError as e:
                reason = reason or "recursion through %s" % e
                continue
            if why.get(t):
                reason = reason or why[t]
                continue
            if depth[t] > best:
                best, best_edge = depth[t], t
            best_aux = max(best_aux, aux[t])
        if rom:
            best = max(best, ROM_CALL_DEPTH)
        if is_emitted(blocks[s].name):
            best = max(best, rt_depth)
        depth[s] = blocks[s].frame + extras.get(blocks[s].name, 0) + best
        aux[s] = own_aux + best_aux
        why[s] = reason
        chain[s] = best_edge
        color[s] = BLACK

    for s in blocks:
        try:
            visit(s)
        except RecursionError as e:
            why[s] = why.get(s) or "recursion through %s" % e
            depth.setdefault(s, blocks[s].frame)
            aux.setdefault(s, blocks[s].aux)
            color[s] = BLACK
    return depth, aux, why, chain


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("elf")
    ap.add_argument("--objdump", default=os.environ.get("XTENSA_OBJDUMP") or os.path.join(
        os.environ.get("XTENSA_BIN", os.path.expanduser("~/.espressif/tools/xtensa-esp-elf/esp-16.1.0_20260609/xtensa-esp-elf/bin")),
        "xtensa-esp32s3-elf-objdump"))
    ap.add_argument("--runtime-syms", help="file naming the runtime's symbols, one per line (nm over the runtime objects); "
                                           "without it, symbols starting with silica_rt_, silica_pid_, silica_dangerous_, silica_device_ or _ are the runtime")
    ap.add_argument("--root", default="_start", help="symbol to bound (default _start: main's machine stack)")
    ap.add_argument("--report", action="store_true", help="print the deepest chain")
    ap.add_argument("--ignore-callx", action="store_true", help="count an unreadable CALLX8 as depth 0 (the fixed overhead "
                                                                "of the actor loop, with the behaviour left out)")
    ap.add_argument("--exclude", action="append", default=[], help="leave calls to this symbol out of the walk (repeatable)")
    ap.add_argument("--list", action="store_true", help="print every function's bounded depth, deepest first")
    a = ap.parse_args()

    img = Image(a.objdump, a.elf)
    blocks = build(img)
    names = {b.name: s for s, b in blocks.items()}

    runtime_syms = None
    if a.runtime_syms:
        with open(a.runtime_syms) as f:
            runtime_syms = {ln.strip() for ln in f if ln.strip()}

    def is_runtime(name):
        base = name.split("+")[0]
        if runtime_syms is not None:
            return base in runtime_syms or base.startswith("_")
        return base.startswith(("silica_rt_", "silica_pid_", "silica_dangerous_", "silica_device_", "_"))

    def is_emitted(name):
        return not is_runtime(name)

    for b in blocks.values():
        aux_usage(b, is_runtime)

    # the runtime reserve: the deepest bounded runtime chain any emitted function calls directly
    depth0, aux0, why0, _ = solve(blocks, lambda n: False, 0, False, img.bounds, extras=img.extras)
    rt_depth = 0
    rt_unbounded = []
    for b in blocks.values():
        if not is_emitted(b.name):
            continue
        for t, label in b.edges:
            if t in blocks and is_runtime(blocks[t].name):
                if why0.get(t):
                    rt_unbounded.append("%s -> %s: %s" % (b.name, blocks[t].name, why0[t]))
                else:
                    rt_depth = max(rt_depth, depth0[t])
    rt_depth = (rt_depth + 15) & ~15

    depth, aux, why, chain = solve(blocks, is_emitted, rt_depth, a.ignore_callx, img.bounds, set(a.exclude), img.extras)
    root = names.get(a.root)
    if root is None:
        sys.stderr.write("main_stack_bound: no symbol %s\n" % a.root)
        sys.exit(2)

    aux_unknown = None
    seen = set()
    stack = [root]
    while stack:
        s = stack.pop()
        if s in seen:
            continue
        seen.add(s)
        b = blocks[s]
        aux_unknown = aux_unknown or b.aux_unknown
        for t, _ in b.edges:
            if t in blocks and t not in seen:
                stack.append(t)

    status = "bounded" if not why.get(root) else "unbounded: " + why[root]
    print("root %s" % a.root)
    print("status %s" % status)
    print("machine %d" % depth[root])
    print("aux %s" % ("unbounded: " + aux_unknown if aux_unknown else str(aux[root])))
    print("rt_depth %d" % rt_depth)
    for u in sorted(set(rt_unbounded)):
        print("rt_unbounded %s" % u)
    if a.list:
        print("functions:")
        for s2 in sorted(blocks, key=lambda x: -depth0.get(x, 0)):
            b = blocks[s2]
            if not b.reached:
                continue
            print("  %-48s frame %5d  depth %6d  %s" % (b.name, b.frame, depth0.get(s2, 0), why0.get(s2) or ""))
    if a.report:
        s = root
        print("chain:")
        while s is not None:
            b = blocks[s]
            print("  %-48s frame %5d  aux %5d  depth %6d%s" % (b.name, b.frame, b.aux, depth[s], "  [rom call]" if b.rom_calls else ""))
            s = chain.get(s)
    sys.exit(0)


if __name__ == "__main__":
    main()
