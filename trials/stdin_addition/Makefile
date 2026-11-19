# Standard-input trials (stdin_carrier_design.md section 8.1). Each trial is a sub-trial directory with its own
# Makefile (which includes trial.mk), so it is compiled as its own application: E2415 (standard input
# claimed twice) is checked across every module of one compile. Input: <base>.stdin, else /dev/null.
# A trial with no .ascomp skips the assembly comparison (see trial.mk).
# Run: make integrate SILICA_COMPILER=<path to silica-gen1>
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../silica_compiler.mk
TRIAL_DIR := $(notdir $(patsubst %/,%,$(THIS_DIR)))
MSG_PREFIX := $(TRIAL_DIR)/

SUB_TRIALS := stdin_lines_piped stdin_no_final_newline stdin_crlf stdin_empty stdin_line_too_long stdin_exit_line_is_data stdin_tx_refused stdin_second_open_in_use stdin_recreate_too_large stdin_recreate_bad_utf8 app_wait_for_exit_unchanged fail_stdin_tainted_chunk_printed fail_stdin_carrier_from_plain_module

.DEFAULT_GOAL := all
.PHONY: all clean integrate integrate-run

all: integrate

integrate-run:
	@rm -f .integrate_counts; ok=0; ko=0; failed=0; \
	for sub in $(SUB_TRIALS); do \
		[ -f "$(THIS_DIR)$$sub/Makefile" ] || continue; \
		if [ -f "$(THIS_DIR)$$sub/INTEGRATE_PENDING" ]; then echo "SKIP: $(MSG_PREFIX)$$sub (INTEGRATE_PENDING -- see $$sub/README.md)"; continue; fi; \
		if $(MAKE) -C "$(THIS_DIR)$$sub" integrate; then :; else failed=1; fi; \
		sf="$(THIS_DIR)$$sub/.integrate_counts"; \
		if [ -f "$$sf" ]; then \
			read sub_ok sub_ko < "$$sf" || true; \
			ok=$$((ok + $${sub_ok:-0})); \
			ko=$$((ko + $${sub_ko:-0})); \
		fi; \
	done; \
	[ "$$failed" -ne 0 ] && [ "$$ko" -eq 0 ] && ko=1; \
	printf '%d %d\n' "$$ok" "$$ko" > .integrate_counts; \
	exit $$failed

clean:
	@for sub in $(SUB_TRIALS); do [ -f "$(THIS_DIR)$$sub/Makefile" ] && $(MAKE) --no-print-directory -C "$(THIS_DIR)$$sub" clean; done; true
	@echo "✅ $(MSG_PREFIX)Clean complete"
