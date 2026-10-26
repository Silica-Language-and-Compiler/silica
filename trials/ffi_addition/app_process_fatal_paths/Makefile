# Process-fatal paths that a Silica program cannot reach from its own source (spec §15.4.5.5):
#
#   fault_before_main     a fault raised before main runs; the startup code has already installed the
#                         fault handlers, so it is reported like any other fatal fault (line + 70).
#   fault_inside_handler  a fault raised while the fault handler itself runs; it takes the last-resort
#                         path (line + 70) instead of the default action of a blocked signal (139).
#   foreign_fault_without_actor  a fault in guarded foreign code with no current actor: a fatal fault
#                         (line + 70), not the old "foreign_fault" + exit 1.
#
# Each program is an ordinary Silica main linked with one C object, <trial>_probe.c. The probe object is
# linked AFTER the Silica runtime object, so its constructor runs after the runtime's constructor
# (Mach-O __mod_init_func and ELF .init_array both run in link order) and before main. That link
# order is why this app has its own recipe instead of common_app.mk, which links extra objects first.
# The .scout goldens are hand-derived in the folded form of ../../normalize_fatal_reports.awk.
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_process_fatal_paths
APP_EXECUTABLES := fault_before_main fault_inside_handler foreign_fault_without_actor

FFI_TRIAL_DIR := $(abspath $(THIS_DIR)/..)
include $(THIS_DIR)../../silica_compiler.mk

MACOS_MIN_VERSION := 26.0
ASFLAGS := -mmacosx-version-min=$(MACOS_MIN_VERSION)
LDFLAGS_clang := -Wl,-e,main -Wl,-macos_version_min,$(MACOS_MIN_VERSION)
ifeq ($(shell uname -s),Darwin)
  PROBE_CFLAGS := -std=gnu11 -Wall -Wextra -O0 -arch arm64 -mmacosx-version-min=$(MACOS_MIN_VERSION)
else
  PROBE_CFLAGS := -std=gnu11 -Wall -Wextra -O0 -D_GNU_SOURCE
  # linux_host.mk overrides LDFLAGS_clang (-no-pie -rdynamic -lpthread) and ASFLAGS.
  ASFLAGS :=
endif

.PHONY: all integrate clean

all: integrate

integrate-run:
	@$(ENSURE_SILICA_COMPILER)
	@cd "$(APP_TRIAL_DIR)" && rm -f *.sams *.o *.iface $(APP_EXECUTABLES) silica.config silica.link .integrate_counts silica.compile.order silica.needs_runtime silica.atoms
	@cd "$(APP_TRIAL_DIR)" && find "$(APP_TRIAL_DIR)" -maxdepth 1 -name '*.silica' | sed "s|^$(APP_TRIAL_DIR)/||" | sort > silica.config
	@cd "$(APP_TRIAL_DIR)" && if ! { $(RUN_SILICA_COMPILER); }; then echo "❌❌ $(APP_LABEL): compilation failed"; $(INTEGRATE_DOT_FAIL); printf '%d %d\n' 0 1 > .integrate_counts; exit 1; fi
	@failed=0; ok=0; ko=0; \
	cd "$(APP_TRIAL_DIR)"; \
	for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		[ "$$base" = "__silica_runtime" ] && continue; \
		if [ ! -f "$$base$(ASCOMP_EXT)" ]; then \
			echo "  ❌ $(APP_LABEL)/$$base: missing $(ASCOMP_EXT)"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		elif ! diff -Bw -q "$$sams" "$$base$(ASCOMP_EXT)" > /dev/null 2>&1; then \
			echo "  ❌ $(APP_LABEL)/$$base .sams differs from $(ASCOMP_EXT)"; \
			$(INTEGRATE_DOT_FAIL); \
			diff -Bw "$$sams" "$$base$(ASCOMP_EXT)" || true; \
			ko=$$((ko + 1)); failed=1; \
		else \
			echo "  ✅✅ $(APP_LABEL)/$$base assembly matches $(ASCOMP_EXT)"; \
			$(INTEGRATE_DOT_OK); \
			ok=$$((ok + 1)); \
		fi; \
	done; \
	if [ "$(SILICA_TARGET_IS_HOST)" != 1 ]; then \
		echo "  $(APP_LABEL): $(SILICA_CROSS_NOTE)"; \
		printf '%d %d\n' "$$ok" "$$ko" > .integrate_counts; exit $$failed; \
	fi; \
	for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		if ! clang $(ASFLAGS) -c -x assembler "$$sams" -o "$$base.o"; then \
			echo "❌❌ $(APP_LABEL)/$$base assemble failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		fi; \
	done; \
	for trial in $(APP_EXECUTABLES); do \
		[ -f "$$trial.o" ] || continue; \
		if ! clang $(PROBE_CFLAGS) -c "$${trial}_probe.c" -o "$${trial}_probe.o"; then \
			echo "❌❌ $(APP_LABEL)/$$trial probe compile failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; continue; \
		fi; \
		if ! clang "$$trial.o" __silica_runtime.o "$${trial}_probe.o" -o "$$trial" $(LDFLAGS_clang); then \
			echo "❌❌ $(APP_LABEL)/$$trial link failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; continue; \
		fi; \
		$(call INTEGRATE_RUN_TRIAL,$(APP_LABEL)/$$trial,$$trial.sout,./$$trial); \
		if [ "$$integrate_killed" = 1 ]; then \
			echo "❌❌ $(APP_LABEL)/$$trial $(INTEGRATE_KILLED_MSG)"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; continue; \
		fi; \
		if "$(SHELL)" "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" "$$trial.sout" "$(call SCOUT_FOR,$$trial)" > /dev/null 2>&1; then \
			echo "  ✅✅ $(APP_LABEL)/$$trial output matches .scout"; \
			$(INTEGRATE_DOT_OK); \
			ok=$$((ok + 1)); \
		else \
			echo "  ❌ $(APP_LABEL)/$$trial .sout differs from .scout (normalized compare)"; \
			$(INTEGRATE_DOT_FAIL); \
			"$(SHELL)" "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" "$$trial.sout" "$(call SCOUT_FOR,$$trial)" || true; \
			ko=$$((ko + 1)); failed=1; \
		fi; \
	done; \
	printf '%d %d\n' "$$ok" "$$ko" > .integrate_counts; \
	exit $$failed

clean:
	@cd "$(THIS_DIR)" && rm -f *.sams *.o *.iface $(APP_EXECUTABLES) silica.config silica.link .integrate_counts silica.compile.order silica.needs_runtime silica.atoms *.sout
