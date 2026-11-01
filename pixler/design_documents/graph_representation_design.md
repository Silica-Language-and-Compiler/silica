# Graph Representation Design (silica-compiler)

## 1. Purpose and scope

This document specifies graph representations for Silica code generation without custom type declarations. **Algorithm authority:** [Phase1_TODOs/data_structure_to_algorithms.md](Phase1_TODOs/data_structure_to_algorithms.md) (locked 2026-06).

Primary families:

1. **`WeightBalancedGraph`** — live functional graph: **WBT** vertex map + **WBT** neighbor set (unweighted) or **WBT** neighbor map `to → payload` (weighted/attributed).
2. **`CompressedSparseRowGraph`** — **snapshot only**: O(V + E) freeze from live WBT graph [KL95].
3. **`DenseMatrixGraph`** — specialized small dense graphs using **Okasaki skew binary random-access lists** [Oka95, Oka98 §5].

**Removed from scope:** `NodeIdAdjacencyGraph` (list-scan adjacency), **`DenseBitsetGraph`**.

Phase 1: trait-oriented constructors and graph traits ([Phase1_TODOs/data_structures_as_traits.md](Phase1_TODOs/data_structures_as_traits.md)). **Emitted module filenames:** representation + directedness only — e.g. `graph_wbt_directed.silica`, `graph_csr_directed.silica`, `graph_dense_directed.silica`.

**Implementation status (2026-10-16):** implemented in `compiler/stdlib/data_structures/`: live `graph_wbt_core` with `graph_wbt_directed`, `graph_wbt_undirected`, `graph_weighted`, `graph_weighted_undirected`; `graph_csr_core` with `graph_csr_directed`, `graph_csr_undirected`, `graph_csr_weighted`, `graph_csr_weighted_undirected`; `graph_dense_core` with the four `graph_dense_*` modules; and the traits `DirectedGraph`, `UndirectedGraph`, `WeightedGraph`. Trials: `trials/ordered_data_structures/` (`graph_live_core`, `graph_csr_core`, `graph_dense_core`, `graph_collections`). The family names `WeightBalancedGraph`, `CompressedSparseRowGraph` and `DenseMatrixGraph` and the registry keys below are descriptive; the registered construction modules are the `graph_*` names. Dense cells are optional references over the skew RAL (`graph_dense_core.silica` header, deviation 1). Per-module deviations are numbered in the module headers.

**Typing:** Phase 1 public vertex IDs, CSR/dense slots, counts, offsets, and cell indexes are **`int64`**. Public IDs and dense slots are distinct semantic domains even though their machine type is the same. Edge payload/data types remain generic.

**Layout stability:** generated WBT, CSR, and dense records are distinct concrete types. CSR/dense inline layouts are private to one compiler/standard-library version, not stable source, FFI, serialization, or cross-version ABIs.

---

## 2. Shared model

### 2.1 Node identity

Nodes are `int64` values compared by `compare_node: fn(int64, int64) -> atom`. Dense-slot invariant: `0 <= dense_slot < node_count`. Public IDs are translated through `node_to_slot` and are not assumed to equal slots.

### 2.2 Directedness

| Suffix | Meaning |
|--------|---------|
| `Directed` | Store `u → v` once |
| `Undirected` | Store both directions when `u ≠ v` |

Example modules: `graph_wbt_directed`, `graph_wbt_undirected`, `graph_csr_directed`, `graph_dense_directed`.

### 2.3 Edge and node payload

| Variant | Inner neighbor structure |
|---------|-------------------------|
| Unweighted | **WBT set** of `int64` |
| Weighted / attributed | **WBT map** `int64 → EdgePayloadType` (one edge per `(from, to)`) |

Optional **`NodeDataType`** on vertices: store in node metadata or parallel structure per generator; updates return new graph values.

### 2.4 Constructor function records

Directed graph:

```text
{
    compare_node: fn(int64, int64) -> atom,
    compare_edge: fn(EdgePayloadType, EdgePayloadType) -> atom,
    edge_target: fn(EdgePayloadType) -> int64
}
```

Weighted graphs may add `compare_weight` when weight is separate from edge payload.

### 2.5 Immutability

- **Live WBT graph:** `add_edge`, `remove_edge`, `set_node_data`, … return **new** graph records (path copying).
- **CSR snapshot:** immutable after **freeze**; no incremental edge updates on CSR values.
- **Dense matrix:** path copying on random-access list cells.
- Construction buffers: only inside `sequence proc[mem(S)] … produces pure … end`.
- Mutable builders: modules named with **`_builder_`** or **`_mutable_`** only.

### 2.6 Uniform inline types

The same inline graph record type must appear at every boundary for one value flow (silica-spec §4.2.4 / §8.2.4).

### 2.7 Registry bracket forms

List-aligned registry keys document generator metadata, e.g. `WeightBalancedGraphDirected[EdgePayloadType, mem(S)]`, `CompressedSparseRowGraphDirected[mem(S)]`.

---

## 3. Weight-balanced graph (live representation)

**References:** [Ada93], [KL95], [Erw97].

### 3.1 Logical model

```text
adj : WBT<int64, WBT<int64, Unit>>                 -- unweighted (inner set as WBT)
adj : WBT<int64, WBT<int64, EdgePayload>>          -- weighted / attributed
```

Outer map: vertices keyed by `compare_node`. Inner structure: neighbor **set** or **map** keyed by `compare_node` on target ids.

### 3.2 Inline shape (unweighted directed — schematic)

```silica
{
    compare_node: fn(int64, int64) -> atom,
    compare_edge: fn(EdgePayloadType, EdgePayloadType) -> atom,
    edge_target: fn(EdgePayloadType) -> int64,
    vertex_count: int64,
    edge_count: int64,
    adj: /* WBT outer + inner shapes per wbt_map / wbt_set design */
}
```

Weighted graphs replace inner set with inner **WBT map** holding `to → payload`.

### 3.3 Operations

| Operation | Algorithm | Complexity |
| --------- | --------- | ---------- |
| **Add edge (unweighted)** | Outer WBT update; inner WBT set insert at `from` | O(log V + log degree) |
| **Add edge (weighted)** | Outer WBT update; inner WBT map insert/replace `(to, payload)` | O(log V + log degree) |
| **Remove edge** | Inner WBT delete; drop outer entry if inner empty | O(log V + log degree) |
| **Add vertex** | Insert `id ↦ empty` inner WBT | O(log V) |
| **Has edge** | Inner WBT lookup | O(log degree) |
| **Neighbors** | Return inner WBT at `from` | O(log degree) access |
| **From edge list** | Fold add edge | O(E · (log V + log degree)) |

Undirected: symmetric updates on both endpoints.

### 3.4 Validation

Check node id ranges, edge counts, inner WBT order, undirected symmetry, one-payload-per-pair on weighted maps.

### 3.5 When to use

Default graph for incremental construction, functional passes, and moderate sizes. Prefer **CSR freeze** when the graph is built and then traversed many times.

---

## 4. Compressed sparse row graph (snapshot)

**References:** [KL95], [Erw97].

### 4.1 Role

CSR is a **read-optimized snapshot**, not the live mutable graph. Build from a **WBT live graph** via **freeze**.

### 4.2 Freeze algorithm

Two-pass standard CSR build:

1. Count out-degrees from WBT adjacency (in-order fold per vertex).
2. Prefix-sum into `offsets`.
3. Scatter `neighbors` (and `edge_data` / weights if weighted) into fresh buffers.

Complexity: **O(V + E)**. Prior WBT graph unchanged.

### 4.3 Inline shape (unweighted)

```silica
{
    r: region(R, S),
    node_count: int64,
    edge_count: int64,
    node_ids: buf(R, S, int64, N),
    offsets: buf(R, S, int64, N_PLUS_ONE),
    neighbors: buf(R, S, int64, M)
}
```

Attributed/weighted variants add a parallel `edge_data` buffer of extent `M`; unweighted variants omit it. `N`, `N_PLUS_ONE`, and `M` are runtime-sized internal extents, not public type parameters.

### 4.4 After freeze

Public query APIs (`neighbors`, `has_edge`, …) are read-only. Topology mutation requires editing the **live WBT graph** and re-freezing.

### 4.5 Dynamic buffer growth

Parametric CSR builders that outgrow capacities use region grow/copy during **freeze construction** inside `sequence proc` (see silica-spec buffer rules).

---

## 5. Dense matrix graph (specialized)

**References:** [Oka95], [Oka98 §5].

### 5.1 Role

Small **V** or very high density where O(V) row scan is acceptable. **Not** the default graph family.

### 5.2 Storage

Logical `V × V` cells in one **skew binary random-access list**. Unweighted cells are boolean. Attributed/weighted cells are `:none | (:some, EdgeDataType)`. Index: `from * V + to`.

### 5.3 Operations

| Operation | Algorithm | Complexity |
| --------- | --------- | ---------- |
| Set / clear edge | Random-access list update at index | O(log V) |
| Has edge | Random-access list lookup | O(log V) |
| Neighbors | Scan row | O(V) |

Path copying on each update; no in-place mutation of shared cells.

---

## 6. Choosing a representation

| Representation | Best for | Avoid when |
|----------------|----------|------------|
| WBT live graph | Incremental build, functional updates, moderate V | Need packed cache-friendly traversal without freeze |
| CSR snapshot | Repeated traversal, compiler IR-style queries | Frequent topology changes after freeze |
| Dense matrix | Tiny V, dense graphs | Large sparse graphs |

**Not available:** dense bitset graph.

---

## 7. Generator requirements

### 7.1 WBT graph

Inputs: directedness, weightedness, `EdgePayloadType`, memory space, constructor record fields. Vertex IDs are fixed to `int64`.

Minimum exports: `empty`, `add_edge`, `remove_edge`, `has_edge`, `neighbors`, `validate`, `vertex_count`, `edge_count`, `freeze` (or separate CSR module callable from WBT graph).

### 7.2 CSR snapshot

Inputs: frozen buffer capacities or runtime sizes (Phase 0 dynamic `N`).

Minimum exports: `validate`, `neighbors`, `has_edge`, `node_count`, `edge_count`.

### 7.3 Dense matrix

Inputs: `node_count`, memory space.

Minimum exports: `empty`, `set_edge`, `clear_edge`, `has_edge`, `validate`.

---

## 8. References

- [Phase1_TODOs/data_structure_to_algorithms.md](Phase1_TODOs/data_structure_to_algorithms.md)
- [Ada93] Adams (1993). *JFP* 3(4).
- [Oka95] Okasaki (1995). Purely Functional Random-Access Lists. *FPCA*.
- [Oka98] Okasaki (1998). *Purely Functional Data Structures*.
- [KL95] King & Launchbury (1995). *JFP* 5(1).
- [Erw97] Erwig (1997). Functional Graphs. Chalmers TR 97-9.
