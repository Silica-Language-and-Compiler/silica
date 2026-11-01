# Balanced Tree and Heap Design (silica-compiler)

## 1. Purpose and scope

This document specifies **ordered tree** and **heap** representations for Silica code generation without custom type declarations. **Algorithm authority** is locked in [Phase1_TODOs/data_structure_to_algorithms.md](Phase1_TODOs/data_structure_to_algorithms.md) (reviewed 2026-06). This file records Silica-specific shapes, trait wiring, naming, and generator requirements.

Primary families:

1. **`WeightBalancedTree`** (`WBT`) — Adams weight-balanced trees [Ada93] for ordered sets and maps. **All key types** use WBT with captured comparators; there is no separate integer-trie path.
2. **`BrodalOkasakiHeap`** — optimal purely functional priority queue [BO96]; serves both `Heap` and `PriorityQueue`.

**Superseded (do not implement):** `NodeIDBTree`, `CsrBTree`, `RegionBinaryHeap`, `RegionDaryHeap`, and related module names.

Phase 1 standard behavior is trait-oriented: generated representations implement standard traits; constructors take inline typed function records ([Phase1_TODOs/data_structures_as_traits.md](Phase1_TODOs/data_structures_as_traits.md)). **Immutability and uniform inline types** follow [graph_representation_design.md](graph_representation_design.md) §2.7–§2.8.

First implementation targets:

```text
WeightBalancedTreeSet[ItemType, mem(normal)]
WeightBalancedTreeMap[KeyType, ValueType, mem(normal)]
BrodalOkasakiMinHeap[ItemType, mem(normal)]
BrodalOkasakiPriorityQueue[PriorityType, ItemType, mem(normal)]
```

Registry bracket forms may identify generator keys (§2.6). **Emitted module filenames** use representation (+ min/max for heaps) only — for example `wbt_set.silica`, `wbt_map.silica`, `brodal_okasaki_min.silica` — not filenames that embed payload type or memory space.

**Implementation status (2026-10-16):** implemented in `compiler/stdlib/data_structures/` as `wbt_set` and `wbt_map` (§3) and `brodal_okasaki.silica` with its split units and the `brodal_okasaki_min`, `brodal_okasaki_max` and `brodal_okasaki_priority` forwarders (§4), under the traits `OrderedSet`, `OrderedMap`, `SearchTree`, `Heap` and `PriorityQueue`. Trials: `trials/ordered_data_structures/` (`wbt_core`, `ordered_collections`, `brodal_okasaki_core`, `heap_collections`, `search_tree_collections`). Nodes are inline recursive tuples in a canonical arena, not the node-list alternative of §3.2; comparators return `:less | :equal | :greater`, not `atom`. Deviations the compiler forced (placeholder arguments to `peek`/`get`, `KeyType`/`ValueType` spelling for `PriorityQueue`, `mem(normal)` only) are numbered in the module headers.

---

## 2. Shared constraints

### 2.1 No custom surface types

Do not emit `type OrderedSet = …` or named structs for generated families. Repeat inline structural record types in every signature.

### 2.2 Memory spaces

Use `normal` by default. Allocation during **`from_sorted`** or other one-shot builders runs inside `sequence proc[mem(S)] … produces pure … end`. **WBT** and **Brodal–Okasaki** updates use **path copying** on persistent nodes; they do not mutate caller-held buffers in place.

### 2.3 Constructor function records and operands

Set / search-tree constructor record:

```text
{
    compare_item: fn(ItemType, ItemType) -> atom
}
```

Map constructor record:

```text
{
    compare_key: fn(KeyType, KeyType) -> atom,
    compare_value: fn(ValueType, ValueType) -> atom
}
```

Heap constructor record:

```text
{
    compare_item: fn(ItemType, ItemType) -> atom
}
```

Priority queue constructor record:

```text
{
    compare_priority: fn(PriorityType, PriorityType) -> atom,
    compare_item: fn(ItemType, ItemType) -> atom
}
```

Optional `priority_of: fn(ItemType) -> PriorityType` when priority is embedded in the item.

Comparators return `:less`, `:equal`, or `:greater`.

### 2.4 Immutability

- **`insert`**, **`delete`**, **`push`**, and **`pop`** return a **new** record; the caller's old binding remains valid.
- Persistence: **path copying** [Driscoll86, Oka98] on WBT and heap nodes.

### 2.5 Constructor records, traits, and call syntax

- **Constructors:** `wbt_set@empty({ compare_item: compare_string })`
- **Updates:** `wbt_set@insert(set, key)`; captured comparators preserved in the value.
- **Traits:** `OrderedSet@contains(set, key)` dispatches from the concrete receiver type.

| Family | Registry form | Constructor fields |
|--------|---------------|-------------------|
| WBT set | `[ItemType, mem(S)]` | `compare_item` |
| WBT map | `[KeyType, ValueType, mem(S)]` | `compare_key`, `compare_value` |
| Brodal–Okasaki heap | `[ItemType, mem(S)]` | `compare_item` |
| Brodal–Okasaki PQ | `[PriorityType, ItemType, mem(S)]` | `compare_priority`, `compare_item` |

**Emitted modules:** `wbt_set`, `wbt_map`, `brodal_okasaki_min`, `brodal_okasaki_max`. Do **not** suffix modules with type or memory space.

---

## 3. Weight-balanced tree (ordered set and map)

**Reference:** Adams (1993) [Ada93]; locked decision in [data_structure_to_algorithms.md](Phase1_TODOs/data_structure_to_algorithms.md).

### 3.1 Summary

Binary search tree with subtree-size balancing. Single and double rotations on insert and delete. **O(log n)** worst-case insert, delete, and lookup. Persistence via path copying on the access path.

### 3.2 Inline shape (set)

```silica
{
    compare_item: fn(ItemType, ItemType) -> atom,
    root: WbtNode[ItemType, normal]   // generator-internal node type as inline record or id + node list
}
```

Generator may represent nodes as an inline record tree or as `{ nodes: List<WbtNodeRecord, S>, root_id: int64 }` provided lookup is **O(log n)** per level via tree links, not linear scan of all nodes. **Do not** use list-scan node lookup (superseded `NodeIDBTree` pattern).

Each `WbtNodeRecord` holds `key`, optional `value` (map), `size`, `left`, `right` child references (node ids or nested records per generator choice).

### 3.3 Operations (set)

| Operation | Algorithm | Complexity |
| --------- | --------- | ---------- |
| **Insert** | BST insert; Adams rebalance on unwind | O(log n) |
| **Delete** | BST delete; successor/predecessor swap; Adams rebalance | O(log n) |
| **Contains** | BST search | O(log n) |
| **Fold** | In-order walk | O(n) |

**Duplicate policy (set):** key present → unchanged tree, `inserted = false`.

### 3.4 Operations (map)

Same as set; store `(key, value)` at nodes. **Duplicate key:** replace value, `inserted = false`, `replaced = true`.

### 3.5 Bulk construction

| Constructor | Algorithm | Complexity |
| ----------- | --------- | ---------- |
| **`from_list` / fold** | Repeated `insert` | O(n log n) |
| **`from_sorted`** | Linear balanced build from sorted unique keys (median split) | O(n) |

Both must preserve captured comparators in the returned value.

### 3.6 Validation

Check: BST order by comparator; Adams balance criterion on subtree sizes; map key/value pairing; empty root convention.

### 3.7 `SearchTree` trait

Identical algorithms and representation as `OrderedSet` WBT [Ada93].

---

## 4. Brodal–Okasaki heap

**Reference:** Brodal & Okasaki (1996) [BO96]; Vuillemin binomial heaps [Vui78] as building block.

### 4.1 Summary

Optimal purely functional priority queue: **O(1) worst-case** insert, peek, and meld; **O(log n) worst-case** delete-min. Single implementation shared by `Heap` and `PriorityQueue`.

Max-heap: reverse comparison or store negated keys.

### 4.2 Inline shape (min-heap)

```silica
{
    compare_item: fn(ItemType, ItemType) -> atom,
    // Brodal–Okasaki forest + global min root (generator-internal representation)
    ...
}
```

Priority queue adds `compare_priority` and stores `(priority, value)` pairs with lexicographic ordering.

### 4.3 Operations

| Operation | Algorithm | Complexity |
| --------- | --------- | ---------- |
| **Push** | Skew binomial insert; global min; bootstrapped meld | O(1) worst |
| **Pop** | Remove min; forest fixup; bootstrapped meld of children | O(log n) worst |
| **Peek** | Read global min | O(1) |
| **Meld** | Bootstrapped queue meld | O(1) worst |
| **Decrease-key** | Delete + re-insert | O(log n) |

Static bulk build: fold push O(n log n) or use heap literature batch build if added later.

### 4.4 Validation

Check heap order, forest invariants, global root consistency, priority/value pairing on PQ shape.

---

## 5. Naming rules

Modules:

```text
wbt_set
wbt_map
brodal_okasaki_min | brodal_okasaki_max
```

Exported operations (arity-only exports): `empty`, `insert`, `delete`, `contains`, `get`, `push`, `pop`, `peek`, `validate`, `from_sorted`, `fold` (set/map as applicable).

**Trait dispatch:** `OrderedSet@contains`, `Heap@peek`, `PriorityQueue@pop`.

---

## 6. Generator requirements

### 6.1 WBT generator inputs

```text
kind: set | map
key_type / item_type: concrete inline type
value_type: concrete inline type   // map only
memory_space: normal | ...
compare_functions: constructor record fields
generate_delete: bool
generate_from_sorted: bool
```

Registry keys: `WeightBalancedTreeSet[ItemType, mem(S)]`, `WeightBalancedTreeMap[KeyType, ValueType, mem(S)]`.

### 6.2 WBT emitted functions (minimum)

Set: `empty`, `insert`, `delete`, `contains`, `validate`, `fold`, `from_sorted`.

Map: add `get`, `insert` (with replace semantics).

### 6.3 Brodal–Okasaki generator inputs

```text
kind: min | max
element_type: concrete inline ItemType
priority_type: concrete inline PriorityType   // PQ only
memory_space: normal | ...
heap_functions: constructor record fields
```

Registry keys: `BrodalOkasakiMinHeap[ItemType, mem(S)]`, `BrodalOkasakiPriorityQueue[PriorityType, ItemType, mem(S)]`.

### 6.4 Result shapes

Insert (set): `{ tree, inserted: bool }`.

Insert (map): `{ tree, inserted: bool, replaced: bool }`.

Get: `{ found: bool, value: ValueType }`.

Push: `{ heap, ok: bool }`.

Pop: `{ heap, ok: bool, value: ItemType }` (PQ returns priority and value per trait contract).

---

## 7. References

- [Phase1_TODOs/data_structure_to_algorithms.md](Phase1_TODOs/data_structure_to_algorithms.md) — locked algorithm map
- [Ada93] Adams, N. (1993). Efficient Sets—A Balancing Act. *JFP* 3(4).
- [BO96] Brodal, G. S., & Okasaki, C. (1996). Optimal Purely Functional Priority Queues. *JFP* 6(6).
- [Vui78] Vuillemin, J. (1978). A Data Structure for Manipulating Priority Queues. *CACM* 21(7).
- [Driscoll86] Driscoll et al. (1986). Making Data Structures Persistent. *STOC*.
- [Oka98] Okasaki, C. (1998). *Purely Functional Data Structures*. Cambridge University Press.
