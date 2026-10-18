# Shared silica-compiler invocation helpers for a project root Makefile.
# Include after setting THIS_DIR to the project root (trailing slash).
#
# Override on the command line if needed:
#   make SILICA_COMPILER=/path/to/silica-compiler

# Prefer binaries/silica-compiler, found by walking up from the project root so this works at
# any nesting depth, and fall back to PATH only when there is no binaries/ above (an app built
# against an installed compiler). Inside a silica checkout the link must win: a PATH lookup
# picks whichever silica-compiler comes first, which can be an unrelated checkout on another
# volume, and then a fix made here appears to have no effect at all.
#
# binaries/silica-compiler is the SELFHOST compiler, which is what compiles application .silica
# files. binaries/seed-compiler is the seed and is only for building src; see
# binaries/install_compiler.bash.
ifeq ($(filter command line,$(origin SILICA_COMPILER)),)
  ifeq ($(origin SILICA_COMPILER),undefined)
    SILICA_BINARIES_DIR := $(shell d="$(abspath $(THIS_DIR))"; while [ "$$d" != "/" ]; do if [ -d "$$d/binaries" ]; then echo "$$d/binaries"; break; fi; d=$$(dirname "$$d"); done)
    ifeq ($(SILICA_BINARIES_DIR),)
      SILICA_COMPILER := $(shell command -v silica-compiler 2>/dev/null)
    else
      SILICA_COMPILER := $(SILICA_BINARIES_DIR)/silica-compiler
    endif
  endif
endif

.PHONY: ensure-silica-compiler

ensure-silica-compiler:
	@if [ -z "$(SILICA_COMPILER)" ]; then \
		echo "FAIL: no binaries/ directory above $(abspath $(THIS_DIR)) and no silica-compiler on PATH."; \
		echo "Build the selfhost compiler (make -C compiler/src),"; \
		echo "or pass SILICA_COMPILER=/path/to/silica-compiler"; \
		exit 1; \
	fi; \
	if [ ! -e "$(SILICA_COMPILER)" ]; then \
		echo "FAIL: $(SILICA_COMPILER) does not exist."; \
		echo "Build the selfhost compiler to create it: make -C compiler/src"; \
		echo "(that installs binaries/silica-<NNNNNN>-<platform> and links silica-compiler to it)"; \
		exit 1; \
	fi; \
	if [ ! -x "$(SILICA_COMPILER)" ]; then \
		echo "FAIL: SILICA_COMPILER is not executable: $(SILICA_COMPILER)"; \
		exit 1; \
	fi

# Multi-unit batches use process-per-unit hygiene: the compiler exits 75 (EX_TEMPFAIL)
# between units so the OS reclaims host heap. Recipes must re-invoke until exit 0
# (or a hard failure). Usage inside a recipe (same cwd as silica.config):
#   $(RUN_SILICA_COMPILER)
define RUN_SILICA_COMPILER_WITH
	rm -f silica.compile.inprogress silica.compile.crashed; \
	while true; do \
		$(1); \
		ec=$$?; \
		if [ $$ec -eq 0 ]; then break; fi; \
		if [ $$ec -eq 75 ] || [ $$ec -eq 76 ]; then \
			echo "  (reclaiming memory; continuing next unit)"; \
			continue; \
		fi; \
		exit $$ec; \
	done
endef

define RUN_SILICA_COMPILER
	$(call RUN_SILICA_COMPILER_WITH,"$(SILICA_COMPILER)")
endef
