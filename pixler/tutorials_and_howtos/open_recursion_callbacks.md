# Open Recursion with Callbacks

When you split a recursive algorithm across several Silica **compilation units** (separate `.silica` files / modules), the natural shape is often a cycle: the dispatcher calls a specialist, and the specialist needs to call back into the dispatcher for nested work. Silica’s `use` graph is **acyclic**, so that shape cannot be expressed with mutual `use`.

**Open recursion** is the pattern that keeps the modules acyclic: the parent passes the recursive entry point in as a **function argument** (a callback). Children call the callback instead of `use`ing the parent. In Silica this means **lambda / function capture**, not OO-style recursion through `self` / `this`—see [compiling_with_less_ram.md](./compiling_with_less_ram.md) for that definition in the context of compile-time memory.

---



## When It Is Needed

You need open recursion when **all** of the following are true:

1. **Work is recursive** — checking, emitting, or transforming a tree/AST where a node’s children are the same kind of value as the root.
2. **The algorithm is split across modules** — for size, clarity, or process-per-unit memory reclaim (one unit per process).
3. **A leaf module must recurse** — it cannot finish its job without evaluating, type-checking, or emitting a child subtree.
4. **A** `use` **cycle would appear** — e.g. `facade` uses `binary_ops`, and `binary_ops` would need to `use facade` to call `eval` / `check` / `emit` again.

If the leaf never needs to recurse (pure helpers, string utilities, table lookups), you do **not** need this pattern. Ordinary `use` and `module@fn` calls are enough.

### What does *not* solve this


| Approach                                               | Why it fails here                                         |
| ------------------------------------------------------ | --------------------------------------------------------- |
| Mutual `use`                                           | Forbidden / unsupported; module graph must stay a DAG     |
| Putting everything in one file                         | Works, but recreates a monolith that can be unsupportable |
| Duplicating the whole recursive function in every leaf | Diverges quickly; duplicates policy and bug fixes         |


---



## Analogy: The Switchboard

Think of a **hotel switchboard**.

- Guests (leaf modules) must not dial each other through a tangle of private lines that loop forever.
- Instead, each guest phone has a single button: **“Operator.”**
- When a guest needs something that only the front desk can route (another room, outside line, wake-up call), they press Operator.
- The front desk (facade) already knows how to route every kind of request. It may immediately send the call to another specialist room — and that room again only has the Operator button for further routing.

The Operator button is the **callback**. The guest never needs a directory of the whole hotel (`use facade`). The front desk **installs** the Operator connection when it transfers the call into that room (passes the callback as an argument).

```text
                    ┌──────────────┐
                    │   Facade     │  defines eval / check / emit
                    │  (operator)  │
                    └──────┬───────┘
           passes callback │
                           ▼
                    ┌──────────────┐
                    │ Leaf module  │  calls callback(child)
                    │  (guest)     │  — no `use` of facade
                    └──────────────┘
```

---



## A Tiny Example

We evaluate a toy arithmetic expression tree. Kinds:

- `0` — integer literal (`value` holds the number as a string we parse simply)
- `1` — addition: `inner` and `right_expr` are child indices (same shape as the compiler’s arena idea, but miniaturized)



### Facade: dispatch + recursion root

```silica
// eval_facade.silica
use eval_add;

export eval/1;

fn eval(e: { kind: int64, value: string, left: { kind: int64, value: string, left: rec, right: rec } | :none, right: { kind: int64, value: string, left: rec, right: rec } | :none }) -> int64 {
    case e.kind of {
        0 -> string_to_int64(e.value);
        1 -> eval_add@eval_add_node(e, eval);
        _: int64 -> 0
    }
}

fn string_to_int64(s: string) -> int64 {
    // toy: only single-digit for brevity
    case s of {
        "0" -> 0;
        "1" -> 1;
        "2" -> 2;
        "3" -> 3;
        "4" -> 4;
        "5" -> 5;
        "6" -> 6;
        "7" -> 7;
        "8" -> 8;
        "9" -> 9;
        _: string -> 0
    }
}
```

`eval` is the Operator. For addition it calls into `eval_add`, **handing** `eval` **itself** as the callback.

### Leaf: addition specialist (no `use eval_facade`)

```silica
// eval_add.silica
// Intentionally does NOT `use eval_facade` — that would cycle.

export eval_add_node/2;

fn eval_add_node(
    e: { kind: int64, value: string, left: { kind: int64, value: string, left: rec, right: rec } | :none, right: { kind: int64, value: string, left: rec, right: rec } | :none },
    eval_child: fn({ kind: int64, value: string, left: { kind: int64, value: string, left: rec, right: rec } | :none, right: { kind: int64, value: string, left: rec, right: rec } | :none }) -> int64
) -> int64 {
    case e.left of {
        :none -> 0;
        left_e: { kind: int64, value: string, left: { kind: int64, value: string, left: rec, right: rec } | :none, right: { kind: int64, value: string, left: rec, right: rec } | :none } -> case e.right of {
            :none -> 0;
            right_e: { kind: int64, value: string, left: { kind: int64, value: string, left: rec, right: rec } | :none, right: { kind: int64, value: string, left: rec, right: rec } | :none } ->
                eval_child(left_e) + eval_child(right_e)
        }
    }
}
```

Nested adds work because `eval_child` is the facade’s `eval`: another `kind == 1` child goes back through the switchboard and may re-enter `eval_add_node` with the **same** callback.

### Module graph (acyclic)

```text
eval_facade  ──use──►  eval_add
     │                    │
     │ passes eval        │ calls eval_child(...)
     └────────────────────┘
         (callback edge — not a `use`)
```

---



## Checklist

**Do**

- Keep a **thin facade** that owns the recursive entry point(s).
- Pass **only the callbacks the leaf needs** (often one “typed” and one “surface” style entry, or a small record of them).
- Qualify leaf helpers with `module@fn` from the facade; leave recursion as parameters.
- Prefer a **DAG** of `use`: helpers → specialists → facade (facade at the top).

**Don’t**

- `use` the facade from a leaf that the facade already `use`s.
- Re-export huge APIs just so a sibling can recurse — that fattens every unit’s interface.
- Inject fat callback types into helpers that never recurse (keeps signatures smaller and avoids AArch64’s 8-argument limit pressure).

---



## Naming Tips


| Role                            | Typical names                                              |
| ------------------------------- | ---------------------------------------------------------- |
| Facade entry                    | `eval`, `check_expr`, `emit_term`                          |
| Callback params in leaves       | `eval_child`, `check_typed`, `check_surface`, `emit_child` |
| Leaf entry that takes callbacks | `eval_add_node`, `check_binary_op`, `emit_kind_compound`   |


The callback parameter is ordinary data: a function value. Open recursion is just **who installs that value** (the parent) versus **who calls it** (the child).

---



## Summary

Open recursion splits recursive algorithms across compilation units **without circular** `use`. The facade defines the recursive function and passes it (or a small bundle of related functions) into leaf units. Leaves call the callback for children; they never import the facade. Same idea as a switchboard: guests only press Operator; the operator already knows the whole building.

If the facade itself is the unit that runs out of memory while compiling — because it `use`s every leaf at once — put two or three thin dispatchers under it: [thin_dispatchers_for_compile_ram.md](./thin_dispatchers_for_compile_ram.md).