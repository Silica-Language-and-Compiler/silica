# List Map / Filter / Reduce and Hardening TODO

This TODO tracks the remaining list implementation work for `silica-compiler` after the completed representation, literal, and list-pattern work described in [list_implementation_design.md](../list_implementation_design.md).

It applies only to `silica-compiler` and `compiler/trials/list_addition/`. It does not schedule work on `silica-bootstrap-compiler` or `AArch64/Apple_Silicon/experiments/`.

## Implementation status (2026-10-16)

- TODO 1 (`map`, `filter`, `reduce`): not done. No such list builtins exist in the type checker's builtin signature table, and no trial under `trials/list_addition/` exercises them. List iteration is by `case` on `.is_nil` / `.head` / `.tail`, by `list_at[T, S](xs, i)`, and by the fold-style functions in `stdlib/data_structures`.
- TODO 2 (non-primitive elements): partly done. Record and tuple elements are exercised by `list_of_record_sum_elements`, `list_of_tuple_literals`, `list_of_tuple_literals_length`, `list_at_record_elem` and `list_record_actor_ref_nested_case_repro`, and elements are stored boxed (one pointer per cell) since the uniform boxed record layout. Negative trials for unsupported element shapes were not found; the list-space mismatch diagnostic is `E3011`.
- TODO 3 (spec alignment audit): not done as a closing audit; the implementation differences are recorded in the implementation status of [list_implementation_design.md](../list_implementation_design.md). The "temporary SIR list nodes" no longer exist (lists lower to `list_*` prims).

Paths in this file: `silica-compiler` means the compiler tree (`compiler/`), trials are under `trials/list_addition/`.

## Current Implemented Baseline

The source already contains the core list surface and lowering for:

- `empty`
- `prepend`
- `head`
- `remove_head`
- `length`
- list literals
- list case patterns with `[]`, cons, and `_`
- multi-chunk scalar list trials
- at least one inline-record list trial

This file therefore tracks only the remaining work.

## TODO 1 — Materialized `map`, `filter`, and `reduce`

**Goal:** implement materialized `map`, `filter`, and `reduce` over `List[T, S]` for at least one scalar element type, with correct memory-space behavior and no user-facing view types.

**Tasks**

1. Add compiler-known primitives or lowered loops for `map`, `filter`, and `reduce`.
2. Allocate new result lists or values according to `list_implementation_design.md` §2 and §7.
3. Ensure `sequence proc[mem(S)]` checking aligns the operation with the list memory space.
4. Document that chained `map` / `filter` may allocate intermediate lists unless a later optimizer fuses them.

**Trials**

Add `trials/list_addition/` cases for small finite inputs:

- `map` over a scalar list
- `filter` over a scalar list
- `reduce` over a scalar list
- empty `map`
- empty `filter`
- empty `reduce` behavior, either accepted with a specified identity/initial value or rejected with a golden diagnostic if the surface requires one

**Exit:** trials pass and behavior matches immutable functional semantics.

## TODO 2 — Collectable and Non-Primitive Element Hardening

**Goal:** finish and verify non-primitive element behavior for lists, including Collectable checks and region authority constraints.

**Current status:** the compiler has meaningful support for inline records and tuples in list chunks, and `trials/list_addition/list_record_actor_ref_nested_case_repro.silica` covers a record element shape. This TODO remains open until the behavior is intentionally covered rather than only incidentally supported.

**Tasks**

1. Add explicit trials for tuple elements and record elements.
2. Add negative trials for non-Collectable or unsupported element shapes if any remain possible.
3. Verify that list chunks never expose invalid pointers without the owning list/region authority.
4. Confirm that list operations preserve the `List[T, S]` memory-space contract for non-scalar elements.

**Exit:** positive and negative trials demonstrate the intended Collectable and region-authority behavior.

## TODO 3 — Final Spec Alignment and Regression Cleanup

**Goal:** close remaining divergence between the implementation, [list_implementation_design.md](../list_implementation_design.md), and [silica-specification.md](../silica-specification.md).

**Tasks**

1. Audit the implementation against `list_implementation_design.md` §9, especially primary cursor behavior in `case` and the scope of secondary cursors.
2. Update diagnostics for list edge cases so errors point to the list-specific rule being violated.
3. Remove or document any temporary SIR list nodes introduced during staging.
4. Keep the open SIMD chunk-width work in [list_chunk_vector_alignment_todo.md](../list_chunk_vector_alignment_todo.md) separate unless it becomes required for correctness.

**Exit:** no undocumented divergence remains for the completed list feature set.

## Milestone Summary

| Milestone | Deliverable |
|-----------|-------------|
| M1 | `map` / `filter` / `reduce` implementation and trials |
| M2 | explicit non-primitive and Collectable trials |
| M3 | final spec-alignment audit and diagnostic cleanup |

## Document History

| Version | Summary |
|---------|---------|
| 2.0 | Moved into `Phase1_TODOs`; removed completed representation, literal, and pattern phases; retitled around the remaining list work. |
