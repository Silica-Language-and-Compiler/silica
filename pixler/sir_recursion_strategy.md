# SIR Recursion Strategy

This document is the **single source of truth** for how the Silica compiler handles recursion. It covers tail recursion, non-tail recursion, fold recognition, and explicit-stack lowering.

---

## Related Documents

| Document | Purpose |
|----------|---------|
| [silica-compiler-creation-order.md](../silica-compiler-creation-order.md) | Pipeline overview; entry point for the compiler |
| [sir_design_spec.md](sir_design_spec.md) | SIR structure, terms, types, primitives, lowering |
| [sir_optimization_spec.md](sir_optimization_spec.md) | Optimization phases, passes, and effect-aware rules |

---

## 1. Recursion Types

| Type | Description | Stack growth? | Handled by |
|------|-------------|---------------|------------|
| **Tail recursion** | Recursive call is the last action before return | No (jump) | Code generation |
| **Linear non-tail** | Single recursive call; accumulator convertible | Yes (or use accumulator) | Fold or explicit stack |
| **Tree-shaped** | Multiple recursive calls (e.g. Fibonacci, tree traversal) | Yes | Fold or explicit stack |
| **Nested** | Recursive call inside argument (e.g. McCarthy 91) | Yes | Explicit stack |
| **Mutual** | Two or more functions call each other recursively | Yes | Fold or explicit stack |

---

## 2. Tail Recursion

**Handling**: Code generation responsibility. No IR transformation.

The code generator emits a jump (e.g. `B symbol` on AArch64) for `tail_call` terms instead of call+return. For a tail call to self, this produces a jump back to the function entry—equivalent to a loop—without any IR transformation.

See [sir_optimization_spec.md](sir_optimization_spec.md) Section 2.4 for tail-call implementation details.

---

## 3. Fold Recognition and Lowering

For recursions that can be expressed as folds over data structures, the compiler may recognize the pattern and lower to an iterative fold.

### 3.1 When Folds Apply

| Recursion type | Fold? | Notes |
|----------------|-------|-------|
| Tree-shaped over data structures (lists, trees) | Yes | Direct fold over the structure |
| Tree-shaped over indices (e.g. Fibonacci) | Yes* | Restructure: fold over `[0..n]` with state |
| Nested (e.g. McCarthy 91) | No | No natural fold structure |
| Mutual | Yes | Fold producing a tuple of both results |

### 3.2 Lowering

When a fold pattern is recognized:

1. Emit iterative code that traverses the structure with an explicit stack or work queue.
2. Use the monoid (or combine operation) to accumulate results.
3. No call-stack growth; recursion is eliminated.

---

## 4. Explicit-Stack Lowering

For recursions that do not fit folds (e.g. nested recursion, or when fold recognition fails), the compiler lowers to iterative code with an explicit heap-allocated stack.

### 4.1 Approach

1. Analyze the recursion pattern from SIR `call` and `tail_call` terms.
2. Emit iterative code (a loop in the AArch64 CFG) that:
   - Pushes pending work (arguments, return address) onto a heap-allocated stack
   - Pops work, computes, and pushes new work until the stack is empty
3. The call stack stays bounded; recursion is converted to iteration + explicit stack.

### 4.2 Scope

Works for any recursion: tree-shaped, nested, mutual. The cost is heap allocation for the stack.

---

## 5. Strategy Summary

| Situation | Strategy |
|-----------|----------|
| Tail call | Codegen emits jump; no transformation |
| Fold-recognizable | Lower to iterative fold |
| Other | Lower to iterative + explicit stack |

---

## 6. Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-02-10 | Initial specification |
| 1.1 | 2025-02-11 | Related Documents update; explicit-stack lowering AArch64 CFG clarification |
