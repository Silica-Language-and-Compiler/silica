# `OrderedMap` Detailed Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/OrderedMap.silica` over `wbt_map.silica`; trials in `trials/ordered_data_structures/ordered_collections/` (`ordered_map_*`) and `wbt_core/`. `get` is `get/3` (placeholder value for the `:not_found` payload).

**Public trait:** `OrderedMap`  
**Generated representation module:** `wbt_map`  
**Shared core:** [`weight_balanced_tree.md`](weight_balanced_tree.md)
**Generic placeholders:** `KeyType`, `ValueType`, `AccType`, and `SpaceType` follow the [overriding genericity rule](common_contract.md#overriding-genericity-rule) and are determined by programmer declarations.

## 1. Abstract value

`OrderedMap[KeyType, ValueType, mem(SpaceType)]` is a finite mapping from comparator-equivalence classes of keys to exactly one value.

Keys determine WBT placement. Values never affect placement or balance.

## 2. Constructor

```text
{
    compare_key: fn(KeyType, KeyType) -> (:less | :equal | :greater),
    compare_value: fn(ValueType, ValueType) -> (:less | :equal | :greater)
}
```

`compare_value` supports trait-level `find_value` and deterministic value equality. It is not called by `get`, key insertion descent, deletion, or balancing.

```silica
users: OrderedMap[string, User, mem(normal)] <- wbt_map@empty({
    compare_key: compare_string,
    compare_value: compare_user
});
```

## 3. Trait contract

```text
export trait OrderedMap;

/// Reports whether the map contains the comparator-equivalence class of `key`.
export contains_key/2;

/// Finds the smallest key whose value compares equal to `value`.
export find_value/2;

/// Looks up the value associated with `key`.
export get/2;

/// Returns the number of key/value associations.
export size/1;

/// Visits every association once in strictly ascending key order.
export fold/3;

/// Compares two keys with the key comparator captured by the map.
export compare_key/3;

/// Compares two values with the value comparator captured by the map.
export compare_value/3;

required {
    fn compare_key(map: OrderedMap, a: KeyType, b: KeyType) -> (:less | :equal | :greater);
    fn compare_value(map: OrderedMap, a: ValueType, b: ValueType) -> (:less | :equal | :greater);
    fn get(map: OrderedMap, key: KeyType)
        -> {status: :not_found | :found, value: ValueType};
    fn fold(
        map: OrderedMap,
        init: AccType,
        step: fn(AccType, KeyType, ValueType) -> AccType
    ) -> AccType;
}

provided {
    fn contains_key(map: OrderedMap, key: KeyType) -> boolean;
    fn find_value(map: OrderedMap, value: ValueType)
        -> {status: :not_found | :found, key: KeyType};
    fn size(map: OrderedMap) -> int64;
}

// Empty implementation scaffold.
fn contains_key(map: OrderedMap, key: KeyType) -> boolean {}

fn find_value(map: OrderedMap, value: ValueType)
    -> {status: :not_found | :found, key: KeyType} {}

fn get(map: OrderedMap, key: KeyType)
    -> {status: :not_found | :found, value: ValueType} {}

fn size(map: OrderedMap) -> int64 {}

fn fold(
    map: OrderedMap,
    init: AccType,
    step: fn(AccType, KeyType, ValueType) -> AccType
) -> AccType {}

fn compare_key(map: OrderedMap, a: KeyType, b: KeyType) -> (:less | :equal | :greater) {}
fn compare_value(map: OrderedMap, a: ValueType, b: ValueType) -> (:less | :equal | :greater) {}
```

The WBT implementation overrides `size` with cached `O(1)` access. `find_value` remains an ascending in-order linear search and returns the smallest key whose value compares equal.

## 4. Generated module surface

```text
/// Creates an empty ordered map with the supplied comparators.
export empty/1;

/// Creates an ordered map containing exactly one association.
export singleton/3;

/// Persistently inserts or replaces an association by key class.
export insert/3;

/// Persistently removes an association by key class.
export delete/2;

/// Looks up the value associated with a key class.
export get/2;

/// Reports whether a key class is present.
export contains_key/2;

/// Finds the smallest key whose value compares equal to the query value.
export find_value/2;

/// Returns the cached number of associations.
export size/1;

/// Visits all associations in strictly ascending key order.
export fold/3;

/// Builds a map by inserting associations from an arbitrary list.
export from_list/2;

/// Builds a map in linear time from strictly ascending unique keys.
export from_sorted/2;

/// Checks representation, ordering, size, comparator, and arena invariants.
export validate/1;

// Empty implementation scaffold.
fn empty(
    functions: {
        compare_key: fn(KeyType, KeyType) -> (:less | :equal | :greater),
        compare_value: fn(ValueType, ValueType) -> (:less | :equal | :greater)
    }
) -> OrderedMap[KeyType, ValueType, mem(SpaceType)] {}

fn singleton(
    functions: {
        compare_key: fn(KeyType, KeyType) -> (:less | :equal | :greater),
        compare_value: fn(ValueType, ValueType) -> (:less | :equal | :greater)
    },
    key: KeyType,
    value: ValueType
) -> OrderedMap[KeyType, ValueType, mem(SpaceType)] {}

fn insert(
    map: OrderedMap[KeyType, ValueType, mem(SpaceType)],
    key: KeyType,
    value: ValueType
) -> {
    map: OrderedMap[KeyType, ValueType, mem(SpaceType)],
    inserted: boolean,
    replaced: boolean
} {}

fn delete(
    map: OrderedMap[KeyType, ValueType, mem(SpaceType)],
    key: KeyType
) -> {
    map: OrderedMap[KeyType, ValueType, mem(SpaceType)],
    removed: boolean
} {}

fn get(
    map: OrderedMap[KeyType, ValueType, mem(SpaceType)],
    key: KeyType
) -> {status: :not_found | :found, value: ValueType} {}

fn contains_key(
    map: OrderedMap[KeyType, ValueType, mem(SpaceType)],
    key: KeyType
) -> boolean {}

fn find_value(
    map: OrderedMap[KeyType, ValueType, mem(SpaceType)],
    value: ValueType
) -> {status: :not_found | :found, key: KeyType} {}

fn size(map: OrderedMap[KeyType, ValueType, mem(SpaceType)]) -> int64 {}

fn fold(
    map: OrderedMap[KeyType, ValueType, mem(SpaceType)],
    init: AccType,
    step: fn(AccType, KeyType, ValueType) -> AccType
) -> AccType {}

fn from_list(
    functions: {
        compare_key: fn(KeyType, KeyType) -> (:less | :equal | :greater),
        compare_value: fn(ValueType, ValueType) -> (:less | :equal | :greater)
    },
    items: List[{key: KeyType, value: ValueType}, SpaceType]
) -> {
    map: OrderedMap[KeyType, ValueType, mem(SpaceType)],
    valid: boolean,
    error: atom
} {}

fn from_sorted(
    functions: {
        compare_key: fn(KeyType, KeyType) -> (:less | :equal | :greater),
        compare_value: fn(ValueType, ValueType) -> (:less | :equal | :greater)
    },
    items: List[{key: KeyType, value: ValueType}, SpaceType]
) -> {
    map: OrderedMap[KeyType, ValueType, mem(SpaceType)],
    valid: boolean,
    error: atom
} {}

fn validate(map: OrderedMap[KeyType, ValueType, mem(SpaceType)]) -> {
    valid: boolean,
    error: atom,
    logical_count: int64
} {}
```

Result shapes:

```text
insert(map, key, value) -> {
    map: OrderedMap[KeyType, ValueType, mem(SpaceType)],
    inserted: boolean,
    replaced: boolean
}

delete(map, key) -> {
    map: OrderedMap[KeyType, ValueType, mem(SpaceType)],
    removed: boolean
}

get(map, key) -> {status: :not_found | :found, value: ValueType}
find_value(map, value) -> {status: :not_found | :found, key: KeyType}
```

Bulk input is a uniform list of inline records:

```text
List[{key: KeyType, value: ValueType}, SpaceType]
```

## 5. Key identity and replacement

Insertion of an absent key class creates one binding:

```text
inserted = true
replaced = false
```

Insertion of a comparator-equal key replaces only the value:

```text
inserted = false
replaced = true
```

The previously stored key representation remains canonical. `compare_value` is not used to suppress equal-value replacement because doing so could add an unexpected comparator call and because value equality need not imply representational identity.

## 6. Query semantics

`get` performs direct WBT search in `O(log n)`.

`contains_key` is logically `get(...).status == :found`, but a generated implementation need not synthesize an unused payload.

`find_value` traverses keys in ascending order and returns the first comparator-equal value. Invalid value-comparator results fail deterministically.

`fold` visits every `(key,value)` pair in ascending key order.

## 7. Delete semantics

Deletion is by key comparator class. It returns the old map unchanged if absent. Deleting a present binding removes key and value together.

No operation deletes by value. `find_value` returning a key may be followed by ordinary key deletion.

## 8. Bulk construction

`from_list` folds insert:

- later comparator-equal keys replace earlier values;
- the first key representation remains canonical;
- output ordering is independent of input order.

`from_sorted` requires keys to be strictly ascending and unique. It rejects duplicate classes rather than choosing a value.

## 9. Empty/failure behavior

| Case | Result |
|---|---|
| get empty/absent | `status=:not_found` |
| find value empty/absent | `status=:not_found` |
| delete absent | unchanged, `removed=false` |
| replacement | size unchanged |
| invalid key/value comparator atom | collection error |
| malformed sorted input | bulk result `valid=false` |
| count overflow | no new map published |

Payload fields accompanying `status=:not_found` are semantically inaccessible.

## 10. Invariants

1. WBT key ordering and balance are valid;
2. each key class has exactly one value;
3. cached size equals binding count;
4. key and value comparator bundles are preserved;
5. values remain paired with their keys through every rotation;
6. fold is strictly ascending by key;
7. `find_value` returns the least matching key.

## 11. Persistence

New-key insertion, replacement, and present deletion path-copy `O(log n)` nodes. Absent deletion returns the original root. Replacing a value shares both subtrees of the matched node.

## 12. Complexity

| Operation | Time | New nodes |
|---|---:|---:|
| get/contains key | `O(log n)` | `0` |
| insert/replace/delete | `O(log n)` | `O(log n)` on change |
| size | `O(1)` | `0` |
| find value | `O(n)` | `0` |
| fold | `O(n)` | accumulator-defined |
| from list | `O(n log u)` | persistent build |
| from sorted | `O(n)` | `O(n)` |
| validate | `O(n)` | diagnostics |

## 13. Example

```silica
m0: OrderedMap[string, int64, mem(normal)] <- wbt_map@empty({
    compare_key: compare_string,
    compare_value: compare_int64
});

r1 <- wbt_map@insert(m0, "answer", 41);
r2 <- wbt_map@insert(r1.map, "answer", 42);
q <- OrderedMap@get(r2.map, "answer");
```

`r1.inserted = true`; `r2.replaced = true`; `q` is found with value `42`; `r1.map` still maps the key to `41`.

## 14. Exclusions

No hash-map lookup, duplicate-key multimap, value index, mutable update, or comparator-free key mode is included.
