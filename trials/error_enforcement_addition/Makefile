# Makefile for Silica error enforcement trials
# Files to test: all *.silica directly in this directory (the multi-file trials in
# SUB_TRIALS use their own Makefile + silica.config).
# Each single-file trial is compiled in isolation inside a temporary directory: a symlink to
# the .silica file and a single-entry silica.config are created there, the
# compiler is run, then the temp directory is removed.
# Compiler output is captured to *.cur_fail and diffed against *.golden_fail.
# If a source path has a sidecar "<same-stem>.no_golden_fail" (empty marker next to
# "<stem>.silica"), that file is skipped by the single-file rule (no .golden_fail required).
# Reports ✅✅ on match, ❌❌ on mismatch or missing .golden_fail.
# Exits with failure if any check fails.
#
# The single-file trials are independent, so each is a pattern rule (%.cur_fail: %.silica)
# and `integrate` runs them under make's jobserver; SUB_TRIALS run concurrently with them.
# Each result is one line appended to .integrate_results; the totals come from that file.
#
# Run from this directory: cd error_enforcement_addition && make integrate

THIS_DIR        := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../silica_compiler.mk
TRIAL_DIR := $(notdir $(patsubst %/,%,$(THIS_DIR)))
MSG_PREFIX := $(TRIAL_DIR)/

# Multi-file trials (subdir Makefile generates silica.config on integrate).
SUB_TRIALS      := ffi_addition module_duplicate_name_trial module_nonexported_callee_trial module_cycle_trial unqualified_import_call_one_use_trial unqualified_import_call_two_modules_trial unqualified_import_call_no_use_trial qualified_call_module_name_case_mismatch_trial qualified_call_wrong_arg_count_trial qualified_call_too_many_args_trial qualified_call_literal_out_of_range_trial qualified_call_literal_negative_trial qualified_call_hex_literal_out_of_range_trial qualified_call_hex_literal_uint8_just_over_trial qualified_call_negative_hex_literal_int8_just_under_trial supervisor_agent_type_invalid_atom_trial supervisor_duplicate_child_id_trial standard_data_structures \
	device_peek_missing_marker_trial device_poke_missing_marker_trial device_peek_marker_type_trial device_peek_marker_width_trial device_poke_read_only_trial device_peek_write_only_trial device_register_not_described_trial device_description_second_trial device_description_not_literal_trial device_description_duplicate_name_trial device_description_bad_width_trial device_description_misaligned_trial device_description_overlap_trial device_description_bad_access_trial device_description_empty_trial description_outside_device_module_trial device_module_uses_dangerous_trial main_uses_device_module_trial device_hosted_rejection_trial \
	board_pack_tag_described_trial board_pack_tag_described_bad_body_trial board_pack_wrong_pack_module_trial \
	device_uart_hello_trial device_discarded_peek_trial device_cast_registered_trial device_client_result_trial device_fault_lines_trial device_fault_lines_registered_trial device_gpio_button_trial device_window_param_survives_let_trial device_led_row_constant_heap_trial \
	e2236_supervisor_without_reporter_trial e2236_supervisor_before_registration_trial e2236_helper_starts_supervisor_trial e2236_lib_start_without_reporter_trial e2236_lib_start_through_local_call_trial \
	cast_check_supervisor_child_trial cast_check_cross_module_trial cast_check_cross_module_param_trial

# Single-file trial sources: every *.silica directly in this directory. $(wildcard)
# rather than $(shell find): the tree holds ~20k files and this file is parsed several times.
SILICA_FILES := $(sort $(notdir $(wildcard $(THIS_DIR)*.silica)))
CUR_FAILS := $(SILICA_FILES:.silica=.cur_fail)
SUB_TARGETS := $(SUB_TRIALS:%=ee-sub-%)

.DEFAULT_GOAL := all
.PHONY: all integrate-run ee-units clean help silica.config $(SUB_TARGETS)

silica.config:
	@# Listed by the shell, not expanded into the recipe: ~11k names exceed Linux's 128 KB limit on one argument.
	@cd "$(THIS_DIR)" && find . -maxdepth 1 -name '*.silica' \( -type f -o -type l \) | sed 's|^\./||' | LC_ALL=C sort > silica.config

# integrate (wrapper in silica_compiler.mk) -> integrate-run. Sequential sub-makes:
# clean must finish before silica.config is written.
integrate-run:
	@$(MAKE) -f "$(THIS_DIR)Makefile" clean
	@$(MAKE) -f "$(THIS_DIR)Makefile" silica.config
	@$(MAKE) -f "$(THIS_DIR)Makefile" all

all: | clean
	@cd "$(THIS_DIR)" && : > .integrate_results && rm -f $(SUB_TRIALS:%=%/.integrate_counts)
	@cd "$(THIS_DIR)" && $(MAKE) --no-print-directory -k -f "$(INTEGRATE_MAKEFILE)" ee-units || true
	@cd "$(THIS_DIR)" && ok=$$(grep -c '^PASS' .integrate_results); ko=$$(grep -c '^FAIL' .integrate_results); failed=0; \
	[ "$$ko" -ne 0 ] && failed=1; \
	echo "$(MSG_PREFIX)single-file trials: $$ok matched .golden_fail, $$ko differed or missing"; \
	for sub in $(SUB_TRIALS); do \
		[ -f "$$sub/.integrate_skipped" ] && continue; \
		n1=0; n2=0; \
		if [ -f "$$sub/.integrate_counts" ]; then read n1 n2 < "$$sub/.integrate_counts" || true; fi; \
		n1=$${n1:-0}; n2=$${n2:-0}; \
		cst=$$(cat "$$sub/.integrate_status" 2>/dev/null || echo 1); \
		if [ "$$cst" -ne 0 ] && [ "$$n2" -eq 0 ]; then n2=1; fi; \
		ok=$$((ok + n1)); ko=$$((ko + n2)); \
		[ "$$n2" -ne 0 ] && failed=1; \
	done; \
	[ "$$failed" -ne 0 ] && [ "$$ko" -eq 0 ] && ko=$$((ko + 1)); \
	printf '%d %d\n' "$$ok" "$$ko" > .integrate_counts; \
	exit $$failed

ee-units: $(CUR_FAILS) $(SUB_TARGETS)

# One single-file trial. Never fails the make: every outcome is a results line.
%.cur_fail: %.silica
	@cd "$(THIS_DIR)" && base="$*"; \
	if [ -f "$$base.no_golden_fail" ]; then exit 0; fi; \
	gf="$$base.golden_fail"; if [ -f "$$base$(GOLDEN_FAIL_EXT).golden_fail" ]; then gf="$$base$(GOLDEN_FAIL_EXT).golden_fail"; fi; \
	if [ ! -f "$$gf" ]; then \
		echo "❌❌ $(MSG_PREFIX)$$base: no matching .golden_fail file"; \
		$(INTEGRATE_DOT_FAIL); \
		printf 'FAIL\t%s\tno matching .golden_fail file\n' "$$base" >> .integrate_results; \
		exit 0; \
	fi; \
	tmpdir=$$(mktemp -d); \
	ln -s "$(THIS_DIR)$$base.silica" "$$tmpdir/$$base.silica"; \
	echo "$$base.silica" > "$$tmpdir/silica.config"; \
	$(call TRIAL_SUPPORT_IN_TMP,$$tmpdir,$$base.silica); \
	(cd "$$tmpdir" && { $(call RUN_SILICA_COMPILER_QUIET_WITH,$(SILICA_COMPILER)); }) > "$$base.cur_fail" 2>&1 || true; \
	rm -rf "$$tmpdir"; \
	if diff -q "$$base.cur_fail" "$$gf" > /dev/null 2>&1; then \
		echo "✅✅ $(MSG_PREFIX)$$base"; \
		$(INTEGRATE_DOT_OK); \
		printf 'PASS\t%s\n' "$$base" >> .integrate_results; \
	else \
		{ echo "❌❌ $(MSG_PREFIX)$$base: .cur_fail differs from .golden_fail"; \
		$(INTEGRATE_DOT_FAIL); \
		  diff "$$base.cur_fail" "$$gf" || true; } > "$$base.cur_fail.msg"; \
		cat "$$base.cur_fail.msg"; rm -f "$$base.cur_fail.msg"; \
		printf 'FAIL\t%s\t.cur_fail differs from .golden_fail\n' "$$base" >> .integrate_results; \
	fi

# One multi-file trial directory (its own Makefile, log and report).
$(SUB_TARGETS): ee-sub-%:
	@$(call INTEGRATE_CHILD,$*,COMPILER="$(SILICA_COMPILER)")

clean:
	@find "$(THIS_DIR)" -maxdepth 1 \( -name '*.cur_fail' -o -name '*.cur_fail.msg' \) -type f -delete 2>/dev/null || true
	@rm -f "$(THIS_DIR)silica.config" "$(THIS_DIR).integrate_counts" "$(THIS_DIR).integrate_results"
	@for sub in $(SUB_TRIALS); do $(MAKE) -C "$(THIS_DIR)$$sub" clean; done
	@echo "✅ $(MSG_PREFIX)Clean complete"

help:
	@echo "Makefile - Silica error enforcement trials"
	@echo "=========================================="
	@echo "Single-file list: *.silica here (SUB_TRIALS: $(SUB_TRIALS) have their own Makefiles)."
	@echo "Each file is compiled in an isolated temp directory with a one-line silica.config;"
	@echo "compiler output is captured to .cur_fail and compared to .golden_fail."
	@echo "Files with a sidecar .no_golden_fail are skipped."
	@echo ""
	@echo "Targets:"
	@echo "  integrate - Single-file trials and SUB_TRIALS in parallel, then this directory's report"
	@echo "              ✅✅ = output matches .golden_fail"
	@echo "              ❌❌ = output differs, file not found, or missing .golden_fail (when not skipped)"
	@echo "  all       - Same as integrate-run without the report wrapper"
	@echo "  clean     - Remove .cur_fail files, silica.config, and .integrate_counts"
	@echo "  help      - Show this help"
	@echo ""
	@echo "Single-file trials: $(words $(SILICA_FILES))"
