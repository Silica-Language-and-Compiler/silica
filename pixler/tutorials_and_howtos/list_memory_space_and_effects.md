# Lists, memory spaces, and `mem` effects

This tutorial ties together three surface forms that share **one vocabulary** for memory space `S`:

1. **`sequence proc[mem(S)]`** — declares which memory effect applies to the block.
2. **`alloc_region(S)`** and region-typed values (`region(L1, S)`, `ref(L1, S, T)`, `buf(...)`) — the direct region API (see [memory_region_types.md](memory_region_types.md)). Atomic-capable cells use **`ref(L1, atomic, T)`**, not a separate type name.
3. **`List[T, S]`** — immutable lists whose spine chunks live in a region allocated in space `S` (see [list_implementation_design.md](../design_documents/list_implementation_design.md)).

The self-hosted compiler aims for **inference-free alignment**: `S` is written in types and effects, not reconstructed only from control flow.

---

## Why `S` appears in `List[T, S]`

A list value carries region authority for its spine (the bundle model). Cacheability and allocator policy depend on which memory space that region uses (for example atomic versus normal cacheable). Putting `S` on the list type means:

- **Moves and returns** preserve `S` without a runtime tag for space.
- **Callers** can see whether code that touches list storage must use `mem(S)` matching the list they pass in.

---

## Rule of thumb (effect checker)

In any `sequence proc[mem(S)]` block where you allocate, grow, or pattern-match a list, every `List[T, S]` involved must use the **same** `S` as in `mem(S)`. Do not declare `mem(normal)` and then operate on `List[T, atomic]` unless the language defines a sound widening rule (by default, distinct spaces are not interchangeable).

Trials under `trials/memory_region_addition/` include a short header comment stating that the same `S` names apply to `List[T, S]` as to region types.

---

## Canonical shapes

### Region only

```silica
sequence proc[mem(normal)]
    L1: lifetime <- fresh_lifetime();
    r: region(L1, normal) <- alloc_region(normal);
    cell: ref(L1, normal, int64) <- alloc_ref(r, 42);
produces
    pure 0
end
```

### List literals and `empty` (explicit `S`)

```silica
sequence proc[mem(normal)]
    xs: List[int64, normal] <- [1, 2, 3]: List[int64, normal];
    ys: List[int64, normal] <- empty[int64, normal]();
    n: int64 <- length[int64, normal](xs);
produces
    pure n
end
```

Until the compiler accepts `List[T, S]` everywhere, some trials under `trials/list_addition/` may still use `List[T]` as a shorthand; the design target is the explicit `S` form above (see list implementation design §8).

### Pass a list to a function and get a list back

Argument and return types carry `List[T, S]`; the callee body uses `sequence proc[mem(S)]` for `prepend`, `case`, and other list operations.

```silica
fn add_zero_front(xs: List[int64, normal]) -> List[int64, normal] {
    sequence proc[mem(normal)]
        ys: List[int64, normal] <- prepend[int64, normal](0, xs);
    produces
        pure ys
    end
}

fn main() -> int64 {
    sequence proc[mem(normal)]
        xs: List[int64, normal] <- [1, 2, 3]: List[int64, normal];
        ys: List[int64, normal] <- add_zero_front(xs);
        n: int64 <- length[int64, normal](ys);
    produces
        pure n
    end
}
```

---

## Where to read next

- [list_implementation_design.md](../design_documents/list_implementation_design.md) — chunks, bundle, §9.8 effect alignment.
- [memory_region_types.md](memory_region_types.md) — all named spaces and when to use them.
- `trials/memory_region_addition/` — region allocation and buffers (headers cross-reference `List[T, S]`).
- `trials/list_addition/` — executable list examples.
