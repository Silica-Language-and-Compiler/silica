---
title: Silica's Design Principles
layout: default
permalink: /design-principles/
---

# Silica's Design Principles

These principles are the choices Silica is built around. They decide how the language looks, what the compiler will accept, and how programs run.

The [language specification](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica-specification.md) is the normative source (§1.2 and §1.3). This page is the reader-facing statement of the same list.

[Back to Silica]({% link index.md %})

## 1. Explicit effects

All side effects are tracked in type signatures.

Mutation, I/O, concurrency, and other observable behavior are not inferred from names or comments. They are declared on the sequence that performs them, checked, and visible where the work is written. Effects are local: calling a function does not add that function’s effects to the caller, because the callee’s own sequence declares and discharges them.

**Benefit:** Reviews and tools see the same contract. Observable behavior is checked, not guessed from names.

## 2. Process monad

Sequential computations are represented as monadic processes.

Pure functions stay ordinary functional code. Effectful work is a `proc[…]` — a sequenced computation whose effects are part of its type, not hidden control flow.

**Benefit:** Pure code stays simple. Effectful work cannot hide inside an ordinary function type.

## 3. Actor-based concurrency

Message passing is the primary concurrency mechanism.

Actors are isolated. They communicate by `call` and `cast`, not by sharing mutable memory. Isolation is the default; sharing is a deliberate, typed exception.

**Benefit:** Races and shared-memory bugs are not the ordinary path. Isolation is the default; sharing has to be typed and deliberate.

## 4. Region-based memory

Memory is managed with regions, not a garbage collector.

Ownership and lifetimes are static. There is no shared heap for ordinary long-lived data. Storage follows actor stacks and region handles, so typical heap mistakes never become runnable code.

**Benefit:** Use-after-free, double-free, and leaks of that kind never become runnable code, and there is no garbage collector in the way.

## 5. References stay with their region

A memory reference is never separated from the region that contains the memory it refers to.

A `ref` or `buf` carries the region’s lifetime in its type (`ref(L, Space, T)`). The type checker refuses values that would detach a reference from that region or let it outlive the region. When a region handle moves — into a function, a `spawn`, or a message — the references and buffers tied to it move with that ownership story.

**Benefit:** A dangling pointer is not a representable value. If you have a reference, its region is still there.

## 6. Heap is an effect

Allocating or growing region-backed storage is an effect, and it is treated like any other effect.

Constructing a region, a reference, a buffer, or a growing list is not an invisible runtime service. It happens under an explicit `mem(<space>)` on a `sequence` — for example `sequence proc[mem(normal)]` — the same way I/O happens under `device_io`. The sequence that allocates carries the obligation; a caller of a function that allocates does not repeat it. Pure functions do not allocate.

**Benefit:** Allocation is visible in the type, so “this just computes a value” cannot quietly grow memory. Reviews and tools see the same `mem(…)` contract they see for I/O.

## 7. Designed for modern chips

First-class support for what current hardware actually exposes.

Silica is designed for the chips you can buy and program today — AArch64, RISC-V, x86-64, and the boards that follow — not for a portable 1970s machine model. Memory spaces, vector units, hardware memory tagging, and pointer integrity are part of the language story wherever the core provides them, not after-the-fact backends bolted onto a lowest-common-denominator ISA. AArch64’s NEON/SVE, MTE, and PAC are examples of that class of feature, not the limit of the model.

**Benefit:** What you write can use the hardware you actually have, instead of a lowest-common-denominator machine model.

## 8. LLM-friendly and human-readable

Syntax and semantics are meant to be easy for people to read and for tools — including large language models — to parse without guesswork.

That means one way to do each job at the language level, no type aliases, explicit type annotations, consistent naming, and clear structural patterns. The rest of this page is the expansion of this principle.

### 8.1 One way at the language level

Each job has one language-level construct. Programs are built by putting those constructs together.

There is not a menu of loops, a menu of type-parameter styles, or a menu of operators that all mean “bind.” There is recursion, traits over concrete types, and one operator per job. Composition is where variety lives: you combine the same pieces in many shapes.

**Benefit:** People and LLMs choose among compositions, not among competing primitives for the same job. Generation has fewer forks that all look almost right.

#### 8.1.1 No loops

Source code uses recursion only. The runtime may loop internally.

You write recursive functions and use map, filter, and folds instead of `for` or `while` loops.

**Benefit:** Control flow stays in one recursive form that people and tools can follow.

#### 8.1.2 No generics

Polymorphism is achieved through traits, not generic type parameters.

There is no `Option<T>` or `Result<T, E>`. Shared operations live on traits implemented for concrete, inline types. Every type occurrence in source is syntactically concrete.

**Benefit:** Every type in source is concrete. There is no generic-inference puzzle for compilers, LLMs, or for readers.

#### 8.1.3 Unambiguous syntax

Different operations use different operators:

- `<-` for binding (left-to-right flow)
- `=` for equality comparison, and for bindings only where the grammar already allows it — not for declaring named types
- `->` for function types and case branches

Effect declarations sit on sequences: `sequence proc[device_io, concurrency]`.

Blocks have distinct delimiters: `sequence … produces pure … end` for sequences, `{ … }` for case expressions.

**Benefit:** Structure is obvious. Parsers and readers do not have to disambiguate overloaded punctuation.

### 8.2 Explicit type annotations

Function parameters and return types are always written out:

```silica
fn add(x: int64, y: int64) -> int64
```

Variable bindings carry their type:

```silica
value: int64 <- 42
```

Pattern matching uses typed patterns:

```silica
case x of { n: int64 -> n * 2 }
```

Catch-all patterns must declare a type: `_: int64 -> 0`, not `_ -> 0`.

**Benefit:** Types are unambiguous for tools and immediately visible to people.

### 8.3 Consistent naming conventions

Built-in types (`int64`, `string`, `List[…]`, and the rest) use the spellings in the specification. Composite types are structural and written inline; they are not introduced as new type names.

Functions and variables use `snake_case`: `add_numbers`, `my_value`.

Keywords are lowercase: `fn`, `struct`, `trait`, `impl`.

**Benefit:** Predictable patterns that both people and models can apply consistently.

### 8.4 Concrete types over generics

This is the readable-surface statement of [no generics](#no-generics).

Silica has no generic type parameters. There is no `Option<T>` or `Result<T, E>` in the type system.

Optional and fallible values are ordinary sum types (tagged unions) with concrete payloads written inline wherever a type is required, for example `Some(int64) | None` or `Ok(int64) | Error(string)`.

There are no user-declared type names. The same inline sum shapes appear in application code and in library APIs.

Traits such as `OptionLike` and `ResultLike` supply shared operations by implementing them for specific inline type expressions, without introducing generics.

**Benefit:** Every type in source is concrete. There is no generic-inference puzzle for tools or for readers.

### 8.5 Structured pattern matching

Patterns carry types: `n: int64 if n > 0 -> …`.

Catch-alls require a declared type: `_: int64 -> 0`.

Guards are separated from the pattern: `pattern if condition -> expression`.

The compiler checks that every case is covered.

**Benefit:** Control flow is explicit enough to analyze, and complete enough to verify.

### 8.6 Explicit effect tracking

Side effects are declared on sequence blocks:

```silica
sequence proc[device_io, mem(normal)]
```

Function declarations do not carry effect declarations. Effects appear only on sequences, and each sequence declares exactly what its own steps do; one that declares more is refused. Heap is one of those effects ([principle 6](#heap-is-an-effect)).

**Benefit:** Observable behavior is visible to people and to tools, so analysis does not depend on naming conventions.

### 8.7 Module and import clarity

Modules and imports are explicit: `use calculator;`.

Exports are declared: `export add/2;`.

Module structure matches file structure.

**Benefit:** Dependencies are named and traceable. Cross-module calls say which module they use.

### 8.8 No aliases

There are no type aliases and no user-declared type names. You write the shape at the use site.

There is no `type UserId = int64` and no chain of synonyms that hide a record or a sum behind another name. A reader or a model that sees `{ width: int64, height: int64 }` or `Some(int64) | None` is looking at the type, not at a name that has to be unfolded through a definition set.

**Benefit:** People and LLMs do not get lost in deep or circular alias graphs. The type in source is the type that is meant.

---

See the [language specification](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica-specification.md) for the full rules these principles imply.

[Back to Silica]({% link index.md %})