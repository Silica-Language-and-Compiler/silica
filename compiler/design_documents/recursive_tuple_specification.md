# Recursive Tuple Specification

**Status:** Implemented (see Implementation status (2026-10-16) below); design approved via the Recursive Tuple Design Discussion tool (Trade-off Analysis complete)

**Related:** [tuple_recursion_discussion.jsonld](../compiler-building-tools/tuple_recursion_discussion.jsonld)

## Implementation status (2026-10-16)

Implemented end to end: `rec` is a lexer keyword (`lexer_keywords.silica`); `ref?(R, Space, T)` and `rec` are type syntax; the type checker implements structural equality with the `rec`-scoped occurs check and `ref?` slots (`type_checker/type_checker_recursive_tuples.silica`, exports `recursive_types_equal`, `is_ref_optional_type`, `atom_fits_ref_optional_slot`, `ref_fits_ref_optional_slot`); `alloc_rec` is lowered in `sir_generator/terms/memory_region_calls.silica` and emitted by `terms/prims/prims_memory.silica` in the Apple Silicon and ESP32-S3 backends. The language specification carries the normative text (`silica-specification.md`, recursive tuples section). Trials: `trials/memory_region_addition` and the `ordered_data_structures` suites (the standard collections `wbt_core`, `binary_tree_core`, `skew_ral_core` are built on recursive tuples). The companion `../compiler-building-tools/tuple_recursion_discussion.jsonld` exists. Not verified: the Layer 1 formal-verification rules in section 4 are a proof-side statement with no compiler counterpart. Section 8 (region uniqueness across the application lifetime) is still an open item; no mechanism was found in the compiler or specification.

---

## 1. Design Summary

| Dimension | Decision |
|-----------|----------|
| Self-reference | `rec` (inline only, in tuple types) |
| Base case | `:none` atom |
| Custom types | None — all inline |
| Memory model | Recursive slots = `ref(R, Space, rec) \| :none` |
| Allocation | Explicit |
| Region uniqueness | **Postponed** — R must be unique for application lifetime; mechanism TBD |
| SIR / primitives | New primitives (alloc_rec) |
| Construction | `alloc_rec(region, (value, ...))` |
| Declaration | `ref?(R, Space, T)` = `ref(R, Space, T) \| :none` |
| Decomposition | Explicit `read_ref` + `(pattern) <- expr` + `case` for `:none` vs ref |
| Type checking | Structural equality with `rec`-scoped occurs check |
| Formal verification | Extend Layer 1 (Value Calculus) with recursive products |

---

## 2. Syntax Extensions

### 2.1 Keywords

- **rec** — Self-reference in tuple types. Valid only inside a tuple type; refers to the enclosing tuple type.
- **:none** — Atom denoting empty recursive position (base case).

### 2.2 Type Syntax

```
tuple_type      ::= "(" type {"," type} ")"
type            ::= ... | "rec" | "ref?" "(" region_id "," space "," type ")"
```

**ref?(R, Space, T)** — Shorthand for `ref(R, Space, T) | :none` (optional region reference).

**rec** — In context of tuple `(T1, rec, rec)`, each `rec` refers to `(T1, rec, rec)`.

### 2.3 Construction

```
alloc_rec(r, (value, ...))
```

- Allocates a recursive tuple in the given region.
- Returns `ref(R, Space, tuple_type)`.
- Effect: `mem(Space)`.
- Recursive slots: `:none` stored as-is; refs stored as-is (no extra allocation).

### 2.4 Decomposition

1. Bind ref: `node_ref: ref(R, (int64, ref?(R, rec), ref?(R, rec))) <- expr`
2. Read: `node: (int64, ref?(R, rec), ref?(R, rec)) <- read_ref(node_ref)`
3. Decompose: `(key: int64, left: ref?(R, rec), right: ref?(R, rec)) <- node`
4. Pattern match: `case left of { :none -> ...; left_ref: ref(R, rec) -> ... }`

---

## 3. Type Checking

- **Structural equality** with `rec`-scoped occurs check.
- When comparing types, substitute `rec` with enclosing tuple type.
- On cycle (rec encountered again), treat as equal when structures match.
- Decidable; no explicit fold/unfold.

---

## 4. Formal Verification (Layer 1 Extension)

Recursive product formation and elimination:

```
Γ ⊢ e₁ : T₁    Γ ⊢ e₂ : T₂[rec ↦ (T₁, rec, rec)]    Γ ⊢ e₃ : T₃[rec ↦ (T₁, rec, rec)]
────────────────────────────────────────────────────────────────────────────────────
Γ ⊢ (e₁, e₂, e₃) : (T₁, rec, rec)

Γ ⊢ e : (T₁, rec, rec)
─────────────────────
Γ ⊢ πᵢ(e) : Tᵢ   [with rec substitution]
```

---

## 5. SIR Primitives

### alloc_rec

| PrimOp | SIRType | Args | Effect |
|--------|---------|------|--------|
| alloc_rec | ref(R, Space, T) | (region, tuple_value) | [mem(Space)] |

- T must be a recursive tuple type.
- tuple_value: (v1, v2, ...) where recursive slots are `:none` or refs.
- Returns ref to region-allocated tuple.

---

## 6. Examples

### BST Node

```silica
fn insert(
    r: region(R, normal),
    tree: ref(R, (int64, ref?(R, normal, (int64, rec, rec)), ref?(R, normal, (int64, rec, rec)))),
    key: int64
) -> ref(R, (int64, ref?(R, normal, (int64, rec, rec)), ref?(R, normal, (int64, rec, rec)))) proc[mem(normal)] {
    node: (int64, ref?(R, normal, (int64, rec, rec)), ref?(R, normal, (int64, rec, rec))) <- read_ref(tree);
    (k: int64, left: ref?(R, normal, (int64, rec, rec)), right: ref?(R, normal, (int64, rec, rec))) <- node;
    case key < k of {
        true -> case left of {
            :none -> alloc_rec(r, (k, alloc_rec(r, (key, :none, :none)), right));
            left_ref: ref(R, normal, (int64, rec, rec)) -> alloc_rec(r, (k, insert(r, left_ref, key), right))
        };
        false -> case key > k of {
            true -> case right of {
                :none -> alloc_rec(r, (k, left, alloc_rec(r, (key, :none, :none))));
                right_ref: ref(R, normal, (int64, rec, rec)) -> alloc_rec(r, (k, left, insert(r, right_ref, key)))
            };
            false -> tree
        }
    }
}
```

### Linked List

```silica
fn map(
    r: region(R, normal),
    f: fn(int64) -> int64,
    xs: ref(R, (int64, ref?(R, normal, (int64, rec))))
) -> ref(R, (int64, ref?(R, normal, (int64, rec)))) proc[mem(normal)] {
    (value: int64, next: ref?(R, normal, (int64, rec))) <- read_ref(xs);
    case next of {
        :none -> alloc_rec(r, (f(value), :none));
        next_ref: ref(R, normal, (int64, rec)) -> alloc_rec(r, (f(value), map(r, f, next_ref)))
    }
}
```

---

## 7. Compiler Pipeline Changes

| Phase | Changes |
|-------|---------|
| Lexer | Add `rec` keyword |
| Parser | `rec` in type grammar; `ref?(R, Space, T)`; `alloc_rec` as primitive |
| Type checker | Occurs check for `rec`; `ref?` = `ref \| :none`; recursive type equality |
| SIR | New primitive `alloc_rec` |
| Emitter | Codegen for `alloc_rec` |

---

## 8. Open Items

- **Region uniqueness:** R must be unique across application lifetime. Mechanism postponed.
