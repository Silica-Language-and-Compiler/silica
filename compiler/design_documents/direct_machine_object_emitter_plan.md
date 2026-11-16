# Direct machine-object emitter: phased plan

Plan part split out of [direct_machine_object_emitter_future.md](direct_machine_object_emitter_future.md) (split 2026-11-15). The design, rationale and decisions stay in that file; the sections below are the plan, moved verbatim with their headings and numbering (references such as "design section N" point to the design file, and plan sections keep their original numbers).

Status: open work remains; this plan stays next to its design until every step is done.

---

## 13. Phased plan

Each phase below shows two views of the same work. **Human-readable** is a listing for inspection (the optional disassembly-like trace in §14). **Emitted** is what the compiler owns: `Instr` records, then encoded section bytes and relocation records. Listings are not assembler input and are not Silica source.

AArch64 instruction words are stored little-endian. Relocatable immediates are encoded as zero and completed by the linker.

### Phase 0 - Spike object

Emit one Mach-O object with a single exported integer add. Link it with a small caller. This proves instruction byte order, symbol export, section layout, and linker acceptance.

Human-readable:

```text
global function:
    add x0, x0, x1
    ret
```

Emitted:

```text
Instr.add_reg { width: 64, dst: X0, lhs: X0, rhs: X1 }
Instr.ret { }

CodeObject {
    sections: [
        { name: "__text", segment: "__TEXT",
          bytes: [0x00, 0x00, 0x01, 0x8B,   // ADD X0, X0, X1
                  0xC0, 0x03, 0x5F, 0xD6],  // RET
          alignment_log2: 2 }
    ],
    symbols: [
        { name: "add2", section_name: "__text", offset: 0, global: true, external: false }
    ],
    relocations: [],
    entry_points: ["add2"]
}
```

### Phase 1 - Code buffer and integer subset

Add the `CodeObject` model and enough instruction encoders for simple integer functions with no external references (`ADD`, `SUB`, `MOV` register aliases, compare/subtract, `RET`).

Human-readable:

```text
fn sub_then_add(a, b, c):          // X0, X1, X2
    mov  x9, x0
    sub  x9, x9, x1
    add  x0, x9, x2
    ret
```

Emitted:

```text
Instr.mov_reg { width: 64, dst: X9, src: X0 }
Instr.sub_reg { width: 64, dst: X9, lhs: X9, rhs: X1 }
Instr.add_reg { width: 64, dst: X0, lhs: X9, rhs: X2 }
Instr.ret { }

CodeObject {
    sections: [
        { name: "__text", segment: "__TEXT",
          bytes: [0xE9, 0x03, 0x00, 0xAA,   // MOV X9, X0  (ORR X9, XZR, X0)
                  0x29, 0x01, 0x01, 0xCB,   // SUB X9, X9, X1
                  0x20, 0x01, 0x02, 0x8B,   // ADD X0, X9, X2
                  0xC0, 0x03, 0x5F, 0xD6],  // RET
          alignment_log2: 2 }
    ],
    symbols: [
        { name: "sub_then_add", section_name: "__text", offset: 0, global: true, external: false }
    ],
    relocations: []
}
```

### Phase 2 - Symbols and relocations

Implement page, pageoff, and branch relocations for the existing Apple Silicon symbol materialization patterns.

Human-readable:

```text
    adrp x9, other_fn@PAGE
    add  x9, x9, other_fn@PAGEOFF
    blr  x9
    ret
```

Emitted:

```text
Instr.adrp_page { dst: X9, symbol: "other_fn" }
Instr.add_pageoff { dst: X9, base: X9, symbol: "other_fn" }
Instr.blr { target: X9 }
Instr.ret { }

CodeObject {
    sections: [
        { name: "__text", segment: "__TEXT",
          bytes: [0x09, 0x00, 0x00, 0x90,   // ADRP X9, #0   (page reloc)
                  0x29, 0x01, 0x00, 0x91,   // ADD  X9, X9, #0 (pageoff reloc)
                  0x20, 0x01, 0x3F, 0xD6,   // BLR  X9
                  0xC0, 0x03, 0x5F, 0xD6],  // RET
          alignment_log2: 2 }
    ],
    symbols: [
        { name: "caller", section_name: "__text", offset: 0, global: true, external: false },
        { name: "other_fn", section_name: "", offset: 0, global: false, external: true }
    ],
    relocations: [
        { section_name: "__text", offset: 0, kind: Arm64Page21, symbol: "other_fn", addend: 0 },
        { section_name: "__text", offset: 4, kind: Arm64Pageoff12, symbol: "other_fn", addend: 0 }
    ]
}
```

A direct `BL other_fn` uses `Instr.bl { symbol: "other_fn" }`, encodes `0x94000000` (`BL #0`), and emits one branch relocation against `other_fn`.

### Phase 3 - Literal pools and runtime references

Move strings, numeric constants, atoms, and current runtime helper references into direct sections and relocations.

Human-readable:

```text
    adrp x0, .Lstr@PAGE
    add  x0, x0, .Lstr@PAGEOFF
    adrp x9, silica_runtime_helper@PAGE
    add  x9, x9, silica_runtime_helper@PAGEOFF
    blr  x9
    ret

.Lstr:
    .asciz "ok"
```

Emitted:

```text
Instr.adrp_page { dst: X0, symbol: ".Lstr" }
Instr.add_pageoff { dst: X0, base: X0, symbol: ".Lstr" }
Instr.adrp_page { dst: X9, symbol: "silica_runtime_helper" }
Instr.add_pageoff { dst: X9, base: X9, symbol: "silica_runtime_helper" }
Instr.blr { target: X9 }
Instr.ret { }

CodeObject {
    sections: [
        { name: "__text", segment: "__TEXT",
          bytes: [0x00, 0x00, 0x00, 0x90,   // ADRP X0, .Lstr@PAGE
                  0x00, 0x00, 0x00, 0x91,   // ADD  X0, X0, .Lstr@PAGEOFF
                  0x09, 0x00, 0x00, 0x90,   // ADRP X9, helper@PAGE
                  0x29, 0x01, 0x00, 0x91,   // ADD  X9, X9, helper@PAGEOFF
                  0x20, 0x01, 0x3F, 0xD6,   // BLR  X9
                  0xC0, 0x03, 0x5F, 0xD6],  // RET
          alignment_log2: 2 },
        { name: "__cstring", segment: "__TEXT",
          bytes: [0x6F, 0x6B, 0x00],        // "ok\0"
          alignment_log2: 0 }
    ],
    symbols: [
        { name: "print_ok", section_name: "__text", offset: 0, global: true, external: false },
        { name: ".Lstr", section_name: "__cstring", offset: 0, global: false, external: false },
        { name: "silica_runtime_helper", section_name: "", offset: 0, global: false, external: true }
    ],
    relocations: [
        { section_name: "__text", offset: 0, kind: Arm64Page21, symbol: ".Lstr", addend: 0 },
        { section_name: "__text", offset: 4, kind: Arm64Pageoff12, symbol: ".Lstr", addend: 0 },
        { section_name: "__text", offset: 8, kind: Arm64Page21, symbol: "silica_runtime_helper", addend: 0 },
        { section_name: "__text", offset: 12, kind: Arm64Pageoff12, symbol: "silica_runtime_helper", addend: 0 }
    ]
}
```

### Phase 4 - Trial parity subset

Compile a selected integer/string/function-call subset through `--backend=direct-object`. Keep the assembly backend as the oracle while diagnostics mature. Same Silica input; two backends; same `.sout`.

Human-readable (Silica and the listing the assembly backend would have written):

```text
fn add2(a: int64, b: int64) -> int64 { a + b }

    add x0, x0, x1
    ret
```

Emitted (`--backend=direct-object`; same `Instr` / bytes as Phase 0, produced from the Silica AST rather than a hand spike):

```text
Instr.add_reg { width: 64, dst: X0, lhs: X0, rhs: X1 }
Instr.ret { }

CodeObject {
    sections: [
        { name: "__text", segment: "__TEXT",
          bytes: [0x00, 0x00, 0x01, 0x8B, 0xC0, 0x03, 0x5F, 0xD6],
          alignment_log2: 2 }
    ],
    symbols: [
        { name: "<module>_add2", section_name: "__text", offset: 0, global: true, external: false }
    ],
    relocations: []
}
```

### Phase 5 - Full Apple Silicon replacement candidate

Cover actor runtime helpers, Fifi thunks, aggregate returns, recursion support, memory-space barriers, and floating-point forms used by current trials.

Human-readable (device write that must order against `register_rwr`):

```text
    str  w1, [x0]
    dmb  sy
    isb
    ret
```

Emitted:

```text
Instr.str_imm { width: 32, src: W1, base: X0, offset: 0 }
Instr.dmb { domain: Sy }
Instr.isb { }
Instr.ret { }

CodeObject {
    sections: [
        { name: "__text", segment: "__TEXT",
          bytes: [0x01, 0x00, 0x00, 0xB9,   // STR W1, [X0]
                  0xBF, 0x3F, 0x03, 0xD5,   // DMB SY
                  0xDF, 0x3F, 0x03, 0xD5,   // ISB
                  0xC0, 0x03, 0x5F, 0xD6],  // RET
          alignment_log2: 2 }
    ],
    symbols: [ /* function plus actor / Fifi helper externs as required */ ],
    relocations: [ /* helper page/pageoff or BL records as required */ ]
}
```

Floating-point and aggregate-return forms follow the same pair: a listing for the trace, then `Instr` records and words already used by current trials. Actor and Fifi thunks add external symbols and relocations the same way Phase 2 and Phase 3 do.

### Phase 6 - Additional object formats and chips

After Mach-O is stable, reuse `chip/arm64` for ELF and OS-free board flows. Then add x86-64 and ESP32-S3 / Xtensa as separate chip layers. Do not generalize the object layer before one real target proves the separation is correct.

Same Silica lowering idea (`add` two integer arguments, return the sum). Human-readable listing and encoded bytes change per chip; `Instr` names stay family-specific.

AArch64 (ELF or Mach-O; same words as Phase 0, different object headers):

```text
    add x0, x0, x1
    ret

Instr.add_reg { width: 64, dst: X0, lhs: X0, rhs: X1 }
Instr.ret { }
bytes: [0x00, 0x00, 0x01, 0x8B, 0xC0, 0x03, 0x5F, 0xD6]
```

x86-64 SysV (args in `RDI` / `RSI`, result in `RAX`):

```text
    add  rdi, rsi
    mov  rax, rdi
    ret

Instr.add_reg { width: 64, dst: RDI, src: RSI }
Instr.mov_reg { width: 64, dst: RAX, src: RDI }
Instr.ret { }
bytes: [0x48, 0x01, 0xF7, 0x48, 0x89, 0xF8, 0xC3]
```

Xtensa encodings and object or firmware wrapping belong in `chip/xtensa` and the board-pack writer. Do not reuse AArch64 words or Mach-O page relocations for that family.
