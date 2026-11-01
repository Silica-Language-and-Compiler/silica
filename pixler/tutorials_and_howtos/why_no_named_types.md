# Why No Named Types: Regions Instead of Recursive Type Definitions

Many languages rely on **named type definitions** to build recursive data structures — linked lists, trees, graphs. Silica takes a different path. This tutorial explains why named types are absent, what problems they cause, and how Silica's **memory regions** with **recursive tuples** replace them.

---

## What Are Named Types?

In most languages you write something like:

```
type LinkedList = Cons(int64, LinkedList) | Nil
type Tree = Node(int64, Tree, Tree) | Leaf
```

The name (`LinkedList`, `Tree`) appears on both sides of the definition, allowing the type to refer to itself. Every language with algebraic data types — Haskell, OCaml, Rust, Swift — uses this mechanism.

---

## The Problem with Named Recursive Types

Named recursive types look clean on paper but hide real costs.

### 1. Hidden Heap Allocation

Each recursive position is an implicit pointer. The runtime must heap-allocate every `Cons` cell or `Node` independently. You never see where the memory comes from or when it is freed — the allocator decides.

### 2. Fragmented Memory Layout

Independent heap allocations scatter nodes across memory. Traversing a linked list or tree chases pointers into unpredictable cache lines. This is the opposite of what modern hardware wants.

### 3. Garbage Collection or Reference Counting Overhead

Languages with named recursive types need a strategy to reclaim scattered allocations:
- **Garbage collection** introduces pauses and unpredictable latency
- **Reference counting** adds per-object overhead and cycle-detection complexity
- **Ownership systems** (Rust's `Box<T>`) make the pointer explicit but still allocate individually

### 4. No Control Over Memory Properties

Named types say nothing about *where* or *how* memory is allocated. You cannot specify cache policy, memory space, or region lifetime. The allocator is a black box.

---

## Silica's Alternative: Regions + Recursive Tuples

Silica replaces named recursive types with two orthogonal mechanisms:

| Mechanism | Purpose |
|-----------|---------|
| **`rec`** keyword in tuple types | Self-reference within a type expression |
| **Memory regions** with `ref?` | Explicit allocation, layout, and lifetime |

Together they give you recursive data structures with **explicit memory control** and **no hidden allocation**.

---

## Building a Linked List Without Named Types

### The named-type version (other languages)

```
type IntList = Cons(int64, IntList) | Nil
```

### The Silica version

A linked list node is a tuple `(int64, ref?(L, normal, rec))` — an `int64` value and an optional reference to another node of the same shape. The `rec` keyword refers back to the enclosing tuple type.

```silica
sequence proc[mem(normal)]
    L1: lifetime <- fresh_lifetime();
    r: region(L1, normal) <- alloc_region(normal);

    // Build: 3 -> 2 -> 1 -> :none
    node1: ref(L1, normal, (int64, ref(L1, normal, (int64, rec)) | :none))
        <- alloc_rec(r, (1, :none));
    node2: ref(L1, normal, (int64, ref(L1, normal, (int64, rec)) | :none))
        <- alloc_rec(r, (2, node1));
    node3: ref(L1, normal, (int64, ref(L1, normal, (int64, rec)) | :none))
        <- alloc_rec(r, (3, node2));
produces pure 0 end
```

**What you gain:**
- Every node lives in region `r` — contiguous arena, not scattered heap
- The memory space (`normal`) is explicit in the type
- When the `sequence` block exits, the entire region is freed at once — no GC, no refcount
- You can choose `normal_writethrough`, `atomic`, or any other space by changing one parameter

---

## Building a Binary Tree Without Named Types

### The named-type version (other languages)

```
type IntTree = Node(int64, IntTree, IntTree) | Leaf
```

### The Silica version

A tree node is a tuple with two recursive positions — left and right children:

```silica
sequence proc[mem(normal)]
    L1: lifetime <- fresh_lifetime();
    r: region(L1, normal) <- alloc_region(normal);

    // Leaf nodes
    leaf1: ref(L1, normal, (int64, ref(L1, normal, (int64, rec, rec)) | :none,
                                    ref(L1, normal, (int64, rec, rec)) | :none))
        <- alloc_rec(r, (1, :none, :none));
    leaf2: ref(L1, normal, (int64, ref(L1, normal, (int64, rec, rec)) | :none,
                                    ref(L1, normal, (int64, rec, rec)) | :none))
        <- alloc_rec(r, (3, :none, :none));

    // Parent node: 2 with left=1, right=3
    root: ref(L1, normal, (int64, ref(L1, normal, (int64, rec, rec)) | :none,
                                   ref(L1, normal, (int64, rec, rec)) | :none))
        <- alloc_rec(r, (2, leaf1, leaf2));
produces pure 0 end
```

Each `rec` in the tuple type marks a position where the same tuple shape recurs. No name needed — the structure *is* the type.

---

## Or Just Use `List[T, S]`

For the common case of ordered sequences, Silica provides `List[T, S]` directly. Lists are backed by region-allocated chunk buffers sized to the hardware vector width (128-bit NEON, scalable SVE). You get cache-friendly layout without writing region code by hand:

```silica
sequence proc[mem(normal)]
    L1: lifetime <- fresh_lifetime();
    r: region(L1, normal) <- alloc_region(normal);
    xs: List[int64, normal] <- prepend(r, 3, prepend(r, 2, prepend(r, 1, empty_list())));
produces pure 0 end
```

`List[T, S]` handles the recursive structure internally. The memory space `S` is explicit in the type — no hidden allocation policy.

---

## Why This Is Better

| Concern | Named Types (other languages) | Silica Regions + `rec` |
|---------|-------------------------------|------------------------|
| Memory location | Hidden (heap) | Explicit (region with chosen space) |
| Deallocation | GC / refcount / ownership | Region freed at block exit |
| Cache behavior | Uncontrolled | Chosen per-region (`normal`, `writethrough`, etc.) |
| Layout | Scattered allocations | Arena-contiguous within a region |
| Self-reference | Name on both sides of `=` | `rec` keyword in tuple type |
| Polymorphism | Named-type dispatch | Structural equivalence + traits |

---

## Summary

- **Named types** exist primarily to enable recursive type definitions. Deep recursion through named types is a naive implementation that hides allocation, fragments memory, and requires GC or ownership tracking.
- **Silica uses structural types everywhere.** Two types are equal if their structure matches — no names needed.
- **`rec`** inside a tuple type provides self-reference without a named definition.
- **Memory regions** give you explicit control over where data lives, how it is cached, and when it is freed.
- For common sequences, **`List[T, S]`** wraps the region machinery with a clean interface.

Named types solve a problem that Silica's regions and `rec` keyword solve more directly, with better hardware alignment and no hidden costs.

---

## See Also

- [memory_region_types.md](memory_region_types.md) — memory space types and cache policies
- [region_handles_and_references.md](region_handles_and_references.md) — handles, references, and buffers
- [list_memory_space_and_effects.md](list_memory_space_and_effects.md) — `List[T, S]`, regions, and effect declarations
