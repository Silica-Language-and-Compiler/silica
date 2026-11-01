# Layer 0 §6.4 — Closed CSR/Dense Representation Contract

**Recorded:** 2026-06-29  
**Status:** Closed — implementation input; not reopen without explicit design revision  
**Authority:** [`standard_data_structures_implementation_plan.md`](../standard_data_structures_implementation_plan.md) §6.4 and §4 dependency graph  
**Design sources:** [`csr_graph_snapshot.md`](../data_structure_designs/csr_graph_snapshot.md), [`dense_matrix_graph.md`](../data_structure_designs/dense_matrix_graph.md), [`common_contract.md`](../data_structure_designs/common_contract.md) §1  
**Ledger rows:** [`requirements_to_trials_ledger.md`](requirements_to_trials_ledger.md) §6.4 (`CSR-D1` … `CSR-D7`)

## Purpose

This document closes the Phase 1 representation contract for **CSR snapshot graphs** and **dense matrix graphs**. It is normative for generated module layout, public typing, and acceptance trials. It does not add a scheduling barrier beyond Layer 6 in the implementation plan.

WBT live graphs are governed separately by [`live_wbt_graph.md`](../data_structure_designs/live_wbt_graph.md). CSR and dense values implement the same **public graph traits** for query operations but are **distinct concrete generated types** from live WBT values.

---

## Contract clauses

### CSR-D1 — Compiler-version-private inline layouts

**Requirement.** Generated CSR and dense graph values use inline records whose **field order, padding, and exact compiler spelling are private to one compiler/standard-library version**.

**Allowed.**

- Generated modules (`graph_csr_*`, `graph_dense_*`) and the compiler for one build inspect these layouts.
- Public behavior is exposed only through trait methods and generated module operations declared in the trait designs.

**Forbidden.**

- User source reading or pattern-matching on generated inline record fields.
- Stable FFI, serialization, or cross-version ABI reliance on layout fields.
- A runtime representation tag or erased graph payload that lets callers bypass static module typing.

**Design authority:** CSR §3, §8; dense §4; `common_contract.md` §2.

**Coverage:** Ledger `I` until `cross_representation/graph_layout_not_in_source` compile-fail trial exists.

---

### CSR-D2 — Public `NodeIdType` ≠ internal dense-slot domain

**Requirement.** Public vertex identity is `NodeIdType` (any valid Silica type witnessed by the graph's node comparator). Internal dense slots, CSR buffer indexes, and dense cell indexes are **`int64` in a separate semantic domain**.

**Rules.**

1. Every public endpoint operation accepts `NodeIdType`.
2. Every buffer or cell index is reached only through an explicit **`node_to_slot`** map (CSR: WBT map built by `from_sorted`; dense: WBT map at construction).
3. A public ID must **never** be used directly as a slot index, even when `NodeIdType` is `int64`.
4. CSR stores `node_ids[slot] -> NodeIdType` in ascending slot order; dense stores `slot_to_node` in slot order.

**Design authority:** `common_contract.md` §1; CSR §2; dense §2–§3.

**Coverage:** `graph_csr_core/gcsr_directed_freeze`, `gcsr_generic_payloads`; `graph_dense_core/gd_universe`, `gd_generic_payloads` (landed 2026-09-18; the planned `snapshot_graphs/` stems were not used).

---

### CSR-D3 — Runtime-sized internal extents are not public type parameters

**Requirement.** Buffer capacities and cell counts are **checked runtime `int64` values** fixed at freeze (CSR) or construction (dense). They are **not** bracket parameters on public graph types.

**CSR extents (normative).**

| Symbol | Meaning |
|---|---|
| `V` | vertex count |
| `V_PLUS_ONE` | `V + 1` (offset array length) |
| `A` | adjacency-entry count (directed row entries; undirected symmetry rules apply) |

**Dense extents (normative).**

| Symbol | Meaning |
|---|---|
| `V` | fixed vertex count |
| `V * V` | cell sequence length (`cell_count`) |

**Rules.**

1. Two graphs with the same public type specialization but different `V` or `A` remain the **same public graph type**; size lives only in the value.
2. Overflow on `V + 1`, prefix sums, or `V * V` **fails before publication** of a CSR snapshot or dense graph value.
3. Extent equations in the designs remain normative even if private inline-record spelling changes.

**Design authority:** CSR §3; dense §3–§4; `common_contract.md` §9.

**Coverage:** `graph_csr_core/gcsr_directed_freeze`; `graph_dense_core/gd_universe` (landed 2026-09-18). A V-squared overflow trial was not landed.

---

### CSR-D4 — CSR parallel neighbor and edge-data buffers (attributed/weighted)

**Requirement.** Attributed and weighted CSR snapshots store:

1. **`neighbors`**: `buf(R, Space, NodeIdType, A)` — target IDs in row-major order per §CSR-D5 offset invariant.
2. **`edge_data`**: parallel buffer of length **`A`** holding direction-independent `EdgeDataType`.

**Rules.**

1. Unweighted CSR specializations **omit** `edge_data` entirely.
2. Position `p` in `neighbors` and `edge_data` denotes the **same logical adjacency entry**.
3. Public neighbor views for attributed/weighted forms are **generated** as `{to: neighbors[p], data: edge_data[p]}`; programmers do not supply reverse-edge or retarget functions.
4. Freeze writes edge data at the identical edge position when scattering neighbors (CSR §4 step 5).

**Design authority:** CSR §3–§5; algorithm map locked decision #7.

**Coverage:** `graph_csr_core/gcsr_weighted` (landed 2026-09-18).

---

### CSR-D5 — Dense unweighted: one boolean cell sequence

**Requirement.** Unweighted dense graphs use **exactly one** skew-binary random-access-list sequence:

```text
cells: SkewRAL[boolean]   length V*V
```

**Rules.**

1. Cell `(from_slot, to_slot)` is at index `from_slot * V + to_slot`.
2. `true` = edge present; `false` = absent.
3. No separate bitset, no second presence array, no redundant parallel boolean buffer.

**Design authority:** dense §1, §4, §6; algorithm map locked decision #9 (RAL cells, not bitset).

**Coverage:** `graph_dense_core/gd_directed_updates` (landed 2026-09-18). Implementation status (2026-10-16): the cells are optional references (`ref?`), not booleans; see `graph_dense_core.silica` header, deviation 1.

---

### CSR-D6 — Dense attributed/weighted: one tagged optional-data cell sequence

**Requirement.** Attributed and weighted dense graphs use **exactly one** tagged cell sequence:

```text
cells: SkewRAL[:none | (:some, EdgeDataType)]   length V*V
```

**Rules.**

1. `:none` = edge absent.
2. `(:some, data)` = edge present with complete direction-independent `EdgeDataType`.
3. **No** redundant presence sequence alongside the tagged cells (dense §4).
4. Set/replace updates one cell; counts change only on absent→present transitions per dense §6.

**Design authority:** dense §4, §6.

**Coverage:** `graph_dense_core/gd_weighted` (landed 2026-09-18). Implementation status (2026-10-16): the cells are optional references (`ref?`) because the parser rejected `:none | (:some, EdgeDataType)` when the module was written (E1040, per the module header); the contract text is kept as the design and whether the form now parses was not re-verified.

---

### CSR-D7 — Distinct WBT, CSR, and dense concrete generated types

**Requirement.** Live WBT, CSR snapshot, and dense matrix graphs are **non-interchangeable concrete generated types**, including attributed/weighted specializations.

**Normative module families.**

| Representation | Directed | Undirected | Weighted variants |
|---|---|---|---|
| Live WBT | `graph_wbt_directed` | `graph_wbt_undirected` | inner map + `WeightedGraph` trait |
| CSR snapshot | `graph_csr_directed` | `graph_csr_undirected` | parallel `edge_data` buffer |
| Dense matrix | `graph_dense_directed` | `graph_dense_undirected` | tagged `:none \| (:some, …)` cells |

**Rules.**

1. Static typing prevents passing a CSR value to `graph_wbt_*@add_edge` or any live mutator.
2. CSR query traits do not expose mutation; immutability requires **no runtime “immutable” error** on read-only trait calls (CSR §8).
3. Cross-representation agreement is tested **only through public graph traits** (`cross_representation/` trials), never by comparing private fields.
4. Re-freeze from an updated live graph produces a **new** CSR value; CSR never updates in place.

**Design authority:** implementation plan §4; CSR §8; dense §1; `live_wbt_graph.md` §1.

**Coverage:** `graph_csr_core/gcsr_equivalence_large`, `gcsr_snapshot_isolation`; `graph_dense_core/gd_equivalence`; `graph_collections/gc_csr_*_trait`, `gc_dense_*_trait` (landed 2026-09-18; the `cross_representation/` stems were not used).

---

## Explicitly rejected alternatives

These are **out of scope** for Phase 1 and must not appear as parallel implementations:

| Rejected | Rationale |
|---|---|
| Dense bitset graph | Algorithm map locked decision #10 |
| Public graph types parameterized by `V`, `A`, or `V*V` | CSR-D3 |
| User-visible CSR/dense inline record fields | CSR-D1 |
| Direct use of public vertex IDs as buffer indexes | CSR-D2 |
| CSR incremental edge update after freeze | CSR §1 |
| Dense auto-add vertex on `add_edge` | dense §2, §6 |
| Second presence array for dense weighted cells | CSR-D6 |
| Single erased graph handle shared by WBT/CSR/dense | CSR-D7 |

---

## Trial mapping summary

| Clause | Primary leaf | Planned trial stem |
|---|---|---|
| CSR-D1 | `error_enforcement/` + `cross_representation/` | `graph_layout_not_in_source` |
| CSR-D2 | `snapshot_graphs/` | `csr_node_id_not_slot`, `dense_node_id_not_slot` |
| CSR-D3 | `snapshot_graphs/` | `csr_runtime_extents`, `dense_v_squared_overflow` |
| CSR-D4 | `snapshot_graphs/` | `csr_weighted_parallel_buffers` |
| CSR-D5 | `snapshot_graphs/` | `dense_unweighted_boolean_cells` |
| CSR-D6 | `snapshot_graphs/` | `dense_weighted_tagged_cells` |
| CSR-D7 | `cross_representation/` | `graph_distinct_concrete_types`, `wbt_csr_dense_trait_agree` |

---

## §6.4 acceptance checklist

- [x] All seven implementation-plan §6.4 bullets expanded as normative clauses (`CSR-D1` … `CSR-D7`)
- [x] Design cross-references recorded for each clause
- [x] Rejected alternatives listed
- [x] Ledger rows in [`requirements_to_trials_ledger.md`](requirements_to_trials_ledger.md) §6.4 linked by clause ID
- [x] Trial leaf assignment for every clause

**Dependency note.** CSR-D3 requires Layer 1 runtime-sized buffer hardening (§7.8). CSR-D4–D7 require Layer 4 live graphs and Layer 2 skew RAL core before Layer 6 implementation.
