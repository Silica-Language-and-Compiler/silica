# Dense Matrix Graph Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/graph_dense_core.silica` with `graph_dense_directed`, `graph_dense_undirected`, `graph_dense_weighted`, `graph_dense_weighted_undirected`; trials in `trials/ordered_data_structures/graph_dense_core/` (9 programs) and `graph_collections/`. Deviation: cells are optional references (`ref?`) over the skew RAL for every family, not boolean or `:none | (:some, EdgeDataType)` cells (module header, deviation 1).

**Module family:** `graph_dense_directed`, `graph_dense_undirected`, weighted variants
**Storage:** skew binary random-access lists
**Vertex universe:** fixed at construction

## 1. Use case and boundary

Dense graphs serve small or high-density fixed vertex sets. They are persistent but not dynamically vertex-growing.

The representation is not a bitset. An unweighted graph uses one boolean random-access-list cell sequence. An attributed/weighted graph uses one tagged optional-data random-access-list cell sequence.

## 2. Vertex indexing

Construction receives a strictly ascending unique list of node ids. It builds:

- `slot_to_node`, a `SkewRAL[NodeIdType]` in slot order;
- `node_to_slot`, a `WBTMap[NodeIdType, int64]` built with `from_sorted`.

The vertex universe and slot assignment never change. `add_edge` rejects an endpoint not in the universe; it never auto-adds a vertex.

Public IDs use `NodeIdType`; dense slots use `int64`, and the domains are distinct. Every public operation resolves an ID through `node_to_slot` before indexing a cell.

## 3. Cell indexing

For `V = node_count`:

```text
cell(from_slot, to_slot) = from_slot * V + to_slot
cell_count = V * V
```

Both multiplication and addition are checked. Construction fails if `V * V` exceeds `int64` or the representable generated extent.

## 4. Physical shape

The exact field order, padding, and compiler spelling are private to one compiler/standard-library version.

Unweighted:

```text
cells: SkewRAL[boolean] length V*V
```

Weighted/attributed:

```text
cells: SkewRAL[:none | (:some, EdgeDataType)] length V*V
```

For attributed/weighted forms, `:none` means that the edge is absent and `(:some, data)` means that it is present with the complete direction-independent `EdgeDataType`. There is no redundant presence sequence.

The outer record also carries counts, node indexes, comparator/extractor bundle, region, directedness, and ordering identity.

`V` and `V*V` are checked runtime-sized internal extents. They are not public graph type parameters and do not produce different public graph types for different vertex counts.

## 5. Construction

`empty_for_nodes`:

1. validates strict node ordering;
2. computes `V` and `V*V`;
3. creates `node_to_slot` and `slot_to_node`;
4. for unweighted variants fills boolean cells with `false`;
5. for attributed/weighted variants fills tagged cells with `:none`;
6. sets edge and adjacency-entry counts to zero.

Work and storage are `Theta(V^2)`, which is why the representation is specialized.

## 6. Edge updates

Directed unweighted set:

- resolve both slots;
- update one boolean cell to true;
- increment counts only on false-to-true.

Directed weighted set:

- replace one tagged cell with `(:some, data)`;
- absent-to-present increments counts;
- present-to-present replaces edge data only.

Clear writes `false` in an unweighted graph or `:none` in an attributed/weighted graph and is a no-op for an absent edge.

Undirected non-loop updates both mirrored cells in one persistent result. Self-loops update one diagonal cell. Count equations match the live graph design.

If the second lockstep update fails, no partial outer root is published.

## 7. Neighbor traversal

A row is the logical range:

```text
[from_slot * V, from_slot * V + V)
```

Neighbor materialization scans that range with the random-access-list range cursor in `O(V)`, emits present targets in ascending slot order, and therefore in ascending `compare_node` order.

It must not perform `V` independent root lookups, which would inflate traversal to `O(V log V)`.

## 8. Query and update bounds

Resolving arbitrary node ids costs `O(log V)` through `node_to_slot`. Cell lookup/update costs `O(log(V^2)) = O(log V)`.

For APIs that already hold validated dense slots, internal operations may omit WBT lookup, but slots are not interchangeable with public node ids.

## 9. Persistence

Each cell update path-copies `O(log V)` random-access-list tree nodes. The unaffected matrix cells and all vertex indexes are shared.

An undirected update copies two cell paths. Implementations may share their common forest prefix but must preserve the same asymptotic bound and atomic publication.

## 10. Invariants

1. `V >= 0` and `cell_count = V*V` without overflow;
2. node indexes are a bijection and ascending by slot;
3. the one cell sequence has length exactly `cell_count`;
4. unweighted cells are boolean and attributed/weighted cells use exactly `:none | (:some, EdgeDataType)`;
5. generated neighbor wrappers use `slot_to_node[to_slot]` as their target;
6. counts equal present cells under directedness equations;
7. undirected mirrored cells have equal boolean presence or comparator-equal tagged edge data;
8. diagonal cells are stored once;
9. all nested structures share the canonical arena and ordering identity.

## 11. Validation

Validation checks vertex-index bijection, RAL invariants, exact runtime extent, tag validity where applicable, counts, and symmetry. It is `Theta(V^2)` because absence cells are part of the representation.

## 12. Complexity

| Operation | Time | New nodes |
|---|---:|---:|
| construct empty matrix | `Theta(V^2)` | `Theta(V^2)` |
| has/set/clear directed edge | `O(log V)` | update `O(log V)` |
| set/clear undirected non-loop | `O(log V)` | `O(log V)` |
| neighbors | `O(log V + V)` | list result `O(degree)` |
| fold all cells | `Theta(V^2)` | none |
| validate | `Theta(V^2)` | diagnostics |

## 13. Representation choice rule

Construction: `graph_dense_directed@empty_for_nodes(functions, nodes)` takes the same `functions` record as the matching live graph (`{ compare_node, compare_edge, edge_target }` directed; `{ compare_node, compare_edge_data }` undirected; `{ compare_node, compare_edge_data, edge_weight, compare_weight }` weighted) and the universe of node IDs as a `List`; the dense families have no freeze step.

This design is appropriate only when allocating and scanning `V^2` cells is acceptable. Sparse or dynamically growing graphs use the live WBT representation and may freeze to CSR for traversal.

The generated `graph_dense_directed` and `graph_dense_undirected` families, including attributed/weighted specializations, are distinct concrete types from WBT and CSR graphs. They implement the same query traits statically; no runtime representation tag unifies them. Their structural records are not a stable source, FFI, serialization, or cross-version ABI.
