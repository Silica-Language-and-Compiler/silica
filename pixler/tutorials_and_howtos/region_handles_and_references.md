# Region Handles and Region References: A Memory Tutorial

This tutorial explains the difference between **region handles** and **region references** in Silica's region-based memory model, and how to use each correctly.

---

## What Is an Arena?

An **arena** is a memory pool from which you allocate individual cells. You request space for a value, and the arena gives you back a reference (pointer) to that allocated cell. All allocations in an arena share the same lifetime: when the arena is freed, all of its allocations are freed together. Silica regions are arenas.

---

## The Key Difference

| Concept | Type | Role |
|---------|------|------|
| **Region handle** | `region(L, Space)` | The memory arena itself. Used to *allocate* new cells into the region. One per region. |
| **Region reference** | `ref(L, Space, T)` | A pointer to a *specific* allocated value within a region. Many per region. |

**In short:**
- A **region handle** is the pool. You use it with `alloc_ref`, `alloc_buf`, and `alloc_rec` to create new allocations.
- A **region reference** is a pointer to data. You use it with `read_ref` and `write_ref` to access or modify that data.

Without the region handle, you cannot allocate. Without region references, you cannot point to or access the data you've allocated.

---

## Region Handles

### What They Are

A region handle has type `region(L, Space)`. It represents the memory region (arena) itself. You obtain one from `alloc_region`:

```silica
sequence proc[mem(normal)]
    L1: lifetime <- fresh_lifetime();
    r: region(L1, normal) <- alloc_region(normal);
produces pure r end
```

### What You Use Them For

- **Allocation**: Pass the region handle to `alloc_ref`, `alloc_buf`, or `alloc_rec` to allocate new cells.
- **Ownership and lifetime**: The region handle controls when the entire region is freed. When it goes out of scope (and is not returned), the region is deallocated.

### Operations That Take a Region Handle

| Operation | Purpose |
|-----------|---------|
| `alloc_ref(region, value)` | Allocate a single cell in the region |
| `alloc_buf(region, size)` | Allocate a buffer (array) in the region |
| `alloc_rec(region, (value, ...))` | Allocate a recursive tuple (e.g., list node) in the region |

### Move Semantics: Handles Are Move-Only

Region handles cannot be copied. When you pass a region handle to any function, ownership transfers (the handle is moved). **The function must return the handle** to the caller. This ensures exactly one handle exists per region at any time.

```silica
fn add_cell(r: region(R, normal), value: int64) -> (region(R, normal), ref(R, normal, int64)) proc[mem(normal)] {
    ref: ref(R, normal, int64) <- alloc_ref(r, value);
    (r, ref)   // Must return the handle
}
```

---

## Region References

### What They Are

A region reference has type `ref(L, Space, T)`. It points to a specific allocated value of type `T` within a region. You obtain one from `alloc_ref` or `alloc_rec`:

```silica
ref1: ref(L1, normal, int64) <- alloc_ref(r, 42);
```

### What You Use Them For

- **Access**: Use `read_ref` and `write_ref` to read or modify the stored value.
- **Linked structures**: Store references in tuples or records to build linked lists, trees, and other recursive data structures. The `next` pointer in a list node is a region reference.

### Operations That Take a Region Reference

| Operation | Purpose |
|-----------|---------|
| `read_ref(reference)` | Read the value at the referenced cell |
| `write_ref(reference, value)` | Write a new value to the referenced cell |

---

## One Region, Many References

A single region can hold many allocations. Each allocation produces a distinct reference:

```silica
sequence proc[mem(normal)]
    L1: lifetime <- fresh_lifetime();
    r: region(L1, normal) <- alloc_region(normal);
    a: ref(L1, normal, int64) <- alloc_ref(r, 1);
    b: ref(L1, normal, int64) <- alloc_ref(r, 2);
    c: ref(L1, normal, int64) <- alloc_ref(r, 3);
produces pure (r, a, b, c) end
```

Here, `r` is the region handle (one). `a`, `b`, and `c` are region references (many), all pointing into the same region.

### Regions Can Hold Different Types

A region is not restricted to a single type. You can allocate values of different types into the same region; each reference carries its own type:

```silica
sequence proc[mem(normal)]
    L1: lifetime <- fresh_lifetime();
    r: region(L1, normal) <- alloc_region(normal);
    a: ref(L1, normal, int64) <- alloc_ref(r, 42);
    b: ref(L1, normal, string) <- alloc_ref(r, "hello");
    c: ref(L1, normal, (int64, boolean)) <- alloc_ref(r, (1, true));
produces pure (r, a, b, c) end
```

Each `alloc_ref` allocates a cell of the appropriate type. The region acts as a heterogeneous arena: `a` points to an `int64`, `b` to a `string`, and `c` to a tuple.

### Storing Region Handles in Regions: List Implementation

A region can hold region handles. This pattern underlies how Silica lists are implemented. Per the specification, lists are composed of buffers sized to the vector processing unit (128-bit for NEON, 256-bit for SVE on AArch64). When a list stores non-primitive data, each buffer slot holds a reference to a Silica region—i.e., a region handle.

Each stored handle points to a *chunk* region sized to the vector width. This enables efficient vectorized operations on list elements:

```silica
-- List-like structure: a region holding refs to chunk region handles.
-- Each chunk is a region sized to the vector processing unit (16 bytes = 128-bit NEON).
sequence proc[mem(normal)]
    L1: lifetime <- fresh_lifetime();
    L2: lifetime <- fresh_lifetime();
    L3: lifetime <- fresh_lifetime();
    
    -- Main region: holds refs to chunk region handles
    list_r: region(L1, normal) <- alloc_region(normal);
    
    -- Chunk regions sized to vector width (16 bytes = 2 × int64 for NEON 128-bit)
    chunk1: region(L2, normal) <- alloc_region(normal);
    chunk2: region(L3, normal) <- alloc_region(normal);
    
    -- Allocate buffers in each chunk (2 int64s = 16 bytes)
    (chunk1, buf1) <- alloc_buf(chunk1, 2);
    (chunk2, buf2) <- alloc_buf(chunk2, 2);
    
    -- Store chunk handles in the list region (handles are moved into the cells)
    (list_r, ref1) <- alloc_ref(list_r, chunk1);
    (list_r, ref2) <- alloc_ref(list_r, chunk2);
    
    -- ref1: ref(L1, normal, region(L2, normal)) — points to a cell containing chunk1's handle
    -- ref2: ref(L1, normal, region(L3, normal)) — points to a cell containing chunk2's handle
produces pure (list_r, ref1, ref2, buf1, buf2) end
```

The main region `list_r` holds references to cells that contain region handles. Each handle identifies a chunk-sized region (16 bytes for NEON, or 32 bytes for SVE). The list structure can iterate over these refs, use `read_ref` to obtain a chunk handle when needed, and perform vectorized operations on the chunk buffers.

---

## Passing the Region Handle vs. Returning References

### Region Handle Passed In

When the caller owns the region, pass the region handle as a parameter. The handle is moved into the function, so the function must return it (along with any references it allocates):

```silica
fn add_cell(
    r: region(R, normal),
    value: int64
) -> (region(R, normal), ref(R, normal, int64)) proc[mem(normal)] {
    ref: ref(R, normal, int64) <- alloc_ref(r, value);
    (r, ref)   // Return both handle and reference
}
```

The caller allocates the region and passes `r`. The function returns the handle and the new reference; the region outlives the call because the caller receives the handle back.

### Returning Both Region and References

When a function allocates a region and wants to return references into it, you must return **both** the region handle and the references. Otherwise the region would be freed at scope exit, leaving dangling references:

```silica
fn build_list() -> (region(L1, normal), ref(L1, normal, (int64, ref?(L1, normal, (int64, rec))))) proc[mem(normal)] {
    sequence proc[mem(normal)]
        L1: lifetime <- fresh_lifetime();
        r: region(L1, normal) <- alloc_region(normal);
        head: ref(L1, (int64, ref?(L1, normal, (int64, rec)))) <- alloc_rec(r, (42, :none));
    produces
        pure (r, head)   // Return both so the region stays alive
    end
}
```

The region is considered "returned" when the return value contains `region(L, Space)`. Its lifetime extends to the caller, and it remains allocated as long as the returned value is in use.

### What Not to Do

```silica
fn bad() -> ref(R, normal, int64) proc[mem(normal)] {
    sequence proc[mem(normal)]
        r: region(R, normal) <- alloc_region(normal);
        ref: ref(R, normal, int64) <- alloc_ref(r, 42);
    produces
        pure ref   // ERROR: ref would outlive region r
    end
}
```

Returning only the reference is a compile-time error: the region would be freed when the sequence exits, leaving a dangling reference.

---

## Building Linked Structures

Linked lists and trees use region references for the "next" or "child" pointers. The region handle is passed in so the structure can allocate new nodes. Because the handle is moved, the function must return it:

```silica
-- Linked list node: (value, optional next)
-- The handle r is moved in; the function must return it along with the new list head.
fn map(
    r: region(R, normal),
    f: fn(int64) -> int64,
    xs: ref(R, (int64, ref?(R, normal, (int64, rec))))
) -> (region(R, normal), ref(R, (int64, ref?(R, normal, (int64, rec))))) proc[mem(normal)] {
    (value: int64, next: ref?(R, normal, (int64, rec))) <- read_ref(xs);
    case next of {
        :none -> (r, alloc_rec(r, (f(value), :none)));
        next_ref: ref(R, normal, (int64, rec)) -> do
            (r2, mapped_next) <- map(r, f, next_ref);
            (r2, alloc_rec(r2, (f(value), mapped_next)))
        end
    }
}
```

- `r` (region handle): moved in, must be returned. Used with `alloc_rec` to allocate new nodes.
- `xs`, `next_ref` (region references): used with `read_ref` to read node contents, and stored in new nodes to form the linked structure.

---

## Region Handles and Actors

When passing a region handle to an actor via `spawn`, ownership and lifetime matter. Actors run independently and can outlive the spawner, so the region must stay alive as long as the actor needs it.

### The Problem: Copying the Handle to Multiple Actors

If region handles are copyable and you pass the same handle to two actors:

```silica
r: region(L1, normal) <- alloc_region(normal);
spawn(State1 { region: r }, behavior1);   // copy to actor 1
spawn(State2 { region: r }, behavior2);   // copy to actor 2
```

Both actors receive a copy. But the region was allocated in the spawner's scope. When the spawner returns, that scope exits and the region is freed. Both actors end up with dangling handles.

### The Solution: Copy the Region, Return the Handle

`spawn` follows the same rule as any function: when you pass a region handle, it is moved, and the function must return it. `spawn` performs a region copy so both spawner and actor have valid handles:

1. **Handle is moved**: Ownership transfers to `spawn`.
2. **Copy the region**: Allocate a new region and copy its contents.
3. **Actor receives handle to the copy**: The actor's initial state receives a handle to the newly allocated copy.
4. **Spawn returns the original handle**: `spawn` returns the original handle to the spawner (along with the `actor_ref`). The spawner regains ownership.

After the first spawn:

- **Actor 1** has a handle to its own copy of the region.
- **Spawner** receives the original handle back from `spawn`.

For a second actor, the spawner passes the handle again and receives it back. Each actor has its own handle to its own copy. All handles remain valid.

### Trade-offs

| Aspect | Effect |
|--------|--------|
| **Correctness** | No dangling handles; each owner has a distinct region. |
| **Cost** | Each spawn performs a region copy (allocation plus copying contents). |
| **Semantics** | Regions diverge after spawn; changes in one do not affect the others. |
| **Use case** | Use when each actor should have its own independent copy of the data. |

---

## Summary Table

| Aspect | Region Handle | Region Reference |
|--------|---------------|------------------|
| Type | `region(L, Space)` | `ref(L, Space, T)` |
| Obtained from | `alloc_region(Space)` | `alloc_ref(region, value)`, `alloc_rec(region, ...)` |
| Count per region | One | Many |
| Used with | `alloc_ref`, `alloc_buf`, `alloc_rec` | `read_ref`, `write_ref` |
| Represents | The memory arena | A pointer to a specific cell |
| Controls | When the region is freed | Access to stored data |

---

## See Also

- **Specification**: `silica-specification.md` §4.4 (Region and Memory Types), §12 (Memory Model)
- **Recursive structures**: `recursive_tuple_specification.md` for linked lists and trees
