# Shared integrate recipe for ffi_addition app trials.
# Required variables before include:
#   APP_TRIAL_DIR   - absolute or Make-relative path to the app trial directory
#   APP_LABEL       - short label for log messages (e.g. app_cast_worker_legacy_add)
#   APP_LINK_OBJECTS - optional extra .o files to link with each executable (e.g. stub modules)
APP_LINK_OBJECTS ?=

FFI_TRIAL_DIR := $(abspath $(APP_TRIAL_DIR)/..)
include $(dir $(abspath $(lastword $(MAKEFILE_LIST))))../silica_compiler.mk
FIXTURES_DIR := $(FFI_TRIAL_DIR)/fixtures
SILICA_LINK_SH := $(abspath $(FFI_TRIAL_DIR)/../silica_link.sh)

include $(FFI_TRIAL_DIR)/fixtures.mk

.PHONY: fixtures
fixtures: ffi-wrapper-archives

ARCH := arm64
MACOS_MIN_VERSION := 26.0
ASFLAGS := -mmacosx-version-min=$(MACOS_MIN_VERSION)

RUST_SYSROOT := $(shell rustc --print sysroot 2>/dev/null)
RUST_TARGET := $(shell rustc -vV 2>/dev/null | sed -n "s/^host: *//p")
RUST_LLD := $(RUST_SYSROOT)/lib/rustlib/$(RUST_TARGET)/bin/rust-lld
MACOS_SDK := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
LDFLAGS_rust-lld := -arch $(ARCH) -platform_version macos $(MACOS_MIN_VERSION) $(MACOS_MIN_VERSION) -syslibroot $(MACOS_SDK) -lSystem -e main
LDFLAGS_clang := -Wl,-e,main -Wl,-macos_version_min,$(MACOS_MIN_VERSION)

define APP_INTEGRATE_BODY
	@$(ENSURE_SILICA_COMPILER)
	@# -n as well as -f: without it, BSD ln follows an existing symlink-to-directory and
	@# writes the new link INSIDE the fixtures directory, which corrupts the fixtures for
	@# every other app in the suite.
	@# Relative when the view sits beside the app (every app under ffi_addition/), so a tree
	@# synced to another host does not carry a link into this host's absolute path.
	@ln -sfn "$(patsubst $(abspath $(APP_TRIAL_DIR)/..)/%,../%,$(FFI_SOURCE_VIEW))" "$(APP_TRIAL_DIR)/dangerous_exposure_source"
	@test -f "$(FFI_LEGACY_ARCHIVE)" || { echo "  ❌ $(APP_LABEL): missing $(FFI_LEGACY_ARCHIVE) (run make fixtures)"; exit 1; }
	@for ar in $(FFI_WRAPPER_ARCHIVES); do \
		test -f "$$ar" || { echo "  ❌ $(APP_LABEL): missing wrapper archive $$ar (run make fixtures)"; exit 1; }; \
	done
	@cd "$(APP_TRIAL_DIR)" && rm -f *.sams *.o *.iface $(APP_EXECUTABLES) silica.config silica.link .integrate_counts silica.compile.order silica.needs_runtime silica.atoms
	@cd "$(APP_TRIAL_DIR)" && find "$(APP_TRIAL_DIR)" -maxdepth 1 -name '*.silica' | sed "s|^$(APP_TRIAL_DIR)/||" | sort > silica.config && $(TRIAL_SUPPORT_CONFIG)
	@cd "$(APP_TRIAL_DIR)" && if ! { $(RUN_SILICA_COMPILER); }; then echo "❌❌ $(APP_LABEL): compilation failed"; $(INTEGRATE_DOT_FAIL); printf '%d %d\n' 0 1 > .integrate_counts; exit 1; fi
	@failed=0; ok=0; ko=0; \
	cd "$(APP_TRIAL_DIR)"; \
	if [ -f silica.link.scout ]; then \
		if [ ! -f silica.link ]; then \
			echo "  ❌ $(APP_LABEL): silica.link not emitted"; \
			$(INTEGRATE_DOT_FAIL); \
			printf '%d %d\n' 0 1 > .integrate_counts; exit 1; \
		elif ! diff -Bw -q silica.link silica.link.scout > /dev/null 2>&1; then \
			echo "  ❌ $(APP_LABEL): silica.link differs from .scout"; \
			$(INTEGRATE_DOT_FAIL); \
			diff -Bw silica.link silica.link.scout || true; \
			printf '%d %d\n' 0 1 > .integrate_counts; exit 1; \
		else \
			echo "  ✅✅ $(APP_LABEL)/silica.link matches .scout"; \
			$(INTEGRATE_DOT_OK); \
			ok=$$((ok + 1)); \
		fi; \
	fi; \
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
	for trial in $(APP_EXECUTABLES); do \
		[ "$$failed" -ne 0 ] && break; \
		[ -n "$$tsa_done" ] || { $(TRIAL_SUPPORT_ASSEMBLE); tsa_done=1; }; \
		runtime_obj=""; \
		[ -f __silica_runtime.o ] && runtime_obj=__silica_runtime.o; \
		runtime_obj="$$runtime_obj $(call TRIAL_SUPPORT_OBJ,$$trial.silica)"; \
		if test -x "$(RUST_LLD)"; then \
			objs="$$trial.o $(APP_LINK_OBJECTS)"; \
			if ! "$(RUST_LLD)" -flavor darwin -o "$$trial" $$objs $$runtime_obj $$link_archives $(LDFLAGS_rust-lld); then \
			echo "❌❌ $(APP_LABEL)/$$trial link failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		fi; \
		else \
			objs="$$trial.o $(APP_LINK_OBJECTS)"; \
			if ! clang $$objs $$runtime_obj $$link_archives -o "$$trial" $(LDFLAGS_clang); then \
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
			fi; \
		fi; \
		[ "$$failed" -ne 0 ] && break; \
		if [ ! -f "$$trial.scout" ]; then \
			echo "  ❌ $(APP_LABEL)/$$trial: missing .scout"; ko=$$((ko + 1)); failed=1; \
			$(INTEGRATE_DOT_FAIL); \
		elif [ -f "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" ] && ! "$(SHELL)" "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" "$$trial.sout" "$$trial.scout" > /dev/null 2>&1; then \
			echo "  ❌ $(APP_LABEL)/$$trial .sout differs from .scout (normalized compare)"; \
			$(INTEGRATE_DOT_FAIL); \
			"$(SHELL)" "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" "$$trial.sout" "$$trial.scout" || true; \
			ko=$$((ko + 1)); failed=1; \
		elif [ ! -f "$(FFI_TRIAL_DIR)/compare_scout_normalized.sh" ] && ! diff -Bw -q "$$trial.sout" "$$trial.scout" > /dev/null 2>&1; then \
			echo "  ❌ $(APP_LABEL)/$$trial .sout differs from .scout"; \
			$(INTEGRATE_DOT_FAIL); \
			diff -Bw "$$trial.sout" "$$trial.scout" || true; \
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
endef
