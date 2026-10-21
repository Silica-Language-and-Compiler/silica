THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_dangerous_spawn_thread_limit
APP_EXECUTABLES := dangerous_spawn_thread_limit

FFI_TRIAL_DIR := $(abspath $(THIS_DIR)/..)
include $(THIS_DIR)../../silica_compiler.mk
FIXTURES_DIR := $(FFI_TRIAL_DIR)/fixtures
SILICA_LINK_SH := $(abspath $(FFI_TRIAL_DIR)/../silica_link.sh)

include $(FFI_TRIAL_DIR)/fixtures.mk

ARCH := arm64
MACOS_MIN_VERSION := 26.0
ASFLAGS := -mmacosx-version-min=$(MACOS_MIN_VERSION)

RUST_SYSROOT := $(shell rustc --print sysroot 2>/dev/null)
RUST_TARGET := $(shell rustc -vV 2>/dev/null | sed -n "s/^host: *//p")
RUST_LLD := $(RUST_SYSROOT)/lib/rustlib/$(RUST_TARGET)/bin/rust-lld
MACOS_SDK := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
LDFLAGS_rust-lld := -arch $(ARCH) -platform_version macos $(MACOS_MIN_VERSION) $(MACOS_MIN_VERSION) -syslibroot $(MACOS_SDK) -lSystem -e main
LDFLAGS_clang := -Wl,-e,main -Wl,-macos_version_min,$(MACOS_MIN_VERSION)

.PHONY: all integrate clean fixtures

all: integrate

fixtures: ffi-wrapper-archives

integrate-run: fixtures
	@ln -sfn "$(FFI_SOURCE_VIEW)" "$(APP_TRIAL_DIR)/dangerous_exposure_source"
	@test -f "$(FFI_LEGACY_ARCHIVE)" || { echo "  ❌ $(APP_LABEL): missing legacy archive"; exit 1; }
	@cd "$(APP_TRIAL_DIR)" && rm -f *.sams *.o *.iface $(APP_EXECUTABLES) silica.config silica.link .integrate_counts silica.compile.order silica.needs_runtime silica.atoms
	@cd "$(APP_TRIAL_DIR)" && { \
		find "$(APP_TRIAL_DIR)" -maxdepth 1 -name '*.silica' | sed "s|^$(APP_TRIAL_DIR)/||" | sort; \
		echo "../../../compiler/stdlib/Supervisor.silica"; \
	} > silica.config && $(TRIAL_PRIVATE_SUPERVISOR)
	@$(ENSURE_SILICA_COMPILER)
	@cd "$(APP_TRIAL_DIR)" && if ! { $(RUN_SILICA_COMPILER); }; then echo "❌❌ $(APP_LABEL): compilation failed"; $(INTEGRATE_DOT_FAIL); printf '%d %d\n' 0 1 > .integrate_counts; exit 1; fi
	@failed=0; ok=0; ko=0; \
	cd "$(APP_TRIAL_DIR)"; \
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
		echo "❌❌ $$base assemble failed"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + 1)); failed=1; break; \
	fi; \
	done; \
	[ -f __silica_runtime.sams ] && clang $(ASFLAGS) -c -x assembler __silica_runtime.sams -o __silica_runtime.o || true; \
	for trial in $(APP_EXECUTABLES); do \
		[ "$$failed" -ne 0 ] && break; \
		runtime_obj=""; \
		[ -f __silica_runtime.o ] && runtime_obj=__silica_runtime.o; \
		if test -x "$(RUST_LLD)"; then \
						if ! "$(RUST_LLD)" -flavor darwin -o "$$trial" "$$trial.o" $$runtime_obj $$link_archives $(LDFLAGS_rust-lld); then \
				echo "❌❌ $(APP_LABEL)/$$trial link failed"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; \
			fi; \
		else \
						if ! clang "$$trial.o" $$runtime_obj $$link_archives -o "$$trial" $(LDFLAGS_clang); then \
				echo "❌❌ $(APP_LABEL)/$$trial link failed"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; \
			fi; \
		fi; \
		[ "$$failed" -ne 0 ] && break; \
		if [ -f "$$trial.wait_for_exit" ]; then \
			marker=$$(awk 'NF { if ($$NF ~ /^[0-9]+$$/) { m=$$0; sub(/[ \t]+[0-9]+$$/, "", m); print m } else print $$0; exit } END { if (!NR) print "done" }' "$$trial.wait_for_exit"); \
			marker_count=$$(awk 'NF { if ($$NF ~ /^[0-9]+$$/) print $$NF; else print 1; exit } END { if (!NR) print 1 }' "$$trial.wait_for_exit"); \
			$(call INTEGRATE_EXEC_TRIAL,$(APP_LABEL)/$$trial,python3 "$(FFI_TRIAL_DIR)/run_integration_exit_after_marker.py" "$(APP_TRIAL_DIR)" "$$trial" "$$trial.sout" "$$marker" "$$marker_count"); \
			if [ "$$integrate_killed" = 1 ]; then \
				echo "❌❌ $(APP_LABEL)/$$trial $(INTEGRATE_KILLED_MSG)"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; \
			elif [ "$$integrate_rc" -ne 0 ]; then \
			echo "❌❌ $(APP_LABEL)/$$trial run failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		fi; \
		else \
			$(call INTEGRATE_RUN_TRIAL,$(APP_LABEL)/$$trial,$$trial.sout,./$$trial); \
			if [ "$$integrate_killed" = 1 ]; then \
				echo "❌❌ $(APP_LABEL)/$$trial $(INTEGRATE_KILLED_MSG)"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; \
			elif false; then \
			echo "❌❌ $(APP_LABEL)/$$trial run failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		fi; \
		fi; \
		[ "$$failed" -ne 0 ] && break; \
		if [ ! -f "$(call SCOUT_FOR,$$trial)" ]; then \
			echo "  ❌ $(APP_LABEL)/$$trial: missing .scout"; ko=$$((ko + 1)); failed=1; \
			$(INTEGRATE_DOT_FAIL); \
		elif [ -f "$$trial.scout.sorted" ] && [ -f "$(FFI_TRIAL_DIR)/compare_scout_sorted.sh" ] && ! "$(SHELL)" "$(FFI_TRIAL_DIR)/compare_scout_sorted.sh" "$$trial.sout" "$(call SCOUT_FOR,$$trial)" > /dev/null 2>&1; then \
			echo "  ❌ $(APP_LABEL)/$$trial .sout differs from .scout (sorted compare)"; \
			$(INTEGRATE_DOT_FAIL); \
			"$(SHELL)" "$(FFI_TRIAL_DIR)/compare_scout_sorted.sh" "$$trial.sout" "$(call SCOUT_FOR,$$trial)" || true; \
			ko=$$((ko + 1)); failed=1; \
		elif [ -f "$$trial.scout.sorted" ] && [ ! -f "$(FFI_TRIAL_DIR)/compare_scout_sorted.sh" ] && ! diff -Bw -q "$$trial.sout" "$(call SCOUT_FOR,$$trial)" > /dev/null 2>&1; then \
			echo "  ❌ $(APP_LABEL)/$$trial .sout differs from .scout (missing compare_scout_sorted.sh; used diff -Bw)"; \
			$(INTEGRATE_DOT_FAIL); \
			diff -Bw "$$trial.sout" "$(call SCOUT_FOR,$$trial)" || true; \
			ko=$$((ko + 1)); failed=1; \
		elif [ ! -f "$$trial.scout.sorted" ] && [ -f "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" ] && ! "$(SHELL)" "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" "$$trial.sout" "$(call SCOUT_FOR,$$trial)" > /dev/null 2>&1; then \
			echo "  ❌ $(APP_LABEL)/$$trial .sout differs from .scout (normalized compare)"; \
			$(INTEGRATE_DOT_FAIL); \
			"$(SHELL)" "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" "$$trial.sout" "$(call SCOUT_FOR,$$trial)" || true; \
			ko=$$((ko + 1)); failed=1; \
		elif [ ! -f "$$trial.scout.sorted" ] && [ ! -f "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" ] && ! diff -Bw -q "$$trial.sout" "$(call SCOUT_FOR,$$trial)" > /dev/null 2>&1; then \
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
	[ "$$failed" -ne 0 ] && [ "$$ko" -eq 0 ] && ko=$$((ko + 1)); \
	printf '%d %d\n' "$$ok" "$$ko" > .integrate_counts; \
	exit $$failed

clean:
	@cd "$(THIS_DIR)" && rm -f *.sams *.o *.iface $(APP_EXECUTABLES) silica.config silica.link .integrate_counts silica.compile.order silica.needs_runtime silica.atoms *.sout dangerous_exposure_source
