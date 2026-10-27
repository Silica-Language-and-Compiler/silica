# Parallel self-host tree (`src/`)
# Config-driven like trials/: generate silica.config, run seed host (no argv),
# then .sams → .o → link. Does not use silica-boot for Silica→assembly.
#
# Emit target (TARGET) selects emitter/<TARGET>/ for silica.config and writes
# silica.target. Defaults to the current host platform when unset.
#
# Per-target build directories: every intermediate output of a build (silica.config, silica.target,
# .sams, .iface, .o, silica.link, the linked compiler before it is published) lives under
# compiler/build/<TARGET>/ (BUILD_DIR), never beside the sources. The sources reach that directory
# as symlinks (staged by the `stage` step, one per unit), so the seed, which reads silica.config from
# its working directory and writes each unit's .sams/.iface beside the unit, runs with BUILD_DIR as
# its working directory and leaves src/ untouched. Because each target has its own directory:
#   - building one target after another needs no `make clean` (the old "stale target .sams trap");
#   - each target keeps its own incremental state (a changed .silica recompiles only its unit);
#   - two targets can build at the same time on one machine.
# `make clean` removes the build directory of TARGET (the host's by default); `make clean-all`
# removes compiler/build/ and any pre-per-target leftovers in src/.
#
# Usage:
#   make help                   # descriptive help (project --help equivalent)
#   make                        # assembly + objects + link silica-compiler
#   make assembly               # seed compile only (.sams)
#   make TARGET=apple_silicon_mac   # explicit emit / emitter backend

THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)emit_target.mk

BINARIES_DIR := $(abspath $(THIS_DIR)../../binaries)
# ESP32-S3 cross compiler is built by the latest Mac build (binaries/silica-compiler) because the
# seed is too old for the board pack's sum return types; every other target is built by the seed.
ifeq ($(TARGET),ESP32-S3_raw)
SILICA_COMPILER ?= $(BINARIES_DIR)/silica-compiler
else
SILICA_COMPILER ?= $(BINARIES_DIR)/seed-compiler
endif
SILICA_LINK_SH := $(abspath $(THIS_DIR)../../trials/silica_link.sh)
STDLIB_DS := $(abspath $(THIS_DIR)../stdlib/data_structures)
# POLICY: src links NO Rust libraries. The bootstrap crate's staticlib
# (libsilica_compiler.a) used to be linked here and supplied the whole runtime.
# It is deliberately gone so a Rust dependency cannot creep back in silently:
# if the link fails with undefined _silica_* symbols, implement them in
# silica_rt_shim.s (assembled by clang, like main_entry_alias.s) -- do not
# re-add an archive. Assembler and linker are clang only.

EXECUTABLE := silica-compiler

# A successful build publishes itself to binaries/ (binaries/install_compiler.bash):
#   - TARGET is the host's emit target and EXECUTABLE is the default: the new selfhost,
#     binaries/silica-<NNNNNN>-<platform>, with binaries/silica-compiler pointing at it (what
#     compiles base and the trials);
#   - any other TARGET (e.g. ESP32-S3_raw): a compiler that runs on this host and emits for that
#     target, binaries/silica-<NNNNNN>-<TARGET with - as _>-<platform>, with
#     binaries/silica-compiler-<TARGET> pointing at it (what compiles the trials for a board).
#     Each emit target has its own numbering. It is never installed as binaries/silica-compiler.
# Host-target builds under another EXECUTABLE name (e.g. `make all-targets`) are not published.
# Set INSTALL_SELFHOST=0 to build without publishing.
INSTALL_COMPILER_SH := $(BINARIES_DIR)/install_compiler.bash
INSTALL_SELFHOST ?= 1

# Host toolchain (where this build runs; HOST_UNAME_S comes from emit_target.mk).
# macOS: clang + Apple ld; main_entry_alias.s supplies _main.
# Linux (Debian-family AArch64 or x86-64): cc + GNU ld from build-essential. No entry
# alias (crt1 calls `main`), -no-pie (emitted data tables hold absolute pointers).
# Neither host raises the main-thread stack any more: `main` is not an actor and stays on the
# platform's ordinary stack (spec §15.1.2.2); the compiler's pipeline runs in an actor whose
# runtime-managed stack grows on demand (main.silica), so no link flag and no `ulimit -s` is needed.
ifeq ($(HOST_UNAME_S),Darwin)
ASSEMBLER := clang
MACOS_MIN_VERSION ?= 26.0
ASFLAGS_host := -mmacosx-version-min=$(MACOS_MIN_VERSION)
LINKER_CLANG := $(or $(LINKER_CLANG), $(shell test -x /opt/homebrew/opt/llvm/bin/clang && echo "/opt/homebrew/opt/llvm/bin/clang" || echo "clang"))
LDFLAGS_STACK :=
HOST_RT_ASM := deviceio_link_thunks.s main_entry_alias.s silica_rt_shim.s
else
ASSEMBLER := cc
ASFLAGS_host :=
LINKER_CLANG := cc
LDFLAGS_STACK := -no-pie -rdynamic
# The hand-written runtime of the host's own emit target (runtime_asm/<target>/, one per Linux target).
HOST_RT_ASM := runtime_asm/$(HOST_DEFAULT_TARGET)/deviceio_link_thunks.s runtime_asm/$(HOST_DEFAULT_TARGET)/silica_rt_shim.s
endif

# Parallel .sams → .o assembly (Stage 2). Silica emission (Stage 1) stays serial
# (leaf-to-root + process-per-unit). Override: make build JOBS=4
JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

# Stdlib modules pulled in by compiler_maps (staged under lib/ like trial leaves).
LIB_STDLIB_MODULES := wbt_map OrderedMap
# Stdlib trait modules from the stdlib root (main.silica implements Supervisor for its root supervisor).
STDLIB_ROOT := $(abspath $(THIS_DIR)../stdlib)
LIB_STDLIB_ROOT_MODULES := Supervisor

.DEFAULT_GOAL := build

.PHONY: all clean clean-all build assembly objects executables lib-sources \
	silica.config.regen assembly-selfhost build-selfhost \
	gen1 gen2 trials-gen1 trials-gen2 trials-both fixpoint \
	help --help all-targets check-seed record-compile-start

# Wall-clock compile timing: record epoch seconds at compile start; report
# elapsed time on success or on compilation / emitter / linker failure.
COMPILE_START_FILE := $(BUILD_DIR).compile_start

record-compile-start:
	@mkdir -p "$(BUILD_DIR)"
	@date +%s > "$(COMPILE_START_FILE)"

define REPORT_COMPILE_TIME
	if [ -f "$(COMPILE_START_FILE)" ]; then \
		_start=$$(cat "$(COMPILE_START_FILE)"); \
		_end=$$(date +%s); \
		_elapsed=$$((_end - _start)); \
		if [ "$$_elapsed" -ge 60 ]; then \
			printf 'Compile time: %dm %02ds\n' $$((_elapsed / 60)) $$((_elapsed % 60)); \
		else \
			printf 'Compile time: %ds\n' "$$_elapsed"; \
		fi; \
		rm -f "$(COMPILE_START_FILE)"; \
	fi
endef

# Report elapsed time only when this stage is a top-level goal (not an intermediate).
# Empty MAKECMDGOALS means the default goal `build`.
define MAYBE_REPORT_COMPILE_TIME_SUCCESS
	case " $(if $(MAKECMDGOALS),$(MAKECMDGOALS),build) " in \
	*" $(1) "*|*" $(1)-selfhost "*) $(REPORT_COMPILE_TIME) ;; \
	esac
endef

# Completion chime for this root Makefile only (not the compiler, not subdir Makefiles).
# Tone: Ping — distinct from src (Glass).
define SELFHOST_COMPLETION_BING
	if command -v afplay >/dev/null 2>&1 && [ -f /System/Library/Sounds/Ping.aiff ]; then \
		afplay /System/Library/Sounds/Ping.aiff >/dev/null 2>&1 || true; \
	else \
		printf '\a'; \
	fi
endef

all: clean build

check-seed:
	@if [ ! -x "$(SILICA_COMPILER)" ]; then \
		echo "Missing compiler host: $(SILICA_COMPILER)"; \
		echo "Link it to a known-good compiler, newest first (lowest NNNNNN):"; \
		echo "  (cd $(BINARIES_DIR) && ln -sfn silica-<NNNNNN>-<platform> $$(basename $(SILICA_COMPILER)))"; \
		echo "Available seeds:"; \
		ls "$(BINARIES_DIR)" | grep -E '^silica-[0-9]{6}-seed-[a-z0-9-]+$$' | sort | sed 's/^/  /' || true; \
		exit 1; \
	fi

# Stage stdlib WBT/OrderedMap sources into lib/ for config membership (module name = basename).
LIB_STAGED := $(addprefix $(THIS_DIR)lib/,$(addsuffix .silica,$(LIB_STDLIB_MODULES) $(LIB_STDLIB_ROOT_MODULES)))

$(THIS_DIR)lib/%.silica: $(STDLIB_DS)/%.silica
	@mkdir -p "$(THIS_DIR)lib"
	@if [ ! -f "$<" ]; then echo "FAIL: missing $<"; exit 1; fi
	@cp "$<" "$@"

# wbt_map.silica is one module of about 8,000 lines. Type-checking all of it is
# the unit that a 7 GB runner kills. The compiler calls this module through
# insert (empty, get, fold, contains_key, find_value, size, the compare
# helpers, and insert). Deletion, from_sorted and validate are the rest of the
# file and nothing in this tree calls them. SILICA_COMPILER_WBT_THROUGH=insert
# stages that prefix so the unit fits. compiler/stdlib/data_structures/wbt_map.silica
# stays whole, which is what programs compiled by the result still use.
$(THIS_DIR)lib/wbt_map.silica: $(STDLIB_DS)/wbt_map.silica
	@mkdir -p "$(THIS_DIR)lib"
	@if [ ! -f "$<" ]; then echo "FAIL: missing $<"; exit 1; fi
	@if [ "$(SILICA_COMPILER_WBT_THROUGH)" = "insert" ]; then \
		awk '/^\/\/ §8A\.7 / { exit } \
			/^export (delete|delete_min|delete_max|from_sorted|from_sorted_counted|from_sorted_error_code|from_sorted_preflight_status|validate|validate_error_code)\// { next } \
			{ print }' "$<" > "$@"; \
		echo "staged $@ through insert"; \
	else \
		cp "$<" "$@"; \
	fi

$(THIS_DIR)lib/Supervisor.silica: $(STDLIB_ROOT)/Supervisor.silica
	@mkdir -p "$(THIS_DIR)lib"
	@if [ ! -f "$<" ]; then echo "FAIL: missing $<"; exit 1; fi
	@cp "$<" "$@"

lib-sources: $(LIB_STAGED)

# Canonical batch list (§12). Seed reads the basename `silica.config`.
# Order is a topological sort of module-level `use` edges (topo_silica_config.sh);
# main.silica is forced last. Regenerates only when membership, a unit, TARGET,
# or the topo script changes — not on every make.
TOPO_SILICA_CONFIG := $(THIS_DIR)topo_silica_config.sh
SILICA_CONFIG_UNITS_FILE := $(BUILD_DIR).silica.config.units
CONFIG_COMPILER := $(BUILD_DIR)silica.config.compiler
CONFIG_FILE := $(BUILD_DIR)silica.config

# Detect add/delete: refresh membership list at parse time; mtime bumps only on change.
$(shell \
	if [ -x "$(TOPO_SILICA_CONFIG)" ] && [ -d "$(EMITTER_ROOT)/$(TARGET)" ]; then \
		mkdir -p "$(BUILD_DIR)"; \
		"$(TOPO_SILICA_CONFIG)" --list-units "$(TARGET)" > "$(SILICA_CONFIG_UNITS_FILE).tmp" 2>/dev/null || true; \
		if [ -f "$(SILICA_CONFIG_UNITS_FILE).tmp" ]; then \
			if ! cmp -s "$(SILICA_CONFIG_UNITS_FILE).tmp" "$(SILICA_CONFIG_UNITS_FILE)" 2>/dev/null; then \
				mv "$(SILICA_CONFIG_UNITS_FILE).tmp" "$(SILICA_CONFIG_UNITS_FILE)"; \
			else \
				rm -f "$(SILICA_CONFIG_UNITS_FILE).tmp"; \
			fi; \
		fi; \
	fi \
)

SILICA_CONFIG_UNITS := $(addprefix $(THIS_DIR),$(shell cat "$(SILICA_CONFIG_UNITS_FILE)" 2>/dev/null))

# Membership list (real file). Built when missing; parse-time shell above refreshes on add/delete.
$(SILICA_CONFIG_UNITS_FILE): $(TOPO_SILICA_CONFIG) $(LIB_STAGED) $(TARGET_FILE)
	@mkdir -p "$(BUILD_DIR)"
	@"$(TOPO_SILICA_CONFIG)" --list-units "$(TARGET)" > "$@"

$(CONFIG_COMPILER): $(TARGET_FILE) $(TOPO_SILICA_CONFIG) $(LIB_STAGED) \
		$(SILICA_CONFIG_UNITS_FILE) $(SILICA_CONFIG_UNITS)
	@echo "Regenerating silica.config.compiler (TARGET=$(TARGET), build dir $(BUILD_DIR))..."
	@mkdir -p "$(BUILD_DIR)"
	@"$(TOPO_SILICA_CONFIG)" --list-units "$(TARGET)" > "$(SILICA_CONFIG_UNITS_FILE)"
	@"$(TOPO_SILICA_CONFIG)" "$(TARGET)" > "$(CONFIG_COMPILER).tmp"
	@mv "$(CONFIG_COMPILER).tmp" "$(CONFIG_COMPILER)"
	@test -s "$(CONFIG_COMPILER)" || (echo "FAIL: silica.config.compiler empty"; exit 1)
	@test -n "$$(find "$(THIS_DIR)emitter/$(TARGET)" -type f -name '*.silica' 2>/dev/null | head -n 1)" \
		|| (echo "FAIL: no .silica files under emitter/$(TARGET)/"; exit 1)
	@test "$$(tail -n 1 "$(CONFIG_COMPILER)")" = "main.silica" \
		|| (echo "FAIL: main.silica must be last in silica.config.compiler (mangler/other deps first)"; exit 1)
	@echo "  $$(wc -l < "$(CONFIG_COMPILER)" | tr -d ' ') units (emit target: $(TARGET))"

$(CONFIG_FILE): $(CONFIG_COMPILER)
	@cmp -s "$(CONFIG_COMPILER)" "$(CONFIG_FILE)" 2>/dev/null \
		|| cp "$(CONFIG_COMPILER)" "$(CONFIG_FILE)"

# Short names kept for the command line (make silica.config / silica.target / silica.config.compiler).
.PHONY: silica.config silica.config.compiler silica.target
silica.config: $(CONFIG_FILE)
silica.config.compiler: $(CONFIG_COMPILER)
silica.target: $(TARGET_FILE)

# Force rebuild of the topo-sorted unit list (ignores incremental timestamps).
silica.config.regen:
	@rm -f "$(CONFIG_COMPILER)" "$(CONFIG_FILE)" "$(SILICA_CONFIG_UNITS_FILE)"
	@$(MAKE) -f "$(THIS_DIR)Makefile" silica.config TARGET="$(TARGET)"

# Stage 1: seed reads silica.config → .sams (and optional __silica_runtime.sams / silica.link).
# Multi-unit batches use process-per-unit hygiene: seed exits 75 between units so the OS
# reclaims host heap (required for large modules such as lib/wbt_map.silica).
# Exit 76 means the compiler crashed inside a unit (main.silica, main_crash.silica): the loop runs
# the next process as for 75, and that process reports the unit as failed, skips it and compiles
# the rest; the batch then ends with status 1. silica.compile.inprogress / silica.compile.crashed
# carry that between the processes of one batch and are removed only when a new batch starts.
# Seed failures cover compilation and emitter errors.
#
# Incremental: keep .sams / .iface whose mtime is not older than their .silica source AND not
# older than the seed that produced them. If either artifact is missing or outdated, remove both
# and recompile that unit. Orphan .sams/.iface (no matching .silica) are removed.
# silica.compile.order lists only units that still need a .sams after this prune.
#
# The seed is a staleness input because it decides layout, not just instruction selection: a seed
# fix that moves a record field affects every unit it compiles, so keeping .sams built by an older
# seed links writers using the old offsets against readers using the new ones. That is a silent
# wrong-answer build, and it is exactly what a record-field-offset fix produced here -- the emitter
# modules were recompiled and the rest were not. Comparing against $(SILICA_COMPILER) follows the
# seed-compiler symlink to the binary it currently names, so publishing a new seed invalidates the
# tree on the next build without anyone having to remember to clean.
#
# The seed runs with the target's BUILD_DIR as its working directory (see the header): `stage`
# first makes BUILD_DIR hold one symlink per unit of silica.config (and drops links for units that
# left it), so the relative paths in silica.config resolve there and every output lands there.
# `-nt` and `[ -f ]` follow the links, so staleness is judged against the real source's mtime.
.PHONY: stage
stage: $(CONFIG_FILE)
	@cd "$(BUILD_DIR)" && \
	  while IFS= read -r unit || [ -n "$$unit" ]; do \
	    [ -z "$$unit" ] && continue; \
	    case "$$unit" in \#*) continue ;; esac; \
	    src="$(THIS_DIR)$$unit"; \
	    if [ ! -e "$$unit" ] || [ ! "$$unit" -ef "$$src" ]; then \
	      d=$${unit%/*}; [ "$$d" != "$$unit" ] && mkdir -p "$$d"; \
	      ln -sfn "$$src" "$$unit"; \
	    fi; \
	  done < silica.config; \
	  for l in $$(find . -type l -name '*.silica' | sed 's|^\./||' | sort); do \
	    grep -qxF "$$l" silica.config || { echo "  unstage: $$l"; rm -f "$$l"; }; \
	  done

assembly: check-seed silica.config stage record-compile-start
	@cd "$(BUILD_DIR)" && \
	  SEED_BIN="$(SILICA_COMPILER)"; \
	  removed=0; \
	  for art in $$(find . \( -name '*.sams' -o -name '*.iface' \) ! -path './_wd_probe/*' -type f | sed 's|^\./||' | sort); do \
	    case "$$art" in \
	      __silica_runtime.sams) continue ;; \
	    esac; \
	    case "$$art" in \
	      *.sams) src="$${art%.sams}.silica" ;; \
	      *.iface) src="$${art%.iface}.silica" ;; \
	      *) continue ;; \
	    esac; \
	    if [ ! -f "$$src" ]; then \
	      echo "  orphan: $$art"; \
	      rm -f "$$art"; \
	      removed=$$((removed + 1)); \
	    fi; \
	  done; \
	  while IFS= read -r unit || [ -n "$$unit" ]; do \
	    [ -z "$$unit" ] && continue; \
	    case "$$unit" in \#*) continue ;; esac; \
	    [ -f "$$unit" ] || continue; \
	    base=$${unit%.silica}; \
	    sams="$$base.sams"; \
	    iface="$$base.iface"; \
	    stale=0; \
	    reason="$$unit"; \
	    if [ ! -f "$$sams" ] || [ "$$unit" -nt "$$sams" ]; then stale=1; fi; \
	    if [ ! -f "$$iface" ] || [ "$$unit" -nt "$$iface" ]; then stale=1; fi; \
	    if [ "$$SEED_BIN" -nt "$$sams" ] || [ "$$SEED_BIN" -nt "$$iface" ]; then stale=1; reason="$$SEED_BIN"; fi; \
	    if [ "$$stale" -eq 1 ]; then \
	      if [ -f "$$sams" ] || [ -f "$$iface" ]; then \
	        echo "  stale: $$base.{sams,iface} (vs $$reason)"; \
	      fi; \
	      rm -f "$$sams" "$$iface"; \
	      removed=$$((removed + 1)); \
	    fi; \
	  done < silica.config; \
	  echo "Invalidated $$removed unit artifact set(s)"; \
	  rm -f __silica_runtime.sams silica.link silica.needs_runtime silica.compile.inprogress silica.compile.crashed; \
	  : > silica.compile.order; \
	  while IFS= read -r unit || [ -n "$$unit" ]; do \
	    [ -z "$$unit" ] && continue; \
	    case "$$unit" in \#*) continue ;; esac; \
	    base=$${unit%.silica}; \
	    if [ ! -f "$$base.sams" ]; then \
	      echo "$$unit" >> silica.compile.order; \
	    fi; \
	  done < silica.config; \
	  need=$$(wc -l < silica.compile.order | tr -d ' '); \
	  if [ "$$need" -eq 0 ]; then \
	    rm -f silica.compile.order; \
	    echo "All units up to date (.sams/.iface newer than both .silica and the seed); skipping seed"; \
	    echo "✅ Assembly generated (.sams)"; \
	    $(call MAYBE_REPORT_COMPILE_TIME_SUCCESS,assembly); \
	    exit 0; \
	  fi; \
	  echo "Compiling with seed host: $(SILICA_COMPILER) ($$need unit(s) to compile)"; \
	  echo "Emit target: $(TARGET) (see silica.target)"; \
	  while true; do \
	    "$(SILICA_COMPILER)"; \
	    ec=$$?; \
	    if [ $$ec -eq 0 ]; then break; fi; \
	    if [ $$ec -eq 75 ]; then \
	      echo "  (reclaiming memory; continuing next unit)"; \
	      continue; \
	    fi; \
	    if [ $$ec -eq 76 ]; then \
	      echo "  (the compiler crashed in a unit; continuing with the rest of the batch)"; \
	      continue; \
	    fi; \
	    echo "FAIL: seed compilation failed (exit $$ec)"; \
	    $(REPORT_COMPILE_TIME); \
	    exit 1; \
	  done; \
	  echo "✅ Assembly generated (.sams)"; \
	  $(call MAYBE_REPORT_COMPILE_TIME_SUCCESS,assembly)

# Stage 2: .sams → .o (clang assembler), including nested paths and lib/.
# Invoked in parallel via sub-make -j$(JOBS) after Stage 1 finishes.
%.o: %.sams
	@echo "Assembling: $< -> $@"
	@$(ASSEMBLER) $(ASFLAGS_host) -c -x assembler "$<" -o "$@"

# `objects` normally re-emits stale units first. The Pi bootstrap (below) runs it with
# OBJECTS_PREREQ empty, because no compiler exists there yet to re-emit anything.
#
# emitter/<target>/ trees are parallel implementations of the same function names (one per
# backend), so only the active TARGET's tree may contribute .sams/.o to this build: a leftover
# .sams/.o from a target built earlier in this same checkout (switching TARGET does not clean)
# duplicate-symbols the link. FIND_UNIT_FILES prunes every other emitter/<other>/ subtree; nothing
# outside emitter/ is target-specific, so it is left alone.
FIND_UNIT_FILES = find . \( -path './emitter/*' -a ! -path './emitter/$(TARGET)' -a ! -path './emitter/$(TARGET)/*' \) -prune -o -type f -name '$(1)' ! -path './_wd_probe/*' -print
OBJECTS_PREREQ ?= assembly
objects: $(OBJECTS_PREREQ)
	@cd "$(BUILD_DIR)" && \
	obj_targets=$$($(call FIND_UNIT_FILES,*.sams) \
		| sed 's|^\./||' | sed 's|\.sams$$|.o|' | LC_ALL=C sort | tr '\n' ' '); \
	if [ -z "$$obj_targets" ]; then \
		echo "FAIL: no .sams files found after assembly"; \
		$(REPORT_COMPILE_TIME); exit 1; \
	fi; \
	nobj=$$($(call FIND_UNIT_FILES,*.sams) | wc -l | tr -d ' '); \
	echo "Assembling $$nobj .sams file(s) with -j$(JOBS)..."; \
	if ! $(MAKE) -C "$(BUILD_DIR)" -f "$(THIS_DIR)Makefile" -j$(JOBS) $$obj_targets; then \
		$(REPORT_COMPILE_TIME); exit 1; \
	fi; \
	$(call MAYBE_REPORT_COMPILE_TIME_SUCCESS,objects)

# Stage 3: link entry point `main` with all module objects + runtime.
# No Rust archive is linked (see POLICY above); DeviceIO helpers come from
# silica_rt_shim.s (runtime_asm/linux_aarch64/ on Linux). deviceio_link_thunks.s covers seeds
# that still emit DeviceIO as module_user calls. main_entry_alias.s provides _main for
# Apple ld only (asm emits `main` without underscore). HOST_RT_ASM picks the set per host.
executables: objects
	@cd "$(BUILD_DIR)" && \
	if [ ! -f main.o ]; then echo "FAIL: main.o missing"; $(REPORT_COMPILE_TIME); exit 1; fi; \
	for s in $(HOST_RT_ASM); do \
		d=$${s%/*}; [ "$$d" != "$$s" ] && mkdir -p "$$d"; \
		$(ASSEMBLER) $(ASFLAGS_host) -c "$(THIS_DIR)$$s" -o "$${s%.s}.o" || { $(REPORT_COMPILE_TIME); exit 1; }; \
	done; \
	objs=$$($(call FIND_UNIT_FILES,*.o) | sed 's|^\./||' | sort | tr '\n' ' '); \
	link_archives=""; \
	if [ -x "$(SILICA_LINK_SH)" ]; then link_archives=$$("$(SILICA_LINK_SH)" .); fi; \
	echo "Linking: $(EXECUTABLE)"; \
	if ! $(LINKER_CLANG) $$objs $$link_archives $(LDFLAGS_STACK) -o $(EXECUTABLE); then \
		echo "FAIL: linker failed"; \
		$(REPORT_COMPILE_TIME); \
		exit 1; \
	fi; \
	echo "✅ Built $(EXECUTABLE)"; \
	if [ "$(INSTALL_SELFHOST)" = "1" ] && [ "$(TARGET)" != "$(HOST_DEFAULT_TARGET)" ]; then \
		if [ -x "$(INSTALL_COMPILER_SH)" ]; then \
			"$(INSTALL_COMPILER_SH)" target "$(TARGET)" "$(BUILD_DIR)$(EXECUTABLE)" || { $(REPORT_COMPILE_TIME); exit 1; }; \
		else \
			echo "WARN: $(INSTALL_COMPILER_SH) missing; binaries/silica-compiler-$(TARGET) not updated"; \
		fi; \
	elif [ "$(INSTALL_SELFHOST)" = "1" ] && [ "$(EXECUTABLE)" = "silica-compiler" ]; then \
		if [ -x "$(INSTALL_COMPILER_SH)" ]; then \
			"$(INSTALL_COMPILER_SH)" selfhost "$(BUILD_DIR)$(EXECUTABLE)" || { $(REPORT_COMPILE_TIME); exit 1; }; \
		else \
			echo "WARN: $(INSTALL_COMPILER_SH) missing; binaries/silica-compiler still points at the previous selfhost"; \
		fi; \
	fi; \
	$(call MAYBE_REPORT_COMPILE_TIME_SUCCESS,executables)

# ---- Bootstrap of the first Linux-hosted compiler (temporary) ----------------------
# No compiler exists on a new Linux host, so its first one is built in two halves on two machines.
#   Mac:   make bootstrap-assembly [BOOTSTRAP_TARGET=linux_x86_64]
#                                    the macOS-hosted cross compiler for that target emits every
#                                    unit of this tree as its assembly (.sams); nothing is assembled here.
#   Linux: make bootstrap-link       the system assembler and linker turn the shipped .sams and
#                                    runtime_asm/<target>/ into silica-compiler, and install it as
#                                    this host's selfhost compiler. No compiler runs.
# Between the two, copy this tree and compiler/build/<BOOTSTRAP_TARGET>/ (its .sams and
# silica.link) to the Linux host. Once a compiler exists there
# the ordinary `make build` runs natively and these two targets are no longer needed.
BOOTSTRAP_TARGET ?= linux_aarch64
BOOTSTRAP_CROSS_COMPILER := $(BINARIES_DIR)/silica-compiler-$(BOOTSTRAP_TARGET)

bootstrap-assembly:
	@$(MAKE) -C "$(THIS_DIR)" -f "$(THIS_DIR)Makefile" assembly TARGET=$(BOOTSTRAP_TARGET) \
		SILICA_COMPILER="$(BOOTSTRAP_CROSS_COMPILER)" INSTALL_SELFHOST=0 SILICA_TARGET_PROMPT=0
	@n=$$(find "$(BUILD_ROOT)/$(BOOTSTRAP_TARGET)" -name '*.sams' -type f ! -path '*/_wd_probe/*' | wc -l | tr -d ' '); \
	echo "bootstrap-assembly: $$n .sams emitted for $(BOOTSTRAP_TARGET) into $(BUILD_ROOT)/$(BOOTSTRAP_TARGET)/; copy this tree and that directory to the Linux host and run make bootstrap-link there"

bootstrap-link:
	@if [ "$$(uname -s)" != Linux ]; then echo "FAIL: bootstrap-link assembles and links on the Linux host, not here"; exit 1; fi
	@$(MAKE) -C "$(THIS_DIR)" -f "$(THIS_DIR)Makefile" executables OBJECTS_PREREQ= SILICA_TARGET_PROMPT=0

# Plain `make` / `build`: if silica.config (topo unit list) is missing or stale,
# build it first; then run the normal assembly → objects → link pipeline.
build: silica.config executables
	@$(REPORT_COMPILE_TIME)
	@$(SELFHOST_COMPLETION_BING)

assembly-selfhost: assembly
build-selfhost: build

# ---- Generations -------------------------------------------------------------------
# gen1 = this tree compiled by the seed (binaries/seed-compiler); gen2 = this tree compiled by
# gen1. Each build also keeps a stable copy, binaries/silica-gen1 and binaries/silica-gen2, so
# the trial tree can be run against either generation by name (the numbered install and the
# silica-compiler symlink keep tracking the newest build as before; INSTALL_SELFHOST=0 still
# skips that). gen2 recompiles every unit: the compiler binary is a staleness input.
#
#   make gen1            seed-compiler  -> src  => binaries/silica-gen1
#   make gen2            silica-gen1    -> src  => binaries/silica-gen2
#   make trials-gen1     make -C trials integrate SILICA_COMPILER=binaries/silica-gen1
#   make trials-gen2     make -C trials integrate SILICA_COMPILER=binaries/silica-gen2
#   make trials-both     trials-gen1 then trials-gen2 (reports kept as .integrate_report.gen1/.gen2)
TRIALS_DIR := $(abspath $(THIS_DIR)../../trials)
GEN1_BIN := $(BINARIES_DIR)/silica-gen1
GEN2_BIN := $(BINARIES_DIR)/silica-gen2

gen1:
	@$(MAKE) -C "$(THIS_DIR)" -f "$(THIS_DIR)Makefile" build SILICA_COMPILER="$(BINARIES_DIR)/seed-compiler"
	@rm -f "$(GEN1_BIN)" && cp "$(BUILD_DIR)$(EXECUTABLE)" "$(GEN1_BIN)" && chmod +x "$(GEN1_BIN)"
	@echo "✅ gen1 (seed-built selfhost) saved as $(GEN1_BIN)"

gen2:
	@if [ ! -x "$(GEN1_BIN)" ]; then \
		echo "FAIL: $(GEN1_BIN) is missing; run 'make gen1' first"; exit 1; \
	fi
	@$(MAKE) -C "$(THIS_DIR)" -f "$(THIS_DIR)Makefile" build SILICA_COMPILER="$(GEN1_BIN)"
	@rm -f "$(GEN2_BIN)" && cp "$(BUILD_DIR)$(EXECUTABLE)" "$(GEN2_BIN)" && chmod +x "$(GEN2_BIN)"
	@touch "$(GEN1_EMISSION_STAMP)"
	@echo "✅ gen2 (selfhost-built selfhost) saved as $(GEN2_BIN)"

trials-gen1:
	@if [ ! -x "$(GEN1_BIN)" ]; then echo "FAIL: $(GEN1_BIN) is missing; run 'make gen1' first"; exit 1; fi
	@echo "==== trials with gen1: $(GEN1_BIN) ===="
	@$(MAKE) -C "$(TRIALS_DIR)" integrate SILICA_COMPILER="$(GEN1_BIN)"; st=$$?; \
	cp -f "$(TRIALS_DIR)/.integrate_report" "$(TRIALS_DIR)/.integrate_report.gen1" 2>/dev/null; \
	echo "report kept at $(TRIALS_DIR)/.integrate_report.gen1"; exit $$st

trials-gen2:
	@if [ ! -x "$(GEN2_BIN)" ]; then echo "FAIL: $(GEN2_BIN) is missing; run 'make gen2' first"; exit 1; fi
	@echo "==== trials with gen2: $(GEN2_BIN) ===="
	@$(MAKE) -C "$(TRIALS_DIR)" integrate SILICA_COMPILER="$(GEN2_BIN)"; st=$$?; \
	cp -f "$(TRIALS_DIR)/.integrate_report" "$(TRIALS_DIR)/.integrate_report.gen2" 2>/dev/null; \
	echo "report kept at $(TRIALS_DIR)/.integrate_report.gen2"; exit $$st

trials-both:
	@$(MAKE) -C "$(THIS_DIR)" -f "$(THIS_DIR)Makefile" trials-gen1
	@$(MAKE) -C "$(THIS_DIR)" -f "$(THIS_DIR)Makefile" trials-gen2

# ---- Fixed point ------------------------------------------------------------------
# gen3 = this tree compiled by gen2. The compiler has reached its fixed point when gen3 is
# byte-identical to gen2: nothing in the binary was inherited from the seed.
#
# Run right after `make gen2`: at that moment the .sams here are gen1's emission of these
# sources (gen2's code). `make gen2` stamps them; the stamp check refuses a tree whose .sams
# were rewritten since. gen1's .sams are saved OUTSIDE this directory (the assembly rule's
# orphan scan deletes any .sams under here that has no .silica beside it), gen3 is built
# with gen2, and the .sams are compared unit by unit with the o<N> counters normalised.
#
# gen3 is linked at the same path as gen2 (./silica-compiler): Apple's linker derives the
# LC_UUID and the ad-hoc signature identifier from the output path, so a binary linked under
# another name can never be byte-identical. It is not installed (INSTALL_SELFHOST=0) and is
# kept as silica-compiler-gen3.
FIXPOINT_DIR := $(BUILD_ROOT)/$(TARGET).fixpoint
GEN1_EMISSION_STAMP := $(BUILD_DIR).gen1_emission_stamp
GEN3_EXE := silica-compiler-gen3

fixpoint:
	@if [ ! -x "$(GEN2_BIN)" ]; then echo "FAIL: $(GEN2_BIN) is missing; run 'make gen2' first"; exit 1; fi
	@if [ ! -f "$(GEN1_EMISSION_STAMP)" ]; then \
		echo "FAIL: the .sams here are not the fresh output of 'make gen2'; run 'make gen2' first"; exit 1; \
	fi
	@cd "$(BUILD_DIR)" && newer=$$(find . -name '*.sams' -type f ! -path './_wd_probe/*' -newer "$(GEN1_EMISSION_STAMP)" | head -3); \
	if [ -n "$$newer" ]; then \
		echo "FAIL: .sams rewritten since 'make gen2' (e.g. $$newer); run 'make gen2' first"; exit 1; \
	fi
	@if ! cmp -s "$(GEN2_BIN)" "$(BUILD_DIR)$(EXECUTABLE)"; then \
		echo "FAIL: $(BUILD_DIR)$(EXECUTABLE) is not the gen2 build; run 'make gen2' first"; exit 1; \
	fi
	@rm -rf "$(FIXPOINT_DIR)" && mkdir -p "$(FIXPOINT_DIR)/gen1_sams"
	@cd "$(BUILD_DIR)" && find . -name '*.sams' -type f ! -path './_wd_probe/*' | while read -r f; do \
		mkdir -p "$(FIXPOINT_DIR)/gen1_sams/$$(dirname "$$f")"; cp "$$f" "$(FIXPOINT_DIR)/gen1_sams/$$f"; done
	@n=$$(find "$(FIXPOINT_DIR)/gen1_sams" -name '*.sams' -type f | wc -l | tr -d ' '); \
	echo "saved $$n .sams (gen1's emission) to $(FIXPOINT_DIR)/gen1_sams"; \
	if [ "$$n" -eq 0 ]; then echo "FAIL: nothing saved"; exit 1; fi
	@rm -f "$(GEN1_EMISSION_STAMP)"
	@echo "==== fixpoint: building gen3 with $(GEN2_BIN) ===="
	@$(MAKE) -C "$(THIS_DIR)" -f "$(THIS_DIR)Makefile" build SILICA_COMPILER="$(GEN2_BIN)" INSTALL_SELFHOST=0
	@rm -f "$(BUILD_DIR)$(GEN3_EXE)" && cp "$(BUILD_DIR)$(EXECUTABLE)" "$(BUILD_DIR)$(GEN3_EXE)"
	@cd "$(BUILD_DIR)" && n=0; changed=0; added=0; missing=0; \
	for f in $$(find . -name '*.sams' -type f ! -path './_wd_probe/*' | sed 's|^\./||' | sort); do \
		n=$$((n + 1)); \
		if [ ! -f "$(FIXPOINT_DIR)/gen1_sams/$$f" ]; then added=$$((added + 1)); echo "   + $$f (no gen1 counterpart)"; continue; fi; \
		sed -E 's/o[0-9]+/oN/g' "$(FIXPOINT_DIR)/gen1_sams/$$f" > "$(FIXPOINT_DIR)/a.norm"; \
		sed -E 's/o[0-9]+/oN/g' "$$f" > "$(FIXPOINT_DIR)/b.norm"; \
		if ! cmp -s "$(FIXPOINT_DIR)/a.norm" "$(FIXPOINT_DIR)/b.norm"; then \
			changed=$$((changed + 1)); echo "   * $$f"; \
			diff "$(FIXPOINT_DIR)/a.norm" "$(FIXPOINT_DIR)/b.norm" | head -6 | sed 's/^/       /'; \
		fi; \
	done; \
	for f in $$(cd "$(FIXPOINT_DIR)/gen1_sams" && find . -name '*.sams' -type f | sed 's|^\./||'); do \
		[ -f "$$f" ] || { missing=$$((missing + 1)); echo "   - $$f (gone in gen3)"; }; \
	done; \
	echo "units: $$n compared, $$changed emitted differently by gen2 than by gen1, $$added new, $$missing gone"; \
	s2=$$(stat -c %s "$(GEN2_BIN)" 2>/dev/null || stat -f %z "$(GEN2_BIN)" 2>/dev/null); s3=$$(stat -c %s "$(GEN3_EXE)" 2>/dev/null || stat -f %z "$(GEN3_EXE)" 2>/dev/null); \
	echo "binaries: gen2 $$s2 bytes, gen3 $$s3 bytes"; \
	if cmp -s "$(GEN2_BIN)" "$(GEN3_EXE)"; then \
		echo "✅ fixed point: gen3 is byte-identical to gen2 ($(GEN2_BIN))"; \
	else \
		echo "❌ not a fixed point: gen3 differs from gen2"; \
		if [ "$$changed$$added$$missing" = "000" ]; then \
			echo "   every unit's emission is identical; the difference is in linking (compare 'otool -l' of the two binaries)"; \
		fi; \
		echo "   gen1's .sams are kept under $(FIXPOINT_DIR)/gen1_sams/"; \
		exit 1; \
	fi

all-targets:
	@if [ -z "$(ALLOWED_TARGETS)" ]; then \
		echo "FAIL: no emitter/*/ targets found"; \
		exit 1; \
	fi
	@for t in $(ALLOWED_TARGETS); do \
		echo ""; \
		echo "======== all-targets: TARGET=$$t ========"; \
		$(MAKE) -C "$(THIS_DIR)" clean build TARGET=$$t EXECUTABLE=silica-compiler-$$t || exit 1; \
	done
	@echo ""
	@echo "✅ all-targets complete: $(ALLOWED_TARGETS)"

# clean: this target's build directory only (TARGET, the host's by default); the other targets'
# incremental state is kept. clean-all: every target's, plus the outputs older checkouts left
# beside the sources in src/ (before the per-target build directories existed).
clean:
	@test -n "$(TARGET)" || { echo "FAIL: no TARGET (host not recognised); use make clean TARGET=<emit-target> or make clean-all"; exit 1; }
	@echo "Cleaning $(BUILD_DIR) ..."
	@rm -rf "$(BUILD_DIR)" "$(FIXPOINT_DIR)"
	@echo "✅ Clean complete ($(TARGET))"

clean-all:
	@echo "Cleaning every target's build directory under $(BUILD_ROOT) and legacy outputs in src/ ..."
	@rm -rf "$(BUILD_ROOT)"
	@cd "$(THIS_DIR)" && \
	  find . \( -name '*.sams' -o -name '*.o' -o -name '*.ll' -o -name '*.bc' \) ! -path './_wd_probe/*' -delete; \
	  rm -f silica-compiler silica.config silica.config.compiler silica.target silica.link \
	    silica.compile.order silica.compile.inprogress silica.compile.crashed \
	    .silica.config.units .silica.config.units.tmp silica.config.compiler.tmp \
	    __silica_runtime.sams __silica_runtime.o .compile_start .gen1_emission_stamp; \
	  rm -f silica-compiler-* 2>/dev/null || true; \
	  rm -f lib/wbt_map.silica lib/OrderedMap.silica lib/wbt_map.sams lib/OrderedMap.sams lib/*.o 2>/dev/null || true; \
	  rm -rf .cache/ifaces; \
	  find . -name '*.iface' -type f ! -path './_wd_probe/*' -delete 2>/dev/null || true
	@echo "✅ Clean complete (all targets)"

# Project help. Prefer: make help
# Note: plain `make --help` is GNU Make's own help; use `make help` or `make -- --help`.
--help: help
help:
	@echo "src — config-driven seed build for silica-compiler"
	@echo ""
	@echo "Usage:"
	@echo "  make [target] [TARGET=<emit-target>] [EXECUTABLE=<name>]"
	@echo "  make help"
	@echo "  make -- --help"
	@echo ""
	@echo "Emit target (TARGET)"
	@echo "  Selects which emitter/<TARGET>/ backend is included in silica.config"
	@echo "  and writes <build dir>/silica.target (emit_target: <TARGET>)."
	@echo "  This is the code-generation / emit backend baked into this build —"
	@echo "  not a runtime cross-compile switch inside an already-built binary."
	@echo "  It is also not the local host binary tag used by binaries/"
	@echo "  (e.g. macos-applesilicon); those name where the compiler runs."
	@echo ""
	@echo "  Default: current host platform when TARGET is unset."
	@echo "  Host:    $(HOST_UNAME_S) $(HOST_UNAME_M)"
	@echo "  Active:  TARGET=$(TARGET)  (source: $(TARGET_ORIGIN))"
	@echo "  Build:   $(BUILD_DIR)  (silica.target → emit_target: $(TARGET))"
	@echo ""
	@echo "  Allowable emit targets (from emitter/*/):"
	@for t in $(ALLOWED_TARGETS); do \
		if [ "$$t" = "$(TARGET)" ]; then echo "    * $$t  (selected)"; \
		else echo "      $$t"; fi; \
	done
	@if [ -z "$(ALLOWED_TARGETS)" ]; then echo "      (none found)"; fi
	@echo ""
	@echo "  Examples:"
	@echo "    make                          # asks which emit target to build (default: host)"
	@echo "    make SILICA_TARGET_PROMPT=0   # never ask: host-default TARGET + full build"
	@echo "    make gen1                     # selfhost compiled by seed-compiler -> binaries/silica-gen1"
	@echo "    make gen2                     # selfhost compiled by gen1 -> binaries/silica-gen2"
	@echo "    make trials-gen1 | trials-gen2 | trials-both   # full trial tree against a generation"
	@echo "    make fixpoint                 # build gen3 with gen2; pass iff gen3 == gen2 byte for byte"
	@echo "    make TARGET=apple_silicon_mac     # explicit emit backend"
	@echo "    make TARGET=linux_aarch64         # Linux AArch64 backend (64-bit Raspberry Pi OS)"
	@echo "    make TARGET=linux_x86_64          # Linux x86-64 backend (Debian-family x86-64 hosts)"
	@echo "    make assembly TARGET=apple_silicon_mac"
	@echo "    make all-targets              # loop clean/build for each allowable TARGET"
	@echo ""
	@echo "Build targets"
	@echo "  make / build              create silica.config if missing/stale, then seed → .o → $(EXECUTABLE)"
	@echo "  assembly                  seed compile only (.sams); keeps up-to-date .sams/.iface"
	@echo "  objects                   assemble .sams → .o (parallel -j$(JOBS); override with JOBS=N)"
	@echo "  executables               link $(EXECUTABLE)"
	@echo "  silica.config             create/update topo-sorted unit list if missing or stale"
	@echo "  silica.config.regen       force-regenerate unit list (ignores timestamps)"
	@echo "  silica.target             rewrite emit_target declaration"
	@echo "  all-targets               build silica-compiler-<TARGET> for each allowable TARGET"
	@echo "  clean                     remove TARGET's build directory $(BUILD_ROOT)/<TARGET>/ (other targets keep theirs)"
	@echo "  clean-all                 remove every target's build directory and legacy outputs left in src/"
	@echo "  stage                     link the units of silica.config into the build directory"
	@echo "  check-target              validate TARGET against emitter/*/"
	@echo "  check-seed                ensure binaries/seed-compiler exists"
	@echo ""
	@echo "Paths"
	@echo "  Seed compiler:  $(SILICA_COMPILER)"
	@echo "  Emitter root:   $(EMITTER_ROOT)"
	@echo "  This tree:      $(THIS_DIR)"
	@echo "  Build dir:      $(BUILD_DIR)"
