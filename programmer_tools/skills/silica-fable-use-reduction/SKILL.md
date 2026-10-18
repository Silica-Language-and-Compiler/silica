---
name: silica-fable-use-reduction
description: Decide which model does each piece of Silica work so Fable tokens go only to compiler code. Use whenever delegating or planning work in the Silica repo (spawning subagents, queueing fixes, assigning builds, trial runs, golden refreshes, docs or reports), and whenever a Fable agent is about to build, wait on builds, or run trial suites.
---

# Silica: reduce Fable use

Lee's rules, 2026-10-09. Fable tokens are scarce, so Fable writes compiler code and nothing else; every other activity goes to a lesser model chosen for the job.

## Who does what

| Work | Model |
| --- | --- |
| Compiler code changes in `compiler/src`: the Silica compiler (lexer, parser, type and effect checkers, SIR), the emitters, and the runtimes inside the emitter trees (`board/runtime/*.S`, `prims_*_runtime_asm*.silica`) | **Fable** |
| Root-causing a compiler defect, and the quick checks that go with writing the fix (below) | **Fable** |
| Tasks that only run existing scripts (official build/fixed-point/publish/trial scripts, golden refresh scripts) and report their output | **Haiku** (the least powerful model; Lee 2026-10-15) |
| Full compiler builds: Mac, pix (linux_aarch64), nix (linux_x86_64), ESP32-S3 cross | Haiku when it is only running the scripts; Sonnet if it needs judgement |
| Trial suite runs on hosts and on the board; waiting on builds and runs | Sonnet or Haiku |
| Golden refreshes under Lee's rules; capturing Linux goldens | Sonnet or Haiku |
| Triage and verification of reported defects | Sonnet |
| Trial sources and trial conversions (item M), board sample apps | Opus |
| Trial harness, Makefiles, `programmer_tools` scripts, board tool scripts (`build_image.sh`, `run_on_board.py`, ...) | Opus or Sonnet |
| Documentation changes (spec text, design documents, plans, READMEs, docs/ guides and examples, tutorials, reports) | **Sonnet** (Lee 2026-10-16); the main session only for memory notes |

When in doubt: if the file is under `compiler/src` and is compiler, emitter or runtime code, it is Fable's; otherwise it is not. Board apps under `compiler/src/emitter/ESP32-S3_raw/board/apps` are sample programs, not compiler code.

## How a compiler fix flows

1. **Fable** finds the root cause and writes the change. It checks its work only with:
   - quick incremental Mac builds (`make INSTALL_SELFHOST=0 SILICA_TARGET_PROMPT=0` in `compiler/src`, often 1-3 minutes for a few units);
   - a minimal repro compiled and run in a scratch directory, and the covering trial for the defect.

   Then it hands off with: the files changed, the root cause, the repro, and the trials to run. It does not run full multi-host builds, does not wait on long builds, and does not run whole suites.
2. **A lesser model** (Sonnet or Haiku) takes the hand-off:
   - full builds on the Mac, pix and nix, and the ESP32 cross build;
   - the named trials and suites on every host and on the board (console-only programs);
   - golden refreshes under Lee's rules;
   - the report.
3. **If any target fails**, the evidence (the failing trial, the output, the diff, the platform) goes back to a Fable agent, which repeats step 1.

## Rules every agent keeps

- If Fable tokens run out, stop the compiler work and tell Lee. Do not hand compiler code to another model.
- Builds: never publish (`INSTALL_SELFHOST=0`) unless Lee has asked for a publish step; never `make clean` a shared build directory; take the build-slot lock (`mkdir` of the session scratchpad's `build_slot/lock`) for heavy builds and remove it afterwards.
- Point `SILICA_COMPILER` at a file named exactly `silica-compiler`; the trial harness reads the target from the name.
- `make integrate` is the gate; a bare `make` only compiles.
- Goldens: a `.ascomp` may be refreshed only when that trial's `.sout` matches its `.scout`; a `.scout` changes only with Lee's approval; error goldens are re-derived from real output with the same error code and construct.
- No workarounds for compiler defects: fix them, with a trial.
- Board runs are console-only unless Lee is watching; never run an app Lee must watch, press or listen to without announcing it.
- Kill any wait loops you start; report what is left running.
- Agents started before this rule may finish as they were started.
