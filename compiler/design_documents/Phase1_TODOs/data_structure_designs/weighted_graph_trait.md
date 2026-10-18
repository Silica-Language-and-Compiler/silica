# `WeightedGraph` Detailed Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/WeightedGraph.silica` over `graph_weighted`, `graph_weighted_undirected`, `graph_csr_weighted*` and `graph_dense_weighted*`; trials in `trials/ordered_data_structures/graph_live_core/` (`gl_weighted_directed`, `gl_weighted_undirected`) and `graph_collections/` (`gc_weighted_trait*`). No constructor-record compile-fail trial exists for this family.

**Public trait:** `WeightedGraph`
**Role:** orthogonal edge-weight capability on directed or undirected graph values
**Live storage:** inner WBT map `target -> edge data`
**Generic placeholders:** `NodeIdType`, `EdgeDataType`, `WeightType`, `AccType`, and `SpaceType` follow the [overriding genericity rule](common_contract.md#overriding-genericity-rule) and are determined by programmer declarations.

## 1. Trait relationship

Silica traits do not inherit. A standard weighted directed graph implements both:

```text
DirectedGraph
WeightedGraph
```

A standard weighted undirected graph implements both:

```text
UndirectedGraph
WeightedGraph
```

`WeightedGraph` does not itself choose directedness.

## 2. Public type

```text
WeightedGraph[
    NodeIdType,
    EdgeDataType,
    WeightType,
    mem(SpaceType)
]
```

Vertex IDs use `NodeIdType`, which may be any valid Silica type. `EdgeDataType` is direction-independent. Generated graph representations wrap it internally as `{to: NodeIdType, data: EdgeDataType}`.

## 3. Constructor record

```text
{
    compare_node: fn(NodeIdType, NodeIdType) -> (:less | :equal | :greater),
    compare_edge_data: fn(EdgeDataType, EdgeDataType) -> (:less | :equal | :greater),
    edge_weight: fn(EdgeDataType) -> WeightType,
    compare_weight: fn(WeightType, WeightType) -> (:less | :equal | :greater)
}
```

All fields participate in ordering identity because graph algorithms may rely on any of them.

Implementation: the record is the `functions` argument of `graph_weighted@empty/1` and `graph_weighted_undirected@empty/1` (live WBT) and of `graph_dense_weighted@empty_for_nodes(functions, nodes)` and the undirected dense twin; the signatures are exactly those above, with `ItemType`/`ValueType`/`KeyType` as the source spells the placeholders. CSR weighted graphs take no constructor record: they are frozen from a live graph with `graph_csr_weighted@freeze_from_wbt/1` and carry the live record's functions.

Weight algebra such as zero, addition, negativity checks, or infinity does **not** belong in the graph value. An algorithm such as Dijkstra receives its own inline function record:

```text
{
    zero: WeightType,
    add: fn(WeightType, WeightType) -> WeightType,
    valid_weight: fn(WeightType) -> boolean
}
```

This keeps storage semantics separate from algorithm semantics.

## 4. Trait contract

```text
export trait WeightedGraph;

/// Extracts a weight from direction-independent edge data.
export edge_weight/2;

/// Compares two direction-independent edge-data values.
export compare_edge_data/3;

/// Compares two extracted weights with the graph's captured comparator.
export compare_weight/3;

/// Materializes weighted adjacency entries in ascending target order.
export weighted_neighbors/2;

/// Folds weighted adjacency entries without materializing a list.
export fold_weighted_neighbors/4;

/// Looks up an edge by endpoint pair and returns its extracted weight.
export weight_of/3;

required {
    fn edge_weight(g: WeightedGraph, data: EdgeDataType) -> WeightType;
    fn compare_edge_data(g: WeightedGraph, a: EdgeDataType, b: EdgeDataType) -> (:less | :equal | :greater);
    fn compare_weight(g: WeightedGraph, a: WeightType, b: WeightType) -> (:less | :equal | :greater);
    fn weighted_neighbors(g: WeightedGraph, id: NodeIdType)
        -> List[{to: NodeIdType, data: EdgeDataType}, SpaceType];
    fn fold_weighted_neighbors(
        g: WeightedGraph,
        id: NodeIdType,
        init: AccType,
        step: fn(AccType, {to: NodeIdType, data: EdgeDataType}) -> AccType
    ) -> AccType;
    fn weight_of(g: WeightedGraph, from: NodeIdType, to: NodeIdType)
        -> {status: :not_found | :found, weight: WeightType};
}

// Empty implementation scaffold.
fn edge_weight(g: WeightedGraph, data: EdgeDataType) -> WeightType {}

fn compare_edge_data(
    g: WeightedGraph,
    a: EdgeDataType,
    b: EdgeDataType
) -> (:less | :equal | :greater) {}

fn compare_weight(
    g: WeightedGraph,
    a: WeightType,
    b: WeightType
) -> (:less | :equal | :greater) {}

fn weighted_neighbors(g: WeightedGraph, id: NodeIdType)
    -> List[{to: NodeIdType, data: EdgeDataType}, SpaceType] {}

fn fold_weighted_neighbors(
    g: WeightedGraph,
    id: NodeIdType,
    init: AccType,
    step: fn(AccType, {to: NodeIdType, data: EdgeDataType}) -> AccType
) -> AccType {}

fn weight_of(g: WeightedGraph, from: NodeIdType, to: NodeIdType)
    -> {status: :not_found | :found, weight: WeightType} {}
```

The graph receiver is first for every captured function dispatch.

## 5. Edge identity

Edge identity is `(from,to)`, not edge-data comparison and not weight.

Inserting an existing endpoint pair replaces the complete `EdgeDataType` value. It does not create a parallel edge and does not change edge counts.

`compare_edge_data` supports deterministic data comparison and reverse-edge validation but does not key the adjacency WBT.

## 6. Directed update semantics

`add_edge(g, from, to, data)`:

- auto-adds endpoints in the live representation;
- inserts or replaces `to -> data`;
- returns `inserted=true` only for a new pair;
- returns `replaced=true` only for an existing pair.

Removal is by `(from,to)` and discards the edge data.

## 7. Undirected wrapper model

One logical undirected edge datum produces two internal directional wrappers:

```text
{to: v, data: datum}
{to: u, data: datum}
```

The generated module constructs both wrappers, and `edge_weight` receives their shared `data` field. Replacement updates both wrappers atomically. A self-loop has one wrapper.

Validation requires reverse wrappers to have comparator-equal datum and weight, while their generated `to` fields differ as required.

## 8. Query semantics

Weighted neighbors are ascending by target node, not weight.

`weight_of(from,to)` performs endpoint-key lookup and extracts weight from the stored edge data. It returns `status=:not_found` when the edge is absent and `status=:found` when present.

Graph traversal algorithms that need smallest weight use a heap/priority queue; the graph does not maintain a second weight-sorted adjacency index.

## 9. CSR and dense forms

CSR stores neighbors and edge data in parallel buffers. Their positions must align.

Dense unweighted graphs store one boolean random-access-list cell sequence. Dense attributed/weighted graphs store one tagged `:none | (:some, EdgeDataType)` cell sequence, so presence and edge data cannot diverge.

Both forms implement `weight_of` and weighted-neighbor folds with the same semantics. CSR cannot replace weights incrementally; it must be re-frozen from an updated live graph.

## 10. Weight validity

The structure accepts any `WeightType` and any total `compare_weight`. It does not assume numeric weights, non-negative weights, or absence of NaN-like values.

Algorithm records impose stronger requirements. For example, Dijkstra must reject an edge when its `valid_weight` says the weight is negative or otherwise unsupported.

## 11. Invariants

1. every internal wrapper's target matches its adjacency key;
2. each endpoint pair has one edge-data value;
3. replacement preserves counts;
4. extracted weights always produce values accepted by `compare_weight`'s domain;
5. directedness-specific invariants hold;
6. reverse undirected edge-data values compare equal;
7. neighbor iteration is target-sorted;
8. function bundle and ordering identity are preserved.

## 12. Complexity

Live WBT:

| Operation | Time |
|---|---:|
| add/replace/remove directed edge | `O(log V + log d(from))` |
| weight lookup | `O(log V + log d(from))` |
| weighted neighbors | `O(log V + d(from))` |
| compare/extract weight | function cost |

CSR and dense bounds follow their representation designs.

## 13. Example

```silica
g0: WeightedGraph[int64, {weight: int64}, int64, mem(normal)]
    <- graph_wbt_directed@empty_weighted({
        compare_node: compare_int64,
        compare_edge_data: compare_weight_data,
        edge_weight: weight_data_weight,
        compare_weight: compare_int64
    });

g1 <- graph_wbt_directed@add_edge(
    g0,
    10,
    20,
    {weight: 7}
);
w <- WeightedGraph@weight_of(g1.graph, 10, 20);
```

`w.status = :found` and `w.weight = 7`.

## 14. Exclusions

No parallel weighted edges, weight-sorted neighbor order, implicit numeric weight algebra, or decrease-edge-weight mutation of CSR is included.
