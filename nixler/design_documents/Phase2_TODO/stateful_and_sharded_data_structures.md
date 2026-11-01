# Stateful And Sharded Data Structures

Date: 2026-06-03

**Implementation status (2026-10-16):** not started. No actor-wrapped or sharded collection exists in `compiler/stdlib/data_structures` or elsewhere (searched for an ordered-set actor wrapper and `hash_key`). The Phase 1 collections it builds on are landed (`OrderedSet`/`OrderedMap` over `wbt_set`/`wbt_map`, `Heap`, `PriorityQueue`, `Tree`, `BinaryTree`, `SearchTree`, the graph traits, and the skew-binary random-access list). The `fn(...) -> atom` comparator spelling in the sketches below is shorthand: the real comparator type is `fn(T, T) -> :less | :equal | :greater` (`wbt_set.silica`). Cross-shard transactions and restart handling depend on `link`/`monitor`, which are still runtime stubs (see [actor_monitor_demonitor_todo.md](actor_monitor_demonitor_todo.md)). The Phase 1 reference `data_structures_implementation_command.md` is not in the tree; see [../Phase1_TODOs/standard_data_structures_implementation_plan.md](../Phase1_TODOs/standard_data_structures_implementation_plan.md).

This Phase 2 note describes two extensions to the Phase 1 trait-oriented
standard data-structure design:

1. Actor-wrapped data structures.
2. Sharded actor-backed data structures.

Both extensions build on the same core generated structures, traits, and typed
constructor function records described in
`Phase1_TODOs/data_structures_as_traits.md`. They are not replacements for plain
value data structures.

## Phase 1 Dependency

Phase 1 standard data structures are ordinary typed values with **generic payloads**
(resolved from declared collection types and constructor function records — see
[standard_data_structures_implementation_plan.md](../Phase1_TODOs/standard_data_structures_implementation_plan.md)):

```text
names: OrderedSet[string, mem(normal)] <- wbt_set@empty({
    compare_item: compare_string
});

users: OrderedMap[string, User, mem(normal)] <- wbt_map@empty({
    compare_key: compare_string,
    compare_value: compare_user
});

g: DirectedGraph[NodeIdType, Edge, mem(normal)] <- graph_wbt_directed@empty({
    compare_node: compare_node_id,
    compare_edge: compare_edge,
    edge_target: edge_target
});
```

The constructor function fields determine and check the relevant collection type
parameters at compile time. Comparators return:

```text
:less
:equal
:greater
```

Phase 2 wrappers should reuse these same captured functions. A stateful or
sharded collection actor should hold ordinary Phase 1 collection values
internally. The memory effect remains part of those values' types.

## Extension 1: Actor-Wrapped Data Structures

Actor-wrapped collections provide a stateful process around a plain collection.
They are useful when multiple actors need serialized access to one logical data
structure.

For an ordered set wrapper, the actor owns:

```text
{
    set: OrderedSet[string, mem(normal)],
    compare_item: fn(string, string) -> atom
}
```

The comparison function is supplied at spawn time and must agree with the
declared collection type in the same way Phase 1 constructors require.

### Example Shape

```text
state: {
    set: OrderedSet[string, mem(normal)],
    compare_item: fn(string, string) -> atom
}
```

Message shape:

```text
{
    tag: atom,
    item: string
}
```

The generated behavior can use `tag` values such as `:contains`, `:insert`,
`:delete`, and `:size`. Messages that do not need `item` can ignore that field
or use a separately generated behavior with a different inline message shape.

Behavior sketch:

```text
fn ordered_set_actor_beh(
    msg: {
        tag: atom,
        item: string
    },
    state: {
        set: OrderedSet[string, mem(normal)],
        compare_item: fn(string, string) -> atom
    }
) -> (
    :reply,
    { tag: atom, found: boolean, size: int64 },
    {
        set: OrderedSet[string, mem(normal)],
        compare_item: fn(string, string) -> atom
    }
) {
    ...
}
```

The actor message type follows the existing actor rule: it is determined from
the message parameter of the behavior function passed to `spawn`.

### Constructor Sketch

```text
names_ref: actor_ref <- ordered_set_actor@spawn(
    names,
    {
        compare_item: compare_string
    }
);
```

The exact generated helper syntax is open. The key rule is that type knowledge
remains visible on the wrapped collection value, and captured functions are
passed as an inline record whose fields are named by what they do. The actor
wrapper should not hide the underlying collection type.

### Semantics

- Mutating messages update the actor state.
- Query messages return replies through `call`.
- Cast-only variants may be useful for fire-and-forget inserts or deletes.
- The actor serializes access by processing one message turn at a time.
- The internal collection remains an ordinary Phase 1 value.

### Costs

Actor wrapping adds:

- mailbox overhead,
- message allocation/copying,
- scheduling latency,
- actor lifecycle and supervision concerns.

Therefore actor-wrapped collections should be optional. Local algorithms should
continue to use plain values.

### Open Questions

1. Should actor wrappers be generated for every standard collection family, or
   only for maps, sets, heaps, and graphs?
2. Should wrappers expose both `call` and `cast` message variants?
3. How should reply types be named and generated?
4. Should wrappers support supervisor-friendly restart from initial captured
   functions and a seed collection?
5. Should actor-wrapped structures expose a `snapshot` message that returns the
   current plain collection value?

## Extension 2: Sharded Actor-Backed Data Structures

Sharded collections distribute storage across multiple actor-owned shards. They
are useful when concurrent access matters more than single-actor simplicity.

Each shard owns an ordinary Phase 1 collection. For example, a string-keyed user
map shard owns:

```text
{
    shard_id: int64,
    map: OrderedMap[string, User, mem(normal)],
    compare_key: fn(string, string) -> atom,
    compare_value: fn(User, User) -> atom,
    hash_key: fn(string) -> int64
}
```

A coordinator actor or generated facade routes requests to shards.

## Shard Function Requirements

Sharding requires the ordinary collection function record plus a shard-selection
function. These functions should be direct fields named by what they do.

For sets:

```text
{
    compare_item: fn(ItemType, ItemType) -> atom,
    hash_item: fn(ItemType) -> int64
}
```

For maps:

```text
{
    compare_key: fn(KeyType, KeyType) -> atom,
    compare_value: fn(ValueType, ValueType) -> atom,
    hash_key: fn(KeyType) -> int64
}
```

For graphs:

```text
{
    compare_node: fn(NodeIdType, NodeIdType) -> atom,
    compare_edge: fn(EdgePayloadType, EdgePayloadType) -> atom,
    edge_target: fn(EdgePayloadType) -> NodeIdType,
    hash_node: fn(NodeIdType) -> int64
}
```

The hash function determines shard placement. The comparator remains the
semantic equality/ordering authority inside each shard.

## Sharded Set And Map Shape

For sets and maps, sharding by item or key is straightforward:

```text
shard_index <- abs(hash_key(key)) % shard_count;
```

Requests for one key route to one shard:

- `contains`
- `get`
- `insert`
- `delete`

Requests that need the whole collection fan out across shards:

- `size`
- `find_value`
- iteration or fold operations

`find_value` for maps remains unordered and may be slow. In a sharded map, it
requires querying all shards unless a value-indexed representation exists.

## Sharded Graph Shape

Graph sharding is more complex because edges may connect nodes in different
shards.

The default policy should shard by source node:

```text
source_shard <- abs(hash_node(from_id)) % shard_count;
```

This makes outgoing-neighbor queries local to one shard:

- `neighbors(g, from_id)`
- `out_degree(g, from_id)`
- `add_edge(g, from_id, edge)`

Queries that require incoming edges or global reachability must coordinate
across shards.

Open graph sharding policies:

- source-node sharding,
- target-node sharding,
- edge sharding,
- replicated boundary metadata,
- partition functions supplied by the user.

## Actor Topology

A generated sharded collection may use:

- one coordinator actor plus `N` shard actors,
- direct client-to-shard routing when the facade can compute the shard locally,
- a supervisor-owned shard group for restart and lifecycle management.

Coordinator actor responsibilities may include:

- startup,
- shard registration,
- request routing,
- fan-out/fan-in queries,
- resharding in future versions,
- supervision integration.

## Consistency Model

Initial Phase 2 sharded collections should choose simple semantics:

- per-key operations are linearized by the owning shard actor,
- multi-shard operations are eventually consistent unless performed through a
  coordinator barrier,
- no automatic transaction support across shards.

Cross-shard transactions, snapshots, and resharding should remain future work
until actor monitor/link semantics and region ownership rules are mature.

## Benefits

- Reuses the Phase 1 typed collection implementation.
- Keeps local data structures cheap.
- Provides an optional stateful API for shared mutable collections.
- Provides a scalable API for high-concurrency maps, sets, and graph workloads.
- Keeps function-record-based type checking consistent across plain,
  actor-wrapped, and sharded variants.

## Costs And Risks

- Actor overhead can dominate small operations.
- Sharded APIs require careful reply and fan-out design.
- Graph sharding has many policy choices and should not be overpromised early.
- Multi-shard consistency semantics must be explicit.
- Supervision and restart behavior can become complex if shard state is not
  reconstructible.

## Suggested Phase 2 Experiments

1. Generate an ordered-set actor wrapper around a Phase 1 ordered set.
2. Verify message-type checking from the actor behavior function.
3. Add `contains`, `insert`, `delete`, `size`, and `snapshot` messages.
4. Generate a sharded ordered-map wrapper with a fixed shard count and
   `hash_key`.
5. Verify single-key requests route to one shard.
6. Verify `find_value` and `size` fan out across shards.
7. Add a source-node-sharded `DirectedGraph` trial only after set/map sharding
   is stable.
