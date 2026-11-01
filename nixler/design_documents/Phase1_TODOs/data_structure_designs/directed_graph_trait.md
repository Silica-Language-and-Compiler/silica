# `DirectedGraph` Detailed Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/DirectedGraph.silica` over `graph_wbt_directed`, `graph_csr_directed` and `graph_dense_directed`; trials in `trials/ordered_data_structures/graph_live_core/` and `graph_collections/` (`gc_directed_trait`, `gc_csr_directed_trait`, `gc_dense_directed_trait`). Deviations are numbered in the module headers (placeholder spelling, accumulator-second folds, no arity overloading, required rather than provided methods). No constructor-record compile-fail trial exists for this family.

**Public trait:** `DirectedGraph`
**Generated modules:** `graph_wbt_directed`, `graph_csr_directed`, `graph_dense_directed`
**Default live representation:** [`live_wbt_graph.md`](live_wbt_graph.md)
**Generic placeholders:** `NodeIdType`, `EdgePayloadType`, `AccType`, and `SpaceType` follow the [overriding genericity rule](common_contract.md#overriding-genericity-rule) and are determined by programmer declarations.

## 1. Abstract graph

`DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)]` is a finite directed simple graph whose public vertex IDs have any valid Silica `NodeIdType`:

- vertices are unique under `compare_node`;
- at most one directed edge exists for `(from,to)`;
- self-loops are permitted;
- parallel edges are not;
- isolated vertices are retained;
- every edge endpoint is a vertex.

For the unweighted generated variant, `EdgePayloadType = NodeIdType`. A custom attributed directed variant may use a payload whose `NodeIdType` target is extracted by `edge_target`. The standard weighted variant keeps direction-independent `EdgeDataType` separate and generates the internal directed wrapper `{to,data}`.

## 2. Constructor record

```text
{
    compare_node: fn(NodeIdType, NodeIdType) -> (:less | :equal | :greater),
    compare_edge: fn(EdgePayloadType, EdgePayloadType) -> (:less | :equal | :greater),
    edge_target: fn(EdgePayloadType) -> NodeIdType
}
```

The three functions are captured in the graph value and define its ordering identity.

Unweighted construction uses the same node comparator for `compare_edge` and identity for `edge_target`.

## 3. Trait contract

```text
export trait DirectedGraph;

/// Returns the number of vertices.
export node_count/1;

/// Returns the number of directed endpoint pairs.
export edge_count/1;

/// Reports whether `id` is an explicit vertex.
export has_vertex/2;

/// Materializes outgoing edges in ascending target order.
export neighbors/2;

/// Folds outgoing edges without materializing a list.
export fold_neighbors/4;

/// Compares two vertex IDs with the comparator captured by the graph.
export compare_node/3;

/// Compares two edge payloads with the comparator captured by the graph.
export compare_edge/3;

/// Extracts the target vertex ID from an edge payload.
export edge_target/2;

/// Returns the number of outgoing edges from `id`.
export out_degree/2;

/// Reports whether the directed endpoint pair `(from, to)` exists.
export has_edge/3;

/// Reports whether `to` is reachable from `from`.
export reachable/3;

required {
    fn node_count(g: DirectedGraph) -> int64;
    fn edge_count(g: DirectedGraph) -> int64;
    fn has_vertex(g: DirectedGraph, id: NodeIdType) -> boolean;
    fn neighbors(g: DirectedGraph, id: NodeIdType)
        -> List[EdgePayloadType, SpaceType];
    fn fold_neighbors(
        g: DirectedGraph,
        id: NodeIdType,
        init: AccType,
        step: fn(AccType, EdgePayloadType) -> AccType
    ) -> AccType;
    fn compare_node(g: DirectedGraph, a: NodeIdType, b: NodeIdType) -> (:less | :equal | :greater);
    fn compare_edge(g: DirectedGraph, a: EdgePayloadType, b: EdgePayloadType) -> (:less | :equal | :greater);
    fn edge_target(g: DirectedGraph, edge: EdgePayloadType) -> NodeIdType;
}

provided {
    fn out_degree(g: DirectedGraph, id: NodeIdType) -> int64;
    fn has_edge(g: DirectedGraph, from: NodeIdType, to: NodeIdType) -> boolean;
    fn reachable(g: DirectedGraph, from: NodeIdType, to: NodeIdType) -> boolean;
}

// Empty implementation scaffold.
fn node_count(g: DirectedGraph) -> int64 {}
fn edge_count(g: DirectedGraph) -> int64 {}
fn has_vertex(g: DirectedGraph, id: NodeIdType) -> boolean {}

fn neighbors(g: DirectedGraph, id: NodeIdType)
    -> List[EdgePayloadType, SpaceType] {}

fn fold_neighbors(
    g: DirectedGraph,
    id: NodeIdType,
    init: AccType,
    step: fn(AccType, EdgePayloadType) -> AccType
) -> AccType {}

fn compare_node(g: DirectedGraph, a: NodeIdType, b: NodeIdType) -> (:less | :equal | :greater) {}

fn compare_edge(
    g: DirectedGraph,
    a: EdgePayloadType,
    b: EdgePayloadType
) -> (:less | :equal | :greater) {}

fn edge_target(g: DirectedGraph, edge: EdgePayloadType) -> NodeIdType {}
fn out_degree(g: DirectedGraph, id: NodeIdType) -> int64 {}
fn has_edge(g: DirectedGraph, from: NodeIdType, to: NodeIdType) -> boolean {}
fn reachable(g: DirectedGraph, from: NodeIdType, to: NodeIdType) -> boolean {}
```

### Receiver dispatch

`edge_target/2` has `g` first so dispatch can access the extractor captured by a particular graph value. The same receiver rule applies to comparators.

`fold_neighbors` is required alongside materializing `neighbors`; provided algorithms use it to avoid a temporary list.

## 4. Live module surface

```text
/// Creates an empty live directed graph with the supplied function bundle.
export empty/1;

/// Persistently adds an explicit vertex if it is absent.
export add_vertex/2;

/// Persistently inserts or replaces one outgoing edge payload.
export add_edge/3;

/// Persistently removes one directed endpoint pair.
export remove_edge/3;

/// Reports whether an explicit vertex exists.
export has_vertex/2;

/// Reports whether a directed endpoint pair exists.
export has_edge/3;

/// Materializes outgoing edges in ascending target order.
export neighbors/2;

/// Visits every vertex once in ascending node order.
export fold_vertices/3;

/// Visits every directed edge once in deterministic order.
export fold_edges/3;

/// Returns the cached vertex cardinality.
export node_count/1;

/// Returns the cached directed-edge cardinality.
export edge_count/1;

/// Checks graph, WBT, count, endpoint, comparator, and arena invariants.
export validate/1;

// Empty implementation scaffold.
fn empty(
    functions: {
        compare_node: fn(NodeIdType, NodeIdType) -> (:less | :equal | :greater),
        compare_edge: fn(EdgePayloadType, EdgePayloadType) -> (:less | :equal | :greater),
        edge_target: fn(EdgePayloadType) -> NodeIdType
    }
) -> DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)] {}

fn add_vertex(
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    id: NodeIdType
) -> {
    graph: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    inserted: boolean
} {}

fn add_edge(
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    from: NodeIdType,
    edge: EdgePayloadType
) -> {
    graph: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    inserted: boolean,
    replaced: boolean
} {}

fn remove_edge(
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    from: NodeIdType,
    to: NodeIdType
) -> {
    graph: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    removed: boolean
} {}

fn has_vertex(
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    id: NodeIdType
) -> boolean {}

fn has_edge(
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    from: NodeIdType,
    to: NodeIdType
) -> boolean {}

fn neighbors(
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    id: NodeIdType
) -> List[EdgePayloadType, SpaceType] {}

fn fold_vertices(
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    init: AccType,
    step: fn(AccType, NodeIdType) -> AccType
) -> AccType {}

fn fold_edges(
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    init: AccType,
    step: fn(AccType, NodeIdType, EdgePayloadType) -> AccType
) -> AccType {}

fn node_count(
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)]
) -> int64 {}

fn edge_count(
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)]
) -> int64 {}

fn validate(
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)]
) -> {
    valid: boolean,
    error: atom,
    logical_count: int64
} {}
```

Signatures:

```text
add_vertex(g, id) -> {
    graph: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    inserted: boolean
}

add_edge(g, from, edge) -> {
    graph: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    inserted: boolean,
    replaced: boolean
}

remove_edge(g, from, to) -> {
    graph: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    removed: boolean
}
```

Unweighted duplicate insertion has both flags false. Attributed/weighted insertion on an existing pair has `inserted=false`, `replaced=true`.

## 5. Vertex and edge update semantics

`add_vertex` retains isolated vertices.

`add_edge` derives `to` from the payload and automatically inserts missing `from` and `to` vertices. This rule is specific to the live WBT representation.

`remove_edge` removes only the edge. It never removes an endpoint or another incident edge.

A future `remove_vertex` must be designed separately because removing incoming edges requires a full graph traversal in this outgoing-adjacency representation.

## 6. Query semantics

Neighbor order is ascending by target node comparator. `neighbors` on a missing or isolated node returns an empty list; `has_vertex` distinguishes those states.

`out_degree` is zero for missing or isolated nodes.

`has_edge` is false if either endpoint is absent.

`reachable`:

- false if either endpoint is absent;
- true for identical existing endpoints, including an isolated vertex;
- otherwise performs graph search using an `OrderedSet` visited set under the graph's node comparator;
- follows outgoing edges only;
- terminates on finite cyclic graphs.

Traversal order does not affect the boolean result.

## 7. Representation-specific construction

- `graph_wbt_directed@empty` produces a dynamically growing live graph.
- `graph_csr_directed@freeze_from_wbt` produces an immutable snapshot.
- `graph_dense_directed@empty_for_nodes` produces a fixed-vertex dense graph.

All three implement the query trait. Only their own generated modules expose valid updates.

The three module families produce distinct concrete generated types. Attributed and weighted forms are additional specializations of those families. Their compiler-version-private inline layouts are not a stable source or cross-version ABI.

## 8. Counts

`node_count` is vertex cardinality. `edge_count` is the number of directed pairs. A self-loop counts once.

For the directed representations:

```text
edge_count = sum(out_degree(v))
```

## 9. Invariants

1. all node and edge identity functions satisfy the common comparator contract;
2. every edge target exists as a vertex;
3. each `(from,to)` occurs at most once;
4. extracted payload target equals the adjacency key;
5. counts are exact and non-negative;
6. neighbor order is strict by target;
7. representation-specific invariants hold;
8. captured function bundle, region, and ordering identity are uniform.

## 10. Complexity

Live WBT:

| Operation | Time |
|---|---:|
| add vertex | `O(log V)` |
| add/remove/has edge | `O(log V + log d(from))` |
| out degree | `O(log V)` |
| neighbors | `O(log V + d(from))` plus list allocation |
| reachable | `O((V_r + E_r) log V)` with WBT visited set |

CSR and dense bounds are specified in their representation files.

## 11. Example

```silica
g0: DirectedGraph[int64, int64, mem(normal)]
    <- graph_wbt_directed@empty({
        compare_node: compare_int64,
        compare_edge: compare_int64,
        edge_target: identity_int64
    });

g1 <- graph_wbt_directed@add_edge(g0, 10, 20);
yes: boolean <- DirectedGraph@has_edge(g1.graph, 10, 20);
no: boolean <- DirectedGraph@has_edge(g1.graph, 20, 10);
```

`yes` is true and `no` is false.

## 12. Exclusions

No implicit reverse edge, parallel edge, dense-bitset backend, or mutable CSR update is included. Public vertex IDs are represented by `NodeIdType` and may use any valid Silica type.
