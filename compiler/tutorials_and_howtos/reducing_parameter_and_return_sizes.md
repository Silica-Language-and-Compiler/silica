# Reducing the size of function parameters and returns

Large types composed of many items and layers are naive and inefficient. A record of twenty fields, a tuple nested five deep, a hand-built list that is searched from the front for one entry: each of these is a design that a first-class data structure does better. Silica's standard library provides those structures (`OrderedMap`, `OrderedSet`, `SearchTree`, `Heap`, `PriorityQueue`, `Tree`, `BinaryTree`, `DirectedGraph`, `UndirectedGraph`, `WeightedGraph`; the designs are in [data_structure_designs/README.md](../design_documents/Phase1_TODOs/data_structure_designs/README.md)), and they are the first answer.

This tutorial is for the few cases where a structure does not fit: the data has no key, no order, no priority and no shape the structures model, and yet a function signature has grown large. It explains what a large parameter or return costs, points at the code or document behind each claim, and then shows seven techniques, each as a *before* and *after* pair that compiles and runs.

Nothing here is about making a program correct. The *before* programs are correct. They are just larger and slower than they need to be, and harder to read.

---



## When to read this

Read it when one of these is true:

- A function takes a record or tuple with many fields, and most of its body reads two or three of them.
- A function returns the record it was given, with one field changed or one field added.
- The same large inline type is written out at many parameters, returns and bindings.
- A record or tuple is nested several levels deep.
- A module exports several functions whose signatures all repeat one large shape.
- A value that is really "the program's state" is threaded through call after call.

If the data is a collection you look things up in, test membership in, take the most urgent item from, or walk as a hierarchy or a network, stop here and use the matching standard structure (technique 1).

---



## What a large parameter or return costs

### Every field is a slot, and every nested group is its own object

Records and tuples use one uniform boxed layout. The rule is written at the top of the record emitter, [prims_record.silica](../src/emitter/apple_silicon_mac/terms/prims/prims_record.silica):

- every field is one 8-byte slot;
- a scalar field holds its value; a record-, tuple-, list-, string- or function-typed field holds a pointer;
- a nested record or tuple literal is built in its own slab, heap-promoted, and its pointer is stored;
- a nested aggregate variable is copied to the region and its pointer is stored.

So `{ id: int64, customer: { name: string, street: string, city: string }, weight: int64, express: boolean }` is not one object of seven values. It is a four-slot object whose `customer` slot points at a second, three-slot object, whose slots point at three strings. Every level of nesting adds an allocation and a copy when the value is built.

### Aggregates built at a call are copied out of the caller's frame

A record or tuple literal written as an argument is built in the caller's frame. Silica moves values, so the callee may keep the pointer after the caller returns, and the frame would then be gone. The emitter therefore copies the aggregate into the region before the pointer leaves the frame: `arg_aggregate_heap_promote` in [term_aggregate_helpers.silica](../src/emitter/apple_silicon_mac/terms/term_aggregate_helpers.silica), called from `emit_rest_args` in [term_emit_kind_call.silica](../src/emitter/apple_silicon_mac/terms/term_emit_kind_call.silica). The copy is proportional to the aggregate's size.

### Aggregate results come back by pointer, after a copy

A function whose result is a record or a tuple hands back a pointer in `X0`. Before it returns, the callee copies the value into memory the region owns: `aggregate_return_heap_promote_x0` in the same helper file emits a `_silica_rt_region_alloc` of the value's size followed by a word-by-word copy. A function that returns an echo of a six-field input with one field changed pays a six-slot allocation and a six-word copy on every call, and the caller then reads one or two of those words.

### Eight argument registers, then grouping

A function may have at most eight parameters (spec §3.4.1): AArch64 passes arguments in `X0`–`X7`, and Silica keeps every parameter in a register. The spec's advice past eight is to group related parameters in a tuple or record. That is the right move for two or three values that belong together. It is the wrong move for twenty unrelated values, because the group then becomes one of the large boxed objects described above. Past eight, first ask whether the function is doing too much (technique 3) or needs fields it never reads (technique 2).

### Messages are copied

Values sent between actors are copied at send time; sender and receiver are independent (spec §15.4.7.3, and "Isolation: Message contents are copied between actors" in §16.3.5). A large message is copied on every `call` or `cast`. A large reply is copied back.

### At compile time, the shape is spelled at every use

Silica has no type aliases and no user-declared type names (spec §3.4.2). A large shape is written out in full at every parameter, return and binding that mentions it, and the compiler has to read and check each of those spellings. An exported signature that mentions the shape is part of the module's interface, and that interface is loaded by every unit that `use`s the module: "every fat structural signature you export is paid again by every unit that `use`s you" ([compiling_with_less_ram.md](./compiling_with_less_ram.md)); a facade that `use`s many such modules can exhaust RAM on its own ([thin_dispatchers_for_compile_ram.md](./thin_dispatchers_for_compile_ram.md)).

The compiler's own emitter shows the extreme: the signature line of `emit_rest_args` in [term_emit_kind_call.silica](../src/emitter/apple_silicon_mac/terms/term_emit_kind_call.silica) is 6,610 characters long, most of it one literal-pool record type written out twice (once as a parameter, once inside a callback's type). Do not copy that shape into applications.

---



## Technique 1: reach for a first-class data structure

A structure replaces many fields with one handle. The handle's type is short (`PriorityQueue[int64, string, mem(normal)]`), the structure is persistent (an update returns a new root and shares every unchanged node with the old one), and an update copies only the few nodes it changes instead of rebuilding a record.

**Before.** The three pending jobs are a record of three nested records, and `most_urgent` compares them by hand. A fourth job changes the type at every function that mentions it, and the comparisons grow with every job.

`most_urgent` takes all three jobs and compares them by hand:

```silica
fn most_urgent(jobs: { first: { urgency: int64, name: string }, second: { urgency: int64, name: string }, third: { urgency: int64, name: string } }) -> string {
    case jobs.first.urgency <= jobs.second.urgency of {
        true -> case jobs.first.urgency <= jobs.third.urgency of {
            true -> jobs.first.name;
            false -> jobs.third.name
        };
        false -> case jobs.second.urgency <= jobs.third.urgency of {
            true -> jobs.second.name;
            false -> jobs.third.name
        }
    }
}
```

`main` builds the nested record:

```silica
fn main() -> int64 {
    sequence proc[device_io]
        jobs: { first: { urgency: int64, name: string }, second: { urgency: int64, name: string }, third: { urgency: int64, name: string } } <- { first: { urgency: 3, name: "paint the fence" }, second: { urgency: 1, name: "fix the roof" }, third: { urgency: 2, name: "mow the lawn" } };
        println(most_urgent(jobs))
    produces
        pure 0
    end
}
```

**After.** The jobs are a list, and the ranking is a `PriorityQueue`. The functions take one handle; a fourth job is one more list element.

The file names the queue modules:

```silica
use brodal_okasaki_priority;
use PriorityQueue;
```

The queue ranks jobs by urgency:

```silica
fn compare_urgency(a: int64, b: int64) -> :less | :equal | :greater {
    case a < b of {
        true -> :less;
        false -> case a == b of {
            true -> :equal;
            false -> :greater
        }
    }
}
```

It also needs an ordering for the job names:

```silica
fn compare_names(a: string, b: string) -> :less | :equal | :greater {
    case a < b of {
        true -> :less;
        false -> case a == b of {
            true -> :equal;
            false -> :greater
        }
    }
}
```

`add_jobs` walks the list and pushes each job:

```silica
fn add_jobs(queue: PriorityQueue[int64, string, mem(normal)], jobs: List[{ urgency: int64, name: string }, mem(normal)]) -> PriorityQueue[int64, string, mem(normal)] {
    case jobs of {
        []: List[{ urgency: int64, name: string }, mem(normal)] -> queue;
        [job: { urgency: int64, name: string }, rest: List[{ urgency: int64, name: string }, mem(normal)]] -> {
            longer: PriorityQueue[int64, string, mem(normal)] <- brodal_okasaki_priority@push_priority(queue, job.urgency, job.name);
            add_jobs(longer, rest)
        };
        _: List[{ urgency: int64, name: string }, mem(normal)] -> queue
    }
}
```

`most_urgent` takes one handle and looks at the front:

```silica
fn most_urgent(queue: PriorityQueue[int64, string, mem(normal)]) -> string {
    front: { status: :not_found | :found, value: string } <- PriorityQueue@peek_value(queue, 0, "");
    front.value
}
```

`main` builds the list and an empty queue:

```silica
fn main() -> int64 {
    sequence proc[device_io, mem(normal)]
        jobs: List[{ urgency: int64, name: string }, mem(normal)] <- [{ urgency: 3, name: "paint the fence" }, { urgency: 1, name: "fix the roof" }, { urgency: 2, name: "mow the lawn" }];
        none: PriorityQueue[int64, string, mem(normal)] <- brodal_okasaki_priority@empty({ compare_priority: compare_urgency, compare_item: compare_names });
        println(most_urgent(add_jobs(none, jobs)))
    produces
        pure 0
    end
}
```

Both print `fix the roof`. Compile the *after* program with the standard-library units the queue needs listed in `silica.config` before `main.silica`: `stdlib/data_structures/PriorityQueue.silica`, `brodal_okasaki_priority.silica`, and the `brodal_okasaki_*` units it `use`s (the leaves under `trials/ordered_data_structures/heap_collections/` show the same arrangement).

Pick the structure by the question the code asks:

| The code asks | Use |
|---|---|
| "what is stored under this key?" | `OrderedMap` (`wbt_map`) |
| "have I seen this one?" | `OrderedSet` (`wbt_set`); `SearchTree` for range and neighbour queries over the same value |
| "which is most urgent?" | `PriorityQueue` (`brodal_okasaki_priority`); `Heap` (`brodal_okasaki_min` / `brodal_okasaki_max`) when the item is its own priority |
| "what is under this node?" | `Tree` (`tree_rose`); `BinaryTree` (`tree_binary`) when every node has a left and a right |
| "what is connected to what?" | `DirectedGraph`, `UndirectedGraph`, `WeightedGraph` (`graph_wbt_*`, `graph_weighted*`) |

---



## Technique 2: pass only the fields the function needs

A function that reads two fields should take two parameters. The caller already has the record; reading two fields from it is two loads.

**Before.** `shipping_cost` takes the whole order, including a nested customer record it never reads.

`shipping_cost` takes the whole order, including a nested customer record it never reads:

```silica
fn shipping_cost(order: { id: int64, customer: { name: string, street: string, city: string }, weight: int64, express: boolean }) -> int64 {
    base: int64 <- order.weight * 2;
    case order.express of {
        true -> base * 3;
        false -> base
    }
}
```

The caller passes the order:

```silica
fn main() -> int64 {
    sequence proc[device_io]
        order: { id: int64, customer: { name: string, street: string, city: string }, weight: int64, express: boolean } <- { id: 7, customer: { name: "Ada", street: "1 Main St", city: "Provo" }, weight: 5, express: true };
        _: atom <- print_int64(shipping_cost(order));
        println("")
    produces
        pure 0
    end
}
```

**After.** It takes `weight` and `express`. Its signature now says what it depends on, it can be called without building an order at all, and no caller's change to the customer shape can reach it.

`shipping_cost` takes `weight` and `express`:

```silica
fn shipping_cost(weight: int64, express: boolean) -> int64 {
    base: int64 <- weight * 2;
    case express of {
        true -> base * 3;
        false -> base
    }
}
```

The caller reads the two fields:

```silica
fn main() -> int64 {
    sequence proc[device_io]
        order: { id: int64, customer: { name: string, street: string, city: string }, weight: int64, express: boolean } <- { id: 7, customer: { name: "Ada", street: "1 Main St", city: "Provo" }, weight: 5, express: true };
        _: atom <- print_int64(shipping_cost(order.weight, order.express));
        println("")
    produces
        pure 0
    end
}
```

Both print `30`.

---



## Technique 3: split a large function into narrow stages

When a function needs many fields because it does several jobs, split the jobs. Each stage takes the handful of values its job needs, as scalars or as one small record whose fields belong together.

**Before.** One `checkout` takes a six-field record and computes goods, discount, tax and shipping.

One `checkout` takes a six-field record and does four jobs:

```silica
fn checkout(order: { price: int64, quantity: int64, discount_percent: int64, tax_percent: int64, weight: int64, express: boolean }) -> int64 {
    subtotal: int64 <- order.price * order.quantity;
    discounted: int64 <- subtotal - subtotal * order.discount_percent / 100;
    taxed: int64 <- discounted + discounted * order.tax_percent / 100;
    base: int64 <- order.weight * 2;
    shipping: int64 <- case order.express of {
        true -> base * 3;
        false -> base
    };
    taxed + shipping
}
```

Its caller:

```silica
fn main() -> int64 {
    sequence proc[device_io]
        _: atom <- print_int64(checkout({ price: 20, quantity: 5, discount_percent: 10, tax_percent: 5, weight: 4, express: false }));
        println("")
    produces
        pure 0
    end
}
```

**After.** Three stages. `goods` takes the one small record whose three fields describe an order line; `with_tax` and `shipping` take scalars. Each stage can be tested, reused and read alone.

`goods` takes the one small record whose three fields describe an order line:

```silica
fn goods(line: { price: int64, quantity: int64, discount_percent: int64 }) -> int64 {
    subtotal: int64 <- line.price * line.quantity;
    subtotal - subtotal * line.discount_percent / 100
}
```

`with_tax` takes an amount and a rate:

```silica
fn with_tax(amount: int64, tax_percent: int64) -> int64 {
    amount + amount * tax_percent / 100
}
```

`shipping` takes the two values it reads:

```silica
fn shipping(weight: int64, express: boolean) -> int64 {
    base: int64 <- weight * 2;
    case express of {
        true -> base * 3;
        false -> base
    }
}
```

The caller composes the stages:

```silica
fn main() -> int64 {
    sequence proc[device_io]
        net: int64 <- goods({ price: 20, quantity: 5, discount_percent: 10 });
        total: int64 <- with_tax(net, 5) + shipping(4, false);
        _: atom <- print_int64(total);
        println("")
    produces
        pure 0
    end
}
```

Both print `102`.

---



## Technique 4: return a status and the one value, not an echo

A function that checks or computes something should return what the caller needs next: usually a status and one value. Returning the input record with a result field added makes every call allocate and copy the whole record again (see "Aggregate results come back by pointer, after a copy"), and it makes the result type as large as the input type.

**Before.** `check_order` returns the four fields it was given plus `ok` and `total`.

`check_order` returns the four fields it was given plus `ok` and `total`:

```silica
fn check_order(order: { id: int64, quantity: int64, price: int64, stock: int64 }) -> { id: int64, quantity: int64, price: int64, stock: int64, ok: boolean, total: int64 } {
    case order.quantity <= order.stock of {
        true -> { id: order.id, quantity: order.quantity, price: order.price, stock: order.stock, ok: true, total: order.quantity * order.price };
        false -> { id: order.id, quantity: order.quantity, price: order.price, stock: order.stock, ok: false, total: 0 }
    }
}
```

The caller reads two of the six fields:

```silica
fn main() -> int64 {
    sequence proc[device_io]
        checked: { id: int64, quantity: int64, price: int64, stock: int64, ok: boolean, total: int64 } <- check_order({ id: 7, quantity: 3, price: 20, stock: 10 });
        _: atom <- case checked.ok of {
            true -> print_int64(checked.total);
            false -> print_string("out of stock")
        };
        println("")
    produces
        pure 0
    end
}
```

**After.** `order_total` takes the three values it reads and returns an atom status and the total. The caller unpacks the pair and branches on the status.

`order_total` takes the three values it reads and returns an atom status and the total:

```silica
fn order_total(quantity: int64, price: int64, stock: int64) -> (atom, int64) {
    case quantity <= stock of {
        true -> (:ok, quantity * price);
        false -> (:out_of_stock, 0)
    }
}
```

The caller unpacks the pair and branches on the status:

```silica
fn main() -> int64 {
    sequence proc[device_io]
        (status: atom, total: int64) <- order_total(3, 20, 10);
        _: atom <- case status of {
            :ok -> print_int64(total);
            _: atom -> print_string("out of stock")
        };
        println("")
    produces
        pure 0
    end
}
```

Both print `60`. You can also match the pair with a tuple pattern that has an atom and a named element, `(:ok, n: int64) -> ...`; that form matches and binds since 2026-09-19 (`trials/case_addition/tuple_pattern_atom_and_named_elements.silica`).

---



## Technique 5: keep large state inside an actor

State that many steps update — counters, running totals, a cache, a table — does not have to be passed from function to function. Give it to an actor. The actor keeps the state between messages; the rest of the program holds an `actor_ref`, a primitive handle (spec §16.3.5), and sends small messages. The state's type appears in one behaviour signature instead of in every function that touches it, and only the small message and the small reply cross between actors, where values are copied (spec §15.4.7.3).

**Before.** `main` threads a five-field statistics record through every call, and each call returns a fresh copy of it.

`record_reading` takes the statistics and returns a fresh copy of all five fields:

```silica
fn record_reading(stats: { count: int64, total: int64, largest: int64, smallest: int64, last: int64 }, reading: int64) -> { count: int64, total: int64, largest: int64, smallest: int64, last: int64 } {
    largest: int64 <- case reading > stats.largest of { true -> reading; false -> stats.largest };
    smallest: int64 <- case reading < stats.smallest of { true -> reading; false -> stats.smallest };
    { count: stats.count + 1, total: stats.total + reading, largest: largest, smallest: smallest, last: reading }
}
```

`main` threads the record through every call:

```silica
fn main() -> int64 {
    sequence proc[device_io]
        s0: { count: int64, total: int64, largest: int64, smallest: int64, last: int64 } <- { count: 0, total: 0, largest: 0, smallest: 1000, last: 0 };
        s1: { count: int64, total: int64, largest: int64, smallest: int64, last: int64 } <- record_reading(s0, 12);
        s2: { count: int64, total: int64, largest: int64, smallest: int64, last: int64 } <- record_reading(s1, 30);
        s3: { count: int64, total: int64, largest: int64, smallest: int64, last: int64 } <- record_reading(s2, 18);
        _: atom <- print_int64(s3.total);
        println("")
    produces
        pure 0
    end
}
```

**After.** A weather-station actor owns the statistics. Each message is one `int64` reading; each reply is the running total.

The behaviour owns the statistics and replies with the running total:

```silica
fn weather_station(reading: int64, stats: { count: int64, total: int64, largest: int64, smallest: int64, last: int64 }) -> (:reply, int64, { count: int64, total: int64, largest: int64, smallest: int64, last: int64 }) {
    largest: int64 <- case reading > stats.largest of { true -> reading; false -> stats.largest };
    smallest: int64 <- case reading < stats.smallest of { true -> reading; false -> stats.smallest };
    total: int64 <- stats.total + reading;
    (:reply, total, { count: stats.count + 1, total: total, largest: largest, smallest: smallest, last: reading })
}
```

`main` holds only an `actor_ref` and sends one number per message. It first registers a FailureReporter, the actor that receives every failure report; the compiler requires that registration to run before `main` starts any other actor (spec §15.4.13.4, error E2236). The reporter's own `spawn`, written as `register_failure_reporter`'s argument, is the one start allowed before it:

```silica
fn region_dump_limit() -> int64 {
    0
}

fn reporter(report: string, state: int64) -> (:no_reply, int64) {
    sequence proc[device_io]
        _: atom <- println_stderr(report)
    produces
        pure (:no_reply, state)
    end
}

fn main() -> int64 {
    sequence proc[concurrency, device_io]
        _: atom <- register_failure_reporter(spawn(0, reporter, stack_policy(0, :keep_last_message)));
        station: actor_ref <- spawn({ count: 0, total: 0, largest: 0, smallest: 1000, last: 0 }, weather_station, stack_policy(0, :keep_last_message));
        _: int64 <- call(station, 12 impl ActorMessage {});
        _: int64 <- call(station, 30 impl ActorMessage {});
        total: int64 <- call(station, 18 impl ActorMessage {});
        _: atom <- print_int64(total);
        println("")
    produces
        pure 0
    end
}
```

Both print `60`. The actor still builds its next state each turn; what changes is that nothing outside it names the state's type or carries the state. When the state is itself a collection, make it a first-class structure (technique 1), so the state is one handle. In an application the actor is a child of a supervisor rather than a bare `spawn` from `main`; see [supervisors_and_failure_reporter_tutorial.md](./supervisors_and_failure_reporter_tutorial.md) and [actor_spawning_tutorial.md](./actor_spawning_tutorial.md).

---



## Technique 6: never nest tuples to make a sequence or a hierarchy

A tuple nested inside a tuple inside a tuple has its depth written into its type. One more level means a longer type at every use, and every level is a separate object to build and copy. Sequences of any length are lists, `List[T, mem(Space)]`; hierarchies and networks are `Tree`, `BinaryTree` and the graph families.

**Before.** A five-leg route as a tuple nested four deep. A six-leg route needs a new type everywhere.

`sum_route` unpacks a tuple nested four deep:

```silica
fn sum_route(route: (int64, (int64, (int64, (int64, int64))))) -> int64 {
    (a: int64, rest1: (int64, (int64, (int64, int64)))) <- route;
    (b: int64, rest2: (int64, (int64, int64))) <- rest1;
    (c: int64, rest3: (int64, int64)) <- rest2;
    (d: int64, e: int64) <- rest3;
    a + b + c + d + e
}
```

The caller writes the route as nested pairs:

```silica
fn main() -> int64 {
    sequence proc[device_io]
        _: atom <- print_int64(sum_route((4, (7, (2, (5, 1))))));
        println("")
    produces
        pure 0
    end
}
```

**After.** The route is a `List[int64, mem(normal)]`, and `sum_route` walks a route of any length.

`sum_route` walks the list:

```silica
fn sum_route(route: List[int64, mem(normal)]) -> int64 {
    case route of {
        []: List[int64, mem(normal)] -> 0;
        [leg: int64, rest: List[int64, mem(normal)]] -> leg + sum_route(rest);
        _: List[int64, mem(normal)] -> 0
    }
}
```

The caller writes the route as a list:

```silica
fn main() -> int64 {
    sequence proc[device_io, mem(normal)]
        route: List[int64, mem(normal)] <- [4, 7, 2, 5, 1];
        _: atom <- print_int64(sum_route(route));
        println("")
    produces
        pure 0
    end
}
```

Both print `19`.

Do not reach for hand-built linked nodes instead. Recursive tuples in a region, nodes typed with `rec` and linked by `ref?(L, Space, rec)` references ([why_no_named_types.md](./why_no_named_types.md), [region_handles_and_references.md](./region_handles_and_references.md)), are for building non-naive data structures of the kind the standard ones are: the maps, sets, heaps, trees and graphs of the standard library are made from them. Application code uses `List[T, mem(Space)]` and those structures, and does not hand-build linked lists or ad hoc trees.

---



## Technique 7: narrow the exports

A module's exports are its interface, and every unit that `use`s the module loads them (see "At compile time" above). Export the operation callers need, with the parameters it reads, and keep the helpers private.

**Before.** `orders.silica` exports three functions, each taking the whole seven-field order with its nested customer record. Every user of the module pays for three copies of that shape.

`orders.silica` exports three functions:

```silica
export goods/1;
export tax/1;
export shipping/1;
```

`goods` takes the whole seven-field order:

```silica
fn goods(order: { id: int64, customer: { name: string, city: string }, price: int64, quantity: int64, tax_percent: int64, weight: int64, express: boolean }) -> int64 {
    order.price * order.quantity
}
```

`tax` takes it again:

```silica
fn tax(order: { id: int64, customer: { name: string, city: string }, price: int64, quantity: int64, tax_percent: int64, weight: int64, express: boolean }) -> int64 {
    goods(order) * order.tax_percent / 100
}
```

So does `shipping`:

```silica
fn shipping(order: { id: int64, customer: { name: string, city: string }, price: int64, quantity: int64, tax_percent: int64, weight: int64, express: boolean }) -> int64 {
    case order.express of {
        true -> order.weight * 6;
        false -> order.weight * 2
    }
}
```

`main.silica` builds the order and calls all three:

```silica
use orders;

fn main() -> int64 {
    sequence proc[device_io]
        order: { id: int64, customer: { name: string, city: string }, price: int64, quantity: int64, tax_percent: int64, weight: int64, express: boolean } <- { id: 7, customer: { name: "Ada", city: "Provo" }, price: 20, quantity: 5, tax_percent: 5, weight: 4, express: false };
        _: atom <- print_int64(orders@goods(order) + orders@tax(order) + orders@shipping(order));
        println("")
    produces
        pure 0
    end
}
```

**After.** One export, `order_total/5`, with five scalar parameters. The helpers take what they read and stay private.

`orders.silica` now exports one function:

```silica
export order_total/5;
```

Its helpers take only what they read, and stay private:

```silica
fn goods(price: int64, quantity: int64) -> int64 {
    price * quantity
}
```

`shipping` takes the two values it reads:

```silica
fn shipping(weight: int64, express: boolean) -> int64 {
    case express of {
        true -> weight * 6;
        false -> weight * 2
    }
}
```

The one export takes five scalars:

```silica
fn order_total(price: int64, quantity: int64, tax_percent: int64, weight: int64, express: boolean) -> int64 {
    net: int64 <- goods(price, quantity);
    net + net * tax_percent / 100 + shipping(weight, express)
}
```

`main.silica` calls it:

```silica
use orders;

fn main() -> int64 {
    sequence proc[device_io]
        _: atom <- print_int64(orders@order_total(20, 5, 5, 4, false));
        println("")
    produces
        pure 0
    end
}
```

Both print `113`. For a facade that must `use` many modules, the same idea one level up is [thin_dispatchers_for_compile_ram.md](./thin_dispatchers_for_compile_ram.md).

---



## Checklist

1. Is the data a collection? Use the standard structure that answers the question the code asks.
2. Does the function read every field it is given? If not, pass the fields it reads.
3. Does one function do several jobs? Split it into stages with narrow parameters.
4. Does a function return its input? Return a status and the one value the caller needs.
5. Is a value threaded through many calls as "the state"? Put it in an actor and send it small messages.
6. Is the data a sequence, a hierarchy or a network? Use a list or a standard structure, never a tuple nested by hand.
7. Do the exports repeat a large shape? Export fewer functions with smaller signatures.

---



## Related reading

- [data_structure_designs/README.md](../design_documents/Phase1_TODOs/data_structure_designs/README.md) — every standard structure, its trait and its representation
- [compiling_with_less_ram.md](./compiling_with_less_ram.md) — narrow units and narrow exports for compile-time RAM
- [thin_dispatchers_for_compile_ram.md](./thin_dispatchers_for_compile_ram.md) — when a facade's `use` list is the cost
- [region_handles_and_references.md](./region_handles_and_references.md) and [why_no_named_types.md](./why_no_named_types.md) — the regions and recursive tuples the standard structures are built from
- [actor_spawning_tutorial.md](./actor_spawning_tutorial.md) and [supervisors_and_failure_reporter_tutorial.md](./supervisors_and_failure_reporter_tutorial.md) — actors that own state
