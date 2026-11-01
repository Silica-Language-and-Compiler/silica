# Skew Binary Random-Access List Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/skew_ral.silica` with split units (`skew_ral_weights`, `_node`, `_tree_read`, `_tree_write`, `_forest`, `_index`, `_traverse`, `_build`, `_validate`, `_dispatch_access`, `_dispatch_bulk`); trials in `trials/ordered_data_structures/skew_ral_core/` (11 programs).

**Constructor record:** `skew_ral@empty_ral({ compare_item: fn(ItemType, ItemType) -> (:less | :equal | :greater) }, reversed: boolean)` (named `empty_ral` because an unqualified `empty` resolves to the list builtin, E2020). `compare_item` is the `ItemType` witness and is carried in the list value; the list core never calls it and it is not an ordering identity. The Tree family passes its own comparator.

**Consumers:** dense matrix graph, rose-tree child sequence  
**Algorithm:** Okasaki skew binary random-access list [Oka95, Oka98 §6.4.1]

## 1. Abstract sequence

The structure represents an immutable zero-based sequence. It combines:

- `O(1)` worst-case prepend, head, and tail;
- `O(min(i, log n))` lookup and persistent update at index `i`;
- deterministic left-to-right fold in `O(n)`.

It is not a general persistent vector. In particular, arbitrary insertion, physical removal, and concatenation are not promised logarithmic operations.

## 2. Skew weights and digits

Digit rank `k` has weight:

```text
weight(k) = 2^(k + 1) - 1
```

A sequence is a list of complete binary trees in increasing weight order. Every weight occurs zero or one time, except the smallest present weight may occur twice. This is the sparse skew-binary digit invariant.

The sum of listed weights equals sequence length.

## 3. Tree representation

Logical tree:

```text
Leaf(value)
Node(value, left, right)
```

A tree of weight `w > 1` has:

```text
child_weight = w / 2
w = 1 + child_weight + child_weight
```

Elements are ordered in preorder: node value, left subtree, right subtree. Only each forest root stores its weight; child weights are derived.

Silica encoding uses tagged recursive tuples, conceptually:

```text
(:leaf, ItemType)
| (:node, ItemType, ref(R, SpaceType, rec), ref(R, SpaceType, rec))
```

The forest spine is a Silica:

```text
List[{weight: int64, tree: TreeReference}, SpaceType]
```

The list is immutable, stored in the canonical arena for the specialization and memory space, and structurally shared by persistent versions. No alternate recursive-tuple spine is permitted.

## 4. Prepend

Given new value `x`:

- if the first two forest trees have equal weight `w`, replace them with one tree of weight `1 + 2w` whose root is `x` and whose children are those two trees;
- otherwise prepend a weight-1 leaf.

At most one link occurs, which gives `O(1)` worst-case time and allocation.

## 5. Head and tail

`head` returns the first tree's root value.

`tail`:

- removes a weight-1 leaf; or
- removes a node of weight `w` and prepends its two child trees, each of weight `w/2`.

Empty head/tail returns `status = :not_found`; it does not trap.

## 6. Lookup

Forest lookup subtracts whole-tree weights until the target lies in one tree.

Within a tree:

- index `0` addresses the root;
- for `i > 0`, decrement for the root;
- if the remainder is less than `w/2`, recurse left;
- otherwise subtract `w/2` and recurse right.

Negative or `i >= length` returns `status = :not_found`.

## 7. Persistent update

Update follows lookup's route and allocates one replacement tree node per level. The other child and all other forest trees are shared.

Result:

```text
{ list: RandomAccessListType, updated: boolean }
```

An invalid index returns the original list and `updated = false`.

## 8. Append convention for consumers

The primitive is front-oriented. Consumers that need stable append indexes store their logical sequence in reverse physical order:

```text
physical_index = length - 1 - logical_index
```

Prepending a new physical item assigns it logical index equal to the old length. Existing logical indexes continue to address the same values because both length and their physical position increase by one.

This convention is used by rose-tree child slots. Dense graphs do not append cells after construction.

## 9. Bulk construction

`from_list` defines whether the supplied list is logical-order or physical-order input. The standard helper accepts logical order and builds a reverse-physical sequence without changing observable order.

Building by repeated prepend from right to left is `O(n)` total because each prepend is worst-case `O(1)`.

For a fixed-length repeated value, `filled(n, value)` has the same bound. Negative length and weight/rank overflow fail before publication.

## 10. Fold and range traversal

`fold_logical` visits values in logical index order independent of physical orientation. `fold_range(start, count, ...)` validates the range and visits exactly that slice.

Dense graph row scans require an internal cursor/range traversal whose total time is `O(log n + count)`, not `count` independent `O(log n)` lookups.

## 11. Invariants

1. length is non-negative and equals the forest weight sum;
2. every forest weight is positive and of form `2^(k+1)-1`;
3. weights increase strictly after an optional equal first pair;
4. only the first two entries may have equal weight;
5. each tree is complete for its declared weight;
6. node children both have weight `w/2`;
7. all references belong to the owning region;
8. tree and forest reference graphs are acyclic;
9. orientation metadata agrees with the consumer's logical-index rule.

## 12. Validation

Validation checks forest weights, allowed duplicate digit, exact tree shapes, length sum, region membership, and overflow. It counts tree nodes without interpreting payloads.

Time is `O(n)`; stack depth is `O(log n)` for valid input.

## 13. Complexity

| Operation | Time | Allocation |
|---|---:|---:|
| prepend | `O(1)` worst | `O(1)` |
| head/tail | `O(1)` worst | `O(1)` |
| lookup/update | `O(min(i, log n))` | update `O(log n)` |
| build/fill | `O(n)` | `O(n)` |
| full fold | `O(n)` | none excluding accumulator |
| range fold | `O(log n + k)` | cursor-dependent |
| validate | `O(n)` | diagnostic-dependent |

## 14. Explicit exclusions

- No claim that physical `remove_at` is `O(log n)`.
- No general `O(log n)` append without the reverse-orientation convention.
- No mutable array update.
- No persistent-vector/RRB alternative.
