# Shared seed host for trials — always binaries/silica-compiler unless overridden
# on the make command line (e.g. `make SILICA_COMPILER=/path/to/other integrate`).
# Paths are anchored to this file (trials/silica_compiler.mk).
#
# Usage (from any trials Makefile):
#   THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
#   include $(THIS_DIR)../silica_compiler.mk          # depth-1 trial
#   include $(THIS_DIR)../../silica_compiler.mk        # depth-2 trial
#   include silica_compiler.mk                        # trials/Makefile
#
# IMPORTANT: capture THIS_DIR (or MAKEFILE_DIR / LEAF_DIR) *before* this include.
# After include, $(lastword $(MAKEFILE_LIST)) is this file (trials/), so recipes that
# still use MAKEFILE_LIST write silica.config in the wrong directory and integrate SKIPs.
#
# Leaf helpers that already include this file (do not re-point the compiler elsewhere):
#   standard_data_structures_phase1/leaf.mk
#   ffi_addition/common_app.mk
#
# Per-target goldens (defined below, after the emit target): assembly <stem>$(ASCOMP_EXT), errors
# <stem>$(GOLDEN_FAIL_EXT).golden_fail, run output $(call SCOUT_FOR,<stem>). The plain names
# (<stem>.ascomp, .golden_fail, .scout) are the macOS goldens; on any other emit target
# <stem>.<target>.{ascomp,golden_fail,scout} is used instead -- always for .ascomp, and for
# .golden_fail / .scout only when that file exists (else the plain one). <target> is
# $(SILICA_EMIT_TARGET): linux_aarch64, linux_x86_64, ESP32-S3_raw.

_SILICA_COMPILER_MK_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BINARIES_DIR := $(abspath $(_SILICA_COMPILER_MK_DIR)../binaries)
_SILICA_COMPILER_SEED := $(BINARIES_DIR)/silica-compiler

# Force the seed binary for undefined / environment origins. Command-line
# SILICA_COMPILER=... still wins (GNU make: origin "command line").
ifeq ($(filter command line,$(origin SILICA_COMPILER)),)
SILICA_COMPILER := $(_SILICA_COMPILER_SEED)
endif

UPDATE_SILICA_COMPILER_LINK := $(BINARIES_DIR)/update_silica_compiler_link.bash

include $(_SILICA_COMPILER_MK_DIR)linux_host.mk

# ---- Emit target -------------------------------------------------------------------
# SILICA_EMIT_TARGET names the target the compiler in use generates code FOR, which is not
# always the machine the trials run ON. Compiling is target independent and always happens.
# Assembling, linking and running need a toolchain for the emitted target, and a host only
# has one for its own: a macOS host cannot assemble the ELF that the linux_aarch64 emitter
# produces, and a Linux host cannot assemble Mach-O. When the two differ the trial stops
# after compiling, and the emitted assembly is the deliverable -- that is what lets one host
# compile the whole suite for the other and hand the assembly over.
#
# The target is taken from the compiler's own name, which install_compiler.bash sets:
# binaries/silica-compiler-<emit-target> for a cross build, plain binaries/silica-compiler
# for a build that emits for this host. Override it when the compiler reaches the trials
# under some other name, e.g. through a wrapper:
#   make integrate SILICA_EMIT_TARGET=linux_aarch64
# The host's own emit target comes from the one platform table.
include $(_SILICA_COMPILER_MK_DIR)../project_makefiles/platform/platforms.mk
# (SILICA_HOST_EMIT_TARGET, SILICA_HOST_PLATFORM, SILICA_HOST_UNAME_S/_M are defined there.)

_SILICA_COMPILER_NAME := $(notdir $(SILICA_COMPILER))
SILICA_EMIT_TARGET ?= $(if $(filter silica-compiler-%,$(_SILICA_COMPILER_NAME)),$(patsubst silica-compiler-%,%,$(_SILICA_COMPILER_NAME)),$(SILICA_HOST_EMIT_TARGET))

# 1 when the emitted code is for this host and the whole pipeline can run; 0 when the trial
# can only be compiled here. An unknown host leaves SILICA_HOST_EMIT_TARGET empty, which is
# treated as "this host runs its own code" so an unrecognised platform behaves as before.
SILICA_TARGET_IS_HOST := $(if $(SILICA_HOST_EMIT_TARGET),$(if $(filter $(SILICA_EMIT_TARGET),$(SILICA_HOST_EMIT_TARGET)),1,0),1)

# Printed once by a suite that stops after compiling, so the run says why rather than
# looking like the trials silently did nothing.
SILICA_CROSS_NOTE := emit target $(SILICA_EMIT_TARGET) is not this host ($(SILICA_HOST_EMIT_TARGET)): compiling only, not assembling or running

# The assembly golden a trial is compared against. Assembly is target-specific, so each emit
# target keeps its own: the plain .ascomp is the original macOS (Darwin) golden, and every other
# target's golden carries the target name, <stem>.<target>.ascomp, beside it. Recording a golden
# writes the same name, so one checkout serves every target it has goldens for.
ASCOMP_EXT := $(if $(filter apple_silicon_mac,$(SILICA_EMIT_TARGET)),.ascomp,.$(SILICA_EMIT_TARGET).ascomp)

# The error golden a trial is compared against: <stem>.<target>.golden_fail when it exists, else the
# plain <stem>.golden_fail (the macOS golden). GOLDEN_FAIL_EXT is empty on the Mac.
GOLDEN_FAIL_EXT := $(if $(filter apple_silicon_mac,$(SILICA_EMIT_TARGET)),,.$(SILICA_EMIT_TARGET))

# The output golden a trial's run (<stem>.sout) is compared against. The plain <stem>.scout is the
# macOS (Darwin) golden and the default for every target; a target whose run legitimately prints
# something else (a host-specific fact, e.g. the CPU topology) keeps <stem>.<target>.scout beside it,
# and that file wins on that target when it exists. SCOUT_EXT is empty on the Mac, so the Mac always
# reads the plain .scout, exactly as before. A target-specific scout is a golden, never a trial: the
# trials are the .silica files, and markers (<stem>.scout.multiset, .sorted, .alt, ...) stay keyed on
# the plain stem.
#   "$(call SCOUT_FOR,$$base)"  ->  the path of the golden for shell variable base, in a recipe.
# On the Mac it expands to plain "$base.scout" (no subshell); elsewhere to a POSIX-sh
# $( if [ -f ... ] ...) that picks "$base.<target>.scout" when that file exists, else "$base.scout".
SCOUT_EXT := $(if $(filter apple_silicon_mac,$(SILICA_EMIT_TARGET)),,.$(SILICA_EMIT_TARGET))
_SCOUT_PICK_SH = $$(if [ -f "$(1)$(SCOUT_EXT).scout" ]; then echo "$(1)$(SCOUT_EXT).scout"; else echo "$(1).scout"; fi)
SCOUT_FOR = $(if $(SCOUT_EXT),$(_SCOUT_PICK_SH),$(1).scout)

# Toolchain for the emitted target's code: trials/platform/<emit target>.mk (assembler, linker,
# link flags, FFI fixture flags, golden suffix, skip list). Optional while the per-trial makefiles
# still carry their own macOS values; once those lines are deleted this include is the only source.
-include $(_SILICA_COMPILER_MK_DIR)platform/$(SILICA_EMIT_TARGET).mk

# If silica-compiler is missing, run update_silica_compiler_link.bash and re-check.
define ENSURE_SILICA_COMPILER
	if [ "$(SILICA_COMPILER)" = "$(_SILICA_COMPILER_SEED)" ] && [ -L "$(SILICA_COMPILER)" ] && [ -n "$(SILICA_HOST_PLATFORM)" ] \
		&& case "$$(readlink "$(SILICA_COMPILER)")" in *-$(SILICA_HOST_PLATFORM)) false;; *) true;; esac; then \
		echo "$(SILICA_COMPILER) -> $$(readlink "$(SILICA_COMPILER)") is not a $(SILICA_HOST_PLATFORM) build; relinking for this host..."; \
		"$(UPDATE_SILICA_COMPILER_LINK)" "$(SILICA_HOST_PLATFORM)" || exit 1; \
	fi; \
	if [ ! -x "$(SILICA_COMPILER)" ]; then \
		echo "Missing $(SILICA_COMPILER); running update_silica_compiler_link.bash..."; \
		"$(UPDATE_SILICA_COMPILER_LINK)" || exit 1; \
		if [ ! -x "$(SILICA_COMPILER)" ]; then \
			echo "Missing seed host after update: $(SILICA_COMPILER)"; \
			exit 1; \
		fi; \
	fi
endef

.PHONY: ensure-silica-compiler
ensure-silica-compiler:
	@$(ENSURE_SILICA_COMPILER)

# Merged into every including Makefile's compile/assembly when present.
# (`integrate` is defined by the wrapper section at the end of this file.)
compile: ensure-silica-compiler
assembly: ensure-silica-compiler

# Merged into every including Makefile's clean: drop published unit iface caches under
# that trial's CURDIR (make -C <trial> clean). Nested *.iface are included. Also drops
# the integrate wrapper's bookkeeping files (see the wrapper section below).
.PHONY: clean-silica-ifaces
clean: clean-silica-ifaces
clean-silica-ifaces:
	@find "$(CURDIR)" -name '*.iface' -type f -delete 2>/dev/null || true
	@[ -n "$$SILICA_INTEGRATE_ACTIVE" ] || { rm -f $(INTEGRATE_FILES); rm -rf "$(INTEGRATE_RUNNING_DIR)"; }

# So prerequisites like `integrate: $(SILICA_COMPILER)` create the binaries/ link if needed.
$(SILICA_COMPILER):
	@$(ENSURE_SILICA_COMPILER)

# Multi-unit batches use process-per-unit hygiene: the seed exits 75 (EX_TEMPFAIL)
# between units so the OS reclaims host heap (76 = crashed in a unit; the next process reports it
# and skips it; treated like 75). Recipes must re-invoke until exit 0
# (or a hard failure). Usage inside a recipe (same cwd as silica.config):
#   $(RUN_SILICA_COMPILER)
# Optional override of the binary path:
#   $(call RUN_SILICA_COMPILER_WITH,$(abspath $(SILICA_COMPILER)))
# Quiet variant (no reclaim chatter) for golden-output capture:
#   $(call RUN_SILICA_COMPILER_QUIET_WITH,"$(SILICA_COMPILER)")
# Per-unit compile timeout. Without it a compiler hang blocks the suite indefinitely --
# an orphaned resume loop once spun for 14 hours overnight. Exit 142 = alarm fired.
# Raised 300 -> 900 (2026-09-28): the graph_collections suite alone takes ~200s on the fastest
# machine in the fleet (a known, unfixed compiler perf defect -- type-checker trait-dispatch
# re-scanning type surfaces with no memo, see compiler/design_documents perf notes), so 300s was
# already tight on Apple Silicon and genuinely insufficient on a Raspberry Pi. This is a stopgap
# for the slow machine, not a fix for the underlying slowness; lower it again once that's fixed.
SILICA_COMPILE_TIMEOUT ?= 900
define RUN_SILICA_COMPILER_WITH
	rm -f silica.compile.inprogress silica.compile.crashed; \
	while true; do \
		perl -e 'alarm shift @ARGV; exec @ARGV' $(SILICA_COMPILE_TIMEOUT) $(1); \
		ec=$$?; \
		if [ $$ec -eq 0 ]; then break; fi; \
		if [ $$ec -eq 75 ] || [ $$ec -eq 76 ]; then \
			echo "  (reclaiming memory; continuing next unit)"; \
			continue; \
		fi; \
		if [ $$ec -eq 142 ]; then \
			echo "❌❌ compiler TIMED OUT after $(SILICA_COMPILE_TIMEOUT)s (compile hang)"; \
		fi; \
		exit $$ec; \
	done
endef

# Quiet reclaim loop for golden capture. Do not `exit` on hard failure: recipe lines that
# redirect into `.cur_fail` often run in the make shell (not a subshell), and `exit`
# would abort the recipe before the diff step. Callers use `|| true` around the loop.
define RUN_SILICA_COMPILER_QUIET_WITH
	rm -f silica.compile.inprogress silica.compile.crashed; \
	while true; do \
		perl -e 'alarm shift @ARGV; exec @ARGV' $(SILICA_COMPILE_TIMEOUT) $(1); \
		ec=$$?; \
		if [ $$ec -eq 0 ]; then break; fi; \
		if [ $$ec -eq 75 ] || [ $$ec -eq 76 ]; then continue; fi; \
		break; \
	done
endef

define RUN_SILICA_COMPILER
	$(call RUN_SILICA_COMPILER_WITH,"$(SILICA_COMPILER)")
endef

define RUN_SILICA_COMPILER_QUIET
	$(call RUN_SILICA_COMPILER_QUIET_WITH,"$(SILICA_COMPILER)")
endef

# ---- supervisor-actor shaped trials (actor_memory_budget_plan.md item M) ----
# A trial's main starts a supervisor, casts its work (a function literal) to the supervisor's one
# worker and waits in wait_for_exit. The supervisor and worker live in the shared trial-support
# modules trials/lib_trial_support/trial_{support,call,wait}_<type>.silica (written by
# programmer_tools/trial_shape_m/gen_support.py), which use the Supervisor trait. Each suite compiles
# the modules its trials `use`, plus Supervisor (unless its config already lists the stdlib trait),
# through private symlinks in <suite>/.trial_stdlib/,
# so their .sams/.iface land in the suite and the suite's own `*.sams` loops never see them.
#   silica.config rule (in the directory holding silica.config, after writing it):
#       ... > silica.config && $(TRIAL_SUPPORT_CONFIG)
#   before linking:            $(TRIAL_SUPPORT_ASSEMBLE);
#   per trial, in the link line: $(call TRIAL_SUPPORT_OBJ,<trial .silica>)
TRIAL_STDLIB_SUPERVISOR := $(abspath $(_SILICA_COMPILER_MK_DIR)../compiler/stdlib/Supervisor.silica)
TRIAL_SUPPORT_DIR := $(abspath $(_SILICA_COMPILER_MK_DIR)lib_trial_support)
# The links these helpers make inside the tree are relative to the directory holding the link,
# so a tree synced to another host (nix, pix) keeps working
# links; an absolute link carried /Volumes/2T/... there. $(TRIAL_REL_FN) defines the shell function
# _trial_rel <target> <existing link directory>, which prints the target relative to the link
# directory. Both sides are resolved physically (pwd -P): the kernel resolves a relative link from
# the directory the link really lives in.
TRIAL_REL_FN = _trial_rel() { _t="$$(CDPATH= cd "$${1%/*}" && pwd -P)/$${1\#\#*/}"; _f="$$(CDPATH= cd "$$2" && pwd -P)"; _u=""; while :; do case "$$_t/" in "$$_f"/*) break;; esac; _f="$${_f%/*}"; _u="../$$_u"; done; printf '%s%s\n' "$$_u" "$${_t\#"$$_f"/}"; }
TRIAL_SUPPORT_CONFIG = { $(TRIAL_REL_FN); rm -rf .trial_stdlib && mods=$$(grep -rhoE --include='*.silica' '^use trial_(support|call|wait)_[a-z0-9_]+;' . 2>/dev/null | sed 's/^use //;s/;$$//' | LC_ALL=C sort -u) && if [ -n "$$mods" ]; then mkdir .trial_stdlib && { grep -q 'Supervisor\.silica$$' silica.config || { ln -sfn "$$(_trial_rel "$(TRIAL_STDLIB_SUPERVISOR)" .trial_stdlib)" .trial_stdlib/Supervisor.silica && echo .trial_stdlib/Supervisor.silica >> silica.config; }; } && for mod in $$mods; do ln -sfn "$$(_trial_rel "$(TRIAL_SUPPORT_DIR)/$$mod.silica" .trial_stdlib)" ".trial_stdlib/$$mod.silica" && echo ".trial_stdlib/$$mod.silica" >> silica.config || exit 1; done; fi; }
# A harness that compiles and links everything in a lib/ directory (ordered_data_structures/leaf.mk)
# gets the modules as lib/ links instead (gitignored): run before the lib/ listing is taken.
TRIAL_SUPPORT_LIB = { $(TRIAL_REL_FN); mods=$$(grep -hoE '^use trial_(support|call|wait)_[a-z0-9_]+;' *.silica 2>/dev/null | sed 's/^use //;s/;$$//' | LC_ALL=C sort -u); rm -f lib/trial_support_*.silica lib/trial_wait_*.silica lib/trial_call_*.silica; [ ! -L lib/Supervisor.silica ] || rm -f lib/Supervisor.silica; if [ -n "$$mods" ]; then mkdir -p lib && { [ -e lib/Supervisor.silica ] || ln -sfn "$$(_trial_rel "$(TRIAL_STDLIB_SUPERVISOR)" lib)" lib/Supervisor.silica; } && for mod in $$mods; do ln -sfn "$$(_trial_rel "$(TRIAL_SUPPORT_DIR)/$$mod.silica" lib)" "lib/$$mod.silica" || exit 1; done; fi; }
TRIAL_SUPPORT_ASSEMBLE = { for tss in .trial_stdlib/trial_*.sams; do [ -f "$$tss" ] || continue; $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$tss" -o "$${tss%.sams}.o" || echo "❌❌ assembling $$tss failed"; done; }
TRIAL_SUPPORT_OBJ = $$(sed -n 's|^use \(trial_[a-z0-9_]*\);.*|.trial_stdlib/\1.o|p' "$(1)" 2>/dev/null)
# compiler/stdlib/Supervisor.sams is a golden (Supervisor.ascomp) that only supervisors_addition
# writes and compares. Every other suite that lists the stdlib Supervisor in its silica.config gets a
# private copy instead: the line is rewritten in place (same position, so the unit order and the
# application's atom table do not change) to .trial_stdlib/Supervisor.silica, a symlink, so the
# compiler writes that suite's Supervisor.sams/.iface under <suite>/.trial_stdlib/ rather than into
# compiler/stdlib/, where suites with different atom tables overwrote one another's output.
#   silica.config rule, after writing it (and after TRIAL_SUPPORT_CONFIG, which empties .trial_stdlib):
#       ... > silica.config && $(TRIAL_SUPPORT_CONFIG) && $(TRIAL_PRIVATE_SUPERVISOR)
TRIAL_PRIVATE_SUPERVISOR = { $(TRIAL_REL_FN); if grep -qE '^(\.\./)+compiler/stdlib/Supervisor\.silica$$' silica.config; then mkdir -p .trial_stdlib && ln -sfn "$$(_trial_rel "$(TRIAL_STDLIB_SUPERVISOR)" .trial_stdlib)" .trial_stdlib/Supervisor.silica && sed -E 's|^(\.\./)+compiler/stdlib/Supervisor\.silica$$|.trial_stdlib/Supervisor.silica|' silica.config > silica.config.tmp && mv silica.config.tmp silica.config; fi; }
# Single-file compiles (error trials) in a scratch directory <dir> holding <file>: add Supervisor and
# the support module the file uses (none for a trial left in its old shape, which keeps its golden).
#   $(call TRIAL_SUPPORT_IN_TMP,<dir>,<file>)
TRIAL_SUPPORT_IN_TMP = { for mod in $$(LC_ALL=C sed -n 's/^use \(trial_[a-z0-9_]*\);.*/\1/p' "$(2)"); do ln -sfn "$(TRIAL_SUPPORT_DIR)/$$mod.silica" "$(1)/$$mod.silica" && echo "$$mod.silica" >> "$(1)/silica.config" && ln -sfn "$(TRIAL_STDLIB_SUPERVISOR)" "$(1)/Supervisor.silica" && echo Supervisor.silica >> "$(1)/silica.config"; done; }

# ============================================================================
# integrate wrapper -- parallel fan-out, per-directory log and report
# ============================================================================
#
# Every trial Makefile names its real integrate recipe `integrate-run`. The shared
# `integrate` target below wraps it:
#
#   1. records the start time,
#   2. runs `integrate-run` (parallel when no jobserver is already active),
#      capturing everything it prints to <dir>/.integrate_log,
#   3. writes a report for just this directory to <dir>/.integrate_report: pass/fail
#      totals, elapsed time, every failure with the file and the kind of difference,
#      and the log path. The outermost directory prints its report; nested ones only
#      write theirs (the outermost failure list replays every nested failure).
#
# Parents that fan out over children use $(call INTEGRATE_CHILD,<subdir>[,flags]):
# the child's output goes only to its own log; the terminal shows the live pass/fail
# counters (see the progress channel below) and the outermost report at the end. Diff bodies
# stay in the child's log and are replayed, deduplicated, in the failure section.
#
# Counts are the existing per-directory `.integrate_counts` files ("<ok> <fail>").
# Nothing here parses free-form output for totals.
#
# Knobs (command line or environment):
#   JOBS=N                 parallelism for a standalone `make integrate` (default: cores)
#   SDS_JOBS=N             parallelism for ordered_data_structures (memory-bound, default 4)
#   INTEGRATE_DETAIL_LINES per-failure context lines replayed in reports (default 40)
#   INTEGRATE_WATCHDOG_MINUTES minutes without a pass or fail before running trials are killed (default 15)

INTEGRATE_MAKEFILE := $(abspath $(firstword $(MAKEFILE_LIST)))
INTEGRATE_DIR      := $(dir $(INTEGRATE_MAKEFILE))
_INTEGRATE_TRIALS_ROOT := $(patsubst %/,%,$(abspath $(_SILICA_COMPILER_MK_DIR)))
_INTEGRATE_DIR_NOSLASH := $(patsubst %/,%,$(INTEGRATE_DIR))
INTEGRATE_LABEL := $(if $(filter $(_INTEGRATE_TRIALS_ROOT),$(_INTEGRATE_DIR_NOSLASH)),trials,$(patsubst $(_INTEGRATE_TRIALS_ROOT)/%,%,$(_INTEGRATE_DIR_NOSLASH)))
# Board trial runs (targets/) name their directories after the target, e.g. ESP32-S3_raw/case_addition.
ifdef INTEGRATE_LABEL_OVERRIDE
INTEGRATE_LABEL := $(INTEGRATE_LABEL_OVERRIDE)
endif

INTEGRATE_FILES := $(INTEGRATE_DIR).integrate_log $(INTEGRATE_DIR).integrate_report \
	$(INTEGRATE_DIR).integrate_status $(INTEGRATE_DIR).integrate_start \
	$(INTEGRATE_DIR).integrate_results $(INTEGRATE_DIR).integrate_skipped \
	$(INTEGRATE_DIR).integrate_pass_marks $(INTEGRATE_DIR).integrate_fail_marks
INTEGRATE_RUNNING_DIR := $(INTEGRATE_DIR).integrate_running

ifeq ($(origin JOBS),undefined)
JOBS := $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
endif
export JOBS
SDS_JOBS ?= 4
export SDS_JOBS
INTEGRATE_DETAIL_LINES ?= 40
export INTEGRATE_DETAIL_LINES
# The watchdog kills every registered running trial after this many minutes without a new mark.
INTEGRATE_WATCHDOG_MINUTES ?= 15
export INTEGRATE_WATCHDOG_MINUTES

# A Makefile may set INTEGRATE_JOBS before or after including this file (leaf.mk and
# ordered_data_structures use SDS_JOBS). When make already runs under a jobserver the
# sub-make inherits it and no -j is added.
INTEGRATE_JOBS ?= $(JOBS)
INTEGRATE_JOBFLAGS = $(if $(filter -j% --jobserver%,$(MAKEFLAGS)),,-j$(INTEGRATE_JOBS))

# ---- progress channel ---------------------------------------------------------------
# The outermost `integrate` exports SILICA_INTEGRATE_ROOT (its directory) and creates two
# empty files there, .integrate_pass_marks and .integrate_fail_marks. Every check appends one
# byte to one of them: a one-byte O_APPEND write is atomic, so parallel suites never lose or
# tear a mark, and no check ever touches the terminal. A loop in the outermost wrapper (the
# same loop that runs the watchdog) redraws one line on the terminal once a second from the
# two file sizes: `✅✅ <passes>  ❌❌ <failures>`. Nothing is drawn when stdout is not a
# terminal. The final totals still come from the suites' .integrate_counts; the marks are
# display only. Without the wrapper (no root exported) the appends fail silently.
# fd 3 and fd 4 are the make 3.81 jobserver pipe; never use them for anything here.
INTEGRATE_DOT_OK   = { printf P >> "$$SILICA_INTEGRATE_ROOT/.integrate_pass_marks"; } 2>/dev/null || true
INTEGRATE_DOT_FAIL = { printf F >> "$$SILICA_INTEGRATE_ROOT/.integrate_fail_marks"; } 2>/dev/null || true

# One redraw of the live counter line on fd 9 (the terminal). $(1) = directory holding the marks.
define INTEGRATE_DRAW_COUNTS
{ pm=$$(stat -c %s "$(1).integrate_pass_marks" 2>/dev/null || stat -f %z "$(1).integrate_pass_marks" 2>/dev/null || echo 0); fm=$$(stat -c %s "$(1).integrate_fail_marks" 2>/dev/null || stat -f %z "$(1).integrate_fail_marks" 2>/dev/null || echo 0); \
  printf '\r✅✅ %-8s ❌❌ %-8s' "$$pm" "$$fm" >&9; } 2>/dev/null || true
endef

# ---- trial runs -----------------------------------------------------------------------
# Every trial executable (and every helper script that drives one) runs through one of
# these so the watchdog can find and kill it: the process runs in its own process group,
# registered in the root's .integrate_running/ while it runs. Afterwards $$integrate_rc is
# its exit status and $$integrate_killed is 1 when the watchdog killed it, in which case
# the recipe reports the trial as incomplete instead of comparing its output.
#
# $(call INTEGRATE_RUN_TRIAL,<label>,<sout path>,<command>): output then exit status into <sout path>.
define INTEGRATE_RUN_TRIAL
integrate_killed=0; \
perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' $(3) > "$(2)" 2>&1 & integrate_pid=$$!; \
integrate_reg="$${SILICA_INTEGRATE_ROOT:-.}/.integrate_running/$$integrate_pid"; \
{ printf '%s %s\n' "$$integrate_pid" "$(1)" > "$$integrate_reg"; } 2>/dev/null; \
wait $$integrate_pid; integrate_rc=$$?; \
printf '%s\n' "$$integrate_rc" >> "$(2)"; \
if [ -f "$$integrate_reg.killed" ]; then integrate_killed=1; fi; \
rm -f "$$integrate_reg" "$$integrate_reg.killed" 2>/dev/null
endef
# $(call INTEGRATE_EXEC_TRIAL,<label>,<command>): the command manages its own output.
define INTEGRATE_EXEC_TRIAL
integrate_killed=0; \
perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' $(2) & integrate_pid=$$!; \
integrate_reg="$${SILICA_INTEGRATE_ROOT:-.}/.integrate_running/$$integrate_pid"; \
{ printf '%s %s\n' "$$integrate_pid" "$(1)" > "$$integrate_reg"; } 2>/dev/null; \
wait $$integrate_pid; integrate_rc=$$?; \
if [ -f "$$integrate_reg.killed" ]; then integrate_killed=1; fi; \
rm -f "$$integrate_reg" "$$integrate_reg.killed" 2>/dev/null
endef
# The message a recipe prints for a trial the watchdog killed.
INTEGRATE_KILLED_MSG = killed by the watchdog after $$SILICA_INTEGRATE_WATCHDOG_MINUTES minutes of silence; trial incomplete

.PHONY: integrate integrate-run integrate-report

# SILICA_INTEGRATE_ACTIVE tells the shared clean hook not to delete the log and start
# stamp while the run they belong to is in progress (most integrate-run recipes clean first).
#
# Trial targets (targets/README.md). The outermost `integrate` -- the one the user typed, in
# trials/ or in a suite -- first decides where the trials run:
#   TRIAL_TARGET=host              this host (macOS, Linux x86-64 or AArch64), binaries/silica-compiler (what integrate always did)
#   TRIAL_TARGET=<board target>    e.g. ESP32-S3_raw: compiled by binaries/silica-compiler-<target>,
#                                  run on the board (targets/trial_target.sh does the whole run)
#   TRIAL_TARGET=both              host, then every board target, one after the other
# Without TRIAL_TARGET an interactive run asks (Enter = host); a run without a terminal, with
# SILICA_TARGET_PROMPT=0, or with SILICA_COMPILER given on the command line (trials-gen1/gen2)
# runs on the host without asking. Only one trial run of any target may be in progress: the
# outermost integrate takes trials/.integrate.lock (runs started from a board run or a `both` run
# share their parent's lock through SILICA_INTEGRATE_LOCK_PID, and never dispatch again:
# SILICA_INTEGRATE_DISPATCHED). All of this happens before the directory's previous log and report
# are touched, so a board run leaves the host's results alone.
#
# Recipe lines that contain $(MAKE) are executed even under `make -n` (make passes -n
# down instead), so every such line here and in the fan-out Makefiles carries nothing
# but the sub-make and its output plumbing; file writes sit on their own lines. Under
# -n the wrapper only forwards the dry run to integrate-run and writes nothing.
integrate: ensure-silica-compiler
ifneq (,$(findstring n,$(firstword -$(MAKEFLAGS))))
	@$(MAKE) --no-print-directory -C "$(INTEGRATE_DIR)" -f "$(INTEGRATE_MAKEFILE)" integrate-run
else
	@if [ -z "$$SILICA_INTEGRATE_ROOT" ] && [ -z "$(TRIAL_MIRROR)" ] && [ -z "$$SILICA_INTEGRATE_DISPATCHED" ]; then \
		tt="$(_INTEGRATE_TRIALS_ROOT)/targets/trial_target.sh"; \
		trial_target="$(TRIAL_TARGET)"; \
		if [ -z "$$SILICA_INTEGRATE_LOCK_PID" ]; then bash "$$tt" check "$(INTEGRATE_LABEL)" || exit 1; fi; \
		if [ -z "$$trial_target" ]; then \
			if [ "$(SILICA_TARGET_PROMPT)" != 0 ] && [ -z "$(filter command line,$(origin SILICA_COMPILER))" ]; then \
				trial_target=$$(bash "$$tt" choose); \
			else \
				trial_target=host; \
			fi; \
		fi; \
		if [ "$$trial_target" != host ]; then \
			if [ -z "$$SILICA_INTEGRATE_LOCK_PID" ]; then \
				bash "$$tt" lock $$$$ "$(INTEGRATE_LABEL)" "$$trial_target" || exit 1; \
				export SILICA_INTEGRATE_LOCK_PID=$$$$; \
				trap 'bash "$$tt" unlock $$$$' EXIT; trap 'exit 130' INT TERM; \
			fi; \
			bash "$$tt" run "$$trial_target" "$(_INTEGRATE_DIR_NOSLASH)" "$(MAKE)"; \
			exit $$?; \
		fi; \
	fi; \
	date +%s > "$(INTEGRATE_DIR).integrate_start"; \
	rm -f "$(INTEGRATE_DIR).integrate_log" "$(INTEGRATE_DIR).integrate_status" "$(INTEGRATE_DIR).integrate_report" "$(INTEGRATE_DIR).integrate_skipped"; \
	if [ -n "$$SILICA_INTEGRATE_ROOT" ]; then \
		export SILICA_INTEGRATE_ACTIVE=1; \
		{ $(MAKE) --no-print-directory $(INTEGRATE_JOBFLAGS) -C "$(INTEGRATE_DIR)" -f "$(INTEGRATE_MAKEFILE)" integrate-run; \
		  echo $$? > "$(INTEGRATE_DIR).integrate_status"; } 2>&1 | tee -a "$(INTEGRATE_DIR).integrate_log"; \
		$(MAKE) --no-print-directory -C "$(INTEGRATE_DIR)" -f "$(INTEGRATE_MAKEFILE)" integrate-report; \
	else \
		own_lock=0; \
		if [ -z "$$SILICA_INTEGRATE_LOCK_PID" ]; then \
			bash "$(_INTEGRATE_TRIALS_ROOT)/targets/trial_target.sh" lock $$$$ "$(INTEGRATE_LABEL)" "$(if $(TRIAL_MIRROR),$(TRIAL_TARGET),host)" || exit 1; \
			own_lock=1; export SILICA_INTEGRATE_LOCK_PID=$$$$; \
		fi; \
		release_lock() { if [ "$$own_lock" = 1 ]; then bash "$(_INTEGRATE_TRIALS_ROOT)/targets/trial_target.sh" unlock $$$$; own_lock=0; fi; }; \
		trap 'release_lock' EXIT; \
		exec 9>&1; \
		export SILICA_INTEGRATE_ACTIVE=1 SILICA_INTEGRATE_ROOT="$(_INTEGRATE_DIR_NOSLASH)" SILICA_INTEGRATE_WATCHDOG_MINUTES="$(INTEGRATE_WATCHDOG_MINUTES)"; \
		rm -rf "$(INTEGRATE_RUNNING_DIR)"; mkdir -p "$(INTEGRATE_RUNNING_DIR)"; \
		: > "$(INTEGRATE_DIR).integrate_pass_marks"; : > "$(INTEGRATE_DIR).integrate_fail_marks"; \
		: "While the run owns the terminal, keystrokes are swallowed: echo off and canonical mode off so nothing is shown and the cursor stays put; isig stays on so Ctrl-C still kills. Anything typed is drained (min 0 time 0 + cat) before the settings are restored, so it cannot spill into the shell prompt."; \
		if [ -t 9 ]; then tty=1; else tty=0; fi; \
		saved_stty=""; \
		if [ "$$tty" = 1 ]; then \
			saved_stty=$$(stty -g < /dev/tty 2>/dev/null); \
			stty -echo -icanon min 1 time 0 < /dev/tty 2>/dev/null; \
		fi; \
		parent=$$$$; \
		( wd_secs=$$(( $(INTEGRATE_WATCHDOG_MINUTES) * 60 )); tick=0; \
		  while sleep 1; do \
			kill -0 "$$parent" 2>/dev/null || exit 0; \
			if [ "$$tty" = 1 ]; then $(call INTEGRATE_DRAW_COUNTS,$(INTEGRATE_DIR)); fi; \
			tick=$$((tick + 1)); [ $$((tick % 30)) -eq 0 ] || continue; \
			p=$$(stat -c %Y "$(INTEGRATE_DIR).integrate_pass_marks" 2>/dev/null || stat -f %m "$(INTEGRATE_DIR).integrate_pass_marks" 2>/dev/null || echo 0); f=$$(stat -c %Y "$(INTEGRATE_DIR).integrate_fail_marks" 2>/dev/null || stat -f %m "$(INTEGRATE_DIR).integrate_fail_marks" 2>/dev/null || echo 0); \
			last=$$p; [ "$$f" -gt "$$last" ] && last=$$f; now=$$(date +%s); \
			if [ $$((now - last)) -ge "$$wd_secs" ]; then \
				for reg in "$(INTEGRATE_RUNNING_DIR)"/*; do \
					[ -f "$$reg" ] || continue; case "$$reg" in *.killed) continue;; esac; \
					read -r pid label < "$$reg"; : > "$$reg.killed"; \
					kill -TERM -- "-$$pid" 2>/dev/null; sleep 5; kill -KILL -- "-$$pid" 2>/dev/null; \
				done; \
				touch "$(INTEGRATE_DIR).integrate_pass_marks"; \
			fi; \
		  done ) & wd_pid=$$!; \
		trap 'kill "$$wd_pid" 2>/dev/null; if [ -n "$$saved_stty" ]; then stty "$$saved_stty" < /dev/tty 2>/dev/null; fi; release_lock' INT TERM EXIT; \
		{ $(MAKE) --no-print-directory $(INTEGRATE_JOBFLAGS) -C "$(INTEGRATE_DIR)" -f "$(INTEGRATE_MAKEFILE)" integrate-run; \
		  echo $$? > "$(INTEGRATE_DIR).integrate_status"; } 2>&1 | tee -a "$(INTEGRATE_DIR).integrate_log" > /dev/null; \
		kill "$$wd_pid" 2>/dev/null; wait "$$wd_pid" 2>/dev/null; trap - INT TERM EXIT; trap 'release_lock' EXIT; \
		if [ -n "$$saved_stty" ]; then \
			stty -icanon min 0 time 0 < /dev/tty 2>/dev/null; cat < /dev/tty > /dev/null 2>&1; \
			stty "$$saved_stty" < /dev/tty 2>/dev/null; \
		fi; \
		rm -rf "$(INTEGRATE_RUNNING_DIR)"; \
		if [ "$$tty" = 1 ]; then $(call INTEGRATE_DRAW_COUNTS,$(INTEGRATE_DIR)); printf '\n' >&9; fi; \
		$(MAKE) --no-print-directory -C "$(INTEGRATE_DIR)" -f "$(INTEGRATE_MAKEFILE)" integrate-report; \
	fi
endif

integrate-report:
	@$(INTEGRATE_REPORT)

# Failure replay: every ❌ line in every .integrate_log under this directory, each
# followed by the context the recipe printed after it (the diff), capped at
# INTEGRATE_DETAIL_LINES lines. Deepest logs first, so the copy with the diff wins
# and the bare copies echoed by enclosing directories are dropped as duplicates.
# The board target mirrors the tree under trials/.target/<target>/ and its logs carry that target's
# label. A host run must not walk into it: doing so put board failures in the host report, where they
# looked like this machine's and drowned the real ones.
# A log under a directory this run skipped (.integrate_skipped, from INTEGRATE_PENDING) is from an
# earlier run, not this one: INTEGRATE_CHILD deletes such logs when it skips, and this filter drops
# any that survive (a log written after the skip, or a tree the skip did not clean), so the report
# lists only failures this run produced.
define INTEGRATE_FAILURE_DETAILS
logs=$$(find $(or $(INTEGRATE_LOG_ROOTS),"$(INTEGRATE_DIR)") -name '.target' -prune -o -name .integrate_log -print 2>/dev/null | awk '{ n = gsub("/", "/"); print n "\t" $$0 }' | sort -rn | cut -f2-); \
logs=$$(for l in $$logs; do d=$${l%/*}; keep=1; \
	while [ -n "$$d" ]; do \
		if [ -f "$$d/.integrate_skipped" ]; then keep=0; break; fi; \
		[ "$$d" = "$(_INTEGRATE_DIR_NOSLASH)" ] && break; \
		[ "$${d#"$(_INTEGRATE_DIR_NOSLASH)"/}" != "$$d" ] || break; d=$${d%/*}; \
	done; \
	[ "$$keep" = 1 ] && printf '%s\n' "$$l"; done); \
[ -n "$$logs" ] && awk -v cap="$(INTEGRATE_DETAIL_LINES)" ' \
	function flush() { if (blk != "") print blk; blk = "" } \
	FNR == 1 { flush(); skip = 1 } \
	/^(❌❌|❌ )|^ (❌❌|❌ )|^  (❌❌|❌ )/ { flush(); if ($$0 in seen) { skip = 1; next } seen[$$0] = 1; blk = $$0; n = 0; skip = 0; next } \
	/^(✅✅|✅ )|^ (✅✅|✅ )|^  (✅✅|✅ )|^(=== |SKIP:|Assembling|Linking|Running|Compiling|Reusing|make\[|════|success:|fail:|elapsed:|log:|failures:)/ { flush(); skip = 1; next } \
	{ if (!skip) { if (n < cap) blk = blk "\n" $$0; else if (n == cap) blk = blk "\n(... more in log)"; n++ } } \
	END { flush() }' $$logs
endef

define INTEGRATE_REPORT
cd "$(INTEGRATE_DIR)" || exit 1; \
st=$$(cat .integrate_status 2>/dev/null || echo 1); \
ok=0; ko=0; \
if [ -f .integrate_counts ]; then read ok ko < .integrate_counts || true; fi; \
ok=$${ok:-0}; ko=$${ko:-0}; \
if [ "$$st" -ne 0 ] && [ "$$ko" -eq 0 ]; then ko=1; fi; \
start=$$(cat .integrate_start 2>/dev/null || date +%s); now=$$(date +%s); el=$$((now - start)); \
if [ "$$el" -ge 3600 ]; then elapsed=$$(printf '%dh %02dm %02ds' $$((el / 3600)) $$((el % 3600 / 60)) $$((el % 60))); \
elif [ "$$el" -ge 60 ]; then elapsed=$$(printf '%dm %02ds' $$((el / 60)) $$((el % 60))); \
else elapsed=$$(printf '%ds' "$$el"); fi; \
{ \
	printf '════ integrate report: %s ════\n' "$(INTEGRATE_LABEL)"; \
	printf 'success: ✅✅ %s\n' "$$ok"; \
	printf 'fail: ❌❌ %s\n' "$$ko"; \
	printf 'elapsed: %s\n' "$$elapsed"; \
	if [ "$$ko" -ne 0 ]; then \
		printf 'failures:\n'; \
		details=$$({ $(INTEGRATE_FAILURE_DETAILS); }); \
		if [ -n "$$details" ]; then printf '%s\n' "$$details" | sed 's/^/    /'; \
		else printf '    (no ❌ line was printed; the run ended with status %s -- last %s lines of the log)\n' "$$st" "$(INTEGRATE_DETAIL_LINES)"; \
			tail -n "$(INTEGRATE_DETAIL_LINES)" .integrate_log 2>/dev/null | sed 's/^/    /'; fi; \
	fi; \
	printf 'log: %s\n' "$(INTEGRATE_DIR).integrate_log"; \
} > .integrate_report; \
if [ "$$SILICA_INTEGRATE_ROOT" = "$(_INTEGRATE_DIR_NOSLASH)" ]; then cat .integrate_report; fi; \
[ "$$ko" -eq 0 ] && [ "$$st" -eq 0 ]
endef

# $(call INTEGRATE_CHILD,<subdir relative to INTEGRATE_DIR>[,extra make args])
# Never fails the calling recipe: the parent sums the children's .integrate_counts
# afterwards and decides the exit status itself, so every sibling always runs.
define INTEGRATE_CHILD
cd "$(INTEGRATE_DIR)" || exit 1; \
dir="$(1)"; \
rm -f "$$dir/.integrate_counts" "$$dir/.integrate_report" "$$dir/.integrate_status" "$$dir/.integrate_skipped"; \
if [ -f "$$dir/INTEGRATE_PENDING" ] && [ -z "$(INTEGRATE_NAMED_SUITES)" ]; then \
	echo "SKIP: $$dir (INTEGRATE_PENDING -- see $$dir/README.md)"; \
	: > "$$dir/.integrate_skipped"; \
	find "$$dir" -name .target -prune -o \( -name .integrate_log -o -name .integrate_report -o -name .integrate_status \) -type f -exec rm -f {} + 2>/dev/null || true; \
else \
	$(MAKE) --no-print-directory -C "$$dir" integrate $(2) > /dev/null 2>&1; \
	if [ ! -f "$$dir/.integrate_report" ]; then \
		echo "❌❌ $$dir: integrate produced no report (make failed before reporting; see $$dir/.integrate_log)"; \
		$(INTEGRATE_DOT_FAIL); \
	fi; \
fi
endef

# Sum the .integrate_counts of listed child directories (skipped children are not
# counted; a child with no counts file and a non-zero status counts as one failure).
# $(call INTEGRATE_SUM_CHILDREN,<dirs>) -- leaves $ok / $ko / $failed set in the shell.
define INTEGRATE_SUM_CHILDREN
ok=0; ko=0; failed=0; \
printf '──── %s: per-directory results ────\n' "$(INTEGRATE_LABEL)"; \
for dir in $(1); do \
	if [ -f "$$dir/.integrate_skipped" ]; then \
		printf '  %-48s SKIPPED (INTEGRATE_PENDING)\n' "$$dir"; \
		continue; \
	fi; \
	n1=0; n2=0; \
	if [ -f "$$dir/.integrate_counts" ]; then read n1 n2 < "$$dir/.integrate_counts" || true; fi; \
	n1=$${n1:-0}; n2=$${n2:-0}; \
	cst=$$(cat "$$dir/.integrate_status" 2>/dev/null || echo 1); \
	if [ "$$cst" -ne 0 ] && [ "$$n2" -eq 0 ]; then n2=1; fi; \
	el=$$(sed -n 's/^elapsed: //p' "$$dir/.integrate_report" 2>/dev/null | head -1); \
	printf '  %-48s ✅✅ %6s  ❌❌ %6s  %s\n' "$$dir" "$$n1" "$$n2" "$$el"; \
	ok=$$((ok + n1)); ko=$$((ko + n2)); \
	[ "$$n2" -ne 0 ] && failed=1; \
done; \
printf '%d %d\n' "$$ok" "$$ko" > .integrate_counts
endef
