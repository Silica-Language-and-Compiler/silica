# HIGH PRIORITY — Compiler defects and diagnostic gaps found while generating training trials (2026-09-08)

**Status (original, 2026-09-08):** open defects; see Implementation status below for the current state. Each was found with the seed compiler
`binaries/silica-compiler` (a Silica-built generation, `silica-999994-macos-applesilicon` at the time) while generating the
5,294 `train_*` trial pairs, and each was *avoided* in the generated corpus rather than
fixed. Every reproduction is a single `.silica` file: put it in a scratch
directory with a one-line `silica.config` naming it and run the compiler there (milliseconds), so nothing here needs a compiler rebuild to confirm.

Generator: `programmer_tools/train_trial_generator/` (its README lists the areas it skips
because of the items below).

---

## Implementation status (2026-10-16)

Every item below has an installed `train_defect_*` trial (56 `.silica` files across `actors_addition`,
`floatNN_addition`, `intNN_addition`, `uintNN_addition`, `tuples_addition`, `traits_addition`,
`deep_frame_spill_addition` and `error_enforcement_addition`). The behaviour trials carry hand-derived
`.scout` goldens and their last recorded `.sout` equals the `.scout`; the error trials carry `.golden_fail`
goldens that equal the last `.cur_fail`. Plan and execution record:
[compiler_defects_resolution_plan.md](./compiler_defects_resolution_plan.md),
[compiler_defects_execution_status_2026-09-10.md](./compiler_defects_execution_status_2026-09-10.md).

| Item | Status | Where it lives |
| --- | --- | --- |
| A1 second float parameter lost | fixed | `train_defect_a1_*` (6 trials, float16/32/64) |
| A2 returned closure loses capture | rejected with E1067 (interim); closure environments NOT implemented | `train_defect_a2_*` (3 `.golden_fail`) |
| A3 record-typed actor state through call/reply | fixed | `actors_addition/train_defect_a3_record_state_reply_0001` |
| A4 tuple/record parameter after a scalar | fixed | `train_defect_a4_*` (3 trials) |
| A5 provided trait methods across the exit-75 restart | fixed | `traits_addition/train_defect_a5_*` |
| A6 large single units killed | fixed (20-40 live bindings compile) | `deep_frame_spill_addition/train_defect_a6_*` |
| A7 parenthesised right operand | fixed | `train_defect_a7_*` (per integer width) |
| A8 float compare, compound both sides | fixed | `train_defect_a8_*` (float32, float64) |
| A9 record message with List state | fixed | `actors_addition/train_defect_a9_*` |
| A10 call whose message is a call expression | fixed | `actors_addition/train_defect_a10_*` |
| B1-B14 diagnostic gaps | all diagnosed | `error_enforcement_addition/train_defect_b*` (B1 E2005, B2 E2001, B3/B4 E3002, B5 E3010, B6 E1040, B7 E1066, B8/B9 E2001, B10 E2019, B11 E2005/E2001, B12 E2011, B13 E2001, B14 E2005) |

Open: A2 closure environments (a function value is a code pointer only; the E1067 diagnostic stops the
silent wrong answer for a returned capturing literal; the design decision, a two-word closure of code
pointer and environment, is not taken). The four misleading-diagnostic wordings in the section after
the Part B table were not re-checked against the current compiler and stay listed as open.

The body of this document is the original 2026-09-08 report, kept as the record of the reproductions.

---

## Part A — Programs that compile and run wrong (silent miscompilation)

These are the most important. A program the compiler accepts produces the wrong answer.

### A1. The second floating-point parameter of a user function is lost

```silica
fn addf(x: float64, y: float64) -> float64 {
    x + y
}

fn main() -> atom {
    sequence proc[device_io]
        result: atom <- print_float64(addf(1.5, 2.25))
    produces pure result end
}
```

Prints `0.000000000000000`; expected `3.75`. Variants measured:

| Signature | Body | Call | Printed | Expected |
| --- | --- | --- | --- | --- |
| `(x: float64, y: float64)` | `x + y` | `(1.5, 2.25)` | `0.0` | `3.75` |
| `(x: float32, y: float32)` | `y` | `(1.5, 2.25)` | `1.5` | `2.25` |
| `(n: int64, y: float64)` | `y` | `(3, 2.25)` | `0.0` | `2.25` |
| `(x: float16)` (one param) | `x + 1.0` | `(2.0)` | correct | — |

Only the first floating-point argument reaches the callee; a second float, whether or not
an integer precedes it, arrives as 0.0 or as a copy of the first. The existing
`float*_addition/call_registers.silica` trials pass only because every helper there takes
one parameter. **Avoided by:** every generated float helper takes exactly one float
parameter.

### A2. A closure returned from a function loses its captured parameter

```silica
fn make_adder(k: int64) -> fn(int64) -> int64 {
    fn(x: int64) -> int64 { x + k }
}

fn main() -> int64 {
    add_k: fn(int64) -> int64 <- make_adder(10);
    add_k(5)
}
```

Exit status 5; expected 15. A function literal *passed into* a call and capturing a local
of the caller (`functions_addition/fn_param_binary_fn_type_capture.silica`) works; a
literal *returned* out of the frame that owns the captured value does not. The
specification's `make_multiplier` example (§3.4.1) is exactly this shape.
**Avoided by:** the returned-closure template was dropped.

### A3. Record-typed actor state through `call` / `(:reply, …)` faults

```silica
fn tally(msg: int64, state: { v: int64, hits: int64 }) -> (:reply, int64, { v: int64, hits: int64 }) {
    (:reply, state.v + msg, { v: state.v + msg, hits: state.hits + 1 })
}

fn main() -> atom {
    sequence proc[concurrency, device_io]
        w: actor_ref <- spawn({ v: 6, hits: 0 }, tally);
        r0: int64 <- call(w, 9 impl ActorMessage {});
        print_int64(r0);
        println("")
    produces
        pure :ok
    end
}
```

Output is nondeterministic and the process emits a stream of
`[silica] fault at … in _longjmp+0x48 …` lines. The same record state through a
`cast`-only behavior (`actors_addition/actor_behavior_forward_cast.silica`) works.
**Avoided by:** the record-state actor template was dropped; generated actor state is
`int64`, `string` or `atom`.

### A4. Tuple parameter after a scalar parameter clobbers the scalar (previously noted, still open)

Found the same day in another session and recorded in the project notes: any function
whose tuple parameter follows a scalar reads garbage for the scalar because the
destructure stages the tuple pointer through `X0` without saving the first parameter.

```silica
fn second_sum_step(acc: int64, x: (int64, int64)) -> int64 {
    (_: int64, b: int64) <- x;
    acc + b          // second_sum_step(5, (3, 10)) returns 13, not 15
}
```

A staged repro (`tuple_param_after_scalar_callback.silica`, expected exit 0, exits 1
today) exists outside the tree. **Avoided by:** generated tuple parameters are always the
first parameter.

### A5. Provided trait methods lose overload resolution across the exit-75 restart

`trials/traits_addition` as committed has 31 units and the seed compiles it in one
process; `shape_main.silica` then calls the mangled
`Shape_double_area___width___int32___length___int32____ret_int32` and links. Add two
units to that directory (one root program using `Sizeable` plus one new trait module and
its root program; each alone is harmless) and the seed begins exiting 75 between units to
reclaim memory. On resume, `shape_main` is emitted calling a bare `Shape_double_area`,
which nothing defines, and the link fails:

```
Undefined symbols for architecture arm64:
  "Shape_double_area", referenced from: main in shape_main.o
```

The in-memory record of `provided` methods and their overloads is evidently not
reconstructed from the published `.iface` files on the resume path. Any trial directory
that grows past the reclaim threshold and calls a provided method is exposed.
**Avoided by:** no `train_*` files were added to `traits_addition`, and generated trait
programs (used only during verification) never called provided methods.

### A6. Compiler killed on large single units

Six generated `deep_frame_spill_addition` candidates (20–40 live `int64` bindings summed in
one block, the same shape as the existing `many_live_across_calls.silica`) ended the seed
with signal 9 during the batch compile. Not isolated further. **Avoided by:** that
directory was left untouched.

---

## Part B — Things the compiler should reject but accepts (diagnostic gaps)

Each of these was tried as a "one deliberate mistake" and the compiler reported
**no error**. They cannot be turned into failure trials until the diagnostic exists.
Counts are from the two generation runs (151 rejected candidate mistakes in total).

| # | Mistake | Example that compiles | Notes |
| --- | --- | --- | --- |
| B1 | Extra call argument | `sum4(1, 2, 3, 4, 1)` after `fn sum4(a, b, c, d)` | Too **few** arguments is diagnosed (`E2005 … argument count mismatch`); a minimal 2-parameter case *is* diagnosed, so the check is shape-dependent. |
| B2 | Integer literal passed to a `string` parameter | `double_len(5)` after `fn double_len(s: string)` | A string literal into an integer parameter *is* diagnosed (E2001). A minimal case reports `E2001 string literal required, got numeric literal`, so again shape-dependent. |
| B3 | Wrong effect inside a `case` arm | `sequence proc[mem(normal)] … case x of { 0 -> print_int64(0); … }` | `E3002` fires only for effectful calls at the top level of the sequence body. |
| B4 | `mem(normal_writeback)` list ops under `proc[device_io]` | `List[int64, mem(normal_writeback)]` literal inside `sequence proc[device_io]` | With `mem(normal)` the same program is rejected (E3002). |
| B5 | Unused `mem(normal)` on a pure sequence | `sequence proc[mem(normal)] produces pure 42 end` | `E3010` fires only when the block contains a call (`seq_lifetime_only` trial). |
| B6 | `bxor` | `three bxor five` | Not an operator per §3.3.1; parses anyway. |
| B7 | Standalone `if … { } else { }` | `if x > 2 { 1 } else { 0 }` | §3.3.5 says `if` is only a case guard. |
| B8 | Float literal returned from an integer function | `fn main() -> int64 { 2.5 }` | |
| B9 | Integer literal to `print_bool` | `print_bool(5)` | (`print_bool("5")` also accepted in generated programs; a minimal case is rejected.) |
| B10 | `main` returning `string` or a tuple | `fn main() -> string { "hi" }` | Existing trial headers document that this was never a supported shape. |
| B11 | `length_bytes(42)`, `concatenate("a")` | | Built-in argument types/arity not checked. |
| B12 | Literal out of range for its type | `fn main() -> int8 { 200 }`, `x: uint8 <- -1` | |
| B13 | Integer literal message to an `atom`-typed behavior | `call(w, 7 impl ActorMessage {})` with `fn srv(msg: atom, …)` | The reverse direction (atom to `int64`) is diagnosed (E2001). |
| B14 | Message-type mismatch is not the only actor gap | `spawn` with a one-parameter behavior compiles | |

### Inconsistent or misleading diagnostics (not gaps, but worth knowing)

- `E2002` (undefined identifier) is reported as `E2005` (`no field z on this type`) when the
  undefined name is the head of a field access (`missing_rect.top_left.x`), and as `E2010`
  in some binding positions.
- `E2003` "type mismatch: x" names only the identifier; the expected and actual types are
  not reported.
- An unterminated string literal is reported as `E1060 unclosed '{'`.
- A missing `;` between two **bindings** is accepted (`case_brace_let_nosemi` shows this
  is intentional), but between two expression statements it is `E1040`; the E1040 message
  does not say which.
- `E3009` (`proc[...]` on a function return type) makes up 63 % of the pre-existing failure
  corpus (179 of 286 files).

---

## Part C — Facts the generator had to learn (spec vs. behaviour)

Recorded because each one cost a failed batch before it was understood.

- Operator precedence follows §3.9: `+`/`-` bind **tighter** than `band`/`bor`, so
  `(bnot two) band three + lo` is `(bnot two) band (three + lo)`.
- A right operand of *equal* precedence needs parentheses: `84 * (50 * 31 % 7)` must keep
  its parentheses.
- `-` directly followed by a digit is a negative literal; binary minus needs spaces.
- Numeric literals take their type from context; `2.5` is `float16`, `float32` or `float64`
  depending on the consumer. The float printer emits the exact binary expansion
  (`3.14` prints `3.140000000000000`), so goldens should use dyadic values.
- `print_float32` / `print_float64` have no NaN/inf handling (they print saturated
  integers); only `print_float16` prints `nan`/`inf`.
- The exit status of `main -> atom` is the atom's table index; `:ok` is 2, and the first
  user atom is 23 *unless* actor features shift the table (`:no_reply`, `:enqueued`).
- `print_*` never emits a newline; `.scout` files therefore often end with the exit code
  glued to the last printed value.

---

## Suggested order of attack

1. A1 (float parameters) and A4 (tuple after scalar) — both are argument-passing defects
   in the emitter and both silently corrupt results.
2. A5 — the resume path must rebuild provided-method overload tables from `.iface`, or the
   reclaim exit must not be taken inside a directory that has trait modules.
3. A2 (returned closures) and A3 (record actor state).
4. B1–B5 — the argument-count and effect checks that are shape-dependent.

When any item is fixed, turn its reproduction into a trial under the matching
`trials/<area>_addition/` directory (and a failure trial under
`error_enforcement_addition/` for the Part B items) before closing it.
