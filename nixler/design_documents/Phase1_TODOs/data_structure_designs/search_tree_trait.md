# `SearchTree` Detailed Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/SearchTree.silica`, a trait over the `wbt_set` value that implements `OrderedSet`; trials in `trials/ordered_data_structures/search_tree_collections/` (14 programs). A `SearchTree`-typed parameter accepts an updated tree (`st_parameter_accepts_updated_tree`).

**Public trait:** `SearchTree`  
**Concrete standard implementation:** the same `wbt_set` value that implements `OrderedSet`  
**Separate storage:** none
**Generic placeholders:** `ItemType` and `SpaceType` follow the [overriding genericity rule](common_contract.md#overriding-genericity-rule) and are determined by programmer declarations.

## 1. Meaning

`SearchTree` is a behavioral view for ordered membership search. It exists so algorithms that require search but not set-specific vocabulary can accept a narrower trait.

It does not denote a rose tree, B-tree, node-id tree, trie, or second WBT record.

## 2. Type and construction

```text
SearchTree[ItemType, mem(SpaceType)]
```

The standard value is constructed with `wbt_set`:

```silica
index: SearchTree[string, mem(normal)] <- wbt_set@empty({
    compare_item: compare_string
});
```

Constructor record:

```text
{ compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater) }
```

The generated concrete record is identical to the `OrderedSet` record. The compiler registers that one concrete type as implementing both independent traits.

## 3. Trait contract

```text
export trait SearchTree;

/// Reports whether the tree contains the comparator-equivalence class of `key`.
export contains_key/2;

/// Compares two items with the comparator captured by the tree.
export compare_item/3;

required {
    fn compare_item(tree: SearchTree, a: ItemType, b: ItemType) -> (:less | :equal | :greater);
    fn contains_key(tree: SearchTree, key: ItemType) -> boolean;
}

// Empty implementation scaffold.
fn compare_item(tree: SearchTree, a: ItemType, b: ItemType) -> (:less | :equal | :greater) {}
fn contains_key(tree: SearchTree, key: ItemType) -> boolean {}
```

For the standard implementation:

```text
SearchTree@contains_key(tree, key)
    = OrderedSet@contains(tree, key)
```

The forwarding implementation performs direct WBT search; it does not fold.

## 4. Updates

`SearchTree` has no separate mutation trait surface. Standard construction and persistent updates use:

```text
wbt_set@empty
wbt_set@insert
wbt_set@delete
wbt_set@from_list
wbt_set@from_sorted
```

The returned concrete value continues to implement both `SearchTree` and `OrderedSet`.

## 5. Semantics

- Key identity is comparator equality.
- Search on empty or absent key returns false.
- Search on present key returns true.
- Duplicate insertion through `wbt_set` is a no-op.
- Prior versions remain valid after updates.

## 6. Why the trait remains distinct

An algorithm may require only:

```text
SearchTree@contains_key
```

A custom representation can implement `SearchTree` without promising ordered-set fold or size behavior. Trait independence therefore avoids inheritance while retaining semantic precision.

Conversely, implementing `OrderedSet` does not automatically imply `SearchTree`; the standard adapter explicitly registers both.

## 7. Invariants and complexity

The standard implementation inherits all `OrderedSet` and WBT invariants.

| Operation | Time | Allocation |
|---|---:|---:|
| contains key | `O(log n)` | none |
| compare item | comparator cost | none |
| standard insert/delete | `O(log n)` | `O(log n)` on change |

## 8. Non-goals

No range-search API, predecessor/successor cursor, key/value association, or alternate storage family is implied by this minimal trait. Such operations belong to a separately designed trait expansion rather than being inferred from the name.
