# Config-driven Silica project build: generate silica.config, run silica-compiler
# (no argv), then .sams → .o → link.
#
# Drop this Makefile and its sibling support files into your application source
# root. Optionally copy Makefile.subdir into each subdirectory as Makefile.
#
# Usage:
#   make help                   # descriptive help
#   make                        # assembly + objects + link
#   make assembly               # compile only (.sams)
#   make SILICA_COMPILER=/path/to/silica-compiler
#   make EXECUTABLE=my_app

THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)silica_compiler.mk

SILICA_LINK_SH := $(THIS_DIR)silica_link.sh
EXECUTABLE ?= $(notdir $(patsubst %/,%,$(THIS_DIR)))
ASSEMBLER := clang
MACOS_MIN_VERSION ?= 26.0
ASFLAGS_macos := -mmacosx-version-min=$(MACOS_MIN_VERSION)
LINKER_CLANG := $(or $(LINKER_CLANG), $(shell test -x /opt/homebrew/opt/llvm/bin/clang && echo "/opt/homebrew/opt/llvm/bin/clang" || echo "clang"))
# Raise main-thread stack when modules recurse deeply (macOS default is often 8MB).
LDFLAGS_STACK ?= -Wl,-stack_size,0x10000000

# Parallel .sams → .o assembly (Stage 2). Silica emission (Stage 1) stays serial
# (leaf-to-root + process-per-unit). Override: make build JOBS=4
JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

.DEFAULT_GOAL := build

.PHONY: all clean build assembly objects executables \
	silica.config.regen help --help check-seed record-compile-start

# Wall-clock compile timing: record epoch seconds at compile start; report
# elapsed time on success or on compilation / assembler / linker failure.
COMPILE_START_FILE := $(THIS_DIR).compile_start

record-compile-start:
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
	*" $(1) "*) $(REPORT_COMPILE_TIME) ;; \
	esac
endef

define COMPLETION_BING
	if command -v afplay >/dev/null 2>&1 && [ -f /System/Library/Sounds/Ping.aiff ]; then \
		afplay /System/Library/Sounds/Ping.aiff >/dev/null 2>&1 || true; \
	else \
		printf '\a'; \
	fi
endef

all: clean build

check-seed: ensure-silica-compiler

# Canonical batch list. silica-compiler reads the basename `silica.config`.
# Order is a topological sort of module-level `use` edges (topo_silica_config.sh);
# main.silica is forced last when present. Regenerates only when membership, a
# unit, or the topo script changes — not on every make.
TOPO_SILICA_CONFIG := $(THIS_DIR)topo_silica_config.sh
SILICA_CONFIG_UNITS_FILE := $(THIS_DIR).silica.config.units

# Detect add/delete: refresh membership list at parse time; mtime bumps only on change.
$(shell \
	if [ -x "$(TOPO_SILICA_CONFIG)" ]; then \
		"$(TOPO_SILICA_CONFIG)" --list-units > "$(SILICA_CONFIG_UNITS_FILE).tmp" 2>/dev/null || true; \
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

$(SILICA_CONFIG_UNITS_FILE): $(TOPO_SILICA_CONFIG)
	@"$(TOPO_SILICA_CONFIG)" --list-units > "$@"

silica.config.compiler: $(TOPO_SILICA_CONFIG) \
		$(SILICA_CONFIG_UNITS_FILE) $(SILICA_CONFIG_UNITS)
	@echo "Regenerating silica.config.compiler..."
	@cd "$(THIS_DIR)" && "$(TOPO_SILICA_CONFIG)" --list-units > "$(SILICA_CONFIG_UNITS_FILE)"
	@cd "$(THIS_DIR)" && "$(TOPO_SILICA_CONFIG)" > silica.config.compiler.tmp
	@mv "$(THIS_DIR)silica.config.compiler.tmp" "$(THIS_DIR)silica.config.compiler"
	@test -s "$(THIS_DIR)silica.config.compiler" || (echo "FAIL: silica.config.compiler empty"; exit 1)
	@if [ -f "$(THIS_DIR)main.silica" ]; then \
		test "$$(tail -n 1 "$(THIS_DIR)silica.config.compiler")" = "main.silica" \
			|| (echo "FAIL: main.silica must be last in silica.config.compiler"; exit 1); \
	fi
	@echo "  $$(wc -l < "$(THIS_DIR)silica.config.compiler" | tr -d ' ') units"

silica.config: silica.config.compiler
	@cmp -s "$(THIS_DIR)silica.config.compiler" "$(THIS_DIR)silica.config" 2>/dev/null \
		|| cp "$(THIS_DIR)silica.config.compiler" "$(THIS_DIR)silica.config"

# Force rebuild of the topo-sorted unit list (ignores incremental timestamps).
silica.config.regen:
	@rm -f "$(THIS_DIR)silica.config.compiler" "$(THIS_DIR)silica.config" "$(SILICA_CONFIG_UNITS_FILE)"
	@$(MAKE) -f "$(THIS_DIR)Makefile" silica.config

# Stage 1: silica-compiler reads silica.config → .sams (and optional
# __silica_runtime.sams / silica.link). Multi-unit batches use process-per-unit
# hygiene: the compiler exits 75 between units so the OS reclaims host heap.
#
# Incremental: keep .sams / .iface whose mtime is not older than their .silica.
# If either artifact is missing or older than .silica, remove both and recompile.
# Orphan .sams/.iface (no matching .silica) are removed. silica.compile.order
# lists only units that still need a .sams after this prune.
assembly: check-seed silica.config record-compile-start
	@cd "$(THIS_DIR)" && \
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
	    if [ ! -f "$$sams" ] || [ "$$unit" -nt "$$sams" ]; then stale=1; fi; \
	    if [ ! -f "$$iface" ] || [ "$$unit" -nt "$$iface" ]; then stale=1; fi; \
	    if [ "$$stale" -eq 1 ]; then \
	      if [ -f "$$sams" ] || [ -f "$$iface" ]; then \
	        echo "  stale: $$base.{sams,iface} (vs $$unit)"; \
	      fi; \
	      rm -f "$$sams" "$$iface"; \
	      removed=$$((removed + 1)); \
	    fi; \
	  done < silica.config; \
	  echo "Invalidated $$removed unit artifact set(s)"; \
	  rm -f __silica_runtime.sams silica.link silica.needs_runtime silica.atoms silica.shapes; \
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
	    echo "All units up to date (.sams/.iface not older than .silica); skipping compile"; \
	    echo "✅ Assembly generated (.sams)"; \
	    $(call MAYBE_REPORT_COMPILE_TIME_SUCCESS,assembly); \
	    exit 0; \
	  fi; \
	  echo "Compiling with $(SILICA_COMPILER) ($$need unit(s) to compile)"; \
	  rm -f silica.compile.inprogress silica.compile.crashed; \
	  while true; do \
	    "$(SILICA_COMPILER)"; \
	    ec=$$?; \
	    if [ $$ec -eq 0 ]; then break; fi; \
	    if [ $$ec -eq 75 ] || [ $$ec -eq 76 ]; then \
	      echo "  (reclaiming memory; continuing next unit)"; \
	      continue; \
	    fi; \
	    echo "FAIL: compilation failed (exit $$ec)"; \
	    $(REPORT_COMPILE_TIME); \
	    exit 1; \
	  done; \
	  echo "✅ Assembly generated (.sams)"; \
	  $(call MAYBE_REPORT_COMPILE_TIME_SUCCESS,assembly)

# Stage 2: .sams → .o (clang assembler), including nested paths.
# Invoked in parallel via sub-make -j$(JOBS) after Stage 1 finishes.
%.o: %.sams
	@echo "Assembling: $< -> $@"
	@$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$<" -o "$@"

objects: assembly
	@cd "$(THIS_DIR)" && \
	obj_targets=$$(find . -type f -name '*.sams' ! -path './_wd_probe/*' \
		| sed 's|^\./||' | sed 's|\.sams$$|.o|' | LC_ALL=C sort | tr '\n' ' '); \
	if [ -z "$$obj_targets" ]; then \
		echo "FAIL: no .sams files found after assembly"; \
		$(REPORT_COMPILE_TIME); exit 1; \
	fi; \
	nobj=$$(find . -type f -name '*.sams' ! -path './_wd_probe/*' | wc -l | tr -d ' '); \
	echo "Assembling $$nobj .sams file(s) with -j$(JOBS)..."; \
	if ! $(MAKE) -C "$(THIS_DIR)" -f "$(THIS_DIR)Makefile" -j$(JOBS) $$obj_targets; then \
		$(REPORT_COMPILE_TIME); exit 1; \
	fi; \
	$(call MAYBE_REPORT_COMPILE_TIME_SUCCESS,objects)

# Stage 3: link entry point `main` with all module objects + optional runtime / archives
executables: objects
	@cd "$(THIS_DIR)" && \
	if [ ! -f main.o ]; then echo "FAIL: main.o missing (need main.silica as the app entry)"; $(REPORT_COMPILE_TIME); exit 1; fi; \
	objs=$$(find . -type f -name '*.o' ! -path './_wd_probe/*' | sed 's|^\./||' | sort | tr '\n' ' '); \
	link_archives=""; \
	if [ -x "$(SILICA_LINK_SH)" ]; then link_archives=$$("$(SILICA_LINK_SH)" .); fi; \
	echo "Linking: $(EXECUTABLE)"; \
	if ! $(LINKER_CLANG) $$objs $$link_archives $(LDFLAGS_STACK) -o $(EXECUTABLE); then \
		echo "FAIL: linker failed"; \
		$(REPORT_COMPILE_TIME); \
		exit 1; \
	fi; \
	echo "✅ Built $(EXECUTABLE)"; \
	$(call MAYBE_REPORT_COMPILE_TIME_SUCCESS,executables)

# Plain `make` / `build`: if silica.config is missing or stale, build it first;
# then run the normal assembly → objects → link pipeline.
build: silica.config executables
	@$(REPORT_COMPILE_TIME)
	@$(COMPLETION_BING)

clean:
	@echo "Cleaning generated files (including *.iface and .cache/ifaces)..."
	@cd "$(THIS_DIR)" && \
	  find . \( -name '*.sams' -o -name '*.o' -o -name '*.ll' -o -name '*.bc' \) ! -path './_wd_probe/*' -delete; \
	  rm -f $(EXECUTABLE) silica.config silica.config.compiler silica.link \
	    silica.compile.order \
	    .silica.config.units .silica.config.units.tmp silica.config.compiler.tmp \
	    __silica_runtime.sams __silica_runtime.o "$(COMPILE_START_FILE)"; \
	  rm -rf .cache/ifaces; \
	  find . -name '*.iface' -type f ! -path './_wd_probe/*' -delete 2>/dev/null || true
	@echo "✅ Clean complete"

# Note: plain `make --help` is GNU Make's own help; use `make help` or `make -- --help`.
--help: help
help:
	@echo "Silica project — config-driven build"
	@echo ""
	@echo "Usage:"
	@echo "  make [target] [EXECUTABLE=<name>] [SILICA_COMPILER=<path>]"
	@echo "  make help"
	@echo "  make -- --help"
	@echo ""
	@echo "Build targets"
	@echo "  make / build              create silica.config if missing/stale, then compile → .o → $(EXECUTABLE)"
	@echo "  assembly                  compile only (.sams); keeps up-to-date .sams/.iface"
	@echo "  objects                   assemble .sams → .o (parallel -j$(JOBS); override with JOBS=N)"
	@echo "  executables               link $(EXECUTABLE)"
	@echo "  silica.config             create/update topo-sorted unit list if missing or stale"
	@echo "  silica.config.regen       force-regenerate unit list (ignores timestamps)"
	@echo "  clean                     remove generated artifacts (*.sams/*.o, silica.compile.order, *.iface, .cache/ifaces)"
	@echo "  check-seed                ensure silica-compiler is available"
	@echo ""
	@echo "Paths"
	@echo "  Compiler:   $(if $(SILICA_COMPILER),$(SILICA_COMPILER),(not found on PATH))"
	@echo "  Executable: $(EXECUTABLE)"
	@echo "  This tree:  $(THIS_DIR)"
