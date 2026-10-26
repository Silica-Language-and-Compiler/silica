# Module trials: library sources under lib/ have no main(). Only entry-point units are linked and run.
# silica.config lists lib/*.silica + root entry *.silica (refreshed via find before compile / integrate).
# Default `make` compiles only; `make integrate` runs assembly diffs, link, run, and output diffs.

THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../silica_compiler.mk

TRIAL_DIR := $(notdir $(patsubst %/,%,$(THIS_DIR)))
MSG_PREFIX := $(TRIAL_DIR)/


RUST_SYSROOT := $(shell rustc --print sysroot 2>/dev/null)
RUST_TARGET := $(shell rustc -vV 2>/dev/null | sed -n "s/^host: *//p")
RUST_LLD := $(RUST_SYSROOT)/lib/rustlib/$(RUST_TARGET)/bin/rust-lld
LINKER := $(shell test -x "$(RUST_LLD)" && echo "$(RUST_LLD)" || echo "clang")
ASSEMBLER := clang

MACOS_SDK := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
MACOS_MIN_VERSION ?= 26.0
ASFLAGS_macos := -mmacosx-version-min=$(MACOS_MIN_VERSION)
LDFLAGS_rust-lld := -arch arm64 -platform_version macos $(MACOS_MIN_VERSION) $(MACOS_MIN_VERSION) -syslibroot $(MACOS_SDK) -lSystem -e main
LDFLAGS_clang := -Wl,-e,main -Wl,-macos_version_min,$(MACOS_MIN_VERSION)

.PHONY: all integrate clean help silica.config

silica.config:
	@cd "$(THIS_DIR)" && find "$$PWD" -type f -name '*.silica' | sed "s|^$$PWD/||" | LC_ALL=C sort > silica.config && $(TRIAL_SUPPORT_CONFIG)

.DEFAULT_GOAL := all

all: clean silica.config
	@cd "$(THIS_DIR)" && \
	rm -f *.sams *.iface silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link __silica_runtime.sams lib/*.sams && \
	echo "Compiling with silica-compiler..." && \
	if ! { $(RUN_SILICA_COMPILER); }; then \
		echo "❌❌ $(MSG_PREFIX)compilation failed"; \
		$(INTEGRATE_DOT_FAIL); \
		exit 1; \
	fi && \
	echo "✅ $(MSG_PREFIX)Assembly generated"

integrate-run:
	@$(MAKE) -f "$(THIS_DIR)Makefile" clean
	@$(MAKE) -f "$(THIS_DIR)Makefile" silica.config
	@$(MAKE) -f "$(THIS_DIR)Makefile" all
	@cd "$(THIS_DIR)" && \
	rm -f .integrate_counts; ok=0; ko=0; failed=0; \
	for line in $$(grep -v '^#' silica.config 2>/dev/null | grep -v '^$$' | grep -v '^\.trial_stdlib/' | grep -v '^lib/'); do \
		base=$${line%.silica}; \
		sams="$$base.sams"; \
		if [ ! -f "$$sams" ]; then \
			echo "❌❌ $(MSG_PREFIX)$$base: missing $$sams"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
			continue; \
		fi; \
		if [ ! -f "$$base$(ASCOMP_EXT)" ]; then \
			echo "❌❌ $(MSG_PREFIX)$$base has no .ascomp file"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		elif ! diff -Bw -q "$$sams" "$$base$(ASCOMP_EXT)" > /dev/null 2>&1; then \
			echo "❌❌ $(MSG_PREFIX)$$base .sams differs from .ascomp"; \
			$(INTEGRATE_DOT_FAIL); \
			diff -Bw "$$sams" "$$base$(ASCOMP_EXT)" || true; \
			ko=$$((ko + 1)); failed=1; \
		else \
			echo "✅✅ $(MSG_PREFIX)$$base assembly matches .ascomp"; \
			$(INTEGRATE_DOT_OK); \
			ok=$$((ok + 1)); \
		fi; \
	done; \
	for line in $$(grep -v '^#' silica.config 2>/dev/null | grep -v '^$$' | grep -v '^\.trial_stdlib/' | grep -v '^lib/'); do \
		base=$${line%.silica}; \
		sams="$$base.sams"; \
		[ -f "$$sams" ] || continue; \
		echo "Assembling $$sams..."; \
		if ! $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "$$base.o"; then \
		echo "❌❌ $(MSG_PREFIX)$$base assemble failed"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + 1)); failed=1; break; \
	fi; \
	done; \
	if [ -f "__silica_runtime.sams" ]; then \
		echo "Assembling __silica_runtime.sams..."; \
		if ! $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "__silica_runtime.sams" -o "__silica_runtime.o"; then \
		echo "❌❌ $(MSG_PREFIX)__silica_runtime assemble failed"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + 1)); failed=1; \
	fi; \
	fi; \
	for sams in lib/*.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$$(basename "$$sams" .sams); \
		obj="lib/$$base.o"; \
		echo "Assembling $$sams..."; \
		if ! $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "$$obj"; then \
		echo "❌❌ $(MSG_PREFIX)$$obj assemble failed"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + 1)); failed=1; break; \
	fi; \
	done; \
	for line in $$(grep -v '^#' silica.config 2>/dev/null | grep -v '^$$' | grep -v '^\.trial_stdlib/' | grep -v '^lib/'); do \
		base=$${line%.silica}; \
		[ -f "$$base.o" ] || continue; \
		echo "Linking $$base..."; \
		lib_objs=""; \
		for lib_obj in lib/*.o; do \
			[ -f "$$lib_obj" ] && lib_objs="$$lib_objs $$lib_obj"; \
		done; \
		[ -n "$$tsa_done" ] || { $(TRIAL_SUPPORT_ASSEMBLE); tsa_done=1; }; \
		runtime_obj=""; \
		[ -f "__silica_runtime.o" ] && runtime_obj="__silica_runtime.o"; \
		runtime_obj="$$runtime_obj $(call TRIAL_SUPPORT_OBJ,$$base.silica)"; \
		if test -x "$(RUST_LLD)"; then \
						if ! $(RUST_LLD) -flavor darwin -o "$$base" "$$base.o" $$lib_objs $$runtime_obj $(LDFLAGS_rust-lld); then \
				echo "❌❌ $(MSG_PREFIX)$$base link failed"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; \
			fi; \
		else \
			if ! $(ASSEMBLER) "$$base.o" $$lib_objs $$runtime_obj -o "$$base" $(LDFLAGS_clang); then \
			echo "❌❌ $(MSG_PREFIX)$$base link failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		fi; \
		fi; \
	done; \
	for line in $$(grep -v '^#' silica.config 2>/dev/null | grep -v '^$$' | grep -v '^\.trial_stdlib/' | grep -v '^lib/'); do \
		base=$${line%.silica}; \
		if [ ! -x "$$base" ]; then \
			echo "❌❌ $(MSG_PREFIX)$$base missing executable (assemble/link failed earlier)"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
	elif [ -x "$$base" ]; then \
			$(call INTEGRATE_RUN_TRIAL,$(MSG_PREFIX)$$base,$$base.sout,./$$base); \
			if [ "$$integrate_killed" = 1 ]; then \
				echo "❌❌ $(MSG_PREFIX)$$base $(INTEGRATE_KILLED_MSG)"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; continue; \
			fi; \
			if [ -f "$(call SCOUT_FOR,$$base)" ]; then \
				if ! diff -Bw -q "$$base.sout" "$(call SCOUT_FOR,$$base)" > /dev/null 2>&1; then \
					echo "❌❌ $(MSG_PREFIX)$$base .sout differs from .scout"; \
					$(INTEGRATE_DOT_FAIL); \
					diff -Bw "$$base.sout" "$(call SCOUT_FOR,$$base)" || true; \
					ko=$$((ko + 1)); failed=1; \
				else \
					echo "✅✅ $(MSG_PREFIX)$$base output matches .scout"; \
					$(INTEGRATE_DOT_OK); \
					ok=$$((ok + 1)); \
				fi; \
			else \
				echo "❌❌ $(MSG_PREFIX)$$base has no .scout file"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; \
			fi; \
		fi; \
	done; \
	[ "$$failed" -ne 0 ] && [ "$$ko" -eq 0 ] && ko=$$((ko + 1)); \
	printf '%d %d\n' "$$ok" "$$ko" > .integrate_counts; \
	exit $$failed

clean:
	@cd "$(THIS_DIR)" && \
	rm -f *.sout lib/*.sams lib/*.o *.iface *.sams __silica_runtime.o && \
	for line in $$(grep -v '^#' silica.config 2>/dev/null | grep -v '^$$' | grep -v '^\.trial_stdlib/' | grep -v '^lib/'); do \
		base=$${line%.silica}; \
		rm -f "$$base" "$$base.o"; \
	done && \
	rm -f silica.config .integrate_counts silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link && \
	echo "✅ $(MSG_PREFIX)Clean complete"

help:
	@echo "modules_addition: multi-file module trials; lib/*.silica are libraries (no main)."
	@echo "Targets: all (default, compile only), integrate (assembly/output checks + run), clean"

# Under -j, `clean` and `silica.config` must not run side by side (clean deletes the config).
silica.config: | clean
