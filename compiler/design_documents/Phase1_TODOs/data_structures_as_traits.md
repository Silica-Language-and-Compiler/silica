# Standard Data Structures As Traits

**Date:** 2026-06-29; BinaryTree amendment 2026-07-02
**Status:** Trait API and representation wiring specification. **Implementation status (2026-10-16):** all ten traits and their representation modules are implemented in `compiler/stdlib/data_structures/` (see `standard_data_structures_implementation_plan.md` status records); the source snippets below remain the design, and the deviations the compiler forced are numbered in each module's header (placeholder-item arguments to `peek`/`root_item`/`get`, `KeyType`/`ValueType` spelling for `PriorityQueue`, `add_leaf/3` for the rose-tree `add_child`, `mem(normal)` only, inline records for values not bound from an `@empty` call).
**Algorithm authority (locked):** [data_structure_to_algorithms.md](data_structure_to_algorithms.md)
**Detailed API and representation authority:** [data_structure_designs/README.md](data_structure_designs/README.md)

---

## Purpose

Silica standard collections expose **behavior through traits**. Generated representation modules implement those traits. Construction and updates use **inline constructor function records** checked against explicitly declared collection types.

This document specifies:

- Trait module surfaces (`required` / `provided` operations)
- Constructor function-record contracts
- Which **generated module** implements each trait (aligned with the algorithm map)
- What programmers vs generated code supply

It does **not** describe bootstrap stdlib modules (`btree_`*, `graph_adj_*`, `heap_binary_*`). Those are obsolete relative to the locked algorithm map.

---

## Architecture (trait → representation → algorithm)

```text
OrderedSet / OrderedMap / SearchTree  →  wbt_set / wbt_map           →  Adams WBT [Ada93]
DirectedGraph / UndirectedGraph       →  graph_wbt_*                 →  WBT + WBT neighbors [Ada93, KL95]
WeightedGraph                         →  graph_wbt_* (weighted)        →  WBT + WBT map (to → edge data)
CSR graph (snapshot)                    →  graph_csr_*                 →  O(V+E) freeze from live WBT [KL95]
Dense matrix graph                    →  graph_dense_*                 →  Skew binary random-access list [Oka95]
Tree                                  →  tree_rose                    →  Rose tree; random-access child list [Oka95]
BinaryTree                            →  tree_binary                  →  Fixed left/right persistent tree + zipper [Hue97]
Heap                                  →  brodal_okasaki_min / max      →  Brodal–Okasaki [BO96]
PriorityQueue                         →  brodal_okasaki_min (pairs)    →  Brodal–Okasaki [BO96]
```

**Not in scope:** dense bitset graph.

**Rejected parallel paths:** finger trees, Patricia tries, HAMT, lazy/bootstrapped primary heaps, persistent vectors, d-ary array heaps, Hinze priority-search queues — see algorithm map.

---

## Design principles

1. Traits are not inheritable; a concrete type may implement multiple traits.
2. Behavior traits dispatch from a receiver-like first argument (`OrderedSet@contains(set, key)`).
3. All mutators return **new values** (functional persistence); captured comparators are preserved on every update path.
4. Node IDs, keys, values, priorities, directed edge payloads, direction-independent edge data, and weights are **typed collection parameters**.
5. Counts, capacities, and internal indices may remain `int64`.
6. Generated constructors take **inline function records** (no named struct aliases for those records); every landed family's record has at least one function field; `BinaryTree`'s is `{ compare_item }` (decision 2026-10-16), a witness for `ItemType` that the tree core never calls.
7. Collection variables declare explicit collection types including memory effects (`mem(normal)`, `mem(writethrough)`).
8. **One exported function per operation** per generated module (`export insert/2`, not per-width duplicates).
9. Algorithms in user code and stdlib should depend on **traits**, not generated module names.
10. Programmers may implement traits directly or supply **views/adapters** over custom storage.
11. Every constructor uses the canonical application-lifetime arena for its generated representation specialization and memory space.
12. Query status uses the atoms `:not_found | :found`; no named option type is introduced.

### Overriding placeholder rule

`ItemType`, `KeyType`, `ValueType`, `PriorityType`, `NodeIdType`, `EdgePayloadType`, `EdgeDataType`, `WeightType`, and `AccType` may each be any valid Silica value type legal in the declared memory and ownership context. `SpaceType` may be any valid Silica memory-space type.

The programmer determines every placeholder through explicit collection, binding, return, argument, callback, constructor-record, and constructor-value declarations. Compiler and standard-library implementations—including AI-generated implementations—must resolve and preserve those declared types. Concrete types appearing in examples, internal counts, slots, ranks, offsets, indexes, or representation sketches never constrain a placeholder. Missing or contradictory declaration evidence is a compile-time error; an implementation must not choose a default concrete type.

The detailed per-placeholder declaration mapping and implementation prohibitions are normative in the [common contract's overriding genericity rule](data_structure_designs/common_contract.md#overriding-genericity-rule).

---

## Comparator contract

Ordering comparators return exactly the atom union `(:less | :equal | :greater)`.

```text
fn compare_string(a: string, b: string) -> (:less | :equal | :greater) { ... }
```

No constructor, trait, or generated-module signature may widen this return type to bare `atom`.

---

## Constructor function record rule

Every standard collection constructor takes an inline function record. The compiler:

1. Checks the binding's declared collection type (e.g. `OrderedSet[string, mem(normal)]`).
2. Witnesses payload types from function-field signatures (e.g. `compare_item: fn(string, string) -> (:less | :equal | :greater)`).
3. Uses explicit non-record constructor arguments as additional type witnesses where the detailed design permits them.
4. Specializes the generated representation and trait dispatch to those concrete types.
5. Stores captured functions, when present, in the generated value for use by trait `provided` algorithms and representation updates.
6. Resolves the canonical application-lifetime arena for the generated specialization and memory space.

Memory space comes from the declared collection type, not from the function record.

Ordering compatibility is based on exact function-value identity. A top-level function symbol has one canonical identity; a closure identity includes its exact captured-environment instance, so separately created closures are incompatible even if behaviorally equivalent. Function-type equality is insufficient, and programmers cannot override identity with a declared token.

An unordered family such as `BinaryTree` has the constructor record `{ compare_item }` only as an `ItemType` witness (a bare `ItemType` resolves only from a `compare_*` field of the first argument; `{}` gives none, E2017). The function is stored in the tree record and never called, so the family carries no ordering bundle. Its specialization is determined from the declared collection type, the witness and explicit item arguments.

**Example (ordered set):**

```text
names: OrderedSet[string, mem(normal)] <- wbt_set@empty({
    compare_item: compare_string
});
names2: OrderedSet[string, mem(normal)] <- wbt_set@insert(names, "Ada");
```

**Example (mismatch — compile error):**

```text
names: OrderedSet[string, mem(normal)] <- wbt_set@empty({
    compare_item: fn(a: int64, b: int64) -> (:less | :equal | :greater) { ... }
        // wrong: not fn(string, string) -> (:less | :equal | :greater)
});
```

**Assoc-type placeholders:** trait signatures use `ItemType`, `KeyType`, `ValueType`, `NodeIdType`, `EdgePayloadType`, `EdgeDataType`, `WeightType`, and `SpaceType` (via `mem(SpaceType)`), plus receiver placeholders such as `BinaryTreeType`. The compiler resolves them from declared bracket types, constructor-record fields when present, and explicit constructor value arguments where the detailed design permits them.

---

## Trait categories

### Behavior traits

Operations over an existing structure value:

```text
DirectedGraph@neighbors(g, node_id)
OrderedSet@contains(set, key)
OrderedMap@get(map, key)
Heap@peek(heap)
```

### Generated construction and updates

Factory and mutator functions on representation modules (`wbt_set@empty`, `wbt_set@insert`, `graph_wbt_directed@add_edge`, `brodal_okasaki_min@push`, …). These are **not** separate trait surfaces; they return new values and preserve captured functions from construction.

---

## Trait modules and generated backends


| Trait module      | Primary generated module(s)                                              | Algorithm                          |
| ----------------- | ------------------------------------------------------------------------ | ---------------------------------- |
| `OrderedSet`      | `wbt_set`                                                                | Adams WBT [Ada93]                  |
| `OrderedMap`      | `wbt_map`                                                                | Adams WBT map [Ada93]              |
| `SearchTree`      | `wbt_set` (same backing as ordered set)                                  | Adams WBT [Ada93]                  |
| `DirectedGraph`   | `graph_wbt_directed`, `graph_csr_directed`, `graph_dense_directed`       | WBT live / CSR freeze / dense list |
| `UndirectedGraph` | `graph_wbt_undirected`, `graph_csr_undirected`, `graph_dense_undirected` | same                               |
| `WeightedGraph`   | weighted variants of above                                               | WBT inner map `to → edge data`     |
| `Heap`            | `brodal_okasaki_min`, `brodal_okasaki_max`                               | Brodal–Okasaki [BO96]              |
| `PriorityQueue`   | `brodal_okasaki_min` (pair compare)                                      | Brodal–Okasaki [BO96]              |
| `Tree`            | `tree_rose`                                                              | Random-access child list [Oka95]   |
| `BinaryTree`      | `tree_binary`                                                            | Fixed binary tree + zipper [Hue97] |


Thin **adapter modules** (`ordered_set_wbt_adapter`, `ordered_map_wbt_adapter`, …) may forward trait `impl fn` bodies to generated `@` operations on inner record shapes. Adapters are stdlib glue, not a separate public constructor style.

---

## OrderedSet

**Representation:** Adams weight-balanced tree with path copying [Ada93]. No integer-key specialization (no Patricia / crit-bit).

**Constructor function record:**

```text
{ compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater) }
```

**Trait surface:**

```text
export trait OrderedSet;

export contains/2;
export size/1;
export fold/3;
export compare_item/3;

required {
    fn compare_item[SetType, ItemType](
        set: SetType, a: ItemType, b: ItemType
    ) -> (:less | :equal | :greater);
    fn fold[SetType, ItemType, AccType](
        set: SetType, init: AccType, step: fn(AccType, ItemType) -> AccType
    ) -> AccType;
}

provided {
    fn contains[SetType, ItemType](set: SetType, item: ItemType) -> boolean;
    fn size[SetType](set: SetType) -> int64;
}
```

**Representation-supplied `fold`:** in-order WBT traversal. Default `contains` and `size` may use `fold` + `compare_item`.

**Generated module `wbt_set`:**

```text
export empty/1;
export insert/2;
export delete/2;
export fold/3;           // required trait hook
export from_sorted/2;    // comparator record plus sorted unique item list

fn empty[ItemType, SpaceType](
    item_functions: {
        compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater)
    }
) -> OrderedSet[ItemType, SpaceType];

fn insert[ItemType, SpaceType](
    set: OrderedSet[ItemType, SpaceType], item: ItemType
) -> { set: OrderedSet[ItemType, SpaceType], inserted: boolean };

fn delete[ItemType, SpaceType](
    set: OrderedSet[ItemType, SpaceType], item: ItemType
) -> { set: OrderedSet[ItemType, SpaceType], removed: boolean };
```

**Semantics:** duplicate insert → unchanged tree, `inserted = false`. Default bulk build: fold insert; optional `from_sorted` when keys are pre-sorted.

---

## OrderedMap

**Representation:** Adams WBT map [Ada93] — replace value on duplicate key.

**Constructor function record:**

```text
{
    compare_key: fn(KeyType, KeyType) -> (:less | :equal | :greater),
    compare_value: fn(ValueType, ValueType) -> (:less | :equal | :greater)
}
```

Value comparator enables linear `find_value` via fold; primary storage remains key-indexed.

**Trait surface:**

```text
export trait OrderedMap;

export contains_key/2;
export find_value/2;
export get/2;
export size/1;
export fold/3;
export compare_key/3;
export compare_value/3;

required {
    fn compare_key[MapType, KeyType](
        map: MapType, a: KeyType, b: KeyType
    ) -> (:less | :equal | :greater);
    fn compare_value[MapType, ValueType](
        map: MapType, a: ValueType, b: ValueType
    ) -> (:less | :equal | :greater);
    fn fold[MapType, KeyType, ValueType, AccType](
        map: MapType, init: AccType,
        step: fn(AccType, KeyType, ValueType) -> AccType
    ) -> AccType;
    fn get[MapType, KeyType, ValueType](map: MapType, key: KeyType)
        -> { status: :not_found | :found, value: ValueType };
}

provided {
    fn contains_key[MapType, KeyType, ValueType](map: MapType, key: KeyType) -> boolean;
    fn find_value[MapType, KeyType, ValueType](map: MapType, value: ValueType)
        -> { status: :not_found | :found, key: KeyType };
    fn size[MapType](map: MapType) -> int64;
}
```

**Generated module `wbt_map`:**

```text
export empty/1;
export insert/3;
export delete/2;
export get/2;
export fold/3;
export from_sorted/2;    // optional O(n) from sorted unique keys + parallel values

fn empty[KeyType, ValueType, SpaceType](
    map_functions: {
        compare_key: fn(KeyType, KeyType) -> (:less | :equal | :greater),
        compare_value: fn(ValueType, ValueType) -> (:less | :equal | :greater)
    }
) -> OrderedMap[KeyType, ValueType, SpaceType];

fn insert[KeyType, ValueType, SpaceType](
    map: OrderedMap[KeyType, ValueType, SpaceType], key: KeyType, value: ValueType
) -> { map: OrderedMap[KeyType, ValueType, SpaceType], inserted: boolean, replaced: boolean };

fn get[KeyType, ValueType, SpaceType](
    map: OrderedMap[KeyType, ValueType, SpaceType], key: KeyType
) -> { status: :not_found | :found, value: ValueType };
```

---

## SearchTree

**Representation:** identical to `OrderedSet` (Adams WBT [Ada93]). Search-tree behavior is trait naming and documentation, not a separate storage family.

**Constructor function record:** same as `OrderedSet`.

**Trait surface:**

```text
export trait SearchTree;

export contains_key/2;
export compare_item/3;

required {
    fn compare_item[TreeType, ItemType](
        tree: TreeType, a: ItemType, b: ItemType
    ) -> (:less | :equal | :greater);
    fn contains_key[TreeType, ItemType](tree: TreeType, key: ItemType) -> boolean;
}
```

The standard implementation delegates `contains_key` to direct WBT search. No separate B-tree or node-id tree representation exists.

---

## Graph traits

### Live model (WBT + WBT adjacency)

```text
adj : WBTMap<NodeIdType, WBTSet<NodeIdType>>               -- unweighted
adj : WBTMap<NodeIdType, WBTMap<NodeIdType, EdgeData>>     -- weighted / attributed
```

Outer and inner structures use WBT with `compare_node`. Undirected graphs: symmetric update on `(u, v)` and `(v, u)`.

**Vertex identity:** public vertex IDs use `NodeIdType`, which may be any valid Silica type. Internal CSR/dense slots remain `int64` and are reached through an explicit node-to-slot map.

**Unweighted directed edge payload:** `EdgePayloadType = NodeIdType`.

**Weighted / attributed edge data:** target and direction-independent `EdgeDataType` are separate inputs. Generated neighbor views use the inline wrapper `{to: NodeIdType, data: EdgeDataType}`. Undirected graphs store two generated directional wrappers over one logical edge datum; programmers do not provide reverse-edge or retarget functions.

### DirectedGraph

**Constructor function record (directed unweighted minimum):**

```text
{
    compare_node: fn(NodeIdType, NodeIdType) -> (:less | :equal | :greater),
    compare_edge: fn(EdgePayloadType, EdgePayloadType) -> (:less | :equal | :greater),
    edge_target: fn(EdgePayloadType) -> NodeIdType
}
```

**Trait surface:**

```text
export trait DirectedGraph;

export node_count/1;
export edge_count/1;
export has_vertex/2;
export neighbors/2;
export fold_neighbors/4;
export compare_node/3;
export compare_edge/3;
export edge_target/2;
export out_degree/2;
export has_edge/3;
export reachable/3;

required {
    fn node_count(g: DirectedGraph) -> int64;
    fn edge_count(g: DirectedGraph) -> int64;
    fn has_vertex(g: DirectedGraph, id: NodeIdType) -> boolean;
    fn neighbors[GraphType, NodeIdType, EdgePayloadType, SpaceType](
        g: GraphType, node_id: NodeIdType
    ) -> List[EdgePayloadType, SpaceType];
    fn fold_neighbors(g: DirectedGraph, id: NodeIdType, init: AccType,
        step: fn(AccType, EdgePayloadType) -> AccType) -> AccType;
    fn compare_node(g: DirectedGraph, a: NodeIdType, b: NodeIdType)
        -> (:less | :equal | :greater);
    fn compare_edge(g: DirectedGraph, a: EdgePayloadType, b: EdgePayloadType)
        -> (:less | :equal | :greater);
    fn edge_target(g: DirectedGraph, edge: EdgePayloadType) -> NodeIdType;
}

provided {
    fn out_degree(...);
    fn has_edge(...);
    fn reachable(...);
}
```

**Generated live module `graph_wbt_directed`:**

```text
export empty/1;
export add_edge/3;
export remove_edge/3;
export add_vertex/2;

fn empty[NodeIdType, EdgePayloadType, SpaceType](
    graph_functions: {
        compare_node: fn(NodeIdType, NodeIdType) -> (:less | :equal | :greater),
        compare_edge: fn(EdgePayloadType, EdgePayloadType) -> (:less | :equal | :greater),
        edge_target: fn(EdgePayloadType) -> NodeIdType
    }
) -> DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)];

fn add_edge[NodeIdType, EdgePayloadType, SpaceType](
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    from_id: NodeIdType,
    edge: EdgePayloadType
) -> {
    graph: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    inserted: boolean,
    replaced: boolean
};

fn add_vertex[NodeIdType, EdgePayloadType, SpaceType](
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    id: NodeIdType
) -> {
    graph: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    inserted: boolean
};

fn remove_edge[NodeIdType, EdgePayloadType, SpaceType](
    g: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    from_id: NodeIdType,
    to_id: NodeIdType
) -> {
    graph: DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)],
    removed: boolean
};
```

Vertices may be added dynamically when an edge references a new id (path-copying WBT insert).

### UndirectedGraph

`UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)]` stores direction-independent edge data and generates directional neighbor wrappers internally.

Constructor record:

```text
{
    compare_node: fn(NodeIdType, NodeIdType) -> (:less | :equal | :greater),
    compare_edge_data: fn(EdgeDataType, EdgeDataType) -> (:less | :equal | :greater)
}
```

Its trait surface mirrors `DirectedGraph`, with `degree/2` and `connected/3`, and uses:

```text
neighbors(g, id: NodeIdType) -> List[{to: NodeIdType, data: EdgeDataType}, SpaceType]
edge_target(g, edge: {to: NodeIdType, data: EdgeDataType}) -> NodeIdType
```

The general generated update is `add_edge(g, from, to, data)`. The unweighted `EdgeDataType = unit` specialization also exports `add_edge(g, from, to)`.

### WeightedGraph

`WeightedGraph[NodeIdType, EdgeDataType, WeightType, mem(SpaceType)]` is an independent capability implemented alongside `DirectedGraph` or `UndirectedGraph`. Its constructor record is:

```text
{
    compare_node: fn(NodeIdType, NodeIdType) -> (:less | :equal | :greater),
    compare_edge_data: fn(EdgeDataType, EdgeDataType) -> (:less | :equal | :greater),
    edge_weight: fn(EdgeDataType) -> WeightType,
    compare_weight: fn(WeightType, WeightType) -> (:less | :equal | :greater)
}
```

Its behavior trait exposes receiver-based `compare_edge_data/3`, `edge_weight/2`, `compare_weight/3`, `weighted_neighbors/2`, `fold_weighted_neighbors/4`, and `weight_of/3`.

Algorithm-specific fields (`zero_weight`, `add_weight`) belong in algorithm function records, not necessarily in the graph value.

### CSR snapshot (read-only traversal)

**Module family:** `graph_csr_`*. Built by **freeze** from a live WBT graph: O(V + E) two-pass (degree count → prefix-sum → scatter). Live graph unchanged after freeze. CSR does not support incremental edge updates — re-freeze after live-graph edits.

Implements the same graph traits for query operations (`neighbors`, `has_edge`, …) on immutable snapshot values.

CSR stores public `NodeIdType` values and internal `int64` dense slots as distinct domains. Runtime-sized internal buffers hold node IDs, offsets, neighbors, and—only for attributed/weighted specializations—a parallel edge-data buffer.

### Dense matrix graph (specialized)

**Module family:** `graph_dense_`*. Edge storage in a **skew binary random-access list** indexed by `from * V + to` [Oka95]. For small, dense `V`. Implements graph traits for set/clear/test edge operations via path copying.

Unweighted dense graphs use one boolean cell sequence. Attributed/weighted dense graphs use one `:none | (:some, EdgeDataType)` cell sequence; they do not maintain a redundant presence sequence.

CSR/dense extents are runtime-sized internal values and are not public graph type parameters. WBT, CSR, and dense families are distinct concrete generated types, with additional attributed/weighted specializations and static trait conformance. Their inline structural layouts are private to one compiler/standard-library version and are not stable source, FFI, serialization, or cross-version ABIs.

---

## Heap and PriorityQueue

**Representation:** Brodal–Okasaki optimal queue [BO96] — shared implementation for `Heap` and `PriorityQueue`. Max-heap uses reversed comparison. Arbitrary-entry deletion and decrease-key are not in the Phase 1 API.

### Heap

**Constructor function record:**

```text
{ compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater) }
```

**Trait surface:**

```text
export trait Heap;

export len/1;
export is_empty/1;
export peek/1;
export compare_item/3;

required {
    fn len(heap: Heap) -> int64;
    fn peek[HeapType, ItemType](heap: HeapType)
        -> { status: :not_found | :found, value: ItemType };
    fn compare_item(heap: Heap, a: ItemType, b: ItemType)
        -> (:less | :equal | :greater);
}

provided {
    fn is_empty(heap: Heap) -> boolean;
}
```

**Generated module `brodal_okasaki_min` / `brodal_okasaki_max`:**

```text
export empty/1;
export push/2;
export pop/1;
export meld/2;

fn empty[ItemType, SpaceType](
    item_functions: {
        compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater)
    }
) -> Heap[ItemType, SpaceType];

fn push[ItemType, SpaceType](
    heap: Heap[ItemType, SpaceType], item: ItemType
) -> Heap[ItemType, SpaceType];

fn pop[ItemType, SpaceType](
    heap: Heap[ItemType, SpaceType]
) -> {
    heap: Heap[ItemType, SpaceType],
    status: :not_found | :found,
    value: ItemType
};
```

### PriorityQueue

**Constructor function record:**

```text
{
    compare_priority: fn(PriorityType, PriorityType) -> (:less | :equal | :greater),
    compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater)
}
```

When priority is embedded in the item, add `priority_of: fn(ItemType) -> PriorityType`.

**Trait surface:**

```text
export trait PriorityQueue;

export len/1;
export is_empty/1;
export peek/1;
export peek_priority/1;
export peek_value/1;

required {
    fn len(queue: PriorityQueue) -> int64;
    fn peek(queue: PriorityQueue) -> {
        status: :not_found | :found,
        priority: PriorityType,
        value: ItemType
    };
}

provided {
    fn is_empty(queue: PriorityQueue) -> boolean;
    fn peek_priority(queue: PriorityQueue)
        -> { status: :not_found | :found, priority: PriorityType };
    fn peek_value(queue: PriorityQueue)
        -> { status: :not_found | :found, value: ItemType };
}
```

**Generated operations:** `empty_priority_queue`, `push_priority`, `peek_priority_entry`, `pop_priority`, `meld_priority`, `len`, `from_entries`, and `validate`, using the same Brodal–Okasaki core with lexicographic pair comparison (priority first, then value). No `delete_entry` or `decrease_priority` operation is generated.

---

## BinaryTree

**Representation:** persistent fixed-arity binary tree with one optional left and one optional right recursive child. A Huet-style zipper is available through representation-module operations for focused traversal and reconstruction.

**Constructor function record:**

```text
{ compare_item: fn(ItemType, ItemType) -> :less | :equal | :greater }
```

Item ordering, equality, and extraction do not control this representation, so the tree core never calls `compare_item` and builds no ordering bundle. The field exists because the compiler resolves a bare `ItemType` at a qualified call only from a `compare_item` or `compare_priority` function field of the first argument; an empty record `{}` gives no witness (E2017). The function is stored in the tree record and carried through every constructor and update. The expected collection type and explicit item arguments witness `SpaceType`.

**Trait surface:**

```text
export trait BinaryTree;

export node_count/1;
export is_empty/1;
export root_item/1;
export get/2;
export left_item/2;
export right_item/2;
export fold_preorder/3;
export fold_inorder/3;
export fold_postorder/3;
```

Paths are inline `List[:left | :right, SpaceType]` values. `:none` represents an empty root or child; no cyclic dummy node is part of the representation.

**Implementation status (2026-10-16):** the landed trait is `BinaryTree.silica` over `tree_binary.silica`. Its required methods are `node_count/1`, `root_item/2`, `get/3`, `left_item/3`, `right_item/3` and the three folds (`/3`), with provided `is_empty/1`; the extra argument is a placeholder item for the `:not_found` payload. Paths are built with `tree_binary@path_root`, `path_left`, `path_right` because atoms are numbered per compilation unit. The constructor record is `{ compare_item }` (decision 2026-10-16: the specification follows the implementation).

**Generated module `tree_binary`:** `empty`, `with_root`, `node`, `replace_item`, `replace_left`, `replace_right`, `clear_left`, `clear_right`, root/child queries, preorder/inorder/postorder folds, shape-preserving maps, inline zipper operations, and `validate`.

Updates path-copy only the selected route and share every untouched subtree. The concrete value carries a canonical arena and specialization key but no comparator or ordering bundle. The zipper is an inline representation-module value, not a named public collection family.

`BinaryTree` does not replace `Tree`, `SearchTree`, or their representations.

---

## Tree

**Representation:** rose tree — each node holds a label and a **child sequence** stored in a skew binary random-access list [Oka95, Oka98 §5].

**Constructor function record:**

```text
{ compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater) }
```

Root construction is `tree_rose@with_root(functions, root_item)`.

**Trait surface:**

```text
export trait Tree;

export node_count/1;
export root_item/1;
export get/2;
export child_count/2;
export child_slot_count/2;
export child_at/3;
export fold_preorder/3;
export compare_item/3;
```

**Generated module `tree_rose`:** `with_root`, `replace_item`, `add_child`, `add_subtree`, `remove_child`, `get`, `child_at`, `find_first`, `fold_preorder`, and `validate`. Updates use stable child slots and path copying; child slots are never compacted, reused, or renumbered. `node_count` counts logical rose-tree nodes, not WBT or random-access-list internal nodes.

**SearchTree** is documented above; it is not a separate rose-tree search structure.

---

## Views and adapters

Views let custom storage participate in trait algorithms without exposing the generated record shape:

```text
view: {
    graph: GraphType,
    neighbors_of: fn(GraphType, NodeIdType) -> List[EdgePayloadType, SpaceType]
} <- DirectedGraph@view(
    graph,
    {
        compare_node: compare_node,
        compare_edge: compare_edge,
        edge_target: edge_target
    },
    neighbors_of
);
```

The function record passed to `@view` supplies comparison semantics; `edge_target` is exposed through receiver-based `DirectedGraph@edge_target(view, edge)`. The view value holds only storage-specific access (`neighbors_of`).

Stdlib adapters (`ordered_set_wbt_adapter`, …) are the same pattern wired as `impl fn` glue from trait modules to generated backends.

---

## What programmers supply

- Explicit collection type declarations at bindings and function returns.
- Inline constructor function records with comparators/extractors where required, or `{ compare_item }` as a witness-only record for BinaryTree.
- For custom structures: either direct trait `impl fn` or a view/adaptor value.

**Examples:**

```text
names: OrderedSet[string, mem(normal)] <- wbt_set@empty({
    compare_item: compare_string
});

users: OrderedMap[string, User, mem(normal)] <- wbt_map@empty({
    compare_key: compare_string,
    compare_value: compare_user
});

frontier: Heap[int64, mem(normal)] <- brodal_okasaki_min@empty({
    compare_item: compare_node_id
});

syntax: BinaryTree[string, mem(normal)] <- tree_binary@with_root({ compare_item: compare_strings }, "root");

g: DirectedGraph[NodeId, Edge, mem(normal)] <- graph_wbt_directed@empty({
    compare_node: compare_node_id,
    compare_edge: compare_edge,
    edge_target: edge_target
});
```

---

## What generated modules supply

Each representation module supplies:

1. Constructor and update functions (`@empty`, `@insert`, `@add_edge`, `@push`, …).
2. Representation-specific traversals required by trait `provided` blocks (especially `fold` on WBT set/map).
3. Trait `impl fn` bodies (directly or via adapters) for `required` operations.
4. Optional `validate/1` helpers for development trials (not part of public trait surface unless exported by design).

Example responsibilities:


| Module               | Trait ops                                                | Module ops                                     |
| -------------------- | -------------------------------------------------------- | ---------------------------------------------- |
| `wbt_set`            | `OrderedSet@contains`, `@size`, `@fold`, `@compare_item` | `@empty`, `@insert`, `@delete`, `@from_sorted` |
| `wbt_map`            | `OrderedMap@get`, `@fold`, `@contains_key`, …            | `@empty`, `@insert`, `@delete`, `@get`         |
| `graph_wbt_directed` | `DirectedGraph@neighbors`, `@node_count`, …              | `@empty`, `@add_edge`                          |
| `graph_csr_directed` | query ops on frozen snapshot                             | `@freeze_from_wbt`                             |
| `brodal_okasaki_min` | `Heap@peek`, `@len`                                      | `@empty`, `@push`, `@pop`, `@meld`             |
| `tree_binary`        | `BinaryTree@root_item`, child queries, folds              | construction, replacement, map, zipper, validate |


---

## Compiler obligations

Required compiler support before stdlib acceptance:


| #   | Obligation                                                                              | Notes                                                  |
| --- | --------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| 1   | First-argument trait dispatch from concrete receiver type                               |                                                        |
| 2   | Placeholder matching for trait `required` / `provided` signatures                       | E2092-class errors                                     |
| 3   | Constructor function-record resolution from declared collection type + field signatures | E2017-class errors                                     |
| 4   | Bracket-type witnesses for all collection families                                      | `OrderedSet`, `OrderedMap`, `Heap`, `DirectedGraph`, … |
| 5   | Checking / codegen for `provided` trait block bodies                                    |                                                        |
| 6   | Link-name mangling from resolved concrete trait impl types                              |                                                        |
| 7   | Closed comparator return-type enforcement                                               | statically require `:less | :equal | :greater`         |
| 8   | Exact empty constructor-record resolution for unordered families                        | BinaryTree `{ compare_item }`; declared/argument witnesses required   |


**Implementation status (2026-10-16):** obligations 1–7 are met by the checker and the landed stdlib (`compiler_substrate/` trait-dispatch, constructor, registry and comparator trials; `error_enforcement_addition/standard_data_structures/`). Obligation 8 is met in the form `{ compare_item }` (decision 2026-10-16): `tree_binary@empty` takes `{ compare_item }`, because a bare `ItemType` resolves only from a `compare_*` field of the constructor record, and `{}` gives no witness (E2017). The `BinaryTree[ItemType, mem(normal)]` bracket type is accepted.

`Collectable` placeholder resolution remains **list-specific**; standard structures use constructor function records, not public `Collectable` construction.

---

## Cross-representation pipelines


| Pipeline               | Trait / module involvement              |
| ---------------------- | --------------------------------------- |
| Edge list → live graph | Fold `graph_wbt_*@add_edge`             |
| Live WBT graph → CSR   | `graph_csr_*@freeze_from_wbt`           |
| Sorted keys → WBT set  | `wbt_set@from_sorted` or fold `@insert` |
| Multiple heaps → one   | `brodal_okasaki_*@meld`                 |
| SearchTree lookup      | `SearchTree@contains_key` → WBT backing |
| Binary tree rewrite    | `tree_binary` zipper or postorder map   |


---

## Resolved CSR/dense ABI decision

The CSR/dense decision is closed:

1. layouts are compiler-version-private structural records;
2. public vertex IDs use `NodeIdType`; internal slots use `int64`, and the domains remain distinct;
3. extents are runtime-sized internal values, not public graph type parameters;
4. CSR uses parallel neighbor/edge-data buffers, while dense uses boolean cells for unweighted graphs and one tagged optional-data sequence for attributed/weighted graphs;
5. WBT, CSR, and dense module families are distinct concrete generated types with additional attributed/weighted specializations.

---

## Benefits

- Algorithms written once per trait, shared across WBT, CSR snapshot, and dense matrix graph backends where applicable.
- Custom user structures participate via views or direct impls.
- Payload and vertex-ID types are explicit at construction; graph IDs may use any valid Silica type.
- Representation modules become implementation details behind traits.
- BinaryTree offers fixed-role persistent rewrites and zipper traversal without weakening or replacing rose `Tree`.

---

## Risks

- `provided` algorithms that default to `fold` may be asymptotically fine but allocation-heavy if `neighbors` materializes large lists every call.
- Error messages must distinguish trait dispatch, constructor resolution, function-record mismatch, and payload mismatch.
- Brodal–Okasaki and WBT codegen complexity is higher than array-backed bootstrap modules.
- BinaryTree `empty({ compare_item: ... })` requires sufficient declared result context; accepting it without a complete item/space witness would reintroduce ambiguous defaulting.

---

## Related documents


| Document                                                                               | Role                                              |
| -------------------------------------------------------------------------------------- | ------------------------------------------------- |
| [data_structure_to_algorithms.md](data_structure_to_algorithms.md)                     | Locked algorithms and complexity                  |
| [graph_representation_design.md](../graph_representation_design.md)                    | WBT graph shapes, CSR freeze, dense matrix        |
| [balanced_tree_and_heap_design.md](../balanced_tree_and_heap_design.md)                | WBT and Brodal–Okasaki module design              |
| [btree_set_design.md](../btree_set_design.md)                                          | Ordered set/map operations (WBT; filename legacy) |
| [silica-specification.md](../silica-specification.md)                                  | §8.2.4 standard generated structures              |
| [data_structure_designs/persistent_binary_tree.md](data_structure_designs/persistent_binary_tree.md) | BinaryTree core, zipper, sharing, validation |
| [data_structure_designs/binary_tree_trait.md](data_structure_designs/binary_tree_trait.md) | Public BinaryTree trait/module contract |
| [bootstrap_retirement_and_self_host_plan.md](bootstrap_retirement_and_self_host_plan.md) | The compiler's emitter pools on `wbt_map`; further compiler adoption withdrawn 2026-09-29 |
