# Common Contract for Standard Data Structures

**Implementation status (2026-10-16):** Implemented; the checker enforces the constructor-record, bracket-type, comparator-atom and lookup-status rules (`trials/ordered_data_structures/compiler_substrate/` and `trials/error_enforcement_addition/standard_data_structures/`). Known deviations: only `mem(normal)` is used by the landed modules; the specification's constructor record for BinaryTree is `{ compare_item }` (decision 2026-10-16), not `{}`; trait methods that return an `ItemType` take a placeholder argument. See `../standard_data_structures_baseline/requirements_to_trials_ledger.md` for coverage per section.

**Applies to:** every design in this directory
**Nature:** semantic and Silica-encoding rules, not an implementation plan

## 1. Public type model

Public collection types use bracket parameters:

```text
OrderedSet[ItemType, mem(SpaceType)]
OrderedMap[KeyType, ValueType, mem(SpaceType)]
SearchTree[ItemType, mem(SpaceType)]
DirectedGraph[NodeIdType, EdgePayloadType, mem(SpaceType)]
UndirectedGraph[NodeIdType, EdgeDataType, mem(SpaceType)]
WeightedGraph[NodeIdType, EdgeDataType, WeightType, mem(SpaceType)]
Heap[ItemType, mem(SpaceType)]
PriorityQueue[PriorityType, ItemType, mem(SpaceType)]
Tree[ItemType, mem(SpaceType)]
BinaryTree[ItemType, mem(SpaceType)]
```

### Overriding genericity rule

This rule is normative and overrides every concrete type shown in an example, sketch, trial suggestion, internal layout, or older design statement:

> `ItemType`, `KeyType`, `ValueType`, `PriorityType`, `NodeIdType`, `EdgePayloadType`, `EdgeDataType`, `WeightType`, and `AccType` may each be any valid Silica value type that is legal in the declared memory and ownership context. `SpaceType` may be any valid Silica memory-space type. The programmer determines every one of these types through explicit collection, binding, return, argument, callback, constructor-record, and constructor-value declarations.

An implementation—including one produced by an AI—must infer these placeholders from programmer declarations and must preserve the inferred concrete types through parsing, type checking, specialization, storage, operations, trait dispatch, and code generation. It must never:

- hard-code a placeholder to a scalar type used by an example;
- infer a payload type from an internal count, slot, offset, rank, or buffer index;
- restrict a placeholder because one representation uses a concrete structural type internally; or
- silently choose a default type when the programmer's declarations are missing or contradictory.

Missing or contradictory declaration evidence is a compile-time error, not permission to select a concrete type.

| Placeholder | May resolve to | Determined from programmer declarations |
|---|---|---|
| `ItemType` | any valid Silica value type | `OrderedSet`, `SearchTree`, `Heap`, `PriorityQueue`, `Tree`, or `BinaryTree` type plus comparator/callback signatures where required and explicit constructor items |
| `KeyType` | any valid Silica value type | `OrderedMap` type plus key comparator and operation signatures |
| `ValueType` | any valid Silica value type | `OrderedMap` type plus value comparator and operation signatures |
| `PriorityType` | any valid Silica value type | `PriorityQueue` type plus priority comparator or extractor signatures |
| `NodeIdType` | any valid Silica value type | graph type plus node comparator, endpoint, and traversal signatures |
| `EdgePayloadType` | any valid Silica value type | directed-graph type plus edge comparator and target-extractor signatures |
| `EdgeDataType` | any valid Silica value type | attributed/weighted graph type plus edge-data comparator and operation signatures |
| `WeightType` | any valid Silica value type | weighted-graph type plus weight extractor, comparator, and algorithm-record signatures |
| `AccType` | any valid Silica value type | fold initial-value declaration and callback parameter/return declarations |
| `SpaceType` | any valid Silica memory-space type | the programmer's explicit `mem(SpaceType)` collection and list declarations |

After constructor resolution and monomorphization, generated records contain the concrete inline Silica types selected by those declarations.

The memory argument is part of the public type. Values with different spaces are not structurally interchangeable even when hosted platforms map both spaces to ordinary virtual memory.

Graph vertex identity is represented by the public `NodeIdType` parameter, which may be any valid Silica type accepted by the captured node comparator. CSR and dense representations use `int64` only for dense slots, offsets, and cell indexes. Public vertex IDs and internal dense slots remain different semantic domains: an implementation must translate through its node-to-slot index and must never treat a public ID as a slot.

## 2. No custom surface types

Silica has no user-defined aliases, structs, or enums. A document may name `WbtNode`, `TreePath`, or `HeapEntry` only as expository shorthand. Emitted signatures repeat their inline tuple, record, tagged-tuple, list, buffer, or sum shape.

Generated collection families are compiler-known bracket types whose resolved runtime representation is an inline record. Their names do not authorize arbitrary user-defined named types.

CSR and dense inline records have compiler-version-private structural layouts. The compiler, generated modules, and standard library for one build share their exact layout, but source programs may not rely on field order or field presence. The layout is not a stable FFI, serialization, or cross-version ABI. WBT, CSR, and dense values remain distinct concrete generated types and acquire common graph behavior only through static trait implementations.

## 3. Constructor resolution

Every public constructor receives one inline function record, which carries at least the function that witnesses `ItemType` (`BinaryTree` uses `{ compare_item }`, a witness its core never calls; an empty record `{}` gives no witness, E2017). Resolution uses:

1. the expected collection type at the binding or return position; and
2. all function-field parameter and return types, when fields are present; and
3. explicit non-record value arguments such as a root item, when the detailed design names them as type witnesses.

Resolution must produce exactly one tuple of payload types and one memory space. Missing context, contradictory witnesses, missing fields, extra fields forbidden by the constructor contract, wrong arity, or wrong return type are compile-time errors.

Example:

```silica
names: OrderedSet[string, mem(normal)] <- wbt_set@empty({
    compare_item: compare_string
});
```

The comparator is stored in the value's ordering bundle unless the generated specialization can prove that a direct symbol is equivalent. Either encoding has the same observable behavior.

## 4. Comparator law

Every compare function in a constructor record or exported trait dispatch (`compare_item`, `compare_key`, `compare_node`, `compare_edge`, `compare_priority`, …) has return type:

```text
(:less | :equal | :greater)
```

A comparator `compare(a, b)` returns one of those three atoms and no other:

It must define a total preorder suitable for key identity:

- reflexive equality: `compare(a, a) = :equal`;
- sign symmetry;
- transitivity of `:less` and `:greater`;
- transitivity of `:equal`;
- substitutability: values equal under the comparator take the same search branch relative to every third value.

Collections cannot efficiently prove these laws. They validate the result atom at every call. A different atom causes `:invalid_comparator_result`. Violation of the relational laws is programmer error; `validate` may expose a resulting order violation but cannot diagnose every inconsistent comparator.

For set and map keys, comparator equality is collection identity even when Silica's built-in `==` would distinguish the values.

## 5. Ordering identity and cross-value operations

Each constructor for an ordered structure resolves an opaque ordering-identity token from the exact function values in the complete bundle that affects ordering or extraction, plus representation orientation where applicable. An unordered structure whose exact constructor record is `{}` carries no ordering token.

- A direct top-level function symbol has one canonical function-value identity throughout the program.
- A closure's identity includes the exact captured-environment instance. Separately created closures are distinct even when they contain equal captured values and execute equivalent code.
- Two bundles are compatible only when every corresponding function value and orientation component has identical identity.
- Function type equality and observationally equivalent behavior do not establish ordering identity.

Persistent updates preserve the token exactly.

Operations combining two independently constructed ordered values—principally heap `meld`—require matching tokens. Matching function types alone is insufficient. A mismatch returns `compatible = false` and leaves both inputs unchanged.

No ordering token is exposed as a public scalar, no programmer-supplied identity may override exact function-value identity, and no behavior may depend on the token's numeric representation.

## 6. Result conventions

Query results use the atom-valued status field:

```text
{ status: :not_found | :found, value: ItemType }
```

No named option/result type is introduced. The `value` field is semantically inaccessible when `status = :not_found`; generated code may use a compiler-internal zero value only to satisfy the fixed structural record shape.

Persistent updates return the new collection and, where specified, status flags:

```text
{ set: SetType, inserted: boolean }
{ map: MapType, inserted: boolean, replaced: boolean }
{ heap: HeapType, status: :not_found | :found, value: ItemType }
```

Flags describe logical change, not allocation. A no-op may return the identical root.

## 7. Region and persistence model

Each non-empty recursive representation is rooted in a collection arena:

```text
{
    r: region(R, SpaceType),
    root: ref?(R, SpaceType, RecursiveNodeShape),
    ...
}
```

Logical update rules:

- read-only operations allocate nothing except an explicitly documented materialized result such as `neighbors`;
- update descends through old references, allocates replacement nodes on changed paths, and reuses untouched references;
- no old node is modified;
- no result contains a reference into a shorter-lived region;
- comparator and extractor functions and ordering identity, where present in the detailed design, are copied into the new outer record;
- failure before publication leaves the old value unchanged.

The arena supplies one region identity for recursive references in that concrete generated value family. Every standard constructor is required to resolve the canonical arena for its generated representation specialization and memory space. All constructor calls for that specialization and space use the same application-lifetime arena; standard constructors do not create isolated arenas. This makes independently constructed compatible heaps eligible for constant-time meld and makes persistent references uniform.

The allocation effect appears on the `sequence proc[mem(SpaceType)]` that performs construction or update. The canonical arena has application lifetime, so a completed persistent value may be carried out of that sequence.

Structural sharing means physical-node count is not logical size. `size`, `len`, `node_count`, and `edge_count` count logical contents only.

## 8. Recursive structural encoding

Recursive nodes use the approved recursive-tuple model:

```text
ref?(R, SpaceType, (..., rec, ...))
```

`:none` is the empty child/base case. `alloc_rec` creates a new recursive tuple. Records may wrap recursive references, but recursive self-reference is expressed through tuple positions.

All concrete node shapes must be repeated inline at actual Silica boundaries. Documents use field names to explain positional meanings; generated code may lower them to tuples after type checking.

## 9. Integer safety

Logical counts, ranks, weights, offsets, capacities, and dense indexes are `int64` and obey:

- values are non-negative;
- `size(left) + size(right) + 1`, `V * V`, prefix sums, and rank-derived weights are checked for overflow;
- negative public indices are rejected;
- an operation that would overflow returns a deterministic failure and publishes no partial value;
- validation rejects negative or arithmetically inconsistent metadata.

## 10. Trait/representation separation

Traits contain behavior on existing values. Generated modules contain constructors and representation-specific updates.

Required trait methods are the minimal hooks a representation must supply. Provided methods may call only trait methods and ordinary public functions; they may not inspect generated records.

Representation modules may export `validate/1` for diagnostic use. `validate` is not a substitute for encapsulation and is not required by algorithms consuming the trait.

## 11. Materialization policy

Where the parent trait uses `List[T, SpaceType]`, the operation returns a fresh list in deterministic order:

- WBT set/map: ascending comparator order;
- graph neighbors: ascending target-node order;
- tree traversal: documented preorder or child-slot order.

Materialization costs `O(k)` time and space for `k` returned elements. Representation designs should additionally expose internal fold hooks so provided algorithms can avoid a temporary list, but such hooks do not change the public list-returning contract.

## 12. Validation result

All representation validators use:

```text
{
    valid: boolean,
    error: atom,
    logical_count: int64
}
```

`error = :ok` iff `valid = true`. Other error atoms identify the first deterministic preorder violation, such as:

```text
:negative_count
:size_mismatch
:order_violation
:balance_violation
:rank_violation
:heap_order_violation
:edge_count_mismatch
:undirected_asymmetry
:csr_offset_violation
:dense_cell_mismatch
:invalid_comparator_result
```

Validation is read-only and `O(n)` in representation size unless a specific design states otherwise.
