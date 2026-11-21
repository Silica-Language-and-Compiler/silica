# The trial hook (a builtin used only by trials) is built only into trial compilers
# (make build TRIAL_BUILD=1). The trials in this directory are compiled by the NORMAL compiler
# ($(SILICA_NORMAL_COMPILER), see silica_compiler.mk), and check what a normal build does with that name:
#   hook_call_rejected/        a call to supervision_ingress_enqueue is rejected: E2007 unknown function
#   own_function_same_name/    a program's own function of that name is an ordinary function and runs
# The two trials are separate directories so that the rejected unit cannot take the other with it.
# Each child is run with SILICA_COMPILER set to the normal compiler. COMPILER is set to it as well:
# error_enforcement_addition/Makefile passes COMPILER=<trial compiler>, which MAKEFLAGS would carry down.

THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../../silica_compiler.mk

SUB_TRIALS := hook_call_rejected own_function_same_name

.PHONY: integrate-run clean help $(SUB_TRIALS:%=nb-sub-%)

.DEFAULT_GOAL := integrate-run

integrate-run:
	@[ -x "$(SILICA_NORMAL_COMPILER)" ] || { echo "Missing normal compiler $(SILICA_NORMAL_COMPILER): build it with make -C compiler/src build SILICA_TARGET_PROMPT=0 INSTALL_SELFHOST=0"; exit 1; }
	@cd "$(THIS_DIR)" && rm -f $(SUB_TRIALS:%=%/.integrate_counts)
	@cd "$(THIS_DIR)" && $(MAKE) --no-print-directory -f "$(INTEGRATE_MAKEFILE)" $(SUB_TRIALS:%=nb-sub-%) || true
	@cd "$(THIS_DIR)" && $(call INTEGRATE_SUM_CHILDREN,$(SUB_TRIALS)); \
	[ "$$ko" -eq 0 ] && [ "$$failed" -eq 0 ]

$(SUB_TRIALS:%=nb-sub-%): nb-sub-%:
	@$(call INTEGRATE_CHILD,$*,SILICA_COMPILER="$(SILICA_NORMAL_COMPILER)" COMPILER="$(SILICA_NORMAL_COMPILER)")

clean:
	@for sub in $(SUB_TRIALS); do $(MAKE) -C "$(THIS_DIR)$$sub" clean SILICA_COMPILER="$(SILICA_NORMAL_COMPILER)" || true; done
	@rm -f "$(THIS_DIR).integrate_counts"
	@echo "✅ $(notdir $(patsubst %/,%,$(THIS_DIR)))/ Clean complete"

help:
	@echo "normal_build_trial_hook_rejected_trial: trial-hook name in a normal build (compiled by $(SILICA_NORMAL_COMPILER))"
	@echo "  integrate - run $(SUB_TRIALS) and sum their counts"
