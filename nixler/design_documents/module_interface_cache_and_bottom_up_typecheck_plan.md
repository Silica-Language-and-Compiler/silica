# Module Interface Cache and Bottom-Up Type Checking

**Status:** Implemented (phases 0-4); see Implementation status (2026-10-16) below  
**Date:** 2026-07-25 (status 2026-10-16)  
**Applies to:**

- `compiler/src/` (the only compiler tree; the dual seed/self-host trees this plan was written for no longer exist)

**Related:**

- Spec §28.1.1–28.1.2 (dependency tracking, `.types` module cache)
- Spec §19 (modules, `use` / `export`)
- [Phase2_TODO/use_tree_first_pass.md](./Phase2_TODO/use_tree_first_pass.md) (first process: uses-only prefix parse)
- Spec §3.4.2 (inline-only types; no user type aliases)
- Seed type-checker work: surface→type_id cache and id-first equality (reduces cost of fat export type strings once loaded)

---

## Implementation status (2026-10-16)

Phases 1-4 are implemented in `compiler/src/module_checker/module_iface.silica` (extract, publish, read,
stub injection, invalidation) and `module_iface_type_dag.silica` (the interned type-DAG persisted in
the iface). Where each design point lives:

| Plan item | Implementation |
| --- | --- |
| Draft extract, publish after type-check success | `publish_module_iface/4`, called from `main_compile_pipeline.silica` after a successful type check |
| Failed check deletes a stale iface | `unpublish_module_iface_at_path/1` on each failure path in `main_compile_pipeline.silica` |
| Location | beside the unit: `<unit>.iface` next to `<unit>.sams` (under the per-target build directory `compiler/build/<TARGET>/` for compiler builds; beside the source for trials) |
| Format | text, line-oriented; magic `SILICA_IFACE_V1`, `format=2`, `stamp=selfhost-iface-7`, `source=`, `source_hash=`, `deps=`, `deps_hash=`, `export_trait=`, `export_count=`, `impl_count=`, then a `===DAG===` section (names and type nodes) replacing the v1 type-surface strings |
| Read path | `load_ifaces_for_module_names/2` then `import_ifaces_into_context/2` (`add_exports_by_surface`); dependents type-check against iface stubs (`append_iface_stub_programs/2`), not dependency ASTs |
| Invalidation (phase 3) | header validated on load: magic, format version, compiler stamp, source hash and dependency hash; `iface_usable_for_source/2` gates use |
| Parse skip | `main_iface_skip.filter_use_paths_missing_iface/3`, used by `main_parse.silica`: a `use` target with a usable iface is not re-parsed |
| Trial coverage | `modules_addition` and `generic_modules_addition` (every trial unit leaves a `.iface`); trait specialization across stubs is pinned by `traits_addition/train_defect_a5_*` |

Differences from the plan as written:

- v1 stored type surfaces as strings; format 2 stores the DAG (the plan's phase 4) and the compiler stamp is a literal in `iface_compiler_stamp/0`, bumped by hand when the format or a consumer changes.
- Trait specialization and call mangling still need provided-method data not carried by plain exports; the pipeline runs `specialize_iface_stub_world` over stub programs before mangling (the A5 fix), so a dependent sees the same overload set whether the dependency was parsed in-process or loaded from its iface.
- There is no `.cache/ifaces` directory; the plan's "or alongside unit outputs" alternative was taken.
- The export-conflict check named `E4001` in section 11 is now `E4013 DuplicateExport` (E4001 is the internal unlowered-builtin code); self-import is `E4008`.
- Not verified here: the correctness checklist in section 11 was not re-audited item by item, and phase 5 trials named in section 10 (stale iface rejected, dependent type-checked with the dependency AST omitted) were not found as separate named trials.

Per [APPLICATION_IS_ONE_COMPILATION_UNIT.md](./APPLICATION_IS_ONE_COMPILATION_UNIT.md), the iface cache is part of the per-file build that works around compiler memory; no language or runtime feature may depend on it.

---

## 1. Problem

Type-checking a thin module such as `term_emit_kind_compound.silica` OOMs even though its own AST is tiny.

**Cause (for that file):** while type-checking unit `U`, `build_module_world` loads **full** `Program` **ASTs** for the transitive `use` closure. Importing exports (especially fat signatures from `term_emit_kind_compound_part1`) then walks those ASTs and interns huge structural function types into the env.

Peak type-check RAM for `U` is dominated by:

1. **Dep world = full programs** (primary for thin shims)
2. **Interning fat export types** from those deps
3. **Not** `U`’s own AST when `U` is a forwarder

SIR generation still needs `U`**’s** AST through emit. The fix must not discard `U`’s AST before SIR; it must stop using **dep** ASTs as the type-check world.

---



## 2. Goals

1. Persist a per-module **interface (iface)** containing export data sufficient for type-checking dependents.
2. Type-check in **dependency order** (bottom-up) using existing Kahn topological sort.
3. When type-checking `U`, resolve `use M` from `M.iface`, not from `M`’s full AST.
4. Keep `U`’s AST through module check → type check → SIR → emit for `U`.
5. Implement in **both** `src` and `src` with the same design; dialect differences only in data-structure syntax (named structs vs inline records / `List[…]`).
6. Remain correct under process-per-unit (ifaces on **disk** so the next process can read them).



### Non-goals (this plan)

- Full incremental rebuild skipping unchanged units (may follow once ifaces exist).  
- Discarding ASTs before SIR for the unit under compilation.  
- Language-level type aliases (§3.4.2 forbids them).  
- Replacing Kahn with a heap keyed on raw `use` counts (incorrect).

---



## 3. Design overview

```text
Use-tree pass (lex + parse through first `fn` only; see use_tree_first_pass.md)
    → Kahn topo order (deps before dependents)
    → For each unit U in order:
         Full parse of U (and missing-iface `use` targets)
         Module-check U
         Extract draft export table from U’s decls (in memory)
         Type-check U using dep ifaces (not dep ASTs)
         On type-check success: publish U.iface to disk
         SIR + emit U (still using U’s AST)
         (process-per-unit: exit; next process loads ifaces from disk)
```

**Lazy variant (optional later):** on `use M`, if `M.iface` missing, type-check `M` first (DFS post-order). Equivalent to topo; still not use-count heaps. Prefer the existing global Kahn order for the first implementation.

---



## 4. Interface artifact



### 4.1 Location and naming

Per spec §28.1.2 spirit, store under a build/cache directory next to compile outputs (exact root may match existing object/SIR dirs):

```text
.cache/ifaces/<module_name>.iface
```

or alongside unit outputs:

```text
<build_out>/<module_name>.iface
```

**Requirement:** path must be stable and readable by a fresh process-per-unit child.

### 4.2 Logical contents (v1)

Enough to replace `add_exported_symbols_from_items` / `apply_use_add_symbols_loop` for deps:


| Field                     | Purpose                                                                                 |
| ------------------------- | --------------------------------------------------------------------------------------- |
| `module_name`             | Module id (filename stem)                                                               |
| `compiler_stamp`          | Seed/selfhost version or content digest of compiler                                     |
| `source_hash`             | Hash or mtime+size of `.silica` source                                                  |
| `dep_module_names`        | Direct `use` list (invalidation)                                                        |
| `exports[]`               | See below                                                                               |
| `export_trait` (optional) | Trait module metadata if present                                                        |
| `flags` (optional)        | e.g. dangerous module, supervisor/failure-reporter markers needed by module/type phases |


Each `exports[]` entry:


| Field           | Purpose                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------- |
| `name`          | Function name                                                                                               |
| `arity`         | Export arity                                                                                                |
| `type_surface`  | Full function type string `(T1,…,Tn) -> R` (same text `build_function_type_for_module_export` builds today) |
| `effects`       | Declared effect list encoding                                                                               |
| `source_module` | Always this module (for env `source_module`)                                                                |


**v1 stores type surfaces as strings** (matches today’s env). Later optimization: store interned type-DAG blobs to avoid re-parsing multi-KB surfaces (pairs with seed surface→id cache).

### 4.3 Format

Pick one and use it in both trees:

- **Text, line-oriented** (easiest to debug; good for v1), or  
- **Length-prefixed records** if string escaping becomes painful.

Include a leading magic + format version byte/line.

### 4.4 When to extract vs publish


| Stage                         | Action                                                                                                                                |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Module check**              | Build **draft** export table in memory from decls (same data as today’s export walk). Do **not** treat as trusted for dependents yet. |
| **After type check succeeds** | **Publish** draft → `U.iface` on disk.                                                                                                |
| **Type check fails**          | Do not publish; delete stale `U.iface` if present.                                                                                    |


Module check is the right place to *construct* the table; type check success is the right place to *commit* it.

---



## 5. Kahn ordering (both trees)



### 5.1 Already present

Both `src/main.silica` and `src/main.silica` already:

- Build dep edges from `use`  
- Compute `in_degree`  
- Run `kahn_topological_sort`  
- Compile units in that order

The **first** process must collect those `use` edges with a **prefix parse** (lex + declarations through the first `fn`), not `parse_program` on whole files. See [use_tree_first_pass.md](./Phase2_TODO/use_tree_first_pass.md). Today’s `parse_all_files_recursive` still full-parses every unit and discards the ASTs on the 75-exit; that is the work this prefix pass replaces.

**Do not replace this with a min-heap on “number of** `use`**s”.**  
Static use-count is not a topological key. Kahn’s ready set is “remaining unmet prerequisites == 0” (queue is enough; a heap is optional and must key on remaining in-degree / readiness, not raw use count).

### 5.2 Required guarantee for iface plan

Compile/type-check order must remain **prerequisites before dependents**, so when `U` runs, every direct `use` target already has a published iface (or is forced to compile first on cache miss).

Process-per-unit already resumes via `silica.compile.order`; iface files must be written before the process exits after a successful unit.

---



## 6. Type-check integration



### 6.1 Today

```text
build_module_world(parsed, U)
  → ListNamedProgram of full Programs for transitive uses
type_check_program_with_modules(U, world)
  → apply_use_* walks each dep Program’s declarations
  → build_function_type_for_module_export → add_symbol
```



### 6.2 Target

```text
build_typecheck_world(U)
  → current Program = U only (full AST)
  → deps = ListModuleIface loaded from disk/memory
type_check_program_with_modules(U, iface_world)
  → apply_use_* iterates iface.exports → add_symbol(name, type_surface, effects, source_mod)
```



### 6.3 Hook points (both trees)


| Area                             | Change                                                                                                                                                                                             |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `main.silica`                    | After successful type check in `compile_to_sir_module` (or immediately after TC returns ok), write iface. Before TC, load dep ifaces instead of/in addition to `build_module_world` full programs. |
| `type_checker_callee_env.silica` | `apply_use_add_symbols_loop` / `add_all_export_symbols_from_program`: prefer iface path; keep AST path as fallback when iface missing.                                                             |
| `check_use_conflicts_ordered`    | Can use iface export keys (`name/arity`) without full ASTs.                                                                                                                                        |
| Module checker                   | Optionally share draft-export extraction helpers with iface writer (avoid two divergent export walkers).                                                                                           |




### 6.4 Fallback

If `M.iface` is missing or invalid:

1. Type-check / compile `M` first if not done (should be rare if Kahn order held), or
2. Fall back to today’s full-AST world for `M` only, then publish iface.



### 6.5 What stays on the AST path

- **Current unit** `U`**:** full AST through SIR/emit.  
- **Trait specialization / call mangling** that still need dep `Program`s: keep using parsed/specialized programs until those phases are taught to use ifaces (phase 2). Document any temporary dual-load.

---



## 7. Invalidation

Rebuild or ignore iface when:

1. Source hash/mtime of the module changes
2. Any **direct or transitive** dep iface/source changes (structural types in export surfaces may embed dep shapes)
3. `compiler_stamp` mismatches
4. Format version mismatches
5. Explicit clean (`make clean` / delete `.cache/ifaces`)

**v1 practical rule:** if any dep in the Kahn prefix of `U` was recompiled in this run, treat `U`’s iface as dirty after `U` recompiles (always rewrite `U.iface` on successful TC). Across runs, compare `source_hash` + recursive dep hashes stored in the iface header.

---



## 8. RAM behavior (expected)

For thin `U` with fat deps (e.g. `term_emit_kind_compound`):


| Component                        | Before          | After                   |
| -------------------------------- | --------------- | ----------------------- |
| Dep full ASTs in TC world        | Yes (large)     | No                      |
| Dep export type strings / intern | Yes             | Yes (necessary)         |
| `U` AST                          | Small           | Small                   |
| Peak during TC of `U`            | World-dominated | Export-import-dominated |


For fat `U` (e.g. `part1`), iface helps the dep slice; `U`’s own annotations remain costly — mitigated by seed id/surface cache (already started), not by iface alone.

**Do not discard** `U`**’s AST after TC** — SIR needs it. Process-per-unit already drops process memory after the unit finishes.

---



## 9. Dual-tree implementation strategy



### 9.1 Shared design, parallel code

Implement the same phases in both trees. Keep logic aligned; accept dialect differences:


| Concern         | `src` (seed)                                      | `src`                          |
| --------------- | ------------------------------------------------- | --------------------------------------- |
| Records / lists | Named `struct` lists OK in seed dialect           | Inline records + `List[T, mem(normal)]` |
| Iface I/O       | `DeviceIO` file helpers already used by main      | Same                                    |
| Kahn sort       | Already present                                   | Already present                         |
| Callee env / TC | `type_checker_callee_env`, `type_checker_modules` | Mirror modules under `src`     |




### 9.2 Suggested module layout (each tree)

Add a small focused module (names illustrative):

- `module_iface.silica` — draft extract, serialize, deserialize, validate stamp  
- Optional: `module_iface_io.silica` if I/O should stay out of pure helpers

Wire from `main.silica` and `type_checker_callee_env.silica`.

### 9.3 Order of landing

Prefer **seed (**`src`**) first** if the OOM is observed while the seed binary type-checks `src`. Then port the same design to `src` so self-host builds stay capable.

Alternatively land skeletons in both trees in the same change set if churn control allows.

---



## 10. Phased implementation plan



### Phase 0 — Instrumentation (short)

- Log per-unit: size of module world (program count), whether TC fails/OOM, export type string lengths for imported symbols.  
- Confirm Kahn order already places deps before `term_emit_kind_compound`.  
- **Exit:** measurements that show world size vs self size for the OOM unit.



### Phase 1 — Draft extract + write-only iface (seed, then selfhost)

- Implement export-table extraction (share logic with export symbol builder).  
- After successful type check, write `U.iface`.  
- No read path yet.  
- **Exit:** successful full compile writes ifaces for all units; failure deletes/leaves unpublished.



### Phase 2 — Read path for `use` (type check)

- Load dep ifaces in topo order.  
- Change `apply_use_*` to populate env from iface.  
- `build_module_world` for TC becomes “current AST + dep ifaces” (or empty named programs for deps).  
- Keep AST fallback if iface missing.  
- **Exit:** `term_emit_kind_compound` (and similar shims) type-check without loading `part1`’s full AST; no correctness regressions on module trials.



### Phase 3 — Process-per-unit + invalidation hardening

- Verify child process finds ifaces written by parent/prior units.  
- Implement stamp/hash invalidation.  
- Clean targets remove ifaces.  
- **Exit:** large `src` config completes TC under process-per-unit without OOM on atoms trials.



### Phase 4 — Shrink remaining cost (optional)

- Store compact type-DAG in iface instead of giant surfaces.  
- Ensure specialization/mangling do not re-pull all dep ASTs into the TC heap (lazy load only if those phases need them, after TC).  
- Align with spec `.types` naming if desired.



### Phase 5 — Trials and docs

- Add trials: iface written; dependent type-checks with dep AST omitted; stale iface rejected; conflict `E4001` still fires from iface keys.  
- Update design_documents README index if the tree maintains one.  
- Cross-link from §28.1.2 notes if appropriate (informative, not a language change).

---



## 11. Correctness checklist

- [ ] Export set matches `export name/arity` + decl resolution used today  
- [ ] `source_module` on imported symbols unchanged (shadowing / qualified calls)  
- [ ] Cross-module export conflicts (`E4001`) still detected  
- [ ] Self-import (`E4008`) unchanged  
- [ ] Failed TC never leaves a new good iface  
- [ ] Kahn cycle detection unchanged  
- [ ] SIR/emit still see current unit AST  
- [ ] Dangerous / supervisor / failure-reporter module flags available if TC or module phase needs them from iface  
- [ ] Seed and selfhost behavior match for the same sources (modulo dialect)

---



## 12. Risks and mitigations


| Risk                                                       | Mitigation                                                                              |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Iface omits data TC still reads from dep AST               | Audit `world` uses during TC; extend iface; fallback to AST until covered               |
| Structural types in exports embed dep details; stale iface | Invalidate on dep changes; rewrite iface every successful compile in-run                |
| Giant `type_surface` still OOMs on import                  | Seed surface→id cache; later DAG encoding in iface                                      |
| Dual trees drift                                           | Same phase checklist; shared golden trials                                              |
| Mangling/specialization needs dep programs                 | Load those **after** TC or keep separate specialized cache; do not put them in TC world |


---



## 13. Success criteria

1. Type-checking `term_emit_kind_compound.silica` no longer loads full ASTs of `part1`/`part2`/`part3`/compare into the TC module world when valid ifaces exist.
2. Measurable drop in peak RSS during that unit’s “Type checking…” phase.
3. Existing module/export/use trials green on both seed-built and (when applicable) selfhost-built compilers.
4. Process-per-unit builds of large configs remain correct with ifaces on disk.

---



## 14. Summary

- **Create** export iface data at module-check time (draft); **publish** after type-check success.  
- **Use** ifaces for dep `use` resolution during type check.  
- **Order** with existing **Kahn** topo sort (not a use-count min-heap).  
- **Keep** current-unit AST through SIR; **stop using** dep ASTs for type check.  
- Land in `src` **and** `src` with the same phases; seed-first if seed is what OOMs on selfhost sources.

