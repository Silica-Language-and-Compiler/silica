# Trait trials: trait sources under traits/ have no main(). Only entry-point units are linked and run.
# Each traits/*.silica may carry an empty sidecar traits/<Stem>.no_golden_fail so any golden-based harness skips it.
# silica.config lists traits/*.silica + root entry *.silica (refreshed via find before compile / integrate).
# Default `make` / `make all`: compile, assemble with $(ASSEMBLER), link with rust-lld or clang.
# `make compile`: silica-compiler only (emit .sams).
# `make integrate`: compile, assemble, .sams vs .ascomp diffs, link, run binaries, .sout vs .scout diffs.

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

.PHONY: all compile integrate clean help silica.config

silica.config:
	@cd "$(THIS_DIR)" && find "$$PWD" -type f -name '*.silica' | sed "s|^$$PWD/||" | LC_ALL=C sort > silica.config && $(TRIAL_SUPPORT_CONFIG)

.DEFAULT_GOAL := all

compile: clean silica.config
	@cd "$(THIS_DIR)" && \
	rm -f *.sams *.iface silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link __silica_runtime.sams traits/*.sams && \
	echo "Compiling with silica-compiler..." && \
	if ! { $(RUN_SILICA_COMPILER); }; then \
		echo "❌❌ $(MSG_PREFIX)compilation failed"; \
		$(INTEGRATE_DOT_FAIL); \
		exit 1; \
	fi && \
	echo "✅ $(MSG_PREFIX)Assembly generated (.sams)"

all: compile
	@failed=0; \
	cd "$(THIS_DIR)" && \
	for line in $$(grep -v '^#' silica.config 2>/dev/null | grep -v '^$$' | grep -v '^\.trial_stdlib/' | grep -v '^traits/'); do \
		base=$${line%.silica}; \
		sams="$$base.sams"; \
		if [ ! -f "$$sams" ]; then \
			echo "❌ $(MSG_PREFIX)$$base: missing $$sams"; \
			$(INTEGRATE_DOT_FAIL); \
			failed=1; \
			continue; \
		fi; \
		echo "Assembling $$sams..."; \
		if ! $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "$$base.o"; then \
		echo "❌❌ $(MSG_PREFIX)$$base assemble failed"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + 1)); failed=1; \
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
	for sams in traits/*.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$$(basename "$$sams" .sams); \
		obj="traits/$$base.o"; \
		echo "Assembling $$sams..."; \
		if ! $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "$$obj"; then \
		echo "❌❌ $(MSG_PREFIX)$$obj assemble failed"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + 1)); failed=1; \
	fi; \
	done; \
	for line in $$(grep -v '^#' silica.config 2>/dev/null | grep -v '^$$' | grep -v '^\.trial_stdlib/' | grep -v '^traits/'); do \
		base=$${line%.silica}; \
		[ -f "$$base.o" ] || continue; \
		echo "Linking $$base..."; \
		trait_objs=""; \
		for trait_obj in traits/*.o; do \
			[ -f "$$trait_obj" ] && trait_objs="$$trait_objs $$trait_obj"; \
		done; \
		[ -n "$$tsa_done" ] || { $(TRIAL_SUPPORT_ASSEMBLE); tsa_done=1; }; \
		runtime_obj=""; \
		[ -f "__silica_runtime.o" ] && runtime_obj="__silica_runtime.o"; \
		runtime_obj="$$runtime_obj $(call TRIAL_SUPPORT_OBJ,$$base.silica)"; \
		if test -x "$(RUST_LLD)"; then \
			if ! $(RUST_LLD) -flavor darwin -o "$$base" "$$base.o" $$trait_objs $$runtime_obj $(LDFLAGS_rust-lld); then \
			echo "❌❌ $(MSG_PREFIX)$$base link failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		fi; \
		else \
			if ! $(ASSEMBLER) "$$base.o" $$trait_objs $$runtime_obj -o "$$base" $(LDFLAGS_clang); then \
			echo "❌❌ $(MSG_PREFIX)$$base link failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		fi; \
		fi; \
	done; \
	if [ $$failed -ne 0 ]; then \
		echo "❌❌ $(MSG_PREFIX)assemble/link failed"; \
		$(INTEGRATE_DOT_FAIL); \
		exit 1; \
	fi; \
	echo "✅ $(MSG_PREFIX)Linked entrypoints (root *.silica from silica.config)"

integrate-run:
	@$(MAKE) -f "$(THIS_DIR)Makefile" clean
	@$(MAKE) -f "$(THIS_DIR)Makefile" silica.config
	@$(MAKE) -f "$(THIS_DIR)Makefile" compile
	@cd "$(THIS_DIR)" && \
	rm -f .integrate_counts; ok=0; ko=0; failed=0; \
	for line in $$(grep -v '^#' silica.config 2>/dev/null | grep -v '^$$' | grep -v '^\.trial_stdlib/' | grep -v '^traits/'); do \
		base=$${line%.silica}; \
		sams="$$base.sams"; \
		if [ ! -f "$$sams" ]; then \
			echo "❌❌ $(MSG_PREFIX)$$base: missing $$sams"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
			continue; \
		fi; \
		echo "Assembling $$sams..."; \
		if ! $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "$$base.o"; then \
		echo "❌❌ $(MSG_PREFIX)$$base assemble failed"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + 1)); failed=1; \
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
	for sams in traits/*.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$$(basename "$$sams" .sams); \
		obj="traits/$$base.o"; \
		echo "Assembling $$sams..."; \
		if ! $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "$$obj"; then \
		echo "❌❌ $(MSG_PREFIX)$$obj assemble failed"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + 1)); failed=1; \
	fi; \
	done; \
	for line in $$(grep -v '^#' silica.config 2>/dev/null | grep -v '^$$' | grep -v '^\.trial_stdlib/' | grep -v '^traits/'); do \
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
	for line in $$(grep -v '^#' silica.config 2>/dev/null | grep -v '^$$' | grep -v '^\.trial_stdlib/' | grep -v '^traits/'); do \
		base=$${line%.silica}; \
		[ -f "$$base.o" ] || continue; \
		echo "Linking $$base..."; \
		trait_objs=""; \
		for trait_obj in traits/*.o; do \
			[ -f "$$trait_obj" ] && trait_objs="$$trait_objs $$trait_obj"; \
		done; \
		[ -n "$$tsa_done" ] || { $(TRIAL_SUPPORT_ASSEMBLE); tsa_done=1; }; \
		runtime_obj=""; \
		[ -f "__silica_runtime.o" ] && runtime_obj="__silica_runtime.o"; \
		runtime_obj="$$runtime_obj $(call TRIAL_SUPPORT_OBJ,$$base.silica)"; \
		if test -x "$(RUST_LLD)"; then \
			if ! $(RUST_LLD) -flavor darwin -o "$$base" "$$base.o" $$trait_objs $$runtime_obj $(LDFLAGS_rust-lld); then \
			echo "❌❌ $(MSG_PREFIX)$$base link failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		fi; \
		else \
			if ! $(ASSEMBLER) "$$base.o" $$trait_objs $$runtime_obj -o "$$base" $(LDFLAGS_clang); then \
			echo "❌❌ $(MSG_PREFIX)$$base link failed"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		fi; \
		fi; \
	done; \
	for line in $$(grep -v '^#' silica.config 2>/dev/null | grep -v '^$$' | grep -v '^\.trial_stdlib/' | grep -v '^traits/'); do \
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
			if [ -f "$$base.scout" ]; then \
				if ! diff -Bw -q "$$base.sout" "$$base.scout" > /dev/null 2>&1; then \
					echo "❌❌ $(MSG_PREFIX)$$base .sout differs from .scout"; \
					$(INTEGRATE_DOT_FAIL); \
					diff -Bw "$$base.sout" "$$base.scout" || true; \
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
	rm -f *.sout traits/*.sams traits/*.o *.iface *.sams __silica_runtime.o && \
	for line in $$(grep -v '^#' silica.config 2>/dev/null | grep -v '^$$' | grep -v '^\.trial_stdlib/' | grep -v '^traits/'); do \
		base=$${line%.silica}; \
		rm -f "$$base" "$$base.o"; \
	done && \
	rm -f silica.config .integrate_counts silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link && \
	echo "✅ $(MSG_PREFIX)Clean complete"

help:
	@echo "traits_addition: multi-file trait trials; traits/*.silica are trait definitions (no main)."
	@echo "Entrypoints: non-traits paths in silica.config (refreshed with find before compile)."
	@echo "  Sizeable/Scalable: single required + single impl (int64). Doubling: int64 transform."
	@echo "  Shape: required + provided default; two impl fn area/1 (overload). combined_trait_main nests Sizeable + Doubling."
	@echo "  PointSum: pair_sum/2 on int64 (tuple_pair_main). Labeled/ReportEcho: int64 witness + trait-on-trait echo."
	@echo "Targets: all (default: compile+assemble+link), compile (.sams only), integrate (assemble, .ascomp diff, link, .scout), clean"

# Under -j, `clean` and `silica.config` must not run side by side (clean deletes the config).
silica.config: | clean
