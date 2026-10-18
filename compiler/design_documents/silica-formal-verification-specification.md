# Silica Formal Verification Specification

**Status:** Initial document. Extends to cover recursive tuple types. Implementation status below.

**Related:** [recursive_tuple_specification.md](recursive_tuple_specification.md)

---

## Implementation status (2026-10-16)

This document states proof-side rules; the compiler contains no mechanized proof checker or proof-term output. What the compiler implements of the judgments it names:

- Section 2.4: the 8-parameter limit is enforced at parse time as `E1070 FunctionTooManyParameters` for every target, not only AArch64 (the parser does not look at the emit target).
- Sections 5.1 to 5.4: `rec`, `ref?` and the occurs-checked structural equality are implemented in `src/type_checker/type_checker_recursive_tuples.silica` (see [recursive_tuple_specification.md](recursive_tuple_specification.md)).
- Section 6: region lifetime analysis is partly implemented in the type checker (`type_checker_memory_regions.silica`) and the scope rules of `silica-specification.md` section 12.1.4; the remaining gaps are tracked in [region_memory_safety_design.md](region_memory_safety_design.md) and `Phase1_TODOs/region_memory_safety_todo.md`. Not verified here: whether every extended-judgment rule in section 6 is enforced.

---

## 1. Overview

This document specifies the formal verification framework for Silica, including type-theoretic foundations and proof terms. The value calculus (Layer 1) handles product types and is extended to support recursive product types.

---

## 2. Language Semantics (Relevant to Verification)

### 2.1 Function Return Semantics

User-defined functions return the result of the last expression in the function body. There is no `return` keyword; the value of the final expression is implicitly the return value. No semicolon is required for the final expression. For example, `fn main() -> int64 { 42 }` returns 42.

### 2.2 Module-Qualified Function Calls

The `@` operator discriminates between the module name and the function name for any function that exists in a different module: `ModuleName@function_name(args)`.

### 2.3 Atom Literals

The `@` character is never used as an indicator of the end of an atom name; it is reserved for module@function qualified calls.

### 2.4 Parameter Limit (AArch64)

A function may have at most 8 parameters. The AArch64 architecture provides 8 argument registers (X0–X7) per procedure call. Arguments beyond the first 8 must be passed on the stack, which is less efficient than register passing. Silica enforces this limit at parse time (error E1070). Functions requiring more than 8 arguments should be refactored to use tuples or records to group related parameters. See silica-specification.md §3.4.1.

---

## 3. Curry–Howard Foundation

Silica's type system corresponds to a logical calculus via the Curry–Howard isomorphism:

- **Types** ↔ **Propositions**
- **Terms** ↔ **Proofs**
- **Type checking** ↔ **Proof verification**

---

## 4. Layer 1: Value Calculus (λΠ + Sums and Products)

### 4.1 Product Types (Existing)

Product type A × B corresponds to conjunction A ∧ B.

**Introduction:**
```
Γ ⊢ e₁ : T₁    Γ ⊢ e₂ : T₂
────────────────────────────
Γ ⊢ (e₁, e₂) : (T₁, T₂)
```

**Elimination:**
```
Γ ⊢ e : (T₁, T₂)
─────────────────
Γ ⊢ πᵢ(e) : Tᵢ
```

---

## 5. Recursive Product Types (Extension)

### 5.1 Formation

A recursive tuple type `(T₁, rec, rec)` has `rec` referring to the enclosing tuple type. The type checker resolves `rec` via structural equality with occurs check.

### 5.2 Introduction Rule

```
Γ ⊢ e₁ : T₁
Γ ⊢ e₂ : T₂[rec ↦ (T₁, rec, rec)]
Γ ⊢ e₃ : T₃[rec ↦ (T₁, rec, rec)]
────────────────────────────────────────────────────────
Γ ⊢ (e₁, e₂, e₃) : (T₁, rec, rec)
```

Where `T₂[rec ↦ (T₁, rec, rec)]` denotes substitution of `rec` by the enclosing tuple type.

### 5.3 Elimination Rule

```
Γ ⊢ e : (T₁, rec, rec)
─────────────────────
Γ ⊢ πᵢ(e) : Tᵢ[rec ↦ (T₁, rec, rec)]
```

### 5.4 Occurs Check

When comparing recursive types, the type checker:
1. Maintains a mapping: `rec` → enclosing tuple type.
2. On encountering `rec`, substitutes and continues.
3. On cycle (rec encountered again during expansion), treats as equal when structures match.
4. Ensures decidability.

### 5.5 Well-Foundedness

Recursive structures are finite: the base case `:none` ensures termination. All recursive positions are either `:none` or a ref to a region-allocated node; no infinite unfoldings at runtime.

---

## 6. Region Lifetime Analysis (Extension)

The typing judgment is extended with a lifetime environment L and scope dependency set ScopDep for region-based memory:

**Lifetime Environment:**
```
L ::= ∅ | L, Lᵢ:scope
```

**Scope Dependency Set:**
```
ScopDep ::= ∅ | ScopDep, ref(Lᵢ, Space, T):scope
```

**Extended Typing Judgment:**
```
Γ; L; ScopDep ⊢ e : T; L'; ScopDep'
```

**Key Rules:**
- **Region Allocation**: At `alloc_region`, add Lᵢ to L with current scope.
- **Reference Allocation**: At `alloc_ref`, verify Lᵢ ∈ L, add ref(Lᵢ, Space, T) to ScopDep.
- **Reference Usage**: At `read_ref`/`write_ref`, verify Lᵢ ∈ L, ref ∈ ScopDep, scope constraints hold.
- **Scope Exit**: Remove regions/refs from current scope; verify ∀ ref(Lᵢ, ...) ∈ ScopDep'. Lᵢ ∈ L'.

See silica-specification.md §12.1.4 for the full algorithm and rules.

---

## 7. Reference

- [recursive_tuple_specification.md](recursive_tuple_specification.md) — Full design, syntax, and examples.
- [silica-specification.md](silica-specification.md) §12 — Memory Model, lifetime analysis.
