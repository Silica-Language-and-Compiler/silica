# Trial targets: where `make integrate` runs the trials

`make integrate` can run the trials in several places, and in several places at once:

| Target | Compiler | Where the programs run |
| ------ | -------- | ---------------------- |
| `host` | `binaries/silica-compiler` | this machine (the Mac: key `macos_applesilicon`; a Linux machine: its own `linux_*` key) |
| `linux_aarch64` | the compiler built on that machine (`~/silica/binaries/silica-compiler` there) | the Raspberry Pi ("pix"), reached over ssh: remote hosted |
| `linux_x86_64` | the compiler built on that machine | the x86-64 Linux machine ("nix"), reached over ssh: remote hosted |
| `ESP32-S3_raw` | `binaries/silica-compiler-ESP32-S3_raw` | an ESP32-S3 board on USB, bare metal |
| `STM32-L476RG_raw` | `binaries/silica-compiler-STM32-L476RG_raw` | an ST NUCLEO-L476RG over its ST-LINK, bare metal (see below) |

A board target is defined by `<target>.conf` in this directory. The software each target needs is
listed in [docs/required-software.md](../../docs/required-software.md). A remote hosted target is a
line of `.silica_build_hosts` in the repository root (`<target> <user@host|local> <path>`, gitignored,
mode 600, never committed or printed); `programmer_tools/build_all_platforms.sh` writes it.

## Choosing the target

```
make integrate                                   # interactive: asks; Enter = host
make integrate TRIAL_TARGET=host                 # this machine, no question
make integrate TRIAL_TARGET=linux_x86_64         # the nix machine: sync, then its own run there
make integrate TRIAL_TARGET=ESP32-S3_raw         # the board
make integrate TRIAL_TARGET=all                  # host + both remotes + both boards, all at the same time
make integrate TRIAL_TARGET=both                 # host + the boards (the old spelling, now in parallel)
make integrate TRIAL_TARGET="ESP32-S3_raw STM32-L476RG_raw linux_x86_64"    # a list (spaces or commas), in parallel
make -C case_addition integrate TRIAL_TARGET=ESP32-S3_raw     # one suite on the board
make integrate TRIAL_TARGET=ESP32-S3_raw TRIAL_SUITES="base list_addition"   # some suites
make integrate TRIAL_TARGET=linux_aarch64 TRIAL_SUITES="base"                # some suites, on the Pi
```

An interactive `make integrate` (in `trials/` or in a suite) asks first:

```
Select the trial target (make integrate):
  1) host   this Mac (Apple Silicon), binaries/silica-compiler  [default]
  2) linux_aarch64   Linux AArch64 (pix), remote hosted: sync, then its own binaries/silica-compiler
  3) linux_x86_64   Linux x86-64 (nix), remote hosted: sync, then its own binaries/silica-compiler
  4) ESP32-S3_raw   ESP32-S3 board over USB (bare metal), binaries/silica-compiler-ESP32-S3_raw
  5) STM32-L476RG_raw   ST NUCLEO-L476RG over ST-LINK (bare metal), binaries/silica-compiler-STM32-L476RG_raw
  6) all   every target above, at the same time (the host run, the remote runs and the boards)
Number(s) or name(s) [host]:
```

Several numbers or names may be typed. It never asks, and runs on the host, when there is no terminal
(CI, `nohup`, pipes), with `SILICA_TARGET_PROMPT=0`, or when `SILICA_COMPILER=` is given on the command
line (so `make trials-gen1` / `trials-gen2` behave as before).

### Several targets at once

`all`, `both` and a list run every selected target at the same time, each with its own lock, log and
report. Output of the runs goes to `trials/.target/<target>/.all.log` (the host's, to
`.target/macos_applesilicon/.all.log`) instead of the terminal, and a combined summary ends the run:

```
TARGET               STATUS   PASSED    FAILED    REPORT / REASON
host                 PASS     1234      0         /Volumes/.../trials/.integrate_report.macos_applesilicon
ESP32-S3_raw         FAIL     900       3         .../trials/.integrate_report.ESP32-S3_raw
linux_aarch64        SKIPPED  -         -         ssh key authentication to the linux_aarch64 machine failed ...
```

(one row per target: PASS, FAIL or SKIPPED, the counts from its report, and the report path or the
reason). The exit status is non-zero when any target failed. A target whose prerequisite is missing is
SKIPPED with the reason and does not stop the others: no board attached or the board tools missing, the
board compiler not built, the ssh key rejected (`ssh -o BatchMode=yes`, never a password prompt), a remote
not listed in `.silica_build_hosts`, or another run of that same target in progress. A skip is not a failure.
A single target that cannot run stops with the same message and a non-zero status.

**Memory.** The host run peaks at 6-8 GB of RAM (the compiler units). Two host-compiler runs at once on
one machine would need 12-16 GB, so a host run is never started twice (the lock refuses it); in `all`
only one Mac host run exists, and the remote runs use the remote machines' memory.

## One run per target

Each target has its own lock, the directory `trials/.integrate.lock.<target>`, where `<target>` is the
board target, the remote target, or for the host run the machine's own key (`macos_applesilicon`,
`linux_aarch64`, `linux_x86_64`). The Mac host run, ESP32, Nucleo and the two remote runs can therefore all
run at the same time. A second run of the SAME target, from any terminal, stops at once and names the
holder:

```
❌❌ another trial run of target ESP32-S3_raw is in progress: trials (started 2026-09-13 04:14:15, pid 52309).
```

A lock is released when the run ends, including after Ctrl-C; one whose process no longer exists is
taken over by the next run (an old single `trials/.integrate.lock/` directory from before this scheme is
ignored and can be deleted). A multi-target run takes every selected lock with its own pid and the runs
it starts share them (`SILICA_INTEGRATE_LOCK_PID`). `bash trials/targets/trial_target.sh status` lists the
holders. `run_one_trial.sh` takes its target's lock too, so a one-trial board check can run beside the
other target's integrate run.

## Remote hosted targets

`TRIAL_TARGET=linux_aarch64` (or `linux_x86_64`) does, from the Mac:

1. `ssh -o BatchMode=yes ... true` to the machine; when key authentication fails the run stops (or the
   target is skipped in a multi-target run) with a message, never a hang or a password prompt.
2. Syncs this tree with `programmer_tools/sync_to_hosts.sh --apply --targets <target>` (pulls that
   platform's goldens back, deletes what this tree no longer has, pushes; built artifacts and
   `binaries/` are never touched). `TRIAL_REMOTE_SYNC=0` skips this step.
3. Runs `cd ~/silica/trials && make integrate TRIAL_TARGET=host JOBS=... SDS_JOBS=...` on the machine (with
   `TRIAL_SUITES` when given): the machine's own host run with its own compiler and its own lock there.
   `JOBS` defaults match `programmer_tools/run_trials_all_platforms.sh` (Pi 2/1, nix 3/1; `PI_JOBS`,
   `PI_SDS_JOBS`, `NIX_JOBS`, `NIX_SDS_JOBS` override).
4. Streams the remote output (and keeps it in `trials/.target/<target>/.integrate_log`) and copies the
   remote's `.integrate_report.<target>` to `trials/.integrate_report.<target>` here.

`SILICA_REMOTE_DRY_RUN=1` checks ssh, runs the sync as a dry run (nothing changes anywhere) and prints
the remote command instead of running it. If the Mac run is stopped, a remote run that already started
keeps going on its machine (its own lock there refuses a second one).

## What every run writes

A run's files carry its target's name so no run can overwrite another's:

| File | Written by |
| ---- | ---------- |
| `<trial>.<target>.sout` next to each trial | the host run (`<target>` = `macos_applesilicon`, `linux_aarch64` or `linux_x86_64`, the machine's own) and each board run |
| `.integrate_report.<target>`, `.integrate_log.<target>` in the directory run (the trials root for a whole-tree run; a suite directory also gets its own) | every run; for a remote target the report is the remote's own |
| `trials/.target/<target>/` | a board run's work area, a remote run's log and sync lists, a multi-target run's `.all.log` |

The goldens keep their names (`<trial>.scout`, the unsuffixed `.ascomp` for Apple Silicon,
`<trial>.<platform>.ascomp`). The plain `.integrate_report` / `.integrate_log` / `.integrate_*` files of a
host run are that run's internal bookkeeping (the suites read each other's); the `.<target>` copies are
the ones to read and the ones nothing else writes. Old `<trial>.sout` files from before this scheme are
ignored (gitignored); delete them with `find trials -name '*.sout' -not -name '*.*.sout' -delete`.

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
  `<trial>.<target>.cur_fail`. Nothing the host run writes is touched: the host's `.sams`,
  `<trial>.macos_applesilicon.sout` (its own key), logs and reports stay as they were.
- The report is `trials/.integrate_report.<target>` (a suite run also leaves a copy in the suite);
  the full log is `trials/.target/<target>/.integrate_log`.

### What it does not run

[`<target>.skip`](ESP32-S3_raw.skip) lists the suites and single trials a target skips, each with a
reason (`target:` the board cannot run it; `driver:` the board driver does not handle that suite's
layout yet). Subdirectories with their own Makefile (the multi-file trials under
error_enforcement_addition) are skipped automatically. Skips are reported, never counted as passes.

## Target STM32-L476RG_raw (ST NUCLEO-L476RG)

```
make integrate TRIAL_TARGET=STM32-L476RG_raw TRIAL_SUITES=base      # stage 1: base only
bash trials/targets/run_one_trial.sh STM32-L476RG_raw base test     # one trial, same code path
```

- Prerequisites: Homebrew `openocd`, `stlink` (`st-info`) and `arm-none-eabi-gcc` (which brings
  `arm-none-eabi-nm`), plus a Python with pyserial (the ESP-IDF environment, as for the ESP32).
  The preflight checks them, then `st-info --probe` must show exactly one ST-LINK (serial
  `066CFF343654393143174720`, or `BOARD_ST_SERIAL`); the probe line is `port chip serial`.
- Port: `BOARD_PORT`, else `/dev/cu.usbmodem21103` when it exists, else the single `/dev/cu.usbmodem*`.
  `/dev/cu.usbserial*` (the ESP32 board) is never a candidate, and `run_on_board.py` refuses it even
  when named, so a stale `BOARD_PORT` meant for the ESP32 stops the run instead of reaching that board.
- RAM only: `board/tools/run_on_board.py` opens the console, then runs OpenOCD (`reset halt`,
  `load_image <elf>`, the wall clock `mww`, `resume <_start>`, `shutdown`). Nothing is written to flash.
  Images are `.elf` (`TARGET_IMAGE_EXT=elf` in the conf; the ESP32 uses `.bin`).
- Assembly goldens are `<trial>.st_nucleo.ascomp` (the `TARGET_ASCOMP_PLATFORM` of the conf, and the
  `silica_golden_name_for_target` row of `project_makefiles/platform/platforms.mk`, which
  `trials/silica_compiler.mk` uses for `ASCOMP_EXT`). They do not exist until `gen_board_ascomp.sh
  STM32-L476RG_raw` writes them after a green run; before that every trial also reports
  "has no .st_nucleo.ascomp file". `BOARD_ASCOMP=off` (or `run_one_trial.sh --no-ascomp`) compares output only.
- [STM32-L476RG_raw.skip](STM32-L476RG_raw.skip) skips every suite but `base` for now (the runtime has no
  message copier, call, failure reports yet); delete a suite's line to widen the run.

`run_one_trial.sh <target> <suite> <stem>` runs one program or compile-failure trial through
`board_suite.sh` (`BOARD_ONLY_STEM`), prints the diff on a mismatch, keeps its work area (`--work <dir>`
or a new directory under `$TMPDIR`) and works for both board targets. It refuses to start while a
`make integrate` run of the same target holds that target's lock.

## Settings

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `TRIAL_TARGET` | ask, or `host` | `host`, `linux_aarch64`, `linux_x86_64`, a board target, `all`, `both`, or a space/comma list of them (several run in parallel) |
| `TRIAL_SUITES` | every suite | limit a tree run (host or board) to these suites, e.g. `make integrate TRIAL_TARGET=host TRIAL_SUITES="actors_addition base"`; a name that is not a suite is an error, and a named suite runs even if it has `INTEGRATE_PENDING` (whole-tree runs skip those). On the host the report and failure list cover only the named suites |
| `BOARD_PORT` | the single USB serial port | the board's serial port |
| `BOARD_MAC` | (none) | refuse any board with another MAC (ESP32; the STM32 driver ignores it) |
| `BOARD_ST_SERIAL` | the lab Nucleo's | STM32 target: the ST-LINK serial `--probe` must find |
| `BOARD_ASCOMP` | (on) | `off`: skip the `<trial>.<platform>.ascomp` check |
| `BOARD_SILICA_COMPILER` | `binaries/silica-compiler-<target>` | the board compiler |
| `BOARD_PYTHON` | from `<target>.conf` | Python with esptool and pyserial (pyserial only for the STM32) |
| `TRIAL_REMOTE_SYNC` | 1 | `0`: a remote run skips the sync step |
| `SILICA_REMOTE_DRY_RUN` | (off) | `1`: a remote run checks ssh, dry-runs the sync, prints the remote command |
| `SILICA_BUILD_HOSTS` | `.silica_build_hosts` in the repository root | the machine list |
| `BOARD_TRIAL_TIMEOUT` | 300 | seconds a program may run on the board before it counts as hung |
| `BOARD_FAIL_JOBS` | 4 | compile-failure trials compiled at once |

## Files

| File | Role |
| ---- | ---- |
| [trial_target.sh](trial_target.sh) | the per-target locks, the menu, the selection (`all`, lists), the preflight checks, the board and remote runs, the combined summary |
| [board_root.mk](board_root.mk), [board_suite.mk](board_suite.mk) | the board run's top level and one suite, on top of the shared integrate wrapper (`../silica_compiler.mk`): same progress line, watchdog, logs and report as a host run |
| [board_suite.sh](board_suite.sh) | one suite on the board |
| [run_one_trial.sh](run_one_trial.sh) | one trial on the board, through board_suite.sh |
| `<target>.conf`, `<target>.skip` | a board target and what it skips |
