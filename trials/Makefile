# Makefile for Silica trials — `integrate` first ensures binaries/silica-compiler
# exists (same seed host as src), then runs each subdirectory's own
# Makefile (messages and pass/fail rules come from those Makefiles, not from here).
#
# integrate / clean: `make -C <trial> integrate|clean` for each immediate child with Makefile or makefile
# To refresh only silica.config in a trial: `make -C <trial> silica.config`
#
# Parallelism: the subdirectories run concurrently under one make jobserver
# (`make integrate` uses JOBS=<cores>; `make -j6 integrate` uses 6). Each subdirectory
# prints its own report when it finishes; the final report covers the whole tree.
# ordered_data_structures runs in its own, smaller pool (SDS_JOBS, default 4) because
# its per-unit compiles are memory-bound, not core-bound.
# Suites start largest first (by .silica file count; see TRIAL_ORDER below); `make print-trial-order`
# lists the order; ordered_data_structures is always first. The final report is alphabetical.
#
#   make integrate                       # everything, cores-wide
#   make integrate JOBS=4 SDS_JOBS=2     # gentler
#   make -C actors_addition integrate    # one suite, with its own report

# Immediate trial subdirs that contain Makefile or makefile (GNU make finds makefile in -C dir)
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)silica_compiler.mk

TRIAL_MAKEFILES := $(wildcard */Makefile */makefile)
TRIAL_SUBDIRS := $(sort $(foreach mf,$(TRIAL_MAKEFILES),$(notdir $(patsubst %/,%,$(dir $(mf))))))

# Largest suites first: make starts the prerequisites of integrate-dirs in list order as job slots
# free up, so the big suites begin at once and the many small ones fill the other cores meanwhile,
# instead of a few big suites forming a tail at the end of the run. Size = number of .silica files
# under the suite (nested suites and apps included), a cheap deterministic estimate that needs no
# earlier run; ties break alphabetically. Plain POSIX find/wc/tr/sort/awk (BSD and GNU alike), and
# only make 3.81 functions. `make print-trial-order` shows the order with the sizes.
# The final report lists the suites alphabetically (TRIAL_REPORT_ORDER), not in start order.
SDS_DIR := ordered_data_structures
TRIAL_SIZED := $(shell for d in $(TRIAL_SUBDIRS); do \
	printf '%s %s\n' "$$(find "$(THIS_DIR)$$d" -name '*.silica' -type f | wc -l | tr -d ' ')" "$$d"; \
	done | LC_ALL=C sort -k1,1nr -k2,2 | awk '{print $$1 ":" $$2}')
# ordered_data_structures is pinned first whatever its size: its own memory-bound pool makes it
# a long suite, so it must not start late (a TRIAL_SUITES filter below drops it if not selected).
TRIAL_SIZED := $(filter %:$(SDS_DIR),$(TRIAL_SIZED)) $(filter-out %:$(SDS_DIR),$(TRIAL_SIZED))
TRIAL_ORDER := $(foreach e,$(TRIAL_SIZED),$(word 2,$(subst :, ,$(e))))
TRIAL_REPORT_ORDER := $(TRIAL_SUBDIRS)

# TRIAL_SUITES="a b" limits a host tree run to the named suites (the board target reads the same
# variable in targets/trial_target.sh). A name that is not a suite is an error. A named suite runs
# even when it has INTEGRATE_PENDING (INTEGRATE_NAMED_SUITES tells INTEGRATE_CHILD so); the
# failure report then replays only the named suites' logs, not stale ones from other suites.
# Unset, nothing here changes. Board mirrors (TRIAL_MIRROR) are driven by trial_target.sh instead.
ifneq ($(strip $(TRIAL_SUITES)),)
ifeq ($(strip $(TRIAL_MIRROR)),)
$(foreach s,$(TRIAL_SUITES),$(if $(filter $(s),$(TRIAL_SUBDIRS)),,$(error TRIAL_SUITES: no suite named $(s))))
TRIAL_ORDER := $(filter $(TRIAL_SUITES),$(TRIAL_ORDER))
TRIAL_REPORT_ORDER := $(filter $(TRIAL_SUITES),$(TRIAL_REPORT_ORDER))
INTEGRATE_NAMED_SUITES := 1
INTEGRATE_LOG_ROOTS := "$(THIS_DIR).integrate_log" $(foreach s,$(TRIAL_ORDER),"$(THIS_DIR)$(s)")
endif
endif
INTEGRATE_DIR_TARGETS := $(TRIAL_ORDER:%=integrate-dir-%)

.PHONY: print-trial-order integrate-run integrate-prepare integrate-dirs integrate-summary integrate-ffi clean help $(INTEGRATE_DIR_TARGETS)

.DEFAULT_GOAL := integrate

# integrate (wrapper in silica_compiler.mk) -> integrate-run:
#   prepare once (serial), fan out over the suites (parallel), then summarise.
# `integrate-dirs` is a sub-make so the fan-out cannot start before prepare finishes.
integrate-run: integrate-prepare
	@$(MAKE) --no-print-directory -f "$(INTEGRATE_MAKEFILE)" integrate-dirs || true
	@$(MAKE) --no-print-directory -f "$(INTEGRATE_MAKEFILE)" integrate-summary

# Shared state that several suites would otherwise build concurrently:
#   - the ffi wrapper archives (ffi_addition and warning_enforcement_addition both build them)
#   - the published iface cache
# Each suite cleans its own directory inside its own integrate-run, so no tree-wide
# `make clean` sweep runs here.
integrate-prepare:
	@rm -rf "$(THIS_DIR).cache/ifaces"
	@rm -f $(TRIAL_SUBDIRS:%=$(THIS_DIR)%/.integrate_counts)
	@$(MAKE) --no-print-directory -C "$(THIS_DIR)ffi_addition" fixtures

integrate-dirs: $(INTEGRATE_DIR_TARGETS)

# One rule per suite. Never fails: the summary decides the exit status, so every suite runs.
$(INTEGRATE_DIR_TARGETS): integrate-dir-%:
	@$(call INTEGRATE_CHILD,$*,$(if $(filter $*,$(SDS_DIR)),-j$(SDS_JOBS)))

integrate-summary:
	@cd "$(THIS_DIR)" && $(call INTEGRATE_SUM_CHILDREN,$(TRIAL_REPORT_ORDER)); \
	[ "$$ko" -eq 0 ] && [ "$$failed" -eq 0 ]

# print-trial-order: the order the suites are handed to the jobserver (size = .silica files).
print-trial-order:
	@for e in $(TRIAL_SIZED); do printf '%7s  %s\n' "$${e%%:*}" "$${e#*:}"; done

# integrate-ffi: success-path FFI app trials only (same as make -C ffi_addition integrate).
# Compile/link failure goldens live under error_enforcement_addition/ffi_addition integrate.
integrate-ffi: ensure-silica-compiler
	@$(call INTEGRATE_CHILD,ffi_addition)
	@cd "$(THIS_DIR)" && $(call INTEGRATE_SUM_CHILDREN,ffi_addition); \
	[ "$$ko" -eq 0 ] && [ "$$failed" -eq 0 ]

# clean: delegate so each trial removes what its Makefile defines (same dirs as integrate),
# then drop any published *.iface caches under the trials tree.
clean:
	@failed=0; \
	for dir in $(TRIAL_SUBDIRS); do \
		echo "Cleaning $$dir..."; \
		$(MAKE) -C $$dir clean || failed=1; \
	done; \
	echo "Removing *.iface and .cache/ifaces under trials..."; \
	rm -rf "$(THIS_DIR).cache/ifaces"; \
	find "$(THIS_DIR)" -name '*.iface' -type f -delete 2>/dev/null || true; \
	find "$(THIS_DIR)" \( -name '.integrate_log' -o -name '.integrate_report' -o -name '.integrate_status' \
		-o -name '.integrate_start' -o -name '.integrate_results' -o -name '.integrate_skipped' \
		-o -name '.integrate_pass_marks' -o -name '.integrate_fail_marks' \) -type f -delete 2>/dev/null || true; \
	find "$(THIS_DIR)" -name '.integrate_running' -type d -prune -exec rm -rf {} + 2>/dev/null || true; \
	exit $$failed

help:
	@echo "Silica trials"
	@echo "  make integrate                 run every suite in parallel (JOBS=$(JOBS), SDS_JOBS=$(SDS_JOBS)), report per suite and overall"
	@echo "                                 (interactive: asks where to run the trials; Enter = this host: macOS, Linux x86-64 or Linux AArch64)"
	@echo "  make integrate TRIAL_TARGET=T  T = host, linux_aarch64, linux_x86_64, ESP32-S3_raw, STM32-L476RG_raw, all, both, or a list; see targets/README.md"
	@echo "  make integrate TRIAL_SUITES=\"a b\"                         only these suites (host or board; a named suite runs even if INTEGRATE_PENDING)"
	@echo "  make print-trial-order         suites in start order (ordered_data_structures first, then largest first, with .silica counts)"
	@echo "  make integrate JOBS=N         cap the parallel pool"
	@echo "  make integrate SDS_JOBS=N      cap ordered_data_structures separately (memory-bound)"
	@echo "  make -C <suite> integrate      one suite; prints that suite's own report"
	@echo "  make integrate INTEGRATE_WATCHDOG_MINUTES=N   kill running trials after N minutes without a result (default 15)"
	@echo "  make integrate-ffi             ffi_addition success-path apps only"
	@echo "  make clean                     clean every suite"
	@echo "  bash targets/trial_target.sh status   which trial runs hold a lock (one lock per target), if any"
	@echo "Suites: $(TRIAL_SUBDIRS)"
