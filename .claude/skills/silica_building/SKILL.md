---
name: silica_building
description: Decide which model does each piece of Silica work (building, trials, scripts, compiler code, docs, goldens) so Fable tokens go only to compiler code, and how builds, trial runs and compiler fixes flow. Use whenever delegating or planning work in the Silica repo (spawning subagents, queueing fixes, assigning builds, trial runs, golden refreshes, docs or reports, remote machine runs), and whenever a Fable agent is about to build, wait on builds, or run trial suites.
---

# Silica: who does what, building, trials and scripts

Lee's rules (2026-10-09, amended 2026-10-24, trials and scripts under Sonnet from 2026-10-29). Fable tokens are scarce, so Fable writes compiler code and nothing else; every other activity goes to a lesser model chosen for the job. These rules apply to subagents too: when you delegate, name the model the rule assigns.

## Who does what

1. **Haiku controls all builds and script runs.** Starting, polling, waiting on and collecting results from builds, trial runs, scripts and remote machines all go to Haiku, the cheapest model that can do control work (Opus only when a build needs judgement; never Fable or Sonnet). This covers incremental builds, unit compiles, RSS measurements, full compiler builds on the Mac, pix (linux_aarch64), nix (linux_x86_64) and the cross builds, the official build/fixed-point/publish/trial scripts, and golden refresh scripts.
2. **Fable (or Opus) modifies the compiler.** Fable for every change under `compiler/src` that is compiler, emitter, runtime or front-end code (lexer, parser, type and effect checkers, SIR, the emitters, the runtimes inside the emitter trees such as `board/runtime/*.S` and `prims_*_runtime_asm*.silica`) and for root-causing a compiler defect. Opus when Fable is out; tell Lee. Board apps under `compiler/src/emitter/ESP32-S3_raw/board/apps` are sample programs, not compiler code.
3. **Sonnet evaluates and writes tests and scripts.** Sonnet evaluates all compilation and trial results (successes and failures), triages and verifies reported defects, writes and modifies all trials (sources, conversions, board sample apps), the trial harness, Makefiles, `programmer_tools` scripts and board tool scripts (`build_image.sh`, `run_on_board.py`, ...), and all bash scripts. Opus may do this work when judgement beyond Sonnet is needed.
4. **Documentation** (spec text, design documents, plans, READMEs, docs/ guides and examples, tutorials, reports) is written by Sonnet; the main session only for memory notes.
5. **Full trial runs always go through `programmer_tools/run_trials_all_platforms.sh`.** Any full trial run, for one platform or several, is started with that script (`--targets "<platforms>"`, `--sync` to push the tree to pix and nix first, `--board` to include the ESP32-S3 and the Nucleo; `--list` shows the plan), never by calling `make integrate` by hand or running a platform's trials some other way. The script runs the remote machines at the same time, starts the boards together when the Mac run ends, takes the per-target locks and writes one summary table. Haiku starts it; Sonnet reads the table and judges the results. A single suite or a few trials during development may still use that suite's own Makefile.

When in doubt: if the file is under `compiler/src` and is compiler, emitter or runtime code, it is Fable's; otherwise it is not.

## How a compiler fix flows

1. **Fable** finds the root cause and writes the change. It does **not** build, compile or run trials itself (Lee 2026-10-24). To check its work it hands each check to a **Haiku** agent, one at a time, with exact commands:
   - a quick incremental Mac build (`make build INSTALL_SELFHOST=0 SILICA_TARGET_PROMPT=0` in `compiler/src`; bare `make` is `clean build`);
   - a minimal repro compiled and run in a scratch directory, and the covering trial for the defect.

   The Haiku agent changes no files and reports the full error text or the pass/fail counts back. If Fable cannot spawn a subagent, it appends an exact build request to its notes file and hands back; the main session runs the Haiku build and returns the results. Fable's final hand-off lists the files changed, the root cause, the repro, and the trials to run.
2. **A Haiku agent** (Opus only if judgement is needed) takes the hand-off: full builds on the Mac, pix, nix and the cross builds; the named trials and suites on every host and on the board (console-only programs); golden refreshes under Lee's rules, with the scripts; the report.
3. **If any target fails**, the evidence (the failing trial, the output, the diff, the platform) goes back to a Fable agent, which repeats step 1.

## Rules every agent keeps

- If Fable tokens run out, switch the compiler work to Opus (Lee 2026-10-24) and tell Lee. The Opus agent resumes from the Fable agent's notes file, with the same rules (it does not build either).
- Only one agent may be building or compiling at a time on a machine; no agent spawns parallel building subagents. The build-slot lock is not a substitute for this. Trial runs of different targets may run at the same time (each has its own lock, work directory and port); a target runs once at a time.
- Builds: never publish (`INSTALL_SELFHOST=0`) unless Lee has asked for a publish step; no fixed point unless Lee asks for one; never `make clean` a shared build directory; take the build-slot lock (`mkdir` of the session scratchpad's `build_slot/lock`) for heavy builds and remove it afterwards.
- Point `SILICA_COMPILER` at a file named exactly `silica-compiler`; the trial harness reads the target from the name.
- `make integrate` is the gate; a bare `make` only compiles.
- Goldens: a `.ascomp` may be refreshed only when that trial's `.sout` matches its `.scout`; a `.scout` changes only with Lee's approval; error goldens are re-derived from real output with the same error code and construct.
- No workarounds for compiler defects: fix them, with a trial.
- Board runs are console-only unless Lee is watching; never run an app Lee must watch, press or listen to without announcing it.
- Kill any wait loops you start; report what is left running.
