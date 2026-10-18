# Compressed Sparse Row Graph Snapshot Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/graph_csr_core.silica` with `graph_csr_directed`, `graph_csr_undirected`, `graph_csr_weighted`, `graph_csr_weighted_undirected`; trials in `trials/ordered_data_structures/graph_csr_core/` (9 programs) and `graph_collections/`. The freeze overflow-failure path has no trial.

**Module family:** `graph_csr_directed`, `graph_csr_undirected`, weighted variants
**Source:** frozen live WBT graph
**Mutability:** immutable topology snapshot

## 1. Semantic role

CSR is a read-optimized snapshot of one live graph version. Freezing does not consume or modify the live graph. Subsequent live updates do not appear in the snapshot.

CSR modules expose query and traversal operations only. There is no `add_edge`, `remove_edge`, `add_vertex`, or in-place capacity growth on a completed snapshot.

## 2. Deterministic dense slot assignment

Public vertex IDs use `NodeIdType`; internal dense slots use `int64`. They are distinct domains, and a public ID is never used directly as a buffer index. Live vertex IDs are visited in ascending `compare_node` order and assigned:

```text
slot 0 .. V-1
```

The snapshot stores both:

- `node_ids[slot] -> NodeIdType` public vertex ID;
- a WBT map `node_to_slot` built linearly from the already sorted ids.

This allows any valid Silica `NodeIdType` without requiring that public IDs equal dense slots.

## 3. Physical shape

The exact field order, padding, and compiler spelling are private to one compiler/standard-library version. Conceptually, the generated record contains:

```text
{
    r: region(R, SpaceType),
    node_count: int64,
    edge_count: int64,
    adjacency_entry_count: int64,
    node_ids: buf(R, SpaceType, NodeIdType, V),
    offsets: buf(R, SpaceType, int64, V_PLUS_ONE),
    neighbors: buf(R, SpaceType, NodeIdType, A),
    edge_data: OptionalBuffer[EdgeDataType, A],
    node_to_slot: WbtMap[NodeIdType, int64],
    compare_node: fn(NodeIdType, NodeIdType) -> (:less | :equal | :greater),
    compare_edge_data: fn(EdgeDataType, EdgeDataType) -> (:less | :equal | :greater),
    ordering_identity: OpaqueToken,
    directedness: :directed | :undirected
}
```

Unweighted snapshots omit `edge_data`. Weighted/attributed snapshots use a parallel direction-independent edge-data buffer of length `A`; neighbor views are generated as `{to: neighbors[p], data: edge_data[p]}`.

`V`, `V_PLUS_ONE`, and `A` are runtime-sized internal extent identifiers bound to checked `int64` values during freeze. They are not public graph type parameters and do not create a distinct public graph type for each graph size. The extent equations are normative even when the compiler changes the private inline-record spelling.

## 4. Freeze definition

A CSR snapshot has no constructor record of its own. `graph_csr_directed@freeze_from_wbt/1` (and the undirected, weighted and weighted-undirected twins) takes a live WBT graph and carries that graph's `functions` record (`{ compare_node, compare_edge, edge_target }` directed, `{ compare_node, compare_edge_data }` undirected, plus `edge_weight` and `compare_weight` weighted). Internally the snapshot stores them as `compare_key` and `compare_value`.

Freeze is a deterministic sequence:

1. validate or trust a previously validated live graph under the same invariants;
2. traverse outer WBT in ascending node order, assigning slots and writing `node_ids`;
3. compute each stored adjacency size and checked prefix sum into `offsets`;
4. traverse each inner WBT in ascending target order and write contiguous `neighbors`;
5. write edge data at the identical edge position when present;
6. build `node_to_slot` with WBT `from_sorted`;
7. publish the snapshot only after all counts and final offsets agree.

No comparison sort occurs. Because WBT traversals are already ordered, the total freeze work is `O(V + A)`.

## 5. Offset invariant

```text
offsets[0] = 0
offsets[V] = A
0 <= offsets[i] <= offsets[i+1] <= A
row(i) = [offsets[i], offsets[i+1])
```

Within every row, neighbor ids are strictly ascending under `compare_node`. Weighted/attributed edge data at position `p` belongs to the endpoint pair represented by `neighbors[p]`.

## 6. Query behavior

`has_vertex(id)` searches `node_to_slot` in `O(log V)`.

`neighbors(id)`:

- looks up slot;
- on absence returns the canonical empty list; callers use `has_vertex` when they must distinguish a missing vertex from an isolated vertex;
- materializes the row in stored order.

`has_edge(from, to)` binary-searches the sorted row after locating `from`, for `O(log V + log d(from))`.

`fold_neighbors` streams the contiguous row without allocation. Whole-graph traversals scan buffers in `O(V + A)`.

## 7. Directedness and counts

CSR preserves the live graph's logical edge count and adjacency-entry count exactly.

An undirected non-loop appears in two rows; a self-loop appears once. CSR validation applies the same symmetry and count equations as the live representation.

## 8. Snapshot compatibility

A CSR value implements the query portions of `DirectedGraph`, `UndirectedGraph`, and where applicable `WeightedGraph`. Mutation is not placed in those behavior traits, so read-only trait conformance requires no runtime “immutable” error.

Construction/update modules remain representation-specific. Code requesting `graph_wbt_*@add_edge` cannot accept a CSR value by accident because the concrete generated type differs.

The concrete types are the generated `graph_csr_directed` and `graph_csr_undirected` families, with additional attributed/weighted specializations. They are distinct from the corresponding WBT and dense concrete types; there is no runtime representation tag or erased graph payload.

Their structural layout is valid only within one compiler/standard-library version. Only generated module operations and public graph traits are stable source-level access paths.

## 9. Failure behavior

Freeze fails without publishing a snapshot on:

- count or prefix-sum overflow;
- invalid comparator atom;
- malformed live graph;
- buffer allocation failure;
- edge-data alignment mismatch;
- ordering-identity mismatch in nested WBTs.

The live input remains valid in every failure case.

## 10. Validation

Validation checks:

- buffer extents against `V` and `A`;
- offset monotonicity and endpoints;
- row sort order and target membership;
- edge-data alignment;
- exact logical counts;
- node-to-slot bijection;
- undirected symmetry where required.

Undirected symmetry can be checked in `O(A log d)` by row binary search. An `O(V + A)` merge-based validator is preferred but is not part of public graph operation bounds.

## 11. Complexity

| Operation | Time | Allocation |
|---|---:|---:|
| freeze | `O(V + A)` | `O(V + A)` |
| node lookup | `O(log V)` | none |
| has edge | `O(log V + log d)` | none |
| neighbors list | `O(log V + d)` | `O(d)` |
| neighbor fold | `O(log V + d)` | none |
| full traversal | `O(V + A)` | none |
| validate | `O(V + A)` directed; symmetry check as above | diagnostics |
