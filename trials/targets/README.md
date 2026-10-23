# Trial targets: running the trials on a board

`make integrate` can run the trials in two places:

| Target | Compiler | Where the programs run |
| ------ | -------- | ---------------------- |
| `host` | `binaries/silica-compiler` | this Mac (what `make integrate` always did) |
| `ESP32-S3_raw` | `binaries/silica-compiler-ESP32-S3_raw` | an ESP32-S3 board on USB, bare metal |

A board target is defined by `<target>.conf` in this directory. The software each target needs is
listed in [docs/required-software.md](../../docs/required-software.md).

## Choosing the target

```
make integrate                                   # interactive: asks; Enter = host
make integrate TRIAL_TARGET=host                 # this Mac, no question
make integrate TRIAL_TARGET=ESP32-S3_raw         # the board
make integrate TRIAL_TARGET=both                 # host, then the board, one after the other
make -C case_addition integrate TRIAL_TARGET=ESP32-S3_raw     # one suite on the board
make integrate TRIAL_TARGET=ESP32-S3_raw TRIAL_SUITES="base list_addition"   # some suites
```

An interactive `make integrate` (in `trials/` or in a suite) asks first:

```
Select the trial target (make integrate):
  1) host  [default]   this Mac, binaries/silica-compiler
  2) ESP32-S3_raw   ESP32-S3 board over USB (bare metal), binaries/silica-compiler-ESP32-S3_raw
  3) both   host, then ESP32-S3_raw (one after the other)
Number or name [host]:
```

It never asks, and runs on the host, when there is no terminal (CI, `nohup`, pipes), with
`SILICA_TARGET_PROMPT=0`, or when `SILICA_COMPILER=` is given on the command line (so
`make trials-gen1` / `trials-gen2` behave as before).

## One run at a time

Only one trial run, of any target, can be in progress. The first `make integrate` takes
`trials/.integrate.lock`; a second one, host or board, stops at once and names the run that holds
it:

```
❌❌ another trial run is in progress: trials (target ESP32-S3_raw, started 2026-09-13 04:14:15, pid 52309).
```

The lock is released when the run ends, including after Ctrl-C. A lock whose process no longer
exists is taken over by the next run. `bash trials/targets/trial_target.sh status` shows the holder.

## What a board run does

Before compiling anything it checks that the board compiler exists, that the board tools are
installed, and that a board answers on USB: the ESP32-S3 on the single USB serial port, or the one
`BOARD_PORT` names (an interactive run asks when there are several), and, when `BOARD_MAC` is set,
that the board has that MAC. Any failure stops the run with one line saying what is missing.

Then, for each suite, [board_suite.sh](board_suite.sh):

1. compiles the suite's sources with the board compiler, all in one run as the host suites do,
   in a work area under `trials/.target/<target>/<suite>/`;
2. for each program trial, builds an image with the board runtime (`board/tools/build_image.sh`),
   loads it into the board's RAM and runs it (`board/tools/run_on_board.py`; nothing is written
   to flash), and compares its output and exit status with the trial's `.scout`, as the host does
   (`diff -Bw`; through the suite's `compare_scout_multiset.sh` for a trial marked
   `<stem>.scout.multiset`, whose actor failure reports are compared as a set with their pointers
   folded (in supervisors_addition, record_shapes_actors_addition and device_actor_addition that
   script is `../compare_scout_unordered.sh`: the FailureReporter prints reports asynchronously, so
   report blocks and the other lines are both compared as multisets, the exit status last and
   exact; the marker is honoured for a `<stem>.<target>.scout` golden too); through the suite's `compare_scout_normalized.sh` when it has one: that folds the
   addresses in a process-fatal report line, `[silica] fault at <PTR>` / `[silica] abort: <reason> at
   <PTR>`, which differ between the board and the host; see
   [runtime_failure_reporting.md](../../compiler/design_documents/runtime_failure_reporting.md)).
   A standard-library module the suite's Makefile adds to its `silica.config`
   (`echo "../../compiler/stdlib/<Module>.silica"`, as `supervisors_addition` does for
   `Supervisor`) is compiled with the programs too;
3. compiles each compile-failure trial (`.golden_fail`) alone and compares the diagnostics.

Suites run in parallel, so compiles overlap; the board runs one trial at a time. A board trial takes
about 1 to 3 seconds on the board. Most trials compile in a fraction of a second; a few very large
programs (deep_frame_spill_addition) take about 10 seconds each. A whole-tree board run takes hours;
the Mac is kept awake while it runs (`caffeinate`).

If the board stops answering during a run, the remaining trials are reported as not run (one line
per suite) instead of as thousands of failures.

### What it compares, and what it leaves alone

- Program output: the board's output and exit status are compared with the same `.scout` as the
  host. The assembly is not compared on the board target (there are no Xtensa `.ascomp` goldens).
- A real, reviewed difference between the host and the board can be recorded as
  `<trial>.<target>.scout` (or `.golden_fail`) next to the trial; it is used instead of the shared
  golden. Such files are written by hand, never generated.
- A `<trial>.max_rss_mb` peak-memory ceiling (see [../README.md](../README.md), "Peak memory
  ceiling") is host only and is ignored here: the board run compares output only, so a trial
  whose leak shows only in host RSS passes on the board when its output matches.
- The board's own outputs are written next to each trial as `<trial>.<target>.sout` and
  `<trial>.<target>.cur_fail`. Nothing the host run writes is touched: the host's `.sams`, `.sout`,
  logs and reports stay as they were.
- The report is `trials/.integrate_report.<target>` (a suite run also leaves a copy in the suite);
  the full log is `trials/.target/<target>/.integrate_log`.

### What it does not run

[`<target>.skip`](ESP32-S3_raw.skip) lists the suites and single trials a target skips, each with a
reason (`target:` the board cannot run it; `driver:` the board driver does not handle that suite's
layout yet). Subdirectories with their own Makefile (the multi-file trials under
error_enforcement_addition) are skipped automatically. Skips are reported, never counted as passes.

## Settings

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `TRIAL_TARGET` | ask, or `host` | `host`, a board target, or `both` |
| `TRIAL_SUITES` | every suite | limit a tree run (host or board) to these suites, e.g. `make integrate TRIAL_TARGET=host TRIAL_SUITES="actors_addition base"`; a name that is not a suite is an error, and a named suite runs even if it has `INTEGRATE_PENDING` (whole-tree runs skip those). On the host the report and failure list cover only the named suites |
| `BOARD_PORT` | the single USB serial port | the board's serial port |
| `BOARD_MAC` | (none) | refuse any board with another MAC |
| `BOARD_SILICA_COMPILER` | `binaries/silica-compiler-<target>` | the board compiler |
| `BOARD_PYTHON` | from `<target>.conf` | Python with esptool and pyserial |
| `BOARD_TRIAL_TIMEOUT` | 300 | seconds a program may run on the board before it counts as hung |
| `BOARD_FAIL_JOBS` | 4 | compile-failure trials compiled at once |

## Files

| File | Role |
| ---- | ---- |
| [trial_target.sh](trial_target.sh) | the lock, the menu, the preflight checks, and the board run |
| [board_root.mk](board_root.mk), [board_suite.mk](board_suite.mk) | the board run's top level and one suite, on top of the shared integrate wrapper (`../silica_compiler.mk`): same progress line, watchdog, logs and report as a host run |
| [board_suite.sh](board_suite.sh) | one suite on the board |
| `<target>.conf`, `<target>.skip` | a board target and what it skips |
