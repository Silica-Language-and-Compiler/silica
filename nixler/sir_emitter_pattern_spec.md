# SIR to AArch64 Assembly Emitter Specification

## Document Purpose

This document specifies the use of Silica to implement pattern-based instruction selection for lowering SIR to AArch64 assembly. The emitter is written in Silica and uses `case` expressions with pattern matching and guards to select AArch64 instructions from SIR terms. This specification is intended for use by tools that generate or guide the creation of emitter code in Silica.

**Related Documents**

| Document | Purpose |
|----------|---------|
| [sir_design_spec.md](sir_design_spec.md) | SIR structure, types, terms, primitives (authoritative source for PrimOp and SIRTerm) |
| [sir_optimization_spec.md](sir_optimization_spec.md) | Optimization passes applied before emission |
| [sir_recursion_strategy.md](sir_recursion_strategy.md) | Tail calls, fold lowering, explicit-stack lowering |

---

## 1. Overview

### 1.1 Methodology

The emitter uses **declarative pattern-based instruction selection** implemented in Silica:

1. **Pattern matching**: Each SIR term (or flattened operation) is matched against structural patterns using Silica's `case` expression.
2. **Guards**: Constraints on operands (e.g., immediate range, alignment) are expressed as guards. The first matching branch with a satisfied guard is selected.
3. **Branch ordering**: Cheaper or preferred instruction forms are placed earlier in the `case`; fallback forms come later.
4. **Emit helpers**: Each branch invokes an emit function that produces assembly text or an abstract instruction representation.

### 1.2 Invocation Contract

- **Input**: SIRModule (or SIRFunction, SIRTerm) — the output of sir_generator after optimization.
- **Output**: AArch64 assembly text (or abstract instructions with virtual registers for a subsequent register allocation pass).
- **Dependencies**: sir_ast (SIRTerm, SIRFunction, SIRModule structures)

### 1.3 Pipeline Position

```
AST → sir_generator → SIR → optimization → emitter → AArch64 assembly
```

The emitter consumes optimized SIR and produces assembly. Register allocation may be integrated or a separate pass.

---

## 2. Directory Structure

```
emitter/
├── core.silica           # Entry point, orchestrates emission
├── Makefile
├── constraints/
│   └── constraints.silica   # Guard helpers: fits_imm12, fits_shifted_imm, etc.
├── terms/
│   ├── terms.silica         # Dispatcher: switch on SIRTerm.kind
│   ├── const.silica
│   ├── var.silica
│   ├── let.silica
│   ├── case.silica
│   ├── call.silica
│   ├── tail_call.silica
│   └── prims/
│       ├── prims.silica     # Dispatcher: switch on PrimOp
│       ├── arithmetic.silica
│       ├── comparison.silica
│       ├── logical.silica
│       ├── memory.silica
│       └── (vector.silica, string.silica, ... as capabilities added)
├── control/
│   └── control.silica      # Case-to-decision-tree, block layout
└── aarch64/
    └── aarch64.silica      # AArch64 instruction mnemonics, register names, conventions
```

**Naming**: Filenames do NOT use an `emitter_` prefix; directory provides context.

---

## 3. SIR Term Structure Reference

The emitter receives SIR in the form defined by sir_ast and sir_design_spec. Key structures:

### 3.1 SIRTerm (sir_ast)

| kind | Term | Fields used |
|------|------|-------------|
| 0 | const | type_name, value |
| 1 | var | name |
| 2 | let | name, type_name, inner (binder term), (continuation in extended structure) |
| 3 | case | type_name, (scrutinee, branches in extended structure) |
| 4 | call | type_name, name (callee), value (effect set), (args in extended structure) |
| 5 | tail_call | name (callee), (args in extended structure) |
| 6 | prim | type_name, name (PrimOp string), value (arg encoding), inner (nested structure) |

**Note**: The actual sir_ast.silica SIRTerm struct may use a linked/encodied representation. The emitter must handle the structure as implemented. Extend sir_ast if richer term representation (e.g., explicit arg lists for prim) is needed for pattern matching.

### 3.2 PrimOp Reference

PrimOps are defined in sir_design_spec §7. The emitter dispatches on the PrimOp name (string) and argument forms. Reference:

- **Arithmetic**: add, sub, mul, div, rem, neg
- **Comparison**: eq, ne, lt, le, gt, ge
- **Logical**: and, or, not
- **Memory**: alloc_region, alloc_ref, read_ref, write_ref, alloc_buf, buf_load, buf_store
- **Atomic**: atomic_load, atomic_store, atomic_add, atomic_sub, atomic_cas
- **Tuple/Record**: tuple_proj, record_proj, tuple_make, record_make
- **Variant**: variant_tag, variant_payload, variant_make
- **List**: list_nil, list_cons, list_is_nil, list_head, list_tail
- **Actor**: spawn, send, recv
- **String**: string_concat, string_length, string_eq
- **Device I/O**: print, println, print_int64, read_line
- **Cast**: cast
- **Vector**: vec_load, vec_store, vec_add, vec_sub, vec_mul, vec_cmp_eq, vec_cmp_lt, vec_select

---

## 4. Pattern Structure

### 4.1 Pattern Components

Each selectable instruction form is a `case` branch:

1. **Pattern (LHS)**: Structural match on the SIR term — e.g., `prim` with specific PrimOp and argument forms (var, const).
2. **Guard**: Boolean condition on bound variables — e.g., `fits_imm12(k)`.
3. **Body (RHS)**: Call to an emit function that produces assembly.

### 4.2 Argument Forms

When matching `prim` operands, classify each argument:

| Form | SIR term | Binding |
|------|----------|---------|
| var | var(name) | Binds register/variable name |
| const | const(type, value) | Binds constant value (parse for integer/float) |
| any | — | Matches any form (used when both reg and imm are acceptable) |

### 4.3 Dispatch Order

1. **By SIR term kind**: `case term.kind of { 0 -> const_emit(...); 1 -> var_emit(...); 6 -> prim_emit(...); ... }`
2. **By PrimOp**: `case prim_op_name of { "add" -> emit_add(...); "sub" -> emit_sub(...); ... }`
3. **By argument forms**: `case (arg1_form, arg2_form) of { (var, var) -> ...; (var, const) if fits_imm12(k) -> ...; (var, const) -> ... }`

Cheaper patterns (e.g., reg+imm) come before fallback patterns (e.g., reg+reg with MOV).

### 4.4 Flat Case Structure

**Avoid deep case-in-case nesting.** Prefer more branches at the first or second level rather than nesting `case` expressions. Flatten by:

- Expanding compound patterns into separate top-level branches (e.g., `(PrimOp "add", Var(a), Var(b))` as one branch, `(PrimOp "add", Var(a), Const(k))` as another, not a nested case on arg forms).
- Using guards to distinguish variants instead of inner `case` on the same scrutinee.
- Delegating to helper functions that return a value, rather than to helpers that perform another `case` on sub-components.

A single `case` with many branches is preferred over nested `case` expressions. This improves readability and reduces indentation.

---

## 5. Constraint Helpers

Place constraint checks in `constraints/constraints.silica`. These are used as guards.

### 5.1 AArch64 Immediate Constraints

| Helper | AArch64 context | Meaning |
|--------|-----------------|---------|
| fits_imm12 | ADD/SUB 12-bit unsigned | 0 ≤ k < 4096 |
| fits_imm12_signed | Some signed immediates | -4096 ≤ k < 4096 |
| fits_logical_imm | Logical (AND/ORR) | Encodable as bitmask immediate |
| fits_shifted_imm | MOV with shift | Encodable as 16-bit value with optional shift |
| fits_load_store_offset | LDR/STR offset | Alignment-dependent; 0 ≤ offset < 4096 for 64-bit |

### 5.2 Implementation Note

Helpers are pure functions: `fn fits_imm12(k: int64) -> bool`. They take the constant value (parsed from SIR const) and return whether the constraint holds.

---

## 6. Emit Function Convention

### 6.1 Signature Pattern

Emit functions receive:

- **dest**: Where the result goes (virtual register name or physical reg, e.g. `%dest`, `X0`).
- **Operands**: Names or values bound by the pattern (e.g., `a`, `b` for var; `k` for const).
- **Context**: Optional emitter state (e.g., label counter, register allocator, effect set).

Return: Assembly lines (string or list of abstract instructions).

### 6.2 Assembly Output Format

Emit functions produce AArch64 assembly syntax. Examples:

- `ADD X0, X1, X2`
- `ADD X0, X1, #42`
- `LDR X0, [X1, #8]`
- `B label_name`
- `RET`

Use virtual registers (e.g., `%v0`, `%v1`) if register allocation is a separate pass. The allocator replaces them with X0–X30, SP, etc.

---

## 7. AArch64 Instruction Mapping

### 7.1 Arithmetic (int64)

| SIR prim | Arg forms | AArch64 |
|----------|-----------|---------|
| add | (var, var) | ADD dest, a, b |
| add | (var, const) if fits_imm12 | ADD dest, a, #k |
| add | (var, const) | MOV tmp, #k; ADD dest, a, tmp |
| sub | (var, var) | SUB dest, a, b |
| sub | (var, const) if fits_imm12 | SUB dest, a, #k |
| mul | (var, var) | MUL dest, a, b |
| neg | (var) | NEG dest, a |

Extend for int32/int16/int8 (W registers, size suffix) and float (F/S/D registers, FADD, etc.) per sir_design_spec §7.

### 7.2 Comparison (bool from eq/ne/lt/le/gt/ge)

| SIR prim | Arg forms | AArch64 |
|----------|-----------|---------|
| eq | (var, const 0) | CMP a, #0; CSET dest, EQ |
| eq | (var, var) | CMP a, b; CSET dest, EQ |
| lt | (var, var) | CMP a, b; CSET dest, LT |
| ne | (var, const 0) | CMP a, #0; CSET dest, NE |

### 7.3 Memory

| SIR prim | AArch64 |
|----------|---------|
| read_ref | LDR dest, [ref] |
| write_ref | STR value, [ref] |
| alloc_region | Runtime call or custom allocator |
| alloc_ref | Store value at region offset; ref = base + offset |

Effect annotations (mem(normal), mem(atomic)) determine barrier placement; see sir_design_spec §4.

### 7.4 Control Flow

| SIR term | AArch64 |
|----------|---------|
| const | MOV dest, #value (or load from literal pool for large values) |
| var | Already in register; use dest = a (or MOV dest, a if needed) |
| tail_call | B callee_symbol (no return) |
| call | BLR callee_symbol; result in X0 |

---

## 8. Case Term Handling

`case` terms are not instruction selection; they are control-flow lowering. Handle separately:

1. **Case to decision tree**: Compile scrutinee, then for each branch: test pattern (variant tag, literal, etc.), branch to block, bind variables, emit branch body.
2. **Pattern matching**: Use `case` in Silica to match SIRPattern kind (literal_pattern, var_pattern, variant_pattern, etc.) and emit the corresponding test (CMP, TBZ, jump table).
3. **Block layout**: Emit labels for each branch body; use B/CBZ/TBZ to select.

Reference: sir_design_spec §10.1 phases 1–2.

---

## 9. Extensibility Rule

When adding support for a new PrimOp or SIR term:

1. Add the PrimOp to the prims dispatcher in `terms/prims/prims.silica`.
2. Create or extend the capability module (e.g., `terms/prims/arithmetic.silica`).
3. Add `case` branches for each instruction form. Place preferred forms first.
4. Add guards for constraints. Add constraint helpers to `constraints/constraints.silica` if new.
5. Implement emit functions for each pattern body.

---

## 10. Branch Ordering Convention

Within a `case` for a given PrimOp:

1. **Immediate forms first** (when constraint holds): e.g., `(var, const)` with `fits_imm12(k)`.
2. **Register forms**: e.g., `(var, var)`.
3. **Fallback forms**: e.g., `(var, const)` without constraint — emit MOV then op.

This ordering encodes a simple cost model: immediates are cheaper than extra moves.

---

## 11. Example Silica Pattern (Conceptual)

```silica
-- terms/prims/arithmetic.silica
-- emit_prim_add: given dest, and args (as (form, term) or similar), select instruction
fn emit_prim_add(ctx: EmitContext, dest: string, arg1: SIRTerm, arg2: SIRTerm) -> ListString proc[mem(normal)] {
    case (arg_form(arg1), arg_form(arg2)) of
        (Var(a), Var(b)) -> emit_add_reg_reg(ctx, dest, a, b);
        (Var(a), Const(k)) if constraints@fits_imm12(k) -> emit_add_reg_imm(ctx, dest, a, k);
        (Var(a), Const(k)) -> emit_add_reg_imm_via_mov(ctx, dest, a, k);
        (Const(k), Var(a)) if constraints@fits_imm12(k) -> emit_add_reg_imm(ctx, dest, a, k);
        (Const(k), Var(a)) -> emit_add_reg_imm_via_mov(ctx, dest, a, k);
        _: (ArgForm, ArgForm) -> emit_add_reg_reg(ctx, dest, eval_to_reg(ctx, arg1), eval_to_reg(ctx, arg2))
    end
}
```

The tool generating emitter code should produce structure of this form: dispatch by arg form, guards for constraints, ordered branches.

---

## 12. Reference Documents (Tool Instructions)

A tool that generates or guides emitter code MUST reference:

- `AArch64/silica-compiler/sir_design_spec.md` — SIR grammar, PrimOp list (§7), term structure (§5)
- `AArch64/silica-compiler/sir_ast.silica` — Actual SIRTerm/SIRFunction/SIRModule struct definitions
- `AArch64/silica-compiler/sir_recursion_strategy.md` — Tail call handling, explicit stack

---

## 13. Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-02-12 | Initial specification |
