# `OrderedSet` Detailed Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/OrderedSet.silica` over `wbt_set.silica`; trials in `trials/ordered_data_structures/ordered_collections/` (`ordered_set_*`, `wbt_set_empty_insert`) and `wbt_core/`.

**Public trait:** `OrderedSet`  
**Generated representation module:** `wbt_set`  
**Shared core:** [`weight_balanced_tree.md`](weight_balanced_tree.md)
**Generic placeholders:** `ItemType`, `AccType`, and `SpaceType` follow the [overriding genericity rule](common_contract.md#overriding-genericity-rule) and are determined by programmer declarations.

## 1. Abstract value

`OrderedSet[ItemType, mem(SpaceType)]` is a finite set whose identity and ascending order are both defined by `compare_item`.

For any two values `a` and `b`, `compare_item(a,b) = :equal` means they denote the same set member. Inserting one after the other cannot create two entries.

The value is immutable and persistent.

## 2. Type and constructor

Constructor function record:

```text
{
    compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater)
}
```

Canonical construction:

```silica
names: OrderedSet[string, mem(normal)] <- wbt_set@empty({
    compare_item: compare_string
});
```

The generated value captures the comparator, region, optional WBT root, logical size through root metadata, and ordering identity.

## 3. Trait file contract

```text
export trait OrderedSet;

/// Reports whether the set contains the comparator-equivalence class of `item`.
export contains/2;

/// Returns the number of distinct comparator-equivalence classes.
export size/1;

/// Visits every item once in strictly ascending comparator order.
export fold/3;

/// Compares two items with the comparator captured by the set.
export compare_item/3;

required {
    fn compare_item(set: OrderedSet, a: ItemType, b: ItemType) -> (:less | :equal | :greater);
    fn fold(
        set: OrderedSet,
        init: AccType,
        step: fn(AccType, ItemType) -> AccType
    ) -> AccType;
}

provided {
    fn contains(set: OrderedSet, item: ItemType) -> boolean;
    fn size(set: OrderedSet) -> int64;
}

// Empty implementation scaffold.
fn contains(set: OrderedSet, item: ItemType) -> boolean {}
fn size(set: OrderedSet) -> int64 {}

fn fold(
    set: OrderedSet,
    init: AccType,
    step: fn(AccType, ItemType) -> AccType
) -> AccType {}

fn compare_item(set: OrderedSet, a: ItemType, b: ItemType) -> (:less | :equal | :greater) {}
```

The `wbt_set` implementation overrides provided `contains` and `size` with `O(log n)` search and `O(1)` cached size. Their fold-derived definitions remain valid fallbacks for custom trait implementations.

`fold` visits items in strictly ascending comparator order.

## 4. Generated module surface

```text
/// Creates an empty ordered set with the supplied item comparator.
export empty/1;

/// Creates an ordered set containing exactly one item.
export singleton/2;

/// Persistently inserts one comparator-equivalence class.
export insert/2;

/// Persistently removes one comparator-equivalence class.
export delete/2;

/// Reports whether an item class is present by direct WBT search.
export contains/2;

/// Returns the cached number of distinct items.
export size/1;

/// Visits all items in strictly ascending comparator order.
export fold/3;

/// Builds a set by inserting items from an arbitrary list.
export from_list/2;

/// Builds a set in linear time from a strictly ascending list.
export from_sorted/2;

/// Checks representation, ordering, size, comparator, and arena invariants.
export validate/1;

// Empty implementation scaffold.
fn empty(
    functions: {compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater)}
) -> OrderedSet[ItemType, mem(SpaceType)] {}

fn singleton(
    functions: {compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater)},
    item: ItemType
) -> OrderedSet[ItemType, mem(SpaceType)] {}

fn insert(
    set: OrderedSet[ItemType, mem(SpaceType)],
    item: ItemType
) -> {
    set: OrderedSet[ItemType, mem(SpaceType)],
    inserted: boolean
} {}

fn delete(
    set: OrderedSet[ItemType, mem(SpaceType)],
    item: ItemType
) -> {
    set: OrderedSet[ItemType, mem(SpaceType)],
    removed: boolean
} {}

fn contains(
    set: OrderedSet[ItemType, mem(SpaceType)],
    item: ItemType
) -> boolean {}

fn size(set: OrderedSet[ItemType, mem(SpaceType)]) -> int64 {}

fn fold(
    set: OrderedSet[ItemType, mem(SpaceType)],
    init: AccType,
    step: fn(AccType, ItemType) -> AccType
) -> AccType {}

fn from_list(
    functions: {compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater)},
    items: List[ItemType, SpaceType]
) -> {
    set: OrderedSet[ItemType, mem(SpaceType)],
    valid: boolean,
    error: atom
} {}

fn from_sorted(
    functions: {compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater)},
    items: List[ItemType, SpaceType]
) -> {
    set: OrderedSet[ItemType, mem(SpaceType)],
    valid: boolean,
    error: atom
} {}

fn validate(set: OrderedSet[ItemType, mem(SpaceType)]) -> {
    valid: boolean,
    error: atom,
    logical_count: int64
} {}
```

Normative result shapes:

```text
empty(functions) -> OrderedSet[ItemType, mem(SpaceType)]

singleton(functions, item)
    -> OrderedSet[ItemType, mem(SpaceType)]

insert(set, item)
    -> {set: OrderedSet[ItemType, mem(SpaceType)], inserted: boolean}

delete(set, item)
    -> {set: OrderedSet[ItemType, mem(SpaceType)], removed: boolean}

contains(set, item) -> boolean
size(set) -> int64

from_list(functions, items)
    -> {set: OrderedSet[ItemType, mem(SpaceType)], valid: boolean, error: atom}

from_sorted(functions, items)
    -> {set: OrderedSet[ItemType, mem(SpaceType)], valid: boolean, error: atom}
```

`items` has uniform type `List[ItemType, SpaceType]` for the complete value flow.

## 5. Operation semantics

### Empty and singleton

`empty` allocates the owning region/outer value but has no root node. `singleton` creates one WBT node of size one.

### Contains

Performs direct WBT search. Invalid comparator atoms produce a collection error rather than returning false.

### Insert

- Absent comparator class: insert one node, `inserted = true`.
- Present comparator class: preserve the old root and canonical stored item, `inserted = false`.

The set does not replace an existing item with a later comparator-equal representation.

### Delete

- Present class: remove its one node and return `removed = true`.
- Absent class: return the old root and `removed = false`.

### Fold

The callback is invoked exactly once for every logical item, in ascending order. Callback effects and accumulator ownership follow the callback's own type; the set traversal itself does not mutate the set.

### Bulk construction

`from_list` folds `insert` in list order. Comparator-equal duplicates are ignored. Complexity is `O(n log u)`, where `u` is the number of unique comparator classes.

`from_sorted` requires strict ascending order and rejects duplicates. It uses the deterministic linear builder in the WBT design.

## 6. Empty and failure cases

| Case | Result |
|---|---|
| contains on empty | `false` |
| delete from empty | unchanged, `removed=false` |
| duplicate insert | unchanged, `inserted=false` |
| fold empty | initial accumulator |
| invalid comparator result | `:invalid_comparator_result` |
| size overflow | update fails; old value remains valid |
| malformed sorted input | `valid=false`; no partial set published |

## 7. Invariants

In addition to WBT invariants:

1. each comparator-equivalence class occurs once;
2. root size is the public set size;
3. the captured comparator and ordering identity are preserved by every update;
4. fold output is strictly ascending;
5. the empty set has root `:none` and size zero.

## 8. Persistence and memory effects

Insertion/deletion execute under `mem(SpaceType)` and path-copy changed nodes. Queries are read-only. A duplicate insert or absent delete allocates no tree node.

Two versions may share all unaffected subtrees in the canonical application-lifetime arena. Individual collection versions do not reclaim that arena.

## 9. Complexity

| Operation | Time | Result allocation |
|---|---:|---:|
| empty | `O(1)` | outer value |
| singleton | `O(1)` | one node |
| contains | `O(log n)` | none |
| size | `O(1)` | none |
| insert/delete | `O(log n)` | `O(log n)` nodes on change |
| fold | `O(n)` | accumulator-defined |
| from_list | `O(n log u)` | `O(n log u)` transient persistent nodes |
| from_sorted | `O(n)` | `O(n)` |
| validate | `O(n)` | diagnostics |

## 10. Example

```silica
names0: OrderedSet[string, mem(normal)] <- wbt_set@empty({
    compare_item: compare_string
});

r1: {set: OrderedSet[string, mem(normal)], inserted: boolean}
    <- wbt_set@insert(names0, "Ada");

r2: {set: OrderedSet[string, mem(normal)], inserted: boolean}
    <- wbt_set@insert(r1.set, "Ada");

present: boolean <- OrderedSet@contains(r2.set, "Ada");
```

`names0` remains empty, `r1.inserted` is true, and `r2.inserted` is false.

## 11. Exclusions

No hash-set behavior, insertion-order iteration, integer trie, multiset count, in-place mutation, or alternate balance family is part of this type.
