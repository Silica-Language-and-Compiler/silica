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
#
#   make integrate                       # everything, cores-wide
#   make integrate JOBS=4 SDS_JOBS=2     # gentler
#   make -C actors_addition integrate    # one suite, with its own report

# Immediate trial subdirs that contain Makefile or makefile (GNU make finds makefile in -C dir)
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)silica_compiler.mk

TRIAL_MAKEFILES := $(wildcard */Makefile */makefile)
TRIAL_SUBDIRS := $(sort $(foreach mf,$(TRIAL_MAKEFILES),$(notdir $(patsubst %/,%,$(dir $(mf))))))

# Longest jobs first: make starts prerequisites in list order, so the heavy suites
# begin immediately instead of forming a tail behind the small ones.
SDS_DIR := ordered_data_structures
HEAVY_FIRST := $(SDS_DIR) error_enforcement_addition
TRIAL_ORDER := $(filter $(HEAVY_FIRST),$(TRIAL_SUBDIRS)) $(filter-out $(HEAVY_FIRST),$(TRIAL_SUBDIRS))

# TRIAL_SUITES="a b" limits a host tree run to the named suites (the board target reads the same
# variable in targets/trial_target.sh). A name that is not a suite is an error. A named suite runs
# even when it has INTEGRATE_PENDING (INTEGRATE_NAMED_SUITES tells INTEGRATE_CHILD so); the
# failure report then replays only the named suites' logs, not stale ones from other suites.
# Unset, nothing here changes. Board mirrors (TRIAL_MIRROR) are driven by trial_target.sh instead.
ifneq ($(strip $(TRIAL_SUITES)),)
ifeq ($(strip $(TRIAL_MIRROR)),)
$(foreach s,$(TRIAL_SUITES),$(if $(filter $(s),$(TRIAL_SUBDIRS)),,$(error TRIAL_SUITES: no suite named $(s))))
TRIAL_ORDER := $(filter $(TRIAL_SUITES),$(TRIAL_ORDER))
INTEGRATE_NAMED_SUITES := 1
INTEGRATE_LOG_ROOTS := "$(THIS_DIR).integrate_log" $(foreach s,$(TRIAL_ORDER),"$(THIS_DIR)$(s)")
endif
endif
INTEGRATE_DIR_TARGETS := $(TRIAL_ORDER:%=integrate-dir-%)

.PHONY: integrate-run integrate-prepare integrate-dirs integrate-summary integrate-ffi clean help $(INTEGRATE_DIR_TARGETS)

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
	@cd "$(THIS_DIR)" && $(call INTEGRATE_SUM_CHILDREN,$(TRIAL_ORDER)); \
	[ "$$ko" -eq 0 ] && [ "$$failed" -eq 0 ]

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
	@echo "  make integrate TRIAL_TARGET=T  T = host, ESP32-S3_raw (a board on USB) or both; see targets/README.md"
	@echo "  make integrate TRIAL_SUITES=\"a b\"                         only these suites (host or board; a named suite runs even if INTEGRATE_PENDING)"
	@echo "  make integrate JOBS=N          cap the parallel pool"
	@echo "  make integrate SDS_JOBS=N      cap ordered_data_structures separately (memory-bound)"
	@echo "  make -C <suite> integrate      one suite; prints that suite's own report"
	@echo "  make integrate INTEGRATE_WATCHDOG_MINUTES=N   kill running trials after N minutes without a result (default 15)"
	@echo "  make integrate-ffi             ffi_addition success-path apps only"
	@echo "  make clean                     clean every suite"
	@echo "  bash targets/trial_target.sh status   which trial run holds the lock, if any"
	@echo "Suites: $(TRIAL_SUBDIRS)"
