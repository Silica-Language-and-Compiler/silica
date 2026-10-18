# Peek and poke on `ESP32-S3_raw` — Implementation Details

**Scope:** the concrete design behind [esp32s3_peek_poke_implementation_plan.md](esp32s3_peek_poke_implementation_plan.md);
section numbers here follow that plan's work items where they overlap. This is a design record for one port and the
shared change it needs, not a specification: where it disagrees with
[silica_device_actor_specification.md](../silica_device_actor_specification.md) or
[porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5, those win.
**Implementation status (2026-10-16):** the design below is implemented as described in the plan's status table, with these differences from the text: the SIR lowering lives in `sir_generator/terms/sir_device_calls.silica`; the emitter copy of the board pack is `emitter/ESP32-S3_raw/board_pack.silica` (12 windows, with a generated per-peripheral register layer under `board/pack/`); only 32-bit accesses are lowered; the "today" statements below (codes stopping at E2114, `register_rwr` giving E3005, no diagnostic channel, the `.error`-line refusals) describe 2026-09-29 and are no longer true for the device prims (the codes are E2201 to E2233, `register_rwr` is a built-in effect, `sir_target_verify.silica` is the narrow channel).
**Ground truth used:** the tree as of 2026-09-29. Every address, instruction, and file position below is cited to a
file in `compiler/src/` (paths relative to it unless they start with `trials/` or `compiler/`) or to a spec section.
Statements drawn from the Xtensa ISA or the ESP32-S3 Technical Reference Manual rather than from this tree are marked
with a confidence level in §5 and §9.

## 1. The SIR prim nodes

A SIR term node has six fields, `{ kind, type_name, value, name, inner, right_expr }`
(`sir_generator/sir_ast.silica:129`, `make_sir_term(kind, type_name, value, name, left, right)`); a prim is kind 6 and
prints as `prim(<name>, <left>, <right>)` (`sir_ast.silica:400-408`). The effect a prim carries rides in `value`:
`build_spawn_named_prim` writes `"[concurrency]"` there and packs the extra spawn arguments into a `tuple_make` chain
in the right slot (`sir_generator/terms/actor_calls.silica:150-158`), which the emitter unpacks
(`emitter/ESP32-S3_raw/terms/term_emit_kind_compound_part3.silica:80-81`). The three device prims follow that
exactly, with `"[register_rwr]"` in `value` (device spec §4.9 "The SIR prim node carries the resolved offset and
width"; [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.5 "as `spawn` carries `[concurrency]`").

| Prim | `name` | `type_name` | `value` | `inner` (left) | `right_expr` (right) |
| --- | --- | --- | --- | --- | --- |
| `map_device((:tag), base)` | `map_device` | the window type text, `device_window(R,(:tag))`, as `types@type_name_to_sir` spells it | `[register_rwr]` | the `base` term (`uint64`) | an integer constant node: the window **size** in bytes (largest `offset + width/8` in the description, device spec §4.9 "Validity") |
| `peek(w, :r) impl RegisterN {}` | `peek` | `uintN` (the marker's type, which is `T`) | `[register_rwr]` | the window term | an integer constant node: the register's **offset** in bytes |
| `poke(w, :r, v impl RegisterN {})` | `poke` | `atom` | `[register_rwr]` | the window term | `tuple_make(<offset constant>, <value term of type uintN>)` |

What this buys:

- **No register names or access modes reach any emitter.** Name resolution, width agreement, and the access-mode
  table are all in the shared checker (§2); the emitter reads an offset, a width (from `type_name`), and for
  `map_device` a size. That is the split §5.5 of the porting document prescribes and the reason a hosted emitter can
  reject by prim name alone (§6).
- **The width is the node's type.** `peek`'s `type_name` is `uint8` … `uint64`; `poke`'s value child has that type.
  The emitter's existing `dest_for_type` conversion (`emitter/ESP32-S3_raw/terms/prims/prims.silica:88`, applied at 168) already
  turns a `uint32` destination into a `W`-class virtual register, whose home is the low word of a pair
  ([esp32s3_xtensa_port.md](esp32s3_xtensa_port.md) §2 "`W`-class values use the low register of the pair").
- **The device tag stays in the window's type text**, so a `device_window(R, (:esp32s3_uart))` can never be passed
  where a `region(R, device)` is expected or vice versa: `alloc_ref`, `read_ref`, and the other region prims match on
  `region(` in the type text (`type_checker/type_checker_memory_regions.silica:45` and its callers) and will not
  accept it (spec §4.4.6).

The lowering module is `sir_generator/terms/device_calls.silica`, entered from the `call_base` dispatch chain in
`sir_generator/terms/terms.silica:114-135` (the `memory_region_calls@is_region_builtin` arm at line 128 is the
shape: a name predicate, then a builder that lowers the argument terms with `expr_to_sir_in_let_body` and calls
`make_sir_term`). Two lists must learn the new names so existing passes do not misfire: `sir_generator_core.silica:35`
(`is_actor_runtime_prim`) and `sir_call_verify.silica:59-70` (`callee_is_unlowered_builtin`, or E4001 would report
`peek` as an unlowered builtin).

**Discarded reads.** `_: uint32 <- peek(w, :int_raw) impl Register32 {};` is a let (AST kind 6,
`parser/parser_ast.silica:77`), lowered to a SIR let node named `%_` (`terms.silica:96-103`); the SIR generator only
withholds `_` from the environment (`terms_helpers.silica:594`, `is_discard`), the emitters emit every let's
right-hand side and recognise `%_` only to skip spill bookkeeping (`emitter/ESP32-S3_raw/terms/term_reg_spill.silica:856`,
`term_sir_helpers.silica:131`), and there is no dead-code pass anywhere in the emitter. So the binding form the
specification requires (device spec §4.7 "Reads are never removed") is emitted unconditionally today, without new
work. The known host defect that a **bare** statement `print_int64(<literal>);` drops its value
([esp32s3_port_status.md](esp32s3_port_status.md) §4.6, `trials/sequence_block_addition/sequence_print_int64_literal_statement`)
is outside the required form; the checker of §2 should nonetheless reject a bare `peek(...)` statement rather than let
it depend on that behaviour.

## 2. Device descriptions and the prims in the type checker

### 2.1 Reading a description

A description is an ordinary `impl fn` declaration to the parser (`parser/constraint_extract_decls.silica:770,883,1015-1016`,
`extract_impl_fn_function`): declaration tag 0 (`parser_ast.silica:81`) with the `impl` marker, name `registers`, one
parameter whose type text is a one-atom tagged tuple `(:esp32s3_uart)`, and a body. The new shared module
`type_checker/device/type_checker_device_descriptions.silica` collects them from the `world` every checker already
carries (`List[{ module_name, program }]`; the same list `type_checker_traits@find_program_declaring_trait` walks,
`type_checker/traits/type_checker_traits.silica:160`) and reads each body as data:

```
description := { tag: string,                      // ":esp32s3_uart"
                 module_name: string,              // the device_* module that declares it
                 registers: List[{ name: string, offset: int64, width: int64, access: string }],
                 size: int64 }                      // max(offset + width/8)
```

The body must be exactly: one list literal, each element a record literal, each field an atom literal (kind 5) or an
integer literal (kind 0) (`parser_ast.silica:77`); any identifier, call (kind 4), binary op (kind 3), let (kind 6), or
sequence (kind 11) anywhere in it is the "not a list literal of literal records" error (device spec §4.9 rule 3, §11).
Reading the AST rather than the SIR is deliberate: the description must be available to the type checker, which runs
before SIR generation (`main_compile_pipeline.silica:220-240`).

Validation (device spec §4.9 "Validity"), each with its own code in the E2201 family (device spec §11 "Suggested
codes"; today's codes stop at E2114 in the E21xx range and nothing uses E22xx, so the family is free):

| Check | Proposed code |
| --- | --- |
| second description for one tag (across the world) | E2201 |
| body not a list literal of literal records | E2202 |
| duplicate register name | E2203 |
| width not 8 / 16 / 32 / 64 | E2204 |
| offset not a multiple of width / 8 | E2205 |
| two registers overlap | E2206 |
| access not one of the four modes | E2207 |
| no registers | E2208 |
| `map_device` tag with no description visible from the calling module (own module or a `use`d one) | E2209 |
| `impl fn` of a trait other than `DeviceDescription` outside its trait's file; or `impl fn registers` outside a `device_*` module | E2210 |

The trait file itself, `compiler/stdlib/DeviceDescription.silica` (device spec §4.9, in the form of
`compiler/stdlib/Supervisor.silica:22-27`), is shape-checked the way `Supervisor` and `FailureReporter` are
(`trait_checker/trait_checker_core.silica:127-169`, `module_checker/module_checker_core.silica:275-332`): exactly one
required method `registers/1` with the record-list return type. "Visible from the calling module" is decided from the
module's `use` list (tag 2 declarations), which is what the `dangerous_` cascade already reads
(`module_checker/module_checker_ffi.silica:207-228`).

### 2.2 The register markers

`Register8` … `Register64` are four closed built-in marker traits (device spec §4.8). In
`type_checker/traits/type_checker_traits.silica`, `actual_type_satisfies_trait_expectation` (339–360) gains four arms
beside `Collectable` and `ActorMessage`, each accepting exactly one concrete type; and any user `impl RegisterN` or
`impl fn` for them is the "any `impl` of `Register8`…`Register64` outside the built-in ones" error (device spec §11).
The postfix form is parsed by extending `is_postfix_message_impl_marker_start`
(`parser/constraint_extract_decls.silica:788-800`) from the lexemes `ActorMessage` / `SupervisorMessage` to the four
register names, and by allowing the marked expression to be any expression, not only a call argument; the marker
reaches the checker the way `impl ActorMessage {}` does today (value `"AM"` on the argument pair,
`sir_generator/terms/actor_calls.silica:86-104`), with a distinct value per width, e.g. `"R32"`. Unlike
`ActorMessage`, the marker **asserts** the type: `word impl Register32 {}` with `word: uint64` is an error, and an
unsized literal takes the marker's type (device spec §4.8 "Agreement"; the one-viable-implementation rule the device
spec cites as spec §3.4.11 is the type-implementation disambiguation text at spec §3.4.12 in the current numbering —
the cross reference should be verified when the checker lands).

### 2.3 Checking `map_device`, `peek`, `poke`

New `type_checker/expressions/type_checker_expressions_device.silica`, entered from the call dispatch beside
`type_checker_expressions_call_region_actor.silica:53`, with return types added to
`type_checker/type_checker_builtin_signatures.silica:52-56`:

1. **Name resolution** (device spec §4.7 "Names are not reserved"; §11 rows "Unqualified … outside a `device_*`
   module" and "`device_*` module defines a function named …"). The three names are looked up as user functions
   first; inside a `device_*` module an unqualified call that matches no function in scope is the prim, and a
   `device_*` module that *defines* one of the names is an error; outside a `device_*` module the same unqualified call
   with no function in scope is an error whose message points to the device specification instead of the generic
   unknown-function diagnostic. A module-qualified `m@peek` is always an ordinary call.
2. **`map_device((:tag), base)`**: the first argument is a tuple literal of one atom literal (AST kind 9 over kind 5);
   its description must be visible (E2209); `base` is `uint64`; the result type is `device_window(R, (:tag))` with a
   fresh lifetime, move-only like a region handle (device spec §5.1; enforced to the same partial extent as regions
   today, plan "Still to decide").
3. **`peek(w, :r) impl RegisterN {}`**: `w`'s type text must be `device_window(…, (:tag))`; `:r` must be an atom
   literal (kind 5), not a variable; the description of `(:tag)` must list `:r`; the marker must be present, its
   width must equal the register's `width`, and the result type is the marker's type; access must be `:read_write`,
   `:read_only`, or `:write_one_to_clear` (not `:write_only`). Errors: missing marker, marker width ≠ described width,
   register not an atom literal, register not described, `peek` of `:write_only` (device spec §11).
4. **`poke(w, :r, v impl RegisterN {})`**: as for `peek` on `w` and `:r`; the marker is on the value; `v`'s type must
   be the marker's type; access must not be `:read_only`; the result is `atom` (the emitter returns `:ok`, §4.3).
5. **The write-one-to-clear warning**: §7.

Suggested codes continue the family: E2211 missing marker, E2212 marker type disagreement, E2213 register not an atom
literal or not described, E2214 width disagreement, E2215 access mode, E2216 unqualified prim outside a `device_*`
module, E2217 `device_*` module defining a prim name, E2218 outside-any-implementation `impl RegisterN`. The exact
strings are assigned when the checker lands (device spec §11).

### 2.4 Device workers

The `spawn_dangerous` chain is copied for `spawn_device` / `spawn_device_registered`, with `device_actor_ref` as the
result (`type_checker_builtin_signatures.silica:54-55` pattern), and for `cast_device` / `cast_device_registered`.
Two compatibility checks mirror E4044 / E4045 (`type_checker/expressions/type_checker_expressions_actor_spawn.silica:700-713`):
`spawn` / `spawn_registered` / `spawn_dangerous*` must not start a behavior that contains `register_rwr` or a prim,
and `spawn_device*` must not start one that contains `external_danger` or a `dangerous_*` call (device spec §4.2). A
third env marker, `__silica_tc_in_device_behavior`, is added where `__silica_tc_in_behavior` and `__silica_tc_in_main`
are (`type_checker/declarations/type_checker_declarations_functions.silica:258-266`,
`type_checker_expressions_actors.silica:443-456`); the prim checker of §2.3 and the `sequence proc[register_rwr]`
check require it, which gives the first five rows of device spec §11 (`main`, ordinary behavior, FFI behavior,
`spawn_device` inside a `register_rwr` sequence) one mechanism. `cast` / `call` / `cast_registered` reject a
`device_actor_ref` operand as they reject a `dangerous_actor_ref` today; `cast_device_registered` resolves the third
registry. Effects: `proc[concurrency]` for all four (`effect_checker/effect_checker_core.silica:334-339,421-426`);
`register_rwr` itself joins `is_builtin_effect` (`effect_checker_core.silica:245-256`), which is what turns today's
E3005 into acceptance inside a device worker.

## 3. The ESP32-S3 board-pack window table

The pack publishes the legal `[base, size)` ranges for `map_device` and the widths it allows
([porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.1, §10; device spec §2 "Board window"). The
first version lists the peripheral blocks the runtime already drives from hand-written assembly, because every one
of those base addresses is verified on the port test board by code in this tree. All of them lie on the ESP32-S3
peripheral bus at `0x6000_0000` and are 4 KB-aligned; the runtime's constants are `base + offset` for each register
it uses, which is exactly the shape a device description spells out.

| Window (proposed tag) | `base` | `size` | Widths | Registers the runtime uses today, as `base + offset` | Source |
| --- | --- | --- | --- | --- | --- |
| UART0 `(:esp32s3_uart)` | `0x60000000` | `0x1000` | 32 | `FIFO +0x00`, `STATUS +0x1C` (TXFIFO_CNT is bits 16–25 of STATUS) | `board/runtime/rt_console.S:64-65`, `putc` at 208–223 |
| GPIO `(:esp32s3_gpio)` | `0x60004000` | `0x1000` | 32 | `OUT_W1TS +0x08`, `OUT_W1TC +0x0C`, `OUT1_W1TS +0x14`, `OUT1_W1TC +0x18`, `ENABLE_W1TS +0x24`, `ENABLE_W1TC +0x28`, `ENABLE1_W1TS +0x30`, `ENABLE1_W1TC +0x34`, `IN +0x3C`, `IN1 +0x40`, `PIN0 +0x74 (+4·pin)`, `FUNC0_OUT_SEL_CFG +0x554 (+4·pin)` | `rt_board.S:42-53` |
| RTC_CNTL `(:esp32s3_rtc_cntl)` | `0x60008000` | `0x1000` | 32 | `OPTIONS0 +0x00`, `WDTCONFIG0 +0x98`, `WDTWPROTECT +0xB0`, `SWD_CONF +0xB4`, `SWD_WPROTECT +0xB8`, `SW_CPU_STALL +0xBC` | `rt_start.S:52-55,71,73` |
| IO_MUX `(:esp32s3_io_mux)` | `0x60009000` | `0x1000` | 32 | `GPIO0 +0x04 (+4·pin)` | `rt_board.S:33` |
| TIMG0 `(:esp32s3_timg0)` | `0x6001F000` | `0x1000` | 32 | `WDTCONFIG0 +0x48`, `WDTWPROTECT +0x64` | `rt_start.S:56-57` |
| TIMG1 `(:esp32s3_timg1)` | `0x60020000` | `0x1000` | 32 | `WDTCONFIG0 +0x48`, `WDTWPROTECT +0x64` | `rt_start.S:58-59` |
| SYSTIMER `(:esp32s3_systimer)` | `0x60023000` | `0x1000` | 32 | `CONF +0x00`, `UNIT0_OP +0x04`, `UNIT0_VALUE_HI +0x40`, `UNIT0_VALUE_LO +0x44` | `rt_supervisors.S:103-106`, read sequence 145–166 |
| USB_SERIAL_JTAG `(:esp32s3_usb_serial_jtag)` | `0x60038000` | `0x1000` | 32 | `CONF0 +0x18` | `rt_board.S:60` |
| SYSTEM `(:esp32s3_system)` | `0x600C0000` | `0x1000` | 32 | `CORE_1_CONTROL_0 +0x00` | `rt_start.S:67` |

Never windows, whatever the base: internal SRAM (`0x3FC88000`–`0x3FCE9700` on the data bus, `0x40378000` on the
instruction bus, `board/runtime/silica_esp32s3.ld:18-31,38-41`), the ROM (`0x40000600` `ets_delay_us`,
`0x40000720` `ets_set_appcpu_boot_addr`, `rt_board.S:55`, `rt_start.S:74`), and anything outside the peripheral
region. A constant `map_device((:esp32s3_uart), 0x3FC88000)` is therefore a compile error in the emitter (§4.1).

Notes on the table:

- **The 4 KB block extents are the pack's statement, to be confirmed against the TRM's address-map table**; the
  *bases* are not in doubt (they are the constants the runtime uses). A description is validated against its own
  registers' extents, and `map_device` requires `[base, base + size)` to lie inside one window, so an over-generous
  block size cannot make an access reach a register the description does not list; it can only make an unusual base
  legal. Tightening a block later is not a language change.
- **Two windows are shared with the runtime.** UART0 is the console (`rt_console.S`), and SYSTIMER is the
  supervisors' restart clock (`rt_supervisors.S:145-166`). The device specification's exclusive-window rule is about
  actors (§5.1); the runtime's own drivers are outside actors and outside the cascade (§7;
  [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §9.2). Both stay legal for `map_device` in
  the first version because the specification's own worked example is the UART (§4.7, §4.9) and the bring-up app
  needs it; the console lock (`rt_console.S:79-96`) does not know about a worker's writes to the same FIFO, so a
  program that maps UART0 and also prints interleaves at the byte level. This is documented, not prevented.
- **Widths.** 32 only. A `Register64` access cannot be one load or one store on this bus and is refused with the
  width named (device spec §11 per-emitter row); `Register8` / `Register16` are refused until the TRM confirms that
  sub-word accesses to peripheral registers are architecturally supported here (§9).
- The example description in the device specification (§4.9: `:fifo` at `0x00` `:read_write`, `:int_raw` at
  `0x04` `:write_one_to_clear`, `:status` at `0x1C` `:read_only`) matches `rt_console.S:64-65` for the two registers
  the runtime uses; its window size is `0x20`.

The table lives twice, by construction: once in the emitter (`emitter/ESP32-S3_raw/board_pack.silica`, read by
`prims_device.silica` for the compile-time check) and once in the runtime (`board/runtime/rt_device.S`, walked by
`silica_rt_map_device_check` for the run-time check). Both are generated from one list in `board/README.md` or one is
copied from the other with a comment naming the twin, the way the per-core register-block offsets are shared between
`rt_start.S:81-82` and `shared/xt_vr.silica` today. The emitter copy is drafted as [board_pack.silica](board_pack.silica)
in this directory: the nine rows above as `window_tag(i)` / `window_base(i)` / `window_size(i)` with
`window_containing(base, size)` and `window_allows_width(i, width)` for the checks, the runtime-used registers of
the fifth column as `register_offset_of(window, name)`, and the "never windows" paragraph's SRAM ranges as
`is_sram_address` and its two ROM entry points as `rom_ets_delay_us` / `rom_ets_set_appcpu_boot_addr`; it is pure indexed tables (no lists, no effects), and the same file name is
meant for every OS-free target's `emitter/<TARGET>/`.

## 4. ESP32-S3 code generation

All three prims are emitted by a new `emitter/ESP32-S3_raw/terms/prims/prims_device.silica`, dispatched from
`terms/prims/prims.silica` by name before the type-based dispatch (the `prims_memory@is_memory_prim` arm at
`prims.silica:155` is the pattern). Operands arrive the way memory prims' do: `term_emitter` stages the left child in
`X1` and the right child in `X2` before calling `emit_prim_op` (`prims.silica:19`;
`prims_memory.silica:229,239` "Operands: X1 = ref, X2 = value"). On this target `X1` and `X2` are the pairs
`a12:a13` and `a14:a15` ([esp32s3_xtensa_port.md](esp32s3_xtensa_port.md) §2), a window is a pointer-class value
with a zero high word, and the low word is what addresses the bus.

### 4.1 `map_device`

The window value is the base address: a `device_window` is to a peripheral what a region handle is to its first
block, a pointer that never moves (`prims_memory.silica:33-35`). Nothing is allocated (device spec §4.7 "it does not
allocate").

- **Constant base** (the `inner` child is an integer constant node): `prims_device.silica` checks
  `[base, base + size)` against `board_pack.silica`'s table (`window_containing`, [board_pack.silica](board_pack.silica)). Inside a window: emit `movi` of the base into the
  destination pair (`xt_isa@xt_movi`, high word 0). Outside: refuse with the range named
  ([porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §10 "The port's emitter refuses a constant
  `map_device` outside the pack's windows"; device spec §11 per-emitter row 3). Until the wide diagnostic channel
  exists the refusal is an `.error "ESP32-S3: map_device [0x…, 0x…) is not a board window"` line like the port's other
  refusals (`emitter_core.silica:347`, `terms/file_io_inline.silica:81-96`); when `unsupported_prim_reason` gains an
  operand-aware form it moves onto the pre-emit pass (§6).
- **Non-constant base**: emit a call to `silica_rt_map_device_check(base, size)` in `board/runtime/rt_device.S`,
  Silica pair convention (`a2:a3` = base, `a4:a5` = size, [esp32s3_xtensa_port.md](esp32s3_xtensa_port.md) §4),
  through `terms/call.silica`'s runtime-call path. The routine walks the same table and returns on success; on
  failure it calls `silica_rt_abort_with` with a reason string (`board/runtime/rt_console.S:376-381`), which prints
  `[silica] abort: illegal device map at 0x<pc>` and ends the program with status 71
  ([runtime_failure_reporting.md](../runtime_failure_reporting.md); `board/README.md` "Console protocol"). That is the
  "otherwise at initialization with a hard halt" of [porting_for_os_free_targets.md](../porting_for_os_free_targets.md)
  §5.1. Then `dest <- X1`.
- **Overlap with a live map** (device spec §5.1, §11): the constant-vs-constant case is decidable in the shared
  checker; the runtime case needs `rt_device.S` to keep a small table of live windows and halt on the second
  overlapping map. Which of the two the specification means is a plan-level open question; the routine above is
  where either lands.

`rt_device.S` joins `RUNTIME_SOURCES` in `board/tools/build_image.sh:68`.

### 4.2 `peek`

For a `peek` node of type `uint32` with offset `off` and the window in `X1`:

```
    memw                          ; order after every earlier load/store (§5)
    l32i    a2, aW, off           ; the one load; aW = the window's low word, off from the SIR node
    <put a2 into dest's low word, 0 into its high word>
```

Mechanics, all through existing helpers:

- The window's low word is fetched from its virtual-register home by `xt_vr@vr_lo_load` (`shared/xt_vr.silica`),
  the same step `xt_strb` takes for its source (`shared/xt_mem.silica:438-443`).
- The access is `xt_mem`'s `access()` with the operand text `[X1, #off]` (operand forms at `xt_mem.silica:22-24`;
  `access` at 334–345 produces `op3m("l32i", r, base, disp)` for a non-frame operand). `disp_fits`
  (`xt_mem.silica:196-201`) allows `0 … 1020` in multiples of 4 for a 32-bit access, `0 … 510` even for 16-bit,
  `0 … 255` for 8-bit; the GPIO block's `FUNC0_OUT_SEL_CFG` at `+0x554` (§3) is the one register in today's table
  outside the 32-bit range, and for it `addr_setup` / `addr_disp` already materialise `base + disp` into a scratch
  register (`xt_mem.silica:253,299`, `add_imm_into` at 204). So no new addressing code is needed, only the pair
  `(window register, constant offset)` handed to the helper that `emit_read_ref` hands `"[X1]"` to
  (`prims_memory.silica:228-231`).
- The result goes to the destination through `store_words(dst, "a2", zero)` (`xt_mem.silica:374`), which is what
  `xt_ldrb` / `xt_ldrh` do for an unsigned narrow load (`xt_mem.silica:389-394`); no sign extension, since `T` is
  unsigned. If `Register8` / `Register16` are later allowed, the opcode is `l8ui` / `l16ui` with the same shape.
- Exactly one load: `xt_ldr`'s 8-byte path is two `l32i`s (`xt_mem.silica:382`), which is why a `uint64` `peek` is
  refused rather than emitted (§3).
- A `peek` bound to `_` emits the same three lines (§1 "Discarded reads").

### 4.3 `poke`

For a `poke` node with offset `off`, the window in `X1`, and the value in `X2`:

```
    memw                          ; order after every earlier load/store
    s32i    a2, aW, off           ; the one store; a2 = the value's low word
    memw                          ; the store is performed before anything that follows (§5)
    <dest <- the program's index for :ok>
```

- The value's low word comes from `xt_vr@vr_lo_load("X2", "a2")`, as in `xt_strb` (`xt_mem.silica:438`); the store
  is `access("s32i", …, is_store = true, …)` with `[X1, #off]`. `s8i` / `s16i` (`xt_mem.silica:438-443`) would serve
  the narrower widths if the pack allowed them.
- **`:ok`.** Atom indices are per executable, so the emitter maps a fixed runtime meaning to the program's own index
  at the call site: `emit_prim_op_with_atoms` does this for `migrate_actor` with
  `atom_table@atom_lexeme_to_index(table, ":ok")` (`terms/prims/prims_actors.silica:606-628`). `poke` uses the same
  entry point (`prims.silica` must route it to the `_with_atoms` variant, as it does the actor prims). The precedent
  accepts index −1 for an atom the program never names because no `case` arm can match it; `poke`'s `:ok` is the
  same, but the SIR lowering should make `:ok` visible to `atom_table@build_atom_table(sir_module)` (an atom-constant
  child, or the seeded prefix `main_emit.silica:30-38` mentions) so that a program which prints the result prints
  `:ok` rather than a missing atom.
- Two accesses, never one, for a read-modify-write (device spec §4.7 "No read-modify-write prim"): the compiler has
  no prim that could fuse them, and §7 warns about the common mistake.

### 4.4 What the scheduler does not do

There is no preemption between a `memw` and its access: interrupts are never enabled (`board/runtime/rt_vectors.S:147-149`;
[esp32s3_xtensa_port.md](esp32s3_xtensa_port.md) §8.1 "nothing is preempted"), and a context switch happens only
inside a runtime call ([esp32s3_xtensa_port.md](esp32s3_xtensa_port.md) §8.2). A window is owned by one actor
(device spec §5.1), and an actor runs on one core at a time ([esp32s3_xtensa_port.md](esp32s3_xtensa_port.md) §8.5),
so the per-core ordering `memw` gives is the ordering the window needs; cross-core visibility of ordinary memory is
the mailbox's business, and the runtime already fences its shared words with `memw` around lock release
(`rt_actors.S:270-293`, `rt_heap.S:74-80`, `rt_console.S:149-153,172-174`).

### 4.5 Call-site barriers stay

`effects/emitter_effects.silica:87-105` keeps emitting `memw` before and `memw` + `isync` after a call whose
effect string contains `register_rwr` (applied at `terms/call.silica:120-122`). With the access-level barriers of
§4.2–§4.3 these are redundant, not wrong; removing the `isync` is a later tidy-up (§5.3).

## 5. Why `MEMW`, and what about `ISYNC`

Spec §9.1.1 gives `DSB SY` before and `ISB` after for AArch64 and leaves the ESP32-S3 opcodes to the port table
([porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.3). The port table already exists for calls
(`emitter/ESP32-S3_raw/effects/emitter_effects.silica:76-81`: "`MEMW` orders every earlier load/store before every
later one (the role `DSB SY` / `DMB ISH` play on AArch64) and `ISYNC` waits for it to take effect before the next
instruction fetch (`ISB`)"). The question for the accesses themselves is what is required at each `peek` / `poke`.

### 5.1 What the runtime itself does

Every device access the runtime makes follows one pattern, and it is the best evidence available in this tree:

| Site | Pattern | Purpose it serves there |
| --- | --- | --- |
| `rt_board.S:76,126,149,168` | `s32i` to GPIO / IO_MUX, then `memw` before `retw` | the pin change is performed before the caller's next instruction (a delay loop, another pin) |
| `rt_board.S:181` | `memw`, then `l32i` of `GPIO_IN` | the read is not satisfied before the writes that preceded it have taken effect |
| `rt_console.S:208-223` (`putc`) | poll `l32i STATUS` (no barrier inside the loop), `s32i FIFO`, `memw` | the byte is in the FIFO before the lock is released |
| `rt_start.S:202-230` | a sequence of `l32i` / `s32i` to RTC_CNTL and SYSTEM, one `memw` at the end | the APP-cpu reset pulse is complete before the ROM call |
| `rt_supervisors.S:145-166` | `s32i UPDATE`, poll `l32i` until `VALID`, `l32i LO`, `l32i HI` — no `memw` | a status poll whose loads must each be performed (this is the "reads are never removed" case in runtime form) |
| lock release, `rt_actors.S:270-293`, `rt_heap.S:74-80`, `rt_console.S:149-153,172-174` | `memw`, `s32i 0`, `memw` | release ordering for a word the other core reads |

`isync` appears only after writing special registers that affect fetch or debug state (`rt_actors.S:849` after
`wsr dbreakc`), and `rsync` after `wsr ps` / `windowstart` (`rt_vectors.S:76,236,239`, `rt_start.S:102`): never around
a data access.

### 5.2 The Xtensa instructions (from the ISA, not this tree)

- `MEMW` (Memory Wait): the processor performs every earlier load, store, acquire, release, prefetch and cache
  operation before any later one; it is the instruction the Xtensa ISA provides for ordering accesses to memory-mapped
  devices, and the Xtensa GCC port's default `-mserialize-volatile` inserts a `MEMW` before each volatile memory
  reference so that volatile accesses appear in program order. **Confidence: high** (ISA definition; the GCC option
  and its default; consistent with every runtime site above).
- `ISYNC`: waits until earlier instructions that change instruction-fetch state (special-register writes, cache and
  breakpoint changes) have taken effect before fetching further instructions. It has no role in ordering data accesses
  to a peripheral. **Confidence: high.**
- `DSYNC` / `ESYNC` / `RSYNC`: synchronise special-register writes of various kinds; not relevant to MMIO data.
- On the ESP32-S3 the peripheral region at `0x6000_0000` is not behind the cache: only external memory (flash and
  PSRAM through the cache MMU) is cached; internal SRAM and the peripheral bus are accessed directly. So the
  "never a cacheable path" requirement ([porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.2)
  holds by address, with no cache-control instruction at the access. **Confidence: medium-high**; confirm in the
  TRM's memory-map and cache chapters before the gate (this bare-metal image also never enables flash XIP,
  `board/README.md` "Image model", so no cache is configured at all today).

### 5.3 The choice

- **`memw` before every `peek` and every `poke`.** This is the "before" barrier: every access is performed after
  every earlier load and store, so two accesses are never reordered with each other (the "moved past another `peek`
  or `poke`" clause of §5.2) and a `peek` after a `poke` sees the poke's effect. It is exactly GCC's
  `-mserialize-volatile` discipline and the `rt_board.S:181` read.
- **`memw` after every `poke`.** The "after" barrier: the store is performed before whatever follows, which may be
  ordinary Silica code (a busy-wait, a `cast` whose receiver reads a DMA buffer, a return to the scheduler). Every
  runtime routine that ends with a device store does this (`rt_board.S:76,126,149,168`, `rt_console.S:219`,
  `rt_start.S:230`). A trailing `memw` after a `peek` is not needed: the value is already in a register.
  **Confidence: medium** that it is required in every case rather than only where the next instruction depends on
  the device having seen the store; it is cheap, and mirroring the runtime is the safer reading of
  "wrap the accesses" ([porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.3).
- **No `isync` at accesses.** Nothing about a data load or store to a peripheral changes instruction-fetch state.
  The call-site `isync` (`emitter_effects.silica:97-105`) is a faithful transcription of the AArch64 `ISB` into the
  port table rather than a need of the hardware; it can stay for board release 1 and be reconsidered afterwards.
- **Not `s32c1i`.** The compare-and-swap the locks use (`rt_actors.S:259-266`) is for atomic RAM words on the
  two-core path, not for device registers; a register write is a plain `s32i`.

## 6. The hosted rejection

### 6.1 Where the check goes

The compiler binary is built for one `TARGET`, and only that target's `emitter/<TARGET>/` tree is compiled into it
(`compiler/src/Makefile:5-38,298`); `emitter_core` is therefore always the target's own module. Each of the four
`emitter_core.silica` files exports one new function:

```
unsupported_prim_reason(prim_name: string) -> string
```

returning `""` when the target lowers the prim and a one-line reason otherwise. The hosted trees return, for
`map_device`, `peek`, and `poke`, `"this target cannot reach a device (silica_device_actor_specification.md §10)"`;
`ESP32-S3_raw` returns `""` for them and, on the same channel, the reasons it prints as `.error` lines today for
foreign calls and file io (`emitter_core.silica:347`, `terms/file_io_inline.silica:81-96`).

A new `sir_generator/sir_target_verify.silica`, built on `sir_call_verify.silica:29-57` (`verify_module_calls`,
`verify_functions`, `verify_nodes`, `declaration_location`), walks every function's SIR nodes after SIR generation and
reports the first kind-6 node whose name has a non-empty reason:

```
CodegenError E2220  <file> line <n> column <m>
module 'device_uart', function 'drain_fifo': the prim 'peek' cannot be compiled for apple_silicon_mac:
this target cannot reach a device (silica_device_actor_specification.md §10)
```

(the E4001 message at `sir_call_verify.silica:53` is the model: module, function, builtin, at the function's
declaration location). The driver calls it where it calls `sir_call_verify` (`main_compile_pipeline.silica:276-285`),
so the error goes through `diagnostics_core@print_compiler_error` (`diagnostics/diagnostics_core.silica:24,89`), the
unit's status is non-zero, `compile_parsed_unit` never reaches `emit_module` or `build_output@write_assembly`
(`main_emit.silica:82-95`), and no `.sams` exists for the unit. Because the pass walks every function, a `peek` in a
function nothing calls is rejected (device spec §10 "wherever a poke prim appears"). The target name in the message
is the emitter's; the file, line and column are the function's, since SIR nodes carry no locations yet
([porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §5.5 "line and column need source locations on
SIR nodes, which can follow").

### 6.2 What it must not do

- It must not be an assembler `.error` (device spec §10: "not an assembler `.error` line"): those fail only when the
  file is assembled, with no Silica location ([esp32s3_port_status.md](esp32s3_port_status.md) §3).
- It must not depend on the emitter's dispatch reaching a catch-all. Today the three hosted `prims.silica` files end
  in `_ -> concat("    ; unsupported prim type: ", dispatch_type)` (`emitter/apple_silicon_mac/terms/prims/prims.silica:193`;
  `//` comments in the two Linux trees), and every per-type dispatcher has the same shape
  (`prims_memory.silica:622`, `prims_actors.silica:723`, `prims_atom.silica:82`, `prims_bool.silica:81`,
  `prims_narrow.silica:118`, `prims_uint64.silica:97`, `prims_tuple.silica:383`, `prims_list.silica:602`,
  `prims_float16/32/64.silica`, `prims_checked_int64.silica:97`). A `peek` of type `uint32` that reached
  `prims_narrow@emit_prim_op` would fall to line 118 and become a comment: the load is gone and the destination
  register holds whatever was there, which is the silent miscompile of
  [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) §14. Two changes close this independently of
  §6.1: every one of those arms becomes an `.error "unsupported … prim: <name>"` line, as the ESP32-S3 tree's
  already are (`emitter/ESP32-S3_raw/terms/prims/prims.silica:193`, `prims_memory.silica:598`), and the three hosted
  `prims.silica` gain explicit `map_device` / `peek` / `poke` arms producing an `.error` that names the prim. Neither
  is the rejection the specification requires (they have no source location and fire late); both make the required
  rejection's failure mode loud instead of silent.
- It must not reject `spawn_device`, `spawn_device_registered`, `cast_device`, or `cast_device_registered` (device
  spec §10): those lower on every target through `terms/prims/prims_actors.silica` with a third registry
  (`prims_actors_runtime_asm.silica` on the hosted paths).
- It must not be bypassed by module-qualified names: the shared checker resolves `m@peek` to an ordinary function
  (§2.3), so only the prim node carries the name `peek`, and only the prim node is what the pass sees.

### 6.3 Trials

One `.golden_fail` trial per hosted path in `trials/error_enforcement_addition/` (device spec §11 "the hosted
rejection needs one such trial on each hosted path"), whose program is a `device_*` module with a description and a
`peek` in an uncalled function; the same trial is listed in `trials/targets/ESP32-S3_raw.skip` with a `target:` reason,
since on the board it is not an error. A second trial on each hosted path spawns and casts to a device worker with no
`map_device`, and compiles and runs.

## 7. The write-one-to-clear warning

Device spec §4.9: for a register described `:write_one_to_clear`, "the compiler warns when the poked value is the
unmodified result of a `peek` of the same register, a read-modify-write that clears every bit that was set". The
check is syntactic and local to one `sequence` body, in `type_checker_expressions_device.silica` (§2.3):

1. On a `poke(w, :r, v impl RegisterN {})` whose register `:r` is `:write_one_to_clear` in `w`'s description and whose
   value expression is a bare identifier `v` (AST kind 1), walk the enclosing sequence body's earlier statements
   (kind 6 lets, `parser_ast.silica:77`) for the binding of `v`.
2. If that binding's right-hand side is `peek(w', :r') impl RegisterN {}` with the same window identifier `w' == w`
   and the same register atom `:r' == :r`, and no statement between the two rebinds `v` or `w`, report the warning.
   Any expression around `v` (`v band mask`, `v bor bit`, a call) is not "unmodified" and is not warned about;
   nor is a `peek` of a different register or through a different window.
3. Report through `diagnostics_core@print_compiler_warning(warning_type, code, location, message, spec_section)`
   (`diagnostics/diagnostics_core.silica:25,138`), the path the compiler's one warning, W4001, uses today; the
   location is the `poke` call's. Proposed code **W2201** (device spec §11: "the write-one-to-clear warning takes a
   warning code in the same family"); message: `poke of :int_raw writes back the unmodified value read from it;
   :int_raw is write-one-to-clear, so this clears every bit that was set (silica_device_actor_specification.md §4.9)`.
4. Trial: `trials/warning_enforcement_addition/device_w1c_read_modify_write` (that suite's fixtures build C
   archives today, [esp32s3_port_status.md](esp32s3_port_status.md) §4.1 row "Foreign calls"; a pure-Silica warning
   trial in it needs no archive).

The warning is not an error because the pattern is legitimate when the programmer's intent is "acknowledge every
pending interrupt", which is the common use of `int_clr`-style registers; the specification chose a warning for the
same reason (§4.9 table, last row).

## 8. The third registry

The runtime keeps two PID registries as actors whose state is a 240-slot table of refs indexed by atom
(`board/runtime/rt_actors.S:210,354-358,2021-2024`), started by `silica_pid_registry_init`, which the emitter injects
at the top of `main` (`rt_actors.S:390`; [esp32s3_xtensa_port.md](esp32s3_xtensa_port.md) §8.7); the keyed forms pick
the registry by which `*_registered` intrinsic was called (`rt_actors.S:1818-1866`). The device table is a third ref
word, `silica_device_pid_registry_ref`, a third registry actor spawned by the same init, and a `cast_device_registered`
path that looks up only that word, so `cast_registered` can never resolve a device worker and
`cast_device_registered` can never resolve an ordinary or FFI one (device spec §1 "Split registries", §11 row 7). Its
cost on the board is one more 2 KB-reserve actor plus the table ([actor_memory_budget_plan.md](../actor_memory_budget_plan.md)
"Per-actor and per-supervisor cost"). The hosted runtimes (`emitter/<T>/terms/prims/prims_actors_runtime_asm.silica`)
mirror the same third table.

## 9. Confidence and what to verify before the gate

| Claim | Basis | Confidence | Verify by |
| --- | --- | --- | --- |
| `MEMW` is the Xtensa ordering barrier for MMIO; place it before each access | ISA; GCC `-mserialize-volatile`; every runtime site in §5.1 | high | reading the ISA reference for `MEMW`; the xt_helpers self-test style check (`board/tests/xt_helpers_selftest`) is not needed for a barrier |
| a trailing `memw` after a `poke` is required, not only conventional | runtime habit (`rt_board.S`, `rt_console.S`, `rt_start.S`) | medium | TRM bus chapter; harmless if unnecessary |
| the `0x6000_0000` peripheral region is never cached on this image | ESP32-S3 memory model (cache is for external memory); this image enables no cache | medium-high | TRM memory-map and cache chapters |
| 4 KB block extents for the windows in §3 | the runtime's constants are all `0x6000_x000 + small offset` | medium (bases: high) | TRM address-map table; tighten `size` per block if narrower |
| 8- and 16-bit peripheral accesses are supported on this bus | not established | low | TRM; until then `Register8` / `Register16` are refused |
| `sequence proc[register_rwr]` is E3005 today | `effect_checker_core.silica:245-256`, `effect_checker_declarations.silica:135-166`; no trial uses the effect | high | one error-enforcement trial before work item 1 |
| the emitters emit every `%_` let's right-hand side | `term_reg_spill.silica:856`, `term_sir_helpers.silica:131`; no dead-code pass | high | the gate's `.sams` inspection of a discarded `peek` |
| `xt_mem` operand forms cover `[X1, #off]` with a fallback for large offsets | `xt_mem.silica:22-24,196-201,300-345` | high | the GPIO app's `FUNC0_OUT_SEL_CFG` (`+0x554`) exercises the fallback |
| the device spec's cross reference to spec §3.4.11 for literal typing | spec §3.4.11 is "Trait Method Disambiguation", §3.4.12 "Type Implementation Disambiguation" | medium | correct the reference when the checker lands |
