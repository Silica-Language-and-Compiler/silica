# Lexer error E0007 InvalidUtf8 (spec §2.1) on a source file of exactly three bytes, C8 08 94: the
# lead byte C8 is followed by 08, which is not a continuation byte, and the file ends on the lone
# continuation byte 94. The file holds nothing else, so the trial's explanation lives here and in
# README.md rather than in a comment inside the source.
#
# HANG-CLASS TRIAL: a compiler older than the fixed-point build that carries the 2026-10-16 lexer
# changes (binaries/silica-999949 and earlier; and gen1 of that build on some other invalid-UTF-8
# inputs) never finishes lexing this file. It has its own directory so the compile can run under a
# short alarm (SILICA_COMPILE_TIMEOUT below, instead of the shared 900 s): an older compiler is
# stopped after two minutes (exit 142) and the trial fails cleanly with ".cur_fail differs".
#
# Run from this directory: make integrate   (or from trials/: make integrate)
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../silica_compiler.mk

# The fixed-point compiler lexes the three bytes in milliseconds; anything longer is the old hang.
SILICA_COMPILE_TIMEOUT := 120

COMPILER ?= $(SILICA_COMPILER)
TRIAL_DIR := $(notdir $(patsubst %/,%,$(THIS_DIR)))
MSG_PREFIX := $(TRIAL_DIR)/
MAIN := lexer_e0007_three_byte_file

.DEFAULT_GOAL := all
.PHONY: all integrate check clean help silica.config

all: integrate

integrate-run: check

silica.config: | clean
silica.config:
	@cd "$(THIS_DIR)" && echo "$(MAIN).silica" > silica.config

check: silica.config
	@cd "$(THIS_DIR)" && { $(call RUN_SILICA_COMPILER_QUIET_WITH,$(COMPILER)); } > $(MAIN).cur_fail 2>&1 || true
	@if diff -q "$(THIS_DIR)$(MAIN).cur_fail" "$(or $(wildcard $(THIS_DIR)$(MAIN)$(GOLDEN_FAIL_EXT).golden_fail),$(THIS_DIR)$(MAIN).golden_fail)" > /dev/null 2>&1; then \
		echo "✅✅ $(MSG_PREFIX)$(MAIN)"; \
		$(INTEGRATE_DOT_OK); \
		printf '%d %d\n' 1 0 > "$(THIS_DIR).integrate_counts"; \
	else \
		echo "❌❌ $(MSG_PREFIX)$(MAIN): .cur_fail differs from .golden_fail"; \
		$(INTEGRATE_DOT_FAIL); \
		diff "$(THIS_DIR)$(MAIN).cur_fail" "$(or $(wildcard $(THIS_DIR)$(MAIN)$(GOLDEN_FAIL_EXT).golden_fail),$(THIS_DIR)$(MAIN).golden_fail)" || true; \
		printf '%d %d\n' 0 1 > "$(THIS_DIR).integrate_counts"; \
		exit 1; \
	fi

clean:
	@rm -rf "$(THIS_DIR)$(MAIN).cur_fail" "$(THIS_DIR)silica.config" "$(THIS_DIR).integrate_counts" "$(THIS_DIR)"*.sams "$(THIS_DIR)"*.iface "$(THIS_DIR)silica.atoms" "$(THIS_DIR)silica.shapes"

help:
	@echo "$(TRIAL_DIR) (E0007: a three-byte source file C8 08 94; hangs compilers older than the 2026-10-16 lexer fixed point)"
	@echo "  integrate - write silica.config, run the compiler under a $(SILICA_COMPILE_TIMEOUT) s alarm, diff $(MAIN).cur_fail against $(MAIN).golden_fail"
