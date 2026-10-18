# `Heap` Detailed Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/Heap.silica` over `brodal_okasaki_min` / `brodal_okasaki_max`; trials: the `heap_*` programs in `trials/ordered_data_structures/heap_collections/`. Deviations (module header): `peek` takes a placeholder item; a `Heap[...]` binding is accepted only for an `@empty` call, other results use the inline record type.

**Public trait:** `Heap`  
**Generated modules:** `brodal_okasaki_min`, `brodal_okasaki_max`  
**Shared core:** [`brodal_okasaki_queue.md`](brodal_okasaki_queue.md)
**Generic placeholders:** `ItemType` and `SpaceType` follow the [overriding genericity rule](common_contract.md#overriding-genericity-rule) and are determined by programmer declarations.

## 1. Abstract value

`Heap[ItemType, mem(SpaceType)]` is an immutable multiset with efficient access to one comparator-extreme item.

Min and max orientation are distinct generated concrete types even though both implement `Heap`. Duplicate comparator-equal items are retained and popped one at a time.

## 2. Constructor

```text
{ compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater) }
```

```silica
frontier: Heap[int64, mem(normal)]
    <- brodal_okasaki_min@empty({
        compare_item: compare_node_id
    });
```

The max module reverses ordering internally. User comparators always describe their natural ascending order.

## 3. Trait contract

```text
export trait Heap;

/// Returns the number of item occurrences in the heap.
export len/1;

/// Reports whether the heap contains no item occurrences.
export is_empty/1;

/// Returns the comparator-extreme item without removing it.
export peek/1;

/// Compares two items with the comparator captured by the heap.
export compare_item/3;

required {
    fn len(heap: Heap) -> int64;
    fn peek(heap: Heap) -> {status: :not_found | :found, value: ItemType};
    fn compare_item(heap: Heap, a: ItemType, b: ItemType) -> (:less | :equal | :greater);
}

provided {
    fn is_empty(heap: Heap) -> boolean;
}

// Empty implementation scaffold.
fn len(heap: Heap) -> int64 {}
fn is_empty(heap: Heap) -> boolean {}
fn peek(heap: Heap) -> {status: :not_found | :found, value: ItemType} {}
fn compare_item(heap: Heap, a: ItemType, b: ItemType) -> (:less | :equal | :greater) {}
```

`is_empty` is exactly `len(heap) == 0`.

## 4. Generated module surface

Both min and max modules export:

```text
/// Creates an empty oriented heap with the supplied item comparator.
export empty/1;

/// Creates an oriented heap containing one occurrence.
export singleton/2;

/// Persistently adds one item occurrence.
export push/2;

/// Returns the comparator-extreme item without removing it.
export peek/1;

/// Persistently removes and returns one comparator-extreme occurrence.
export pop/1;

/// Persistently combines two compatible heaps.
export meld/2;

/// Returns the number of item occurrences.
export len/1;

/// Reports whether the heap contains no occurrences.
export is_empty/1;

/// Builds a heap by pushing every item in a list.
export from_list/2;

/// Checks representation, ordering, rank, count, and arena invariants.
export validate/1;

// Empty implementation scaffold.
fn empty(
    functions: {compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater)}
) -> Heap[ItemType, mem(SpaceType)] {}

fn singleton(
    functions: {compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater)},
    item: ItemType
) -> Heap[ItemType, mem(SpaceType)] {}

fn push(
    heap: Heap[ItemType, mem(SpaceType)],
    item: ItemType
) -> Heap[ItemType, mem(SpaceType)] {}

fn peek(heap: Heap[ItemType, mem(SpaceType)])
    -> {status: :not_found | :found, value: ItemType} {}

fn pop(heap: Heap[ItemType, mem(SpaceType)]) -> {
    heap: Heap[ItemType, mem(SpaceType)],
    status: :not_found | :found,
    value: ItemType
} {}

fn meld(
    left: Heap[ItemType, mem(SpaceType)],
    right: Heap[ItemType, mem(SpaceType)]
) -> {
    heap: Heap[ItemType, mem(SpaceType)],
    compatible: boolean
} {}

fn len(heap: Heap[ItemType, mem(SpaceType)]) -> int64 {}
fn is_empty(heap: Heap[ItemType, mem(SpaceType)]) -> boolean {}

fn from_list(
    functions: {compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater)},
    items: List[ItemType, SpaceType]
) -> Heap[ItemType, mem(SpaceType)] {}

fn validate(heap: Heap[ItemType, mem(SpaceType)]) -> {
    valid: boolean,
    error: atom,
    logical_count: int64
} {}
```

Signatures:

```text
push(heap, item) -> Heap[ItemType, mem(SpaceType)]

pop(heap) -> {
    heap: Heap[ItemType, mem(SpaceType)],
    status: :not_found | :found,
    value: ItemType
}

meld(left, right) -> {
    heap: Heap[ItemType, mem(SpaceType)],
    compatible: boolean
}
```

## 5. Ordering behavior

For min heap, `peek`/`pop` select an item no greater than every other item.

For max heap, they select an item no less than every other item.

When several items compare equal, which representation is selected is unspecified. The heap is not stable by insertion order.

## 6. Operations

### Push

Adds exactly one occurrence, including when comparator-equal items already exist. It checks `len + 1` before allocation.

### Peek

Reads the distinguished root without allocation. Empty returns `status=:not_found`.

### Pop

Empty returns the identical heap and `status=:not_found`. Non-empty returns `status=:found`, the prior extreme value, and a new heap missing exactly that occurrence.

### Meld

Combines all occurrences from both inputs in `O(1)` worst-case via bootstrapping. It succeeds only for matching item type, space, orientation, and exact function-value ordering identity.

Incompatible meld returns the left heap with `compatible=false`; neither input changes.

### From list

Folds `push`. Because push is worst-case `O(1)`, construction is `O(n)`, not `O(n log n)`. The result retains all list elements, including duplicates.

## 7. Persistence and region rule

Push and meld allocate constant new structure and share both input roots. Pop allocates `O(log n)` nodes.

Because meld can make the result reference both operands, standard meld requires both heaps to have the same canonical arena identity in addition to the same memory-space type. Standard constructors for one generated specialization always resolve that canonical arena.

## 8. Empty/failure behavior

| Case | Result |
|---|---|
| peek empty | `status=:not_found` |
| pop empty | unchanged, `status=:not_found` |
| meld empty with compatible heap | other heap |
| meld incompatible ordering/orientation/region | left heap, `compatible=false` |
| invalid comparator atom | collection error |
| length overflow | no result published |

## 9. Invariants

The heap inherits every Brodal–Okasaki invariant and additionally guarantees:

1. public length equals logical occurrence count;
2. orientation is immutable;
3. item comparator, ordering identity, and arena are preserved;
4. min/max trait behavior matches orientation;
5. duplicates are counted independently.

## 10. Complexity

| Operation | Worst-case time | New structure |
|---|---:|---:|
| len/is empty/peek | `O(1)` | none |
| push | `O(1)` | `O(1)` |
| meld | `O(1)` | `O(1)` |
| pop | `O(log n)` | `O(log n)` |
| from list | `O(n)` | `O(n)` |
| validate | `O(n)` | diagnostics |

## 11. Example

```silica
h0: Heap[int64, mem(normal)] <- brodal_okasaki_min@empty({
    compare_item: compare_int64
});
h1: Heap[int64, mem(normal)] <- brodal_okasaki_min@push(h0, 9);
h2: Heap[int64, mem(normal)] <- brodal_okasaki_min@push(h1, 3);
p <- brodal_okasaki_min@pop(h2);
```

`p.value = 3`, `p.heap` contains `9`, and `h2` still contains both occurrences.

## 12. Exclusions

No handles, arbitrary delete, in-place mutation, stable tie order, or separate binary/d-ary heap representation is included.
