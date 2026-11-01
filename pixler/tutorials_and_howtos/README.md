<h1 align="left">
  <img src="../../../silica_icon_tiny.png" alt="" width="40" height="40" style="vertical-align: middle; margin-right: 0.35em;" />
  Silica compiler — tutorials and how-tos
</h1>

These files are **working documents**: hands-on tutorials and explanatory notes for learning Silica and the self-hosted compiler. They are **revised as the language and tooling evolve**; where they disagree with [design_documents](../design_documents/) or with the code, prefer the **language specification** and implementation unless a tutorial explicitly states it is illustrative only.

Use the entries below for **quick navigation**. Each item links to a file in this directory, followed by a short summary of what it contains.

---

## [actor_spawning_tutorial.md](./actor_spawning_tutorial.md)

**Spawning actors** and choosing **migration strategies** (`lazy`, `eager_copy`, `static_core`, etc.): gen_server-style behaviors, how stack depth relates to message turns, decision tables, examples, and performance tradeoffs.

---

## [actor_scheduler_policy_tutorial.md](./actor_scheduler_policy_tutorial.md)

**Choosing a per-core dispatch-order policy** with `set_scheduler_policy` (`ESP32-S3_raw` only):
`:priority_fifo` (default, strict tiers, can starve), `:round_robin` (flat, simplest, no tiers),
`:weighted_fair` (deficit round robin, proportional, no starvation), `:lottery` (weighted random draw,
same proportions, no fixed order). Selection table, examples, and a comparison table.

---

## [why_no_named_types.md](./why_no_named_types.md)

Explains **why Silica avoids classic named recursive type definitions**, what problems that style hides (allocation, layout, reclamation), and how **regions** and **recursive tuples** aim to replace linked structures with explicit memory and typing discipline.

---

## [memory_region_types.md](./memory_region_types.md)

**Memory spaces** for regions (`normal`, write-through, non-cacheable, `atomic`, `device`): cache behavior, visibility, and how they connect to **`alloc_region`**, **`List[T, S]`**, and **`sequence proc[mem(S)]`** with pointers to list design and trials.

---

## [region_handles_and_references.md](./region_handles_and_references.md)

Contrasts **region handles** (`region(L, Space)`) with **region references** (`ref(L, Space, T)`): arenas vs. pointers to cells, allocation with `alloc_ref` / `alloc_buf`, and read/write patterns—tutorial form of the region model.

---

## [list_memory_space_and_effects.md](./list_memory_space_and_effects.md)

Unifies **`sequence proc[mem(S)]`**, region APIs, and **`List[T, S]`**: why the same memory space `S` appears in types and effects, rule-of-thumb for the effect checker, and canonical code shapes linking to region and list implementation docs.

---

## [ffi_wrappers_and_makefiles.md](./ffi_wrappers_and_makefiles.md)

Hands-on guide for **outbound FFI**: C wrapper functions, `dangerous_exposure_source/` sidecar metadata, `dangerous_*` Silica wrapper modules, `external_danger` FFI worker actors, `W4001` warnings, and Makefile patterns for building archives, compiling Silica, linking, and running trials.

---

## [designing_apps_with_foreign_functions.md](./designing_apps_with_foreign_functions.md)

App-design tutorial for engineers new to Silica who must use **foreign functions**: keep dangerous code concentrated in a few `dangerous_*` adapter and worker modules, route requests through cast-only FFI worker actors, supervise dangerous workers, and avoid spreading wrapper calls through business logic.

---

## [open_recursion_callbacks.md](./open_recursion_callbacks.md)

How to split a **recursive** algorithm across compilation units without circular `use`: the facade passes recursive entry points as **callbacks** (`eval_child` / `check_typed` / `emit_child`). Covers when the pattern is needed, a switchboard analogy, a small standalone example, and a do/don’t checklist.

---

## [compiling_with_less_ram.md](./compiling_with_less_ram.md)

Practical guide to **lowering host RAM** when compiling a general app with `silica-compiler`: what a **compilation unit** is, **leaf-to-root** batch order, **smaller units** and splitting large files, following the compiler’s **process-per-unit reclaim** pattern (`silica.config`, exit `75`), and **open recursion** in the Silica sense (recursion via a **captured function argument**, not OO `self`).

---

## [thin_dispatchers_for_compile_ram.md](./thin_dispatchers_for_compile_ram.md)

When a **short facade** still exhausts RAM while compiling because it `use`s every specialist at once: insert **two or three thin dispatchers** so each compilation loads one leaf group, keep recursive callbacks as **local** function values, and split a dispatcher again if *it* is the unit that fails.

---

## [reducing_parameter_and_return_sizes.md](./reducing_parameter_and_return_sizes.md)

Why **large inline records and tuples** in parameters and returns are the naive choice (one 8-byte slot per field, a separate heap object per nested group, copies at call and return, copied messages, shapes spelled at every use and carried in every interface), and seven **before/after** techniques for the few cases a **first-class data structure** does not fit: choose a structure first, pass only needed fields, split stages, return a status plus one value, keep state in an actor, use lists and structures instead of nested tuples, and narrow exports.

---

## [building_apps_with_project_makefiles.md](./building_apps_with_project_makefiles.md)

How to build a **general application** with the drop-in Makefiles under repository-root `project_makefiles/`: what to copy into your app root and subdirectories, prerequisites (`silica-compiler`, Make, Clang), `make` targets and options (`EXECUTABLE`, `SILICA_COMPILER`), how `silica.config` / topo sort / reclaim / link work, and a small multi-module example.
