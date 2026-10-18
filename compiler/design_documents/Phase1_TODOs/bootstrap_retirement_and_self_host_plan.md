# Bootstrap Retirement and Self-Host Migration Plan

**Purpose:** Identify every change needed so `silica-compiler` can build and maintain itself without `silica-bootstrap-compiler`, replacing bootstrap-era internal data structures and workarounds with the standard generated families specified in [data_structures_as_traits.md](data_structures_as_traits.md) and [data_structure_to_algorithms.md](data_structure_to_algorithms.md).

**Scope (as written 2026-09-08; see the status section below for the current state):** Parallel compiler tree `compiler/src/` (self-host edits), additive build targets, and compiler-facing trials. Production `compiler/src/` and `silica-bootstrap-compiler` stay untouched until Phase 6 cutover. Stdlib implementation of WBT / Brodal–Okasaki / BinaryTree modules is tracked in [standard_data_structures_implementation_plan.md](standard_data_structures_implementation_plan.md). **Withdrawn 2026-09-29:** the compiler's further adoption of the standard structures (WBT maps for the symbol, effect, module and FFI environments, and a `BinaryTree` syntax tree) is no longer planned. The compiler keeps its lists and its index-arena `Expr`/`SIRTerm`; only the emitter pools moved to `wbt_map` (Phase 3). The former Phase 4 and Phase 7 are removed from this plan.

**Authority:**

- [data_structure_to_algorithms.md](data_structure_to_algorithms.md) — **locked algorithms** (Adams WBT for ordered collections; Brodal–Okasaki for heaps; WBT graphs + CSR freeze; no dense bitset)
- [data_structures_as_traits.md](data_structures_as_traits.md) — trait API specification, constructor function records, trait → module mapping (`wbt_set`, `wbt_map`, …)
- [standard_data_structures_implementation_plan.md](standard_data_structures_implementation_plan.md) — stdlib build progress and acceptance trials
- [list_implementation_design.md](../list_implementation_design.md) — when `List[T, S]` remains correct (AST chains, token streams)

## Status (2026-10-16): self-hosting reached, bootstrap retired

The goal of this plan is met. The text below the status tables is the working plan as it stood on 2026-09-08 and is kept as the record of how the migration was sequenced; the phase tables here supersede it wherever they disagree. Tree names in the body are historical: "frozen `src/`" was the Rust-bootstrapped seed tree and "parallel tree `src/`" was the selfhost tree; both no longer exist as such. There is now one compiler tree, `compiler/src/` (formerly `src_selfhost`), and the Rust bootstrap crate is deleted from the repository (removed in commit `8dcf493d4`, 2026-09-17).

| Milestone | Date | Where |
| --------- | ---- | ----- |
| First fixed point (gen3 equals gen2 modulo UUID/signature), 33,000+ trials pass | 2026-09-12 | commit `9285f5330` |
| Apple Silicon fixed point 1 | 2026-09-13 | commit `8aff9cdc5` |
| Linux AArch64 fixed point 1 (Raspberry Pi) | 2026-09-17 | commit `8dcf493d4`; Rust bootstrap crate removed |
| Linux x86-64 first fixed point | 2026-09-19/20 | commit `e8274292e` (with Apple Silicon and Linux AArch64) |
| Fixed points on all three hosted platforms again, ESP32-S3 cross compiler rebuilt | 2026-10-07 | commit `eff040583`; the 2026-10-07 `-linux-aarch64` and `-linux-x86_64` binaries in `binaries/` |
| Apple Silicon fixed point (349 units compared, 0 differ, gen2 = gen3 = 6,850,384 bytes) | 2026-10-16 | `/Volumes/2T/silica_builds/20261016-052517/fixpoint-apple_silicon_mac.log`; `binaries/silica-compiler` -> `silica-999949-macos-applesilicon`, `seed-compiler` -> `silica-999983-seed-macos-applesilicon` |
| Linux AArch64 fixed point (349 units, 0 differ, 11,095,520 bytes) | 2026-10-16 | `remote-linux_aarch64.log` in the same build directory |
| ESP32-S3 cross compiler built by the Mac compiler | 2026-10-16 | `binaries/silica-compiler-ESP32-S3_raw` -> `silica-999981-ESP32_S3_raw-macos-applesilicon` |

The Linux x86-64 build of 2026-10-16 (`remote-linux_x86_64.log`, built on `nix`, 20 m 26 s) reached its fixed point: 355 units compared, 0 differ, gen2 = gen3 = 12,670,752 bytes. That binary is not yet published into `binaries/`; the newest published x86-64 compiler there is the 2026-10-07 one.

How the build works now (details in `compiler/src/README.md`, `compiler/src/Makefile` and `programmer_tools/README.md`): `binaries/seed-compiler`, a published Silica-built binary, compiles `compiler/src`; `make gen1`, `make gen2` and `make fixpoint` produce `binaries/silica-gen1`, `silica-gen2` and compare gen3 with gen2; a build that reaches its fixed point becomes the next seed. Generation numbers count down and seeds and selfhosts are numbered independently (`binaries/install_compiler.bash`). Each emit target builds in its own directory `compiler/build/<TARGET>/` so one target's build never leaves artifacts that disturb another. The platform scripts are `programmer_tools/build_all_platforms.sh`, `rebuild_refresh_verify.sh`, `sync_to_hosts.sh` and `run_trials_all_platforms.sh`. The link is Rust-free: the runtime comes from the self-emitted `__silica_runtime.sams` plus the small hand-written shims in `compiler/src/runtime_asm/<target>/` (`silica_rt_shim.s`, `deviceio_link_thunks.s`) and `main_entry_alias.s`.

| Phase / step | Status |
| ------------ | ------ |
| Phase 0 (audit, parallel tree) | Done |
| Phase 1 (build targets, Rust-free link, config-driven batch) | Done; superseded by `make build`, `gen1`, `gen2`, `fixpoint` and the per-target build directory |
| Phase 2 (bootstrap workarounds W01-W16) | Done as a gate: the selfhost reproduces itself. Individual workaround comments may remain in source as history; this plan no longer tracks them |
| Phase 3 (BST to WBT in the emitter pools) | Done for the five pools; `data_structures/bst.silica` is gone from `src`. Step 3.3 (`string_literal_pool`) is NOT migrated: it still deduplicates by linear list scan (`find_index_in_list`) |
| Phase 4, Phase 7 (compiler adoption of standard structures) | Withdrawn 2026-09-29, removed |
| Phase 5.1 (no `type` aliases) | Done: zero `type` aliases and zero named `struct` declarations in `compiler/src` (verified with `git grep`) |
| Phase 5.2 (no legacy stdlib `use`) | Done; compiler-internal stdlib is `wbt_map` and `OrderedMap` only |
| Step 6.1 (gen 2, differential, fixpoint) | Done: `make gen2`, `make fixpoint` (the fixpoint check also reports units emitted differently by gen2 than by gen1); logs under `/Volumes/2T/silica_builds/`. `trials/self_host_addition/` was not created; `make trials-gen1`, `trials-gen2`, `trials-both` run the whole tree against a generation instead |
| Step 6.3 (cutover) and 6.4 (bootstrap retirement) | Done: single tree `compiler/src`, no `silica-boot`, no Rust crate |

Open items that remain from this plan:

- Step 3.3, `string_literal_pool` linear scan.
- Orphans (removed 2026-10-16): `compiler/src/btree_set_nodeid.silica` (was excluded from the build by `topo_silica_config.sh`) and `compiler/src/fix_seed_emission.py` (not referenced by the Makefile) were removed from git on 2026-10-16.
- The reachability of provided trait methods across the exit-75 restart (defect A5) is fixed; see [../HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md](../HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md).
- The compiler still builds one unit per file with process-per-unit reclaim; the one-unit model is described in [../APPLICATION_IS_ONE_COMPILATION_UNIT.md](../APPLICATION_IS_ONE_COMPILATION_UNIT.md).

Everything below the status section is the original 2026-09-08 plan.

This document intentionally contains no Silica source code. It is written as fine-grained work items that an LLM can follow when migrating compiler internals.

## Global Rules

1. **Do not remove bootstrap until a self-hosted stage produces a passing `make integrate` on the full compiler tree.**
2. **Lists stay lists** where order and immutability are the model (tokens, AST declaration lists, SIR function lists). **Maps/sets** replace linear-scan or naive-BST lookups keyed by `string` or ordered scalars.
3. **Use trait-oriented WBT APIs** once stdlib modules exist: `wbt_map@empty({ compare_key, compare_value })`, `OrderedMap@get`, etc.—not legacy `btree_*` / `graph_adj_*` / `heap_binary_*` bootstrap modules and not width-specialized exports like `empty[int64, mem(normal)]/0`.
4. **No new named constructor-record struct types** (per traits doc Constructor Function Record Rule).
5. **Each migration step** adds or extends a trial under `trials/` before deleting the old path.
6. **Retire duplicated logic** only after self-hosted cross-module ABI is verified (see Phase 2).
7. **Safe dual-path freeze until cutover — relaxed 2026-08/09.** `silica-bootstrap-compiler` stays untouched. `src/` is edited **only** when the seed must gain a builtin or codegen fix that `src/` depends on (the bootstrap boundary: a new builtin is implemented in `src/`, the seed is rebuilt and published, and only then may `src/` use it — `list_nth` on 2026-09-08 is the worked example). Record each such seed change with the seed generation that publishes it. All alias/BST/WBT/ABI/dialect edits remain confined to `src/`. The default *trial* compiler is now the selfhost binary, not the seed.
8. **No `type` aliases and no named `struct` declarations in the parallel compiler source.** After Phase 5.1 / §12 dialect waves: `rg '^\s*type\s+\w+\s*='` and `rg '^\s*struct\s+\w+'` under `compiler/src` must stay at zero. Types follow [silica-specification.md](../silica-specification.md) §3.4.2 (inline records, `List[T]`, seed-legal tree encodings). Do not introduce temporary aliases or named wrapper structs.
9. **Self-host compile requires self-hostable parallel source first.** Do not claim a successful `build-selfhost` while `bst`, any `type` alias, or any named `struct` declaration remains in `src/`. Host is the seed `silica-compiler` from frozen `src/` with **E1047 on** — do not disable E1047 to pass the gate.

## Implementation Order

Critical path for full self-hosting without the bootstrap compiler (matches [standard_data_structures_implementation_plan.md](standard_data_structures_implementation_plan.md) §§11–13):

1. **Phase 0** — Audit, workaround inventory, stdlib smoke; stand up `src/` as a copy of frozen `src/`.
2. **Phase 5.1** — Remove every `type` alias from **`src/`** only (Global Rule 9).
3. **Phase 3** — In **`src/`**, replace emitter `bst` with WBT maps; drop `bst` from the parallel graph only (keep `src/data_structures/bst.silica`).
4. **Phase 2 (class-A) + §12 dialect rewrite** — Rewrite **`src/`** to seed-legal Silica (no named structs / no aliases; List + inline records + Wave C arena for trees) and fix remaining W-ids so the seed compiles the full parallel graph. Prefer edits in the parallel tree; shared host bugfixes only when they do not alter frozen `src/` contracts. **Do not** expand the seed to re-accept boot-era named structs.
5. **Phase 1** — Add dual-build targets: default stays bootstrap → `src/`; `build-selfhost` / `assembly-selfhost` build only from `src/` using the seed host.
6. **Phase 2 (remainder) + Phase 5.2** — Finish workaround cleanup and legacy `use` greps inside `src/`.
7. **Phase 6** — Self-host integrate + fixed-point on the parallel tree; **then** cut over (promote `src/` → production `src/`) and retire bootstrap from the default path.

Phase 2 class-A + dialect rewrite that block compile precede a green Phase 1 exit; deleting duplicated lookups (Step 2.2) waits until after Phase 1 ABI is verified and stays inside the parallel tree until cutover.

**Phase 3 requires** accepted `wbt_map` / `wbt_set` (Adams WBT [Ada93]) per the algorithm map — now available via standard-plan §§8A–§10. Do not adopt legacy `btree_nodeid` as the long-term compiler backend.

## Compiler-internal collection targets

Per [data_structure_to_algorithms.md](data_structure_to_algorithms.md) and [data_structures_as_traits.md](data_structures_as_traits.md):

| Compiler need | Trait | Target module | Algorithm | Needed for bootstrap retirement? |
| ------------- | ----- | ------------- | --------- | -------------------------------- |
| String-keyed symbol / literal tables | `OrderedMap` | `wbt_map` | Adams WBT [Ada93] | **Yes** (Phase 3) |
| Ordered scalar pools (optional) | `OrderedMap` / `OrderedSet` | `wbt_map` / `wbt_set` | Adams WBT [Ada93] | **Yes** (emitter pools) |
| Priority worklists | `Heap` | `brodal_okasaki_min` | Brodal–Okasaki [BO96] | **No** (not used in compiler today) |
| Graph structures | `DirectedGraph` | `graph_wbt_*` | WBT + WBT neighbors | **No** (symbol tables are maps, not graphs) |

**Not in scope for compiler or stdlib:** dense bitset graphs, Patricia tries, region binary/d-ary heaps, NodeIDBTree / CsrBTree bootstrap families.

## Phase 0 — Prerequisites (blocking self-hostable source and the build flip)

These are compiler/runtime fixes or stdlib gaps that block compiling the full `src/` tree with `silica-compiler` instead of `silica-boot`. Alias removal (Phase 5.1) and BST → WBT (Phase 3) are also on that critical path; this phase inventories them.

### Step 0.1 — Inventory bootstrap-only build assumptions + stand up `src/`

**Actions:**

1. Document that `src/Makefile` uses **two build models**:
   - Per-file `.silica` → `.ll` via `silica-boot` (compiler executable)
   - `silica.config` batch → `.sams` via `silica-compiler` (trials, `standard_data_structures/`)
2. List all Makefiles still pointing at bootstrap (7 found):
   - `src/Makefile`, `src/lexer/Makefile`, `src/effect_checker/Makefile`, `src/sir_generator/Makefile`, `src/emitter/Makefile` (+ parent rules for `parser/`, `type_checker/`, `module_checker/`, `ffi/`, `trait_checker/` via `src/Makefile`)
3. Identify bootstrap runtime dependency: `libsilica_compiler.a` linked into `silica-compiler` executable (`src/Makefile` lines 13–14, 143–148).
4. Note stray duplicates not in the build graph for later cleanup (do **not** delete from frozen `src/` in this step unless already proven unused by the default path):
   - `src/btree_set_nodeid.silica` (orphan bootstrap copy, removed 2026-10-16; superseded by target `stdlib/data_structures/wbt_set.silica`)
   - `stdlib/data_structures/` duplicate or `.bak` files if present
5. Create `compiler/src/` as a copy of frozen `src/`; add a short README: self-host migration edits only this tree; bootstrap and `src/` stay default until Phase 6 cutover.

**Exit criteria:**

- Written inventory checked into this plan's Completion Tracking table; `src/` present as the sole self-host edit target.

### Step 0.2 — Self-host compile feasibility matrix (read-only audit)

**Actions:** For each bootstrap workaround comment in `src/`, classify as:

- **A — Compiler bug** (must fix in `silica-compiler` before self-host)
- **B — Source workaround** (can delete once self-host compiles correctly)
- **C — Intentional** (unrelated to bootstrap, e.g. FailureReporter "bootstrap" in supervisor sense)

**Known bootstrap workaround sites (27 comments across 20 files):**

| ID | File | Issue | Class |
| -- | ---- | ----- | ----- |
| W01 | `build_output.silica` | `concat` drops second arg in inline `case` | A/B |
| W02 | `effect_checker_core.silica`, `effect_serializer.silica` | `length_bytes("")` returns non-zero | A |
| W03 | `lexer_runner.silica` | `skip_whitespace` sometimes no-ops | A |
| W04 | `atom_rodata.silica`, `int_rodata.silica` | `.asciz` / escaped-quote bugs | B (emitter style) |
| W05 | `type_checker_expressions_string_calls.silica` | string pattern-match issues | A/B |
| W06 | `type_checker_tuple_decompose_helpers.silica` | tuple binding decomposition bug; cross-module string return segfault | A |
| W07 | `sir_generator/terms/terms.silica` | cross-`.ll` string return segfault → duplicated lookup fns | A |
| W08 | `type_checker_core.silica` | sret/stack on deep module TC; `(bool,string)` tuple return ABI | A |
| W09 | `sir_generator/declarations/qualified_call_mangler.silica`, `trait_specialization.silica` | structural-vs-Named inference for `List`-typed fields | A/B |
| W10 | `parser_tuples.silica` | token.kind false-matches grouping kinds | A/B |
| W11 | `type_checker_expressions.silica` | `call_name_is_module_qualified` misclassification; `tc_` prefix collision | A/B |
| W12 | `parser_ast.silica` | nominal rebuild helpers for structural records; legacy recursive Expr representation | B |
| W13 | `parser/constraint_extract.silica` | tuple order for bootstrap codegen; stack overflow guard on case branches | A/B |
| W14 | `sir_generator/terms/identifiers.silica` | nested tuple destructuring codegen | A/B |
| W15 | `emitter/.../term_emitter.silica` | 6-param `emit_const` issue | B |
| W16 | `type_checker_core.silica` | `lookup_symbol_found` exists because `""` string compare unreliable | A |

**Exit criteria:**

- Every W-id has an owner phase (2, 3, or 7) and a trial or integrate check.

### Step 0.3 — Stdlib readiness for compiler-internal use

**Target (not yet implemented):** Adams WBT modules `wbt_map` and `wbt_set` with trait adapters per [data_structures_as_traits.md](data_structures_as_traits.md). Progress tracked in [standard_data_structures_implementation_plan.md](standard_data_structures_implementation_plan.md).

**Actions:**

1. **OrderedMap / OrderedSet:** Block compiler adoption on **`wbt_map` / `wbt_set` acceptance trials** (insert, delete, get, generic `string` keys). Do **not** wire compiler internals to legacy `btree_nodeid`, `btree_set_nodeid`, or CSR B-tree modules—they are obsolete relative to the algorithm map.
2. **Heap / PriorityQueue:** Not required for compiler symbol tables. If adopted later, use **`brodal_okasaki_min`** only—not `heap_binary_*` or `heap_dary_*`.
3. **Graph:** Not required for compiler internals (maps suffice).
4. ~~Add `src/silica.config.compiler_internal`~~ **Done differently:** compiler-internal stdlib membership is `LIB_STDLIB_MODULES` in `src/Makefile` (currently `wbt_map OrderedMap`), staged into `src/lib/` and topo-sorted by `topo_silica_config.sh` into `src/silica.config.compiler`. No `*_adapter` modules exist; `wbt_set`/`OrderedSet` are not compiler-internal.
5. Add compiler obligation checklist from traits doc §Compiler obligations: trait dispatch, function-record witnesses (E2017), `provided` block checking, `{ found: boolean, … }` get shapes.

**Exit criteria:**

- `wbt_map` / `wbt_set` pass stdlib acceptance trials for at least `string` and `int64` payload shapes.
- Minimal stdlib batch config compiles with smoke trial: `OrderedMap[string, int64, mem(normal)]` constructed via `wbt_map@empty({ compare_key, compare_value })` and queried via `OrderedMap@get`.

## Phase 1 — Build system: bootstrap → self-host staging

**Prerequisite:** Phase 0 inventory + `src/` tree; Phase 5.1 (zero `type` aliases in `src/`); Phase 3 (zero `bst` / WBT emitter pools in `src/`); Phase 2 class-A items **and** the §12 dialect rewrite (zero named `struct` declarations; List/inline/arena shapes) so the **seed with E1047 on** can compile that parallel tree. Claiming `build-selfhost` success before those source gates is invalid.

**Safe-transition note:** Phase 1 **adds** self-host targets; it does **not** change the default bootstrap → `src/` path and does **not** modify `silica-bootstrap-compiler`.

### Step 1.1 — Introduce dual-build Makefile switch

**Actions:**

1. Add `BOOTSTRAP_COMPILER` and `HOST_COMPILER` variables (root or `src/` Makefile) without changing default behavior.
2. Add target `build-selfhost`: requires existing `silica-compiler` (seed from last bootstrap build of frozen `src/`), compiles **`src/`** with the self-hosted compiler.
3. Keep `build-bootstrap` (frozen `src/` via `silica-boot`) as default until Phase 6 cutover.
4. Prefer consolidating the self-host path on batch config (Step 1.2); leave existing per-file `.ll` bootstrap recipes for `src/` alone.

**Exit criteria:**

- **Met.** `make -C src build` (aliases `build-selfhost`, `assembly-selfhost`) produces the selfhost binary from `src/` with `binaries/seed-compiler` as host and no bootstrap `.a`. `src/Makefile` still passes a `HOST_COMPILER` variable that `src/Makefile` ignores (it uses `SILICA_COMPILER ?= $(BINARIES_DIR)/seed-compiler`); delete or wire it.
- `src/Makefile` still builds the seed via bootstrap → frozen `src/`.

### Step 1.2 — Unify self-host build on `silica.config` batch mode

**Rationale:** `main.silica` already implements the batch pipeline (`silica.config`, dependency sort, `.sams` emission). Trials use this successfully; subdir `.ll` per-module builds are redundant for the linked executable (`src/Makefile` comment: "main.o contains everything").

**Actions:**

1. Create `src/silica.config.compiler` listing all parallel-tree `.silica` units in dependency order (lexer → parser → … → `main.silica`).
2. Add `make assembly-selfhost`: run `silica-compiler` against `src/` with that config → `.sams` → `.o` → link.
3. **Done, and stricter than planned:** the self-host link is Rust-free. `src/Makefile` links no `libsilica_compiler.a`; the runtime symbols come from the self-emitted `__silica_runtime.sams` plus `silica_rt_shim.s`, `deviceio_link_thunks.s` and `main_entry_alias.s`. Do not re-add an archive (see the POLICY block in that Makefile).
4. Do not retire bootstrap subdir `.o` production for frozen `src/` in this phase.

**Exit criteria:**

- Self-host binary from `src/` built through the `.sams` pipeline; no `main.ll` on the **self-host** critical path.

### Step 1.3 — Fix stack / resource limits for self-host input size

**Actions:**

1. Preserve/enlarge main-thread stack flags (`-Wl,-stack_size,0x10000000` in `src/Makefile`) in the new link recipe.
2. Add integrate trial compiling the full `src/silica.config.compiler` graph (compile-only or run `--version` smoke if available).

**Exit criteria:**

- Full compiler source batch compiles without stack overflow (constraint_extract case-depth guard W13 may become unnecessary—track in Phase 2).

### Step 1.4 — Bootstrap retirement gate (deferred to Phase 6)

**Actions (document only in Phase 1; execute in Phase 6 after fixed-point):**

1. Document **fixed-point procedure:** bootstrap-built seed → host₁ (from `src/`) → host₂; compare artifacts or run full `make integrate`.
2. Do **not** remove `silica-bootstrap-compiler` or change the default Makefile here.
3. Note the cutover checklist for Phase 6 (promote parallel tree, then retire bootstrap from default path).

**Exit criteria (Phase 1):**

- Fixed-point and cutover procedure written; bootstrap and frozen `src/` still the default.

## Phase 2 — Remove bootstrap workarounds in compiler source

Work items map to W-ids from Step 0.2. Prefer fixing and simplifying **inside `src/`**. Shared host/runtime bugfixes are allowed only when they do not change frozen `src/` contracts. Do not strip workarounds from frozen `src/` until Phase 6 cutover.

### Step 2.1 — String and empty-string reliability (W02, W16)

**Files:** `effect_checker_core.silica`, `effect_serializer.silica`, `type_checker_core.silica` (`lookup_symbol_found`).

**Actions:**

1. Add error-enforcement or unit trials for `length_bytes("") == 0` and reliable `""` equality.
2. Once green under self-host, collapse `(bool, string)` lookup pairs to single string return where safe (W08).

**Exit criteria:**

- W02/W16 trials pass; `lookup_symbol_found` documented as temporary or removed.

### Step 2.2 — Cross-module string / tuple ABI (W06, W07, W08, W14)

**Files:** `type_checker_core.silica`, `type_checker_tuple_decompose_helpers.silica`, `sir_generator/terms/terms.silica`, `sir_generator/terms/identifiers.silica`.

**Actions:**

1. Fix emitter/ABI for returning `string` across module boundaries on Apple Silicon.
2. Delete **four duplicated** symbol lookup implementations (status 2026-09-08: `…_local` is gone from `src/`; the other three remain — `type_checker_core.silica:381`, `type_checker_tuple_decompose_helpers.silica:349`, `sir_generator/terms/terms_helpers.silica:361`):
   - `type_checker_core@lookup_fn_type_by_name_and_module`
   - `type_checker_expressions@lookup_fn_type_by_name_and_module_local`
   - `type_checker_tuple_decompose_helpers@lookup_fn_type_by_name_and_module_infer`
   - `sir_generator/terms/terms@lookup_fn_type_by_name_and_module_sir`
3. Route all through `type_checker_core` exports.

**Exit criteria:**

- Single lookup implementation; `make integrate` green for module-checker and SIR trials.

### Step 2.3 — Parser / type-checker inference quirks (W09–W11, W13)

**Files:** `qualified_call_mangler.silica`, `trait_specialization.silica`, `parser_tuples.silica`, `type_checker_expressions.silica`, `constraint_extract.silica`.

**Actions:**

1. Fix structural-vs-Named inference for `List`-typed fields so manual `Declaration { … }` rebuilds in `clone_decl_with_first_param_type` are unnecessary.
2. Revisit `branch_depth` stack guard in `constraint_extract.silica` after self-host stack sizing.
3. Remove `tc_` prefix duplication if parser/type_checker symbol collision is resolved.

**Exit criteria:**

- Trait specialization and qualified-call mangler trials unchanged; reduced manual AST cloning.

### Step 2.4 — Lexer and build_output (W01, W03, W04)

**Actions:**

1. Fix root causes or confirm self-host already correct; simplify `sams_path_from_source`, rodata `.byte` emission, whitespace skipping.

**Exit criteria:**

- Workaround comments removed or marked "historical."

## Phase 3 — Replace `bst` in the parallel tree (`src/`)

**Prerequisite:** Step 0.3 — `wbt_map` / `wbt_set` acceptance trials green; Phase 5.1 complete (no `type` aliases in `src/`). **This phase is on the critical path before Phase 1** — self-host compile of the parallel tree must not depend on `bst`.

**Freeze:** Do not edit emitter modules or delete `bst` under frozen `src/`. Production continues to use `src/data_structures/bst.silica`.

**Current module (frozen `src/`):** Unbalanced BST with `BstNode { value, index, next_left, next_right }`, numeric/string compare via `string_parse@string_to_int64` hack for lexicographic order.

**Target (in `src/`):** `OrderedMap[string, int64, mem(normal)]` (and other key/value instantiations) backed by **`wbt_map`** — Adams weight-balanced tree with path copying [Ada93]. All lookups via **`OrderedMap@get`** / trait dispatch, not direct legacy module calls.

### Step 3.1 — Shared compile-time map helper module

**Actions:**

1. Add `compiler_maps.silica` under `src/` (or a self-host-only helper path):
   - `compare_string(a, b) -> :less | :equal | :greater` (atom contract per traits doc)
   - `compare_int64(a, b) -> atom` for numeric-key pools
   - `empty_string_int64_map()` → `wbt_map@empty({ compare_key: compare_string, compare_value: compare_int64 })`
   - `map_insert_or_get_index(map, key, value) -> { map, index, inserted }` using `wbt_map@insert`
   - `map_index_of(map, key) -> int64` using `OrderedMap@get` ( `{ found: boolean, value: int64 }` shape)
2. No type aliases of any kind; explicit `OrderedMap[Key, Value, mem(normal)]` at bindings.
3. Preserve functional persistence: every insert returns a new map value.

**Exit criteria:**

- Trial `compiler_string_index_map.silica` in `trials/` (self-host leaf) covers insert, lookup, duplicate key via WBT-backed map.

  Key identity follows the map's comparator, not the key's text. `empty_string_int64_map`
  orders by `compare_string`, so `"10"` and `"010"` are distinct keys. Numeric maps from
  `empty_numeric_string_int64_map` order by `compare_string_as_int64`, which compares
  `parse_decimal_string` results, so `"10"` and `"010"` are the **same** key: re-inserting
  `"010"` is a duplicate that returns the existing index and reports `inserted: false`.
  The trial therefore exits `0`.

### Step 3.2 — Migrate emitter literal pools in `src/` (5 modules)

| Module (under `src/`) | Frozen `src/` current | Migration in parallel tree |
| ------ | ------- | ----------- |
| `emitter/.../atom_table.silica` | `bst@bst_insert_string` + `ListAtomLexeme` | `OrderedMap[string, int64, mem(normal)]` via `wbt_map`; keep `ListAtomLexeme` for rodata order |
| `emitter/.../int64_literal_pool.silica` | `bst@bst_insert` (int64 keys) | `OrderedMap[int64, int64, mem(normal)]` with `compare_int64` |
| `emitter/.../float32_literal_pool.silica` | BST on stringified float | `wbt_map` keyed by `string` canonical form |
| `emitter/.../float64_literal_pool.silica` | same | same |
| `emitter/.../int_rodata.silica` | BST for int8–int64 print tables | Same WBT map pattern per width |

**Actions:**

1. In `src/` only: replace `use bst` with `use wbt_map`, `use OrderedMap`, `use compiler_maps`.
2. Remove `BstNode` fields from table structs in the parallel tree; store `OrderedMap[…]` in table record.
3. Add or extend self-host / emitter trials that compile against `src/` (do not break frozen `src/` goldens).

**Exit criteria:**

- Parallel emitter path green; zero `use bst` under `src/`; frozen `src/` still uses `bst` unchanged.

### Step 3.3 — Migrate `string_literal_pool.silica` in `src/` (list scan → map)

**Current (frozen):** O(n) list dedup for UTF-8 correctness.

**Actions:**

1. In `src/`: use `wbt_map`-backed `OrderedMap[string, int64, mem(normal)]` with **raw string ordering** via `compare_string` on full UTF-8 lexeme (not BST int64 hack).
2. Retain immutability contract and rodata emission order via auxiliary list (same as atom table).

**Exit criteria:**

- Parallel string literal / UTF-8 path green; frozen `src/` unchanged.

**Status 2026-09-08: not started.** `src/emitter/apple_silicon_mac/atoms/string_literal_pool.silica` still deduplicates by linear list scan (`find_index_in_list`); the five pools in Step 3.2 are migrated.

### Step 3.4 — Drop `bst` from the parallel graph only

**Exit criteria:**

- `src/` search paths no longer need `bst`; `src/data_structures/bst.silica` **retained** until Phase 6 cutover.

## Phase 5 — Type alias ban and API cleanup (parallel tree)

**Schedule:** Step 5.1 runs **before Phase 3 and Phase 1** on `src/` (standard-plan §11). Step 5.2 may complete after the first self-host binary. Frozen `src/` keeps its aliases until Phase 6 cutover.

### Step 5.1 — Remove every `type` alias from `src/` (including `TokenKind`)

**File (parallel):** `src/lexer/lexer_token_kind.silica` (known in frozen tree: `type TokenKind = int64`); re-grep all of `src/` before exit.

**Actions:**

1. In `src/` only: replace `TokenKind` with bare `int64` in signatures; `token_kinds()` returns an **inline** constant record (not a named `TokenKinds` struct type — that removal is part of the §12 dialect waves).
2. Remove any other `type` alias under `src/` — none may remain there.
3. Do not add replacement aliases or replacement named structs; do not edit frozen `src/` for this step (Global Rules 8–9).

**Exit criteria:**

- `rg '^\s*type\s+\w+\s*=' compiler/src` returns zero matches; frozen `src/` alias state unchanged; production lexer trials still pass via bootstrap → `src/`.
- Named-struct removal is tracked under standard-plan §12 waves A–C (Global Rule 9), not solely this step.

### Step 5.2 — Stop depending on bootstrap stdlib exports in compiler `use` graph

**Actions:**

1. Ensure compiler sources never `use` legacy bootstrap modules (`btree_*`, `graph_adj_*`, `heap_binary_*`, `heap_dary_*`) or width-specialized `empty[int64, mem(normal)]` exports.
2. Compiler-internal stdlib usage goes only through **`wbt_map` / `wbt_set`** and trait dispatch (`OrderedMap@…`, `OrderedSet@…`) per Phase 0.3 config.

**Exit criteria:**

- Grep for `btree_`, `graph_adj_`, `heap_binary_`, and width-specialized bootstrap exports under compiler `use` paths returns zero.

## Phase 6 — Validation, cutover, bootstrap removal

**Until Steps 6.1–6.2 pass, the §11 freeze still holds:** bootstrap and frozen `src/` remain the production default.

### Step 6.1 — Self-host integrate suite, generation 2, differential, fixpoint

**Status 2026-09-08:** de facto self-host integrate exists (every trial suite runs on the selfhost binary), but there is no `trials/self_host_addition/`, no gen-2 target, no differential and no fixpoint script. Follow the seven-step ladder in the status snapshot at the top of this document (steps 4–7) rather than the two-line sketch that used to be here.

**Actions:**

1. Add a `gen2` target to `src/Makefile`: `make build SILICA_COMPILER=binaries/silica-compiler` (selfhost compiles `src`), publishing as a selfhost generation; run the full trial tree under it. **Pause and report after this step.**
2. Differential: compile the same trial sources with gen 1 and gen 2 and diff every `.sams` (label counters `o[0-9]+` are the only expected noise; see `trials/` notes).
3. Fixpoint: gen 2 builds gen 3; compare binaries byte-for-byte modulo embedded metadata. Self-compiling once is *not* fixpoint.
4. (Done: `src/fix_seed_emission.py` was removed 2026-10-16.) Retire it before claiming fixpoint if it is still applied to any `.sams`.
5. Optionally add `trials/self_host_addition/` wrapping steps 1–3 so `make integrate` runs them.

**Exit criteria:**

- Gen 2 passes the full trial tree; gen-1/gen-2 differential clean; gen-3 == gen-2. Only then Steps 6.3–6.4.

### Step 6.2 — Update design docs

**Actions:**

1. Cross-link this plan from `standard_data_structures_implementation_plan.md` (section: "Compiler internal consumption").
2. When the parallel tree adopts WBT maps, add a note to `data_structures_as_traits.md` §Related documents or a short "Compiler adoption" subsection (implementation status remains driven by acceptance trials).
3. Prepare (but do not yet finalize) bootstrap-analysis “historical / retired” wording for Step 6.4.

### Step 6.3 — Cutover: promote `src/` → production `src/`

**Actions:**

1. Only after Step 6.1 fixed-point is green: replace production `src/` with the parallel tree contents (or atomic directory swap), preserving history per project policy.
2. Point default Makefile targets at the promoted tree / self-host build.
3. Remove `bst` from the promoted production tree if it was only retained for the frozen path.
4. Confirm production `src/` now has zero `type` aliases.

**Exit criteria:**

- Default build no longer depends on the pre-cutover frozen tree; alias/`bst` constraints hold on production `src/`.

### Step 6.4 — Remove `silica-bootstrap-compiler` from repo workflow

**Actions:**

1. Delete bootstrap references from default Makefiles (archive dual-path notes if useful).
2. Archive or remove `silica-bootstrap-compiler` crate per project policy (outside this plan's file scope).
3. Mark bootstrap-analysis doc historical / retired.

**Exit criteria:**

- No `silica-boot` in default build path.

## Historical: the first vertical slice (all landed between 2026-07-16 and 2026-09-02)

1. Step 0.1 inventory (read-only against frozen `src/` / bootstrap); optionally note orphan `src/btree_set_nodeid.silica` for later cleanup (removed 2026-10-16) — **do not delete from frozen `src/` in this PR unless already unused by the default build**
2. Copy `src/` → `src/` (or scripted sync) with README stating: edit only `src/` for self-host work
3. Step 5.1 in `src/` only: remove `type TokenKind = int64` (and any other aliases)
4. Step 3.1 `src/compiler_maps.silica` + self-host trial (explicit `OrderedMap[…]`; no aliases)
5. Step 3.2 migrate **only** `src/.../atom_table.silica` off BST onto `wbt_map`

**Then continue the critical path (still without touching bootstrap or frozen `src/`):**

6. Finish Phase 3 in `src/` (remaining emitter pools); drop `bst` from the parallel graph only
7. Phase 2 class-A fixes needed to compile `src/` with `silica-compiler`
8. Step 1.1+ `build-selfhost` / `assembly-selfhost` targets (default remains bootstrap → `src/`)
9. Phase 6 fixed-point, then cutover, then bootstrap retirement

That sequences **freeze production → parallel alias ban → parallel WBT emitter adoption → compileability → additive build flip → fixed-point → cutover**.

## Risks

1. **Chicken-and-egg:** Last bootstrap build of frozen `src/` seeds first self-host; document seed binary policy. Bootstrap stays available until Phase 6.4.
2. **Source-before-flip:** Self-host compile fails if aliases, `bst`, or named `struct` declarations remain in `src/`; do not reorder a green Phase 1 exit ahead of those gates. Disabling E1047 in a staging seed is not a valid substitute for the dialect rewrite.
3. **Drift between trees:** `src/` and `src/` can diverge; document refresh/cherry-pick rules and prefer landing unrelated bugfixes in both trees only when required for production.
4. **WBT stdlib gate:** Phase 3 requires accepted `wbt_map` / `wbt_set` (standard-plan §§8A–§10); do not permanently adopt legacy `btree_*` as a shortcut.
5. **Compile time / memory:** Full compiler batch may stress host compiler; may need staged `silica.config` shards before monolithic config.
6. **Trait compiler gaps:** `provided` blocks, graph bracket witnesses, and boolean `found` shapes from traits doc may block clean `OrderedMap@get` adoption until compiler obligations are met.

## Completion Tracking

Superseded by the Status (2026-10-16) tables at the top of this document. Remaining open: Step 3.3 (`string_literal_pool` linear scan). The two orphan files named there were removed 2026-10-16.
