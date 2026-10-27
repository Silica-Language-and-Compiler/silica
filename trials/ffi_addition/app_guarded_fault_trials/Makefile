THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_guarded_fault_trials
APP_EXECUTABLES := \
	dangerous_guarded_null_deref_fault \
	dangerous_guarded_arena_bounds_fault \
	dangerous_guarded_sigbus_fault \
	dangerous_guarded_sigill_fault \
	dangerous_guarded_sigfpe_fault \
	dangerous_handler_altstack_stack_overflow_smoke \
	dangerous_unguarded_null_deref_abort

FFI_TRIAL_DIR := $(abspath $(THIS_DIR)/..)
include $(THIS_DIR)../../silica_compiler.mk
FIXTURES_DIR := $(FFI_TRIAL_DIR)/fixtures
SILICA_LINK_SH := $(abspath $(FFI_TRIAL_DIR)/../silica_link.sh)
UNGUARDED_PROBE := $(THIS_DIR)/unguarded_null_deref_probe

include $(FFI_TRIAL_DIR)/fixtures.mk

ARCH := arm64
MACOS_MIN_VERSION := 26.0
ASFLAGS := -mmacosx-version-min=$(MACOS_MIN_VERSION)
# macOS needs -arch/-mmacosx-version-min; the Linux driver rejects both, and glibc hides
# mkstemp and friends under strict -std=c11 unless _GNU_SOURCE is defined.
ifeq ($(shell uname -s),Darwin)
  FFI_HOST_CFLAGS := -arch $(or $(FFI_ARCH),$(ARCH)) -mmacosx-version-min=$(or $(MACOS_MIN_VERSION),26.0)
else
  FFI_HOST_CFLAGS := -D_GNU_SOURCE
endif
FFI_CFLAGS := -std=c11 -Wall -Wextra -O0 $(FFI_HOST_CFLAGS) \
	-I$(FIXTURES_DIR)/dangerous_exposure_source/legacy

RUST_SYSROOT := $(shell rustc --print sysroot 2>/dev/null)
RUST_TARGET := $(shell rustc -vV 2>/dev/null | sed -n "s/^host: *//p")
RUST_LLD := $(RUST_SYSROOT)/lib/rustlib/$(RUST_TARGET)/bin/rust-lld
MACOS_SDK := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
LDFLAGS_rust-lld := -arch $(ARCH) -platform_version macos $(MACOS_MIN_VERSION) $(MACOS_MIN_VERSION) -syslibroot $(MACOS_SDK) -lSystem -e main
LDFLAGS_clang := -Wl,-e,main -Wl,-macos_version_min,$(MACOS_MIN_VERSION)

.PHONY: all integrate clean fixtures unguarded_probe altstack_check

all: integrate

fixtures: ffi-wrapper-archives

# A probe that is not a native executable (a Mach-O copied to Linux, or an ELF to the Mac) is deleted when
# this Makefile is read, so the rule below sees it missing and rebuilds it whatever the mtimes say.
# Parse time, because make would already have judged the file up to date by its mtime. $(shell) uses
# /bin/sh (dash on the hosts): no parentheses, make would miscount them.
ifeq ($(shell uname -s),Darwin)
  NATIVE_EXE_FORMAT := Mach-O
else
  NATIVE_EXE_FORMAT := ELF
endif
PROBE_FOREIGN := $(shell if [ -e '$(UNGUARDED_PROBE)' ] && ! file -L '$(UNGUARDED_PROBE)' 2>/dev/null | grep -q '$(NATIVE_EXE_FORMAT)'; then rm -f '$(UNGUARDED_PROBE)'; echo removed; fi)

$(UNGUARDED_PROBE): $(FIXTURES_DIR)/src/silica_ffi_fault.c $(THIS_DIR)unguarded_null_deref_main.c
	clang $(FFI_CFLAGS) -c $(FIXTURES_DIR)/src/silica_ffi_fault.c -o $(THIS_DIR)/silica_ffi_fault.o
	clang $(FFI_CFLAGS) $(THIS_DIR)/unguarded_null_deref_main.c $(THIS_DIR)/silica_ffi_fault.o -o $@

unguarded_probe: $(UNGUARDED_PROBE)

altstack_check: dangerous_guarded_null_deref_fault
	@nm "$(APP_TRIAL_DIR)/dangerous_guarded_null_deref_fault" 2>/dev/null | grep -Eq '(^|[^A-Za-z0-9_])_?silica_rt_ffi_altstack_mem' || { echo "  ❌ altstack symbol missing"; exit 1; }
	@echo "  ✅ altstack memory symbol present"

integrate-run: fixtures unguarded_probe
	@ln -sfn "$(FFI_SOURCE_VIEW)" "$(APP_TRIAL_DIR)/dangerous_exposure_source"
	@test -f "$(FFI_LEGACY_ARCHIVE)" || { echo "  ❌ $(APP_LABEL): missing legacy archive"; exit 1; }
	@cd "$(APP_TRIAL_DIR)" && $(call TRIAL_RM_UNTRACKED,$(APP_EXECUTABLES)); rm -f *.sams *.o *.iface  silica.config silica.link .integrate_counts silica.compile.order silica.needs_runtime silica.atoms
	@cd "$(APP_TRIAL_DIR)" && find "$(APP_TRIAL_DIR)" -maxdepth 1 -name '*.silica' ! -name 'dangerous_unguarded_null_deref_abort.silica' | sed "s|^$(APP_TRIAL_DIR)/||" | sort > silica.config && $(TRIAL_SUPPORT_CONFIG)
	@$(ENSURE_SILICA_COMPILER)
	@cd "$(APP_TRIAL_DIR)" && if ! { $(RUN_SILICA_COMPILER_ISOLATING); }; then echo "❌❌ $(APP_LABEL): compilation failed"; $(INTEGRATE_DOT_FAIL); printf '%d %d\n' 0 1 > .integrate_counts; exit 1; fi
	@failed=0; ok=0; ko=0; bf=""; \
	cd "$(APP_TRIAL_DIR)"; \
	$(call INTEGRATE_COMPILE_REJECTS,$(APP_LABEL)/); \
	link_archives=$$("$(SILICA_LINK_SH)" .); \
	for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		[ "$$base" = "__silica_runtime" ] && continue; \
		if [ ! -f "$$base$(ASCOMP_EXT)" ]; then \
			echo "  ❌ $(APP_LABEL)/$$base: missing .ascomp"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		elif ! diff -Bw -q "$$sams" "$$base$(ASCOMP_EXT)" > /dev/null 2>&1; then \
			echo "  ❌ $(APP_LABEL)/$$base .sams differs from .ascomp"; \
			$(INTEGRATE_DOT_FAIL); \
			diff -Bw "$$sams" "$$base$(ASCOMP_EXT)" || true; \
			ko=$$((ko + 1)); failed=1; \
		else \
			echo "  ✅✅ $(APP_LABEL)/$$base assembly matches .ascomp"; \
			$(INTEGRATE_DOT_OK); \
			ok=$$((ok + 1)); \
		fi; \
	done; \
	for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		echo "Assembling $$sams..."; \
		if ! clang $(ASFLAGS) -c -x assembler "$$sams" -o "$$base.o"; then \
		echo "❌❌ $(APP_LABEL)/$$base assemble failed"; \
		$(INTEGRATE_DOT_FAIL); \
		bf="$$bf $$base "; ko=$$((ko + 1)); failed=1; \
	fi; \
	done; \
	$(TRIAL_SUPPORT_ASSEMBLE); \
	rejected_units=$$(cut -f1 silica.compile.rejected 2>/dev/null); \
	for trial in dangerous_guarded_null_deref_fault dangerous_guarded_arena_bounds_fault dangerous_guarded_sigbus_fault dangerous_guarded_sigill_fault dangerous_guarded_sigfpe_fault dangerous_handler_altstack_stack_overflow_smoke; do \
		: "Each trial stands alone: a rejected, unassembled, unlinked or failing trial is reported once and the loop moves on."; \
		if printf '%s\n' "$$rejected_units" | grep -qxF "$$trial.silica"; then continue; fi; \
		case "$$bf" in *" $$trial "*) echo "$(APP_LABEL)/$$trial not run: assemble failed (reported above)"; continue;; esac; \
		linked=1; ran=0; \
		runtime_obj=""; [ -f __silica_runtime.o ] && runtime_obj=__silica_runtime.o; \
		runtime_obj="$$runtime_obj $(call TRIAL_SUPPORT_OBJ,$$trial.silica)"; \
		if test -x "$(RUST_LLD)"; then \
						if ! "$(RUST_LLD)" -flavor darwin -o "$$trial" "$$trial.o" $$runtime_obj $$link_archives $(LDFLAGS_rust-lld); then \
				echo "❌❌ $(APP_LABEL)/$$trial link failed"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; linked=0; \
			fi; \
		else \
						if ! clang "$$trial.o" $$runtime_obj $$link_archives -o "$$trial" $(LDFLAGS_clang); then \
				echo "❌❌ $(APP_LABEL)/$$trial link failed"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; linked=0; \
			fi; \
		fi; \
		[ "$$linked" = 1 ] || continue; ran=1; \
		if [ -f "$$trial.wait_for_exit" ]; then \
			marker=$$(awk 'NF { if ($$NF ~ /^[0-9]+$$/) { m=$$0; sub(/[ \t]+[0-9]+$$/, "", m); print m } else print $$0; exit } END { if (!NR) print "done" }' "$$trial.wait_for_exit"); \
			marker_count=$$(awk 'NF { if ($$NF ~ /^[0-9]+$$/) print $$NF; else print 1; exit } END { if (!NR) print 1 }' "$$trial.wait_for_exit"); \
			$(call INTEGRATE_EXEC_TRIAL,$(APP_LABEL)/$$trial,python3 "$(FFI_TRIAL_DIR)/run_integration_exit_after_marker.py" "$(APP_TRIAL_DIR)" "$$trial" "$$trial.sout" "$$marker" "$$marker_count"); \
			if [ "$$integrate_killed" = 1 ]; then \
				echo "❌❌ $(APP_LABEL)/$$trial $(INTEGRATE_KILLED_MSG)"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; ran=0; \
			elif [ "$$integrate_rc" -ne 0 ]; then \
			echo "❌❌ $(APP_LABEL)/$$trial run failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; ran=0; \
		fi; \
		else \
			$(call INTEGRATE_RUN_TRIAL,$(APP_LABEL)/$$trial,$$trial.sout,./$$trial); \
			if [ "$$integrate_killed" = 1 ]; then \
				echo "❌❌ $(APP_LABEL)/$$trial $(INTEGRATE_KILLED_MSG)"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; ran=0; \
			elif false; then \
			echo "❌❌ $(APP_LABEL)/$$trial run failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; ran=0; \
		fi; \
		fi; \
		[ "$$ran" = 1 ] || continue; \
		if [ ! -f "$(call SCOUT_FOR,$$trial)" ]; then \
			echo "  ❌ $(APP_LABEL)/$$trial: missing .scout"; ko=$$((ko + 1)); failed=1; \
			$(INTEGRATE_DOT_FAIL); \
		elif [ -f "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" ] && ! "$(SHELL)" "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" "$$trial.sout" "$(call SCOUT_FOR,$$trial)" > /dev/null 2>&1; then \
			echo "  ❌ $(APP_LABEL)/$$trial .sout differs from .scout (normalized compare)"; \
			$(INTEGRATE_DOT_FAIL); \
			"$(SHELL)" "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" "$$trial.sout" "$(call SCOUT_FOR,$$trial)" || true; \
			ko=$$((ko + 1)); failed=1; \
		elif [ ! -f "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" ] && ! diff -Bw -q "$$trial.sout" "$(call SCOUT_FOR,$$trial)" > /dev/null 2>&1; then \
			echo "  ❌ $(APP_LABEL)/$$trial .sout differs from .scout"; \
			$(INTEGRATE_DOT_FAIL); \
			diff -Bw "$$trial.sout" "$(call SCOUT_FOR,$$trial)" || true; \
			ko=$$((ko + 1)); failed=1; \
		else \
			echo "  ✅✅ $(APP_LABEL)/$$trial output matches .scout"; \
			$(INTEGRATE_DOT_OK); \
			ok=$$((ok + 1)); \
		fi; \
	done; \
	if [ "$$failed" -eq 0 ] && ! $(MAKE) -C "$(APP_TRIAL_DIR)" altstack_check; then \
		echo "❌❌ $(APP_LABEL)/altstack_check failed"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + 1)); failed=1; \
	fi; \
	if [ "$$failed" -eq 0 ]; then \
		$(call INTEGRATE_EXEC_TRIAL,$(APP_LABEL)/unguarded_probe,python3 "$(FFI_TRIAL_DIR)/run_integration_expect_crash.py" "$(UNGUARDED_PROBE)"); \
		if [ "$$integrate_killed" = 1 ]; then \
			echo "❌❌ $(APP_LABEL)/unguarded_probe $(INTEGRATE_KILLED_MSG)"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		elif [ "$$integrate_rc" -eq 0 ]; then \
			echo "  ✅✅ $(APP_LABEL)/unguarded_null_deref_abort crash probe OK"; \
			$(INTEGRATE_DOT_OK); \
			ok=$$((ok + 1)); \
		else \
			echo "❌❌ $(APP_LABEL)/unguarded_null_deref_abort crash probe failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		fi; \
	fi; \
	printf '%d %d\n' "$$ok" "$$ko" > .integrate_counts; \
	exit $$failed

clean:
	@cd "$(THIS_DIR)" && $(call TRIAL_RM_UNTRACKED,$(APP_EXECUTABLES) dangerous_exposure_source $(UNGUARDED_PROBE) unguarded_sigill_probe); rm -rf *.sams *.o *.iface  silica.config silica.link .integrate_counts silica.compile.order silica.needs_runtime silica.atoms *.sout .trial_stdlib silica_ffi_fault.o
