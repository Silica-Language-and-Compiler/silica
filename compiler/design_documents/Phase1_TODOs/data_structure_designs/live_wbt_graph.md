# Live WBT Graph Representation Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/graph_wbt_core.silica` (outer `wbt_map` of inner `wbt_map` target-to-value); trials in `trials/ordered_data_structures/graph_live_core/` (17 programs).

**Consumers:** directed, undirected, and weighted graph traits
**Role:** default persistent representation for incremental topology updates

## 1. Logical storage

Unweighted:

```text
vertices : WBTMap<NodeIdType, WBTSet<NodeIdType>>
```

Weighted or attributed:

```text
vertices : WBTMap<NodeIdType, WBTMap<NodeIdType, EdgeData>>
```

Both outer and inner WBTs use `compare_node` for key order. There is exactly one adjacency position for a `(from, to)` pair.

An unweighted public edge payload is the target node id itself. Thus the generated unweighted directed graph specializes:

```text
EdgePayloadType = NodeIdType
edge_target(x) = x
compare_edge = compare_node
```

Attributed/weighted graphs receive the target separately from direction-independent `EdgeDataType`. They store that data as the inner map value and generate `{to,data}` wrappers only for neighbor views.

## 2. Outer record

Conceptually:

```text
{
    r: region(R, SpaceType),
    vertices_root: OptionalOuterWbtRoot,
    node_count: int64,
    edge_count: int64,
    adjacency_entry_count: int64,
    compare_node: fn(NodeIdType, NodeIdType) -> (:less | :equal | :greater),
    compare_edge_data: fn(EdgeDataType, EdgeDataType) -> (:less | :equal | :greater),
    ordering_identity: OpaqueToken,
    directedness: :directed | :undirected,
    payload_kind: :unweighted | :attributed | :weighted
}
```

The public type fixes directedness and payload kind; the atoms above are explanatory metadata, not runtime switches required by every specialization.

## 3. Vertex semantics

Every vertex exists as an outer-map key, including isolated vertices and target-only vertices.

`add_vertex(id)` inserts `id -> empty adjacency`.

`add_edge(from, to, data)` first ensures both `from` and `to` exist. The unweighted convenience form omits `data`. Edge insertion may increase node count by zero, one, or two.

Removing an edge never removes either endpoint. Vertex deletion, if exposed, is a distinct operation that removes all incident logical edges and must update counts exactly.

## 4. Directed insertion

Unweighted:

1. ensure both endpoints;
2. insert `to` into `from`'s neighbor set;
3. if duplicate, return the semantically unchanged graph;
4. otherwise increment logical edge and adjacency-entry counts once.

Weighted/attributed:

1. ensure endpoints;
2. insert `to -> data` in `from`'s neighbor map;
3. absent target: increment both edge counts;
4. present target: replace edge data, leave counts unchanged, retain the canonical stored target key.

All WBT updates path-copy both the inner search path and outer path to `from`.

## 5. Undirected insertion

For `u != v`, update both `u -> v` and `v -> u` from the same old graph and publish one new graph only after both succeed.

- a new logical edge increments `edge_count` once and `adjacency_entry_count` twice;
- duplicate unweighted edge is a no-op;
- weighted replacement updates both directions with the same logical edge data and changes neither count.

For a self-loop `u == v`, store one adjacency entry, increment both counts once, and perform only one inner update.

Partial symmetry is never observable because the graph is immutable until the complete new root is returned.

## 6. Removal

Directed removal deletes `to` from `from`'s inner structure. Missing source or target pair is a no-op. Empty inner structures remain attached to their vertex because vertex existence is independent of degree.

Undirected removal mirrors insertion:

- non-loop removal deletes both directions and decrements adjacency entries by two;
- self-loop removal deletes once;
- logical edge count decrements once;
- detecting only one stored direction is `:undirected_asymmetry`, not permission to publish a partially repaired graph.

## 7. Queries

- `has_vertex`: outer WBT search.
- `has_edge`: outer search plus inner search.
- `out_degree`: cached inner WBT size.
- `neighbors`: in-order inner fold into a fresh list.
- `fold_neighbors`: representation hook with no materialized list.
- `node_count`, `edge_count`: outer cached counters.

For undirected graphs, `degree` counts a self-loop according to graph-theoretic convention as two incidences, while `neighbor_entry_count` counts its one stored adjacency entry. The public `neighbors` list contains the loop target once.

## 8. Ordering

Vertex iteration is ascending `compare_node` order. Neighbor iteration is ascending target-node order.

`compare_edge_data` does not control adjacency placement. It supports trait-level data comparison and undirected reverse-entry validation. Neighbor views are generated as `{to: NodeIdType, data: EdgeDataType}`, so target extraction is structural and cannot disagree with the inner key.

## 9. Count invariants

Directed:

```text
edge_count = adjacency_entry_count
```

Undirected:

```text
adjacency_entry_count
  = 2 * non_loop_logical_edges + self_loop_logical_edges
edge_count
  = non_loop_logical_edges + self_loop_logical_edges
```

Outer WBT size equals node count. The sum of inner sizes equals adjacency-entry count.

## 10. Persistence and allocation

An edge update allocates:

- `O(log degree(from))` inner nodes;
- `O(log V)` outer nodes;
- for non-loop undirected edges, the corresponding path for the second endpoint, with sharing wherever old or newly built paths permit.

Old outer and inner roots remain valid. Comparator bundles and ordering identity are preserved.

## 11. Validation

Validation checks:

- outer and every inner WBT;
- endpoint existence for every adjacency target;
- every generated neighbor wrapper's `to` field equals the inner key;
- exact node and edge counts;
- directedness-specific symmetry and self-loop rules;
- for attributed/weighted undirected graphs, reverse entries carry comparator-equal direction-independent data and equal extracted weight;
- uniform canonical arena and ordering identity.

With only the live WBT indexes, target membership and reverse-edge checks require ordered lookups. Validation is therefore `O(V + A log V)` worst-case. A diagnostic build may reduce this with an auxiliary dense-slot or hash index, but that is not part of the live representation's bound.

## 12. Complexity

Let `d(u)` be stored adjacency entries at `u`, `A` total adjacency entries.

| Operation | Time |
|---|---:|
| add vertex | `O(log V)` |
| directed add/remove edge | `O(log V + log d(u))` |
| undirected add/remove non-loop | `O(log V + log d(u) + log d(v))` |
| has vertex | `O(log V)` |
| has edge | `O(log V + log d(u))` |
| materialize neighbors | `O(log V + d(u))` |
| fold all vertices/edges | `O(V + A)` |
| validate | `O(V + A log V)` |
