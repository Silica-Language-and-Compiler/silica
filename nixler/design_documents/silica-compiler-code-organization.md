# Silica Compiler Code Organization

## Overview

This document describes how the Silica compiler, which is written in Silica, is organized on disk. It
is the only compiler source tree: `compiler/src/` (the former `src_selfhost`). There is no bootstrap
compiler tree and no separate seed tree; the Rust bootstrap was retired and the seed is a published
Silica-built binary reached through `binaries/seed-compiler`. The layout follows Silica's design
principles of explicit structure and clear naming, for human and LLM readers alike.

**Key Principles:**
- One directory per compiler phase (lexer, parser, module checker, type checker, effect checker, SIR generator, emitter)
- One emitter backend directory per target, selected at build time
- Small units: a phase is split into many small modules, named by the feature they implement, so a feature change touches few files and one unit's compile fits in memory
- Consistent naming: file names carry the phase or feature prefix, and the module name equals the file stem
- New features add files and are wired in at a dispatcher; they do not rewrite existing files

## Directory Structure

```
compiler/src/
├── main.silica, main_*.silica      -- Driver: entry point, topo-sorted unit list, first/resume processes,
│                                      world/lists/specialize, per-unit pipeline (main_compile_pipeline),
│                                      emit, hygiene, iface skip, crash handling
├── lexer/                          -- lexer_core, lexer_keywords, lexer_operators, lexer_comments,
│                                      integer/float/float32/float64/boolean/string/atom literal lexers,
│                                      lexer_token_kind, lexer_runner, lexer_recursion_phases,
│                                      lexer_supervisor_phases
├── parser/                         -- constraint-propagation parser (see parser_design.md)
│   ├── constraint_core, constraint_extract_*   -- constraints and the extraction passes (decls, params,
│   │                                              slots, expr, expr_bindings, expr_lits, lambda_lift,
│   │                                              hof_wrap, validate)
│   ├── capabilities/                -- one file per parsing capability (capability_fn_decl, _case,
│   │                                   _list, _sequence, _trait, _actors, _foreign, _memory_region,
│   │                                   _module, _effect_decl, _supervisor_phases, _tuple_decompose, ...)
│   ├── parser_core, parser_ast, parser_tuples, parser_runner, constraint_runner,
│   │   instantiated_fn_name, parse_in_actor
├── module_checker/                 -- module_checker_core/_device/_ffi; module_iface and
│                                      module_iface_type_dag (the .iface interface files)
├── type_checker/                   -- type_checker_core, _runner, _modules, _lists, _collections,
│   │                                  _memory_regions, _recursion, _recursive_tuples, _supervisor,
│   │                                  _failure_reporter, _cast_convention, _start_order,
│   │                                  _builtin_signatures, _callee_env(_cache), type_interner,
│   │                                  type_surface_cache
│   ├── declarations/                -- function declaration validation
│   ├── expressions/                 -- about 56 files: dispatch_*, call_*, user_call_* (check,
│   │                                   resolve, world), actors, atoms, bindings, control, data,
│   │                                   literals, tuples, numeric builtins, strings, regions, device
│   ├── traits/                      -- type_checker_traits, trait_specialization, placeholders
│   └── device/                      -- device description checks
├── trait_checker/                  -- trait_checker_core
├── effect_checker/                 -- effect_checker_core, _capabilities, _declarations, _lists,
│                                      _memory_regions, _propagation
├── ffi/                            -- ffi_abi_checker, ffi_placement_checker, ffi_taint_checker,
│                                      ffi_sidecar_loader, ffi_link_manifest
├── sir_generator/                  -- AST to SIR (see sir_design_spec.md)
│   ├── sir_generator_core, sir_ast, sir_call_verify, sir_target_verify
│   ├── declarations/                -- functions, traits, dispatcher, ffi, overload and qualified-call mangling
│   ├── terms/                       -- about 45 files: per-type binary ops and calls (int8 ... uint64,
│   │                                   float16/32/64), literals, identifiers, lists, tuples, structs,
│   │                                   case/sequence/region/actor lowering, user calls, device calls
│   ├── patterns/, effects/, types/
├── lowering_cleanup/               -- lowering_cleanup_core
├── diagnostics/                    -- diagnostics_core (error codes and messages; registry in ../error_codes.md)
├── data_structures/                -- compiler_maps, string_escapes, string_parse
├── build_output/                   -- build_output (compiler artifacts written by the driver)
├── lib/                            -- OrderedMap, wbt_map, Supervisor (the compiler's own library copies)
├── emitter/                        -- one backend per target; see below
└── runtime_asm/                    -- hand-written assembly shims per hosted target
                                       (silica_rt_shim.s, deviceio_link_thunks.s)
```

The pipeline runs per compilation unit in this order: lex, parse, module check (interface files),
type check, trait check, effect check, FFI checks, SIR generation, lowering cleanup, emit. The stage
sequence is wired in `main_compile_pipeline.silica`; the driver processes (`main_driver*.silica`)
decide which units run in which process (`main_driver_first` computes the compile order and the
process exits 75 between units to be resumed; the prefix-only use-tree pass is still a design,
`Phase2_TODO/use_tree_first_pass.md`).

### Emitter backends

`emitter/<target>/` holds one code-generation backend. Targets present today:

| Directory | Target |
| --------- | ------ |
| `apple_silicon_mac/` | macOS on Apple Silicon (AArch64) |
| `linux_aarch64/` | Linux AArch64 hosted |
| `linux_x86_64/` | Linux x86-64 hosted (`regs/` holds the register and frame model README; `ladder/` the bring-up ladder programs) |
| `ESP32-S3_raw/` | ESP32-S3 bare metal, native Xtensa (`board/` holds the board runtime, apps and tools; `board_pack.silica` the board pack) |

Every backend has the same internal shape: `emitter_core.silica`, `module_linkage.silica`, and the
subdirectories `atoms/` (atom table and read-only data pools), `constraints/`, `control/`,
`effects/`, `recursion/`, `shared/` (register conventions; ISA helpers on Xtensa) and `terms/`
(per-term emission: calls, case, let, primitives, inline print and string routines, FFI and runtime
assembly). The target is chosen with `make TARGET=<name>` (see `emit_target.mk`); the platform table
of record is `project_makefiles/platform/platforms.mk`. A backend other than the host's is
published as `binaries/silica-compiler-<target>`.

## Naming Convention

Files are named for the phase or feature they implement; the module name equals the file stem.
Prefixes group related files within a phase and avoid collisions:

- `lexer_*` and `<type>_lexer_literals` in `lexer/`
- `constraint_*`, `capability_*`, `parser_*` in `parser/`
- `type_checker_*` (and `tc_decl_*`, `trait_*`) in `type_checker/`
- `effect_checker_*`, `sir_*`, `terms_*`, `module_checker_*`, `ffi_*`, `main_*`
- `term_*`, `print_*_inline`, `*_runtime_asm` in an emitter's `terms/`

Examples:
- `lexer/lexer_core.silica` - core lexer functionality
- `parser/capabilities/capability_case.silica` - case-expression parsing capability
- `type_checker/expressions/type_checker_expressions_user_call_resolve.silica` - user-call resolution
- `sir_generator/terms/int64_binary_ops.silica` - int64 binary operators in SIR
- `emitter/apple_silicon_mac/terms/term_emit_kind_case.silica` - case emission

## Adding a New Feature

1. **Lexer**: add a token kind or literal lexer under `lexer/` only if new tokens are needed.
2. **Parser**: add a capability file under `parser/capabilities/` and wire it in at the constraint dispatcher.
3. **Type checker**: add the rule under `type_checker/expressions/` (or `declarations/`, `traits/`), and register builtin signatures in `type_checker_builtin_signatures.silica` when it is a builtin.
4. **Effect checker and diagnostics**: add effect rules to `effect_checker/`; register any new error code in `error_codes.md` and `diagnostics/`.
5. **SIR**: add lowering under `sir_generator/terms/` (or `declarations/`, `patterns/`).
6. **Emitters**: implement the term in every backend under `emitter/*/terms/`; a backend that cannot yet do it must reject the program with a diagnostic rather than emit wrong code.
7. **Trials**: add a trial under `trials/` with its `.scout` golden; a defect with no covering trial gets a trial even if the fix is deferred.

Edits are crafted one scoped site at a time; no tree-wide batch rewrites (see `compiler/src/README.md`).

## List trials (`trials/list_addition/`)

Executable **list** trials live under `trials/list_addition/` and follow the implementation design in
`design_documents/list_implementation_design.md`: list operations run inside
`sequence proc[mem(<space>)] ... produces pure ... end`, with `device_io` added when printing.
Non-`normal` memory spaces (for example `normal_writethrough`) are illustrated in
`list_int64_mem_writethrough.silica`. `list_uint32_prepend_second_chunk.silica` stresses multi-chunk
spines via repeated `prepend`; `list_int64_recursive_sum.silica` covers recursive helpers with
`sequence proc[mem]` inside the function (no `proc` on the function). List support lives in
`parser/capabilities/capability_list.silica`, `type_checker/type_checker_lists.silica`,
`effect_checker/effect_checker_lists.silica`, `sir_generator/terms/list_terms.silica`, and the
emitters' `terms/prims/prims_list.silica`.

---

## Relationship to Specification

- **Lexical Structure** -> `lexer/`
- **Syntax** -> `parser/`
- **Type System** -> `type_checker/`
- **Effect System** -> `effect_checker/`
- **Actor Model** -> `type_checker/expressions/type_checker_expressions_actor*.silica`, `sir_generator/terms/actor_calls.silica`, the emitters' runtime assembly
- **Memory Model** -> `type_checker/type_checker_memory_regions.silica`, `effect_checker/effect_checker_memory_regions.silica`, `sir_generator/terms/memory_region_calls.silica`

Section numbers are in `silica-specification.md`; each feature group corresponds to a specification
section, which makes completeness easy to verify.
