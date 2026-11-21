# Multi-file trial: a child supervisor start function with an invalid :dangerous row fails.

THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../../silica_compiler.mk
COMPILER ?= $(SILICA_COMPILER)

TRIAL_DIR := $(notdir $(patsubst %/,%,$(THIS_DIR)))
MSG_PREFIX := $(TRIAL_DIR)/

.DEFAULT_GOAL := all
.PHONY: all integrate check clean help silica.config

all: integrate

# Sequential: clean must not run after silica.config (sibling prereqs can reorder).
integrate-run:
	@$(MAKE) -f "$(THIS_DIR)Makefile" clean
	@$(MAKE) -f "$(THIS_DIR)Makefile" silica.config
	@$(MAKE) -f "$(THIS_DIR)Makefile" check

check: silica.config
	@cd "$(THIS_DIR)" && { $(call RUN_SILICA_COMPILER_QUIET_WITH,$(COMPILER)); } > sub_supervisor_dangerous_row_plain_id.cur_fail 2>&1 || true
	@if diff -q "$(THIS_DIR)sub_supervisor_dangerous_row_plain_id.cur_fail" "$(THIS_DIR)sub_supervisor_dangerous_row_plain_id.golden_fail" > /dev/null 2>&1; then \
		echo "✅✅ $(MSG_PREFIX)sub_supervisor_dangerous_row_plain_id"; \
		$(INTEGRATE_DOT_OK); \
		printf '%d %d\n' 1 0 > "$(THIS_DIR).integrate_counts"; \
	else \
		echo "❌❌ $(MSG_PREFIX)sub_supervisor_dangerous_row_plain_id: .cur_fail differs from .golden_fail"; \
		$(INTEGRATE_DOT_FAIL); \
		diff "$(THIS_DIR)sub_supervisor_dangerous_row_plain_id.cur_fail" "$(THIS_DIR)sub_supervisor_dangerous_row_plain_id.golden_fail" || true; \
		printf '%d %d\n' 0 1 > "$(THIS_DIR).integrate_counts"; \
		exit 1; \
	fi

clean:
	@rm -f "$(THIS_DIR)sub_supervisor_dangerous_row_plain_id.cur_fail" "$(THIS_DIR)silica.config" "$(THIS_DIR).integrate_counts"

silica.config:
	@cd "$(THIS_DIR)" && printf '%s\n%s\n' \
		"sub_supervisor_dangerous_row_plain_id.silica" \
		"../../../compiler/stdlib/Supervisor.silica" > silica.config && $(TRIAL_PRIVATE_SUPERVISOR)

help:
	@echo "sub_supervisor_dangerous_row_plain_id (multi-file error enforcement)"
	@echo "======================================================================"
	@echo "Targets:"
	@echo "  all       - Same as integrate (default)"
	@echo "  integrate - Regenerate silica.config, run compiler, diff vs .golden_fail"
	@echo "  check     - Run compiler + diff (assumes silica.config is current)"
	@echo "  clean     - Remove .cur_fail, silica.config, .integrate_counts"
	@echo "  help      - Show this help"
