# Use-Tree First Pass

**Status**: Phase 2 design / TODO  
**Date:** 2026-08-13  
**Applies to:**

- `compiler/src/main_parse.silica` (`parse_all_files_recursive`) and `compiler/src/main_driver_first.silica` (`prepare_compile_order`, the first-pass driver). There is one compiler source tree now (`compiler/src`); the seed/selfhost split this note was written against no longer exists.

**Implementation status (2026-10-16):** not implemented. `parse_all_files_recursive` still prints `Parsing <file>...`, `  Lexing...`, `  Parsing...` and runs `lexer_runner` and the full parser on every config path, and no parser entry that stops at the first function exists. The batch compile order file is still written by `main_driver_first.silica` and the run exits 75 as described below; `main_crash.silica` adds a second batch exit (76) not covered here. `topo_silica_config.sh` now lives in `compiler/src/`.

**Related:**

- Spec §19.3.1 (`use` must appear before any function definitions; E4005)
- Spec §19.4.4–19.4.5 (compilation order, dependency graph)
- [module_interface_cache_and_bottom_up_typecheck_plan.md](../module_interface_cache_and_bottom_up_typecheck_plan.md) (Kahn order, process-per-unit)

---

## Summary

The first process of a multi-unit `silica.config` batch must **build the module use-tree**, not compile. It lexes each unit and parses only the declaration prefix through the **first function**, extracts `use` edges, Kahn-sorts, writes `silica.compile.order`, and exits 75. Function bodies are not parsed on this pass. Progress text must say that a use-tree is being built.

A later process still does a full lex/parse of the unit (and any `use` target without a usable `.iface`) before module checking, type checking, and emit.

---

## Current Source State

`main` with no `silica.compile.order` calls `parse_all_files_recursive`, which runs `lexer_runner` and `parse_program` on **every** config path. It then `topological_sort_from_parsed` and `prepare_compile_order`. For more than one unit the process writes the order file and exits 75; those full ASTs are discarded.

Progress is `Parsing` / `Lexing...` / `Parsing...` per file, so the pass looks like a compile that never reaches `Emitting...`.

`extract_use_modules_from_program` only reads declaration tag 2 (`use`) and the imported names in `parameters`. Spec §19.3.1 and E4005 already require every `use` to appear before any `fn`. The graph does not need function bodies.

The compiler Makefile’s `topo_silica_config.sh` already approximates the same graph with a line scan of `use ...;`. That remains a membership/order hint. The compiler’s first pass is the authoritative in-process graph and must see comments, strings, and multi-line `use` correctly.

---

## Required Behavior

### First process (no `silica.compile.order`)

1. Print a use-tree banner, for example `Building use tree (N units)...`.
2. For each path in `silica.config`:
   - Lex the file (comments and strings must be tokens, not source text).
   - Parse only declarations that can precede a function: `module`, `use`, `export`, effect aliases, and any other non-`fn` top-level form.
   - **Stop at the first function declaration** (`fn` in declaration position; AST tag 0). Do not parse that function’s signature body or any later declaration.
   - Record `use` module names (tag 2) as directed edges to in-config modules.
   - Per-file progress names the use-tree work, for example `  uses: path.silica`, not a compile `Parsing...` / `Lexing...` / `Parsing...` sequence.
3. Kahn-sort; report a cycle as today.
4. Multi-unit: write `silica.compile.order` and exit 75 (`Compile order ready; exiting to reclaim memory before unit compiles...`).
5. Single-unit: the existing compile path still full-parses that unit before module checking. The use-tree prefix is not a substitute for the compile parse.

### Resume process (`silica.compile.order` present)

Unchanged: `parse_use_closure_work` full-parses the next unit and any transitive `use` target that has no usable `.iface`, then `compile_one_sorted_unit` (module check, type check, emit). Those messages stay `Parsing` / `Lexing...` / `Parsing...` / `Module checking...`.

### Stop rule

Stop at the first **function declaration**, not the first non-`use` line. `module`, `export`, and effect aliases may appear around `use` and must be skipped, not treated as the end of the prefix. A `use` after the first `fn` is not an edge on this pass; the later full parse reports E4005.

### What the prefix parse must get right

- `use a, b, c;` including whitespace and newlines between tokens.
- `use` inside comments or string literals is not an import.
- Empty prefix (no `use`, file starts with `fn`) is a valid leaf.

---

## Non-goals

- Skipping the resume-process full parse.
- Replacing `topo_silica_config.sh`.
- Incremental rebuild skipping unchanged units.
- Changing Kahn (still prerequisites before dependents; not a heap on raw `use` counts).

---

## Implementation Notes

- Add a parser entry such as `parse_use_prefix` / `parse_until_first_function` that reuses existing `use` / `module` / `export` extractors and returns when `is_fn_decl_start` (or equivalent) is true.
- Replace `parse_all_files_recursive`’s `parse_program` call with that entry. The returned “program” for the sort may be a decls-only prefix; `extract_use_modules_from_program` already ignores non-tag-2 decls.
- Keep fail-fast: a lex or prefix-parse error still aborts the batch before writing `silica.compile.order`.

---

## Completion Criteria

- First process of a multi-unit batch does not call `parse_program` on whole files.
- Use-tree progress is distinct from compile progress.
- Multi-line `use` and `use` in comments/strings match today’s full-parse graph.
- A `use` after the first `fn` is omitted from the first-pass graph and still fails E4005 on the compile parse.
- A multi-unit trial suite (`make integrate` in `trials/`) still compiles; independent files remain leaves.
