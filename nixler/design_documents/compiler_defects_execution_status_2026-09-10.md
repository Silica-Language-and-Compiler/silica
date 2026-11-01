# Execution status: HIGH_PRIORITY compiler defects (2026-09-10, scratch copies)

**Implementation status (2026-10-16):** the scratch work below was accepted into the repository. All Part A items except A2 3b and all Part B items are fixed and pinned by installed `train_defect_*` trials; A3, A9 and A10, listed as open below, are fixed and pass (`actors_addition/train_defect_a3_*`, `_a9_*`, `_a10_*`: `.sout` equals `.scout`). Still open: A2 3b (closure environments; E1067 rejects the returned capturing literal) and the four misleading-diagnostic wordings. The scratch paths, the seed/selfhost patch pair and the "still open" list in this file are the 2026-09-10 record; the seed source tree it mentions no longer exists (the compiler is `compiler/src`, built by the Silica-built seed in `binaries/seed-compiler`).

All work is in scratch copies; the repository is untouched.

| Tree | Path |
|---|---|
| compiler sources (seed `src/` and `src/`, both patched) | `/Volumes/2T/silica_compiler_scratch/compiler/` |
| trials (106 new `train_defect_*` files, hand-derived goldens) | `/Volumes/2T/silica_trials_scratch/trials/` |
| plan | `design_documents/compiler_defects_resolution_plan.md` (this directory) |

## Phase 0 — validation trials (done)

Trials were added to the real suite directories of the scratch trials tree and run red on
both current compilers (silica-999997 and the 999996 seed) before any fix.

Reproduced (open at the start): A1, A2, A3, A4 (tuple), A5, A7, A8, A9, B7, B8, B10, B11
(concatenate), B12, B13.

Not reproduced with the documented shapes, converted to regression trials: A6, A10, the
record-after-scalar A4 sibling, B1, B2, B3, B4, B5, B6, B9, B11 (length_bytes), B14.

## Fixed (scratch seed, validated by the trial runner; ported to src)

| Item | Cause found | Change |
|---|---|---|
| A1 | `build_param_outer_reg_loop` and its int64-ABI twin sliced `param_types` at the pipe index found in `param_names`, so the second float's register was computed from a truncated ("loat64\|float64") type list; separately, numeric literal call arguments were lowered with the inferred float32 type instead of the callee's formal | keep the full type list through the loop recursion (`emitter_core.silica`); literal arguments take the formal type (`expected_or_inferred_call_arg_type`, new `build_rest_chain_with_formals`, the three 2-argument sites in the SIR generator) |
| A4 | a tuple/record parameter after a scalar is destructured through X0 while the scalar still lives there | such parameters at index >= 1 count as GPR64 for the entry shadow (`counts_as_gpr64_param_at`), so the scalar is moved to X19 first |
| A7 | the var/prim operand branches staged the left operand through X0/W0 (the first parameter's register); `%` and unsigned `%` used W0 as the quotient scratch | left staged in `left_reg`; quotient scratch X16 |
| A8 | bound-name branch: a float prim on the left with a compound right was emitted right-then-left with no spill | right first, `STR right_reg` across the left, restore before the op |
| A5 | iface stub programs carry the provided-method template and the impls but not the per-receiver specializations, so the overload count is 1 on resume and the bare symbol is emitted | `specialize_iface_stub_world` runs `trait_specialization@specialize_program` over stub programs before mangling |
| A2 (interim) | no closure environment exists; a returned capturing lambda loses its captures | new parse-stage check E1067 rejects returning a lifted lambda whose parameter count exceeds the declared fn type's arity |
| B7 | standalone `if` parsed as an expression | kind-994 marker + E1066 |
| B8, B12 | numeric literals accepted for any numeric type | integer expectations reject float text (E2001) and out-of-range values (E2011) |
| B10 | no check on `main`'s signature | E2019 unless the return type is int64 or atom |
| B11 | `concatenate("a")` checked a dummy second argument | E2005 unless exactly two arguments |
| B13 | `type_id_accepts_numeric_literal` accepted numeric literals for atom | atom clause removed |

Trial runner result with the final scratch seed: every Part A trial except A2 (3b), A3 and
A9 passes; every originally-open Part B trial passes.

## Still open

- **A2 3b** closure environments: design decision (fn value = code pointer + environment).
- **A3** record-typed actor state through call/reply: the behaviour's assembly is now
  structurally identical to the working int-state shape (X2 reply buffer, balanced frame),
  yet the actor thread faults at a tiny PC (2 or 5) or returns 0; five reply-shape probes
  narrow it to the runtime's reply protocol when the state slot is a pointer. Not fixed.
- **A9** record message with List state: wrong values (1, 4 instead of 0, 2). Not fixed.
- The four misleading-diagnostic message cleanups (planned last; they move goldens).

## Facts learned during execution

- The seed (`src`) lags `src` in diagnostic wording and positions and computes the
  `offset:` field differently, so error_enforcement goldens recorded from the selfhost-built
  compiler cannot be validated with a seed build (111 offset-only differences in the full run).
- `make -n` executes any recipe line containing `$(MAKE)`; the trial makefiles were changed
  earlier today so the wrapper only forwards a dry run.
- The bootstrap cannot emit a `bool` inside a returned tuple; a tuple parameter carrying an
  `Expr` record corrupted the record (an A4-family shape). Compiler code must avoid both.
- A6's six candidates compile in 284 MB; the signal-9 report did not reproduce.

## Validation status

- Full scratch trials tree under the seed with A1/A4/A7/A8 (52 min, `make integrate JOBS=6`):
  26893 pass, 5819 fail, of which 5643 are `.ascomp` drift (expected: operand staging
  changed), 111 are error_enforcement `offset:`/wording differences between the seed and the
  selfhost-built compiler that recorded the goldens, 35 are new trials without `.ascomp` yet,
  and the rest are the open items (A2, A3, A9) plus six trials (three tuples decomposes, three
  supervisors protocol trials) that fail identically under the unmodified stock seed, i.e.
  pre-existing seed differences. No behavioural regression attributable to the changes.
- Selfhost build with the patched seed (31 min, 334 units, no errors) produced a compiler that
  passes every Part A trial except the open A2 (rejected by E1067 by design), A3 and A9, and
  every originally-open Part B trial. The first build exposed that B10 was too strict: existing
  suites give `main` int8..uint64 and float returns, so B10 now accepts every scalar numeric
  type and atom and rejects string/tuple/record/list/fn; second build in progress.
- The six regression trials whose goldens came from the older 999997 build were re-recorded
  from this build (the current selfhost source words those diagnostics like the seed does).

## Final validation (selfhost-built compiler, 2026-09-10 18:22)

Built from the patched `src` with the patched seed (two of the builds were killed by
the OS while another session's compiler build ran; the resumed build completed clean).

| Check | Result |
|---|---|
| defect trials, single-file runner | 41 pass / 4 fail: A3, A9 (open), the two A2 pins (rejected by E1067 by design) |
| traits_addition over the 32-unit threshold (A5 resume path) | 40 pass / 0 fail |
| deep_frame_spill_addition (A6 candidates) | 14 pass / 0 fail |
| actor_registration_addition | 6 pass / 0 fail |

`.ascomp` goldens were recorded from this binary for every new passing trial (29 single-file
trials, the two traits roots, and `traits/Countable`).

## Deliverables

- `compiler_defects_fixes_src.patch` (11 files) and `compiler_defects_fixes_selfhost.patch`
  (12 files) at `/Volumes/2T/silica_compiler_scratch/`: the seed and selfhost source changes.
- The new trials and goldens under `/Volumes/2T/silica_trials_scratch/trials/` (`train_defect_*`
  plus `traits/Countable.*`); the tree-wide `.ascomp` drift for existing trials still needs a
  deliberate regeneration once the fixes are accepted.
