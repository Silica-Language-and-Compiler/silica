# Direct machine object emitter

**Status:** Future development. Not implemented. Not normative for the current compiler. The current Apple Silicon path emits assembly text and lets the platform assembler produce object files. This document records the intended future direction for replacing that assembly step with Silica-owned chip instruction encoders and relocatable object writers.

## Implementation status (2026-10-16)

Still not implemented; the design is unchanged. What exists today: four assembly-text backends in `compiler/src/emitter/` (`apple_silicon_mac`, `linux_aarch64`, `linux_x86_64`, `ESP32-S3_raw`), each producing `.sams` text that the host or cross toolchain assembles and the platform linker links (`make` stages `.sams -> .o -> link`). The ESP32-S3 backend is native Xtensa LX7 bare metal with no IDF; its instruction selection (`emitter/ESP32-S3_raw/shared/xt_isa.silica`, over virtual registers in `xt_vr.silica`) still produces assembly text. The first implementation target named in section 3 (Apple Silicon Mach-O) is therefore no longer the only existing backend, and the x86-64 and Xtensa rows of the section 4 table describe targets that now have text backends; "Hardware behavior to expose" entries mentioning IDF-style cache synchronization and PSRAM do not match the shipped ESP32-S3 port (internal SRAM only).

---

## Related Documents


| Document                                                                                       | Purpose                                                                                                          |
| ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| [silica-specification.md](silica-specification.md)                                             | AArch64-native language intent, x86-64 containment notes, effects, memory spaces, actors, and compiler interface |
| [silica-compiler-code-organization.md](silica-compiler-code-organization.md)                   | Compiler directory organization and modularity expectations                                                      |
| [memory-effects-aarch64-implementation-plan.md](memory-effects-aarch64-implementation-plan.md) | AArch64 and embedded memory-space lowering, including ESP32-S3 / Xtensa notes                                    |
| [porting_for_os_free_targets.md](porting_for_os_free_targets.md)                               | OS-free / raw-metal port inventory (MMIO prims, boot, board packs)                                               |
| [recursion_implementation.md](recursion_implementation.md)                                     | Stack, tail-call, trampoline, and preemption implications for emitted code                                       |
| [silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md)                     | Fifi link boundaries, foreign symbols, and dangerous-worker integration                                          |


---

## 1. Purpose

Silica is intended to expose chip behavior directly and deliberately. The current language and compiler documents emphasize AArch64, but they also name x86-64 for MPK-backed containment and ESP32-S3 / Xtensa as an embedded memory-space target. Emitting assembly text is useful during compiler bring-up, but it hides the final machine representation behind an external parser and encoder. The future direct object emitter makes the compiler responsible for:

1. Selecting concrete instruction forms for the active chip family.
2. Encoding each instruction into its exact target byte representation.
3. Recording labels, symbols, sections, and relocations needed by the linker.
4. Writing a relocatable object file that can be linked with other Silica objects, runtime objects, and approved foreign objects.

The goal is not merely faster compilation. The goal is a compiler architecture where Silica can reason about the chip-shaped facts it exposes: registers, flags, barriers, atomic operations, cache and memory attributes, PC-relative addressing, branch ranges, alignment, literal pools, system/privilege boundaries, and object-file relocation boundaries.

---

## 2. Current state

The current Apple Silicon emitter returns assembly strings. Many term emitters produce fragments such as:

```text
ADRP X9, symbol@PAGE
ADD  X9, X9, symbol@PAGEOFF
BLR  X9
```

The generated `.sams` assembly is then assembled into `.o` files by the host toolchain. This keeps early implementation simple, but it means Silica does not own the instruction encoding or relocation model. It also makes hardware-facing features pass through text syntax before becoming the values the chip and linker actually consume.

The future direct emitter keeps the existing lowering knowledge, but changes the emitted artifact from text to structured code.

---

## 3. Non-goals

- Replacing the platform linker.
- Implementing a full general-purpose assembler syntax.
- Using LLVM, Cranelift, or another backend/object library for this path.
- Removing the existing assembly path before the direct path passes equivalent trials.
- Defining every instruction for every supported chip before integration starts.
- Making object emission a separate compiler or application with duplicated Silica lowering logic.
- Promising portable object-file output for all targets at once.
- Claiming that all chips expose the same memory, privilege, atomic, vector, or protection behavior.

The first implementation target remains **Apple Silicon macOS AArch64 Mach-O relocatable object files**, because that matches the current self-hosted emitter directory and existing trial flow. The design, however, must allow other chips already named in the documentation: generic AArch64 OS-free boards, **x86-64**, and **ESP32-S3 / Xtensa LX7**. Other chips can follow only when a document names their hardware contract.

---

## 4. Target families

The direct emitter is a family of chip-specific encoders, not one universal byte generator.


| Target family               | Initial object format                              | Hardware behavior to expose                                                                                                                               |
| --------------------------- | -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Apple Silicon AArch64 macOS | Mach-O relocatable                                 | AArch64 registers, weak memory ordering, barriers, NEON, optional SVE/SVE2 where present, MTE/PAC notes where usable from the runtime                     |
| Generic AArch64 OS-free     | ELF relocatable or final firmware image, per board | `MAIR_EL1`, page attributes, device memory, LDAR/STLR, DMB/DSB/ISB, system-register privilege boundaries                                                  |
| x86-64 hosted               | ELF, Mach-O, or COFF depending on OS               | GPR/SIMD register classes, TSO memory model, fences/locked operations, MPK for FFI containment where available                                            |
| ESP32-S3 / Xtensa LX7       | ELF or board-pack firmware image                   | Xtensa registers and call ABI, dual-core ordering, internal RAM vs PSRAM, DMA-capable buffers, peripheral/device regions, IDF-style cache synchronization |


A target entry is not a promise that the current compiler supports that target. It is a requirement that the future direct-emitter architecture not bake AArch64 assumptions into the common layers.

---

## 5. Architecture

The design has three layers.


| Layer                     | Responsibility                                                                                                                            |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `chip/<family>`           | Registers, instruction forms, encodings, barriers, atomics, branch ranges, memory/protection features, and ABI-facing instruction helpers |
| `object/<format>`         | Mach-O / ELF / COFF sections, symbols, string table, relocation entries, header layout, and object writing                                |
| `emitter/<target>/direct` | SIR-to-code lowering, Silica symbol naming, literal pools, runtime dependencies, Fifi linkage, and target calling-convention decisions    |


The chip layer must not know Silica names, module interfaces, actors, or Fifi. The object layer must not know SIR terms. The direct emitter is the bridge between Silica semantics and the selected target.

---

## 6. Core data model

Assembly strings are replaced by a structured code value.

```text
CodeObject {
    sections: List[Section],
    symbols: List[Symbol],
    relocations: List[Relocation],
    entry_points: List[string],
    diagnostics: List[EmitterDiagnostic]
}

Section {
    name: string,
    segment: string,
    bytes: List[uint8],
    alignment_log2: int64,
    attributes: int64
}

Symbol {
    name: string,
    section_name: string,
    offset: int64,
    global: bool,
    external: bool
}

Relocation {
    section_name: string,
    offset: int64,
    kind: RelocKind,
    symbol: string,
    addend: int64
}
```

Exact field names may differ in implementation. The required distinction is stable: bytes are already encoded machine code or data; unresolved addresses are relocations; exported and imported names are symbols.

---

## 7. Instruction representation

Instruction emission should be chip-shaped, not assembly-shaped.

```text
Instr.add_reg {
    width: 64,
    dst: X0,
    lhs: X1,
    rhs: X2
}

Instr.adrp_page {
    dst: X9,
    symbol: "module_function"
}
```

The instruction encoder lowers these forms to the byte representation for the selected chip family. For AArch64 this is a 32-bit instruction word stored little-endian. For x86-64 it is a variable-length byte sequence. For Xtensa it follows the selected Xtensa instruction width and encoding mode. A relocation-bearing instruction is still encoded immediately, with placeholder immediate or address bits where required, and paired with a relocation record.

This representation gives Silica a place to expose and validate chip behavior before the final bytes are written.

Each chip family defines its own instruction variants. AArch64 has `ADRP`, `ADD`, `BLR`, `DMB`, and `LDAR` / `STLR`. x86-64 has variable-length encodings, ModR/M and SIB addressing, `LOCK`-prefixed atomics, fences, and MPK instructions where available. Xtensa has its own register windows/calling convention details, instruction widths, and memory/cache-control requirements. These differences belong in `chip/<family>`, not in shared Silica lowering.

---

## 8. Initial AArch64 instruction subset

The first implementation should cover only the current emitter surface needed by small trials.


| Group          | Initial forms                                                                       |
| -------------- | ----------------------------------------------------------------------------------- |
| Control        | `RET`, `B`, `BL`, `BR`, `BLR`, conditional branches used by current lowering        |
| Integer data   | `MOV` register aliases, `ADD`, `SUB`, `MUL`, compare/subtract forms already emitted |
| Memory         | Common `LDR` / `STR` register+immediate forms for current stack and record access   |
| Addressing     | `ADRP symbol@PAGE`, `ADD reg, reg, symbol@PAGEOFF`                                  |
| Barriers       | `DMB`, `DSB`, `ISB` forms required by effect lowering                               |
| Floating point | Only forms already emitted by existing trials, added after the integer path works   |


The encoder must reject impossible operands instead of producing a best-effort word. Examples: out-of-range immediates, invalid register class, misaligned branch target, and unsupported relocation kind for an instruction form.

---

## 9. Relocations

Direct object emission becomes useful only when it can describe link-time unknowns. The first Mach-O relocation set should match the current assembly patterns:


| Assembly pattern                | Direct emitter behavior                                               |
| ------------------------------- | --------------------------------------------------------------------- |
| `ADRP Xn, symbol@PAGE`          | Encode `ADRP` placeholder and emit page relocation against `symbol`   |
| `ADD Xn, Xn, symbol@PAGEOFF`    | Encode `ADD` placeholder and emit pageoff relocation against `symbol` |
| `BL symbol`                     | Encode branch placeholder and emit branch relocation against `symbol` |
| local label branch              | Resolve during emission when target offset is known                   |
| string / literal pool reference | Use section symbol plus offset relocation where needed                |


Indirect calls through function values may continue to lower through materialized addresses and `BLR`. Direct calls may use `BL` when branch relocation and range behavior are implemented.

Relocation records are part of the compiler output contract. The direct emitter must never silently bake in an address that belongs to the linker.

Each chip/object pair owns its relocation vocabulary. AArch64 Mach-O page/pageoff relocations do not generalize to x86-64 RIP-relative relocations or Xtensa firmware images. The shared contract is only this: unresolved addresses are represented explicitly, validated for the active object format, and left for the linker or firmware image writer at the correct boundary.

---

## 10. Object-file scope

The first object writer targets Mach-O relocatable objects on Apple Silicon macOS.

Minimum sections:


| Section                                | Purpose                                               |
| -------------------------------------- | ----------------------------------------------------- |
| `__TEXT,__text`                        | Encoded function bodies and runtime helper code       |
| `__TEXT,__cstring` or `__TEXT,__const` | String constants and read-only data where appropriate |
| `__DATA,__data`                        | Writable data that must be present at link time       |
| `__DATA,__bss`                         | Zero-filled data when required by runtime helpers     |


Minimum object features:

1. Mach-O 64-bit header for ARM64.
2. Segment/section descriptions for a relocatable object.
3. Symbol table and string table.
4. Relocation tables per section.
5. Section alignment and file offsets computed by the writer.

Debug information, unwind information, dead-strip hints, and compact unwind are future additions. The first milestone may omit them if linked programs still run correctly for the covered trials.

Later object writers:


| Format                | Targets                                                                                                  |
| --------------------- | -------------------------------------------------------------------------------------------------------- |
| ELF                   | Linux AArch64, bare-metal AArch64 board flows, x86-64 Linux, Xtensa/ESP32-S3 toolchains where applicable |
| Mach-O                | Apple Silicon macOS, possible x86-64 macOS maintenance target                                            |
| COFF                  | Windows x86-64 and future Windows ARM64 work if the language targets it                                  |
| Firmware image writer | OS-free boards where a relocatable object is not the final useful artifact                               |


---

## 11. Compiler integration

The direct emitter should be integrated as a compiler-internal module, not as a separate app. It needs existing compiler knowledge: Silica module linkage, exported function naming, arity, literal pools, runtime dependencies, aggregate return lowering, actor runtime helpers, and Fifi boundaries.

Recommended source layout:

```text
compiler/src/
    chip/arm64/
        arm64_registers.silica
        arm64_instructions.silica
        arm64_encode.silica
        arm64_relocs.silica

    chip/x86_64/
        x86_64_registers.silica
        x86_64_instructions.silica
        x86_64_encode.silica
        x86_64_relocs.silica

    chip/xtensa/
        xtensa_registers.silica
        xtensa_instructions.silica
        xtensa_encode.silica
        xtensa_relocs.silica

    object/macho/
        macho_sections.silica
        macho_symbols.silica
        macho_relocations.silica
        macho_writer.silica

    object/elf/
        elf_sections.silica
        elf_symbols.silica
        elf_relocations.silica
        elf_writer.silica

    emitter/apple_silicon_mac/direct/
        direct_emitter_core.silica
        direct_term_emitter.silica
        direct_literal_pools.silica
        direct_runtime_helpers.silica

    emitter/x86_64_hosted/direct/
        direct_emitter_core.silica

    emitter/esp32s3_xtensa/direct/
        direct_emitter_core.silica
```

The exact directory names can change to match implementation pressure, but the separation of chip, object, and Silica lowering should remain.

During transition, the compiler should expose an explicit option such as:

```text
--backend=asm
--backend=direct-object
```

The assembly backend remains the default until the direct backend passes the selected trial set.

---

## 12. Test strategy

Testing should be staged so failures identify the layer that broke.

1. **Encoding tests:** Known instruction forms produce exact words or byte sequences for the selected chip family.
2. **Object smoke tests:** A generated object with one exported function links with a tiny C or Silica caller.
3. **Relocation tests:** `ADRP` / `ADD` / `BL` references survive object writing and link correctly.
4. **Trial parity:** Existing `.silica` trials compile through both backends and produce the same `.sout`.
5. **Negative tests:** Invalid immediates, invalid register classes, and unsupported relocation combinations fail at compile time with direct emitter diagnostics.

The trial path should keep generated assembly outputs for the assembly backend and add direct-object outputs only where useful. Object bytes are not stable across every writer change; behavior and linker acceptance matter more than byte-for-byte object snapshots.

Cross-chip tests must include chip-specific negative cases. Examples: AArch64 page relocation used with an x86-64 object writer must fail; x86-64 MPK instructions must fail when the target feature is absent; ESP32-S3 DMA/noncacheable buffer lowering must fail when the selected board pack cannot provide the required memory capability.

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

---

## 14. Risks

- Mach-O relocation details are easy to almost implement. The writer must be tested through the real linker early.
- A text assembler currently catches many invalid instruction forms. The direct emitter must replace that safety with explicit validation.
- Branch and immediate ranges need diagnostics before large generated functions rely on them.
- Debuggability may temporarily get worse when `.sams` text is bypassed. The direct backend should support an optional disassembly-like trace for human inspection.
- Unwind information may become necessary for better crash handling and interop. It is not a Phase 0 requirement, but it should not be designed out.
- AArch64 assumptions are already present in the language and emitter. Shared direct-emitter code must not accidentally encode those assumptions for x86-64 or Xtensa.
- x86-64 uses variable-length instructions and different relocation habits, so the AArch64 fixed-width encoder model cannot be the shared abstraction.
- ESP32-S3 support depends on board-pack memory capability declarations, not just instruction encoding.

---

## 15. Design rule

The direct emitter should make hardware facts explicit in compiler data. It should not treat machine code as an opaque byte string assembled by scattered helpers.

When a Silica feature has chip-specific meaning, the compiler is to point at the exact instruction form, register class, memory ordering rule, protection mechanism, memory-space capability, and relocation boundary that implement it on the selected target.