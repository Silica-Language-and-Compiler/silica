# Brodal–Okasaki Purely Functional Queue Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/brodal_okasaki.silica` with split units (`brodal_okasaki_node`, `_compare`, `_link`, `_forest`, `_extract`, `_boot`, `_validate`, `_dispatch_core`, `_dispatch_bulk`); trials in `trials/ordered_data_structures/brodal_okasaki_core/` (13 programs). The `Heap` and `PriorityQueue` traits sit on it through `brodal_okasaki_min`, `brodal_okasaki_max` and `brodal_okasaki_priority`.

**Consumers:** `Heap`, `PriorityQueue`  
**Algorithm:** bootstrapped skew-binomial queue [BO96]

## 1. Algorithm identity

The selected Brodal–Okasaki structure is the paper's purely functional bootstrapped skew-binomial queue:

1. skew-binomial trees bound insertion to one skew link;
2. a distinguished root stores the global minimum;
3. data-structural bootstrapping stores non-empty queues inside a primitive queue and reduces meld to insertion.

This is not an imperative violation-list Brodal queue and does not use mutable parent/sibling pointers.

## 2. Abstract ordering

The core is a min-oriented comparison queue over `EntryType`. The comparator defines a total order under the common comparator contract.

A max heap uses the same structure with an orientation adapter that reverses `:less` and `:greater`; it does not negate numeric values and therefore works for arbitrary item types.

Duplicates are retained. Comparator equality does not deduplicate entries.

## 3. Skew-binomial tree

A primitive tree has:

```text
(
    entry: EntryType,
    rank: int64,
    children_and_deferred: List[TreeReference, SpaceType]
)
```

A rank-0 tree is a singleton. A simple link combines equal-rank trees by making the larger root a child of the smaller and increasing rank by one.

A skew link combines a new rank-0 tree and two equal-rank trees. The smallest of the three roots becomes the new root; the other two become children in the shape defined by [BO96].

Tree height equals rank. Rank-derived minimum/maximum sizes are checked for `int64` overflow.

## 4. Primitive forest invariant

Trees are in increasing rank order, except the first two may have equal rank. No other duplicate rank exists.

This corresponds to skew-binary digits and is what limits insert to:

- one skew link when the first two ranks match; or
- one rank-0 prepend otherwise.

Primitive meld first removes the optional initial duplicate rank from each forest, merges unique-rank forests with ordinary links, and restores the primitive invariant. Primitive meld is `O(log n)`; bootstrapping hides it from top-level meld.

## 5. Bootstrapped representation

Mathematically:

```text
BootQueue[Entry] =
    Empty
  | Root(
        minimum: Entry,
        queue_of_nonempty_boot_queues: PrimitiveSkewQueue[BootQueue[Entry]]
    )
```

Nested boot queues are compared only by their `minimum`.

The physical representation is the flattened optimized recursive node from [BO96]. Primitive children and the deferred nested forest are combined into one Silica `List`:

```text
(
    minimum: EntryType,
    rank: int64,
    children_and_deferred: List[TreeReference, SpaceType]
)
```

The boundary between ranked children and the deferred nested forest is derived from rank and the child-order invariant. No alternate unflattened or recursive-spine representation is permitted.

## 6. Empty, peek, and length

The outer collection record stores:

- optional boot root;
- exact logical `len`;
- comparator/orientation bundle;
- ordering identity;
- region.

`peek` reads the distinguished root in `O(1)`. Empty returns `{status: :not_found}`.

The recursive boot representation does not derive logical length cheaply, so updates maintain the outer count with checked arithmetic.

## 7. Insert

Insertion forms a singleton boot queue and melds it with the input:

```text
insert(x, q) = meld(Root(x, primitive_empty), q)
```

Because top-level meld performs at most one primitive insertion, insert is `O(1)` worst-case.

The result length is `q.len + 1`.

## 8. Meld

Empty is the identity.

For roots `(x, qx)` and `(y, qy)`:

- if `x <= y`, keep `x` and insert the entire non-empty `y` queue into `qx`;
- otherwise keep `y` and insert the entire non-empty `x` queue into `qy`.

The losing queue is nested, not flattened. This is `O(1)` worst-case because primitive skew insertion is `O(1)`.

Meld requires:

- identical concrete entry type and memory space;
- identical min/max orientation;
- matching ordering identity.

Public generated `meld` returns:

```text
{ heap: HeapType, compatible: boolean }
```

On incompatibility it returns the left input and `compatible = false`. Length addition is checked before allocation.

## 9. Delete minimum

For `Root(x, q)`:

- if primitive `q` is empty, result is empty;
- otherwise obtain the nested boot queue with smallest root, `(y, q1)`;
- delete that nested queue from primitive `q`, yielding `q2`;
- new root is `y`;
- new deferred primitive queue is primitive `meld(q1, q2)`.

Primitive find-min, delete-min, and meld are `O(log n)`, so top-level pop is `O(log n)` worst-case.

The public pop returns removed root `x` and decrements length.

## 10. Primitive delete-min normalization

Deleting a minimum skew-binomial tree:

1. separates rank-0 children from positive-rank children;
2. treats positive-rank children as a valid skew forest in their defined rank order;
3. melds that forest with remaining roots;
4. reinserts each rank-0 child.

The operation must preserve child ordering conventions from [BO96]. It may not treat the children as an arbitrary list.

## 11. Persistence and strictness

Every link allocates a new parent and shares existing trees. Forest-spine prefixes changed by normalization are copied; untouched tree references are shared.

Bootstrapped and skew operations are represented directly under Silica's strict evaluation. The representation contains no deferred computation or lazy thunk. The word “deferred” in `children_and_deferred` describes nested queue structure, not delayed execution.

## 12. Invariants

1. empty iff root is absent and length is zero;
2. non-empty length is positive;
3. distinguished root is no greater than every logical entry;
4. every skew tree is heap ordered;
5. rank is non-negative and child ranks/shapes are valid;
6. primitive forests have only the allowed initial duplicate rank;
7. every nested queue is non-empty;
8. nested queues are ordered by their distinguished roots;
9. flattened children/deferred boundaries can be reconstructed unambiguously;
10. canonical arena, comparator, orientation, and ordering identity are uniform;
11. recursive references are acyclic within one root;
12. logical node count equals outer `len`.

## 13. Validation

Validation recursively checks tree ranks, heap order, primitive forest ranks, nested non-emptiness, global root minimality, canonical arena identity, and logical count.

It must avoid counting a shared persistent node twice only when validating multiple roots together. Within one root, duplicate reachability is invalid.

## 14. Complexity

| Operation | Worst-case time | New structure |
|---|---:|---:|
| empty/is_empty/len | `O(1)` | `0` |
| peek | `O(1)` | `0` |
| push | `O(1)` | `O(1)` |
| meld | `O(1)` | `O(1)` |
| pop/delete-min | `O(log n)` | `O(log n)` |
| validate | `O(n)` | diagnostics only |

These are comparison-model bounds. Comparator execution cost is multiplied by the number of comparisons.

## 15. Out of scope

- arbitrary item deletion by value;
- handles into heap nodes;
- in-place decrease-key;
- stable insertion-order tie breaking unless a public sequence number is added to entry comparison;
- d-ary or binary array heaps;
- a second simpler heap behind the same module name.
