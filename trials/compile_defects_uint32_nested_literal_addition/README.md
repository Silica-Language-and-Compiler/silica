# compile_defects_uint32_nested_literal_addition (INTEGRATE_PENDING)

One valid Silica program that today's compilers reject, staged for a defect found while writing the
NUCLEO-L476RG pin app (2026-11-10); see `../compile_defects_addition/README.md` for why a compile-time
defect gets a directory of its own.

- `uint32_nested_literal`: an integer literal nested inside an expression whose other operand is a uint32
  is rejected with E2003 ("type mismatch: n"). Failing forms, each checked on the Mac host compiler
  (`binaries/silica-compiler`): `n % 2 == 1` and `n - 1 == 1` as a case scrutinee (and as a function body),
  `n + 1 > 3`, and a message built from a uint32 parameter, `cast(me, (msg + 1) impl ActorMessage {})`.
  Compiling fine today: `n % 2` alone, `x == 1`, `g(n + 1)`, and the same shapes on int64. Related, not
  fixed by this trial's text but found beside it: `case n + 1 of { 8 -> ... }` gives E2005 "cannot infer
  type of case scrutinee", and `{ step: msg.step + 1, ... } impl ActorMessage {}` gives E2005 "cannot infer
  field expression type in struct literal".

| today (Mac host, 2026-11-10) | `.scout` (correct behaviour) |
|---|---|
| E2003 at line 11 column 10 (`n % 2 == 1`), the first rejected form; the rest follow once it is fixed | `odd=1 even=0 minus=1 other=0`, `msg=7`, `msg=8`, `0` |

The `.scout` was checked by running the same program with int64 in place of uint32 (it compiles today and
prints exactly that). No `.ascomp` yet: generate the goldens only after the fix, from correct output.

`INTEGRATE_PENDING` keeps this directory out of tree-wide runs on the host and on the board; the
STM32-L476RG_raw skip file also lists it. Run it by hand from `trials/`:

```
make -C compile_defects_uint32_nested_literal_addition integrate TRIAL_TARGET=host SILICA_COMPILER=/Volumes/2T/silica/binaries/silica-compiler
```

When it passes, move `uint32_nested_literal` into `uint32_addition` with `.ascomp` goldens and delete this directory.
