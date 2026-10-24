---
title: Silica for Programmers
layout: default
permalink: /learn-silica/
---

# Silica for Programmers

**A short introduction if you already write software**

Copyright © 2026 Lee Scott Barney

Silica is a functional systems language. Effects are explicit. Actors stay isolated and talk by message. Memory is regional, stacked per actor, and not garbage-collected. There are no user-level loops. This book assumes you already write software in C, Rust, Erlang or Elixir, Haskell, Go, Python, or something in that neighborhood. It maps Silica onto ideas you already have, then spends a little time on why the mapping is not one-to-one.

If you have never programmed, use [Learn to Program]({{ '/learn-programming/' | relative_url }}) first. That book is slower on purpose.

The [language specification](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica-specification.md) wins if this book and the compiler disagree. The hosted targets today are macOS on Apple Silicon, Linux on AArch64 and Linux on x86-64; the ESP32-S3 is supported OS-free through a cross compiler.

Simple runnable programs live in `[trials/](https://github.com/yenrab/silica/tree/main/trials)`. Each subdirectory is one topic. The snippets in this book are maps of the idea. Open those files when you want a program that is meant to compile and run.

## 1. Positioning

You will recognize most of the pieces. The combination is the point. Silica puts effects, isolation, and memory into one model so the compiler can refuse programs that other languages would accept and then hope a review or a collector saves.

| You know                              | Silica’s analogue                        | Difference that matters                                                                                                                     |
| ------------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Rust ownership / lifetimes            | Regions + move of region handles         | No borrow-checker theatre. A lifetime is a value from `fresh_lifetime()`. Storage is the actor stack, not a heap the collector later walks. |
| Erlang/Elixir actors                  | `spawn` / `call` / `cast`, supervisors   | Native code. A behavior is `(Msg, State) -> …` and runs once per message. The runtime owns the mailbox loop.                                |
| Haskell `IO` / `ST`                   | `sequence proc[ε] … produces pure e end` | Effects live on sequences, never on `fn` signatures.                                                                                        |
| C pointers + malloc                   | `region`, `ref`, `buf`, `alloc_*`        | Space (`normal`, `atomic`, `device`, …) is part of the type. There is no implicit free.                                                     |
| Go goroutines + channels              | Actors + messages                        | Isolation is the default. There is no shared mutable heap for ordinary data.                                                                |
| ML / OCaml ADTs                       | Inline sums, tagged tuples, atoms        | No user-declared type names. You write the shape at the use site.                                                                           |
| C++ / Java generics                   | Traits over concrete inline types        | No `T` parameters in user code.                                                                                                             |
| Python names, `if`/`for`, GC, `print` | Bindings, `case`, regions, `device_io`   | Types and effects are written down. Names do not mutate. There is no heap collector.                                                        |

The design rules, in the order you will feel them:

- **Effects are explicit.** If a block prints, allocates, or sends a message, its `sequence` says so. Effects are local: a sequence declares what its own steps do, and calling a function adds nothing to the caller, because the callee's own sequence declares and discharges its effects.
- **Heap is an effect.** Allocating or growing region-backed storage is `mem(<space>)` on a sequence, not an invisible runtime service.
- **Memory is regional and stack-shaped per actor.** There is no garbage collector and no shared heap for long-lived application data. A `ref` or `buf` is never separated from the region that contains the memory it refers to.
- **Concurrency is message passing.** Isolation comes first. Sharing is a deliberate, typed move of a region, not a default. A well-designed application is a set of actors, not a tree of function calls.
- **Readable for people and for LLMs.** One way at the language level: recursion, not loops; traits, not generics; one operator per job. You compose those pieces; you do not pick among several primitives that do the same thing. There are no type aliases: the shape at the use site is the type, so nothing has to be unfolded through a definition set.
- **FFI is visible.** Mixed stacks wear `dangerous_` up the import graph. Pure Silica stays visibly pure.

Motto: *secure by default at compile time — fail soft, never fail silent.*

## 2. Syntax in one pass

A function has a name, typed parameters, a typed result, and a body. `main` is the entry. When the body talks to the world, it does that inside a `sequence` that names the effects.

```silica
fn add(x: int64, y: int64) -> int64 {
    x + y
}

fn main() -> int64 {
    sequence proc[device_io]
        println("hi");
        n: int64 <- add(2, 3)
    produces
        pure n
    end
}
```

`add` is pure: two `int64` values in, one out. `main` prints, then binds `n`, then produces `n`. The `device_io` on the sequence is what authorizes the print. `<-` is a bind, not a mutation. `produces pure n` is the result of the sequence; `pure` means that expression does not start any new effect.

Operators you will hit immediately:

| Token        | Role                            |
| ------------ | ------------------------------- |
| `<-`         | Bind a name to a value          |
| `=` / `==`   | Equality (not “declare a type”) |
| `->`         | Function type, or a `case` arm  |
| `:`          | Type ascription                 |
| `@`          | Module qualify: `math@add`      |
| `//` `{- -}` | Comments                        |
| `:ok`        | Atom literal                    |

There is no standalone `if`. You branch with `case`. The keyword `if` exists only as a guard on a case arm: `n: int64 if n > 0 -> …`. Python `if` / `elif` / `else` and unguarded `match` do not exist here.

Catch-alls are typed: `_: int64 -> 0`. A bare `_` is illegal. Python `match` allows `_`; Silica will not, because the type of the leftover value still has to be written down.

`and` / `or` / `not` are boolean. Comparisons are `==` `!=` `<` `>` `<=` `>=`. Integer `/` truncates toward zero. That is closer to Python `//` than to `/`, except Python `//` floors and Silica truncates toward zero.

Functions are top-level only, and they take at most eight parameters. A nested `fn name` declaration is an error. Function literals (`fn(x: int64) -> int64 { x + 1 }`) are fine in expression position. The `-> type` is required (a literal without it is error E1071; the type is never inferred). A literal may capture a name only if, where the literal is written, that name is bound to an integer literal (decimal or hex) by an integer-typed binding (`int8` to `int64`, `uint8` to `uint64`). Every other capture is error E1072, which names the captured name: a function parameter, a computed value (`m: int64 <- n * 2`), a float, boolean, string or atom literal, a record, a name rebound later to a non-literal, a name shadowed by a tuple decomposition or a case pattern, or a formal of an enclosing literal. To use any other value, pass it to the literal as an argument. There are no closure environments. With `n: int64 <- 3` in scope, `f: fn(int64) -> int64 <- fn(x: int64) -> int64 { x + n }` adds 3, and `f` can be passed as an argument or sent as a message (the trials `functions_addition/fn_param_unary_lambda_as_variable_capture` and `actors_addition/actor_message_capturing_fn_literal` show both). A literal that captures a local binding cannot be returned from the function that owns the binding (E1067): a returned capturing literal stays an error. There are no Python-style nested `def`s, no `*args`, and no default arguments. If you need more than eight inputs, group them in a tuple or a record.

The entry point is `main`. There is no `if __name__ == "__main__"`.

First program: `[trials/base/test.silica](https://github.com/yenrab/silica/blob/main/trials/base/test.silica)`. Arithmetic: `[int64_addition](https://github.com/yenrab/silica/tree/main/trials/int64_addition)`. Functions: `[functions_addition](https://github.com/yenrab/silica/tree/main/trials/functions_addition)` (`add_with_params.silica`, `fn_two_functions.silica`).

## 3. Types are structural

Silica does not let you introduce a new type name. There is no `type Foo = …`, no `struct Foo { … }`, and no user `enum` that binds a fresh identifier. You write the shape wherever a type is required — on a parameter, a return, a binding, a pattern. Python `class`, `dataclass`, `TypedDict`, and `TypeAlias` are the same kind of thing, and they are absent too.

```silica
fn area(r: { width: int64, height: int64 }) -> int64 {
    r.width * r.height
}

fn wrap(n: int64) -> (atom, int64) {
    (:ok, n)
}
```

`area` takes a record that has `width` and `height`. Any value with those fields and those field types is acceptable. Two records with the same fields and field types are the same type. The same rule holds for tuples and for inline sums such as `Some(int64) | None`. A Python `dict` with the same keys is not a type. Two dataclasses with the same fields are still different classes.

`None` in that sum is a **constructor name**, a tag with no payload. It is not Python’s `None`. The unit value — “there is no interesting result” — is `()`. Do not use `None` when you mean unit.

Everyday primitives: `int64`, `uint64`, `boolean`, `string`, `char`, `atom`, `()`, `float64`. Width-specific ints and floats exist when you need them. There is no implicit widening. Python `int` is unbounded; Silica `int64` is not.

Function types are written `(int64, int64) -> int64`. They are required, not optional annotations.

Lists are `List[int64]` in casual description, or `List[int64, mem(normal)]` when the memory space is part of the type. That space must agree along a value’s whole flow. Do not write `List[int64]` in one place and `List[int64, mem(normal)]` in another for the same list. The trials use the two-parameter form.

Atoms are interned at compile time. Equality is identity. Use them as tags (`:ok`, `:error`, `:noreply`) rather than as strings. They are not Python `Enum` members and not interned `str` constants.

Widths and literals: `[int64_addition](https://github.com/yenrab/silica/tree/main/trials/int64_addition)`, `[boolean_addition](https://github.com/yenrab/silica/tree/main/trials/boolean_addition)`, `[atoms_addition](https://github.com/yenrab/silica/tree/main/trials/atoms_addition)`, `[string_addition](https://github.com/yenrab/silica/tree/main/trials/string_addition)`. Records: `[records_addition/01_basic_struct_creation.silica](https://github.com/yenrab/silica/blob/main/trials/records_addition/01_basic_struct_creation.silica)`.

## 4. Functions, bindings, case

A function is the unit of reuse. A binding gives a value a name for the rest of the scope. `case` is how you choose.

```silica
fn abs(n: int64) -> int64 {
    case n of {
        x: int64 if x >= 0 -> x;
        x: int64 -> 0 - x
    }
}

fn labeled(n: int64) -> string {
    case n of {
        x: int64 if x > 0 -> "pos";
        x: int64 if x < 0 -> "neg";
        _: int64 -> "zero"
    }
}
```

`abs` binds the scrutinee as `x` and uses a guard for the non-negative side. The second arm covers the rest. `labeled` needs three outcomes, so the last arm is a typed catch-all.

Bindings always carry a type: `n: int64 <- 3`. Names do not mutate. If you need a different value, bind another name. `next: int64 <- n + 1` is a new binding. It is not Python `n += 1`.

`case` is exhaustive. A guard does not cover the values that fail the guard. Keep a typed catch-all, or cover the remaining constructors. Python `match` is exhaustive only if you opt in. Silica’s `case` always is. That is the feature: a forgotten arm is a compile error, not a runtime surprise.

When an arm needs more than one step, wrap it in `{ … }`:

```silica
case ready of {
    true -> {
        next: int64 <- n + 1;
        next
    };
    false -> n
}
```

Records and tuples pattern-match in the obvious way: `{ width: w, height: h }`, `(tag: atom, n: int64)`.

Working programs: `[case_addition](https://github.com/yenrab/silica/tree/main/trials/case_addition)` (`case_boolean_literal_branches.silica`, `case_int64_mirror_sign.silica`). Bindings and helpers: `[functions_addition](https://github.com/yenrab/silica/tree/main/trials/functions_addition)`.

## 5. Sequences and effects

A `sequence` is ordered steps with a marked result. Effects are declared on that block, not on the function signature. This is illegal:

```silica
fn boom() -> int64 proc[device_io] { … }   // no
```

This is legal:

```silica
fn boom() -> int64 {
    sequence proc[device_io]
        println("x")
    produces
        pure 0
    end
}
```

The signature of `boom` is only `() -> int64`. The sequence admits `device_io`. `produces pure 0` is the value that comes out; `pure` means `0` itself does not start a new effect. Nested sequences — including sequences inside lambdas — each declare what they need. Effects are local: a sequence declares only the effects of its own operations. A caller of `boom` needs no `device_io` of its own, because `boom`'s sequence already declares and discharges it; a caller that declares an effect only because a callee uses it gets E3010 (unused effect declaration). The one exception is `register_rwr`: a function whose body holds a `register_rwr` sequence reaches a device, so every caller must declare it too.

That is the honesty rule. A helper that prints cannot print without a sequence that says so, and you see that sequence where the printing is written. Reading a function body tells you what that body does itself; a `sequence` header never lists work that only a callee performs.

Built-in effects:

| Effect            | Means                                                 |
| ----------------- | ----------------------------------------------------- |
| `device_io`       | stdout, console, files                                |
| `network_io`      | network I/O, reached through Fifi wrappers (§20.4)    |
| `concurrency`     | `spawn`, `call`, `cast`, and related actor work       |
| `mem(Space)`      | allocate, read, or write in that memory space         |
| `atomic`          | atomic operations                                     |
| `hot_swap`        | dynamic code load                                     |
| `register_rwr`    | MMIO; only inside `spawn_device` behaviors            |
| `external_danger` | outbound FFI; only inside `spawn_dangerous` behaviors |

Print helpers require `device_io`. In Python, `print` is an ordinary call. Here the sequence that prints must admit the effect. The print builtins are `print_string`, `print_int64`, `print_boolean`, `print_char`, `println` and `println_stderr`; each returns the atom `:ok`, so a print that is not the last step is written `_: atom <- print_int64(n);` (a bare `println("x");` statement is also accepted). `wait_for_exit()` needs `device_io` as well, because it reads standard input.

On OS-hosted targets, `mem(Space)` is still in the type system. Distinct hardware attributes per space are guaranteed on OS-free targets, not on macOS or Linux process virtual memory. The OS still chooses the page attributes; Silica still makes you name the space you meant.

A sequence that only produces `42`: `[sequence_block_addition](https://github.com/yenrab/silica/tree/main/trials/sequence_block_addition)`. Effects on sequences: `[effect_check_addition](https://github.com/yenrab/silica/tree/main/trials/effect_check_addition)` (`device_io_in_sequence.silica`). Print: `[string_addition/test_print.silica](https://github.com/yenrab/silica/blob/main/trials/string_addition/test_print.silica)`.

## 6. Data

**Tuples** are ordered groups. `(3, true)` has type `(int64, boolean)`. Unpack with `(n: int64, b: boolean) <- pair`. Position is the API, as with a Python tuple, but the types are required.

**Records** are named fields. The value `{ x: 1, y: 2 }` has type `{ x: int64, y: int64 }`. Field access is `p.x`. This is not a `dict`, not a `namedtuple`, and not a dataclass instance. The shape *is* the type.

**Lists** are immutable, head-oriented, and shared structurally. They are not a Python `list`: there is no `xs[i]`, no in-place `append` or `pop`, and no slice assignment.

```silica
xs: List[int64, mem(normal)] <- [1, 2, 3];
ys: List[int64, mem(normal)] <- prepend[int64, mem(normal)](0, xs);   // xs unchanged
```

Every list type names its memory space: `List[int64, mem(normal)]`, not `List[int64]`. The same holds for every other data structure (`OrderedMap[...]`, `OrderedSet[...]`, `Heap[...]` and the rest take `mem(Space)` as their last type argument). In casual prose a list of integers may be called `List[int64]`, but code always writes the space.

`prepend` returns a new list. `xs` is still `[1, 2, 3]`. Growing a list allocates, so it belongs in `sequence proc[mem(Space)]`. There is no primitive that deletes from the middle. Walking a list is usually a `case` on `[]` and `[h, t]` rather than a family of `head` / `tail` calls.

**Tagged results** are how you represent failure. Prefer data over exceptions. There is no `try` / `except`, no `raise`, and no Python `None` meaning “missing.”

```silica
fn safe_div(x: int64, y: int64) -> (atom, int64) {
    case y == 0 of {
        true -> (:error, 0);
        false -> (:ok, x / y)
    }
}
```

The caller must look at the atom. Forget an arm and `case` is incomplete.

**Recursive tuples** replace named recursive ADTs. Self-reference is the keyword `rec` inside a tuple type, where it means "this same tuple type" (spec §4.2.2). A Python class with a `next` field hides allocation. Here the region is explicit.

This applies only to tuples whose type contains `rec`. An ordinary tuple such as `(3, true)` is a plain value: no region, no `ref?`, no `:none`, and the compiler decides where it lives. A recursive tuple is different in four ways:

- **It always lives in a region.** Every cell is allocated with `alloc_rec(region, (…))` in a region of type `region(L, Space)`, and `alloc_rec` returns a reference `ref(L, Space, …)` to the new cell. There is no other way to build one.
- **Its memory space is part of its type.** Each recursive position is `ref?(L, Space, …)`, shorthand for `ref(L, Space, …) | :none`, naming the region's lifetime `L` and its space. Region and reference types write the space bare (`ref?(L, normal, rec)`, `region(L, normal)`); collection types wrap it (`List[int64, mem(normal)]`).
- **`:none` is the empty case.** It fills a recursive position that points nowhere, like the end of a list or a missing child.
- **Allocation and reading are memory effects.** `alloc_rec` and `read_ref` carry `mem(Space)`, so the sequence that does them declares it, for example `sequence proc[mem(normal)] … end`.

Here is a node from a real structure: the weight-balanced tree behind `OrderedSet`, `OrderedMap` and `SearchTree`. The standard library declares the node type in `stdlib/data_structures/wbt_set.silica`:

```silica
(ItemType, int64, ref?(L, normal, rec), ref?(L, normal, rec))
```

The four positions are the item, the cached size of the subtree rooted at this node, the left subtree and the right subtree. The cached size is what keeps every insert and delete logarithmic: rebalancing compares subtree sizes without walking the subtrees.

The three functions below fix `ItemType` to `int64` so they compile on their own.

Reading a node. `subtree_size` returns 0 for an empty subtree (`:none`); otherwise it reads the cell with `read_ref` and takes the cached size out of it:

```silica
fn subtree_size(subtree: ref?(L, normal, (int64, int64, ref?(L, normal, rec), ref?(L, normal, rec)))) -> int64 {
    case subtree of {
        :none -> 0;
        node_ref: ref(L, normal, (int64, int64, ref?(L, normal, rec), ref?(L, normal, rec))) -> {
            sequence proc[mem(normal)]
                node: (int64, int64, ref?(L, normal, rec), ref?(L, normal, rec)) <- read_ref(node_ref);
                (_: int64, size: int64, _: ref?(L, normal, rec), _: ref?(L, normal, rec)) <- node
            produces
                pure size
            end
        }
    }
}
```

Building a node. `make_node` computes the new node's size from its two subtrees and allocates the cell in the region with `alloc_rec`. It returns the region together with the new reference: a function that returns a reference into a region must return the region too (spec §12.1.4). The standard library's own node constructor does the same.

```silica
fn make_node(
    arena: region(L, normal),
    item: int64,
    left: ref?(L, normal, (int64, int64, ref?(L, normal, rec), ref?(L, normal, rec))),
    right: ref?(L, normal, (int64, int64, ref?(L, normal, rec), ref?(L, normal, rec)))
) -> (region(L, normal), ref(L, normal, (int64, int64, ref?(L, normal, rec), ref?(L, normal, rec)))) {
    sequence proc[mem(normal)]
        size: int64 <- subtree_size(left) + subtree_size(right) + 1;
        cell: ref(L, normal, (int64, int64, ref?(L, normal, rec), ref?(L, normal, rec))) <- alloc_rec(arena, (item, size, left, right))
    produces
        pure (arena, cell)
    end
}
```

Using them. `main` creates a region, builds a three-node tree with 2 at the root and 1 and 3 below it, and prints the root's cached size, 3:

```silica
fn main() -> int64 {
    sequence proc[mem(normal), device_io]
        L: lifetime <- fresh_lifetime();
        arena: region(L, normal) <- alloc_region(normal);
        (a1: region(L, normal), one: ref(L, normal, (int64, int64, ref?(L, normal, rec), ref?(L, normal, rec)))) <- make_node(arena, 1, :none, :none);
        (a2: region(L, normal), three: ref(L, normal, (int64, int64, ref?(L, normal, rec), ref?(L, normal, rec)))) <- make_node(a1, 3, :none, :none);
        (a3: region(L, normal), root: ref(L, normal, (int64, int64, ref?(L, normal, rec), ref?(L, normal, rec)))) <- make_node(a2, 2, one, three);
        print_int64(subtree_size(root));
        println("")
    produces
        pure 0
    end
}
```

Recursive tuples are only for building non-naive data structures of the kind the built-in ones exemplify: `OrderedMap`, `OrderedSet`, `SearchTree`, `Heap`, `PriorityQueue`, `Tree`, `BinaryTree` and the graph structures are written this way, as balanced, persistent structures with stated bounds, inside the standard library. Application code does not hand-build linked lists or ad hoc trees from them; it uses `List[T, mem(Space)]` and the built-in structures, and reaches for recursive tuples only when it is writing a new data structure of that quality. See [why no named types](https://github.com/yenrab/silica/blob/main/compiler/tutorials_and_howtos/why_no_named_types.md) and [region handles and references](https://github.com/yenrab/silica/blob/main/compiler/tutorials_and_howtos/region_handles_and_references.md).

**Strings** are UTF-8. Join and slice with the string operations (`concatenate` / `concat`, `substring` with character indices, `length_chars` / `length_bytes`, `starts_with` / `ends_with` / `contains`). There is no `+` for strings, no f-string, and no `str.format`. See `[string_addition](https://github.com/yenrab/silica/tree/main/trials/string_addition)` (`test_concat_literals.silica`, `test_length_chars.silica`).

Tuples: `[tuples_addition](https://github.com/yenrab/silica/tree/main/trials/tuples_addition)` (`int64_pair.silica`, `decompose_from_literal.silica`). Records: `[records_addition](https://github.com/yenrab/silica/tree/main/trials/records_addition)`. Lists: `[list_addition](https://github.com/yenrab/silica/tree/main/trials/list_addition)` (`list_int64_prepend.silica`, `list_int64_recursive_sum.silica`). Atoms: `[atoms_addition](https://github.com/yenrab/silica/tree/main/trials/atoms_addition)`.

## 7. Recursion only

There is no `for`, `while`, or `loop`. You walk data by recursion. There is no Python `for x in xs`, no `while`, and no comprehension. The mailbox “infinite loop” is inside the runtime. Your actor behavior returns.

```silica
fn sum(xs: List[int64, mem(normal)]) -> int64 {
    case xs of {
        []: List[int64, mem(normal)] -> 0;
        [h: int64, t: List[int64, mem(normal)]] -> h + sum(t);
        _: List[int64, mem(normal)] -> 0
    }
}
```

The empty list is the base case. Everything else is the head plus the sum of the rest. Forget the base case and you ask the machine to work forever.

Write the stopping case first. That is the habit that keeps recursion honest. The thing that stresses an actor stack is deep work **during one message**, not the number of messages over time. Each behavior invocation returns before the next message is received.

The same idea without lists is factorial; with lists, a recursive `case` on `[h, t]`. See `[recursive_function_addition](https://github.com/yenrab/silica/tree/main/trials/recursive_function_addition)` (`recursive_factorial.silica`, `recursive_sum_tail.silica`) and `[list_addition/list_int64_recursive_sum.silica](https://github.com/yenrab/silica/blob/main/trials/list_addition/list_int64_recursive_sum.silica)`.

## 8. Modules and traits

A file is a module. The file stem is the module name. You export by name and arity; nothing is public by accident.

```silica
export add/2;

fn add(x: int64, y: int64) -> int64 {
    x + y
}
```

`export add/2` means this module offers `add` with two parameters. Importers qualify the call. That is closer to `import math` / `math.add` than to `from math import add`:

```silica
use math;

fn main() -> int64 {
    math@add(2, 3)
}
```

There is no implicit public `def` and no `__init__.py` package tree. `use` plus `@` keeps the origin of a name visible.

Traits are files, not `trait T { }` blocks and not Python ABCs or `Protocol`. `shape.silica` declares `export trait Shape;`, lists `required` and `provided` methods, and supplies `impl fn` for concrete inline types. Callers write `use shape;` and `shape@area(rect)`.

There is no `Option<T>`. Shared operations live on traits implemented for concrete sums such as `Some(int64) | None`. Marker traits (`ActorMessage`) are compile-time tags. In that sum, `None` is a constructor, not Python `None`.

If two compilation units need to recurse into each other, do not create a `use` cycle. Pass the recursive entry as a callback. See [open recursion](https://github.com/yenrab/silica/blob/main/compiler/tutorials_and_howtos/open_recursion_callbacks.md).

Modules: `[modules_addition](https://github.com/yenrab/silica/tree/main/trials/modules_addition)` (`one_use_main.silica`, `lib/lib_base.silica`). Traits: `[traits_addition](https://github.com/yenrab/silica/tree/main/trials/traits_addition)` (`shape_main.silica`, `traits/Shape.silica`).

## 9. Standard data structures

Large types built from many items and layers are the naive design. Silica's standard library supplies persistent data structures instead, each defined by a **trait** (the queries) and one or more **construction modules** (building and updating). The designs are in [data_structure_designs](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/README.md). Bounds below are the designs' stated bounds. The implementations are in [stdlib/data_structures](https://github.com/yenrab/silica/tree/main/compiler/stdlib/data_structures), and each module header lists the deviations the current compiler forces.

Reference: what each trait is for, the module that builds it, its representation and its headline bounds.

| Trait | For | Construction modules | Representation | Headline bounds |
|---|---|---|---|---|
| `OrderedSet` | membership, ordered iteration | `wbt_set` | corrected Adams weight-balanced tree, (δ, γ) = (3, 2) | contains, insert, delete `O(log n)`; size `O(1)` |
| `OrderedMap` | lookup by key | `wbt_map` | the same WBT, with a value per node | get, insert, delete `O(log n)`; find by value `O(n)` |
| `SearchTree` | search-tree view of a set | `wbt_set` (same value as `OrderedSet`) | the same WBT | contains `O(log n)` |
| `Heap` | min or max first | `brodal_okasaki_min`, `brodal_okasaki_max` | Brodal–Okasaki bootstrapped skew-binomial queue | peek, push, meld `O(1)`; pop `O(log n)` |
| `PriorityQueue` | (priority, value), most urgent first | `brodal_okasaki_priority` | the same queue over entries | peek, push, meld `O(1)`; pop `O(log n)` |
| `Tree` | ordered hierarchy, any fan-out | `tree_rose` | rose tree, child slots in a skew binary random-access list | add or replace at depth h: `O(Σ log b_i + h)` |
| `BinaryTree` | fixed left/right roles | `tree_binary` | persistent fixed-arity binary tree, with a zipper | root `O(1)`; path ops `O(h)` |
| `DirectedGraph` | one-way edges | `graph_wbt_directed`, `graph_csr_directed`, `graph_dense_directed` | live WBT graph, CSR snapshot, dense matrix | has/add edge `O(log V + log d)` (live) |
| `UndirectedGraph` | two-way edges | `graph_wbt_undirected`, `graph_weighted_undirected`, `graph_csr_undirected`, `graph_csr_weighted_undirected`, `graph_dense_undirected`, `graph_dense_weighted_undirected` | as above | connected `O((V_c + A_c) log V)` |
| `WeightedGraph` | edge weights | `graph_weighted`, `graph_weighted_undirected`, `graph_csr_weighted`, `graph_csr_weighted_undirected`, `graph_dense_weighted`, `graph_dense_weighted_undirected` | as above | weight lookup `O(log V + log d)` |

Choosing: the algorithm behind each structure, and the reason to reach for it.

| Trait | Algorithms behind it | Why pick it |
|---|---|---|
| `OrderedSet` | corrected Adams weight-balanced tree, (δ, γ) = (3, 2), with cached subtree sizes and path copying | You ask whether an item is present and you want the items in order. Duplicates collapse by the comparator. Membership and update are `O(log n)`, size is `O(1)`. |
| `OrderedMap` | the same weight-balanced tree, one value per node | You look values up by key, and you want the keys in order. Choose it over a list of pairs as soon as the collection is searched more than once. |
| `SearchTree` | the same weight-balanced tree; a view of the `OrderedSet` value | Your algorithm only searches. Taking `SearchTree` says exactly that, and any ordered set satisfies it. |
| `Heap` | Brodal–Okasaki bootstrapped skew-binomial queue, min or max orientation fixed by the module | You repeatedly take the smallest or largest item, and you merge queues: peek, push and meld are `O(1)`, pop is `O(log n)`. |
| `PriorityQueue` | the same queue over (priority, value) entries, compared by priority then value | The same need, but each item carries a payload and ties must break predictably. |
| `Tree` | rose tree whose child slots are a skew binary random-access list in reverse orientation | A hierarchy where a node has any number of children, child slots keep their numbers as siblings come and go, and you address nodes by path. |
| `BinaryTree` | persistent fixed-arity binary tree with cached subtree counts and a zipper | Exactly two roles per node, left and right, and you walk up and down in `O(1)`: expression trees, decision trees, an abstract syntax tree. |
| `DirectedGraph` | live weight-balanced-tree graph; CSR snapshot; dense matrix over a skew binary random-access list | Edges point one way, and you ask what a node points at or what it reaches. |
| `UndirectedGraph` | the same three, with each edge stored in both directions | Edges are mutual: neighbours, connectivity, components. |
| `WeightedGraph` | the same three, with a value on every edge | Edges carry data, such as a distance or a capacity, that you read back with the edge. |

For a graph, the representation is the second choice. The live tree accepts updates. The CSR snapshot freezes a live graph in `O(V + A)` and is then read-only, for repeated queries and scans. The dense matrix fits a fixed, small vertex universe and reaches any cell in `O(log V)`. The construction modules and the full bounds are in the sections below.

Everything is persistent. An update returns a new root, the old root stays valid, and every node off the changed path is shared between the two ([README](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/README.md), suite-wide decisions). Recursive nodes are region-allocated in one canonical arena per representation, linked by `ref?`, with `:none` as the empty position. Comparators return `:less | :equal | :greater` and define identity as well as order. A comparator that returns anything else is a deterministic collection error, not a branch.

### Ordered sets, maps and search trees

`wbt_set` and `wbt_map` are the corrected Adams-family weight-balanced tree ([weight_balanced_tree.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/weight_balanced_tree.md)), with the (3, 2) parameters proved in Hirai and Yamamoto (2011). Each node caches its subtree size, so `size` is `O(1)`. Search, insert and delete are `O(log n)` and path-copy `O(log n)` nodes on change. A duplicate insert or an absent delete allocates nothing. `from_sorted` builds in `O(n)`, `from_list` in `O(n log u)`, and `fold` visits in ascending order in `O(n)` ([ordered_set_trait.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/ordered_set_trait.md) §9, [ordered_map_trait.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/ordered_map_trait.md) §12).

`OrderedSet` and `OrderedMap` forward to those cores. `OrderedMap@get` takes a placeholder value to return with `:not_found`, because Silica source cannot conjure a zero of a programmer-declared type. `SearchTree` is not a third structure. It is a behavioural view over the same `wbt_set` value, so one value implements both traits ([SearchTree.silica](https://github.com/yenrab/silica/blob/main/compiler/stdlib/data_structures/SearchTree.silica) header).

### Heaps and priority queues

`brodal_okasaki` is the Brodal–Okasaki bootstrapped skew-binomial queue ([brodal_okasaki_queue.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/brodal_okasaki_queue.md)): `peek`, `push` and `meld` are `O(1)`, and `pop` is `O(log n)`. `brodal_okasaki_min` and `brodal_okasaki_max` are thin forwarders that fix the orientation; one `Heap` impl serves both. `brodal_okasaki_priority` runs the same core over `{ priority, value }` entries, compared priority-first and then by value. Equal entries coexist. Arbitrary deletion and decrease-key are deliberately absent ([priority_queue_trait.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/priority_queue_trait.md)). The priority and value placeholders are spelled `KeyType` and `ValueType` in the code (module header, deviation 1).

### Trees

`tree_rose` is a rose tree whose child slots are a skew binary random-access list in reverse orientation, so appending a child is `O(1)` and slot numbers stay stable ([tree_trait.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/tree_trait.md)). Removing a child vacates its slot. Siblings are never renumbered. Paths are `List[int64, mem(normal)]` of slot numbers, with the empty list as the root. The design's `add_child` is exported as `add_leaf`, because `add_child` is a supervisor built-in name.

`tree_binary` is a persistent fixed-arity binary tree with fixed left and right roles, cached subtree counts, and a zipper whose down and up moves are `O(1)` ([persistent_binary_tree.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/persistent_binary_tree.md)). Paths are built with `tree_binary@path_root`, `path_left` and `path_right`, because atoms are numbered per compilation unit and `:left` / `:right` written in another unit would not match.

### Graphs

There are three representations, all behind the same traits, each a distinct concrete record with no runtime tag:

- **Live WBT graph.** `graph_wbt_core` is a WBT map from node to a WBT map from target to edge value, over `wbt_map`. It supports updates. `has_edge` and `add_edge` are `O(log V + log d)`, and `reachable` / `connected` walk with a WBT visited set ([live_wbt_graph.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/live_wbt_graph.md)).
- **CSR snapshot.** `graph_csr_core` freezes a live graph in `O(V + A)` into offset, target and value buffers plus a node-to-slot WBT index. It is read-only. `has_edge` is a binary search, `O(log V + log d)` ([csr_graph_snapshot.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/csr_graph_snapshot.md)).
- **Dense matrix.** `graph_dense_core` has a fixed vertex universe and `V × V` cells in a skew binary random-access list. An edge update path-copies one cell in `O(log V)`, and a neighbour scan is `O(log V + V)` ([dense_matrix_graph.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/dense_matrix_graph.md)).

Vertex IDs are any type the node comparator accepts. They are never slot indexes. A weighted undirected graph also implements `UndirectedGraph`. The weighted directed `graph_weighted` does not implement `DirectedGraph` today; it offers the same directed queries as its own module functions ([DirectedGraph.silica](https://github.com/yenrab/silica/blob/main/compiler/stdlib/data_structures/DirectedGraph.silica) header, deviation 5).

### What the current compiler forces

The module headers list these deviations. You will meet them today:

- **Bracket types.** A bracket-typed binding such as `OrderedMap[string, int64, mem(normal)]` is accepted for a `module@empty/1` result, and for parameters and returns. The record an update returns (`{ map, inserted, replaced }`, `{ set, inserted }`, `{ tree, added, child_slot }`) is rejected when its field is written with the bracket type (E2003). It must be bound with the representation's inline record. `BinaryTree[ItemType, mem(normal)]` is accepted like the others (a `tree_binary@with_root({ compare_item: f }, item)` result, parameters and returns).
- **Placeholders.** Lookups take a placeholder argument to return with `:not_found` (`get`, `peek`, `root_item`, `weight_of`).
- **Trait dispatch.** A bracket-typed receiver, and a method whose result mentions a placeholder, are dispatched to the last listed implementation. The graph trait headers name the affected methods. Call the representation module's function of the same name instead.
- **Memory space.** Only `mem(normal)` is supported.
- **Atoms.** Atoms are numbered per compilation unit, so atom-valued paths and error codes are built and decoded inside their module.

## 10. Building new data structures

Each trait impl is a thin forwarder. `OrderedMap@get`, for example, is the whole of this:

```silica
impl fn get(
    map: {
        root: ref?(L, normal, (KeyType, ValueType, int64, ref?(L, normal, rec), ref?(L, normal, rec))),
        compare_key: fn(KeyType, KeyType) -> :less | :equal | :greater,
        compare_value: fn(ValueType, ValueType) -> :less | :equal | :greater,
        region: region(L, normal),
        specialization_key: int64,
        compare_key_ordering_bundle: int64,
        compare_value_ordering_bundle: int64
    },
    key: KeyType,
    placeholder: ValueType
) -> { status: :not_found | :found, value: ValueType } {
    wbt_map@get(map, key, placeholder)
}
```

The work is in the core modules, and their exported functions are building blocks you can compose:

- **`wbt_set` / `wbt_map`:** `empty`, `singleton`, `insert`, `delete`, `delete_min` / `delete_max`, `minimum` / `maximum`, `fold`, `from_sorted`, `size`, and the balancing primitives `smart_node`, `balance_left`, `balance_right`. These give multisets, interval maps (key = interval start, value = end), counters and indexes.
- **`brodal_okasaki` / `brodal_okasaki_priority`:** `push`, `peek`, `pop`, `meld`, `from_list`. Pair one with a `wbt_set` of seen items and you have a deduplicating queue.
- **`skew_ral`:** `prepend`, `head`, `tail`, `lookup` / `update` (physical), `get` / `set` / `append` (logical), `fold_range`, `from_list`. These give indexed sequences and O(1) front and back access.
- **`tree_rose` / `tree_binary`:** `with_root`, `add_leaf`, `find_first`, `child_at`, `node`, `replace_item`, and the folds. These give ordered hierarchies and prefix trees keyed by path.
- **Graph cores:** the families' `add_edge`, `neighbors`, `fold_neighbors`, and `freeze` into CSR.

The rules:

- **Compose before you build nodes.** Recursive tuples in regions are for structures the existing cores cannot express (§6). A new structure should first be a module over existing cores.
- **Every collection type names its memory space:** `OrderedMap[string, int64, mem(normal)]`, `List[int64, mem(normal)]`.
- **Generic modules follow the witness conventions.** The record that carries `compare_item` (or `compare_key` / `compare_priority`) comes first, because a bare `ItemType` resolves from argument one. A fold's accumulator comes second. Bind a nested generic call to a typed let rather than passing it straight into another qualified call.
- **One trait impl per representation.** Dispatch by bracket receiver picks the last impl.
- **Keep the representation record inside the module.** Update results must be bound with the core's inline record (D6 above). That layout is private to one compiler version, so spell it in the one module that builds the structure, and export functions typed with the short bracket type.
- **One collection per exported value, for now.** A record or tuple holding two collections, returned from one module and passed back into it, arrives corrupted in the current compiler: the fields read as garbage. Keep such composites inside one module.

### Example: a word multiset over `wbt_map`

A multiset counts occurrences. It is a `wbt_map` from word to count. Every update is two core calls, a `get` and an `insert` or `delete`, and every value is persistent.

`word_bag.silica` uses the map core and its trait, and exports six operations:

```silica
use wbt_map;
use OrderedMap;
export empty_bag/0;
export add/2;
export remove_one/2;
export count/2;
export distinct/1;
export total/1;
```

The map orders words alphabetically:

```silica
fn compare_words(a: string, b: string) -> :less | :equal | :greater {
    case a < b of {
        true -> :less;
        false -> case a == b of {
            true -> :equal;
            false -> :greater
        }
    }
}
```

It also needs a comparator for its values, the counts:

```silica
fn compare_counts(a: int64, b: int64) -> :less | :equal | :greater {
    case a < b of {
        true -> :less;
        false -> case a == b of {
            true -> :equal;
            false -> :greater
        }
    }
}
```

`empty_bag` is the map constructor. Its result is the one update result that may be bound with the bracket type:

```silica
fn empty_bag() -> OrderedMap[string, int64, mem(normal)] {
    wbt_map@empty({ compare_key: compare_words, compare_value: compare_counts })
}
```

`count` reads through the trait. `0` is the placeholder returned for an absent word:

```silica
fn count(bag: OrderedMap[string, int64, mem(normal)], word: string) -> int64 {
    found: { status: :not_found | :found, value: int64 } <- OrderedMap@get(bag, word, 0);
    found.value
}
```

`store` and `drop` are the only functions that spell the representation record, because `insert` and `delete` return it inside their result records:

```silica
fn store(bag: OrderedMap[string, int64, mem(normal)], word: string, n: int64) -> OrderedMap[string, int64, mem(normal)] {
    updated: { map: { root: ref?(L, normal, (string, int64, int64, ref?(L, normal, rec), ref?(L, normal, rec))), compare_key: fn(string, string) -> :less | :equal | :greater, compare_value: fn(int64, int64) -> :less | :equal | :greater, region: region(L, normal), specialization_key: int64, compare_key_ordering_bundle: int64, compare_value_ordering_bundle: int64 }, inserted: boolean, replaced: boolean } <- wbt_map@insert(bag, word, n);
    updated.map
}
```

```silica
fn drop(bag: OrderedMap[string, int64, mem(normal)], word: string) -> OrderedMap[string, int64, mem(normal)] {
    updated: { map: { root: ref?(L, normal, (string, int64, int64, ref?(L, normal, rec), ref?(L, normal, rec))), compare_key: fn(string, string) -> :less | :equal | :greater, compare_value: fn(int64, int64) -> :less | :equal | :greater, region: region(L, normal), specialization_key: int64, compare_key_ordering_bundle: int64, compare_value_ordering_bundle: int64 }, removed: boolean } <- wbt_map@delete(bag, word);
    updated.map
}
```

`add` and `remove_one` are the multiset operations:

```silica
fn add(bag: OrderedMap[string, int64, mem(normal)], word: string) -> OrderedMap[string, int64, mem(normal)] {
    n: int64 <- count(bag, word);
    store(bag, word, n + 1)
}
```

```silica
fn remove_one(bag: OrderedMap[string, int64, mem(normal)], word: string) -> OrderedMap[string, int64, mem(normal)] {
    n: int64 <- count(bag, word);
    case n <= 1 of {
        true -> drop(bag, word);
        false -> store(bag, word, n - 1)
    }
}
```

`distinct` is the map's cached size, `O(1)`:

```silica
fn distinct(bag: OrderedMap[string, int64, mem(normal)]) -> int64 {
    OrderedMap@size(bag)
}
```

`total` folds the counts. The fold step's argument order is `(accumulator, key, value)`:

```silica
fn add_count(acc: int64, word: string, n: int64) -> int64 {
    acc + n
}
```

```silica
fn total(bag: OrderedMap[string, int64, mem(normal)]) -> int64 {
    OrderedMap@fold(bag, 0, add_count)
}
```

A caller sees only `OrderedMap[string, int64, mem(normal)]`. This `main` exercises the module directly: it is a test of a data structure, not an application (§12 shows the application shape). It begins with the two `use` lines that make `word_bag@...` and `OrderedMap@...` calls legal in this file (a qualified call without its `use` is E1010):

```silica
use word_bag;
use OrderedMap;
```

It uses one small printing helper:

```silica
fn show(label: string, n: int64) -> atom {
    sequence proc[device_io]
        print_string(label);
        _: atom <- print_int64(n);
        println("")
    produces
        pure :ok
    end
}
```

and then:

```silica
fn main() -> int64 {
    sequence
        b0: OrderedMap[string, int64, mem(normal)] <- word_bag@empty_bag();
        b1: OrderedMap[string, int64, mem(normal)] <- word_bag@add(b0, "the");
        b2: OrderedMap[string, int64, mem(normal)] <- word_bag@add(b1, "calf");
        b3: OrderedMap[string, int64, mem(normal)] <- word_bag@add(b2, "the");
        _: atom <- show("the: ", word_bag@count(b3, "the"));
        _: atom <- show("distinct: ", word_bag@distinct(b3));
        _: atom <- show("total: ", word_bag@total(b3));
        b4: OrderedMap[string, int64, mem(normal)] <- word_bag@remove_one(b3, "calf");
        _: atom <- show("distinct after removing calf: ", word_bag@distinct(b4));
        show("the, in the older bag b1: ", word_bag@count(b1, "the"))
    produces
        pure 0
    end
}
```

Compiled with `stdlib/data_structures/wbt_map.silica` and `OrderedMap.silica` listed before `word_bag.silica` in `silica.config`, it prints:

```
the: 2
distinct: 2
total: 3
distinct after removing calf: 1
the, in the older bag b1: 1
```

The last line is persistence at work. `b1`, the bag from before the second `"the"` was added, still counts one.

## 11. Regions

Allocation is not `malloc`, and it is not “the Python heap will get it.” You create a region, then allocate into it. Handles move. A `ref` does not outlive its region. The compiler rejects a `ref` returned without that region: at the end of a sequence the region is freed unless the result still contains the handle. There is no refcounting, no cyclic-GC pause, and no `del`.

To keep a cell after the sequence, produce the region and the `ref` together:

```silica
sequence proc[mem(normal)]
    L1: lifetime <- fresh_lifetime();
    r: region(L1, normal) <- alloc_region(normal);
    cell: ref(L1, normal, int64) <- alloc_ref(r, 42);
    _: atom <- write_ref(cell, 43)
produces
    pure (r, cell)
end
```

`fresh_lifetime()` gives you a unique `L1`. `alloc_region` creates the arena. `alloc_ref` puts a cell in that arena. `write_ref` updates the cell. The effect is `mem(normal)` because that is the space you named. `(r, cell)` keeps the arena alive in the caller; `cell` remains valid because `r` is still owned.

This is rejected with E2100 (reference outlives region) — `cell` would dangle after `r` is freed at `end`:

```silica
sequence proc[mem(normal)]
    L1: lifetime <- fresh_lifetime();
    r: region(L1, normal) <- alloc_region(normal);
    cell: ref(L1, normal, int64) <- alloc_ref(r, 42)
produces
    pure cell
end
```

A value copied out with `read_ref` is an ordinary `int64`, not a `ref`. That copy can be produced without `r`; the region is then freed. That is a different case from returning the cell.

`region(L, Space)` is the arena. `ref(L, Space, T)` is a cell. `buf(L, Space, T, N)` is a fixed buffer. Do not invent two regions that pretend to share `L`. Allocation is only legal inside `sequence … end`.

When a region handle is passed to `spawn` or sent in a `call` / `cast`, ownership moves. After the send, the sender must not use the handle. A reply can move ownership back. That is the same discipline as a function argument that you are not allowed to use after a move.

Memory lives on the actor’s stack, which can grow. Lifetimes follow frames and messages, not a collector. Python objects are shared by default. Silica values are not.

Spaces (`normal`, `normal_writethrough`, `atomic`, `device`, …) are part of the type. Full hardware distinction is for OS-free targets. On a hosted OS the discipline still holds; the attributes are OS-chosen.

Tutorials: [memory region types](https://github.com/yenrab/silica/blob/main/compiler/tutorials_and_howtos/memory_region_types.md), [region handles and references](https://github.com/yenrab/silica/blob/main/compiler/tutorials_and_howtos/region_handles_and_references.md).

Regions: `[memory_region_addition](https://github.com/yenrab/silica/tree/main/trials/memory_region_addition)` (`alloc_region_normal.silica`, `alloc_ref_int64.silica`, `read_ref_int64.silica`, `write_ref_int64.silica`).

## 12. Actors

A well-designed Silica application is a set of actors that pass messages. Functions still do the work *inside* a turn — they are not the shape of the program. If the architecture is only `main` calling helpers calling helpers, you have not yet designed the application.

There is no `actor` keyword. A handler is an ordinary function. `spawn` is what makes it an actor. This is not a thread, not `asyncio`, and not `multiprocessing.Queue`. Isolation is the default. There is no shared object graph and no GIL to reason about.

A **call-only** behavior always replies:

```silica
fn counter(msg: int64, state: int64) -> (:reply, int64, int64) {
    total: int64 <- state + msg;
    (:reply, total, total)
}
```

A **cast-only** behavior never replies:

```silica
fn log(msg: string, state: int64) -> (:no_reply, int64) {
    sequence proc[device_io]
        println(msg)
    produces
        pure (:no_reply, state + 1)
    end
}
```

One behavior is one convention. The compiler tracks call-only versus cast-only on each `actor_ref`, through variables, parameters, results, tuple and record fields, list elements, state and message fields. A cast (`cast`, `cast_registered`) that reaches a call-only actor is error E2237; a call (`call`, `call_registered`) that reaches a cast-only actor is E2238. Where the compiler cannot follow the reference (one returned by `whereis`, a `child` field of a `call_supervisor` reply, a reference in an exit report) the runtime checks the recorded convention before it enqueues anything, and on a mismatch nothing is sent and the sender fails with `:language_error` (in `main`: `language_error` on stderr and exit status 1). You do not write a union of `(:reply, …)` and `(:no_reply, …)` and hope.

Spawning the counter and calling it once:

```silica
fn main() -> int64 {
    sequence proc[concurrency]
        _: atom <- register_failure_reporter(spawn(0, reporter, stack_policy(0, :keep_last_message)));
        a: actor_ref <- spawn(0, counter, stack_policy(0, :keep_last_message));
        n: int64 <- call(a, 3 impl ActorMessage {})
    produces
        pure n
    end
}
```

The first line registers a FailureReporter, the cast-only actor that receives every failure report; `reporter` is the behaviour shown in "Keep `main` small" below. `main` must register one before it starts any actor or supervisor (spec §15.4.13.4), or the compiler rejects the first start with E2236. The reporter's own `spawn`, written as `register_failure_reporter`'s argument (or bound to a name the same function then registers), is the one start allowed before registration.

`spawn(0, counter, stack_policy(0, :keep_last_message))` starts an actor whose state is `0`. Every spawn form takes a stack policy (spec §15.1.2.2): the reservation in bytes (`0` takes the default, the machine's memory plus swap) and a release algorithm (`:keep_last_message` keeps what the last message used). `call` sends `3` and waits for the reply. Messages need `ActorMessage`, usually written `expr impl ActorMessage {}` at the send site.

The runtime model is Erlang `gen_server`, not a user-level receive loop:

1. The runtime receives a message.
2. Your function runs once, with that message and the current state.
3. You return `(:reply, Reply, State)` or `(:no_reply, State)`.
4. The runtime stores the new state and waits for the next message.

`call` blocks for `Reply`. `cast` does not. A call (or cast) to an actor that has ended raises `actor_not_found` in the sender: a supervised sender fails and is restarted, and `main` ends the program. If the target dies with outstanding `call`s, those callers get the same result. A restarted actor does not inherit the failed actor’s mailbox.

Every actor has a 64-bit **identity**, fixed for its life and never reused: the high 32 bits are the position of the spawner that numbered it (`main` is position 0, root supervisors take 1, 2, … in start order) and the low 32 bits are the number that spawner gave it, counting up from 0. `actor_id(ref)` returns it as a `uint64`. It is conventionally printed as `<position.child>`, and the failure banner prints it as one decimal number (`4294967296` is `<1.0>`). `==`, `!=`, `<`, `<=`, `>` and `>=` compare references by identity, as the pair (position, child number). A restarted child gets the spawner’s next number, so it is a new actor: its reference never equals the old one, and compares greater. A reference to an ended actor never equals a live one. A name is only a lookup; it follows a restarted child to its new identity (trial `supervisors_addition/identity_restart`).

Supervisors are a different handle (`supervisor_ref`). You maintain them with `call_supervisor`, not ordinary `call` / `cast`. See the [supervisors tutorial](https://github.com/yenrab/silica/blob/main/compiler/tutorials_and_howtos/supervisors_and_failure_reporter_tutorial.md).

### Keep `main` small

Well designed Silica applications have a very small `main` function consisting of a sequence that registers a FailureReporter, launches a supervisor and makes any initialization calls needed. The last line in `main`'s sequence is almost always `wait_for_exit()`.

That is an architectural rule, not a style preference, and the reason is in the runtime model. `main` is not an actor (spec §15.1.2.2, "The main Function"). It runs on the platform's ordinary program stack, with no growth and no release, and nothing supervises it.

So a failure in `main` ends the process. Exhausting its stack is a fatal fault: the `[silica] fault at …` report and exit status 70 (§15.4.5.5). A pattern-match or arithmetic failure raised in `main` prints `case_clause` or `badarith` and exits with status 1.

The same failures inside a supervised actor are contained. The actor's stack is runtime-managed and grows on demand, the failure goes to its supervisor, and the supervisor restarts it. So the work belongs in actors under a supervisor. `main` only starts the tree, sends whatever initialization messages the application needs, and blocks in `wait_for_exit()` while the actors run. The compiler itself is written this way.

Here is the shape with one supervised worker. The worker, `logger.silica`, numbers each line it is sent and prints it:

```silica
export log/2;

fn log(msg: string, state: int64) -> (:no_reply, int64) {
    sequence proc[device_io]
        _: atom <- print_int64(state + 1);
        println(concat(": ", msg))
    produces
        pure (:no_reply, state + 1)
    end
}
```

`main.silica` names the modules it uses and the supervisor it defines:

```silica
use Supervisor;
use logger;

impl AppSupervisor for Supervisor;
```

`init` is the supervisor's child table: the restart policy, then one child, the logger. Its long return type is the `Supervisor` trait's contract, written once:

```silica
fn init(initial_state: int64) -> (
    {
        strategy: :one_for_one | :one_for_all | :rest_for_one,
        allowed_restart_count: int64,
        restarts_time_frame: int64
    },
    List[
        {
            id: atom,
            agent_type: :worker | :supervisor,
            initial_state: int64,
            behavior: fn(msg: string, state: int64) -> (:no_reply, int64),
            restart: :permanent | :temporary | :transient,
            shutdown: int64,
            flavor: :plain | :dangerous
        },
        mem(normal)
    ]
) {
    sequence proc[mem(normal)]
        flags: {
            strategy: :one_for_one | :one_for_all | :rest_for_one,
            allowed_restart_count: int64,
            restarts_time_frame: int64
        } <- { strategy: :one_for_one, allowed_restart_count: 3, restarts_time_frame: 5 };
        children: List[
            {
                id: atom,
                agent_type: :worker | :supervisor,
                initial_state: int64,
                behavior: fn(msg: string, state: int64) -> (:no_reply, int64),
                restart: :permanent | :temporary | :transient,
                shutdown: int64,
                flavor: :plain | :dangerous
            },
            mem(normal)
        ] <- [
            {
                id: :log,
                agent_type: :worker,
                initial_state: 0,
                behavior: logger@log,
                restart: :permanent,
                shutdown: 0,
                flavor: :plain
            }
        ]
    produces
        pure (flags, children)
    end
}
```

Before it starts anything, `main` registers a FailureReporter (spec §15.4.13.4). Every failure report goes to it, the root supervisor's own included; once a reporter is registered the runtime hands it each report instead of writing the report to stderr itself. `main` keeps a small stack and only waits, so the reporter is where a failed root supervisor ends the program. The compiler checks the order: a start that can run before `register_failure_reporter`, in `main` or in any function `main` calls, is error E2236. The reporter is an ordinary cast-only actor: its behaviour returns `(:no_reply, state)`, and the runtime casts it each formatted report (a call-only reporter would be sent nothing, and the report would fall back to stderr). This reporter writes each report to stderr and ends the program with status 70, the fault status, when the report is the root supervisor's (it has no supervisor, and its frame `#0` is the runtime's `<unknown behavior>`):

```silica
fn region_dump_limit() -> int64 {
    0
}

fn report_is_from_root_supervisor(report: string) -> boolean {
    no_supervisor: boolean <- contains(report, "supervisor_acb:  0x0\n") or contains(report, "supervisor_acb:  (nil)\n") or contains(report, "supervisor_acb:  0x00000000\n");
    no_supervisor and contains(report, "#0  <unknown behavior>")
}

fn reporter(report: string, state: int64) -> (:no_reply, int64) {
    sequence proc[concurrency, device_io]
        _: atom <- println_stderr(report);
        _: boolean <- case report_is_from_root_supervisor(report) of {
            true -> cast_exit(70);
            false -> true
        }
    produces
        pure (:no_reply, state)
    end
}
```

`region_dump_limit` is part of the `FailureReporter` contract: registration calls it once, and `0` turns region dumps off.

`main` registers the reporter, launches the supervisor, sends one initialization message, and waits:

```silica
fn main() -> int64 {
    sequence proc[concurrency, device_io]
        reporter_ref: actor_ref <- spawn(0, reporter, stack_policy(0, :keep_last_message));
        _: atom <- register_failure_reporter(reporter_ref);
        _: supervisor_ref <- spawn_registered_supervisor(AppSupervisor, 0, :app_supervisor, stack_policy(0, :keep_last_message));
        _: boolean <- cast_registered(:log, "service started" impl ActorMessage {});
        _: int64 <- wait_for_exit()
    produces
        pure 0
    end
}
```

Compiled with the standard-library `Supervisor.silica`, it prints `1: service started` and keeps running until standard input delivers `exit`. `init` is the supervisor's child table; everything after the supervisor's start is initialization and waiting.

### Ending the program, and ending a supervisor

`wait_for_exit()` returns when it is told to, and `main` then returns and the program ends (running dispatches are abandoned, mailboxes are discarded). It is told to in two ways:

- A line that reads exactly `exit` on standard input is recorded as `cast_exit(0)`, so it makes `wait_for_exit()` return 0 (and a later `cast_exit` returns `false`). Any other line is ignored. If standard input reaches its end, the wait goes on: the end of input does not end it. (Sent immediately, an `exit` line can end the program before the actors have printed anything; the first example in `docs/examples/first_program/` prints nothing if `exit` is piped to it at once.)
- An actor calls `cast_exit(value: int64) -> boolean`, and `wait_for_exit()` returns `value`. The first request wins: `cast_exit` returns `true` when it recorded the request and `false` when an earlier one had already been recorded. It does not wait, so nothing after it in the same dispatch is guaranteed to run; an actor that needs another actor's work finished first uses `call` for that work and issues `cast_exit` after the reply. A batch program (a compiler, a converter) ends itself this way; a server runs until it is stopped from outside.

The FailureReporter above is the usual caller: the report of the root supervisor means nothing is supervising the program any more, so by convention the reporter calls `cast_exit(70)`, the fault status (§15.4.5.5, §15.4.13.4).

A supervisor that ends takes its children with it. It stops them one at a time, last row of its child table first, waiting for each (a child supervisor stops its own children first), then it goes. A child whose `shutdown` is `0` is killed at once and ends with `(:explicit, :killed)`, reason tag 4; a child with `shutdown` above `0` is allowed to finish the message it is handling and ends with `(:explicit, :shutdown)`, reason tag 4. The time limit that a positive `shutdown` names is not enforced yet: nothing preempts a running message. Each stopped child produces a failure report like any other death, and its registered names are freed. A `:temporary` child’s row is removed when it ends; `:permanent` and `:transient` rows stay (trial `supervisors_addition/child_shut_down_with_supervisor`).

A supervisor answers questions about its table through `call_supervisor(sup, { op: :get_child, id: :log } impl SupervisorMessage {})`: the reply is the child that has that id (its `child` reference and a `child_info` record), not the first live child. The trial `supervisors_addition/supervisor_get_child_by_id` shows the reply type.

The other `main` functions in this book are deliberately not in this shape. The one in §2, the tree-node `main` in §6, the `math@add(2, 3)` in §8 and the `spawn` / `call` above each isolate one construct, and a bare `main` is the shortest place to show it. An application's `main` looks like the one here.

### Prefer cast and cast back

The preferred request/response shape between actors is asynchronous: the requester casts a request, carries on, and the responder casts the answer back as a new message. Synchronous `call` is the fallback. This is how people text: few send a message and then do nothing until the reply comes; most send it, do other things, and read the reply when it arrives.

What `call` costs, per the spec:

- **The caller is suspended for the whole round trip.** `call` blocks until the target returns `(:reply, …)`, and it has no timeout: the caller stays blocked until the target replies or ends (§16.1.1). `call_with_timeout` (§16.1.1.2) is the specified way to bound the wait, but it is not implemented yet: no caller can stop waiting for a reply today.
- **Its mailbox is not served meanwhile.** A behaviour runs one message per turn, and the suspended call is inside that turn, so every message queued for the caller waits as well. A caller's latency and throughput are therefore bound by its slowest callee.
- **Waiting can deadlock.** `call(self(), …)` can never be answered, and the specification makes it a compile error (§16.2.6.5); the compiler rejects it with E2240. The compiler cannot see a cycle through other actors either, and with no timeout, actors that `call` each other in a cycle wait until one of them ends.
- **The callee can die.** If the target is dead, or ends before replying, `call` raises `actor_not_found` in the caller (§16.1.1).

What `cast` gives instead: it returns immediately after enqueueing (§16.1.2), and mailboxes are unbounded, so a cast never blocks on capacity (§18.4.1). The answer arrives as an ordinary message that the requester's behaviour handles in its own turn, between whatever else it is doing. Two consequences follow:

- **The requester's one message type carries both its requests' triggers and the answers**, so the behaviour dispatches on the message. Replies must be matched to requests. Include a request id, or the requester's registered name, in the request, and have the responder echo it in the answer.
- **Nothing slows a fast sender.** Unbounded mailboxes mean there is no built-in backpressure. The spec lists `call` as one way to slow a producer, beside explicit acknowledgements and bounded application queues (§16.2.8).

`call` is still right when the next step genuinely cannot proceed without the answer, and for simple request/response at the edges of a system: a `main` or a test that needs one value, or a producer that must be throttled. BEAM programmers will recognise `gen_server:cast` and `gen_server:call`. One difference: `gen_server:call` has a default timeout of 5000 ms, while Silica's `call` waits indefinitely (`call_with_timeout` is specified but not implemented yet).

An example with two supervised actors. The client asks a translator for words. Each reply echoes the word it answers, which is how the client matches replies to requests. Both actors live in `main.silica`, and their supervisor's `init` lists them with the behaviour type `fn(msg: string, state: int64) -> (:no_reply, int64)`, in the same shape as the logger's.

The client dispatches on the message. A reply contains ` = `; anything else is a word to ask about:

```silica
fn client(msg: string, state: int64) -> (:no_reply, int64) {
    sequence proc[device_io]
        _: atom <- case contains(msg, " = ") of {
            true -> println(concat("reply ", msg));
            false -> request(msg)
        }
    produces
        pure (:no_reply, state)
    end
}
```

`request` casts the word to the translator and returns at once:

```silica
fn request(word: string) -> atom {
    sequence proc[concurrency, device_io]
        _: boolean <- cast_registered(:translator, word impl ActorMessage {});
        println(concat("sent ", word))
    produces
        pure :ok
    end
}
```

The translator casts its answer back to the client as a new message:

```silica
fn translator(msg: string, state: int64) -> (:no_reply, int64) {
    sequence proc[concurrency]
        _: boolean <- cast_registered(:client, spanish(msg) impl ActorMessage {})
    produces
        pure (:no_reply, state + 1)
    end
}
```

`spanish` is the lookup:

```silica
fn spanish(word: string) -> string {
    case word == "hello" of {
        true -> "hello = hola";
        false -> case word == "thanks" of {
            true -> "thanks = gracias";
            false -> "unknown = ?"
        }
    }
}
```

`main` registers the reporter (the one above), starts the supervisor, sends two initialization messages, and waits:

```silica
fn main() -> int64 {
    sequence proc[concurrency, device_io]
        reporter_ref: actor_ref <- spawn(0, reporter, stack_policy(0, :keep_last_message));
        _: atom <- register_failure_reporter(reporter_ref);
        _: supervisor_ref <- spawn_registered_supervisor(AppSupervisor, 0, :app_supervisor, stack_policy(0, :keep_last_message));
        _: boolean <- cast_registered(:client, "hello" impl ActorMessage {});
        _: boolean <- cast_registered(:client, "thanks" impl ActorMessage {});
        _: int64 <- wait_for_exit()
    produces
        pure 0
    end
}
```

It prints:

```
sent hello
sent thanks
reply hello = hola
reply thanks = gracias
```

Both requests are in flight before either answer is handled; the client never blocks. The replies here are string literals to keep the example short. The general form carries a record such as `{ kind: atom, reply_to: atom, id: int64, value: int64 }` and replies with `cast_registered(msg.reply_to, …)`; a record message cast between actors arrives intact (trial `supervisors_addition/record_message_cast_between_actors`).

`spawn` has variants for pinning, registration, device workers, and FFI workers. Migration strategy (`lazy`, `eager_copy`, `static_core`) is about how much stack one message uses and how often the actor moves, not about “how long the actor lives.” [Spawning tutorial](https://github.com/yenrab/silica/blob/main/compiler/tutorials_and_howtos/actor_spawning_tutorial.md).

Actors: `[actors_addition](https://github.com/yenrab/silica/tree/main/trials/actors_addition)` (`actor_boolean_state_reply.silica`, `actor_cast_fire_and_forget.silica`). Supervisors: `[supervisors_addition](https://github.com/yenrab/silica/tree/main/trials/supervisors_addition)`. Pinning: `[cpu_discovery_and_spawn_pinning](https://github.com/yenrab/silica/tree/main/trials/cpu_discovery_and_spawn_pinning)`.

## 13. Fifi

Fifi is outbound FFI: the way a Silica program calls C or anything with a C ABI. Non-Silica code is outside Silica’s memory and type guarantees. This is not `ctypes`, not `cffi`, and not `subprocess` dressed up as a function.

The rules that matter in practice:

- **Wrapper-first.** You do not call C as if it were Silica. Python C-API extensions are in-process and silent. Fifi is neither.
- **Names carry the risk.** Modules that wrap foreign code, or that `use` such a module, take a `dangerous_` name.
- **The name walks up.** That obligation continues to the application root. Pure Silica stays visibly pure at the module and artifact level.
- **Foreign calls run in an FFI worker.** `spawn_dangerous` installs the worker. The worker’s sequence admits `external_danger`. Callers at the spawn site do not get that effect.
- **Device MMIO is a different door.** `spawn_device` / `register_rwr`, not Fifi.

The audit story is `grep dangerous_`. Mixed artifacts advertise themselves. You should not need a linker map or tribal knowledge to see that a release is no longer pure Silica.

Read: [designing apps with foreign functions](https://github.com/yenrab/silica/blob/main/compiler/tutorials_and_howtos/designing_apps_with_foreign_functions.md), [FFI wrapper spec](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica_ffi_wrapper_specification.md), [dangerous FFI model](https://github.com/yenrab/silica/blob/main/compiler/design_documents/dangerous_ffi_security_model.md).

A proposed alternative to in-process FFI is [brokered IPC](https://github.com/yenrab/silica/blob/main/compiler/design_documents/brokered_ipc_isolation_architecture.md): keep the unsafe work out of process so the safe application does not load it at all.

FFI trials: `[ffi_addition](https://github.com/yenrab/silica/tree/main/trials/ffi_addition)`. Compile-fail goldens for the taint rules: `[error_enforcement_addition](https://github.com/yenrab/silica/tree/main/trials/error_enforcement_addition)`.

## 14. What the compiler rejects

Silica would rather stop you than “optimize away” a mistake or wait for a test to notice it. These are hard errors, not warnings you can train yourself to ignore, and not Python’s “run it and see”:

- **Dead bindings** — a name you bound and never used.
- **Duplicate work** — the same computation written twice when once would do.
- **Redundant arithmetic** — additions of zero, multiplications by one, and similar noise.
- **Loop-invariant mistakes** — the recursive equivalent of “this does not change in the loop.”
- **Missing effects** — a print, allocate, or send without the matching `proc[…]`; and the reverse, an effect a sequence declares that none of its own steps needs (E3010).
- **A start before the FailureReporter** — in `main`, or in any function `main` calls, an actor or supervisor that can start before `register_failure_reporter` runs (E2236). The reporter’s own `spawn` is the one start allowed first.
- **Non-exhaustive** `case` — a value that no arm covers.
- **Untyped** `_` — a catch-all that does not name the leftover type.
- `if` **used as a statement** — use `case`.
- **Nested** `fn` **declarations** — helpers go at the top level, or use a lambda.
- **More than eight parameters** — group them.
- `call` **/** `cast` **convention mismatch** — a cast that reaches a call-only actor (E2237), or a call that reaches a cast-only one (E2238).
- **Function literals without `-> type`** (E1071), and nothing is inferred in their place.
- **Function literals that capture anything but an integer-literal binding** (E1072): pass the value as an argument instead.
- **Region, lifetime, or isolation violations** — a `ref` returned without its region, a ref that outlives its region, a handle used after a move.
- `dangerous_` **taint that was not declared** — a foreign dependency that did not walk up the module graph.

Diagnostics carry a code (`E2000`, …), a location, and a spec section. Read the human sentence first, then the location, then the `See specification` pointer. See spec §1.6 and [additional compiler rules](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica-specification-additional.md).

Programs the compiler is supposed to refuse: `[error_enforcement_addition](https://github.com/yenrab/silica/tree/main/trials/error_enforcement_addition)`, `[warning_enforcement_addition](https://github.com/yenrab/silica/tree/main/trials/warning_enforcement_addition)`.

## 15. Running on the ESP32-S3 board

The same programs run on an ESP32-S3 board with no operating system, compiled by the cross compiler `binaries/silica-compiler-ESP32-S3_raw`. The board pack lives in `compiler/src/emitter/ESP32-S3_raw/board/`; its README describes the console protocol, the stack budget and every tool. The sample apps are under `board/apps/`: `silica_00_return42` through `silica_22_device_buzzer` (arithmetic, strings, lists, regions, floats, the stdlib `wbt_map`, and device drivers written in Silica for the UART, GPIO, the ST7789 display, the 24-LED row, the buzzer and the buttons), plus the `asm_*` bring-up programs in assembly. Most `silica_16` and later apps drive LEDs, the display or the buzzer, so run them while watching the board.

One command builds an app in a temporary directory, loads it into the board’s RAM (nothing is written to flash unless you pass `--flash`) and compares the console output with the app’s `expected.scout`:

```sh
B=compiler/src/emitter/ESP32-S3_raw/board
$B/tools/run_app.sh silica_04_print
$B/tools/run_app.sh --build-only silica_14_wbt_map        # image only, the board is not touched
$B/tools/run_app.sh --send 'exit\n' --send-delay 65 --timeout 120 silica_20_device_buttons_led
```

It needs the Xtensa toolchain and the ESP-IDF Python environment (esptool, pyserial) from [Required software]({{ '/required-software/' | relative_url }}); `BOARD_PYTHON`, `XTENSA_BIN`, `ESPTOOL` and `BOARD_PORT` point it elsewhere, and `SILICA_COMPILER` names the cross compiler. `run_app.sh --help` lists every option and exit status. Programs follow the same small-`main` shape as on the hosts: the board has one console, so the FailureReporter’s report appears in the program output, `exit` typed (or `--send`) on the console ends a waiting `main`, and a fault ends the program with status 70 and a runtime abort with 71.

Actors run on both LX7 cores, one cooperative scheduler per core, and an actor’s stack is a chain of heap chunks that grows on demand. The design target is 1,000 actors and supervisors on the board, against millions on a hosted machine ([actor memory budget plan](https://github.com/yenrab/silica/blob/main/compiler/design_documents/actor_memory_budget_plan.md)); [the port status](https://github.com/yenrab/silica/blob/main/compiler/design_documents/ports/esp32s3_port_status.md) lists what is verified on the board and where it differs from the hosts.

## 16. Next

Read the trials when you want a small program in hand. Read the specification when you want the rule. The tutorials are the middle ground for actors, regions, and FFI.

- [trials](https://github.com/yenrab/silica/tree/main/trials) — simple programs, grouped by topic. Run one directory with `make -C trials/<name> integrate`.
- [Language specification](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica-specification.md)
- [Tutorials](https://github.com/yenrab/silica/tree/main/compiler/tutorials_and_howtos)
- [Build and test the compiler]({{ '/build-and-test/' | relative_url }})
- [Participate]({{ '/participate/' | relative_url }})
- [Learn to Program]({{ '/learn-programming/' | relative_url }}) — same language, slower on-ramp

*End of Silica for Programmers.*

Copyright © 2026 Lee Scott Barney