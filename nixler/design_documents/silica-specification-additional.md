# Silica Specification — Additional Compiler Rules

## Related Documents

| Document | Purpose |
|----------|---------|
| [silica-specification.md](silica-specification.md) | Core language specification |
| [silica_sequence_blocks_tutorial.md](../tutorials_and_howtos/silica_sequence_blocks_tutorial.md) | Sequence block syntax (`sequence...produces pure...end`) |
| [sir_optimization_spec.md](../sir_optimization_spec.md) | SIR optimization passes |
| [sir_design_spec.md](../sir_design_spec.md) | SIR structure, terms, types, primitives |
| [actor_growable_stack_design.md](actor_growable_stack_design.md) | Per-actor growable stack and runtime actor loop |

---

## Implementation status (2026-10-16)

| Rule | Status |
| ---- | ------ |
| 3.1 Unused bindings | Implemented as `E1055 UnusedVariable` (parse stage, `parser/constraint_extract_validate.silica`): "unused variable '<name>' in this scope; use it, pass it to a function, return it, or bind it as `_`". A discarded binding is written `_` (`_: T <- expr`). The message text is the compiler's, not the wording given below |
| 3.2 Duplicate computation | NOT implemented; no diagnostic exists |
| 3.3 Redundant algebraic operations | NOT implemented |
| 3.4 Invariant guards in `case` | NOT implemented |
| 3.5, 3.6 Loop-invariant code, constant hoisting | NOT implemented |
| 3.7 Redundant constant expressions | NOT implemented (the compiler folds nothing and rejects nothing here) |
| 3.8 Multiply by power of two | NOT implemented |
| 4 Actor execution contract | Implemented as described; the behaviour's return forms are now the `(:reply, ...)` / `(:noreply, ...)` / state-only shapes of silica-specification.md section 15 |

Rules 3.2 to 3.8 remain a specification of intent. A new error code for any of them must be registered in `../error_codes.md` when it is implemented.

---

## 1. Scope

This specification defines additional compiler rules that cause **hard errors** at compile time. These patterns are anti-patterns that other languages allow (often with optimizer remediation); Silica rejects them outright. The compiler must fail with an error when any of these patterns are detected.

---

## 2. Design Rationale

Rather than optimizing away inefficient or redundant code, Silica enforces that programmers write efficient code by design. Patterns that would traditionally be fixed by optimization passes are instead rejected at compile time. This reduces reliance on optimizer heuristics and makes program behavior more predictable.

---

## 3. Compiler Failure Rules

### 3.1 Unused Bindings (Dead Code)

**Rule**: A `<-` binding whose variable is never used is a compile error.

**Anti-pattern**: Dead code; bindings that serve no purpose.

**Error message**: "Unused binding: `<name>` — remove it or use it."

**Applies to**: Source-level `pattern <- expression` bindings (represented as `let` terms in SIR).

---

### 3.2 Duplicate Computation (CSE)

**Rule**: Computing the same expression twice in the same scope with the same inputs is a compile error.

**Anti-pattern**: Duplicate subexpressions; the programmer should bind once and reuse.

**Error message**: "Duplicate computation: same expression appears twice — bind to a variable and reuse."

**Applies to**: SIR terms where identical expressions (same structure, same free variables) appear in the same scope.

---

### 3.3 Redundant Algebraic Operations

**Rule**: Redundant algebraic operations are compile errors.

**Anti-pattern**: Operations that have no effect: `x * 1`, `x + 0`, `x - 0`, `x * 0`, `x & 0`, `x | ~0`, etc.

**Error message**: "Redundant operation: `<expr>` — simplify to `<simplified>`."

**Applies to**: `prim` operations on SIR; equivalent source-level expressions.

**Examples**:
- `x * 1` → error: use `x`
- `x + 0` or `x - 0` → error: use `x`
- `x * 0` → error: use `0` (and review: the computation of `x` may be dead)
- `x & 0` → error: use `0`
- `x | ~0` → error: use `~0`

---

### 3.4 Invariant Guards in Case Expressions

**Rule**: A guard in a `case` expression that does not depend on any pattern bindings is a compile error.

**Anti-pattern**: Guards that could be evaluated before the case; the programmer should restructure.

**Error message**: "Guard does not depend on pattern bindings — move it before the case or restructure."

**Applies to**: SIR `case` terms; source-level `case` expressions with guards.

---

### 3.5 Loop-Invariant Code

**Rule**: An expression inside a loop (or tail-recursive body) that does not depend on any loop variables is a compile error.

**Anti-pattern**: Loop-invariant computations; the programmer should move them outside the loop.

**Error message**: "Loop-invariant expression — move outside the loop."

**Applies to**: Implicit loops formed by tail recursion; any recursive body where the expression does not depend on the recursive parameter or values derived from it.

---

### 3.6 Constant Hoisting (Loop Invariants)

**Rule**: A constant expression (or pure expression with no loop dependencies) inside a loop body is a compile error.

**Anti-pattern**: Constants recomputed every iteration; the programmer should hoist them.

**Error message**: "Constant expression in loop body — move outside the loop."

**Applies to**: Same context as §3.5; overlaps with loop-invariant but specifically targets constant literals and pure expressions.

---

### 3.7 Redundant Constant Expressions

**Rule**: Literal constant expressions that can be simplified to a single constant are compile errors.

**Anti-pattern**: Writing `2 + 3` instead of `5`, or `1 * x` instead of `x`; the programmer should write the minimal form.

**Error message**: "Redundant constant expression: `<expr>` — use `<minimal>`."

**Applies to**: SIR `const` and `prim` when all operands are constants; source-level literal arithmetic.

**Examples**:
- `2 + 3` → error: use `5`
- `1 * x` (when `1` is literal) → error: use `x`

---

### 3.8 Strength Reduction (Multiply by Power of Two)

**Rule**: Multiplying by a literal power of two (e.g. `x * 8`) is a compile error. The compiler performs strength reduction automatically; the programmer should not write multiplications that are trivially reducible to shifts.

**Anti-pattern**: Writing multiplications by powers of two that the compiler will internally lower to shifts; the programmer should write the minimal form.

**Error message**: "Multiply by literal power of two: `<expr>` — the compiler will lower this to a shift; simplify or use a named constant."

**Applies to**: `prim` multiply with literal power-of-two operand; source-level multiplication.

**Note**: Silica does not expose shift operators (`<<`, `>>`) as surface-language operators. The compiler's code generator handles strength reduction internally. This rule exists to flag trivially reducible multiplications at the source level.

**Examples**:
- `x * 8` → error: redundant literal power-of-two multiply
- `x * 16` → error: redundant literal power-of-two multiply

---

## 4. Actor execution (gen_server pattern)

This document does not duplicate §15–§16 of [silica-specification.md](silica-specification.md); it records the **architectural contract** for tooling and diagnostics:

1. **Runtime-owned loop**: The actor runtime performs `recv()` and then calls the user **behavior** `(Msg, State) -> State` once per message. The behavior is **not** defined as a user-level recursive receive loop.
2. **User behavior**: Returns updated state only; may contain `sequence` blocks that perform `send`, `cast`, and **replies** using the sender’s handle when the **message type** includes it (see §15.1.2, §16.2.1).
3. **Isolation**: `recv()` remains runtime-internal; conflating “behavior body” with “mailbox receive” in user code is inconsistent with the specification.

For stack growth and message-boundary semantics, see [actor_growable_stack_design.md](actor_growable_stack_design.md) §5.2.

---

## 5. Implementation Notes

1. **Detection phase**: These checks run during or after SIR construction, before optimization passes that would have previously remediated them.
2. **Diagnostics**: Each error names the problem and the specification section.
3. **No escape hatches**: These are hard errors. There are no pragmas or attributes to disable them.
4. **Order of application**: Dead code, CSE, and algebraic checks can run on SIR. Loop-invariant and guard-invariant checks require control-flow analysis (tail recursion structure, case structure).

---

## 6. Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.1 | 2026-04-03 | §4: Actor execution (gen_server pattern) cross-reference |
| 1.0 | 2025-02-12 | Initial specification; anti-patterns elevated to compile-time failures |
