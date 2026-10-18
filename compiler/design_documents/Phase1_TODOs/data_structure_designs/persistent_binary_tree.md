# Persistent Fixed-Arity Binary Tree Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/tree_binary.silica`; trials in `trials/ordered_data_structures/binary_tree_core/` (13 programs). See `binary_tree_trait.md` for the deviations; the randomized-oracle and complexity-counter trials were not landed.

**Consumer:** `BinaryTree`  
**Algorithm family:** purely functional binary tree with path copying; optional Huet-style zipper for focused traversal and reconstruction  
**Purpose:** general fixed-role binary structure, including syntax-tree and expression-tree workloads

## 1. Purpose and boundary

This file defines the one persistent fixed-arity binary-tree core used by the standard `BinaryTree` family. It is not the existing `Tree` rose-tree representation and does not replace it.

Every logical node has:

- one item;
- one optional left child;
- one optional right child; and
- one exact cached logical subtree count.

The left and right positions have stable semantic roles. Removing or replacing one child does not shift, renumber, or reinterpret the other child.

This core does not provide:

- ordering by item;
- key search;
- balancing or rotations;
- arbitrary-arity child slots;
- rose-tree tombstones;
- parent pointers;
- mutable cursors; or
- item equality inferred by the implementation.

## 2. Mathematical model

An empty binary tree has no root and logical node count `0`.

A node is:

```text
node(item, left, right)
```

with:

```text
count(:none) = 0
count(node(item, left, right))
    = 1 + count(left) + count(right)
```

The tree is ordered structurally, not by item comparison. Left and right are distinguishable even when their contents are observationally equal.

No comparator participates in construction, navigation, replacement, traversal, validation, or compatibility.

## 3. Logical Silica node shape

In field notation:

```text
(
    item: ItemType,
    subtree_node_count: int64,
    left: ref?(R, SpaceType, rec),
    right: ref?(R, SpaceType, rec)
)
```

This notation is expository. Silica has no user-defined node alias. Every actual boundary repeats the complete inline recursive tuple:

```text
ref?(R, SpaceType, (
    ItemType,
    int64,
    ref?(R, SpaceType, rec),
    ref?(R, SpaceType, rec)
))
```

`:none` is the only empty-tree and empty-child representation. `alloc_rec` is the only production allocation path for a node.

## 4. Owning value and specialization state

The generated owning value contains, conceptually:

```text
{
    r: region(R, SpaceType),
    root: ref?(R, SpaceType, RecursiveBinaryNode),
    compare_item: fn(ItemType, ItemType) -> :less | :equal | :greater,
    specialization_key: int64
}
```

`RecursiveBinaryNode` above is expository only and is expanded inline in generated Silica.

The owning value carries:

- the canonical application-lifetime arena for the exact generated representation specialization;
- the optional root;
- the stable specialization key required by the collection registry;
- the witness-only `compare_item` function from the constructor record (decision 2026-10-16), which the tree never calls and which is not an ordering identity (see `binary_tree_trait.md` §2); and
- no ordering bundle, orientation, or user-forgeable identity token.

Different `ItemType` or `SpaceType` specializations are distinct generated representations. Repeated construction of one specialization and space resolves the same canonical arena.

## 5. Smart construction and checked counts

All production nodes are created through one smart-node constructor:

1. read `left_count`, using zero for `:none`;
2. read `right_count`, using zero for `:none`;
3. check `left_count + right_count`;
4. check the final `+ 1`;
5. allocate only after both checks succeed; and
6. store the derived count.

No caller supplies `subtree_node_count`.

Leaf, unary, binary, subtree replacement, mapping, zipper reconstruction, and any internal builder all use this constructor. Count overflow fails before allocating or publishing a result root.

## 6. Constant-time root and child queries

Given a root or node reference:

- node count reads the cached root count, or zero for `:none`;
- root item reads one node;
- left and right queries read the selected optional child directly;
- selecting one child is `O(1)` and allocates no binary-tree node.

Queries distinguish:

- an empty whole tree;
- an occupied node with an empty selected child; and
- a missing path component encountered before the requested target.

Status uses only `:not_found | :found`. Payload fields accompanying `:not_found` are semantically inaccessible.

## 7. Path model

An expository binary-tree path is:

```text
List[:left | :right, SpaceType]
```

The empty path addresses the root. Each component chooses exactly one fixed child position.

Path lookup:

1. begins at the root;
2. returns `:not_found` immediately when the root is `:none`;
3. consumes one `:left` or `:right` component at a time;
4. follows the selected child;
5. returns `:not_found` when that child is `:none`; and
6. succeeds after consuming the complete path.

No integer slot, negative-index rule, compaction rule, or child renumbering exists. A path valid in an old version continues to address the same structural route in a descendant version unless that route is cleared or replaced.

## 8. Persistent item and child replacement

Item replacement at a valid path:

- allocates a replacement target node with the new item and both old children;
- copies every ancestor on the root-to-target path;
- preserves the unselected child at each ancestor by reference;
- preserves the exact shape and logical count; and
- leaves the old root unchanged.

Because arbitrary `ItemType` has no required equality function, finding the target is sufficient to report `changed = true`; the implementation does not call an undeclared equality operation to suppress an observationally equal replacement.

Left or right subtree replacement:

- resolves the target parent path;
- places the replacement subtree in exactly the selected child position;
- preserves the opposite child;
- recomputes counts on the copied path;
- accepts an empty replacement to clear the child; and
- never turns a right child into a left child or vice versa.

A missing target path is a semantic no-op and returns the original root.

## 9. Subtree grafting and compatibility

An operation that makes one result reference both an existing tree and an independently constructed subtree checks compatibility before allocating the result path.

Compatibility requires:

- identical `ItemType`;
- identical `SpaceType`;
- identical generated representation specialization; and
- the same canonical arena identity.

The first three are normally established statically. Canonical arena identity is checked at runtime where a generic or malformed internal value could bypass ordinary construction.

There is no comparator identity to check.

Standard constructors for the same `BinaryTree` specialization and space resolve the same canonical arena, so their subtrees are normally compatible.

## 10. Traversal and mapping

Preorder traversal visits:

1. node;
2. left subtree;
3. right subtree.

Inorder traversal visits:

1. left subtree;
2. node;
3. right subtree.

Postorder traversal visits:

1. left subtree;
2. right subtree;
3. node.

Each fold visits every logical node occurrence exactly once and allocates no binary-tree node. Accumulator allocation is defined by the callback.

`map_preorder` and `map_postorder` preserve the exact tree shape while replacing every item with the callback result. Because no item equality operation is required, mapping may allocate one new node per logical occurrence even when a callback returns an observationally equal item.

An internal rewrite primitive may replace complete child subtrees, but it must preserve the same compatibility, count, overflow, and publication rules as explicit subtree replacement.

## 11. Functional zipper

The implementation may expose zipper operations from the generated representation module. The zipper is not a named public collection type and does not add another bracket family.

Conceptually, a zipper contains:

```text
{
    r: region(R, SpaceType),
    focus: ref?(R, SpaceType, RecursiveBinaryNode),
    breadcrumbs: List[
        (:from_left, ItemType, OptionalRightSibling)
        | (:from_right, ItemType, OptionalLeftSibling),
        SpaceType
    ],
    specialization_key: int64
}
```

Every actual signature repeats the full inline node and breadcrumb shapes.

Operations:

- `open` focuses the root;
- `down_left` and `down_right` push one breadcrumb and focus the selected child;
- `replace_focus_item` replaces only the focused item;
- `replace_focus_subtree` replaces the complete focus;
- `up` rebuilds one parent through the smart constructor;
- `close` repeatedly moves up and returns the rebuilt whole tree.

Navigation never mutates the original tree. Downward movement allocates only zipper breadcrumbs. Moving up allocates at most one rebuilt binary-tree node per breadcrumb. Closing an unchanged zipper may return the original root when reference identity is retained by the implementation.

An attempt to descend into `:none` reports `:not_found` and preserves the zipper.

## 12. Structural sharing

Path updates allocate `O(h)` nodes for a target at depth `h`. Every untouched subtree is shared.

Sharing is permitted:

- between old and new persistent versions;
- between independently retained roots in the canonical arena; and
- at multiple logical positions within one root.

If the same physical subtree is referenced from both left and right positions, traversal visits it twice and cached counts include it twice. Logical node count measures occurrences, not distinct physical allocations.

Cycles are forbidden. Production operations cannot create a back-reference to a newly allocated ancestor because nodes are immutable and construction receives only already-existing child references.

## 13. Failure behavior

| Case | Result |
|---|---|
| root query on empty tree | `status=:not_found` |
| lookup through empty child | `status=:not_found` |
| replace at missing path | unchanged, `changed=false` |
| descend zipper into empty child | unchanged zipper, `status=:not_found` |
| incompatible subtree graft | unchanged, `compatible=false` |
| count overflow | no new tree published |
| malformed wrong-arena child | validation failure |
| malformed cycle | validation failure; validation terminates |

Failure before result publication leaves all input values valid and observable.

## 14. Invariants

A valid value satisfies:

1. root is `:none` exactly when logical node count is zero;
2. every node reference belongs to the owning canonical arena;
3. every cached count is positive;
4. every cached count equals `1 + left_count + right_count`;
5. the root cached count equals the public logical node count;
6. left and right roles are never interchanged by an operation;
7. the reachable reference graph is acyclic;
8. repeated subtree references are interpreted as repeated logical occurrences;
9. all arithmetic used to derive counts is checked; and
10. every production node was created through the smart constructor.

## 15. Validation

Validation performs a depth-first postorder walk and returns:

```text
{
    valid: boolean,
    error: atom,
    logical_count: int64
}
```

For every logical occurrence it checks:

- child arena identity;
- active-path cycle detection;
- cached count;
- checked count arithmetic; and
- root count agreement.

A global “already visited” set must not reject legal repeated subtree sharing. Cycle detection tracks the active ancestor path. An implementation may separately memoize a validated physical subtree, but memoization must preserve logical multiplicity when computing counts.

Validation is `O(n)` in logical node occurrences. Stack depth is `O(h)` for height `h`. A malformed cyclic graph may require an auxiliary reference-identity set.

## 16. Complexity

Let `h` be target depth and `n` the number of logical node occurrences.

| Operation | Time | New binary-tree nodes |
|---|---:|---:|
| empty / root count | `O(1)` | `0` |
| root / left / right query | `O(1)` | `0` |
| path lookup | `O(h)` | `0` |
| replace item | `O(h)` | `O(h)` |
| replace left/right subtree | `O(h)` | `O(h)` |
| fold | `O(n)` | `0` |
| shape-preserving map | `O(n)` | `O(n)` |
| zipper down | `O(1)` | `0` tree nodes |
| zipper up | `O(1)` | at most `1` |
| zipper close after depth `h` | `O(h)` | `O(h)` |
| validate | `O(n)` | diagnostics-dependent |

## 17. Exclusions and reference

The Phase 1 core does not include:

- balancing;
- comparator search;
- parent pointers stored in nodes;
- mutable zipper focus;
- arbitrary child vectors;
- rose-tree stable slots;
- deletion that promotes or shifts another node;
- automatic subtree hash-consing;
- cycle-tolerant graph semantics; or
- a named node, path, frame, zipper, option, or result type.

The zipper follows the purely functional focused-tree technique described by:

- **[Hue97]** Gérard Huet, *The Zipper*, Journal of Functional Programming 7(5), 549–554, 1997. DOI: `10.1017/S0956796897002864`.
