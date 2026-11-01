# `UndirectedGraph` Detailed Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/UndirectedGraph.silica` over `graph_wbt_undirected`, `graph_csr_undirected` and `graph_dense_undirected`; trials in `trials/ordered_data_structures/graph_live_core/` and `graph_collections/` (`gc_undirected_trait`, `gc_csr_undirected_trait`, `gc_dense_undirected_trait`).

**Public trait:** `UndirectedGraph`
**Generated modules:** `graph_wbt_undirected`, `graph_csr_undirected`, `graph_dense_undirected`
**Generic placeholders:** `NodeIdType`, `EdgeDataType`, `AccType`, and `SpaceType` follow the [overriding genericity rule](common_contract.md#overriding-genericity-rule) and are determined by programmer declarations.

## 1. Abstract graph

`UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)]` is a finite undirected simple graph whose public vertex IDs have any valid Silica `NodeIdType`:

- unordered endpoint pairs identify edges;
- one self-loop per vertex is permitted;
- parallel logical edges are not;
- isolated vertices are retained;
- every endpoint exists as a vertex.

Physical representations may store two directions, but those directions form one logical edge.

## 2. Edge data and internal directional wrapper

The public `EdgeDataType` is direction-independent. The generated representation wraps it internally at each adjacency position:

```text
{
    to: NodeIdType,
    data: EdgeDataType
}
```

For a non-loop logical edge `(u,v,data)`, the representation stores `{to:v,data}` under `u` and `{to:u,data}` under `v`. A self-loop stores one wrapper. The programmer does not supply `edge_target`, `retarget_edge`, or a reverse-edge function.

The unweighted specialization uses `EdgeDataType = unit`; its convenience `add_edge/3` supplies `()` internally. The general attributed operation is `add_edge/4`.

Constructor:

```text
{
    compare_node: fn(NodeIdType, NodeIdType) -> (:less | :equal | :greater),
    compare_edge_data: fn(EdgeDataType, EdgeDataType) -> (:less | :equal | :greater)
}
```

## 3. Trait contract

The trait mirrors `DirectedGraph` but names undirected degree:

```text
export trait UndirectedGraph;

/// Returns the number of vertices.
export node_count/1;

/// Returns the number of logical unordered endpoint pairs.
export edge_count/1;

/// Reports whether `id` is an explicit vertex.
export has_vertex/2;

/// Materializes adjacency entries in ascending target order.
export neighbors/2;

/// Folds adjacency entries without materializing a list.
export fold_neighbors/4;

/// Compares two vertex IDs with the comparator captured by the graph.
export compare_node/3;

/// Compares two direction-independent edge-data values.
export compare_edge_data/3;

/// Extracts the target ID from an internal directional edge wrapper.
export edge_target/2;

/// Returns graph-theoretic degree, counting a self-loop twice.
export degree/2;

/// Reports whether the unordered endpoint pair `(a, b)` exists.
export has_edge/3;

/// Reports whether `a` and `b` are in the same connected component.
export connected/3;

required {
    fn node_count(g: UndirectedGraph) -> int64;
    fn edge_count(g: UndirectedGraph) -> int64;
    fn has_vertex(g: UndirectedGraph, id: NodeIdType) -> boolean;
    fn neighbors(g: UndirectedGraph, id: NodeIdType)
        -> List[{to: NodeIdType, data: EdgeDataType}, SpaceType];
    fn fold_neighbors(
        g: UndirectedGraph,
        id: NodeIdType,
        init: AccType,
        step: fn(AccType, {to: NodeIdType, data: EdgeDataType}) -> AccType
    ) -> AccType;
    fn compare_node(g: UndirectedGraph, a: NodeIdType, b: NodeIdType)
        -> (:less | :equal | :greater);
    fn compare_edge_data(g, a: EdgeDataType, b: EdgeDataType) -> (:less | :equal | :greater);
    fn edge_target(
        g: UndirectedGraph,
        edge: {to: NodeIdType, data: EdgeDataType}
    ) -> NodeIdType;
}

provided {
    fn degree(g: UndirectedGraph, id: NodeIdType) -> int64;
    fn has_edge(g: UndirectedGraph, a: NodeIdType, b: NodeIdType) -> boolean;
    fn connected(g: UndirectedGraph, a: NodeIdType, b: NodeIdType) -> boolean;
}

// Empty implementation scaffold.
fn node_count(g: UndirectedGraph) -> int64 {}
fn edge_count(g: UndirectedGraph) -> int64 {}
fn has_vertex(g: UndirectedGraph, id: NodeIdType) -> boolean {}

fn neighbors(g: UndirectedGraph, id: NodeIdType)
    -> List[{to: NodeIdType, data: EdgeDataType}, SpaceType] {}

fn fold_neighbors(
    g: UndirectedGraph,
    id: NodeIdType,
    init: AccType,
    step: fn(AccType, {to: NodeIdType, data: EdgeDataType}) -> AccType
) -> AccType {}

fn compare_node(g: UndirectedGraph, a: NodeIdType, b: NodeIdType) -> (:less | :equal | :greater) {}

fn compare_edge_data(
    g: UndirectedGraph,
    a: EdgeDataType,
    b: EdgeDataType
) -> (:less | :equal | :greater) {}

fn edge_target(
    g: UndirectedGraph,
    edge: {to: NodeIdType, data: EdgeDataType}
) -> NodeIdType {}

fn degree(g: UndirectedGraph, id: NodeIdType) -> int64 {}
fn has_edge(g: UndirectedGraph, a: NodeIdType, b: NodeIdType) -> boolean {}
fn connected(g: UndirectedGraph, a: NodeIdType, b: NodeIdType) -> boolean {}
```

As in `DirectedGraph`, graph-receiver `edge_target/2` replaces the non-dispatchable parent sketch.

## 4. Live module surface

```text
/// Creates an empty live undirected graph with the supplied function bundle.
export empty/1;

/// Persistently adds an explicit vertex if it is absent.
export add_vertex/2;

/// Persistently inserts an unweighted logical edge.
export add_edge/3;        // unweighted convenience

/// Persistently inserts or replaces an attributed logical edge.
export add_edge/4;        // graph, from, to, data

/// Persistently removes one unordered endpoint pair.
export remove_edge/3;

/// Reports whether an explicit vertex exists.
export has_vertex/2;

/// Reports whether an unordered endpoint pair exists.
export has_edge/3;

/// Materializes adjacency entries in ascending target order.
export neighbors/2;

/// Visits every vertex once in ascending node order.
export fold_vertices/3;

/// Visits every logical undirected edge exactly once.
export fold_edges/3;

/// Returns the cached vertex cardinality.
export node_count/1;

/// Returns the cached logical-edge cardinality.
export edge_count/1;

/// Checks symmetry, WBT, count, endpoint, comparator, and arena invariants.
export validate/1;

// Empty implementation scaffold.
fn empty(
    functions: {
        compare_node: fn(NodeIdType, NodeIdType) -> (:less | :equal | :greater),
        compare_edge_data: fn(EdgeDataType, EdgeDataType) -> (:less | :equal | :greater)
    }
) -> UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)] {}

fn add_vertex(
    g: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)],
    id: NodeIdType
) -> {
    graph: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)],
    inserted: boolean
} {}

fn add_edge(
    g: UndirectedGraph[NodeIdType, unit, mem(SpaceType)],
    from: NodeIdType,
    to: NodeIdType
) -> {
    graph: UndirectedGraph[NodeIdType, unit, mem(SpaceType)],
    inserted: boolean,
    replaced: boolean
} {}

fn add_edge(
    g: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)],
    from: NodeIdType,
    to: NodeIdType,
    data: EdgeDataType
) -> {
    graph: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)],
    inserted: boolean,
    replaced: boolean
} {}

fn remove_edge(
    g: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)],
    from: NodeIdType,
    to: NodeIdType
) -> {
    graph: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)],
    removed: boolean
} {}

fn has_vertex(
    g: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)],
    id: NodeIdType
) -> boolean {}

fn has_edge(
    g: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)],
    a: NodeIdType,
    b: NodeIdType
) -> boolean {}

fn neighbors(
    g: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)],
    id: NodeIdType
) -> List[{to: NodeIdType, data: EdgeDataType}, SpaceType] {}

fn fold_vertices(
    g: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)],
    init: AccType,
    step: fn(AccType, NodeIdType) -> AccType
) -> AccType {}

fn fold_edges(
    g: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)],
    init: AccType,
    step: fn(AccType, NodeIdType, NodeIdType, EdgeDataType) -> AccType
) -> AccType {}

fn node_count(
    g: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)]
) -> int64 {}

fn edge_count(
    g: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)]
) -> int64 {}

fn validate(
    g: UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)]
) -> {
    valid: boolean,
    error: atom,
    logical_count: int64
} {}
```

`add_edge(g, from, to, data)` receives endpoints separately from direction-independent edge data. The unweighted `add_edge(g, from, to)` supplies unit data.

Result flags match directed graph insertion:

```text
{graph, inserted: boolean, replaced: boolean}
```

## 5. Symmetric update semantics

For distinct endpoints `u` and `v`:

- insertion publishes both adjacency entries or none;
- removal publishes deletion of both or none;
- duplicate unweighted insert is a no-op;
- attributed/weighted replacement updates the data in both directional wrappers;
- one logical edge changes `edge_count` by one.

For `u == v`, only one diagonal adjacency entry exists.

Missing endpoints are auto-added by live insertion. Removal never removes vertices.

## 6. Degree and neighbors

Neighbor materialization emits one `{to,data}` entry per stored adjacency entry in ascending target order.

Graph-theoretic degree:

```text
degree(v) = non_loop_adjacency_entries(v) + 2 * self_loops(v)
```

Thus a self-loop appears once in `neighbors` but contributes two to `degree`.

Missing and isolated vertices both yield degree zero; `has_vertex` distinguishes them.

## 7. Edge fold

`fold_edges` visits every logical edge once:

- self-loop once;
- non-loop edge only from the endpoint that compares less under `compare_node`.

This canonical orientation is for traversal only and does not make the graph directed.

## 8. Connected

`connected(g,a,b)`:

- false if either vertex is absent;
- true if comparator-equal existing vertices;
- otherwise performs ordinary visited-set graph search;
- terminates in cycles and self-loops.

Because adjacency is symmetric, traversal direction is irrelevant.

## 9. Counts

Let `L` be self-loops and `N` non-loop logical edges:

```text
edge_count = L + N
adjacency_entry_count = L + 2N
sum(degree(v)) = 2 * edge_count
```

All equations use checked arithmetic.

## 10. Representation behavior

- Live WBT graphs grow vertices dynamically and maintain symmetric inner WBTs.
- CSR snapshots preserve both physical directions and logical edge count.
- Dense graphs use mirrored matrix cells and a single diagonal cell.

All implement identical query semantics.

The WBT, CSR, and dense module families produce distinct concrete generated types. Attributed and weighted forms are additional specializations. Their compiler-version-private inline layouts are not a stable source or cross-version ABI.

## 11. Invariants

1. every non-loop adjacency has exactly one reverse adjacency;
2. reverse entries carry comparator-equal `EdgeDataType` values;
3. self-loops are stored once;
4. endpoint and count invariants hold;
5. logical edge fold's canonical orientation is unique;
6. all representation-specific ordering and persistence invariants hold.

Asymmetry is a validation failure, not an alternate graph state.

## 12. Complexity

Live WBT:

| Operation | Time |
|---|---:|
| add vertex | `O(log V)` |
| add/remove non-loop edge | `O(log V + log d(u) + log d(v))` |
| self-loop update | `O(log V + log d(u))` |
| has edge | `O(log V + log d(u))` |
| neighbors | `O(log V + stored_degree(u))` |
| connected | `O((V_c + A_c) log V)` with WBT visited set |

## 13. Example

```silica
g0: UndirectedGraph[int64, unit, mem(normal)]
    <- graph_wbt_undirected@empty({
        compare_node: compare_int64,
        compare_edge_data: compare_unit
    });

g1 <- graph_wbt_undirected@add_edge(g0, 10, 20);
ab <- UndirectedGraph@has_edge(g1.graph, 10, 20);
ba <- UndirectedGraph@has_edge(g1.graph, 20, 10);
```

Both queries are true and `edge_count = 1`.

## 14. Exclusions

No parallel logical edges, half-edge public state, implicit vertex deletion, or self-loop double storage is allowed.
