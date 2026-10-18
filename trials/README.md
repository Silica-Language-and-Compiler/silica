# Silica trials

Every subdirectory here is a trial suite with its own `Makefile`. `integrate` is the
only target that proves anything: it compiles each trial, diffs the emitted assembly
against its `.ascomp` golden, links and runs the program, and diffs its output
against its `.scout` golden (error and warning suites diff compiler output against
`.golden_fail` / `.golden_warn` instead). A bare `make` in a suite only compiles.

## Running the trials

```
make integrate                      # every suite, in parallel, one job per core
make integrate JOBS=4               # cap the parallel pool
make integrate SDS_JOBS=2           # cap ordered_data_structures separately (default 4)
make -C tuples_addition integrate   # one suite, with its own report
make -C ordered_data_structures/wbt_core integrate   # one leaf of a nested suite
make integrate-ffi                  # the ffi_addition success-path apps only
make clean                          # every suite's clean, plus the integrate logs
```

`make integrate` at this level runs all suites concurrently under one make jobserver.
The suites are started longest-first (ordered_data_structures and
error_enforcement_addition lead). ordered_data_structures runs in its own, smaller
pool because its stdlib batch compile peaks at about 7 GB of memory; `SDS_JOBS`
bounds how many of its leaves and units run at once. `JOBS` and `SDS_JOBS` can also
be set in the environment. A suite run on its own (`make -C <suite> integrate`) uses
the same parallelism inside itself; pass `-j1` to force it serial.

`make -n integrate` is a safe dry run: it prints the commands and writes nothing.

Start a full run from a terminal. On a 10-core machine the whole tree takes about an
hour at `JOBS=6`; the wall clock is set by the largest single suites (case_addition,
functions_addition, tuples_addition), which still run their trials one after another.

## What to expect on the screen

While the trials run, the terminal shows one line with two live counters, redrawn once
a second: the passes so far and the failures so far. Nothing else is printed until the
run ends, so parallel suites never interleave. Nothing is drawn when the output is not a
terminal. The run ends with the final counters, a newline, and the report for the
directory you ran:

```
✅✅ 1246     ❌❌ 0
════ integrate report: tuples_addition ════
success: ✅✅ 1246
fail: ❌❌ 0
elapsed: 6m 12s
log: /Volumes/2T/silica/trials/tuples_addition/.integrate_log
```

When something failed, the report adds a `failures:` section listing every failure
line with the diff that followed it (capped at `INTEGRATE_DETAIL_LINES` lines each,
default 40; the full diff stays in the log). Each failure line names the trial and
the kind of difference (`.sams differs from .ascomp`, `.sout differs from .scout`,
`.cur_fail differs from .golden_fail`, `compilation failed`, `link failed`, `has no
.scout file`, and so on).

A tree-wide run (`make integrate` here) counts every check in every suite on the same
two counters, then prints the tree-wide report; nested suites write their own reports
to their `.integrate_report` files without printing them, and their failures are
replayed in the tree-wide `failures:` section:

```
✅✅ 33618    ❌❌ 0
════ integrate report: trials ════
success: ✅✅ 33618
fail: ❌❌ 0
elapsed: 58m 00s
failures:            (only when something failed; every failure, with its diff)
log: /Volumes/2T/silica/trials/.integrate_log
```

The exit status is 0 only when every check passed. Suites with an `INTEGRATE_PENDING`
file are skipped and not counted. The per-directory table for a tree-wide run is in
the log.

### Running the trials on a board

`make integrate` can also run the trials on an ESP32-S3 board over USB: an interactive run asks
where to run (Enter = this Mac), and `TRIAL_TARGET=host|ESP32-S3_raw|both` answers in advance.

```
make integrate TRIAL_TARGET=ESP32-S3_raw                       # the whole tree on the board
make -C case_addition integrate TRIAL_TARGET=ESP32-S3_raw      # one suite on the board
make integrate TRIAL_TARGET=both                               # this Mac, then the board
```

Only one trial run of any target can be in progress; a second one stops at once and names the
run that holds `trials/.integrate.lock`. A board run compiles with
`binaries/silica-compiler-ESP32-S3_raw`, runs each program from the board's RAM, compares its output
with the same `.scout` goldens, and writes its report to `.integrate_report.ESP32-S3_raw` without
touching the host's files. Details, the skip list and the settings are in
[targets/README.md](targets/README.md); the software it needs is listed in
[docs/required-software.md](../docs/required-software.md).

### Hung trials

Trial programs have no run time limit of their own. Instead the outermost `integrate`
runs a watchdog: when no check has finished for `INTEGRATE_WATCHDOG_MINUTES` (default
15) it kills every trial program that is running at that moment, each one is counted
as a failure, and the run continues. The log and the final `failures:`
section list each one as

```
❌❌ <suite>/<trial> killed by the watchdog after 15 minutes of silence; trial incomplete
```

`make integrate INTEGRATE_WATCHDOG_MINUTES=2` shortens the limit. Compiles keep their
own limit (`SILICA_COMPILE_TIMEOUT`, 300 s).

## Files left behind

Each directory that ran `integrate` keeps a few bookkeeping files (all ignored by the
trials themselves and removed by `make clean`):

| file | contents |
|---|---|
| `.integrate_log` | everything that directory's run printed, diffs included |
| `.integrate_report` | the report block shown above |
| `.integrate_counts` | `<passed> <failed>`, summed by the parent |
| `.integrate_status` | exit status of the run |
| `.integrate_results` | one line per check, in suites that run trials as make rules |
| `.integrate_pass_marks`, `.integrate_fail_marks` | one byte appended per check; their sizes drive the live counters and their timestamps the watchdog (outermost directory only) |
| `.integrate_running/` | one file per trial program currently running, for the watchdog (outermost directory only) |
| `.integrate.lock/` | held by the trial run in progress, of any target (trials root only) |
| `<trial>.<target>.sout`, `.cur_fail`, `.integrate_report.<target>` | a board run's outputs (see [targets/README.md](targets/README.md)); board work files are under `.target/` |

ordered_data_structures leaves compile each unit in a private `.sandbox/<unit>/`
directory (removed when the unit finishes) and keep a content-addressed compile cache
in `.trial_cache/`; `TRIAL_CACHE=0` forces a full recompile.

## How the makefiles fit together

`silica_compiler.mk` is included by every suite. It provides the seed-compiler
location, the compile loop, and the shared `integrate` wrapper. A suite's own
recipe is named `integrate-run`; the wrapper runs it, captures its output to
`.integrate_log`, and prints the report. To add a suite, write its `integrate-run`
so that each check prints one `✅✅ <suite>/<trial> ...` or `❌❌ <suite>/<trial> ...`
line followed by `$(INTEGRATE_DOT_OK)` or `$(INTEGRATE_DOT_FAIL)`, which append the
check to the live counters (diff after the ❌❌ line), runs every trial program through `$(call INTEGRATE_RUN_TRIAL,<label>,<sout>,<cmd>)`
or `$(call INTEGRATE_EXEC_TRIAL,<label>,<cmd>)` so the watchdog can kill it (then
check `$$integrate_killed`), and finishes by writing `.integrate_counts`; the wrapper
and the parent do the rest.

Because everything runs under `-j`, a rule must never list `clean` and
`silica.config` as sibling prerequisites; the suites declare
`silica.config: | clean` so the config is written after the clean.

Parents fan out with `$(call INTEGRATE_CHILD,<subdir>)` and sum with
`$(call INTEGRATE_SUM_CHILDREN,<subdirs>)`; see `Makefile`,
`ordered_data_structures/Makefile`, `error_enforcement_addition/Makefile`, and
`ffi_addition/Makefile` for the pattern.

### Standard input and `<trial>.no_stdin_exit`

`actor_registration_addition` and the three `cast_*registered_unheld_name*` suites pipe
an `exit` line into every trial that does not `use trial_support_*`; that line is
recorded as `cast_exit(0)` (spec §15.1.2.5) and ends `main`'s `wait_for_exit()` at once.
A trial whose `main` must instead wait for one of its own actors (usually the failure
reporter) to call `cast_exit` gets an empty marker file `<trial>.no_stdin_exit`; the
recipe then gives it an empty standard input, whose end does not end the wait. This is
unrelated to `<trial>.wait_for_exit`, which names the output marker a trial prints
before the harness sends `exit`.
