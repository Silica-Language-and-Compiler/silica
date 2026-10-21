# Makefile for the Silica registry trial in cast_dangerous_registered_unheld_name_addition (its own directory: a suite compiles as one application, so a new trial renumbers its neighbours' atoms and every .ascomp golden beside it)
# Uses silica-compiler to generate assembly, then assembles and links.
#
# silica-compiler reads silica.config in this directory and emits .sams files.
# Assembler: clang -c; linker: rust-lld if available, else clang.
#
# Run from this directory: cd actors_addition && make
# Or from anywhere: make -C /path/to/actors_addition

THIS_DIR        := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../silica_compiler.mk
TRIAL_DIR := $(notdir $(patsubst %/,%,$(THIS_DIR)))
MSG_PREFIX := $(TRIAL_DIR)/

# Rust toolchain linker (rust-lld) - optional override
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

.DEFAULT_GOAL := all
.PHONY: all clean assembly objects executables integrate help silica.config

silica.config:
	@cd "$(THIS_DIR)" && \
	{ \
		for f in *.silica; do \
			[ -f "$$f" ] && printf '%s\n' "$$f"; \
		done; \
	} | LC_ALL=C sort > silica.config && $(TRIAL_SUPPORT_CONFIG)

all: executables

# Stage 1: silica-compiler generates .sams (reads silica.config in THIS_DIR)
assembly: clean silica.config
	@echo "Compiling with silica-compiler..."
	@cd "$(THIS_DIR)" && rm -f *.sams *.iface silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link __silica_runtime.sams; \
	$(RUN_SILICA_COMPILER)
	@echo "✅ $(MSG_PREFIX)Assembly generated"

# Stage 2: Assemble .sams -> .o
objects: assembly
	@cd "$(THIS_DIR)" && for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		echo "Assembling: $$sams -> $$base.o"; \
		$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler $$sams -o $$base.o; \
	done

# Stage 3: Link .o -> executable
executables: objects
	@cd "$(THIS_DIR)" && \
	while read -r ln; do \
		[ -n "$$ln" ] || continue; \
		case "$$ln" in .trial_stdlib/*) continue ;; esac; \
		bn=$$(basename "$$ln"); \
		stem=$${bn%.silica}; \
		main_o="$$stem.o"; \
		[ -f "$$main_o" ] || continue; \
		[ "$$stem" = "__silica_runtime" ] && continue; \
		[ -n "$$tsa_done" ] || { $(TRIAL_SUPPORT_ASSEMBLE); tsa_done=1; }; \
		rt_one=""; \
		[ -f "__silica_runtime.o" ] && rt_one="__silica_runtime.o"; \
		rt_one="$$rt_one $(call TRIAL_SUPPORT_OBJ,$$stem.silica)"; \
		echo "Linking $$stem..."; \
		if test -x "$(RUST_LLD)"; then \
			$(RUST_LLD) -flavor darwin -o $$stem $$main_o $$rt_one $(LDFLAGS_rust-lld) && echo "  ✅ $(MSG_PREFIX)$$stem (rust-lld)"; \
		else \
			$(ASSEMBLER) $$main_o $$rt_one -o $$stem $(LDFLAGS_clang) && echo "  ✅ $(MSG_PREFIX)$$stem (clang)"; \
		fi; \
	done < silica.config

# integrate: compile, diff .sams vs .ascomp, run, diff .sout vs .scout
integrate-run:
	@$(MAKE) -f "$(THIS_DIR)Makefile" clean
	@$(MAKE) -f "$(THIS_DIR)Makefile" silica.config
	@cd "$(THIS_DIR)" || exit 1; \
	rm -f .integrate_counts; ok=0; ko=0; failed=0; \
	if [ ! -s silica.config ]; then \
		echo "❌❌ $(MSG_PREFIX)silica.config missing after generation"; \
		$(INTEGRATE_DOT_FAIL); \
		printf '%d %d\n' 0 1 > .integrate_counts; \
		exit 1; \
	fi; \
	rm -f *.sams *.iface silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link __silica_runtime.sams; \
	echo "Compiling with silica-compiler..."; \
	if ! { $(RUN_SILICA_COMPILER); }; then \
		echo "❌❌ $(MSG_PREFIX)compilation failed"; \
		$(INTEGRATE_DOT_FAIL); \
		printf '%d %d\n' 0 1 > .integrate_counts; \
		exit 1; \
	fi; \
	for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		[ "$$base" = "__silica_runtime" ] && continue; \
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
	for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		echo "Assembling $$sams..."; \
		if ! $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler $$sams -o $$base.o; then \
		echo "❌❌ $(MSG_PREFIX)$$base assemble failed"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + 1)); failed=1; break; \
	fi; \
	done; \
	while read -r ln; do \
		[ -n "$$ln" ] || continue; \
		case "$$ln" in .trial_stdlib/*) continue ;; esac; \
		bn=$$(basename "$$ln"); \
		stem=$${bn%.silica}; \
		main_o="$$stem.o"; \
		[ -f "$$main_o" ] || continue; \
		[ "$$stem" = "__silica_runtime" ] && continue; \
		[ -n "$$tsa_done" ] || { $(TRIAL_SUPPORT_ASSEMBLE); tsa_done=1; }; \
		rt_one=""; \
		[ -f "__silica_runtime.o" ] && rt_one="__silica_runtime.o"; \
		rt_one="$$rt_one $(call TRIAL_SUPPORT_OBJ,$$stem.silica)"; \
		echo "Linking $$stem..."; \
		if test -x "$(RUST_LLD)"; then \
						if ! $(RUST_LLD) -flavor darwin -o $$stem $$main_o $$rt_one $(LDFLAGS_rust-lld); then \
				echo "❌❌ $(MSG_PREFIX)$$stem link failed"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; \
			fi; \
		else \
						if ! $(ASSEMBLER) $$main_o $$rt_one -o $$stem $(LDFLAGS_clang); then \
				echo "❌❌ $(MSG_PREFIX)$$stem link failed"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; \
			fi; \
		fi; \
	done < silica.config; \
	while read -r ln; do \
		[ -n "$$ln" ] || continue; \
		case "$$ln" in .trial_stdlib/*) continue ;; esac; \
		bn=$$(basename "$$ln"); \
		stem=$${bn%.silica}; \
		[ "$$stem" = "__silica_runtime" ] && continue; \
		if [ ! -x "$$stem" ]; then \
			echo "❌❌ $(MSG_PREFIX)$$stem missing executable (assemble/link failed earlier)"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; continue; \
		fi; \
		if [ -f "$(call SCOUT_FOR,$$stem)" ]; then \
			{ { grep -q '^use trial_support_' "$$stem.silica" || [ -f "$$stem.no_stdin_exit" ] || printf 'exit\n'; } | ./$$stem 2>&1; echo $$?; } > "$$stem.sout"; \
			if ! diff -Bw -q "$$stem.sout" "$(call SCOUT_FOR,$$stem)" > /dev/null 2>&1; then \
				echo "❌❌ $(MSG_PREFIX)$$stem .sout differs from .scout"; \
				$(INTEGRATE_DOT_FAIL); \
				diff -Bw "$$stem.sout" "$(call SCOUT_FOR,$$stem)" || true; \
				ko=$$((ko + 1)); failed=1; \
			else \
				echo "✅✅ $(MSG_PREFIX)$$stem output matches .scout"; \
				$(INTEGRATE_DOT_OK); \
				ok=$$((ok + 1)); \
			fi; \
		else \
			echo "❌❌ $(MSG_PREFIX)$$stem has no .scout file"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1; \
		fi; \
	done < silica.config; \
	[ "$$failed" -ne 0 ] && [ "$$ko" -eq 0 ] && ko=$$((ko + 1)); \
	printf '%d %d\n' "$$ok" "$$ko" > .integrate_counts; \
	exit $$failed

clean:
	@cd "$(THIS_DIR)" && \
	for s in *.sams; do \
		[ -f "$$s" ] || continue; \
		rm -f $${s%.sams}; \
	done; \
	rm -f *.sams *.o *.iface *.sout silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link .integrate_counts silica.config; \
	echo "✅ $(MSG_PREFIX)Clean complete"

help:
	@echo "Makefile - Silica actor trials (actors_addition)"
	@echo "================================================="
	@echo "Uses: silica-compiler -> .sams -> .o -> executable"
	@echo ""
	@echo "Targets:"
	@echo "  all         - Build executables (default)"
	@echo "  assembly    - Run silica-compiler (generates .sams)"
	@echo "  objects     - Assemble .sams to .o"
	@echo "  executables - Full build: assembly + link"
	@echo "  integrate   - Compile; diff .sams vs .ascomp, run, diff .sout vs .scout"
	@echo "  clean       - Remove .sams, .o, executables, .sout"
	@echo "  help        - Show this help"
	@echo ""
	@echo "Linker: $(LINKER)"

# Under -j, `clean` and `silica.config` must not run side by side (clean deletes the config).
silica.config: | clean
