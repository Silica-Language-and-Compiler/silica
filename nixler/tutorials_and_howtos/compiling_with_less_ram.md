# Using less RAM when compiling with `silica-compiler`

> **Note.** Splitting an application into many compilation units is a work-around for the compiler's memory use, not the language's model: a Silica application is one compilation unit. See [APPLICATION_IS_ONE_COMPILATION_UNIT.md](../design_documents/APPLICATION_IS_ONE_COMPILATION_UNIT.md).

Large Silica programs can push host memory during compile even when the finished binary is modest. Peak RAM is dominated by **how much source the compiler holds at once** for a unit (its own AST plus whatever it needs from dependencies), not by how clever your algorithms are at runtime.

This how-to is for **general applications** you build with `silica-compiler`. The same tactics are how the self-hosted compiler tree stays buildable; you can apply them to any multi-module app.

Four levers matter most:

1. **Leaf-to-root compilation** — compile dependencies before dependents, one unit at a time when the host needs reclaim.
2. **Break up large files** — keep each unit’s source small enough that one process can finish it.
3. **Produce smaller compilation units** — treat each listed `.silica` module as a compile work item, and keep those items narrow so reclaim between them actually helps.
4. **Open recursion** — split recursive algorithms across units **without** circular `use`, by passing callbacks (function values) instead of calling “self.”

For the mechanical callback pattern and a full example, see [open_recursion_callbacks.md](./open_recursion_callbacks.md).

---



## What a compilation unit is

In Silica toolchain practice, a **compilation unit** is one **module source file** (a `.silica` file) that the compiler treats as a single work item in a batch:

- It has its own `use` / `export` surface.
- The compiler runs the usual pipeline on it (module check → type check → SIR → emit).
- Success writes durable artifacts for that unit (typically `.sams`, and when enabled `.iface`) so later units and later processes can consume them without reloading the full source AST of every dependency.

A **batch** is the ordered list of compilation units the compiler will process—usually the lines of `silica.config` in the build directory. The **application root** (often `main.silica`) is still one compilation unit in that batch; it simply comes last in leaf-to-root order.

```text
silica.config (batch)
  helpers.silica          ← compilation unit (leaf)
  leaf_add.silica         ← compilation unit
  facade.silica           ← compilation unit
  main.silica             ← compilation unit (root)
```

---



## Why compile RAM spikes

Silica’s module graph is a **DAG** (`use` is acyclic). The compiler still has to type-check and emit **structural** types: large inline records and function signatures appear in full in environments and diagnostics. A single oversized `.silica` file, or a thin file that pulls a huge dependency world into one process, can OOM the host even if other units are fine unless the dependencies were already compiled.

Mitigations below reduce **per-process** peak:


| Pressure                                 | What helps                                                               |
| ---------------------------------------- | ------------------------------------------------------------------------ |
| One huge AST                             | Smaller compilation units (split sources)                                |
| Holding many units in one process        | Leaf-to-root + silica-compiler’s process-per-unit reclaim                |
| Recursive logic that wants a `use` cycle | Open recursion (callbacks) so the graph stays a DAG and files stay small |


---



## Leaf-to-root compilation

**Leaf-to-root** (also called **bottom-up** or **dependency order**) means: compile modules that nothing else in the remaining work depends on first, then walk toward the application root. Dependents see already-compiled artifacts (for example `.sams` and `.iface`) instead of re-parsing every dependency’s full source in the wrong order.

```text
  leaves (helpers, pure tables)
       │
       ▼
  mid-layer specialists
       │
       ▼
  facade / main  (root)
```



### What you do in practice

1. **One module per compilation unit** — each `.silica` file in the batch is its own unit.
2. **List units in topological order** — dependencies before dependents. Builds that mirror the self-host Makefile typically generate a `silica.config` with a Kahn-style sort of `use` edges; `main` (or your app entry) is last.
3. **Follow silica-compiler’s reclaim pattern** — see [Using silica-compiler’s memory reclaiming pattern](#using-silica-compilers-memory-reclaiming-pattern) below.
4. **Keep incremental artifacts** — up-to-date `.sams` / `.iface` for unchanged leaves mean a rebuild only pays for stale units, still in leaf-to-root order for the remainder.



### Mental model

Think of pouring concrete from the foundation up: you do not type-check the roof while the basement forms are still empty. Leaf-to-root is that order for modules.

### Checklist

- `use` graph is a DAG; no cycles.
- Config / Makefile order is **deps before dependents**.
- Root / `main` is last in the batch list.
- Multi-unit builds use process-per-unit reclaim (or an equivalent one-unit-per-process driver).

---



## Break up large files

A file that “almost” compiles alone and then OOMs when added to the app is a signal: **split it**.

### How to split

1. **Find natural seams** — helpers vs. dispatch vs. one family of cases (arithmetic, calls, decls, I/O adapters).
2. **Extract leaf modules first** — pure helpers with no recursion back into the parent. Ordinary `use` is enough.
3. **Cap unit size by feel and by failure** — if process-per-unit still dies on one file, that compilation unit is still too large or its import surface is too fat; split again or thin the exports.
4. **Avoid catch-all modules** — a facade may `use` many specialists, but each specialist should own a narrow export list.
5. **If the facade is already thin but compiling it still fails** — the cost is often the `use` list (every leaf interface in one process), not the file length. Insert two or three thin dispatchers; see [thin_dispatchers_for_compile_ram.md](./thin_dispatchers_for_compile_ram.md).



### What not to do

- Do not merge everything into one file “to avoid module boilerplate.” That maximizes peak AST size.
- Do not fix OOM by only raising machine RAM if splitting is possible; RAM buys time, modularity buys a repeatable build.
- Do not re-export the world from every leaf; fat export types inflate every dependent’s type-check world.

After a split, regenerate or resort your unit list so leaf-to-root order still holds.

---



## Produce smaller compilation units

Breaking a large file is the edit; **producing smaller compilation units** is the build contract you end up with: more lines in `silica.config`, each naming a narrower module the compiler can finish and then drop.

### Goals for each unit

- **Narrow responsibility** — one concern (or a small family of related cases), not “the whole pass.”
- **Narrow exports** — export only what dependents must call; every fat structural signature you export is paid again by every unit that `use`s you.
- **Acyclic** `use` — leaves do not import facades that already import them (use open recursion when recursion crosses the cut).
- **Standalone finishability** — under process-per-unit, unit *U* must complete with peak RAM bounded by *U* plus dependency **interfaces**, not by the sum of every other unit’s AST in the same process forever.



### How small is small enough?

There is no fixed line count. A unit is small enough when:

1. It compiles under your host’s RAM with process-per-unit enabled, and
2. Changing it does not force you to merge it back with siblings to “make types fit.”

If reclaim between units does not help (still OOM on one line of `silica.config`), that line is still one oversized compilation unit—split again.

---



## Using silica-compiler’s memory reclaiming pattern

`silica-compiler` (and the checked-in seed used to build it) is designed so a **multi-unit batch does not keep growing one process heap across the whole app**. Mirror that pattern in your application Makefile / driver.

### Pattern (what the compiler does)

1. **Read a batch list** — `silica.config` in the working directory: one compilation unit path per line, leaf-to-root.
2. **Compile the next unit** — parse / check / emit that unit; write `.sams` (and `.iface` when the iface path is active) to disk.
3. **Exit so the OS reclaims host heap** — between units the seed uses exit status `75` as “unit succeeded; more units remain.” The driver restarts the compiler for the next unit. A normal exit (`0`) means the batch (or the incremental remainder) is done.
4. **Resume from durable artifacts** — the next process loads dependency interfaces / prior outputs from disk instead of retaining every earlier AST in the same address space.

```text
  driver                         silica-compiler process
    │                                    │
    ├─ write silica.config (topo)        │
    ├─ start compiler ──────────────────►│ compile unit 1 → write artifacts
    │◄──────── exit 75 ──────────────────┤
    ├─ start compiler ──────────────────►│ compile unit 2 → write artifacts
    │◄──────── exit 75 ──────────────────┤
    ├─ …                                 │
    ├─ start compiler ──────────────────►│ compile last unit
    │◄──────── exit 0 ───────────────────┤
    └─ assemble .sams → link app
```



### What you should do for a general app

1. **List every** `.silica` **module** you intend to compile in `silica.config` (or generate that list with a topo sort of `use`, as `compiler/src/topo_silica_config.sh` does for the compiler itself).
2. **Put the entry module last.**
3. **Invoke** `silica-compiler` **from the directory that contains** `silica.config`, the same way trial Makefiles and the self-host `assembly` target do—do not feed the entire tree as one anonymous blob if you can batch by unit.
4. **Loop on exit** `75` in your Makefile or script: treat `75` as continue, `0` as success, anything else as failure. Do not “optimize” by forcing a single long-lived process for huge graphs unless you have measured that you have the RAM.
5. **Preserve** `.sams` **/** `.iface` **across runs** when sources are unchanged, so incremental rebuilds only re-enter the reclaim loop for stale units (the self-host Makefile prunes stale artifacts and may write a shorter `silica.compile.order` for the remainder).
6. **Assemble and link after the Silica batch** — `clang` (or your target toolchain) turns `.sams` into objects; linking is separate from the reclaim loop.

Copying the self-host or trial Makefile shape is usually enough; the important part is **one compilation unit → finish → process exit → OS reclaim → next unit**, not a particular Make recipe spelling.

### What not to do

- Do not concatenate many modules into one `.silica` file to “simplify” `silica.config`; that defeats reclaim.
- Do not ignore exit `75` and treat it as failure, or suppress restart—without the restart there is no reclaim.
- Do not delete `.iface` / `.sams` for the whole tree on every edit if only one leaf changed; you pay full-graph RAM and time again.

---



## Open recursion (Silica sense)



### Definition

In object-oriented languages, **open recursion** often means methods that call `self` **/** `this`, so a subclass can override a step and the base code still recurses through the override.

**In Silica, open recursion means something different and more literal:** recursion is **opened** as a **function parameter**—a **lambda / function value you capture and pass**—rather than as an implicit `self`. A leaf does not `use` the facade that owns the recursive entry point. The facade **installs** the recursive function (or a small bundle of related functions) as an argument; the leaf **calls that callback** when it needs to recurse into a child.

```text
OO open recursion:     base.method() → self.step() → (maybe subclass)
Silica open recursion: facade.eval(...) passes eval into leaf
                       leaf calls eval_child(...)   ← captured function, not self
```

There is no receiver object and no circular `use`. The callback is ordinary data: a function value.

### Why this saves RAM

Recursive tree walks (AST check, emit, transform) want a cycle: facade → specialist → facade. Silica forbids that cycle on `use`. Without open recursion you either:

- keep the whole recursive algorithm in **one giant compilation unit** (high RAM), or
- duplicate the dispatcher in every leaf (unmaintainable).

With open recursion you **split** the algorithm across units (lower peak AST per process) while the `use` **graph stays a DAG**, so leaf-to-root compilation and process-per-unit reclaim still work.

### Minimal shape

```silica
// facade.silica — owns recursion; uses the leaf
use leaf_add;

fn eval(e: /* expr */) -> int64 {
    case e.kind of {
        0 -> /* literal */;
        1 -> leaf_add@eval_add_node(e, eval);  // pass eval as callback
        _: int64 -> 0
    }
}
```

```silica
// leaf_add.silica — does NOT use facade
fn eval_add_node(
    e: /* expr */,
    eval_child: fn(/* expr */) -> int64   // open recursion: captured fn, not self
) -> int64 {
    eval_child(e.left) + eval_child(e.right)
}
```

Full walkthrough, switchboard analogy, and do/don’t list: [open_recursion_callbacks.md](./open_recursion_callbacks.md).

---



## Putting the four together

```text
1. Split oversized sources into smaller compilation units (narrow modules + narrow exports).
2. Where specialists must recurse, pass callbacks (open recursion) — never use the facade from those leaves.
3. List units leaf-to-root in silica.config (deps before root).
4. Run silica-compiler in the process-per-unit reclaim loop (exit 75 → restart → next unit; exit 0 → done).
```

Result: each compile process sees a **small compilation unit** and a **bounded dependency interface**, then exits so the OS can reclaim RAM before the next unit.

---



## Related reading

- [open_recursion_callbacks.md](./open_recursion_callbacks.md) — callback pattern in depth  
- [thin_dispatchers_for_compile_ram.md](./thin_dispatchers_for_compile_ram.md) — when the facade’s `use` list is the unit that OOMs  
- [module_interface_cache_and_bottom_up_typecheck_plan.md](../design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md) — iface cache and bottom-up type-check design  
- [ffi_wrappers_and_makefiles.md](./ffi_wrappers_and_makefiles.md) — app-shaped `silica.config` and compile/link steps  
- Self-host `Makefile` comments on `silica.config` topology and process-per-unit (`exit 75`) under `compiler/src/`

