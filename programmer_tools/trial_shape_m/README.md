# trial_shape_m — every trial in the supervisor-actor shape

Item M of `compiler/design_documents/actor_memory_budget_plan.md` (Lee's design of 2026-10-08):
a trial's `main` starts a supervisor with one worker, casts the trial's work to it as a function
literal, and waits in `wait_for_exit()`, which returns the value the worker sends with
`cast_exit(value: int64)` (spec §15.1.2.5). `main` keeps its name and header; its old body becomes
the literal. Each `.scout` stays as it is.

## Shared trial-support modules

`gen_support.py` writes `trials/lib_trial_support/trial_{support,wait}_<T>.silica` (28
modules; T = int8..int64, uint8..uint64, float16..float64, atom, boolean, string). Each holds its
own `impl ... for Supervisor` (one `:transient` worker, restart limit 0), the worker, and two
exports: `start/0` (spawns the supervisor) and `run/1` (sends the work). Atoms are named only inside
the module (atoms are numbered per unit). A suite compiles the modules its trials `use`, plus
Supervisor, through private links in `<suite>/.trial_stdlib/` (`TRIAL_SUPPORT_CONFIG` in
`trials/silica_compiler.mk`); `TRIAL_SUPPORT_ASSEMBLE` and `TRIAL_SUPPORT_OBJ` assemble and link
them. Error trials compile alone with the module they use (`TRIAL_SUPPORT_IN_TMP`).

## FailureReporter (E2236)

Every `start/0` spawns the reporter and registers it before it starts the supervisor
(`start_reporter`). While a reporter is registered the runtimes cast each unwind report to it
instead of writing it to stderr (`silica_rt_actor_deliver_unwind_report` on every target), so the
reporter writes the report to stderr itself (`println_stderr`); the root supervisor's own report
(null `supervisor_acb`, frame `#0  <unknown behavior>`) ends the program with `cast_exit(70)`. The
reporter's declarations come after the module's older ones and add no atom, so a suite's atom table
is unchanged. The printing is asynchronous: a banner can now appear after output the program printed
later (and the runtime's `[silica] root actor exited (no supervisor)` note, written synchronously,
before the root supervisor's banner), which ordered `.scout` compares can see.

## Forms (`shape.py`)

| form | when | module | main ends with |
|---|---|---|---|
| A | main returns int64 | `trial_support_int64` (worker: `cast_exit(value)`) | `code: int64 <- wait_for_exit()` ... `pure code` |
| B | other type, literal result (`pure :ok`, `true`, `0`) | `trial_support_<T>` (worker: `cast_exit(0)`) | `_: int64 <- wait_for_exit()` ... `pure <literal>` |
| C | other type, computed result | `trial_support_<T>` (worker: `cast_exit(0)`) | `_: int64 <- wait_for_exit()` ... `pure <the value the trial returns today>`, found by `probe.py`. A non-int64 value cannot travel through `cast_exit` and there are no conversions, so the returned value is no longer checked (Lee, 2026-10-08); the `.scout` is unchanged |
| W | main already ended in `_: int64 <- wait_for_exit()` | `trial_wait_<T>` (worker runs it, returns) | `_: int64 <- wait_for_exit()` ... `pure <literal>`; the `.wait_for_exit` marker's `exit` line ends the wait |

Example (A):

```silica
// Order of ops: multiplication before addition (2 + 12 = 14)
use trial_support_int64;

fn main() -> int64 {
    sequence proc[concurrency, device_io]
        _: supervisor_ref <- trial_support_int64@start();
        _: boolean <- trial_support_int64@run(fn() -> int64 {
            2 + 3 * 4
        });
        code: int64 <- wait_for_exit()
    produces
        pure code
    end
}
```

Only insertions are made (one `use` line, a head after main's `{`, spaces at the start of each body
line, a tail before main's `}`; W also drops its `wait_for_exit` statement), so every original
position maps to a new one (`shape.map_position`). Error trials end B/C/W with a placeholder of their
type: an error trial never runs, and its own result may be the error.

## Tools

| script | does |
|---|---|
| `inventory.py [trials] --tsv out` | classifies every `.silica` by role and shape |
| `gen_support.py` | writes the trial-support modules; each one's `start/0` spawns and registers the FailureReporter before it starts the supervisor (spec §15.4.13.4, E2236) |
| `e2236_convert.py scan\|apply [dir]` | E2236 (2026-10-11): finds every trial whose `main` can start an actor or supervisor before `register_failure_reporter` (followed through local and cross-module calls) and inserts `_: atom <- start_reporter();` as main's first statement plus the reporter at the end of the file (written into the trial, not a shared module, so the suite's compile order and atom numbering stay put); skips `e2236_exclusions.txt`. Also used on board apps (`--lib` the emitter tree) and `docs/examples` |
| `convert.py <trials> <suite> [--skip-train]` | rewrites a suite's run trials; lists what it left and why |
| `errcheck.py <error_dir> <compiler> <work> [--train skip\|only\|all] [--install]` | converts single-file error trials, recompiles each alone, installs only those reporting the same code at the mapped position (or, for an error found at main's closing brace, at the literal's) |
| `refresh_ascomp.py <suite_dir> [--ext ...]` | copies `.sams` over `.ascomp` only for trials the integrate log says matched `.scout` |
| `patch_makefile.py <Makefile>...` | adds the support config/assemble/link hooks to a suite Makefile |
| `mirror.sh <work> <suite>...` | scratch copy of the trials scaffolding plus suites |
| `exclusions.txt` | trials left in the old shape (about main itself, item K, defect repros, scheduler order) |
| `mass_suite.sh <suite> [--no-patch] [--no-train] [--no-run]` | one suite end to end on the Mac: patch, probe + convert hand-written trials, train pairs through the generator's shape stage, integrate, refresh .ascomp (env SILICA_COMPILER, MASS_WORK; a claim marker keeps parallel queues apart) |
| `errcheck_dir.py <error_dir> <compiler> [--install]` | the multi-file error trials (one directory each, `make check`) |
| `errcheck_ffi.py <error_ffi_dir> <compiler> [--install]` | error_enforcement_addition/ffi_addition's FAIL_CASES |
| `refresh_via_mirror.sh <suite> [--ext ...]` | .ascomp refresh for a harness that does not run a trial whose assembly differs (ffi apps): run in a mirror, adopt, run again, copy back what matched (`MIRROR_DROP` leaves units out) |
| `revert_failed.py <suite_dir>` | puts back the old shape of converted trials whose run no longer matches, when the file is exactly the conversion of git HEAD |
| `linux_goldens.py <trials> <emit_target>` | on a Linux host after a whole-tree integrate: refresh .<target>.ascomp where the run matched, and .<target>.golden_fail that report the macOS golden's code and position |
| `probe.py <mirror/trials> <suite> <compiler> out.json` | builds a probe copy of a suite in a mirror; for each form-C trial records the value main returns and whether the run matches `.scout` |

## Per suite

```sh
C=compiler/build/apple_silicon_mac/silica-compiler
python3 patch_makefile.py ../../trials/<suite>/Makefile
bash mirror.sh $W <suite> && python3 probe.py $W/trials <suite> $C $W/probe.json
python3 convert.py ../../trials <suite> --probe $W/probe.json
(cd ../../trials/<suite> && make integrate TRIAL_TARGET=host SILICA_COMPILER=$C)
python3 refresh_ascomp.py ../../trials/<suite>   # then integrate again
```

## Train pairs

The 10,519 `train_*` pairs go through the generator: `programmer_tools/train_trial_generator/shape_stage.py`
(`--installed OUT [area,...]` reshapes the installed pairs, verifies them with the compiler of the day and
writes OUT for `install.py`; `pipeline.py` applies the same stage to newly generated pairs unless
`M_SHAPE=0`). A failure twin gets the success twin's form, type and literal.
