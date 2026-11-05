# Chunk 15 phase 6: running notes (Fable)

Design: `chunk15_stack_memory_design.md` §6 (§6.1 the pass and what it computes), §4.5 (strict mode),
§11.1 row 6; `region_memory_safety_design.md` §4, §6, §10, §11 (decision 16: lifetimes and isolation
only, no ownership state); `Phase3_notes.md` §10.8.4 (the parser skips an unknown top-level token, so
`strict …;` needs a declaration tag). Stage 6a is the pass skeleton and the analysis in report mode;
6b onwards add the diagnostics (E2301, E2302, E2300 narrowed, E2242). Nothing here was built or run
(Haiku builds). The Linux twins, the ESP32-S3 tree and src_selfhost are untouched.

## 1. Stage 6a: the pass, the analysis, `strict region_check;` (written 2026-10-31, not built)

### 1.1 Files

| File | Change |
| --- | --- |
| `compiler/src/region_checker/region_checker_core.silica` | new: the pass (`check_program_regions/2`, `program_declares_strict/2`) and the §6.1 analysis |
| `compiler/src/region_checker/Makefile` | new: the `subdir_stub.mk` stub, as `src/ffi/Makefile` (sources are found by `topo_silica_config.sh`'s `find`, so the directory needs no registration) |
| `compiler/src/parser/constraint_extract_decls.silica` | `is_strict_decl_start`, `extract_strict_declaration` (tag 10), one new arm in `extract_one_declaration` after the `module` arm |
| `compiler/src/main_compile_pipeline.silica` | `use region_checker_core;`; the gated call after the effect check, before `Generating SIR` |

### 1.2 The declaration: `strict <what>;`, tag 10

`strict` is not a lexer keyword (`lexer_keywords.silica` has `module`, `use`, `export`, … and no
`strict`), so the line lexes as identifier, identifier, semicolon and the top-level walk dropped it
(`declarations_from_slots`: `decl.tag >= 0` keeps a declaration, anything else skips one slot). The
new extractor is modelled on `extract_module_declaration` (tag 4, `module name;`): identifier with
lexeme `strict`, whitespace, an identifier, whitespace, `;`. The declaration carries the word after
`strict` in `name` (`region_check`, and later `state_release`), tag **10**, the keyword's location,
`dummy_expr()` as body. An unknown word after `strict` is accepted and ignored for now (no code for
it yet; a later stage can reject it). The arm sits after the `module` arm and before `wrapper_meta`
in `extract_one_declaration`, so `fn`, `export`, `use`, `module`, `foreign`, `wrapper_meta`, `effect`,
`impl`, trait markers and the required/provided sections are tested exactly as before.

**Tag audit** (grep over `compiler/src`, `.silica`, the build output excluded). Tags in use: 0 fn /
provided method / impl fn, 1 `effect NAME = [...]`, 2 `use`, 3 `export`, 4 `module`, 5 `export trait`,
6 marker impl, 7 required signature, 8 `wrapper_meta`, 9 `foreign`; 10 was free (no `tag: 10`,
`tag == 10` or `decl_tag == 10` anywhere). Tests on the tag: `.tag == 0` ×69, `decl_tag == 0` ×1,
`.tag == 1` ×1, `== 2` ×12, `== 3` ×8, `== 4` ×3, `== 5` ×14, `== 6` ×7, `== 7` ×14, `decl_tag == 7` ×1,
`== 8` ×8, `== 9` ×22: all equality tests, none matches 10. `.tag != 0` ×1
(`constraint_extract_hof_wrap.silica:402`, a lambda-lifted declaration, never tag 10). `.tag >= 0` ×1
(`declarations_from_slots:1071+`, the keep rule: tag 10 is now kept, which is the point). `case … tag of`
switches ×10: `sir_generator/declarations/dispatcher.silica:35`, `declarations/functions.silica:111`,
`type_checker_callee_env.silica:439` and `:568`, `type_checker_runner.silica:43` and `:60`,
`type_checker_modules.silica:135` and `:231`, `type_checker_expressions_user_call_world.silica:134`,
`type_checker_expressions_user_call_check_defined_world.silica:83`: every one has a `_: int64 ->`
default arm that passes an unknown tag through (the SIR dispatcher returns `dummy_sir_function()`
for every non-zero tag, as it does for tags 2 to 9 today). The `pack_descriptions.silica` `case tag of`
switches are record shape tags, not declaration tags. The `.iface` writer (`module_iface.silica`)
reads tags 2, 5, 7 and 0 only; a tag-10 declaration is never exported. The module checker's own tag
tests (`module_checker_ffi.silica`, `module_checker_device.silica`) are 2, 8, 9 equality tests.
**Result: no existing tag or tag test is disturbed.**

### 1.3 The pipeline insertion

`main_compile_pipeline.silica`, inside `compile_to_sir_module`, directly after
`case effect_result.is_ok of { true -> {` (line 291 after the edit) and before the `[DEBUG AST]` block
and `println("  Generating SIR...")`:

```
region_st: int64 <- region_checker_core@check_program_regions(program, tc_out.context);
case region_st == 0 of {
    false -> (1, sir_ast@dummy_sir_module());
    true -> { …the SIR generation block, unchanged… }
}
```

The shape is the FFI taint check's (`taint_st`, line 278): an int64, non-zero fails the unit with
`(1, dummy_sir_module())`. In stage 6a the pass returns 0 on every path, so the compile result cannot
change; the gate is in place for the enforcing stages. The pass receives `tc_out.context` as §6.1 says;
this stage does not read it (the binding types it needs are the declared annotations the AST carries
in a let's `value` and a decomposition's `pattern_bindings[].type_str`).

### 1.4 What the pass computes (region_checker_core.silica)

Only when `program_declares_strict(program, "region_check")`; otherwise it returns 0 with no output.
Per tag-0 declaration, one state `{ frame: List[string], moved: List[{ name, line, arm }], lifetimes:
List[string], arm: int64 }` is threaded through the body (`rc_walk`), flow-sensitively:

* **F** (`rc_walk_let`, `rc_walk_decompose`, `rc_walk_arm`): a binding joins F when its right side
  `rc_expr_in_frame`: an identifier in F; an `alloc_region` / `alloc_region_on_numa_node` /
  `alloc_ref` / `alloc_rec` / `alloc_buf` call; any call with an argument in F; a tuple (kind 9), list
  (20) or record (21) literal; a projection (22) of an expression in F; a let chain, sequence, case or
  if whose result expression is in F. A call bound with a declared type that may carry a pointer also
  joins F (`rc_type_is_pointer_free`: the scalar names, `lifetime`, `atom`, and a `:a | :b` sum are
  pointer-free; everything else is not). A case-arm pattern's names join F when the scrutinee is in F.
  Parameters never enter F, so projections of parameters are not in F.
* **M**: every `move(x)` call (kind 4, base name `move`, one argument) adds each identifier of its
  operand with the call's line and the innermost case arm number (0 outside a case; arms count from 1
  per `case`, restored on exit). The design names sends, replies and spawn states; the SIR tags both
  the stripped form and the prim form (`terms_actor_lowering.silica:470-474`), so this stage records
  every position. Alias closure: a binding whose right side mentions a moved name is moved; pattern
  names over a scrutinee that mentions a moved name are moved.
* **Lifetimes**: `L:param` for every lifetime found in a parameter type (the first argument of each
  `ref(`, `ref?(`, `buf(`, `region(`, `atomic_ref(` head that is not the tail of a longer identifier);
  `L:here` for the names in the annotation of an `alloc_region` binding; for `l <- fresh_lifetime()`
  the binding name itself, `l:here`.
* **Case and if**: each arm (branch) starts from the state after the scrutinee (condition); the result
  after the construct is the union of the arms (F, M, lifetimes united; the design's "flow-sensitive
  per arm" is kept inside each arm; the union after the construct is the conservative report-mode
  choice, to be refined when E2301 needs "a move in an arm and a use after the case").
* Scopes are not popped: a name bound in an arm or a nested block stays counted. Lambdas (991) are
  walked for moves but their value is never in F (closure environments are §6.4(c), a later stage).
* Case-arm pattern names come from the pattern text (`rc_pattern_names`): identifiers that are not
  `true` / `false` / `_`, not atoms, not record field names, not the type of a typed binding. Quoted
  string patterns are not recognised (their words would be counted; report mode only).

### 1.5 Output format

Under `strict region_check;`, after `Effect checking...` and before `Generating SIR...`:

```
  Region check (report mode)...
  region check: <fn_name> F=<n> M=<m> lifetimes=<L:here,L2:param>
```

One line per tag-0 declaration in declaration order; `lifetimes=-` when none; the lifetime list is in
first-encounter order (parameters first, then the body). No diagnostic code is printed.

### 1.6 Not followed from the design, and why

* §6.1 says M is "names given to an explicit `move(x)` in a send, reply or spawn state (the SIR `|mv`
  tag)". The pass runs on the AST, before SIR, so it reads the `move` call itself, in any position
  (the lowering comment says the stage-5 checker reads the marker from either form).
* §6.1 "a `bind` arm over a scrutinee in F": read as a case arm whose pattern binds names.
* §4.5 / §6.1 spell the switch `strict region_check;` "beside `strict state_release;`"; the parser now
  accepts `strict <identifier>;` generally (tag 10, the word in `name`) so `state_release` needs no
  second tag. Nothing reads `state_release` yet (Phase3_notes §10.8.4 item 1 stays open: W2300 is
  still a warning).
* The `module` extractor is `sequence … produces pure … end`-wrapped with the record literal packed
  into the returned pair (its comment on the dangling frame pointer); the `strict` extractor copies
  that shape exactly.

### 1.7 Checks for Haiku (one builder at a time, build-slot lock; no trial, golden or `.scout` edits)

1. Build the Mac compiler; the new unit `region_checker/region_checker_core.silica` is picked up by
   `topo_silica_config.sh` (it `use`s `parser_ast`, `sir_ast`, `type_checker_core`).
2. Without `strict region_check;` every unit's compiler output is byte-identical to before (the pass
   prints nothing and returns 0).
3. A scratch program (silica.config in a scratch dir, memory note "Fast compiler-fault repro") with
   `strict region_check;` after its `module` line prints `  Region check (report mode)...` and one
   `  region check:` line per function; check a function with `r: region(L1, normal) <- alloc_region(…)`
   reports `lifetimes=L1:here`, a parameter `x: ref(L2, normal, int64)` reports `L2:param`, a
   `cast(p, move(v))` reports `M=1`, and a tuple literal binding reports `F=1`.
4. `make integrate` on `modules_addition` and `error_enforcement_addition` (the parser change is on
   the top-level declaration path).

## 2. Stage 6a gate (2026-11-01)

Build with the phase 5 compiler as builder (sha1 d6438413...); the new compiler is sha1 ceab2048.... The runtime
assembles. The 12-suite gate: zero `.scout` differences, zero faults, zero compile, assemble or link failures, zero
golden mismatches. The 13 `traits/` units in supervisors_addition are left alone. No `Region check` output (no
program declares `strict region_check;` yet). Stage 6a passes; 6b (E2301) next.

## 3. Stage 6b: E2301 UseAfterMove (written 2026-11-01, not built)

### 3.1 Files

| File | Change |
| --- | --- |
| `compiler/src/region_checker/region_checker_core.silica` | the state gains `errors` (a list of `{ name, line, arm, file, use_line, use_column, use_offset }`); `rc_note_use` records a use of a moved name; `rc_expr_carries_move`, `rc_mv_remove`/`rc_mv_remove_all`, `rc_mv_line`/`rc_mv_arm`, `rc_int_text`, `rc_e2301_message`, `rc_print_error(s)`; `use diagnostics_core;`; the pass returns the error count |
| `compiler/error_codes.md` | E2301 UseAfterMove registered (between E2241 and E2311); the Notes line names the region checker as its emitter |
| `compiler/error_codes.jsonld` | the E2301 entry (`@type` TypeError, as every E2xxx entry), before E2311 |

No other file changed: the pipeline insertion of stage 6a already fails the unit with `(1, dummy_sir_module())`
on a non-zero result, so returning the error count is the whole switch. The parser, the emitters, the Linux
and ESP32-S3 trees and `src_selfhost` are untouched; no trial, golden or `.scout` was written.

### 3.2 What is a use, and where it is caught

Every identifier node (kind 1) reached by the walk is checked against M at that point: an argument, a
projection base (`x.f` is kind 22 with `x` as `inner`, so "a field read from it" is the same check), a
return (the body's tail), a case scrutinee, a send, the operand of a second `move` (the operand is walked
before the move is recorded), a record or tuple element, a lambda body. A call whose callee name is in M
(a function value given away) is a use too. A let binding's *name* is not a kind-1 node, so a rebinding is
not a use. The entry carries the use's location (the identifier's own `location`) and the move's line and
arm from M. Errors are collected in the state, not printed during the walk, because `rc_expr_in_frame`
re-walks nested let / case / if / sequence right sides to answer its F query: those walks start from a
local copy and their error lists are dropped, so no use is reported twice and the query's union state
(after a case) cannot produce a false report.

The diagnostic: `diagnostics_core@print_compiler_error("TypeError", "E2301", <use location>, <message>,
"sect12.1.4")`, as the FFI taint checker prints (TypeError is the E2xxx category of the registry and of
E2311's existing `sect12.1.4`; the design's §11.6 table puts E2301's spec text in §12.1.4). The message is
design §6.2's, `'x' was moved at line N (arm K) and is used here; after an explicit move the sender's
frame may release the value`, with one choice: ` (arm K)` is printed only when the move was inside a
`case` (K ≥ 1); outside any case there is no arm to name (region_memory_safety_design §10: "names the
move's line and, for case, the arm"). Numbers are rendered by a local digit-case formatter (`rc_int_text`);
the compiler has no shared one (`int64_to_str` is private to the parser and the SIR generator).

Per function the report line of stage 6a prints first, unchanged, then that function's E2301 errors oldest
first; `rc_report_decls` sums the counts and `check_program_regions` returns the sum, so a unit with any
E2301 fails after `Region check (report mode)...` the way a taint error fails after `FFI taint...`. Without
`strict region_check;` nothing is printed and 0 is returned, as before (errors on by default are stage 6e).

### 3.3 The arm rule (design §6.2)

* Each case arm (and each if branch) starts from the state after the scrutinee (condition), **not** from
  an earlier arm's: a move in arm 1 and a use in arm 2 is legal (the walk of arm 2 never sees arm 1's M).
* After the case the arms' M are united (stage 6a's merge, kept): a move in an arm and a use after the
  case is E2301, and the message names the arm (`(arm K)`), which is what the arm number in M is for.
* A move before the case is in the state every arm starts from: a use in any arm is E2301.
* A move in an arm of a nested case keeps the inner arm number in M; after the inner case the enclosing
  arm number is restored, as in 6a.

Stage 6a's note that "the union after the construct" was to be refined for E2301 is therefore closed by
keeping the union: per-arm flow is given by the arm's start state, the union gives the after-case rule, and
both are what §6.2 asks for. The error list is threaded through the arms in order (`rc_with_errors(pre,
acc.errors)`), so the errors of arm 2 extend arm 1's, and `rc_merge` takes the later list.

### 3.4 Alias closure, rebinding (changed from 6a)

* 6a marked a binding moved when its right side mentioned a moved name **after** walking it (the
  post-state), so `r: int64 <- call(p, move(x))` made `r` moved and any later use of `r` would have been
  a false E2301. Now a binding is moved when its right side mentions a name moved **before** the binding
  (the pre-state: that mention is itself the reported use, and the alias is closed over), or when its
  value comes from a `move(...)`: `rc_expr_carries_move` is true for a move call and for one reached
  through a paren, a projection base, a tuple / list / record literal, a let or decomposition tail, a case
  arm or an if branch, and false through a call's argument (a call's result is its own value) and for a
  lambda (closure environments are §6.4(c)). The same rule marks a decomposition's names and, through the
  scrutinee, a case arm's pattern names.
* A fresh binding of a moved name (a let, a decomposition name, a case-arm pattern name over an unmoved
  scrutinee) now leaves M (`rc_mv_remove`): the new value is not the released one. 6a never removed from
  M; with errors on, a rebinding after a move would have been reported at every later use. (F is not
  changed on rebinding; nothing reads F for an error yet.) Scopes are still not popped: a name bound in
  one arm stays counted in the merged M for the report line, as in 6a.
* Consequence for the report line: `M=` can be smaller than 6a printed for a function with a `call(p,
  move(x))` bound to a name or with a rebinding of a moved name; the format and the line order are
  unchanged.

### 3.5 Not verified (Haiku: one builder at a time, build-slot lock; no trial, golden or `.scout` edits)

Nothing was built or run. To check, in this order:

1. Build the Mac compiler; `region_checker_core.silica` now also `use`s `diagnostics_core`.
2. Without `strict region_check;` every unit's compiler output is byte-identical to before.
3. A scratch program (silica.config in a scratch dir, memory note "Fast compiler-fault repro") with
   `strict region_check;`:
   * `_: int8 <- cast(p, move(v)); print_int64(v.n)` → one E2301 at the `v` of `v.n`, message
     `'v' was moved at line N and is used here; …` (no arm), `See specification: spec:sect12.1.4`,
     metadata `errorCode: E2301`, the unit fails after the report line;
   * `case c of { true -> { _ <- cast(p, move(v)); 0 }; false -> v.n }` → no error (per-arm);
   * the same case followed by a use of `v` → one error with `(arm 1)`;
   * `_ <- cast(p, move(v))` before a case whose arm reads `v` → one error, no arm text;
   * `cast(p, move(v))` twice → one error at the second operand;
   * `r: int64 <- call(p, move(v)); print_int64(r)` → no error (the call result is not an alias);
   * two uses in one function → two diagnostics, in source order (the use location is the identifier's;
     if both print the same line and column, the parser gives identifier nodes no location of their own
     and the use location must come from the enclosing node instead).
4. `make integrate` on `error_enforcement_addition` and `modules_addition` (no program in `trials/`
   declares `strict region_check;`, so no golden changes are expected; a change means the gate leaks).
5. The E2301 error trials of design §18.6 (`send_then_use_*`) are not written in this stage (errors on
   by default is 6e; the strict gate needs its own trial directory per the compile-defect rule).
2026-11-01: superseded: alloc_region is a frame area (Lee's decision); see chunk15 section 3.8.

## 4. The `alloc_region` move: the atomic/device block is a frame allocation (written 2026-11-01, not built)

Lee's decision (2026-11-01): `alloc_region` allocates in the stack. Design §3.8 (line 312-314) and §3.2
(the prim table, line 214). Mac emitter only: `compiler/src/emitter/apple_silicon_mac/terms/prims/prims_memory.silica`.
Not touched: the Linux and ESP32 emitters (phases 8 and 9), src_selfhost, every trial and golden.

### 4.1 What the code already did, and what it did not

* A **normal-space** `alloc_region` was already a frame area in the design's sense: `emit_prim_op`
  (`"alloc_region" -> case alloc_in_frame(term)`) emits the witness `MOV dest, X29` and allocates
  nothing; every `alloc_ref` / `alloc_rec` / `alloc_buf` into it is an `L_dyn_alloc` in the frame that
  executes the prim (phase 2 S5). Unchanged here.
* An **atomic or device** `alloc_region` (`alloc_in_frame` false: the node's value names `atomic` or
  `device`) went through `emit_alloc_region`: `MOV X0, #4128; BL _silica_rt_raw_alloc` (malloc), a
  null check branching to `_silica_rt_region_alloc_failed`, then the header stores, `MOV dest, X0`. The
  `alloc_*` into such a region still use `emit_region_bump_check` (LDAXR/STXR over the block's bump
  and end words) and `L_region_grow`. That malloc is the one this section removes.

### 4.2 Before and after (`emit_alloc_region`, prims_memory.silica:113)

Before:

```
    MOV X0, #4128
    BL _silica_rt_raw_alloc
    CBNZ X0, 1f
    BL _silica_rt_region_alloc_failed
1:
    ADD X4, X0, #32
    STR X4, [X0]
    MOV X5, #4128
    ADD X4, X0, X5
    STR X4, [X0, #8]
    STR XZR, [X0, #16]
    STR X4, [X0, #24]
    MOV <dest>, X0
```

After:

```
    MOV X16, #4128
    BL L_dyn_alloc
    MOV X4, X16
    ADD X5, X4, #32
    STR X5, [X4]
    MOV X5, #4128
    ADD X5, X4, X5
    STR X5, [X4, #8]
    STR XZR, [X4, #16]
    STR X5, [X4, #24]
    MOV <dest>, X4
```

`L_dyn_alloc` (prims_memory `emit_frame_helpers`, emitted in every module by `emitter_core` 186) is
the same frame allocation `emit_alloc_rec_frame`, `emit_alloc_ref_scalar_frame` and `emit_alloc_buf`
use: X16 = bytes in (a multiple of 16), X16 = the block `[floor - n, floor)` out, the transient area
below the floor moved down, X0-X15 kept. The block lies in the dynamic part of the frame whose X29 is
current when the prim runs, so it is released when that frame pops (the adopting epilogue leaves it
for the caller only when the call is adopted, the same rule every other frame node follows).

The malloc, its null check and the `(:explicit, :region_alloc_failed)` path are gone from
`alloc_region`. `_silica_rt_region_alloc_failed` is still referenced by `L_region_overflow`
(`emit_region_helpers`), so the runtime entry stays. A frame allocation that touches a new page is
stack growth (design §3.2, line 208), not a failure the prim checks.

Registers: the heap form clobbered X0 (the malloc result) plus everything caller-saved through the
`BL`; the frame form changes only X4, X5, X16 and the flags, all within the old clobber set.

### 4.3 Frame area size and layout

Size: **4128 bytes**, the heap form's size, kept for three reasons: the bump checks and `L_region_grow`
assume a 32-byte header followed by cells (`ADD X4, X0, #32`), the first block's 4096 bytes of cells
match the grow helper's minimum extension (`MOV X9, #4096`), and 4128 is a multiple of 16 (258 x 16),
which `L_dyn_alloc` requires. The frame allocation design does not require a different fixed size
(§3.1: a frame node's size is whatever its allocation asks for, rounded to 16).

Layout inside the area (unchanged from the heap block, so the `alloc_*` emitters,
`emit_region_bump_check`, `L_region_grow` and `L_region_contains` are not changed):

| Offset | Word |
| --- | --- |
| +0 | bump, starts at base+32 |
| +8 | end = base+4128 |
| +16 | extensions chain head, 0 |
| +24 | span end = base+4128 |
| +32 .. +4128 | cells handed out by `emit_region_bump_check` |

### 4.4 Callers

`emit_prim_op` (prims_memory.silica, the `"alloc_region"` arm, about line 736): `alloc_in_frame` true
gives the witness, false gives `emit_alloc_region(dest)`. That arm is unchanged; it is reached from
`term_emit_kind_compound_part2` (Phase5_notes.md:457, the `alloc_region` arm emits no X1 argument).
Nothing else calls `emit_alloc_region`. The comment on `alloc_in_frame` (line 186-189) that said an
atomic or device region "keeps the shared block it has today (§2.7)" now says the block is a frame
allocation.

### 4.5 Not followed from §3.8, and what it changes (for Lee)

* §3.8 (line 314) says a region "owns no memory", and §3.2 (line 214) describes `alloc_region` as a
  witness with no block. That holds for normal spaces. An atomic or device region does own a block (its
  bump words are what `emit_region_bump_check` moves), and §2.7 (line 172) lists `region(L, atomic)`
  shared cells as memory that stays outside the stack "as today". Lee's decision puts the block in the
  frame, so §2.7 line 172 is now out of date for atomic/device regions on the Mac; the design row
  should be amended when the Linux and ESP32 twins follow.
* Consequence of the frame lifetime for an atomic region: a cell handed to another actor (the
  message copier copies a region handle and a ref as WORD, §3.6 kind 1 retired) points into the
  allocating frame; once that frame pops the cell is gone. With the malloc block the cell outlived
  the frame. §3.8's own text (line 314) accepts this for the witness case and leaves the escape to
  the lifetime checker (E2300/E2302, §6.3-§6.4, phase 6); the checker does not yet distinguish
  spaces. A returned `region(L, atomic)` handle is not a frame-free scalar
  (`reg_conventions@is_frame_free_scalar_type`), so the call site adopts the callee's frame and the
  block survives a return in the dynamic part, as any other frame node does.
* `L_region_grow` still mallocs its extension blocks (`ADD X0, X20, #32; BL _silica_rt_raw_alloc`)
  and chains them at base+16; nothing frees them (`emit_region_free_helper` is not emitted by any
  caller). That was already so before this change (a region block was never freed since the
  region-destroy machinery went in phase 2 S7); a region that overflows 4096 bytes of cells still
  leaks its extensions. The design (§3.2, line 224) deletes `L_region_grow` with the mailbox copier's
  last use; not done here.
* `alloc_region_on_numa_node` has no Mac emitter arm (front end only); not touched.

### 4.6 Not verified (Haiku: one builder at a time, build-slot lock; no trial, golden or `.scout` edits)

Nothing was built or run. To check, in this order:

1. Build the Mac compiler (`prims_memory.silica` only changed).
2. `make integrate` on `memory_region_addition`: `alloc_region_atomic`, `alloc_region_device`,
   `alloc_atomic_int64`, `alloc_ref_atomic_space`, `train_memory_region_atomic_*` are the programs that
   reach `emit_alloc_region`. Their `.sout` must still match `.scout`; their `.ascomp` goldens change
   by exactly the 13-line to 11-line replacement of §4.2 per `alloc_region` site (update allowed when
   `.sout` matches, feedback-ascomp-update-rule). A program whose atomic region hands out more than
   4096 bytes of cells still goes through `L_region_grow`.
3. `grep -c _silica_rt_raw_alloc` over an emitted `.s` of a program with no region overflow: the only
   remaining reference is inside `L_region_grow`.
4. The `error_enforcement_addition/train_memory_region_atomic_*` trials are compile errors and emit
   nothing; no change expected.
