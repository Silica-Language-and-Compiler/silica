THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../../silica_compiler.mk

COMPILER ?= $(SILICA_COMPILER)
TRIAL_DIR := $(notdir $(patsubst %/,%,$(THIS_DIR)))
MSG_PREFIX := $(TRIAL_DIR)/
MAIN := cast_check_cross_module_param

.DEFAULT_GOAL := all
.PHONY: all integrate check clean help silica.config

all: integrate

integrate-run: check

# Units in dependency order: the library whose function casts to its parameter, then this trial.
silica.config: | clean
silica.config:
	@cd "$(THIS_DIR)" && { \
		echo "cast_check_param_lib.silica"; \
		echo "cast_check_cross_module_param.silica"; \
	} > silica.config

check: silica.config
	@cd "$(THIS_DIR)" && { $(call RUN_SILICA_COMPILER_QUIET_WITH,$(COMPILER)); } > $(MAIN).cur_fail 2>&1 || true
	@if diff -q "$(THIS_DIR)$(MAIN).cur_fail" "$(or $(wildcard $(THIS_DIR)$(MAIN)$(GOLDEN_FAIL_EXT).golden_fail),$(THIS_DIR)$(MAIN).golden_fail)" > /dev/null 2>&1; then \
		echo "✅✅ $(MSG_PREFIX)$(TRIAL_DIR)"; \
		$(INTEGRATE_DOT_OK); \
		printf '%d %d\n' 1 0 > "$(THIS_DIR).integrate_counts"; \
	else \
		echo "❌❌ $(MSG_PREFIX)$(TRIAL_DIR): .cur_fail differs from .golden_fail"; \
		$(INTEGRATE_DOT_FAIL); \
		diff "$(THIS_DIR)$(MAIN).cur_fail" "$(or $(wildcard $(THIS_DIR)$(MAIN)$(GOLDEN_FAIL_EXT).golden_fail),$(THIS_DIR)$(MAIN).golden_fail)" || true; \
		printf '%d %d\n' 0 1 > "$(THIS_DIR).integrate_counts"; \
		exit 1; \
	fi

clean:
	@rm -rf "$(THIS_DIR)$(MAIN).cur_fail" "$(THIS_DIR)silica.config" "$(THIS_DIR).integrate_counts" "$(THIS_DIR)"*.sams "$(THIS_DIR)"*.iface "$(THIS_DIR).trial_stdlib"

help:
	@echo "$(TRIAL_DIR) (E2237: a call-only actor passed to another module function that casts to it)"
	@echo "  integrate - regenerate silica.config, run the compiler, diff $(MAIN).cur_fail against $(MAIN).golden_fail"
