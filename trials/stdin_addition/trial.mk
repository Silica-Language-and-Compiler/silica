# trial.mk (included by <trial>/Makefile, THIS_DIR set there): Makefile for the standard-input trials (stdin_carrier_design.md section 8.1): programs that read
# standard input through a `carried_on input: (:serial) (:stdin);` link, plus one regression program
# without the link. Same pipeline as the transport trials (silica-compiler -> .sams -> .o -> executable),
# copied from trials/transport_addition/Makefile, with two local differences:
#   * Input: a program <base> is run as `./<base> < <base>.stdin`, or `< /dev/null` when there is no
#     <base>.stdin. Output (stdout and stderr merged) and the exit status go to <base>.macos_applesilicon.sout
#     exactly as INTEGRATE_RUN_TRIAL does, and are compared with <base>.scout.
#   * Assembly goldens: a trial with no <base>.ascomp is NOT a failure here; the assembly comparison is
#     skipped with a note (the goldens are generated later). With an .ascomp the comparison runs as usual.
# The built-in modules the trials use (STDLIB_MODS) are linked into .trial_stdlib/ as the transport suite does.
# The published compiler predates the feature, so run with SILICA_COMPILER=<path to silica-gen1>.
#
# silica-compiler reads silica.config and outputs .sams (assembly) files.
# Assembler: clang -c (Rust toolchain does not ship a standalone assembler)
# Linker: rust-lld if available, else clang

include $(THIS_DIR)../../silica_compiler.mk

# Rust toolchain linker (rust-lld) - optional override
RUST_SYSROOT := $(shell rustc --print sysroot 2>/dev/null)
RUST_TARGET := $(shell rustc -vV 2>/dev/null | sed -n "s/^host: *//p")
RUST_LLD := $(RUST_SYSROOT)/lib/rustlib/$(RUST_TARGET)/bin/rust-lld

# Use rust-lld if it exists, otherwise clang for linking
LINKER := $(shell test -x "$(RUST_LLD)" && echo "$(RUST_LLD)" || echo "clang")
ASSEMBLER := clang

# macOS: linker flags for minimal executable (when using rust-lld)
MACOS_SDK := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
MACOS_MIN_VERSION := 26.0
ASFLAGS_macos := -mmacosx-version-min=$(MACOS_MIN_VERSION)
LDFLAGS_rust-lld := -arch arm64 -platform_version macos $(MACOS_MIN_VERSION) $(MACOS_MIN_VERSION) -syslibroot $(MACOS_SDK) -lSystem -e main
LDFLAGS_clang := -Wl,-e,main -Wl,-macos_version_min,$(MACOS_MIN_VERSION)

TRIAL_DIR := $(notdir $(patsubst %/,%,$(THIS_DIR)))
MSG_PREFIX := $(TRIAL_DIR)/

# The language's built-in modules (compiler/stdlib) the flat trials here link.
STDLIB_MODS ?= wireframe dangerous_console dangerous_console_stdin_carrier

# The dangerous carrier is a Fifi actor over the C wrapper compiler/stdlib/net/silica_console.c (bound by
# dangerous_console.silica). Local to this suite (the shared ffi_addition fixtures do not know it): the
# wrapper is built once into trials/stdin_addition/.console_build/<platform>/lib/libsilica_console.a, and a
# trial with a dangerous_*.silica program gets dangerous_exposure_source/{lib,sockets} links, the layout
# the sockets trials use (silica.link then names dangerous_exposure_source/lib/libsilica_console.a).
CONSOLE_C := $(abspath $(THIS_DIR)../../../compiler/stdlib/net/silica_console.c)
CONSOLE_NET_DIR := $(abspath $(THIS_DIR)../../../compiler/stdlib/net)
CONSOLE_BUILD := $(abspath $(THIS_DIR)../.console_build/$(SOUT_TARGET))
SILICA_LINK_SH := $(abspath $(THIS_DIR)../../silica_link.sh)
ifeq ($(shell uname -s),Darwin)
  CONSOLE_CFLAGS := -std=c11 -Wall -Wextra -O2 -arch arm64 -mmacosx-version-min=$(MACOS_MIN_VERSION)
else
  CONSOLE_CFLAGS := -std=c11 -Wall -Wextra -O2 -D_GNU_SOURCE
endif
define CONSOLE_PREP
mkdir -p "$(CONSOLE_BUILD)/lib" "$(CONSOLE_BUILD)/obj" && \
clang $(CONSOLE_CFLAGS) -c "$(CONSOLE_C)" -o "$(CONSOLE_BUILD)/obj/silica_console.o" && \
ar rcs "$(CONSOLE_BUILD)/lib/libsilica_console.a" "$(CONSOLE_BUILD)/obj/silica_console.o" && \
mkdir -p dangerous_exposure_source && \
ln -sfn "$(CONSOLE_BUILD)/lib" dangerous_exposure_source/lib && \
ln -sfn "$(CONSOLE_NET_DIR)" dangerous_exposure_source/sockets && \
ln -sfn ../dangerous_exposure_source .trial_stdlib/dangerous_exposure_source
endef
# The output (stdout and stderr merged) is compared in order, except for the runtime's own stderr line
# about the ending carrier: its place relative to the owner's closing lines is not guaranteed (the carrier
# and the owner run on different threads, and the reporter notification races the runtime's print on
# Linux). That line must appear exactly as often as in the .scout and not as the first line (the owner's
# `link up:` comes first); every other line must match in order. $(1) is the .sout, $(2) the .scout; the
# filtered copies are left beside them as <file>.cmp.
define STDIN_COMPARE
{ rl='[silica] root actor exited (no supervisor)'; \
grep -vxF "$$rl" "$(1)" > "$(1).cmp"; grep -vxF "$$rl" "$(2)" > "$(2).cmp"; \
[ "$$(grep -cxF "$$rl" "$(1)")" = "$$(grep -cxF "$$rl" "$(2)")" ] && \
[ "$$(grep -nxF "$$rl" "$(1)" | head -n 1 | cut -d: -f1)" != 1 ] && \
diff -Bw -q "$(1).cmp" "$(2).cmp" > /dev/null 2>&1; }
endef
# No sub-trials in this suite (kept so the shared loops below stay as in the transport Makefile).
SUB_TRIALS :=


.DEFAULT_GOAL := all
.PHONY: all clean assembly objects executables integrate help silica.config

all: executables

# Stage 1: Rebuild silica.config (all *.silica under this directory, relative paths)
silica.config:
	@cd "$(THIS_DIR)" && find "$$PWD" -maxdepth 1 -type f -name '*.silica' | LC_ALL=C sort | sed "s|^$$PWD/||" > silica.config && mkdir -p .trial_stdlib && for m in $(STDLIB_MODS); do ln -sfn ../../../../compiler/stdlib/$$m.silica .trial_stdlib/$$m.silica && echo .trial_stdlib/$$m.silica >> silica.config; done && if ls dangerous_*.silica > /dev/null 2>&1 || [ "$(TRIAL_COMPILE_FAIL)" = 1 ]; then $(CONSOLE_PREP); fi

# Stage 2: silica-compiler generates .sams (reads silica.config)
assembly: clean silica.config
	@echo "Compiling with silica-compiler..."
	@rm -f *.sams silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link __silica_runtime.sams; \
	$(RUN_SILICA_COMPILER)
	@echo "✅ $(MSG_PREFIX)Assembly generated"

# Stage 3: Assemble .sams -> .o (no Rust code, clang assembler only)
objects: assembly
	@for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
	base=$${sams%.sams}; \
	echo "Assembling: $$sams -> $$base.o"; \
	$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler $$sams -o $$base.o; \
	done

# Stage 4: Link .o -> executable (rust-lld or clang)
executables: objects
	@: ; \
	for m in $(STDLIB_MODS); do [ -f .trial_stdlib/$$m.sams ] && { $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler .trial_stdlib/$$m.sams -o .trial_stdlib/$$m.o || echo "❌❌ assembling $$m failed"; }; done; \
	link_archives=$$("$(SILICA_LINK_SH)" .); \
	for o in *.o; do \
	[ -f "$$o" ] || continue; \
	base=$${o%.o}; \
[ "$$base" = "__silica_runtime" ] && continue; \
runtime_obj=""; \
[ -f "__silica_runtime.o" ] && runtime_obj="__silica_runtime.o"; \
for m in $(STDLIB_MODS); do [ -f ".trial_stdlib/$$m.o" ] && runtime_obj="$$runtime_obj .trial_stdlib/$$m.o"; done; \
	if test -x "$(RUST_LLD)"; then \
		$(RUST_LLD) -flavor darwin -o $$base $$o $$runtime_obj $$link_archives $(LDFLAGS_rust-lld) && echo "  ✅ $(MSG_PREFIX)$$base (rust-lld)"; \
	else \
		$(ASSEMBLER) $$o $$runtime_obj $$link_archives -o $$base $(LDFLAGS_clang) && echo "  ✅ $(MSG_PREFIX)$$base (clang)"; \
	fi; \
	done

ifeq ($(TRIAL_COMPILE_FAIL),1)
# A compile-fail trial (TRIAL_COMPILE_FAIL=1 set by its Makefile): the program must be rejected. The part of the
# compiler's output from the "Compilation error" line on is compared with <base>.golden_fail (the progress
# lines before it, which list the stdlib modules, are not part of the golden).
integrate-run:
	@$(MAKE) -f "$(THIS_DIR)Makefile" clean
	@$(MAKE) -f "$(THIS_DIR)Makefile" silica.config
	@cd "$(THIS_DIR)" && rm -f .integrate_counts && \
	{ $(call RUN_SILICA_COMPILER_QUIET_WITH,$(abspath $(SILICA_COMPILER))); } > compile.out 2>&1; \
	base=$$(ls *.silica | head -n 1); base=$${base%.silica}; \
	sed -n '/Compilation error/,$$p' compile.out > "$$base.cur_fail"; \
	if diff -q "$$base.cur_fail" "$$base.golden_fail" > /dev/null 2>&1; then \
		echo "✅✅ $(MSG_PREFIX)$$base"; $(INTEGRATE_DOT_OK); printf '1 0\n' > .integrate_counts; \
	else \
		echo "❌❌ $(MSG_PREFIX)$$base: compiler error differs from .golden_fail"; $(INTEGRATE_DOT_FAIL); \
		diff "$$base.cur_fail" "$$base.golden_fail" || true; printf '0 1\n' > .integrate_counts; exit 1; \
	fi
else
# integrate: compile .silica per silica.config, diff .sams vs .ascomp, run binaries, diff .sout vs .scout
integrate-run:
	@$(MAKE) -f "$(THIS_DIR)Makefile" clean
	@$(MAKE) -f "$(THIS_DIR)Makefile" silica.config
	@rm -f .integrate_counts; ok=0; ko=0; failed=0; \
	if [ ! -s silica.config ]; then \
		echo "❌❌ $(MSG_PREFIX)silica.config missing after generation"; \
		$(INTEGRATE_DOT_FAIL); \
		printf '%d %d\n' 0 1 > .integrate_counts; \
		exit 1; \
	fi; \
	rm -f *.sams *.iface silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link __silica_runtime.sams; \
	echo "Compiling with silica-compiler..."; \
	if ! { $(call RUN_SILICA_COMPILER_ISOLATING_WITH,$(abspath $(SILICA_COMPILER))); }; then \
		echo "❌❌ $(MSG_PREFIX)compilation failed"; \
		$(INTEGRATE_DOT_FAIL); \
		printf '%d %d\n' 0 1 > .integrate_counts; \
		exit 1; \
	fi; \
	$(call INTEGRATE_COMPILE_REJECTS,$(MSG_PREFIX)); \
	for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
	[ "$$base" = "__silica_runtime" ] && continue; \
	[ "$$base" = "__silica_runtime" ] && continue; \
		if [ -n "$(TRIAL_SKIP_GOLDEN)" ]; then \
			: golden assembly check skipped; \
		elif [ ! -f "$$base$(ASCOMP_EXT)" ]; then \
			echo "$(MSG_PREFIX)$$base has no .ascomp file yet: assembly comparison skipped"; \
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
		bf="$$bf $$base "; ko=$$((ko + 1)); failed=1; \
	fi; \
	done; \
	for m in $(STDLIB_MODS); do [ -f .trial_stdlib/$$m.sams ] && { $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler .trial_stdlib/$$m.sams -o .trial_stdlib/$$m.o || echo "❌❌ assembling $$m failed"; }; done; \
	link_archives=$$("$(SILICA_LINK_SH)" .); \
	for o in *.o; do \
		[ -f "$$o" ] || continue; \
		base=$${o%.o}; \
	[ "$$base" = "__silica_runtime" ] && continue; \
	runtime_obj=""; \
	[ -f "__silica_runtime.o" ] && runtime_obj="__silica_runtime.o"; \
	for m in $(STDLIB_MODS); do [ -f ".trial_stdlib/$$m.o" ] && runtime_obj="$$runtime_obj .trial_stdlib/$$m.o"; done; \
		echo "Linking $$base..."; \
		if test -x "$(RUST_LLD)"; then \
			if ! $(RUST_LLD) -flavor darwin -o $$base $$o $$runtime_obj $$link_archives $(LDFLAGS_rust-lld); then \
			echo "❌❌ $(MSG_PREFIX)$$base link failed"; \
			$(INTEGRATE_DOT_FAIL); \
			bf="$$bf $$base "; ko=$$((ko + 1)); failed=1; \
		fi; \
		else \
			if ! $(ASSEMBLER) $$o $$runtime_obj $$link_archives -o $$base $(LDFLAGS_clang); then \
			echo "❌❌ $(MSG_PREFIX)$$base link failed"; \
			$(INTEGRATE_DOT_FAIL); \
			bf="$$bf $$base "; ko=$$((ko + 1)); failed=1; \
		fi; \
		fi; \
	done; \
	for exe in *.sams; do \
		[ -f "$$exe" ] || continue; \
		base=$${exe%.sams}; \
	[ "$$base" = "__silica_runtime" ] && continue; \
	[ "$$base" = "__silica_runtime" ] && continue; \
		if [ ! -x "$$base" ]; then \
			case "$$bf" in *" $$base "*) echo "$(MSG_PREFIX)$$base not run: assemble/link failed (reported above)";; *) \
			echo "❌❌ $(MSG_PREFIX)$$base missing executable (assemble/link failed earlier)"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1;; esac; \
		elif [ -x "$$base" ]; then \
			si=/dev/null; [ -f "$$base.stdin" ] && si="$$base.stdin"; \
			$(call INTEGRATE_RUN_TRIAL,$(MSG_PREFIX)$$base,$$base$(SOUT_EXT),./$$base < "$$si"); \
			if [ "$$integrate_killed" = 1 ]; then \
				echo "❌❌ $(MSG_PREFIX)$$base $(INTEGRATE_KILLED_MSG)"; \
				$(INTEGRATE_DOT_FAIL); \
				ko=$$((ko + 1)); failed=1; continue; \
			fi; \
			if [ -f "$(call SCOUT_FOR,$$base)" ]; then \
				if ! $(call STDIN_COMPARE,$$base$(SOUT_EXT),$(call SCOUT_FOR,$$base)); then \
					echo "❌❌ $(MSG_PREFIX)$$base .sout differs from .scout"; \
					$(INTEGRATE_DOT_FAIL); \
					diff -Bw "$$base$(SOUT_EXT).cmp" "$(call SCOUT_FOR,$$base).cmp" || true; \
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
	for sub in $(SUB_TRIALS); do \
		[ -f "$(THIS_DIR)$$sub/Makefile" ] || continue; \
		if $(MAKE) -C "$(THIS_DIR)$$sub" integrate; then :; else failed=1; fi; \
		sf="$(THIS_DIR)$$sub/.integrate_counts"; \
		if [ -f "$$sf" ]; then \
			read sub_ok sub_ko < "$$sf" || true; \
			ok=$$((ok + $${sub_ok:-0})); \
			ko=$$((ko + $${sub_ko:-0})); \
		fi; \
	done; \
	printf '%d %d\n' "$$ok" "$$ko" > .integrate_counts; \
	exit $$failed
endif

clean:
	@for s in *.sams; do \
		[ -f "$$s" ] || continue; \
		$(call TRIAL_RM_UNTRACKED,"$${s%.sams}"); \
	done
	rm -f dangerous_exposure_source/lib dangerous_exposure_source/sockets; rmdir dangerous_exposure_source 2>/dev/null; true
	rm -f compile.out *.cmp *.cur_fail *.sams *.o *.iface silica.config silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link .integrate_counts
	rm -rf .trial_stdlib
	@for sub in $(SUB_TRIALS); do [ -f "$(THIS_DIR)$$sub/Makefile" ] && $(MAKE) --no-print-directory -C "$(THIS_DIR)$$sub" clean; done; true
	@echo "✅ $(MSG_PREFIX)Clean complete"

help:
	@echo "Makefile - Silica assembly build (no Rust code)"
	@echo "=============================================="
	@echo "Uses: silica-compiler -> .sams -> .o -> executable"
	@echo ""
	@echo "Targets:"
	@echo "  all         - Build executables (default)"
	@echo "  assembly    - Run silica-compiler (generates .sams)"
	@echo "  objects     - Assemble .sams to .o"
	@echo "  executables - Full build: assembly + link"
	@echo "  integrate   - Compile, diff .sams vs .ascomp, run, diff .sout vs .scout"
	@echo "  clean       - Remove .sams, .o, executables"
	@echo "  help        - Show this help"
	@echo ""
	@echo "Config: silica.config — top-level *.silica in this folder (each SUB_TRIALS directory has its own)"
	@echo "Linker: $(LINKER)"

# Under -j, `clean` and `silica.config` must not run side by side (clean deletes the config).
silica.config: | clean
