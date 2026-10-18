# Ordered Set and Map Design (silica-compiler)

## 1. Purpose and scope

This document specifies generated **ordered set** and **ordered map** representations for Silica. It specializes [balanced_tree_and_heap_design.md](balanced_tree_and_heap_design.md) §3 (Adams weight-balanced trees). **Algorithm authority:** [Phase1_TODOs/data_structure_to_algorithms.md](Phase1_TODOs/data_structure_to_algorithms.md).

**Superseded:** `NodeIDBTreeSet`, `CsrBTreeSet`, `NodeIDBTreeMap`, `CsrBTreeMap`, and all B-tree-specific insert/split/finalize pipelines.

There is **one** ordered-set representation: **Adams WBT** [Ada93] for all key types. There is **no** Patricia/crit-bit specialization and **no** packed CSR tree as a mutable set store. CSR appears only in [graph_representation_design.md](graph_representation_design.md) as a **graph** snapshot, not as an ordered set backend.

Phase 1 behavior: generated modules implement `OrderedSet` / `OrderedMap` via trait adapters and constructor function records ([Phase1_TODOs/data_structures_as_traits.md](Phase1_TODOs/data_structures_as_traits.md)).

First target:

```text
WeightBalancedTreeSet[ItemType, mem(normal)]
WeightBalancedTreeMap[KeyType, ValueType, mem(normal)]
```

**Emitted modules:** `wbt_set.silica`, `wbt_map.silica`.

**Implementation status (2026-10-16):** implemented as `compiler/stdlib/data_structures/wbt_set.silica` and `wbt_map.silica` with the `OrderedSet` and `OrderedMap` traits (trials `trials/ordered_data_structures/wbt_core/` and `ordered_collections/`). Differences from the shapes below: the node is an inline recursive tuple `(ItemType, int64, ref?, ref?)` (set) or `(KeyType, ValueType, int64, ref?, ref?)` (map) in a canonical arena, not a node list; the map `get` is `get/3` (a placeholder value for the `:not_found` payload); the public bracket types are `OrderedSet[ItemType, mem(normal)]` and `OrderedMap[KeyType, ValueType, mem(normal)]`, and the registry keys `WeightBalancedTreeSet`/`WeightBalancedTreeMap` below are descriptive only; `mem(normal)` is the only space in the landed modules. `join`/`split`/`concat` are not exported.

---

## 2. Shared ordered-collection model

### 2.1 Keys and comparators

All keys use **`compare_item`** (set) or **`compare_key`** (map) from the constructor record. Comparator results are `:less`, `:equal`, `:greater`.

### 2.2 Set semantics

- Unique keys.
- Insert existing key → unchanged tree, `inserted = false`.

### 2.3 Map semantics

- Unique keys with replace-on-duplicate: `inserted = false`, `replaced = true`.

### 2.4 Immutability

Every `insert` and `delete` returns a new WBT value; path copying preserves the old value [Ada93, Driscoll86].

### 2.5 Bulk construction

| API | Algorithm | Complexity |
| --- | --------- | ---------- |
| Default (`from_list`, fold) | Repeated `insert` | O(n log n) |
| `from_sorted` | Linear balanced build from sorted unique keys | O(n) |

---

## 3. Operations

### 3.1 Set

| Operation | Algorithm | Complexity | Reference |
| --------- | --------- | ---------- | --------- |
| Insert | Adams WBT insert | O(log n) | [Ada93] |
| Delete | Adams WBT delete | O(log n) | [Ada93] |
| Contains | BST search | O(log n) | [Ada93] |
| Fold | In-order traversal | O(n) | [Ada93] |

### 3.2 Map

| Operation | Algorithm | Complexity | Reference |
| --------- | --------- | ---------- | --------- |
| Insert / replace | WBT insert with value | O(log n) | [Ada93] |
| Delete | WBT delete | O(log n) | [Ada93] |
| Get | WBT search | O(log n) | [Ada93] |

---

## 4. Validation

Emit `validate` checking BST order, balance criterion, key counts, and (map) aligned values.

---

## 5. Naming and generator requirements

**Module names:** `wbt_set`, `wbt_map`.

**Exports:** `empty/1`, `insert/2` (set) or `insert/3` (map), `delete/2`, `contains/2`, `get/2`, `fold/3`, `from_sorted/…`, `validate/1`.

**Registry keys:** `WeightBalancedTreeSet[ItemType, mem(S)]`, `WeightBalancedTreeMap[KeyType, ValueType, mem(S)]`.

**Do not** emit width-duplicated exports (`insert[int64,…]`, …); use constructor records and declared collection types.

---

## 6. References

- [Phase1_TODOs/data_structure_to_algorithms.md](Phase1_TODOs/data_structure_to_algorithms.md)
- [balanced_tree_and_heap_design.md](balanced_tree_and_heap_design.md) §3
- [Ada93] Adams (1993). Efficient Sets—A Balancing Act. *JFP* 3(4).
