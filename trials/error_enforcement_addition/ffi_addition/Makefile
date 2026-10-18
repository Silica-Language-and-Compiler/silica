# FFI expected-failure trials live under error_enforcement_addition.
# This harness preserves the FFI-specific temp project setup these cases need.

THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../../silica_compiler.mk
FIXTURES_DIR := $(THIS_DIR)../../ffi_addition/fixtures
FIXTURE_ROOT := $(FIXTURES_DIR)/dangerous_exposure_source
# The archives are per platform (ffi_addition/fixtures_paths.mk); the .meta/.h sources are shared.
include $(THIS_DIR)../../ffi_addition/fixtures_paths.mk
FFI_SUCCESS_DIR := $(THIS_DIR)../../ffi_addition
SILICA_LINK_SH := $(abspath $(THIS_DIR)../../silica_link.sh)

TRIAL_DIR := error_enforcement_addition/ffi_addition
MSG_PREFIX := $(TRIAL_DIR)/

ARCH := arm64
MACOS_MIN_VERSION := 26.0
ASFLAGS := -mmacosx-version-min=$(MACOS_MIN_VERSION)
RUST_SYSROOT := $(shell rustc --print sysroot 2>/dev/null)
RUST_TARGET := $(shell rustc -vV 2>/dev/null | sed -n "s/^host: *//p")
RUST_LLD := $(RUST_SYSROOT)/lib/rustlib/$(RUST_TARGET)/bin/rust-lld
MACOS_SDK := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
LDFLAGS_rust-lld := -arch $(ARCH) -platform_version macos $(MACOS_MIN_VERSION) $(MACOS_MIN_VERSION) -syslibroot $(MACOS_SDK) -lSystem -e main
LDFLAGS_clang := -Wl,-e,main -Wl,-macos_version_min,$(MACOS_MIN_VERSION)

# Link-fail stderr shape differs between rust-lld, Apple ld (via clang) and GNU ld; match the
# linker this host actually uses.
ifeq ($(shell uname -s),Linux)
  LINK_FAIL_GOLDEN_SUFFIX := .gnu-ld
else
  LINK_FAIL_GOLDEN_SUFFIX := $(shell test -x "$(RUST_LLD)" && echo .rust-lld || echo .clang)
endif

FAIL_CASES := \
	module_addition/dangerous_export_raw \
	module_addition/dangerous_missing_wrapper_meta \
	module_addition/dangerous_wrapper_meta_outside_tree \
	module_addition/dangerous_dependency_naming_fail_trial/app_uses_dangerous \
	module_addition/app_spawn_dangerous_naming_fail \
	error_app_sidecar_metadata/dangerous_sidecar_missing_file \
	error_app_sidecar_metadata/dangerous_sidecar_missing_entry \
	error_app_sidecar_metadata/dangerous_sidecar_missing_link_library \
	error_app_sidecar_metadata/dangerous_sidecar_missing_archive \
	error_app_cast_worker/dangerous_external_danger_in_main \
	error_app_cast_worker/dangerous_nested_external_danger \
	error_app_cast_worker/dangerous_nested_external_danger_deep \
	error_app_cast_worker/dangerous_external_danger_at_spawn_site \
	error_app_cast_worker/dangerous_direct_call_fail \
	error_app_cast_worker/dangerous_adapter_called_from_main \
	error_app_cast_worker/dangerous_spawn_plain_bad \
	error_app_cast_worker/dangerous_spawn_dangerous_requires_external \
	error_app_cast_worker/dangerous_spawn_dangerous_wrong_type \
	error_app_cast_worker/dangerous_spawn_registered_wrong_type \
	error_app_cast_worker/dangerous_spawn_registered_bad_atom \
	error_app_cast_worker/dangerous_cast_registered_bad_atom \
	error_app_cast_worker/dangerous_cast_registered_on_dangerous_atom \
	error_app_cast_worker/dangerous_spawn_registered_dangerous_behavior \
	error_app_cast_worker/dangerous_client_not_cast_only \
	error_app_ffi_result_cast/dangerous_taint_in_produces \
	error_app_ffi_result_cast/dangerous_external_danger_message_boundary \
	error_app_ffi_result_cast/dangerous_taint_device_io \
	error_app_ffi_result_cast/dangerous_taint_region_escape \
	error_app_foreign_abi/dangerous_raw_string_param_fail \
	error_app_foreign_abi/dangerous_too_many_args_fail

LINK_FAIL_CASES := \
	error_app_sidecar_metadata/dangerous_missing_foreign_symbol_at_link

ARCHIVE_MISSING_CASE := error_app_sidecar_metadata/dangerous_sidecar_missing_archive

.DEFAULT_GOAL := integrate
.PHONY: all integrate compile-fail-goldens diff-fail-goldens link-fail archive-missing clean help

all: integrate

link-fail:
	@$(MAKE) -C "$(FFI_SUCCESS_DIR)" fixtures
	@failed=0; ok=0; ko=0; \
	for case in $(LINK_FAIL_CASES); do \
		base=$$(basename "$$case"); \
		golden="$(THIS_DIR)$$case.golden_link_fail$(LINK_FAIL_GOLDEN_SUFFIX)"; \
		cur="$(THIS_DIR)$$case.cur_link_fail"; \
		cur_norm="$$cur.norm"; \
		golden_norm="$$golden.norm"; \
		tmpdir=$$(mktemp -d); \
		mkdir -p "$$tmpdir/dangerous_exposure_source"; \
		ln -s "$(FIXTURE_ROOT)/legacy" "$$tmpdir/dangerous_exposure_source/legacy"; \
		ln -s "$(FIXTURE_ROOT)/text" "$$tmpdir/dangerous_exposure_source/text"; \
		ln -s "$(FIXTURE_ROOT)/net" "$$tmpdir/dangerous_exposure_source/net"; \
		ln -s "$(FIXTURE_ROOT)/other" "$$tmpdir/dangerous_exposure_source/other"; \
		ln -s "$(FFI_LIB_DIR)" "$$tmpdir/dangerous_exposure_source/lib"; \
		ln -s "$(THIS_DIR)error_app_sidecar_metadata/dangerous_exposure_source/bad_link_only_symbol.meta" "$$tmpdir/dangerous_exposure_source/bad_link_only_symbol.meta"; \
		ln -s "$(THIS_DIR)$$case.silica" "$$tmpdir/$$base.silica"; \
		printf "$$base.silica\n" > "$$tmpdir/silica.config"; \
		( cd "$$tmpdir" && { $(call RUN_SILICA_COMPILER_QUIET_WITH,"$(SILICA_COMPILER)"); } ) > "$$tmpdir/compile.out" 2>&1 || { \
			echo "❌❌ $(MSG_PREFIX)$$case: expected compile success"; cat "$$tmpdir/compile.out"; rm -rf "$$tmpdir"; failed=1; continue; \
			$(INTEGRATE_DOT_FAIL); \
		}; \
		if [ ! -f "$$tmpdir/silica.link" ]; then \
			echo "❌❌ $(MSG_PREFIX)$$case: silica.link not emitted"; rm -rf "$$tmpdir"; failed=1; continue; \
			$(INTEGRATE_DOT_FAIL); \
		fi; \
		link_archives=$$("$(SILICA_LINK_SH)" "$$tmpdir"); \
		( cd "$$tmpdir" && \
			for sams in *.sams; do \
				[ -f "$$sams" ] || continue; \
				base_obj=$${sams%.sams}; \
				clang $(ASFLAGS) -c -x assembler "$$sams" -o "$$base_obj.o" || exit 1; \
			done ) || { echo "❌❌ $(MSG_PREFIX)$$case: assembly failed"; rm -rf "$$tmpdir"; failed=1; continue; }; \
			$(INTEGRATE_DOT_FAIL); \
		( cd "$$tmpdir" && \
			runtime_obj=""; \
			[ -f __silica_runtime.o ] && runtime_obj=__silica_runtime.o; \
			if test -x "$(RUST_LLD)"; then \
				"$(RUST_LLD)" -flavor darwin -o "$$base" "$$base.o" $$runtime_obj $$link_archives $(LDFLAGS_rust-lld); \
			else \
				clang "$$base.o" $$runtime_obj $$link_archives -o "$$base" $(LDFLAGS_clang); \
			fi ) > "$$cur" 2>&1; \
		link_st=$$?; \
		rm -rf "$$tmpdir"; \
		if [ "$$link_st" -eq 0 ]; then \
			echo "❌❌ $(MSG_PREFIX)$$case: expected link failure"; cat "$$cur"; ko=$$((ko + 1)); failed=1; \
			$(INTEGRATE_DOT_FAIL); \
		elif [ ! -f "$$golden" ]; then \
			echo "❌❌ $(MSG_PREFIX)$$case: missing link golden $$(basename "$$golden")"; ko=$$((ko + 1)); failed=1; \
			$(INTEGRATE_DOT_FAIL); \
		else \
			sed -E -e 's/\(symbol ([^)]+)\+0x[0-9A-Fa-f]+\)/(symbol \1+0xADDR)/g' -e 's/\((\.[a-z._]+)\+0x[0-9A-Fa-f]+\)/(\1+0xADDR)/g' "$$cur" > "$$cur_norm"; \
			sed -E -e 's/\(symbol ([^)]+)\+0x[0-9A-Fa-f]+\)/(symbol \1+0xADDR)/g' -e 's/\((\.[a-z._]+)\+0x[0-9A-Fa-f]+\)/(\1+0xADDR)/g' "$$golden" > "$$golden_norm"; \
			if ! diff -q "$$cur_norm" "$$golden_norm" > /dev/null 2>&1; then \
				echo "❌❌ $(MSG_PREFIX)$$case: .cur_link_fail differs from $$(basename "$$golden")"; \
				$(INTEGRATE_DOT_FAIL); \
				diff "$$cur_norm" "$$golden_norm" || true; \
				ko=$$((ko + 1)); failed=1; \
			else \
				echo "✅✅ $(MSG_PREFIX)$$case (link failure matches golden)"; \
				$(INTEGRATE_DOT_OK); \
				ok=$$((ok + 1)); \
			fi; \
		fi; \
	done; \
	printf '%d %d\n' "$$ok" "$$ko" > "$(THIS_DIR).integrate_link_fail_counts"; \
	exit $$failed

archive-missing:
	@$(MAKE) -C "$(FFI_SUCCESS_DIR)" fixtures
	@failed=0; ok=0; ko=0; \
	case="$(ARCHIVE_MISSING_CASE)"; \
	base=$$(basename "$$case"); \
	golden="$(THIS_DIR)$$case.golden_fail"; \
	cur="$(THIS_DIR)$$case.cur_fail"; \
	tmpdir=$$(mktemp -d); \
	mkdir -p "$$tmpdir/dangerous_exposure_source"; \
	ln -s "$(FIXTURE_ROOT)/legacy" "$$tmpdir/dangerous_exposure_source/legacy"; \
	ln -s "$(FIXTURE_ROOT)/text" "$$tmpdir/dangerous_exposure_source/text"; \
	ln -s "$(FIXTURE_ROOT)/net" "$$tmpdir/dangerous_exposure_source/net"; \
	ln -s "$(FIXTURE_ROOT)/other" "$$tmpdir/dangerous_exposure_source/other"; \
	ln -s "$(FFI_LIB_DIR)" "$$tmpdir/dangerous_exposure_source/lib"; \
	ln -s "$(THIS_DIR)error_app_sidecar_metadata/dangerous_exposure_source/bad_missing_archive.meta" "$$tmpdir/dangerous_exposure_source/bad_missing_archive.meta"; \
	ln -s "$(THIS_DIR)$$case.silica" "$$tmpdir/$$base.silica"; \
	printf "$$base.silica\n" > "$$tmpdir/silica.config"; \
	$(call TRIAL_SUPPORT_IN_TMP,$$tmpdir,$(THIS_DIR)$$case.silica); \
	(cd "$$tmpdir" && { $(call RUN_SILICA_COMPILER_QUIET_WITH,"$(SILICA_COMPILER)"); }) > "$$cur" 2>&1 || true; \
	rm -rf "$$tmpdir"; \
	if [ ! -f "$$golden" ]; then \
		echo "❌❌ $(MSG_PREFIX)$$case: missing .golden_fail"; ko=$$((ko + 1)); failed=1; \
		$(INTEGRATE_DOT_FAIL); \
	elif diff -q "$$cur" "$$golden" > /dev/null 2>&1; then \
		echo "✅✅ $(MSG_PREFIX)$$case (missing archive compile failure)"; \
		$(INTEGRATE_DOT_OK); \
		ok=$$((ok + 1)); \
	else \
		echo "❌❌ $(MSG_PREFIX)$$case: .cur_fail differs from .golden_fail"; \
		$(INTEGRATE_DOT_FAIL); \
		diff "$$cur" "$$golden" || true; \
		ko=$$((ko + 1)); failed=1; \
	fi; \
	printf '%d %d\n' "$$ok" "$$ko" > "$(THIS_DIR).integrate_archive_missing_counts"; \
	exit $$failed

compile-fail-goldens:
	@$(MAKE) -C "$(FFI_SUCCESS_DIR)" fixtures
	@echo "=== $(MSG_PREFIX)compile-fail-goldens: compile each case, write .cur_fail, diff .golden_fail ==="
	@failed=0; ok=0; ko=0; \
	for case in $(FAIL_CASES); do \
		base=$$(basename "$$case"); \
		golden="$(THIS_DIR)$$case.golden_fail"; \
		cur="$(THIS_DIR)$$case.cur_fail"; \
		tmpdir=$$(mktemp -d); \
		mkdir -p "$$tmpdir/dangerous_exposure_source"; \
		ln -s "$(FIXTURE_ROOT)/legacy" "$$tmpdir/dangerous_exposure_source/legacy"; \
		ln -s "$(FIXTURE_ROOT)/text" "$$tmpdir/dangerous_exposure_source/text"; \
		ln -s "$(FIXTURE_ROOT)/net" "$$tmpdir/dangerous_exposure_source/net"; \
		ln -s "$(FIXTURE_ROOT)/other" "$$tmpdir/dangerous_exposure_source/other"; \
		ln -s "$(FFI_LIB_DIR)" "$$tmpdir/dangerous_exposure_source/lib"; \
		ln -s "$(THIS_DIR)error_app_sidecar_metadata/dangerous_exposure_source/bad_wrong_symbol.meta" "$$tmpdir/dangerous_exposure_source/bad_wrong_symbol.meta"; \
		ln -s "$(THIS_DIR)error_app_sidecar_metadata/dangerous_exposure_source/bad_no_link_library.meta" "$$tmpdir/dangerous_exposure_source/bad_no_link_library.meta"; \
		ln -s "$(THIS_DIR)error_app_sidecar_metadata/dangerous_exposure_source/bad_link_only_symbol.meta" "$$tmpdir/dangerous_exposure_source/bad_link_only_symbol.meta"; \
		ln -s "$(THIS_DIR)error_app_sidecar_metadata/dangerous_exposure_source/bad_missing_archive.meta" "$$tmpdir/dangerous_exposure_source/bad_missing_archive.meta"; \
		case "$$case" in \
			module_addition/dangerous_dependency_naming_fail_trial/app_uses_dangerous) \
				ln -s "$(THIS_DIR)module_addition/dangerous_dependency_naming_fail_trial/dangerous_legacy_stub.silica" "$$tmpdir/dangerous_legacy_stub.silica"; \
				ln -s "$(THIS_DIR)module_addition/dangerous_dependency_naming_fail_trial/app_uses_dangerous.silica" "$$tmpdir/app_uses_dangerous.silica"; \
				printf "dangerous_legacy_stub.silica\napp_uses_dangerous.silica\n" > "$$tmpdir/silica.config"; \
				;; \
			error_app_cast_worker/*) \
				ln -s "$(FFI_SUCCESS_DIR)/app_cast_worker_legacy_add/dangerous_legacy_stub.silica" "$$tmpdir/dangerous_legacy_stub.silica"; \
				ln -s "$(THIS_DIR)$$case.silica" "$$tmpdir/$$base.silica"; \
				printf "dangerous_legacy_stub.silica\n$$base.silica\n" > "$$tmpdir/silica.config"; \
				;; \
			error_app_ffi_result_cast/*) \
				ln -s "$(FFI_SUCCESS_DIR)/app_ffi_result_cast_add/dangerous_legacy_stub.silica" "$$tmpdir/dangerous_legacy_stub.silica"; \
				ln -s "$(THIS_DIR)$$case.silica" "$$tmpdir/$$base.silica"; \
				printf "dangerous_legacy_stub.silica\n$$base.silica\n" > "$$tmpdir/silica.config"; \
				;; \
			*) \
				ln -s "$(THIS_DIR)$$case.silica" "$$tmpdir/$$base.silica"; \
				printf "$$base.silica\n" > "$$tmpdir/silica.config"; \
				;; \
		esac; \
		$(call TRIAL_SUPPORT_IN_TMP,$$tmpdir,$(THIS_DIR)$$case.silica); \
		(cd "$$tmpdir" && { $(call RUN_SILICA_COMPILER_QUIET_WITH,"$(SILICA_COMPILER)"); }) > "$$cur" 2>&1 || true; \
		rm -rf "$$tmpdir"; \
		if [ ! -f "$$golden" ]; then \
			echo "❌❌ $(MSG_PREFIX)$$case: missing .golden_fail"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		elif diff -q "$$cur" "$$golden" > /dev/null 2>&1; then \
			echo "✅✅ $(MSG_PREFIX)$$case"; \
			$(INTEGRATE_DOT_OK); \
			ok=$$((ok + 1)); \
		else \
			echo "❌❌ $(MSG_PREFIX)$$case: .cur_fail differs from .golden_fail"; \
			$(INTEGRATE_DOT_FAIL); \
			diff "$$cur" "$$golden" || true; \
			ko=$$((ko + 1)); failed=1; \
		fi; \
	done; \
	printf '%d %d\n' "$$ok" "$$ko" > "$(THIS_DIR).integrate_compile_fail_counts"; \
	echo "$(MSG_PREFIX)compile-fail-goldens: $$ok passed, $$ko failed (.cur_fail vs .golden_fail)"; \
	exit $$failed

diff-fail-goldens:
	@echo "=== $(MSG_PREFIX)diff-fail-goldens: diff existing .cur_fail vs .golden_fail (no recompile) ==="
	@failed=0; ok=0; ko=0; \
	for case in $(FAIL_CASES); do \
		golden="$(THIS_DIR)$$case.golden_fail"; \
		cur="$(THIS_DIR)$$case.cur_fail"; \
		if [ ! -f "$$golden" ]; then \
			echo "❌❌ $(MSG_PREFIX)$$case: missing .golden_fail"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		elif [ ! -f "$$cur" ]; then \
			echo "❌❌ $(MSG_PREFIX)$$case: missing .cur_fail (run compile-fail-goldens or integrate first)"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		elif diff -q "$$cur" "$$golden" > /dev/null 2>&1; then \
			echo "✅✅ $(MSG_PREFIX)$$case (.cur_fail matches .golden_fail)"; \
			$(INTEGRATE_DOT_OK); \
			ok=$$((ok + 1)); \
		else \
			echo "❌❌ $(MSG_PREFIX)$$case: .cur_fail differs from .golden_fail"; \
			$(INTEGRATE_DOT_FAIL); \
			diff "$$cur" "$$golden" || true; \
			ko=$$((ko + 1)); failed=1; \
		fi; \
	done; \
	echo "$(MSG_PREFIX)diff-fail-goldens: $$ok passed, $$ko failed"; \
	exit $$failed

integrate-run: clean
	@failed=0; \
	echo "=== $(MSG_PREFIX)integrate: compile-fail goldens, link-fail, archive-missing ==="; \
	$(MAKE) compile-fail-goldens || failed=1; \
	$(MAKE) link-fail || failed=1; \
	$(MAKE) archive-missing || failed=1; \
	ok=0; ko=0; \
	for cf in "$(THIS_DIR).integrate_compile_fail_counts" "$(THIS_DIR).integrate_link_fail_counts" "$(THIS_DIR).integrate_archive_missing_counts"; do \
		if [ -f "$$cf" ]; then \
			read n1 n2 < "$$cf" || true; \
			ok=$$((ok + $${n1:-0})); ko=$$((ko + $${n2:-0})); \
		fi; \
	done; \
	printf '%d %d\n' "$$ok" "$$ko" > "$(THIS_DIR).integrate_counts"; \
	echo "$(MSG_PREFIX)integrate complete: $$ok passed, $$ko failed (.cur_fail/.golden_fail and link goldens)"; \
	exit $$failed

clean:
	@rm -f "$(THIS_DIR).integrate_counts" "$(THIS_DIR).integrate_compile_fail_counts" \
		"$(THIS_DIR).integrate_link_fail_counts" "$(THIS_DIR).integrate_archive_missing_counts"
	@find "$(THIS_DIR)" -name '*.cur_fail' -o -name '*.cur_link_fail' -o -name '*.norm' | xargs rm -f 2>/dev/null || true
	@echo "✅ $(MSG_PREFIX)Clean complete"

help:
	@echo "FFI error-enforcement trials ($(THIS_DIR))"
	@echo "================================================"
	@echo "integrate runs compile-fail goldens, link-fail, and archive-missing cases."
	@echo "  - Starts with clean (removes existing .cur_fail), recompiles each case,"
	@echo "    writes fresh .cur_fail output, then diffs against .golden_fail."
	@echo "  - Prints a final passed/failed summary line."
	@echo "compile-fail-goldens recompiles FAIL_CASES and diffs .cur_fail vs .golden_fail."
	@echo "diff-fail-goldens diffs existing .cur_fail vs .golden_fail without recompiling."
	@echo "link-fail runs compile-then-link cases that must fail at Stage 3."
	@echo "  Link stderr is matched per linker: .golden_link_fail.clang or .golden_link_fail.rust-lld."
	@echo "archive-missing runs compile failure when a referenced prebuilt archive is absent."
	@echo ""
	@echo "Note: trials/ffi_addition (parent) is the success-path harness (.scout goldens)."
	@echo "      This directory is the error-path harness (.golden_fail goldens)."
