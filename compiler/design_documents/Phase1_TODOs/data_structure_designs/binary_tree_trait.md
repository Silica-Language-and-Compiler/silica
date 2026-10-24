# `BinaryTree` Detailed Design

**Implementation status (2026-10-16):** Implemented as `stdlib/data_structures/BinaryTree.silica` over `tree_binary.silica`; trials in `trials/ordered_data_structures/binary_tree_core/` (13 programs). The constructor record is `{ compare_item }` (decision 2026-10-16: the specification follows the implementation; a bare `ItemType` is witnessed only by a `compare_*` field, and the core never calls the function). Deviations from the placeholder-free draft: `root_item`, `get`, `left_item` and `right_item` take a placeholder item, so they are arity 2 and 3 rather than 1 and 2; paths are built with `tree_binary@path_root/path_left/path_right` (atoms are numbered per unit); `mem(normal)` only. The `BinaryTree[ItemType, mem(normal)]` bracket type is accepted. Not landed: the constructor-record compile-fail trials (`trial_compile_fail_binary_tree_*`, `StubBinaryTree`) and the randomized-oracle and complexity trials (`standard_data_structures_implementation_plan.md` §7.10, §17, §20).

**Public trait:** `BinaryTree`  
**Generated module:** `tree_binary`  
**Representation:** persistent fixed-arity binary tree with optional left/right recursive references  
**Generic placeholders:** `ItemType`, `AccType`, and `SpaceType` follow the [overriding genericity rule](common_contract.md#overriding-genericity-rule).

## 1. Abstract value

`BinaryTree[ItemType, mem(SpaceType)]` is a possibly empty rooted binary tree.

Every occupied node contains:

- one `ItemType` value;
- one optional left subtree;
- one optional right subtree; and
- one cached logical subtree count.

Left and right are distinct structural roles. This type is not item-ordered, is not balanced, and does not infer child placement from an item comparator.

`BinaryTree` is distinct from:

- `Tree`, whose `tree_rose` representation has arbitrary stable child slots;
- `SearchTree`, whose `wbt_set` representation orders unique comparator classes;
- WBT set/map cores; and
- graph or heap families.

## 2. Public type and constructor record

The public type is:

```text
BinaryTree[ItemType, mem(SpaceType)]
```

The constructor function record is:

```text
{ compare_item: fn(ItemType, ItemType) -> :less | :equal | :greater }
```

(Decision 2026-10-16: the specification matches the implementation. An earlier draft of this design made the record the exact empty record `{}`.)

It is still an inline constructor record. The expected result type and explicit item arguments provide the `SpaceType` witness and the item values. The `compare_item` field is the `ItemType` witness: the compiler resolves a bare `ItemType` at a qualified call only from a `compare_item` (or `compare_priority`) function field of the first argument, and an empty record `{}` gives no witness (E2017). The function is stored in the tree record, so every tree value, every node-producing result and every update carries it forward, and the checker can resolve `ItemType` for every later call from the tree. The tree core never calls it: `compare_item` is not an ordering identity, no ordering bundle is materialized, no operation reorders or compares items, and a BinaryTree remains unordered (left and right are fixed roles). The record captures no extractor or orientation.

Examples:

```silica
empty_tree: BinaryTree[string, mem(normal)] <- tree_binary@empty({ compare_item: compare_strings });

rooted: BinaryTree[string, mem(normal)] <- tree_binary@with_root({ compare_item: compare_strings }, "root");
```

where `compare_strings` is any `fn(string, string) -> :less | :equal | :greater`.

Missing type context for `empty({ compare_item: ... })` is a compile-time error; the compiler must not choose a default item type or space.

## 3. No custom surface types

Documents use `BinaryNode`, `BinaryPath`, `BinaryFrame`, and `BinaryZipper` only as expository shorthand.

Generated Silica repeats:

- the full recursive node tuple;
- `List[:left | :right, SpaceType]` paths;
- full tagged breadcrumb tuples;
- inline query/update records; and
- the private owning record fields.

There is no user-defined alias, struct, enum, option, result, path, node, frame, or zipper type.

`BinaryTree[...]` is a compiler-known standard collection family whose generated runtime representation is compiler-version-private and structural, under the same rule as the other standard bracket families.

## 4. Logical representation

The logical node is:

```text
(
    item: ItemType,
    subtree_node_count: int64,
    left: ref?(R, SpaceType, rec),
    right: ref?(R, SpaceType, rec)
)
```

The owning value carries:

```text
{
    r: region(R, SpaceType),
    root: ref?(R, SpaceType, RecursiveBinaryNode),   // spelled as the full inline node tuple; a bare rec here is E2010
    specialization_key: int64
}
```

Both shapes are expository. Actual generated signatures expand the recursive tuple inline.

The owning record intentionally has no comparator or ordering bundle.

## 5. Path model

The path argument is structurally:

```text
List[:left | :right, SpaceType]
```

The empty list addresses the root.

At each occupied node:

- `:left` selects the left child;
- `:right` selects the right child;
- selecting `:none` makes the path missing.

Paths are structural and value-relative. Updating an item at a path preserves every path because shape is unchanged. Replacing or clearing a subtree may invalidate that path and its descendants but does not reinterpret any path outside the replaced route.

## 6. Trait contract

```text
export trait BinaryTree;

export node_count/1;
export is_empty/1;
export root_item/1;
export get/2;
export left_item/2;
export right_item/2;
export fold_preorder/3;
export fold_inorder/3;
export fold_postorder/3;

required {
    fn node_count(tree: BinaryTree) -> int64;
    fn root_item(tree: BinaryTree)
        -> {status: :not_found | :found, value: ItemType};
    fn get(
        tree: BinaryTree,
        path: List[:left | :right, SpaceType]
    ) -> {status: :not_found | :found, value: ItemType};
    fn left_item(
        tree: BinaryTree,
        path: List[:left | :right, SpaceType]
    ) -> {status: :not_found | :found, value: ItemType};
    fn right_item(
        tree: BinaryTree,
        path: List[:left | :right, SpaceType]
    ) -> {status: :not_found | :found, value: ItemType};
    fn fold_preorder(
        tree: BinaryTree,
        init: AccType,
        step: fn(AccType, List[:left | :right, SpaceType], ItemType) -> AccType
    ) -> AccType;
    fn fold_inorder(
        tree: BinaryTree,
        init: AccType,
        step: fn(AccType, List[:left | :right, SpaceType], ItemType) -> AccType
    ) -> AccType;
    fn fold_postorder(
        tree: BinaryTree,
        init: AccType,
        step: fn(AccType, List[:left | :right, SpaceType], ItemType) -> AccType
    ) -> AccType;
}

provided {
    fn is_empty(tree: BinaryTree) -> boolean;
}
```

`is_empty` is exactly `node_count(tree) == 0`.

Fold paths are immutable snapshots. The generated implementation may use a reverse path cursor internally and materialize only the path passed to the callback.

## 7. Generated module surface

```text
export empty/1;
export with_root/2;
export node/4;
export replace_item/3;
export replace_left/3;
export replace_right/3;
export clear_left/2;
export clear_right/2;
export get/2;
export left_item/2;
export right_item/2;
export map_preorder/2;
export map_postorder/2;
export fold_preorder/3;
export fold_inorder/3;
export fold_postorder/3;
export zipper_open/1;
export zipper_down_left/1;
export zipper_down_right/1;
export zipper_replace_item/2;
export zipper_replace_subtree/2;
export zipper_up/1;
export zipper_close/1;
export validate/1;
```

Expository signatures:

```text
fn empty(functions: { compare_item: fn(ItemType, ItemType) -> :less | :equal | :greater }) -> BinaryTree[ItemType, mem(SpaceType)] {}

fn with_root(
    functions: { compare_item: fn(ItemType, ItemType) -> :less | :equal | :greater },
    root_item: ItemType
) -> BinaryTree[ItemType, mem(SpaceType)] {}

fn node(
    functions: { compare_item: fn(ItemType, ItemType) -> :less | :equal | :greater },
    item: ItemType,
    left: BinaryTree[ItemType, mem(SpaceType)],
    right: BinaryTree[ItemType, mem(SpaceType)]
) -> {
    tree: BinaryTree[ItemType, mem(SpaceType)],
    compatible: boolean
} {}

fn replace_item(
    tree: BinaryTree[ItemType, mem(SpaceType)],
    path: List[:left | :right, SpaceType],
    item: ItemType
) -> {
    tree: BinaryTree[ItemType, mem(SpaceType)],
    changed: boolean
} {}

fn replace_left(
    tree: BinaryTree[ItemType, mem(SpaceType)],
    parent_path: List[:left | :right, SpaceType],
    subtree: BinaryTree[ItemType, mem(SpaceType)]
) -> {
    tree: BinaryTree[ItemType, mem(SpaceType)],
    changed: boolean,
    compatible: boolean
} {}

fn replace_right(
    tree: BinaryTree[ItemType, mem(SpaceType)],
    parent_path: List[:left | :right, SpaceType],
    subtree: BinaryTree[ItemType, mem(SpaceType)]
) -> {
    tree: BinaryTree[ItemType, mem(SpaceType)],
    changed: boolean,
    compatible: boolean
} {}

fn clear_left(
    tree: BinaryTree[ItemType, mem(SpaceType)],
    parent_path: List[:left | :right, SpaceType]
) -> {
    tree: BinaryTree[ItemType, mem(SpaceType)],
    changed: boolean
} {}

fn clear_right(
    tree: BinaryTree[ItemType, mem(SpaceType)],
    parent_path: List[:left | :right, SpaceType]
) -> {
    tree: BinaryTree[ItemType, mem(SpaceType)],
    changed: boolean
} {}

fn get(
    tree: BinaryTree[ItemType, mem(SpaceType)],
    path: List[:left | :right, SpaceType]
) -> {status: :not_found | :found, value: ItemType} {}

fn map_preorder(
    tree: BinaryTree[ItemType, mem(SpaceType)],
    step: fn(ItemType) -> ItemType
) -> BinaryTree[ItemType, mem(SpaceType)] {}

fn map_postorder(
    tree: BinaryTree[ItemType, mem(SpaceType)],
    step: fn(ItemType) -> ItemType
) -> BinaryTree[ItemType, mem(SpaceType)] {}
```

`clear_left` and `clear_right` are exact convenience forms of replacement with the empty subtree of the same specialization.

Zipper signatures repeat the complete inline zipper record described by [`persistent_binary_tree.md`](persistent_binary_tree.md); `BinaryZipper` is not introduced as a type name.

## 8. Empty, root, and direct-child behavior

`empty({ compare_item })`:

- resolves the canonical arena for the expected specialization;
- stores `root=:none`;
- reports count zero; and
- allocates no binary-tree node.

`with_root({ compare_item }, item)` creates one leaf with count one.

`root_item` on empty returns `status=:not_found`.

`left_item(tree, path)` and `right_item(tree, path)`:

1. resolve the parent node at `path`;
2. select the fixed child role;
3. return `:not_found` if the parent or selected child is absent; and
4. otherwise return the child item.

No query allocates a binary-tree node.

## 9. Node construction and subtree compatibility

`node({ compare_item }, item, left, right)` creates a one-node root whose children are the supplied whole trees.

It checks both child values before allocating:

- item specialization;
- memory space;
- representation specialization; and
- canonical arena identity.

On incompatibility it returns `compatible=false` and does not publish a new root. The returned tree field is the canonical empty value for the expected specialization.

On success it derives the root count with checked arithmetic and shares both child roots.

No ordering compatibility exists because no comparator is captured.

## 10. Item replacement

`replace_item` follows the path and path-copies the selected route.

On success:

- target children are preserved;
- every unselected ancestor child is shared;
- shape and counts remain unchanged;
- `changed=true`; and
- the old tree remains valid.

The operation does not compare old and new items. Arbitrary `ItemType` has no required equality operation.

On a missing path it returns the exact old tree with `changed=false`.

## 11. Child replacement and clearing

`replace_left` and `replace_right`:

- first resolve and validate subtree compatibility;
- fail before allocation when incompatible;
- find the parent path;
- replace exactly one fixed child;
- recompute counts at the parent and each copied ancestor; and
- preserve the opposite child by reference.

A valid empty subtree clears the selected child.

`clear_left` and `clear_right`:

- do not change the opposite child;
- return `changed=false` when the parent path is missing;
- may return `changed=false` when the selected child is already empty and reference identity permits the check; and
- otherwise publish the path-copied result.

No operation promotes a grandchild, shifts the right child into the left position, or renumbers a path.

## 12. Traversal and mapping

Fold order is exactly:

- preorder: node, left, right;
- inorder: left, node, right;
- postorder: left, right, node.

Each fold callback runs once per logical occurrence.

`map_preorder` invokes the item callback in preorder and preserves shape.

`map_postorder` invokes the item callback after visiting both children and preserves shape. It is the preferred generic transformation primitive when a child-independent item rewrite needs bottom-up visitation.

Neither map operation permits a callback to install arbitrary child references. Structural rewrites use explicit subtree replacement or the zipper so compatibility and counts remain controlled by the representation module.

## 13. Functional zipper behavior

The zipper is an immutable focused view over one tree version.

Opening:

- empty tree returns `status=:not_found`;
- non-empty tree focuses the root with an empty breadcrumb list.

Downward movement:

- pushes the parent item, direction, and untouched sibling;
- moves focus to the selected occupied child;
- allocates no binary-tree node; and
- returns `:not_found` without changing the zipper when the selected child is empty.

Focused replacement:

- item replacement changes only the focused item;
- subtree replacement checks compatibility before accepting a foreign root;
- neither operation mutates the original root or breadcrumbs.

Moving up rebuilds one parent through the checked smart constructor. Closing rebuilds all remaining breadcrumbs and returns a complete `BinaryTree`.

Zipper paths and frames are not stable serialized identities and are not exposed as named types.

## 14. Result and failure conventions

| Case | Result |
|---|---|
| root/get on empty | `status=:not_found` |
| missing path | query not found; update unchanged |
| missing selected child | `status=:not_found` |
| replace item at found path | `changed=true` |
| clear already-empty child | unchanged permitted |
| incompatible subtree | unchanged, `compatible=false` |
| count overflow | no new tree published |
| zipper down into empty child | unchanged zipper, `status=:not_found` |

All result records are inline. No named option or result type is introduced.

## 15. Invariants and validation

In addition to the core invariants:

1. empty value has `root=:none` and public count zero;
2. every occupied node count is exact and positive;
3. all references belong to the owning canonical arena;
4. the reachable physical graph is acyclic;
5. repeated physical subtree sharing is legal and counted per logical occurrence;
6. left/right roles are preserved;
7. specialization key matches the generated family, item type, and memory space; and
8. there is no comparator or ordering bundle field.

`validate` returns:

```text
{
    valid: boolean,
    error: atom,
    logical_count: int64
}
```

It validates active-path acyclicity rather than rejecting all repeated references.

## 16. Persistence and memory effects

Construction and update execute under `mem(SpaceType)`.

- read-only queries and folds allocate no binary-tree node;
- item or child replacement allocates only the target path;
- maps allocate at most one result node per logical occurrence;
- zipper descent allocates breadcrumb storage only;
- zipper reconstruction allocates one node per rebuilt ancestor;
- old roots and zipper source roots remain valid; and
- untouched subtrees are shared.

The canonical arena has application lifetime. Individual `BinaryTree` versions do not reclaim it.

## 17. Complexity

Let `h` be target depth and `n` logical node occurrences.

| Operation | Time | New binary-tree nodes |
|---|---:|---:|
| empty / node count | `O(1)` | `0` |
| root item | `O(1)` | `0` |
| get / child query | `O(h)` | `0` |
| replace item | `O(h)` | `O(h)` |
| replace/clear child | `O(h)` | `O(h)` |
| fold | `O(n)` | `0` |
| shape-preserving map | `O(n)` | `O(n)` |
| zipper down | `O(1)` | `0` |
| zipper up | `O(1)` | at most `1` |
| validate | `O(n)` | diagnostics-dependent |

## 18. Example

```silica
empty_s: BinaryTree[string, mem(normal)] <- tree_binary@empty({ compare_item: compare_strings });

left: BinaryTree[string, mem(normal)] <- tree_binary@with_root({ compare_item: compare_strings }, "left");
right: BinaryTree[string, mem(normal)] <- tree_binary@with_root({ compare_item: compare_strings }, "right");

made: {
    tree: BinaryTree[string, mem(normal)],
    compatible: boolean
} <- tree_binary@node({ compare_item: compare_strings }, "root", left, right);

left_item: {
    status: :not_found | :found,
    value: string
} <- BinaryTree@left_item(
    made.tree,
    []: List[:left | :right, normal]
);
```

The result is a three-node tree. `left` and `right` remain independently usable.

## 19. Exclusions

`BinaryTree` does not provide:

- arbitrary-arity children;
- rose-tree stable slots or tombstones;
- item ordering, lookup by comparator, or balancing;
- implicit equality-based no-op detection;
- mutable nodes or parent pointers;
- child promotion on clear;
- hash-consing;
- cycle construction;
- a public named zipper type; or
- compiler-AST-specific node-kind or arity validation.

The compiler's own syntax tree is not a consumer of `BinaryTree`: that migration was withdrawn on 2026-09-29.
