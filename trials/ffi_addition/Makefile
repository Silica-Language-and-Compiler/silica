# FFI trial harness — Phase 0 builds prebuilt C wrapper static libraries and sidecar fixtures.
#
# Success-path app trials live under app_*/ (each a runnable program with .scout goldens).
# Run: make -C trials/ffi_addition phase-0

THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../silica_compiler.mk

include $(THIS_DIR)fixtures.mk

FIXTURES_DIR := $(FFI_FIXTURES_DIR)
SRC_DIR := $(FFI_SRC_DIR)
LIB_DIR := $(FFI_LIB_DIR)
BUILD_DIR := $(FFI_BUILD_DIR)
CC := $(FFI_CC)
ARCH := $(FFI_ARCH)
CFLAGS := $(FFI_CFLAGS)
LEGACY_OBJ := $(FFI_LEGACY_OBJ)
TEXT_OBJ := $(FFI_TEXT_OBJ)
NET_OBJ := $(FFI_NET_OBJ)
LEGACY_ARCHIVE := $(FFI_LEGACY_ARCHIVE)
TEXT_ARCHIVE := $(FFI_TEXT_ARCHIVE)
NET_ARCHIVE := $(FFI_NET_ARCHIVE)

NM := $(shell command -v llvm-nm 2>/dev/null || command -v nm)

APP_SIDECAR_DIR := app_sidecar_legacy_math_add
APP_CAST_WORKER_DIR := app_cast_worker_legacy_add
APP_CAST_WORKER_REGISTERED_DIR := app_cast_worker_registered_legacy_add
APP_FFI_RESULT_CAST_DIR := app_ffi_result_cast_add
APP_FOREIGN_ABI_DIR := app_foreign_abi_valid
APP_FOREIGN_ABI_TYPES_E2E_DIR := app_foreign_abi_types_e2e
APP_E2E_DIR := app_e2e_scalar_string_echo
APP_GUARDED_ONCE_DIR := app_legacy_math_add_guarded
APP_GUARDED_TWICE_DIR := app_legacy_math_add_twice
APP_TEXT_ECHO_DIR := app_text_echo_guarded
APP_TEXT_ECHO_TWICE_DIR := app_text_echo_twice
# Every supervised-failure trial lives in one directory: a dangerous child faults, the
# supervisor consumes the failure and restarts it, and the trial ends when the restarted
# child services a message. New trials of that shape are added there, not in a directory
# of their own, so the harness needs no per-trial special casing.
APP_SUPERVISOR_DANGEROUS_FAULT_DIR := app_supervisor_dangerous_guarded_fault_trials

APP_DIRS := \
	$(APP_SIDECAR_DIR) \
	$(APP_CAST_WORKER_DIR) \
	$(APP_CAST_WORKER_REGISTERED_DIR) \
	$(APP_FFI_RESULT_CAST_DIR) \
	$(APP_FOREIGN_ABI_DIR) \
	$(APP_FOREIGN_ABI_TYPES_E2E_DIR) \
	$(APP_E2E_DIR) \
	$(APP_GUARDED_ONCE_DIR) \
	$(APP_GUARDED_TWICE_DIR) \
	$(APP_TEXT_ECHO_DIR) \
	$(APP_TEXT_ECHO_TWICE_DIR) \
	$(APP_SUPERVISOR_DANGEROUS_FAULT_DIR) \
	app_worker_second_message \
	app_foreign_call_from_deep_stack \
	app_process_fatal_paths

GUARDED_APP_DIRS := \
	$(APP_GUARDED_ONCE_DIR) \
	$(APP_GUARDED_TWICE_DIR)

APP_GUARDED_FAULT_DIR := app_guarded_fault_trials

FAULT_APP_DIRS := \
	$(APP_GUARDED_FAULT_DIR)

ARENA_APP_DIRS := \
	$(APP_TEXT_ECHO_DIR) \
	$(APP_TEXT_ECHO_TWICE_DIR)

MODULE_VALID_FILE := module_addition/dangerous_naming_valid.silica

.PHONY: all integrate-run ffi-apps $(APP_DIRS:%=ffi-app-%) fixtures phase-0 phase-a phase-3 phase-4 phase-5 phase-6 phase-7 phase-8 phase-9 phase-11 phase-12 phase-13 phase-14 \
	ffi-wrapper-archives module-valid abi-valid verify-symbols clean clean-fixtures clean-apps help

.DEFAULT_GOAL := phase-0

# Success-path regression gate: fixtures + all app integrates (manifest-driven link via .scout goldens).
all: phase-9
	@echo "✅ ffi_addition all complete"

# integrate (wrapper in silica_compiler.mk) -> integrate-run: fixtures once, then every
# app trial concurrently (each with its own Makefile, log and report); sum their counts.
integrate-run: fixtures
	@cd "$(THIS_DIR)" && rm -f $(APP_DIRS:%=%/.integrate_counts)
	@cd "$(THIS_DIR)" && $(MAKE) --no-print-directory -f "$(INTEGRATE_MAKEFILE)" ffi-apps || true
	@cd "$(THIS_DIR)" && $(call INTEGRATE_SUM_CHILDREN,$(APP_DIRS)); \
	[ "$$ko" -eq 0 ] && [ "$$failed" -eq 0 ]

ffi-apps: $(APP_DIRS:%=ffi-app-%)

$(APP_DIRS:%=ffi-app-%): ffi-app-%:
	@$(call INTEGRATE_CHILD,$*)

fixtures: ffi-wrapper-archives
	@echo "✅ ffi_addition/fixtures: static libraries built"

verify-symbols: fixtures
	@test -n "$(NM)" || { echo "FAIL: neither llvm-nm nor nm found"; exit 1; }
	@failed=0; \
	for archive in "$(LEGACY_ARCHIVE)" "$(TEXT_ARCHIVE)" "$(NET_ARCHIVE)" "$(FFI_ABI_TYPES_ARCHIVE)"; do \
		echo "Checking symbols in $$archive..."; \
		syms=$$($(NM) -g "$$archive" 2>/dev/null || $(NM) "$$archive"); \
		case "$$archive" in \
			*libsilica_legacy_math.a) \
				if echo "$$syms" | grep -Eq '(_)?silica_legacy_math_add_int64($$|[[:space:]])'; then \
					echo "  ✅ silica_legacy_math_add_int64"; \
				else \
					echo "  ❌ missing silica_legacy_math_add_int64"; failed=1; \
					$(INTEGRATE_DOT_FAIL); \
				fi ;; \
			*libsilica_text.a) \
				if echo "$$syms" | grep -Eq '(_)?silica_text_echo($$|[[:space:]])'; then \
					echo "  ✅ silica_text_echo"; \
				else \
					echo "  ❌ missing silica_text_echo"; failed=1; \
					$(INTEGRATE_DOT_FAIL); \
				fi ;; \
			*libsilica_net.a) \
				if echo "$$syms" | grep -Eq '(_?)silica_net_parse_port($$|[[:space:]])'; then \
					echo "  ✅ silica_net_parse_port"; \
				else \
					echo "  ❌ missing silica_net_parse_port"; failed=1; \
					$(INTEGRATE_DOT_FAIL); \
				fi ;; \
			*libsilica_abi_types.a) \
				if echo "$$syms" | grep -Eq '(_?)silica_abi_i64_identity($$|[[:space:]])'; then \
					echo "  ✅ silica_abi_i64_identity"; \
				else \
					echo "  ❌ missing silica_abi_i64_identity"; failed=1; \
					$(INTEGRATE_DOT_FAIL); \
				fi ;; \
		esac; \
	done; \
	test "$$failed" -eq 0

phase-0: verify-symbols
	@test -f "$(FIXTURES_DIR)/dangerous_exposure_source/legacy/silica_legacy_math_wrapper.meta"
	@test -f "$(FIXTURES_DIR)/dangerous_exposure_source/text/silica_text_wrapper.meta"
	@echo "✅ ffi_addition phase-0 complete"

module-valid: $(SILICA_COMPILER)
	@$(ENSURE_SILICA_COMPILER)
	@silica="$(MODULE_VALID_FILE)"; \
	base=$$(basename "$$silica" .silica); \
	tmpdir=$$(mktemp -d); \
	ln -s "$(THIS_DIR)$$silica" "$$tmpdir/$$base.silica"; \
	ln -s "$(FFI_SOURCE_VIEW)" "$$tmpdir/dangerous_exposure_source"; \
	echo "$$base.silica" > "$$tmpdir/silica.config"; \
	$(call TRIAL_SUPPORT_IN_TMP,$$tmpdir,$$base.silica); \
	out="$$tmpdir/out.txt"; \
	(cd "$$tmpdir" && { $(call RUN_SILICA_COMPILER_QUIET_WITH,"$(SILICA_COMPILER)"); }) > "$$out" 2>&1 || true; \
	if grep -qE '❌|Error error|ParseError|TypeError|EffectError|ModuleError' "$$out"; then \
		echo "  ❌ $$silica: expected compile success"; cat "$$out"; rm -rf "$$tmpdir"; exit 1; \
		$(INTEGRATE_DOT_FAIL); \
	elif ! grep -q "Type checking..." "$$out"; then \
		echo "  ❌ $$silica: did not reach type checking"; cat "$$out"; rm -rf "$$tmpdir"; exit 1; \
		$(INTEGRATE_DOT_FAIL); \
	else \
		echo "  ✅ $$silica: module rules OK through type check"; \
	fi; \
	rm -rf "$$tmpdir"

phase-3: module-valid
	@echo "✅ ffi_addition phase-3 complete"

abi-valid: $(SILICA_COMPILER)
	@$(MAKE) -C "$(THIS_DIR)abi_addition" integrate
	@echo "✅ ffi_addition abi-valid complete (abi_addition/)"

phase-4: phase-3
	@$(MAKE) -C "$(THIS_DIR)$(APP_SIDECAR_DIR)" integrate
	@echo "✅ ffi_addition phase-4 complete ($(APP_SIDECAR_DIR))"

phase-5: phase-4
	@$(MAKE) -C "$(THIS_DIR)$(APP_CAST_WORKER_DIR)" integrate
	@$(MAKE) -C "$(THIS_DIR)$(APP_CAST_WORKER_REGISTERED_DIR)" integrate
	@echo "✅ ffi_addition phase-5 complete ($(APP_CAST_WORKER_DIR), $(APP_CAST_WORKER_REGISTERED_DIR))"

phase-6: phase-5
	@$(MAKE) -C "$(THIS_DIR)$(APP_FFI_RESULT_CAST_DIR)" integrate
	@echo "✅ ffi_addition phase-6 complete ($(APP_FFI_RESULT_CAST_DIR))"

phase-7: phase-6
	@$(MAKE) -C "$(THIS_DIR)$(APP_FOREIGN_ABI_DIR)" integrate
	@$(MAKE) abi-valid
	@$(MAKE) -C "$(THIS_DIR)$(APP_FOREIGN_ABI_TYPES_E2E_DIR)" integrate
	@echo "✅ ffi_addition phase-7 complete ($(APP_FOREIGN_ABI_DIR), abi_addition/, $(APP_FOREIGN_ABI_TYPES_E2E_DIR))"

phase-8: phase-7 fixtures
	@$(ENSURE_SILICA_COMPILER)
	@$(MAKE) -C "$(THIS_DIR)$(APP_E2E_DIR)" integrate
	@echo "✅ ffi_addition phase-8 complete ($(APP_E2E_DIR))"

phase-9: fixtures
	@$(ENSURE_SILICA_COMPILER)
	@$(MAKE) integrate
	@echo "✅ ffi_addition phase-9 complete (manifest-driven link via app integrates)"

phase-11: fixtures
	@$(ENSURE_SILICA_COMPILER)
	@failed=0; \
	for dir in $(GUARDED_APP_DIRS); do \
		echo "=== ffi_addition/$$dir (guarded boundary) ==="; \
		$(MAKE) -C "$(THIS_DIR)$$dir" integrate || failed=1; \
	done; \
	test "$$failed" -eq 0
	@echo "✅ ffi_addition phase-11 complete (guarded FFI runtime boundary)"

phase-12: fixtures
	@$(ENSURE_SILICA_COMPILER)
	@failed=0; \
	for dir in $(ARENA_APP_DIRS); do \
		echo "=== ffi_addition/$$dir (per-actor FFI arena) ==="; \
		$(MAKE) -C "$(THIS_DIR)$$dir" integrate || failed=1; \
	done; \
	test "$$failed" -eq 0
	@echo "✅ ffi_addition phase-12 complete (per-actor FFI arena marshaling)"

phase-13: fixtures
	@$(ENSURE_SILICA_COMPILER)
	@$(MAKE) -C "$(THIS_DIR)$(APP_GUARDED_FAULT_DIR)" integrate
	@echo "✅ ffi_addition phase-13 complete (macOS guarded FFI fault bridge)"

phase-14: fixtures
	@$(ENSURE_SILICA_COMPILER)
	@$(MAKE) -C "$(THIS_DIR)$(APP_SUPERVISOR_DANGEROUS_FAULT_DIR)" integrate
	@echo "✅ ffi_addition phase-14 complete (supervisor + dangerous guarded FFI restart)"

phase-a: phase-0

# This platform's fixtures only; other platforms' directories under fixtures/build/ are not touched.
clean-fixtures:
	@rm -rf "$(FFI_PLATFORM_DIR)"

clean-apps:
	@for dir in $(APP_DIRS); do $(MAKE) -C "$(THIS_DIR)$$dir" clean; done
	@$(MAKE) -C "$(THIS_DIR)abi_addition" clean
	@$(MAKE) -C "$(THIS_DIR)$(APP_FOREIGN_ABI_TYPES_E2E_DIR)" clean

clean: clean-fixtures clean-apps
	@rm -f .integrate_counts
	@echo "✅ ffi_addition clean complete"

help:
	@echo "ffi_addition Makefile"
	@echo "====================="
	@echo ""
	@echo "App trials (runnable programs with .scout goldens):"
	@echo "  $(APP_SIDECAR_DIR)      - sidecar metadata + legacy math add via FFI worker"
	@echo "  $(APP_CAST_WORKER_DIR)  - spawn_dangerous worker with external_danger behavior"
	@echo "  $(APP_FFI_RESULT_CAST_DIR) - FFI result cast delivers external-danger-touched int64"
	@echo "  $(APP_FOREIGN_ABI_DIR)  - Silica-side ABI declarations compile and run"
	@echo "  abi_addition/           - compile-success trials for documented C ABI data shapes"
	@echo "  $(APP_FOREIGN_ABI_TYPES_E2E_DIR) - int64/boolean/record-by-value runtime ABI e2e"
	@echo "  $(APP_E2E_DIR) - scalar add and string echo end-to-end foreign calls"
	@echo ""
	@echo "Targets:"
	@echo "  all         - Success-path suite: phase-9 (all app integrates)"
	@echo "  integrate   - Run all app trial integrates and sum .integrate_counts"
	@echo "  phase-0     - Build fixture archives and verify exported symbols"
	@echo "  phase-3     - Module naming / export rules (module_addition/)"
	@echo "  phase-4..8  - One app trial integrate per phase (see app dirs above)"
	@echo "  phase-9     - All app integrates with silica.link-driven link (.scout goldens)"
	@echo "  phase-11    - Guarded FFI boundary app trials (legacy math add via enter/exit wrapper)"
	@echo "  phase-12    - Per-actor FFI arena app trials (string echo in/out via arena bump)"
	@echo "  (compile/link failure goldens: error_enforcement_addition/ffi_addition integrate)"
	@echo "  fixtures    - Build libsilica_legacy_math.a, libsilica_text.a, libsilica_net.a, libsilica_abi_types.a"
	@echo "  clean       - Remove fixture and app trial build artifacts"
