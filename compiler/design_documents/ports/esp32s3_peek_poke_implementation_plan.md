# Peek and poke on `ESP32-S3_raw` — Implementation Plan

**Scope:** the "plus peek and poke" half of **ESP32-S3 board release 1** ([ROADMAP.md](../../../ROADMAP.md) §"The four
paths", row ESP32-S3; §"First milestone"). It is the board-release gate for that path, not one of the numbered
enhancement chunks, and chunk 16 (raw chip features, the `device` space) lists it as a prerequisite
([ROADMAP.md](../../../ROADMAP.md) chunk 16). Apple Silicon and Linux AArch64 (and Linux x86-64, which takes the Linux
AArch64 fixed point) take the same shared-compiler change plus a rejection in their emitters and re-establish their
fixed points; nothing they already run changes ([ROADMAP.md](../../../ROADMAP.md) "Peek and poke" paragraph).
**Authority:** [silica_device_actor_specification.md](../silica_device_actor_specification.md) (normative language
rules: §1–§6, §10, §11), [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5 (the port-level
lowering: what the shared stages do, what an OS-free emitter does, what a hosted emitter does; §5.5 is the split),
and [silica-specification.md](../silica-specification.md) §4.4.6, §4.5.1, §9.1.1, §9.2.2. The device specification wins
where this plan and it differ.
**Companion:** [esp32s3_peek_poke_implementation_details.md](esp32s3_peek_poke_implementation_details.md) (the SIR
node shapes, the description table, the board-pack window table, the exact Xtensa lowering, and the hosted
rejection mechanics). **Port status:** [esp32s3_port_status.md](esp32s3_port_status.md) §4.2 is the row this plan
closes.

## Implementation status (2026-10-16)

Work items 1 to 19 are in the tree; the plan's text below keeps its 2026-09-29 starting position ("What exists
today" is that position, not the present one). Where each piece lives now:

| Items | Where |
| --- | --- |
| 1 `register_rwr` effect | `effect_checker/effect_checker_core.silica` (`is_builtin_effect`; a `sequence proc[register_rwr] ... produces pure ... end` does not discharge it, so callers must declare it) |
| 2 lexer and parser surface | keywords `spawn_device`, `spawn_device_registered`, `device_actor_ref`, `device_window`; register markers absorbed at the postfix choke point |
| 3 built-in trait files | `compiler/stdlib/DeviceDescription.silica`, `Register8.silica` to `Register64.silica` (an app lists them in its `extra_sources.txt`) |
| 4, 5, 8 descriptions, prim checks, write-one-to-clear warning | `type_checker/device/type_checker_device_descriptions.silica`, `type_checker/expressions/type_checker_expressions_device.silica`; codes E2201 to E2215, E2219 (device access in `main`), warning W2201 ([error_codes.md](../../error_codes.md)) |
| 6, 7 device workers, module rules | `module_checker/module_checker_device.silica`; E2216, E2217, E2223 to E2225, E2230 to E2233 |
| 9 SIR lowering | `sir_generator/terms/sir_device_calls.silica` (casts lower as `actor_cast_device` / `actor_cast_device_registered`, spawns as `spawn_device` / `spawn_device_registered`) |
| 10, 11 capability query and rejection pass | `emitter_core@unsupported_prim_reason` in each of the four emitters; `sir_generator/sir_target_verify.silica` reports E2220 and stops the driver before `emit_module` |
| 12, 13 hosted emitters | the three hosted `terms/prims/prims.silica` catch-alls write an `.error` line naming the prim (they are reached only if the pre-emit pass is bypassed); the device-worker intrinsics are carried by the hosted runtimes with a third registry |
| 14 window table | `emitter/ESP32-S3_raw/board_pack.silica` (12 windows, `window_containing`, `window_allows_width`), twin `board/runtime/rt_device.S`; the draft in this directory, [board_pack.silica](board_pack.silica), is the design copy |
| 15, 16 `map_device`, `peek`, `poke` | `emitter/ESP32-S3_raw/terms/prims/prims_device.silica`: a constant base is checked against the table at compile time, a computed base by `silica_rt_map_device_check` (abort `illegal device map`, status 71); `peek` is `memw` + `l32i`, `poke` is `memw` + `s32i` + `memw`; **only 32-bit accesses are accepted**, `Register8`/`16`/`64` are refused with an `.error` line naming the width |
| 17 workers and third registry | `terms/prims/prims_actors.silica`, `board/runtime/rt_actors.S` (registries are sized per image from the atom table, `silica_registry_slots`) |
| 18 call-site barriers | unchanged (`effects/emitter_effects.silica`) |
| 19 trials | `trials/error_enforcement_addition/device_*` (54 entries), `trials/warning_enforcement_addition/device_w1c_read_modify_write`, board-only `trials/device_actor_addition` (9 programs with `ESP32-S3_raw.scout` goldens; `INTEGRATE_PENDING`, run by naming it: `make integrate TRIAL_TARGET=ESP32-S3_raw TRIAL_SUITES=device_actor_addition`), `trials/cast_device_registered_unheld_name_board_addition`; apps `board/apps/silica_16_device_uart` to `silica_22_device_buzzer` |
| 20 documentation | done in [esp32s3_port_status.md](esp32s3_port_status.md) §4.2 and `board/README.md`; [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) carries a status paragraph |

Decisions the text below left open: the host-side skip of the board-only suite is `INTEGRATE_PENDING`
(a named suite still runs); the diagnostic channel stayed narrow (items 10 and 11 only); widths other than 32 are
refused on this board. Recorded as open on 2026-09-30 and not re-checked on 2026-10-16: descriptions that sit in
modules seen only through an `.iface`; `spawn_device` inside a `register_rwr` sequence; the move-only rule for
`device_window`; the restart-time hardware `init` rule of device spec §8 (nothing enforces it).

## What the specification requires

A tight summary; the sections named are in [silica_device_actor_specification.md](../silica_device_actor_specification.md)
unless marked otherwise.

- **Three prims, one design on every port.** `map_device(device: D, base: uint64) -> device_window(R, D)`,
  `peek(window, register: atom) -> T`, `poke(window, register: atom, value: T) -> atom`, all `proc[register_rwr]`
  (§4.7). The lexer through the SIR generator are shared by every target, so there is no per-port access design;
  `read_ref` / `write_ref` / `buf_load` / `buf_store` never reach a device (§2 "Poke prim";
  [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.2).
- **Device workers only.** The prims and `sequence proc[register_rwr]` appear only inside a behavior installed by
  `spawn_device` / `spawn_device_registered`, referenced by `device_actor_ref` (no coercion to `actor_ref` or
  `dangerous_actor_ref`), reached by `cast_device` / `cast_device_registered`, cast-only, no `call_device` (§1,
  §4.1–§4.5). The spawn site needs `concurrency` only and must not declare `register_rwr` (§4.3). `main` is never a
  device worker (§4.2). A third atom-keyed registry table keeps device workers apart from ordinary and FFI workers
  (§1 "Split registries").
- **Described devices.** Every device has a programmer-supplied **device description**: an
  `impl fn registers(device: (:tag)) -> List[{ name: atom, offset: uint64, width: uint64, access: atom }]` of the
  built-in `DeviceDescription` trait, written in a `device_*` module that `use`s `devicedescription`, whose body is a
  single list literal of literal records (no calls, bindings, conditionals, arithmetic). The compiler reads it as data
  at compile time; programs may also call it at run time (§4.9). Validity: unique names; width 8/16/32/64; offset a
  multiple of width/8; no overlap; access one of `:read_write`, `:read_only`, `:write_only`, `:write_one_to_clear`; at
  least one register; the window size is the largest `offset + width/8` (§4.9 "Validity"). One description per tag;
  `map_device` with a tag whose description is not visible from the calling module is an error (§4.9 rules 2, 4).
- **Named registers, stated widths.** The register argument is an atom literal naming a register in the
  description; every `peek` is written `peek(w, :r) impl RegisterN {}` and every `poke` value `v impl RegisterN {}`,
  where `Register8`…`Register64` are four closed built-in marker traits with exactly one implementation each
  (`uint8`…`uint64`); the marker's width must equal the register's described width; an unsized literal takes the
  marker's type (§4.7 "Width markers", §4.8). `poke` to `:read_only` and `peek` of `:write_only` are errors; a
  `poke` of the unmodified result of a `peek` of the same `:write_one_to_clear` register is a warning (§4.9 table).
- **Lowering contract.** Each `peek` is exactly one load and each `poke` exactly one store of the marked width at
  `base + offset`, where the SIR prim node carries the offset resolved from the description; none is invented,
  removed (a `peek` bound to `_` included), merged, split, or moved past another, and none takes a cacheable path;
  `uint32` first, other widths where the board pack allows, the emitter rejecting a width its pack does not allow
  ([porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.2; device spec §4.7 "Reads are never
  removed"). Ordering follows the port table: `DSB SY`/`ISB` on AArch64, "ESP32-S3 uses the port table (not those
  opcodes)" ([porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.3; spec §9.1.1).
- **`map_device` is a bind, not an allocation.** `[base, base + size)` must be a board-pack window; an illegal map
  fails at compile time in the port's emitter when the pack can prove it (a constant base), otherwise at
  initialization with a hard halt; the window is move-only and is moved into the worker's initial state
  ([porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.1, §10; device spec §5.1).
- **`device_*` modules.** A module that calls the prims, exports a device-worker behavior with `register_rwr`, or
  `use`s a `device_*` module carries the `device_` prefix, propagating to the root as `dangerous_` does; a
  compilation unit must not depend on both a `device_*` and a `dangerous_*` module (§3.1–§3.2). The prim names are
  not keywords: an unqualified call inside a `device_*` module is the prim, elsewhere (or module-qualified) it is an
  ordinary identifier; a `device_*` module must not define a function with one of the three names (§4.7 "Names are
  not reserved").
- **Hosted rejection.** Every OS-hosted emitter rejects each `map_device`, `peek`, and `poke` with a compile-time
  error naming the module, the enclosing function, and the prim, through the compiler's diagnostics, not an
  assembler `.error` line, never falling through to a catch-all that emits nothing; wherever the prim appears, even in
  a function nothing calls. `spawn_device`, `cast_device`, and the other device-worker intrinsics are not rejected
  (§10; [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.5).
- **Diagnostics.** The compile-time table in §11 (shared-compiler rows) plus the per-emitter rows (hosted rejection;
  width the pack does not allow; constant `map_device` outside the pack's windows). Suggested codes **E2201**
  onward, a warning code in the same family; error-enforcement trials under `trials/error_enforcement_addition/`,
  with the hosted rejection covered on each hosted path (§11).

## What exists today

Measured against the tree on 2026-09-29 (the starting position; see the implementation status above for the present one).

- **Nothing of the prims, the markers, the descriptions, or the device-worker intrinsics** exists in any shared
  stage. `spawn_device`, `cast_device`, `map_device`, `peek`, `poke`, `DeviceDescription`, `Register8`…`Register64`
  have no hits under `compiler/src/lexer/`, `parser/`, `type_checker/`, `effect_checker/`, or `sir_generator/`.
  `device_actor_ref` is a keyword in neither `lexer/lexer_keywords.silica` (only `actor_ref` and
  `dangerous_actor_ref`, lines 183–184) nor a kind in `type_checker/type_interner.silica` (5019–5020 stop at
  `dangerous_actor_ref`); the string appears only in the actor-reference equality check
  (`type_checker/expressions/type_checker_expressions_numeric_builtins.silica:129-131`) and as a dispatcher arm in
  each emitter's `terms/prims/prims.silica:189`, which routes an equality compare on it to the atom prims.
- **`register_rwr` is not an accepted effect name.** `effect_checker/effect_checker_core.silica:245-256`
  (`is_builtin_effect`) lists `mem`, `concurrency`, `atomic`, `device_io`, `external_danger` only, and the alias table
  at 271–277 lists `actor_eff`, `io_eff`, `atomic_eff`; `effect_checker_declarations.silica:135-166` reports any other
  name as **E3005**. So `sequence proc[register_rwr]` is rejected today, although the FFI taint checker already
  names the effect (`ffi/ffi_taint_checker.silica:101`, and E2103 at 292) and every emitter already has a barrier
  arm for it (next item). The inventory row "effect still usable in `main` until the checker lands"
  ([porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §4) describes the emitter side, not the
  checker side; an error-enforcement trial should pin this down before work item 1 changes it.
- **Barriers exist at call sites, not at accesses.** The ESP32-S3 emitter already maps `register_rwr` to `memw`
  before and `memw` + `isync` after a *call* whose effect string contains the name
  (`emitter/ESP32-S3_raw/effects/emitter_effects.silica:76-105`, applied by
  `emitter/ESP32-S3_raw/terms/call.silica:120-122`); the AArch64 emitters emit `DSB SY` / `ISB` at the same place
  (`emitter/apple_silicon_mac/effects/emitter_effects.silica:84-96`). Nothing maps or touches a device.
- **The board runtime pokes hardware from hand-written assembly only.** `emitter/ESP32-S3_raw/board/runtime/rt_board.S`
  is the adjacent precedent: GPIO through the IO_MUX and GPIO matrix (register constants at lines 33–53, USB pad
  release at 60), `silica_rt_delay_us` through the ROM's `ets_delay_us`, `silica_rt_cycles` from `CCOUNT` (line
  206); the `asm_*` bring-up apps under `board/apps/` drive LEDs, buttons, and the buzzer through it
  ([esp32s3_port_status.md](esp32s3_port_status.md) §2 row "Timing", §4.2). Its limits are exactly what the
  specification forbids for application code: fixed addresses in the source, one routine per operation, no
  description, no width or access-mode check, no window ownership, callable from anywhere. It stays as the board
  pack's own driver code (reset, panic, and runtime-internal drivers are the named exceptions, device spec §7;
  [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §9.2), and it is the best source of real
  addresses and of the runtime's ordering habits: `memw` after every device store (`rt_board.S:76,126,149,168`,
  `rt_console.S:219`, `rt_start.S:230`) and before a device load whose value matters (`rt_board.S:181`).
- **The emitter has no diagnostic channel.** `emit_module` returns assembly text
  (`emitter/ESP32-S3_raw/emitter_core.silica:70-76` exports; the driver writes whatever comes back,
  `main_emit.silica:82-95`). The ESP32-S3 refusals are `.error` lines caught only at assembly time with no source
  location (`emitter_core.silica:347` foreign calls, `:3040` frame size, `terms/file_io_inline.silica:81-96` file
  io; catalogued in [esp32s3_port_status.md](esp32s3_port_status.md) §3). The three hosted emitters' catch-alls
  write **a comment**: `"    ; unsupported prim type: "` (`emitter/apple_silicon_mac/terms/prims/prims.silica:193`;
  `// unsupported prim type` in `linux_aarch64` and `linux_x86_64` at the same line) and per-type comments such as
  `; unsupported memory prim` (`apple_silicon_mac/terms/prims/prims_memory.silica:622`) and `; unsupported actor
  prim` (`prims_actors.silica:723`). A poke prim reaching one of those today would compile into nothing: the
  silent-miscompile risk the porting document names ([porting_for_os_free_targets.md](../porting_for_os_free_targets.md)
  §5.5, §14), which this plan fixes rather than extends (work item 12).
- **A pre-emit verification pass that reports through the normal diagnostics already exists.**
  `sir_generator/sir_call_verify.silica` (E4001) walks the SIR of every function after SIR generation and, on a
  builtin the SIR generator left unlowered, reports `module '…', function '…': the builtin '…'` at the function's
  declaration through `diagnostics_core@print_compiler_error("CodegenError", …)`, and the driver then stops before
  `emit_module` runs (`main_compile_pipeline.silica:276-285`). It knows the module and the function, which is exactly
  the first-version content the porting document asks the emitter channel to carry. Work item 11 builds on it.
- **Everything the spawn variants need is threaded end to end for `spawn_dangerous`**, which is the template for
  `spawn_device`: keyword (`lexer/lexer_keywords.silica:189-190`, `lexer_token_kind.silica:111-112,544-548`),
  parser roles (`parser/capabilities/capability_actors.silica:89`), return type
  (`type_checker/type_checker_builtin_signatures.silica:52-56`), the behavior-compatibility checks E4044/E4045
  (`type_checker/expressions/type_checker_expressions_actor_spawn.silica:700-713`), the binding rule
  (`type_checker_expressions_bindings.silica:105-113`), effect classification
  (`effect_checker/effect_checker_core.silica:334-339,421-426`), module placement (`module_checker/module_checker_ffi.silica:233-268`,
  E4026; the `dangerous_` use cascade at 207–212, E4021), SIR lowering (`sir_generator/terms/actor_calls.silica:150-166`,
  `terms_actor_lowering.silica:473-512`), and the four emitters' `terms/prims/prims_actors.silica` (`is_actor_prim`
  at ESP32-S3 line 200, dispatch at 682–685). The two PID registries are runtime actors with 240-slot tables
  (`board/runtime/rt_actors.S:210,354-358,2021-2024`); the hosted runtimes have the same pair.
- **The postfix marker and `impl fn` grammar exist for other traits.** `expr impl ActorMessage {}` is recognised by
  `parser/constraint_extract_decls.silica:788-800` (`is_postfix_message_impl_marker_start`: lexeme `ActorMessage` or
  `SupervisorMessage` followed by `{`) and reaches the SIR as value `"AM"` on the argument pair
  (`sir_generator/terms/actor_calls.silica:86-104`); `impl fn` declarations are extracted by
  `constraint_extract_decls.silica:770,883,1015-1016`; `impl Type;` marker lines are declaration tag 6
  (`parser/parser_ast.silica:81`) and are matched to a concrete type by
  `type_checker/traits/type_checker_traits.silica:171-207`. Built-in marker traits are compile-time only
  (`type_checker_traits.silica:322-326,339-360`, the `Collectable` / `ActorMessage` special cases). The one
  standard-library trait file, `compiler/stdlib/Supervisor.silica:22-27`, shows the trait-file form
  (`export trait …; export f/n; required { … }`) and is added to a build through `silica.config`
  ([trials/targets/README.md](../../../trials/targets/README.md) "What a board run does", step 2).

## Work

Items 1–9 are **shared-compiler** work: one insertion point each, benefiting every target, identical on every port
(device spec §4.9 "Where the checks run"; [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.5).
Items 10–11 give the driver the diagnostic channel. Items 12–13 are the **three hosted emitters'** rejection. Items
14–18 are **ESP32-S3-only**. Items 19–20 are trials and documentation. Details of each design decision are in the
companion document; the item numbers match its sections.

1. **`register_rwr` as a built-in effect.** Add it to `is_builtin_effect` (`effect_checker/effect_checker_core.silica:245`,
   empty parameter), so `sequence proc[register_rwr]` type-checks, and keep the taint rule that already names it
   (`ffi/ffi_taint_checker.silica:101,292`). Before changing it, add the error-enforcement trial that shows today's
   E3005, so the change is visible.
2. **Lexer and parser surface.** New keywords in `lexer/lexer_keywords.silica` and kinds in `lexer/lexer_token_kind.silica`
   for `spawn_device`, `spawn_device_registered`, `cast_device`, `cast_device_registered`, `device_actor_ref`, and
   the type constructor `device_window`, on the `spawn_dangerous` / `dangerous_actor_ref` pattern (lines 183–190);
   parser roles in `parser/capabilities/capability_actors.silica` beside line 89. **Not** keywords: `map_device`,
   `peek`, `poke` (device spec §4.7 "Names are not reserved"); they parse as ordinary calls (kind 4). Genuinely new
   grammar, as opposed to extension of an existing pattern:
   - the postfix marker on a *call* and on a *value*, `peek(w, :r) impl Register32 {}` and `784 impl Register32 {}`,
     which extends `is_postfix_message_impl_marker_start` (`parser/constraint_extract_decls.silica:788-800`) from the
     two message-marker lexemes to the four register-marker lexemes, but is new in that the marked expression may be
     a literal or any expression, not only a call argument, and in that the marker asserts a type instead of
     establishing an implementation (device spec §4.8 "Closed");
   - a device tag `(:tag)` as a parameter type in `impl fn registers(device: (:esp32s3_uart))`, a one-atom tagged
     tuple type (spec §4.4.6); the interner already has atom-literal type nodes (`type_checker/type_interner.silica:203`,
     `kind_atom_lit`), so this is a parameter-type text the parser and `types@type_name_to_sir` must accept, not a new
     type kind;
   - the type text `device_window(R, D)` with a tuple type as its second argument.
   The `impl fn registers(...)` declaration itself is the existing `impl fn` extraction
   (`constraint_extract_decls.silica:883`); the `use devicedescription;` line is an ordinary `use`.
3. **Built-in trait files.** `compiler/stdlib/DeviceDescription.silica` (`export trait DeviceDescription; export
   registers/1; required { fn registers(device: DeviceDescription) -> List[{ name: atom, offset: uint64, width: uint64,
   access: atom }]; }`) and `Register8.silica` … `Register64.silica` (`export trait RegisterN; impl uintN;`), in the
   form of `compiler/stdlib/Supervisor.silica:22-27`. The type checker treats the four register traits as closed
   built-in markers (any other `impl` is an error, device spec §11) in `type_checker/traits/type_checker_traits.silica`
   next to the `ActorMessage` special case (339–360). Decide whether the files are found by `use` like `Supervisor`
   (added to `silica.config` by the program's build) or compiled in like `ActorMessage`; see "Still to decide".
4. **Device descriptions as compile-time data.** A new shared module (proposed
   `type_checker/device/type_checker_device_descriptions.silica`, by analogy with `type_checker/traits/`) that finds
   every `impl fn registers` whose first parameter is a device tag in the calling module and the modules it `use`s
   (the `world` the checkers already carry), reads the body as data, and validates the §4.9 rules with the E2201-family
   codes: body is a single list literal of literal records (AST kinds: list literal, tuple/record literal, atom
   literal 5, integer literal 0; `parser/parser_ast.silica:77`), unique names, width, alignment, overlap, access mode,
   non-empty, one description per tag. The result is a per-tag table `{ registers, size }` used by items 5, 6, 7.
   Trait-shape validation of `DeviceDescription` itself follows the `FailureReporter` / `Supervisor` shape checks
   (`module_checker/module_checker_core.silica:275-332,381-428`; `trait_checker/trait_checker_core.silica:127-169`).
5. **Type checking the prims.** In the call dispatcher chain (`type_checker/expressions/type_checker_expressions_call_region_actor.silica:53`
   is where actor calls branch; region builtins are checked in `type_checker_memory_regions.silica`), a new
   `type_checker_expressions_device.silica`: `map_device` (tag has a visible description; result `device_window(R, D)`;
   move-only like a region handle), `peek` (window type carries `D`; register is an atom literal named in `D`'s
   description; marker present, marker type = `T`, marker width = described width; access mode allows a read),
   `poke` (the same on the value; access mode allows a write; result `atom`), and the resolution of an unqualified
   `map_device` / `peek` / `poke` only inside a `device_*` module, elsewhere an ordinary identifier (device spec §4.7
   "Names are not reserved", §11 rows). Return types go in `type_checker_builtin_signatures.silica` beside
   `builtin_actor_return_type` (52–56). The write-one-to-clear warning (item 8) lives here too.
6. **Device workers.** `spawn_device` / `spawn_device_registered` / `cast_device` / `cast_device_registered` on the
   `spawn_dangerous` chain: return type `device_actor_ref` (`type_checker_builtin_signatures.silica:54-55` pattern),
   the behavior checks mirroring E4044/E4045 (`type_checker_expressions_actor_spawn.silica:700-713`): `spawn` /
   `spawn_registered` / `spawn_dangerous` must not start a behavior containing `register_rwr` or the prims, and
   `spawn_device` must not start one containing `external_danger` or `dangerous_*` calls; a
   `__silica_tc_in_device_behavior` env marker set where `__silica_tc_in_behavior` / `__silica_tc_in_main` are set
   (`type_checker/declarations/type_checker_declarations_functions.silica:258-266`,
   `type_checker_expressions_actors.silica:443-456`) so that the prims and `register_rwr` sequences are errors in
   `main`, in ordinary behaviors, and in FFI behaviors, and `spawn_device` is an error inside a `register_rwr`
   sequence (device spec §11 rows 1–5). `cast` / `call` / `cast_registered` must not accept `device_actor_ref`, and
   `cast_device_registered` / `cast_registered` resolve different tables (§4.1, §11 rows 6–7). Effect classification
   `proc[concurrency]` in `effect_checker_core.silica:334-339,421-426`. Binding rule beside
   `type_checker_expressions_bindings.silica:105-113`.
7. **Module rules.** `device_` prefix and its `use` cascade, disjointness with `dangerous_`, the prim names not
   definable in a `device_*` module, `spawn_device` surface only in `device_*` modules: a `module_checker_device.silica`
   modelled on `module_checker/module_checker_ffi.silica:29-34,207-228,233-316` (E4021 / E4026). The FFI placement
   checker's behavior-name collection (`ffi/ffi_placement_checker.silica:26-28`) is the precedent for "which spawned
   behaviors are device workers".
8. **The write-one-to-clear warning.** In item 5's checker: a `poke(w, :r, v impl RegisterN {})` where `v` is a
   binding whose right-hand side is `peek(w, :r) impl RegisterN {}` of the same window and register and the binding
   is otherwise unused, with `:r` described `:write_one_to_clear`, reports through
   `diagnostics_core@print_compiler_warning` (`diagnostics/diagnostics_core.silica:25,138`), the compiler's one
   existing warning path (W4001 is the only warning code in use today). Code in the E2201 family (device spec §11).
9. **SIR lowering.** In `sir_generator/terms/` a `device_calls.silica` beside `actor_calls.silica` and
   `memory_region_calls.silica`, entered from the `call_base` chain in `terms.silica:114-135` (the region-builtin
   arm at 128 is the shape). Each prim becomes one kind-6 node whose `value` is `"[register_rwr]"` exactly as
   `build_spawn_named_prim` writes `"[concurrency]"` (`actor_calls.silica:150-158`;
   `sir_ast.silica:129` `make_sir_term(kind, type_name, value, name, left, right)`), carrying the resolved offset and
   width and, for `map_device`, the window size, so no emitter sees a register name (device spec §4.9 "Where the
   checks run"). `sir_generator_core.silica:35` (`is_actor_runtime_prim`) and `sir_call_verify.silica` must know the
   new prim names so E4001 does not misfire on them. Node shapes: companion document §1.
10. **The emitter's capability query.** Each of the four `emitter/<T>/emitter_core.silica` exports one new
    function, `unsupported_prim_reason(prim_name: string) -> string` ("" when the target lowers it; a one-line reason
    otherwise), so the driver can ask the *emitter it was built with* (the compiler binary is per `TARGET`,
    `compiler/src/Makefile:5-38,298`) what it cannot lower. The three hosted trees answer for `map_device`, `peek`,
    `poke`; ESP32-S3 answers "" for them and, on the same channel, for the refusals it makes today (foreign calls,
    file io: `emitter_core.silica:347`, `terms/file_io_inline.silica:81-96`), which then stop being `.error` lines
    ([esp32s3_port_status.md](esp32s3_port_status.md) §3, §4.2 last sentence).
11. **The driver-side rejection pass.** A new `sir_generator/sir_target_verify.silica` on the model of
    `sir_call_verify.silica:29-57`: walk every function's SIR, and for each kind-6 node whose name has a non-empty
    `unsupported_prim_reason`, report `E2201`-family `"module '<m>', function '<f>': the prim '<p>' cannot be compiled
    for <target>: <reason>"` at the function's declaration through `diagnostics_core@print_compiler_error`, before
    `emit_module` and before any `.sams` is written (`main_compile_pipeline.silica:276-285`, then
    `main_emit.silica:82-95`). Module, function, and prim are what the first version needs
    ([porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.5); line and column follow when SIR nodes
    carry locations. This *is* the target-neutral diagnostic channel in its narrowest form: a query from the driver to
    `emitter_core`, not a change to `emit_module`'s return type. See "Still to decide" for the wider channel.
12. **Hosted catch-alls stop being comments.** In `emitter/apple_silicon_mac/`, `linux_aarch64/`, `linux_x86_64/`:
    `terms/prims/prims.silica:193` and every per-type `_ -> "    ; unsupported … prim"` arm (`prims_memory.silica:622`,
    `prims_actors.silica:723`, `prims_atom.silica:82`, `prims_bool.silica:81`, `prims_narrow.silica:118`,
    `prims_uint64.silica:97`, `prims_tuple.silica:383`, `prims_list.silica:602`, `prims_float*.silica`,
    `prims_checked_int64.silica:97`) become `.error "unsupported … prim: <name>"` lines as the ESP32-S3 tree already
    does (`emitter/ESP32-S3_raw/terms/prims/prims.silica:193`, `prims_memory.silica:598`). This is the second line of
    defence behind item 11 (a prim that slips past the pass fails the assembly instead of vanishing) and it fixes the
    existing silent-miscompile risk for every future prim, not only these three. Explicit arms for `map_device`,
    `peek`, `poke` in each hosted `prims.silica` name the prim in that `.error` text.
13. **Hosted device-worker intrinsics.** `spawn_device`, `spawn_device_registered`, `cast_device`,
    `cast_device_registered` are lowered on every target (device spec §10: not rejected). In the three hosted
    `terms/prims/prims_actors.silica` (`is_actor_prim`, `emit_prim_op` at Apple lines 200/682-685-equivalents) they
    take the `spawn_dangerous` / `cast_dangerous_registered` paths with a third registry; the hosted runtimes
    (`prims_actors_runtime_asm.silica`) gain the third table beside the two existing ones.
14. **ESP32-S3 board pack: the window table.** A `board/device_windows` fragment (proposed
    `board/runtime/rt_device.S` for the runtime copy plus the same table in the emitter,
    `emitter/ESP32-S3_raw/board_pack.silica`) listing the legal `[base, size)` ranges of the ESP32-S3 peripheral bus
    with the widths the pack allows. First version: the peripheral blocks the runtime already touches
    (companion document §3) and width 32 only. A draft of the emitter copy, in the compiler dialect, is
    [board_pack.silica](board_pack.silica) in this directory: the window table as indexed pure functions
    (`window_containing(base, size)` is the compile-time check), plus the memory ranges that are never windows,
    the register offsets the runtime drives, and the board's pins; the module name is generic so every OS-free
    target carries its own copy at `emitter/<TARGET>/board_pack.silica`.
15. **ESP32-S3 `map_device`.** In a new `emitter/ESP32-S3_raw/terms/prims/prims_device.silica` entered from
    `prims.silica`'s name dispatch (the `prims_memory@is_memory_prim` arm at line 155 is the pattern): when `base` is
    a SIR constant, check `[base, base + size)` against item 14's table at compile time and refuse a map outside it
    (device spec §11 per-emitter row 3; [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §10);
    otherwise emit a call to `silica_rt_map_device_check(base, size)` in `rt_device.S`, which halts through
    `silica_rt_abort_with` (`board/runtime/rt_console.S:376-381`, status 71) on an illegal range. The window value is
    the base address in an X-class pair, as a region handle is a pointer (design §2 of
    [esp32s3_xtensa_port.md](esp32s3_xtensa_port.md)). `rt_device.S` joins `RUNTIME_SOURCES` in
    `board/tools/build_image.sh:68`.
16. **ESP32-S3 `peek` and `poke`.** In the same file: one `memw` then one `l32i` (or `l8ui` / `l16ui` when the
    pack allows those widths) for a `peek`, at `[window, #offset]` through `shared/xt_mem.silica`'s operand forms
    (`xt_ldr` at 378–384 is the 4-byte `l32i` path; `disp_fits` at 196–201 gives the immediate ranges, with a
    `movi`/`add` fallback for larger offsets); one `memw`, one `s32i` (or `s8i` / `s16i`), one `memw` for a `poke`,
    whose result is the program's own index for `:ok` obtained as `emit_prim_op_with_atoms` obtains it for
    `migrate_actor` (`terms/prims/prims_actors.silica:606-628`). A width the pack does not allow is refused with the
    width named (device spec §11 per-emitter row 2). The barrier choice and its confidence: companion document §5.
17. **ESP32-S3 device workers and the third registry.** `spawn_device*` and `cast_device*` in
    `emitter/ESP32-S3_raw/terms/prims/prims_actors.silica` (`is_actor_prim` at 200, `emit_prim_op` at 682) on the
    `spawn_dangerous` path; a third registry actor and ref word in `board/runtime/rt_actors.S` beside
    `silica_pid_registry_ref` / `silica_dangerous_pid_registry_ref` (354–358), looked up by the keyed forms as at
    1818–1866, started from `silica_pid_registry_init` (390).
18. **ESP32-S3 call-site barriers.** Leave `effects/emitter_effects.silica:87-105` as it is (calls into a
    `register_rwr` function keep `memw` before and `memw` + `isync` after); the access-level barriers of item 16 are
    what the specification's "they wrap the accesses" means ([porting_for_os_free_targets.md](../porting_for_os_free_targets.md)
    §5.3). Whether the `isync` at call sites is still wanted is a "Still to decide" item, not a blocker.
19. **Trials.** (a) `trials/error_enforcement_addition/device_*` for every E2201-family row of device spec §11,
    compile-only, run on the host and on the board (the board driver compiles `.golden_fail` trials alone,
    `trials/targets/board_suite.sh:29-31,101-102`); (b) the hosted rejection trial on each hosted path
    (`.golden_fail` on Apple Silicon, Linux AArch64, Linux x86-64), listed in `trials/targets/ESP32-S3_raw.skip` with a
    `target:` reason because on the board it is not an error; (c) a board-only program suite (proposed
    `trials/device_actor_addition/`) with per-target goldens `<stem>.ESP32-S3_raw.scout`
    (`board_suite.sh:34`) — a UART worker that peeks `:status` and pokes `:fifo`, a GPIO worker, a systimer reader,
    a discarded `peek` whose load must still appear — and the bring-up apps `board/apps/silica_16_device_uart` and
    `silica_17_device_gpio` with hand-written `expected.scout` (the host reference script cannot produce them, since
    the host rejects the program). How the host run skips (c) is a "Still to decide" item.
20. **Documentation.** [esp32s3_port_status.md](esp32s3_port_status.md): §3 loses the `.error` rows that move to
    the diagnostic channel, §4.2 is closed, §1 gains the new suites with dates; `board/README.md` gains the window
    table and the two apps; the device spec's status line ("Not implemented") and the inventory rows in
    [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §4 are updated when the gate passes.

Order: 1, 2, 3, 4, 5, 9 first (a `device_*` module with a description and a `peek` reaches SIR on every target);
then 10, 11, 12 (the hosted paths reject it, and their fixed points can be re-established at any later point);
then 14, 15, 16 (a `main`-free worker is not yet needed to see a byte leave UART0 through `peek` / `poke` from a
bring-up app, though the checker of item 6 will require the worker before the app compiles: do 6 and 17 next);
then 7, 8, 13, 18, 19, 20.

## Insertion points

| Piece | Where |
| --- | --- |
| `register_rwr` accepted as an effect | `effect_checker/effect_checker_core.silica:245-256` (`is_builtin_effect`); today E3005 from `effect_checker_declarations.silica:135-166` |
| Keywords and token kinds | `lexer/lexer_keywords.silica:183-190`, `lexer/lexer_token_kind.silica:111-112,544-548` (the `spawn_dangerous` / `dangerous_actor_ref` rows) |
| Parser: spawn/cast roles; postfix register markers; `impl fn registers` | `parser/capabilities/capability_actors.silica:89`; `parser/constraint_extract_decls.silica:788-829` (`is_postfix_message_impl_marker_start`, `is_trait_marker_impl_start`); `constraint_extract_decls.silica:883,1015-1016` (`extract_impl_fn_function`) |
| Built-in trait files | `compiler/stdlib/DeviceDescription.silica`, `Register8.silica` … `Register64.silica`, in the form of `compiler/stdlib/Supervisor.silica:22-27` |
| Closed marker traits, `impl` matching | `type_checker/traits/type_checker_traits.silica:171-207,322-326,339-360` |
| Device description table and validation | new `type_checker/device/type_checker_device_descriptions.silica`; trait-shape checks on the model of `module_checker/module_checker_core.silica:275-332` |
| Prim type checking, markers, access modes, W1C warning | new `type_checker/expressions/type_checker_expressions_device.silica`, entered beside `type_checker_expressions_call_region_actor.silica:53`; return types in `type_checker_builtin_signatures.silica:52-56`; warning through `diagnostics/diagnostics_core.silica:25,138` |
| Device-worker spawn/cast checks and env marker | `type_checker/expressions/type_checker_expressions_actor_spawn.silica:94,700-713`; `type_checker_expressions_actor_concurrency.silica:45-48`; `type_checker/declarations/type_checker_declarations_functions.silica:258-266`; `type_checker_expressions_actors.silica:443-456`; `type_checker_expressions_bindings.silica:105-113` |
| Effect classification of the new intrinsics | `effect_checker/effect_checker_core.silica:334-339,421-426` |
| `device_*` module rules | new `module_checker/module_checker_device.silica` on the model of `module_checker_ffi.silica:29-34,207-228,233-316` |
| SIR lowering | new `sir_generator/terms/device_calls.silica`, entered from `sir_generator/terms/terms.silica:114-135`; node constructor `sir_generator/sir_ast.silica:129`; name lists in `sir_generator_core.silica:35` and `sir_call_verify.silica:59-70` |
| Emitter capability query | `emitter/<T>/emitter_core.silica` (exports at ESP32-S3 lines 70–76), all four trees |
| Driver rejection pass | new `sir_generator/sir_target_verify.silica` on the model of `sir_call_verify.silica:29-57`; called from `main_compile_pipeline.silica:276-285` before `main_emit.silica:82-95` |
| Hosted catch-alls to `.error` | `emitter/{apple_silicon_mac,linux_aarch64,linux_x86_64}/terms/prims/prims.silica:193` and the per-type `_ ->` arms listed in work item 12 |
| Hosted device-worker intrinsics | `emitter/{apple_silicon_mac,linux_aarch64,linux_x86_64}/terms/prims/prims_actors.silica`, `prims_actors_runtime_asm.silica` (third registry) |
| ESP32-S3 window table | new `emitter/ESP32-S3_raw/board_pack.silica` (draft: [board_pack.silica](board_pack.silica)) and `board/runtime/rt_device.S`; `board/tools/build_image.sh:68` |
| ESP32-S3 `map_device` / `peek` / `poke` | new `emitter/ESP32-S3_raw/terms/prims/prims_device.silica`, dispatched from `terms/prims/prims.silica:150-160`; loads and stores through `shared/xt_mem.silica:196-201,334-345,378-443`; `:ok` index as in `terms/prims/prims_actors.silica:606-628`; runtime halt `board/runtime/rt_console.S:376-381` |
| ESP32-S3 device workers, third registry | `emitter/ESP32-S3_raw/terms/prims/prims_actors.silica:200,682-685`; `board/runtime/rt_actors.S:210,354-358,390,1818-1866,2021-2024` |
| ESP32-S3 call-site barriers (unchanged) | `emitter/ESP32-S3_raw/effects/emitter_effects.silica:76-105`, `terms/call.silica:120-122` |
| Trials | `trials/error_enforcement_addition/device_*`; new `trials/device_actor_addition/` with `<stem>.ESP32-S3_raw.scout`; `trials/targets/ESP32-S3_raw.skip`; `board/apps/silica_16_device_uart`, `silica_17_device_gpio` |

## Still to decide

- **The diagnostic channel: narrow now, wide later.** Work items 10–11 deliver the hosted rejection through a
  capability query plus a pre-emit SIR pass, which reports module, function, and prim through the normal
  diagnostics and writes no `.sams` — everything §5.5 of the porting document asks of the first version — without
  changing `emit_module`'s `string` return on four trees. The wider channel (a result type from `emit_module`, so an
  emitter can report any condition it discovers *during* emission with the function it is in, and line/column once
  SIR nodes carry locations) is deferred with the reason that no rejection this plan needs is discovered during
  emission: every one is decidable from the SIR node's name, its constant operands, and the target. The ESP32-S3
  frame-size refusal (`emitter_core.silica:3040`) is the one case that *is* discovered during emission and it stays
  an `.error` line until the wide channel exists. To be confirmed with Lee.
- **The Xtensa barrier around each access.** Proposed: `memw` before every `peek` and `poke`, and `memw` after
  every `poke`; no `isync` at accesses. Grounds: the runtime's own habit (`rt_board.S:76,126,149,168,181`,
  `rt_console.S:219`, the lock macros `rt_actors.S:270-293`), the existing call-site mapping
  (`emitter_effects.silica:76-79`, whose comment says `MEMW` plays the `DSB SY` role and `ISYNC` the `ISB` role), the
  Xtensa ISA definition of `MEMW` (all earlier loads and stores complete before any later one) and the Xtensa GCC
  default `-mserialize-volatile`, which inserts a `MEMW` before every volatile access. Confidence: high on `MEMW`
  being the instruction and on "before each access"; medium on the trailing `memw` after a `poke` being required
  rather than merely consistent with the runtime; medium-high that the peripheral region at `0x6000_0000` is never
  cached on this chip (only external flash/PSRAM goes through the cache MMU), which is what makes "never a cacheable
  path" hold by address rather than by instruction. The companion document §5 gives the reasoning; the Technical
  Reference Manual's memory-map and cache chapters should be checked before the gate. Whether the call-site `isync`
  stays is cosmetic and can be decided then.
- **Device description authoring.** Resolved by device spec §4.9, confirmed: it is Silica source the programmer
  writes — an `impl fn registers(device: (:tag))` of the built-in `DeviceDescription` trait in a `device_*` module —
  and the compiler reads it as data without running it; a generator over vendor files is later work (§3.3) and would
  emit the same source. No open decision here. What *is* open is the mechanics: **(a)** whether the built-in trait
  files are found by `use` from `compiler/stdlib/` (as `Supervisor` is, through `silica.config`) or compiled in like
  `ActorMessage`; the spec's "`use devicedescription;`" (§4.9 rule 1) reads as the former, which means every device
  program's build lists the file, as the supervisors suite does for `Supervisor.silica`; **(b)** how a description
  in a *used* module reaches a unit whose dependency was parse-skipped through its `.iface`
  (`main_compile_pipeline.silica:253-258`: iface stubs carry export trait and impls, not bodies) — the description
  must be read as data from the used module, so either its `.iface` carries the register list or descriptions are
  re-read from source; awaiting discussion.
- **"`map_device` overlapping a live map" as a shared-compiler check.** Device spec §11 lists it among the shared
  rows and §5.1 phrases it as a live-mapping rule. Statically it is decidable only for constant bases within one
  program (two `map_device` calls whose `[base, size)` overlap); a runtime table of live windows (in `rt_device.S`)
  would catch the rest at the second map with the hard halt. Proposed: the constant case in the shared checker, the
  rest at run time; needs confirmation, since the spec table says "Error" without saying where.
- **Widths other than 32 on this board.** The first version allows `Register32` only (device spec §4.7: `uint32`
  required on every port; others "where the board pack allows"). `Register64` cannot be one load or store on a
  32-bit bus and is refused outright. Whether 8- and 16-bit accesses to peripheral registers are architecturally
  supported on the ESP32-S3 peripheral bus is to be confirmed from the TRM before `Register8` / `Register16` are
  allowed; refusing them costs nothing now.
- **Move-only windows.** The specification makes `device_window` move-only like a region handle (§5.1). The
  compiler enforces the region move rule only in its narrowest case today ([ROADMAP.md](../../../ROADMAP.md) chunk 4:
  "a parameter whose own declared type is a region, not returned and not passed on"). A window carried in a worker's
  initial-state record is exactly the unenforced case. Proposed: the same partial enforcement as regions for board
  release 1, with the full rule arriving with chunk 4; to be confirmed.
- **Host-side skipping of a board-only suite.** `trials/targets/ESP32-S3_raw.skip` skips on the board; the only
  host-side mechanism is `INTEGRATE_PENDING`, which skips on every target (`trials/targets/trial_target.sh:251`).
  The device program suite (work item 19c) needs a way to run on the board and be reported as skipped, not failed,
  on the host: a `host.skip` beside the board one, or a suite-level target marker. Awaiting discussion.
- **Where `spawn_device` runs a hardware `init`.** Device spec §8 says a restarted worker's first work must run a
  documented `init` / `recover`. Nothing in this plan enforces it; the supervisors' restart path
  (`board/runtime/rt_supervisors.S`) is untouched. Recorded so it is not mistaken for delivered.

## Gate

Board release 1's peek-and-poke half is delivered when all of the following hold.

- **Shared checks.** Every row of device spec §11's shared table has an `error_enforcement_addition` trial whose
  `.golden_fail` matches on the host and on the board (`make integrate TRIAL_TARGET=both TRIAL_SUITES=error_enforcement_addition`),
  including: the prims and `register_rwr` in `main`, in a `spawn` behavior, in a `spawn_dangerous` behavior; a
  missing marker; a marker of the wrong width; a `poke` to `:read_only`; a `peek` of `:write_only`; a second
  description for one tag; each of the six description-validity faults; a `device_*` module `use`ing a `dangerous_*`
  module; a `device_*` module defining `peek`. The write-one-to-clear warning has a `warning_enforcement_addition`
  trial. `sequence proc[register_rwr]` inside a device worker is accepted (today's E3005 is gone, and a trial
  shows it).
- **Hosted rejection.** On Apple Silicon, Linux AArch64, and Linux x86-64: a program whose `device_*` module calls
  `peek` in a function nothing calls fails to compile with the E2201-family error naming the module, the function,
  and the prim, and **no `.sams` is written** for that unit; a program that only `spawn_device`s and `cast_device`s
  compiles and runs. Both are trials. `make fixpoint` passes again on Apple Silicon and on the Pi (gen3 = gen2),
  and the whole trial tree is green under the selfhost built by the selfhost, so the two hosted paths have their
  new fixed points ([ROADMAP.md](../../../ROADMAP.md) "Peek and poke" paragraph).
- **No silent fall-through anywhere.** A synthetic unsupported prim reaching any hosted emitter's catch-all fails
  the assembly with a `.error` naming it (checked by inspection of the three `prims*.silica` catch-alls and one
  deliberately mis-lowered unit during development, not by a permanent trial).
- **ESP32-S3 accesses.** `board/apps/silica_16_device_uart` (a device worker mapping `(:esp32s3_uart)` at
  `0x60000000`, polling `:status` with `peek`, writing `:fifo` with `poke`) prints its bytes on the console and
  matches its hand-written `expected.scout`; `silica_17_device_gpio` toggles a port-test-board LED and reads a button
  through `peek` / `poke` of `(:esp32s3_gpio)` at `0x60004000`; a trial with `_: uint32 <- peek(w, :status) impl
  Register32 {};` still shows exactly one `l32i` for it in the emitted `.sams`, and every `peek` / `poke` in those
  apps is exactly one `l32i` / `s32i` at `[window, #offset]` with the barriers of work item 16 (read from the
  `.sams`, since the board target has no `.ascomp` goldens, [esp32s3_port_status.md](esp32s3_port_status.md) §4.4).
- **ESP32-S3 refusals.** A constant `map_device((:esp32s3_uart), 0x3FC88000)` (SRAM, not a window) is a compile
  error naming the range; a non-constant illegal base halts at initialization with `[silica] abort: … at 0x…`, status
  71; `peek(w, :r) impl Register64 {}` is refused naming the width. Each is a trial (`.ESP32-S3_raw.golden_fail`
  or `.ESP32-S3_raw.scout`).
- **Device workers on the board.** The new `device_actor_addition` suite (UART worker, GPIO worker, systimer
  reader, a client that `cast_device`s and receives the result by `cast`, a `cast_device_registered` through the
  third registry, `cast` of a `device_actor_ref` rejected) passes on the board through the driver, and every suite
  already in [esp32s3_port_status.md](esp32s3_port_status.md) §1 still passes at its recorded count.
- **Documentation updated** as in work item 20, and [esp32s3_port_status.md](esp32s3_port_status.md) §3 no longer
  lists an `.error`-line refusal for foreign calls or file io.

Related: [actor_memory_budget_plan.md](../actor_memory_budget_plan.md) (the third registry actor costs another
~2 KB reserve plus a 240-slot table on a board where 55% of SRAM is claimed before the program starts),
[esp32s3_xtensa_port.md](esp32s3_xtensa_port.md) §2, §4, §8.7, §8.9 (virtual registers, the call convention the
runtime routines use, the registries, two cores), [runtime_failure_reporting.md](../runtime_failure_reporting.md)
(the abort report the runtime halt produces).
