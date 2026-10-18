# Multi-file trial: a negative hexadecimal literal argument through a qualified call is checked against the parameter's range by its value (E2011).
# Run from this directory or via parent `make integrate` / `make all` (parent runs `make integrate` here).

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
	@cd "$(THIS_DIR)" && { $(call RUN_SILICA_COMPILER_QUIET_WITH,$(COMPILER)); } > main_negative_hex_literal_int8_just_under.cur_fail 2>&1 || true
	@if diff -q "$(THIS_DIR)main_negative_hex_literal_int8_just_under.cur_fail" "$(THIS_DIR)main_negative_hex_literal_int8_just_under.golden_fail" > /dev/null 2>&1; then \
		echo "✅✅ $(MSG_PREFIX)qualified_call_negative_hex_literal_int8_just_under_trial"; \
		$(INTEGRATE_DOT_OK); \
		printf '%d %d\n' 1 0 > "$(THIS_DIR).integrate_counts"; \
	else \
		echo "❌❌ $(MSG_PREFIX)qualified_call_negative_hex_literal_int8_just_under_trial: .cur_fail differs from .golden_fail"; \
		$(INTEGRATE_DOT_FAIL); \
		diff "$(THIS_DIR)main_negative_hex_literal_int8_just_under.cur_fail" "$(THIS_DIR)main_negative_hex_literal_int8_just_under.golden_fail" || true; \
		printf '%d %d\n' 0 1 > "$(THIS_DIR).integrate_counts"; \
		exit 1; \
	fi

clean:
	@rm -f "$(THIS_DIR)main_negative_hex_literal_int8_just_under.cur_fail" "$(THIS_DIR)silica.config" "$(THIS_DIR).integrate_counts"

silica.config:
	@printf '%s\n' \
		main_negative_hex_literal_int8_just_under.silica \
		LiteralLib.silica \
		> "$(THIS_DIR)silica.config" && cd "$(THIS_DIR)" && $(TRIAL_SUPPORT_CONFIG)

help:
	@echo "qualified_call_negative_hex_literal_int8_just_under_trial (multi-file error enforcement)"
	@echo "============================================================================="
	@echo "Targets:"
	@echo "  all       - Same as integrate (default)"
	@echo "  integrate - Regenerate silica.config, run compiler, diff vs .golden_fail"
	@echo "  check     - Run compiler + diff (assumes silica.config is current)"
	@echo "  clean     - Remove .cur_fail, silica.config, .integrate_counts"
	@echo "  help      - Show this help"
