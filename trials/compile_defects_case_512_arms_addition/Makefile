# Makefile for a Silica open-compile-defect trial in compile_defects_case_512_arms_addition (a valid program the compiler rejects; one such trial per directory because one rejection fails the whole directory's compile step); INTEGRATE_PENDING keeps it out of tree-wide runs until the defect is fixed (see README.md)
# Uses silica-compiler to generate assembly, then assembles and links.
#
# silica-compiler reads silica.config in this directory and emits .sams files.
# Assembler: clang -c; linker: rust-lld if available, else clang.
#
# Run from this directory: cd compile_defects_case_512_arms_addition && make
# Or from anywhere: make -C /path/to/compile_defects_case_512_arms_addition

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

# The config takes symlinked units too (a trial may link a stdlib module into this directory).
silica.config:
	@cd "$(THIS_DIR)" && find "$$PWD" -path "$$PWD/.trial_stdlib" -prune -o \( -type f -o -type l \) -name '*.silica' -print | sed "s|^$$PWD/||" | LC_ALL=C sort > silica.config && $(TRIAL_SUPPORT_CONFIG)

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
	@cd "$(THIS_DIR)" && helper_objs=""; for h in *.sams; do \
		[ -f "$$h" ] || continue; hb=$${h%.sams}; \
		[ "$$hb" = "__silica_runtime" ] && continue; \
		grep -qE '^\.global main$$' "$$h" || helper_objs="$$helper_objs $$hb.o"; \
	done; \
	$(TRIAL_SUPPORT_ASSEMBLE); \
	for o in *.o; do \
		[ -f "$$o" ] || continue; \
		base=$${o%.o}; \
	[ "$$base" = "__silica_runtime" ] && continue; \
	grep -qE '^\.global main$$' "$$base.sams" || continue; \
	runtime_obj=""; \
	[ -f "__silica_runtime.o" ] && runtime_obj="__silica_runtime.o"; \
	runtime_obj="$$runtime_obj $(call TRIAL_SUPPORT_OBJ,$$base.silica)"; \
		if test -x "$(RUST_LLD)"; then \
			$(RUST_LLD) -flavor darwin -o $$base $$o $$helper_objs $$runtime_obj $(LDFLAGS_rust-lld) && echo "  ✅ $(MSG_PREFIX)$$base (rust-lld)"; \
		else \
			$(ASSEMBLER) $$o $$helper_objs $$runtime_obj -o $$base $(LDFLAGS_clang) && echo "  ✅ $(MSG_PREFIX)$$base (clang)"; \
		fi; \
	done

# integrate: compile, diff .sams vs .ascomp, run, diff .sout vs .scout.
# Trials with <base>.wait_for_exit print one or more "done" markers and then call wait_for_exit/0; they are
# run through run_integration_exit_after_marker.py, which sends "exit\n" after seeing the marker count.
# Unmarked trials use the ordinary direct executable runner.
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
	if ! { $(RUN_SILICA_COMPILER_ISOLATING); }; then \
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
		bf="$$bf $$base "; ko=$$((ko + 1)); failed=1; \
	fi; \
	done; \
	helper_objs=""; for h in *.sams; do \
		[ -f "$$h" ] || continue; hb=$${h%.sams}; \
		[ "$$hb" = "__silica_runtime" ] && continue; \
		grep -qE '^\.global main$$' "$$h" || helper_objs="$$helper_objs $$hb.o"; \
	done; \
	$(TRIAL_SUPPORT_ASSEMBLE); \
	for o in *.o; do \
		[ -f "$$o" ] || continue; \
		base=$${o%.o}; \
	[ "$$base" = "__silica_runtime" ] && continue; \
	grep -qE '^\.global main$$' "$$base.sams" || continue; \
	runtime_obj=""; \
	[ -f "__silica_runtime.o" ] && runtime_obj="__silica_runtime.o"; \
	runtime_obj="$$runtime_obj $(call TRIAL_SUPPORT_OBJ,$$base.silica)"; \
		echo "Linking $$base..."; \
		runtime_obj=""; \
		[ -f "__silica_runtime.o" ] && runtime_obj="__silica_runtime.o"; \
		runtime_obj="$$runtime_obj $(call TRIAL_SUPPORT_OBJ,$$base.silica)"; \
		if test -x "$(RUST_LLD)"; then \
			if ! $(RUST_LLD) -flavor darwin -o $$base $$o $$helper_objs $$runtime_obj $(LDFLAGS_rust-lld); then \
			echo "❌❌ $(MSG_PREFIX)$$base link failed"; \
			$(INTEGRATE_DOT_FAIL); \
			bf="$$bf $$base "; ko=$$((ko + 1)); failed=1; \
		fi; \
		else \
			if ! $(ASSEMBLER) $$o $$helper_objs $$runtime_obj -o $$base $(LDFLAGS_clang); then \
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
	grep -qE '^\.global main$$' "$$exe" || continue; \
		if [ ! -x "$$base" ]; then \
			case "$$bf" in *" $$base "*) echo "$(MSG_PREFIX)$$base not run: assemble/link failed (reported above)";; *) \
			echo "❌❌ $(MSG_PREFIX)$$base missing executable (assemble/link failed earlier)"; \
			$(INTEGRATE_DOT_FAIL); \
			ko=$$((ko + 1)); failed=1;; esac; \
		elif [ -x "$$base" ]; then \
			if [ -f "$(call SCOUT_FOR,$$base)" ]; then \
				if [ -f "$$base.wait_for_exit" ]; then \
					if [ -f "$(THIS_DIR)run_integration_exit_after_marker.py" ]; then \
						marker=$$(awk 'NF { print $$1; found=1; exit } END { if (!found) print "done" }' "$$base.wait_for_exit"); \
						marker_count=$$(awk 'NF { print ($$2 == "" ? 1 : $$2); found=1; exit } END { if (!found) print 1 }' "$$base.wait_for_exit"); \
						$(call INTEGRATE_EXEC_TRIAL,$(MSG_PREFIX)$$base,python3 "$(THIS_DIR)run_integration_exit_after_marker.py" "$(THIS_DIR)" "$$base" "$$base.sout" "$$marker" "$$marker_count"); \
						if [ "$$integrate_killed" = 1 ]; then \
							echo "❌❌ $(MSG_PREFIX)$$base $(INTEGRATE_KILLED_MSG)"; \
							$(INTEGRATE_DOT_FAIL); \
							ko=$$((ko + 1)); failed=1; continue; \
						fi; \
					else \
						echo "❌❌ $(MSG_PREFIX)$$base missing run_integration_exit_after_marker.py"; \
						$(INTEGRATE_DOT_FAIL); \
						ko=$$((ko + 1)); failed=1; \
						continue; \
					fi; \
				else \
					$(call INTEGRATE_RUN_TRIAL,$(MSG_PREFIX)$$base,$$base.sout,./$$base); \
					if [ "$$integrate_killed" = 1 ]; then \
						echo "❌❌ $(MSG_PREFIX)$$base $(INTEGRATE_KILLED_MSG)"; \
						$(INTEGRATE_DOT_FAIL); \
						ko=$$((ko + 1)); failed=1; continue; \
					fi; \
				fi; \
				if [ -f "$$base.scout.multiset" ]; then \
					if [ -f "$(THIS_DIR)compare_scout_multiset.sh" ] && ! "$(SHELL)" "$(THIS_DIR)compare_scout_multiset.sh" "$$base.sout" "$(call SCOUT_FOR,$$base)"; then \
						echo "❌❌ $(MSG_PREFIX)$$base .sout multiset-compare differs from .scout"; \
						$(INTEGRATE_DOT_FAIL); \
						ko=$$((ko + 1)); failed=1; \
					elif [ ! -f "$(THIS_DIR)compare_scout_multiset.sh" ] && ! diff -Bw -q "$$base.sout" "$(call SCOUT_FOR,$$base)" > /dev/null 2>&1; then \
						echo "❌❌ $(MSG_PREFIX)$$base .sout differs from .scout (missing compare_scout_multiset.sh; used diff -Bw)"; \
						$(INTEGRATE_DOT_FAIL); \
						diff -Bw "$$base.sout" "$(call SCOUT_FOR,$$base)" || true; \
						ko=$$((ko + 1)); failed=1; \
					else \
						echo "✅✅ $(MSG_PREFIX)$$base output multiset-matches .scout"; \
						$(INTEGRATE_DOT_OK); \
						ok=$$((ok + 1)); \
					fi; \
				elif ! diff -Bw -q "$$base.sout" "$(call SCOUT_FOR,$$base)" > /dev/null 2>&1; then \
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
	for s in *.sams; do \
		[ -f "$$s" ] || continue; \
		$(call TRIAL_RM_UNTRACKED,"$${s%.sams}"); \
	done; \
	rm -f *.sams *.o *.iface *.sout silica.config silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link .integrate_counts; \
	echo "✅ $(MSG_PREFIX)Clean complete"

help:
	@echo "Makefile - Silica trials (compile_defects_case_512_arms_addition)"
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
