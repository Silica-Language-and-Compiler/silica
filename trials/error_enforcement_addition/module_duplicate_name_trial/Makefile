# Multi-file trial: two files in one build share a module name (a/alpha.silica and b/alpha.silica); E4012 (spec §19.3.1).
# Run from this directory or via parent `make integrate` / `make all` (parent runs `make integrate` here).

THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../../silica_compiler.mk
# Same binary as parent SILICA_COMPILER; parent passes COMPILER= when invoking.
COMPILER ?= $(SILICA_COMPILER)

TRIAL_DIR := $(notdir $(patsubst %/,%,$(THIS_DIR)))
MSG_PREFIX := $(TRIAL_DIR)/


.DEFAULT_GOAL := all
.PHONY: all integrate check clean help silica.config

# Parent: integrate -> silica.config all; sub: all == integrate == silica.config + golden check.
all: integrate

integrate-run: check

check: silica.config
	@cd "$(THIS_DIR)" && { $(call RUN_SILICA_COMPILER_QUIET_WITH,$(COMPILER)); } > main_duplicate_name.cur_fail 2>&1 || true
	@if diff -q "$(THIS_DIR)main_duplicate_name.cur_fail" "$(or $(wildcard $(THIS_DIR)main_duplicate_name$(GOLDEN_FAIL_EXT).golden_fail),$(THIS_DIR)main_duplicate_name.golden_fail)" > /dev/null 2>&1; then \
		echo "✅✅ $(MSG_PREFIX)module_duplicate_name_trial"; \
		$(INTEGRATE_DOT_OK); \
		printf '%d %d\n' 1 0 > "$(THIS_DIR).integrate_counts"; \
	else \
		echo "❌❌ $(MSG_PREFIX)module_duplicate_name_trial: .cur_fail differs from .golden_fail"; \
		$(INTEGRATE_DOT_FAIL); \
		diff "$(THIS_DIR)main_duplicate_name.cur_fail" "$(or $(wildcard $(THIS_DIR)main_duplicate_name$(GOLDEN_FAIL_EXT).golden_fail),$(THIS_DIR)main_duplicate_name.golden_fail)" || true; \
		printf '%d %d\n' 0 1 > "$(THIS_DIR).integrate_counts"; \
		exit 1; \
	fi

clean:
	@rm -f "$(THIS_DIR)main_duplicate_name.cur_fail" "$(THIS_DIR)silica.config" "$(THIS_DIR).integrate_counts"

# Under -j, `clean` must finish before silica.config is written (clean deletes it).
silica.config: | clean

silica.config:
	@cd "$(THIS_DIR)" && find "$$PWD" -type f -name '*.silica' | sed "s|^$$PWD/||" | LC_ALL=C sort > silica.config && $(TRIAL_SUPPORT_CONFIG)

help:
	@echo "module_duplicate_name_trial (multi-file error enforcement)"
	@echo "=============================================================="
	@echo "Targets:"
	@echo "  all       - Same as integrate (default)"
	@echo "  integrate - Regenerate silica.config, run compiler, diff vs .golden_fail"
	@echo "  check     - Run compiler + diff (assumes silica.config is current)"
	@echo "  clean     - Remove .cur_fail, silica.config, .integrate_counts"
	@echo "  help      - Show this help"
