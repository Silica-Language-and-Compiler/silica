THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../../silica_compiler.mk

COMPILER ?= $(SILICA_COMPILER)
TRIAL_DIR := $(notdir $(patsubst %/,%,$(THIS_DIR)))
MSG_PREFIX := $(TRIAL_DIR)/
MAIN := device_my_uart

.DEFAULT_GOAL := all
.PHONY: all integrate check clean help silica.config

all: integrate

integrate-run: check

# Units in dependency order: the built-in device trait files first, then this trial's modules.
silica.config: | clean
silica.config:
	@cd "$(THIS_DIR)" && { \
		echo "../../../compiler/stdlib/DeviceDescription.silica"; \
		echo "../../../compiler/stdlib/Register32.silica"; \
		echo "device_my_uart.silica"; \
	} > silica.config && $(TRIAL_SUPPORT_CONFIG)

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
	@rm -f "$(THIS_DIR)$(MAIN).cur_fail" "$(THIS_DIR)silica.config" "$(THIS_DIR).integrate_counts" "$(THIS_DIR)"*.sams "$(THIS_DIR)"*.iface

help:
	@echo "$(TRIAL_DIR) (multi-file device error enforcement trial)"
	@echo "  integrate - regenerate silica.config, run the compiler, diff $(MAIN).cur_fail against $(MAIN).golden_fail"
