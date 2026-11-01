# SIR Optimization Specification

## Related Documents

| Document | Purpose |
|----------|---------|
| [silica-compiler-creation-order.md](../silica-compiler-creation-order.md) | Pipeline overview; entry point for the compiler |
| [silica-specification-additional.md](silica-specification-additional.md) | Compiler failure rules: anti-patterns that must fail at compile time |
| [sir_design_spec.md](sir_design_spec.md) | SIR structure, terms, types, primitives |
| [sir_recursion_strategy.md](sir_recursion_strategy.md) | Recursion handling: tail calls, folds, explicit stack |

---

## 1. Scope

This specification defines the optimization passes applied to SIR (Silica Intermediate Representation). It applies to the Silica compiler pipeline from lexer through code generation (assembly emission). The assembler and linker are out of scope.

---

## 2. Design Conclusions

### 2.1 No Recursion-to-Loop Pass

Silica has no loops in its source language or AST; control flow is recursive. A dedicated recursion-to-loop optimization pass is **not used**.

**Rationale**: When the SIR-to-assembly code generator emits a jump for `tail_call` (instead of call+return), the resulting control flow already forms a loop. The back edge is implicit in the jump. Converting recursion to an explicit loop structure in the IR is redundant: the code generator can handle recursion directly by emitting the correct jump instruction for tail calls.

**Implementation**: The code generator treats `tail_call` as "emit jump to callee with arguments in registers." For a tail call to self, this produces a jump back to the function entry—equivalent to a loop—without any IR transformation.

### 2.2 Link-Time Optimization Out of Scope

LTO (link-time optimization) is **not implemented** by the Silica compiler. LTO happens during linking; the compiler does not implement the linker. Cross-module optimizations at link time are out of scope.

### 2.3 Code Layout Deferred

Arranging basic blocks for instruction cache locality and branch prediction can be deferred. It is optional and may be added later if needed.

### 2.4 Tail-Call Handling in Code Generation

Tail-call semantics are a **code generation responsibility**, not an optimization pass. The code generator must:

1. Recognize `tail_call` terms (and optionally `call` in tail position).
2. Emit a jump to the callee (e.g. `B symbol` on AArch64) with arguments in the correct registers.
3. **Not** emit call+return; no new stack frame is created.

---

## 3. Anti-Patterns: Compile-Time Failures

The following patterns are **not** optimizations; they are **compile-time errors**. The compiler must reject them. See [silica-specification-additional.md](silica-specification-additional.md) for full specification.

- Unused bindings (dead code)
- Duplicate computation (CSE)
- Redundant algebraic operations (`x * 1`, `x + 0`, etc.)
- Invariant guards in case expressions
- Loop-invariant code and constant hoisting
- Redundant constant expressions
- Multiply by power of two (use shift instead)

These checks run before optimization passes. Valid SIR will not contain these patterns.

---

## 4. Optimization Phases

Optimizations are split by representation:

- **On SIR**: Constant propagation, inlining, case compilation. These operate on SIR terms (`let`, `case`, `call`, `tail_call`, `prim`).
- **On AArch64 CFG (post-lowering)**: Optimizations on control flow formed by tail recursion (back edges from `B` to self), plus optional code layout for instruction cache and branch prediction. Silica has no explicit loops; these optimizations apply to implicit loops arising from tail recursion, not to loop constructs.

## 5. SIR Optimization Pass Order

Optimizations operate on SIR terms (`let`, `case`, `call`, `tail_call`, `prim`). Effect-aware rules apply: only inline when the caller's effect set includes the callee's; do not reorder effectful terms.

1. **Constant propagation**: Replace `var(%x)` with the constant value when `%x` is known to hold a constant.
2. **Inlining**: Replace `call` with the callee body when the callee is small or the call is hot. Effect-aware: only inline when caller effects include callee effects.
3. **Case compilation**: Compile `case` to decision tree or jump table.

Note: **Tail-call handling** is not an optimization pass; the code generator emits jumps for `tail_call` terms. For non-tail recursion (folds, explicit stack), see [sir_recursion_strategy.md](sir_recursion_strategy.md).

---

## 6. Optional Preprocessing

### 6.1 A-Normal Form

SIR can be converted to A-normal form before optimization: every non-trivial subterm is let-bound. This enables simpler analysis and further optimizations. See `sir_design_spec.md` Section 9.3.

---

## 7. Further Value-Level Optimizations

- **Strength reduction (non-power-of-two)**: Replace expensive `prim` operations with cheaper ones where applicable (e.g. `x * 3` with `x + x * 2`). Multiply by power of two is a compile error; see [silica-specification-additional.md](silica-specification-additional.md).

---

## 8. Region- and Memory-Related Optimizations

- **Region-aware allocation and layout**: Use region and lifetime information to improve memory layout and NUMA/cache-hierarchy placement.
- **Lifetime-based elimination**: Eliminate or shorten-lived allocations when region analysis shows an allocation is used only in a limited scope.
- **Memory space specialization**: Generate code and barriers appropriate to each space (normal, atomic, device) so optimizations do not break memory model guarantees.

---

## 9. Actor- and Concurrency-Related Optimizations

- **Actor and message-passing optimization**: Improve placement and scheduling of actors and message sends (e.g. batching, coalescing).
- **Effect lowering**: Map high-level effects (device_io, concurrency, mem) onto concrete runtime or hardware primitives before code generation.

---

## 10. Loop Optimizations (Implicit Loops)

Loops arise implicitly from tail calls: when the code generator emits a jump for `tail_call` to self, the resulting control flow has a back edge. Loop optimizations apply to this structure if implemented:

- **Induction variable optimization**: Simplify or eliminate induction variables inside loops.
- **Loop unrolling**: Partially or fully unroll loops when beneficial for instruction scheduling or branch overhead.

Note: Loop-invariant code and constant hoisting are **compile errors**; see [silica-specification-additional.md](silica-specification-additional.md).

These run on the CFG produced during lowering, not on SIR.

---

## 11. Vectorization

- **Automatic vectorization**: Detect scalar `prim` operations that can be expressed as vector operations and generate SVE or NEON instructions; align with Silica's list and buffer model.
- **Alignment and layout for vectors**: Ensure data layout and alignment support efficient vector loads and stores on AArch64.

---

## 12. Effect-Aware Optimization Rules

- **Inlining**: Only inline when the caller's effect set includes the callee's effects.
- **Reordering**: Do not reorder effectful terms relative to each other.

---

## 13. Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-02-10 | Initial specification; recursion-to-loop dropped; LTO out of scope |
| 1.1 | 2025-02-11 | Optimization phases (§3); SIR vs AArch64 CFG clarification |
| 1.2 | 2025-02-12 | Anti-patterns moved to compile-time failures (silica-specification-additional.md); refactored optimization list |
