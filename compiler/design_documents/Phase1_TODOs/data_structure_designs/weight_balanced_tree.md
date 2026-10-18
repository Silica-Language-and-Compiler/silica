# Corrected Adams-Family Weight-Balanced Tree Design

**Implementation status (2026-10-16):** Implemented in `stdlib/data_structures/wbt_set.silica` and `wbt_map.silica`; trials in `trials/ordered_data_structures/wbt_core/` (81 programs). §13 join/split is deferred and not exported.

**Consumers:** `OrderedSet`, `OrderedMap`, `SearchTree`, graph indexes and adjacency  
**Algorithm family:** Adams WBT [Ada93], with deletion-safe parameters from [HY11]

## 1. Purpose and boundary

This file defines the one ordered-tree core used by every standard ordered collection. It is not itself a public trait. Set and map modules specialize the payload fields and expose their own APIs.

There is no integer-key specialization, Patricia trie, B-tree, packed CSR tree, AVL tree, red-black tree, or alternate WBT parameterization.

## 2. Mathematical model

An empty tree has size `0`. A node contains:

- one key;
- for maps, one value;
- cached subtree size;
- optional left and right child references.

For any node:

```text
size(node) = 1 + size(left) + size(right)
weight(tree) = size(tree) + 1
```

The binary-search invariant is strict under the captured key comparator:

```text
every key in left  < node.key
every key in right > node.key
```

Comparator-equal keys therefore cannot occupy two nodes.

## 3. Balance definition

The design uses the original WBT weight definition (`size + 1`) with:

```text
DELTA = 3
GAMMA = 2
```

A node is balanced exactly when both directional inequalities hold:

```text
weight(left)  <= DELTA * weight(right)
weight(right) <= DELTA * weight(left)
```

`(3, 2)` is the unique integer parameter pair in the valid range proved for original WBT insertion and deletion [HY11]. The `ratio = 5` example in Adams's short 1993 presentation is not this design's parameter contract.

Multiplications in balance checks use overflow-safe comparison, conceptually `a <= DELTA*b` without permitting `DELTA*b` to wrap.

## 4. Logical Silica node shapes

Set node, in field notation:

```text
(
    key: ItemType,
    size: int64,
    left: ref?(R, SpaceType, rec),
    right: ref?(R, SpaceType, rec)
)
```

Map node:

```text
(
    key: KeyType,
    value: ValueType,
    size: int64,
    left: ref?(R, SpaceType, rec),
    right: ref?(R, SpaceType, rec)
)
```

The owning collection record carries `region`, optional `root`, comparator bundle, and ordering identity. These are expository layouts; emitted Silica repeats the inline recursive tuple.

## 5. Smart construction

No operation directly chooses cached size. A node-construction primitive:

1. reads child sizes (`0` for `:none`);
2. checks `left_size + right_size + 1`;
3. allocates a node with the computed size;
4. never mutates either child.

All rotations and path-copying updates use this primitive. This makes cached-size correctness local.

## 6. Search

Starting at the root:

- `:less`: follow left;
- `:greater`: follow right;
- `:equal`: return the node;
- any other atom: fail with `:invalid_comparator_result`.

Successful and unsuccessful search visit `O(height)` nodes and allocate nothing.

## 7. Rebalancing contract

`balance_left(key/value, left, right)` is used when the right side may have become too heavy. `balance_right` is its mirror.

For a right-heavy node:

1. let `rl` and `rr` be the right child's children;
2. choose a single left rotation when `weight(rl) < GAMMA * weight(rr)`;
3. otherwise choose a double left rotation;
4. rebuild all affected nodes with the smart constructor.

The mirror uses `weight(lr) < GAMMA * weight(ll)` for a single right rotation.

The strict `<` is part of the design. Equality selects the double rotation. Rotation preconditions require the heavy child, and for a double rotation its inner child, to be non-empty; a missing required child is a representation violation rather than a fallback case.

## 8. Set insertion

Insertion descends by comparison.

- At `:none`, allocate a singleton and return `inserted = true`.
- On `:equal`, return the old node and `inserted = false`.
- On a recursive branch, insert into that child.
- If the child reports no insertion, return the old node unchanged.
- Otherwise rebuild and rebalance on the unwind path.

Only the search path and at most a constant number of rotation nodes per level are allocated. Untouched subtrees are shared.

## 9. Map insertion and replacement

Map insertion follows the same descent.

- Empty position: insert `(key, value)`, `inserted = true`, `replaced = false`.
- Equal key and observationally unchanged value are not assumed detectable.
- Equal key: allocate a node with the stored canonical key and new value, preserve both children and size, `inserted = false`, `replaced = true`.
- Unequal key: recurse and rebalance as for a set.

The existing key is retained on replacement so comparator-equal but representationally distinct keys cannot silently change iteration output.

## 10. Deletion

Deletion returns `{root, removed}`.

- Empty position: unchanged, `removed = false`.
- Unequal key: recurse into the selected child. If absent, return the old node unchanged. If removed, rebuild with the deletion-side balancing constructor.
- Equal key with one empty child: return the other child.
- Equal key with two children: remove an extreme binding from the heavier side:
  - if `size(left) > size(right)`, extract the maximum from `left`;
  - otherwise extract the minimum from `right`;
  - install that binding at the root and rebalance the side from which it was removed.

`delete_min` and `delete_max` return both the binding and the residual tree. They rebalance every copied ancestor. The tie rule above is deterministic and shared by set and map.

## 11. Ordered traversal

`fold_ascending(tree, init, step)` performs left-node-right traversal. It is semantically iterative even if expressed recursively: generated code must not require machine-stack depth larger than `O(log n)` for a valid tree.

Set step:

```text
fn(AccType, ItemType) -> AccType
```

Map step:

```text
fn(AccType, KeyType, ValueType) -> AccType
```

Early-exit internal folds may use a tagged accumulator but must preserve ascending order.

## 12. Linear construction from sorted input

`from_sorted` accepts exactly `n` items in strictly ascending comparator order.

The tree shape is defined by recursively choosing:

```text
left_count = n / 2
root = item[left_count]
right_count = n - left_count - 1
```

This yields a deterministic near-complete tree and computes sizes bottom-up in `O(n)`.

Invalid input—descending pair, comparator-equal adjacent keys, count mismatch, invalid comparator atom, or negative count—returns failure and no collection. It is not silently sorted or deduplicated.

Map input is a sorted sequence of key/value bindings. Values do not participate in ordering.

## 13. Optional join/split primitives

Public set/map APIs do not initially require union or split, but the WBT core may define:

- `join(left, binding, right)` with every left key below the binding and every right key above it;
- `concat(left, right)` with every left key below every right key;
- `split(tree, key)` returning less/equal/greater partitions.

These primitives must use the same `(3,2)` balance definition and ordering identity. They may not be added as a second balancing algorithm.

## 14. Invariants

A valid WBT satisfies:

1. root is `:none` iff logical size is zero;
2. every reference belongs to the collection region;
3. the graph of child references reachable from one root is acyclic;
4. cached size is exact and positive at every node;
5. strict BST ordering holds;
6. both balance inequalities hold at every node;
7. map nodes have exactly one value for every key;
8. all comparator calls return a valid ordering atom;
9. root cached size equals collection logical size.

Sharing between different persistent roots is permitted. Sharing the same node twice within one root's child graph is not, because it would duplicate logical entries and corrupt size semantics.

## 15. Validation

Validation performs one postorder pass and returns, for each subtree, computed size and optional minimum/maximum key. It checks child region, acyclicity where reference identity support exists, cached size, strict bounds, and balance.

It is `O(n)` time and `O(log n)` auxiliary stack for a valid tree. A malformed cyclic graph may require an `O(n)` visited-reference set.

## 16. Complexity

| Operation | Time | New nodes |
|---|---:|---:|
| search/contains/get | `O(log n)` | `0` |
| insert new key | `O(log n)` | `O(log n)` |
| replace map value | `O(log n)` | `O(log n)` |
| duplicate set insert | `O(log n)` | `0` |
| delete present key | `O(log n)` | `O(log n)` |
| delete absent key | `O(log n)` | `0` |
| size | `O(1)` | `0` |
| ascending fold | `O(n)` | `0`, excluding accumulator |
| `from_sorted` | `O(n)` | `O(n)` |
| validate | `O(n)` | implementation-dependent diagnostics |

## 17. References

- [Ada93] Stephen Adams, *Efficient Sets—A Balancing Act*, 1993.
- [HY11] Yoichi Hirai and Kazuhiko Yamamoto, *Balancing Weight-Balanced Trees*, 2011.
- [Driscoll86] Driscoll et al., *Making Data Structures Persistent*, 1986.
