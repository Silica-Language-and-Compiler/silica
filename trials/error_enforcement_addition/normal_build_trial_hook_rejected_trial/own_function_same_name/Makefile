# One run trial, compiled by the compiler in SILICA_COMPILER (the parent passes the normal compiler).
# Compile, assemble, link, run, and diff the output against own_function_same_name.scout.
# No .ascomp: the check is the program's output, which proves the name is an ordinary function.
SHELL := /bin/bash

THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../../../silica_compiler.mk
SILICA_LINK_SH := $(abspath $(THIS_DIR)../../../silica_link.sh)

TRIAL_DIR := $(notdir $(patsubst %/,%,$(THIS_DIR)))
MSG_PREFIX := $(TRIAL_DIR)/
MAIN := own_function_same_name

.DEFAULT_GOAL := integrate
.PHONY: clean help silica.config

silica.config: | clean
silica.config:
	@cd "$(THIS_DIR)" && echo "$(MAIN).silica" > silica.config && $(TRIAL_SUPPORT_CONFIG)

integrate-run:
	@$(MAKE) -f "$(THIS_DIR)Makefile" clean
	@$(MAKE) -f "$(THIS_DIR)Makefile" silica.config
	@cd "$(THIS_DIR)" || exit 1; \
	rm -f .integrate_counts; ok=0; ko=0; failed=0; \
	finish() { [ "$$failed" -ne 0 ] && [ "$$ko" -eq 0 ] && ko=$$((ko + 1)); printf '%d %d\n' "$$ok" "$$ko" > .integrate_counts; exit $$failed; }; \
	rm -f *.sams *.iface silica.compile.order silica.needs_runtime silica.link __silica_runtime.sams; \
	echo "Compiling with $(notdir $(SILICA_COMPILER))..."; \
	if ! { $(call RUN_SILICA_COMPILER_WITH,$(abspath $(SILICA_COMPILER))); }; then \
		echo "❌❌ $(MSG_PREFIX)compilation failed"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=1; failed=1; finish; \
	fi; \
	for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		echo "Assembling $$sams..."; \
		if ! $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "$$base.o"; then \
			echo "❌❌ $(MSG_PREFIX)$$base assemble failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; finish; \
		fi; \
	done; \
	link_archives=$$("$(SILICA_LINK_SH)" .); \
	$(TRIAL_SUPPORT_ASSEMBLE); \
	runtime_obj=""; \
	[ -f "__silica_runtime.o" ] && runtime_obj="__silica_runtime.o"; \
	runtime_obj="$$runtime_obj $(call TRIAL_SUPPORT_OBJ,$(MAIN).silica)"; \
	echo "Linking $(MAIN)..."; \
	if test -x "$(RUST_LLD)"; then \
		$(RUST_LLD) -flavor darwin -o "$(MAIN)" "$(MAIN).o" $$runtime_obj $$link_archives $(LDFLAGS_rust-lld) || { echo "❌❌ $(MSG_PREFIX)$(MAIN) link failed"; $(INTEGRATE_DOT_FAIL); ko=$$((ko + 1)); failed=1; finish; }; \
	else \
		$(ASSEMBLER) "$(MAIN).o" $$runtime_obj $$link_archives -o "$(MAIN)" $(LDFLAGS_clang) || { echo "❌❌ $(MSG_PREFIX)$(MAIN) link failed"; $(INTEGRATE_DOT_FAIL); ko=$$((ko + 1)); failed=1; finish; }; \
	fi; \
	$(call INTEGRATE_RUN_TRIAL,$(MSG_PREFIX)$(MAIN),$(MAIN)$(SOUT_EXT),./$(MAIN)); \
	if [ "$$integrate_killed" = 1 ]; then \
		echo "❌❌ $(MSG_PREFIX)$(MAIN) $(INTEGRATE_KILLED_MSG)"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + 1)); failed=1; finish; \
	fi; \
	if [ ! -f "$(call SCOUT_FOR,$(MAIN))" ]; then \
		echo "❌❌ $(MSG_PREFIX)$(MAIN) has no .scout file"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + 1)); failed=1; \
	elif ! diff -Bw -q "$(MAIN)$(SOUT_EXT)" "$(call SCOUT_FOR,$(MAIN))" > /dev/null 2>&1; then \
		echo "❌❌ $(MSG_PREFIX)$(MAIN) .sout differs from .scout"; \
		$(INTEGRATE_DOT_FAIL); \
		diff -Bw "$(MAIN)$(SOUT_EXT)" "$(call SCOUT_FOR,$(MAIN))" || true; \
		ko=$$((ko + 1)); failed=1; \
	else \
		echo "✅✅ $(MSG_PREFIX)$(MAIN) output matches .scout"; \
		$(INTEGRATE_DOT_OK); \
		ok=$$((ok + 1)); \
	fi; \
	finish

clean:
	@cd "$(THIS_DIR)" && rm -f *.sams *.o *.iface $(MAIN) $(MAIN)*.sout silica.config silica.compile.order silica.needs_runtime silica.link silica.atoms silica.shapes .integrate_counts __silica_runtime.sams && { [ ! -d .trial_stdlib ] || find .trial_stdlib -mindepth 1 -delete; rmdir .trial_stdlib 2>/dev/null; true; }
	@echo "✅ $(MSG_PREFIX)Clean complete"

help:
	@echo "$(TRIAL_DIR): compile with the normal compiler, link, run, diff $(MAIN).sout against $(MAIN).scout"
