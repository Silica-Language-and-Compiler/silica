# Shared emit-target selection for src.
# Include after setting THIS_DIR to the src root (trailing slash).
#
# TARGET selects which emitter/<TARGET>/ tree is baked into silica-compiler
# and is written to silica.target as the project's emit_target declaration.
# This is an emit / code-generation backend, not a cross-compile CLI flag
# inside an already-built binary (single emitter_core per binary today).

EMITTER_ROOT := $(THIS_DIR)emitter

# Discover allowable emit targets from emitter/*/ directory names only.
# (macOS / GNU Make wildcard can also match plain files like Makefile.)
# Names must be simple identifiers: letters, digits, underscore, hyphen (ESP32-S3_raw).
ALLOWED_TARGETS := $(shell find "$(EMITTER_ROOT)" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | grep -E '^[A-Za-z0-9_-]+$$' | LC_ALL=C sort -u)

HOST_UNAME_S := $(shell uname -s 2>/dev/null)
HOST_UNAME_M := $(shell uname -m 2>/dev/null)

# The emit target of the current host platform. Candidates are tried in order against
# directories that actually exist under emitter/. Computed whether or not TARGET is given:
# the Makefile's publish step compares TARGET with it (a host build installs as the selfhost,
# any other target as its own kind -- see install_compiler.bash).
# The host default comes from the one platform table (project_makefiles/platform/platforms.mk):
# uname -s / uname -m -> SILICA_HOST_EMIT_TARGET (empty when this host has no emitter yet).
include $(THIS_DIR)../../project_makefiles/platform/platforms.mk
TARGET_CANDIDATES := $(SILICA_HOST_EMIT_TARGET)
HOST_DEFAULT_TARGET := $(firstword $(filter $(TARGET_CANDIDATES),$(ALLOWED_TARGETS)))
# Default TARGET to the current host platform when the user does not pass
# TARGET=... on the command line or via the environment.
ifndef TARGET
  # Ask which emitter/<name>/ to build when more than one exists and a terminal is
  # attached (choose_emit_target.sh prints the host default without asking otherwise).
  # Goals that need no target (help, clean) never prompt; SILICA_TARGET_PROMPT=0 forces
  # the silent host default, e.g. for scripts and CI.
  TARGET_PROMPT_GOALS := $(filter-out help clean,$(if $(MAKECMDGOALS),$(MAKECMDGOALS),build))
  ifeq ($(SILICA_TARGET_PROMPT),0)
    TARGET := $(HOST_DEFAULT_TARGET)
  else ifeq ($(TARGET_PROMPT_GOALS),)
    TARGET := $(HOST_DEFAULT_TARGET)
  else ifeq ($(words $(ALLOWED_TARGETS)),1)
    TARGET := $(HOST_DEFAULT_TARGET)
  else
    TARGET := $(shell sh "$(THIS_DIR)choose_emit_target.sh" "$(HOST_DEFAULT_TARGET)" $(ALLOWED_TARGETS))
    TARGET_CHOSEN_BY_PROMPT := $(if $(filter $(TARGET),$(HOST_DEFAULT_TARGET)),,yes)
  endif
endif

# Sub-makes (objects fan-out, emitter/Makefile) must not ask again: hand the choice down.
export TARGET

# Per-target build directory (trailing slash, like THIS_DIR): compiler/build/<TARGET>/. Every
# intermediate output of a build for TARGET lives there (see the header of Makefile). It is outside
# src/ on purpose, so no scan of the source tree ever sees a build product.
BUILD_ROOT := $(abspath $(THIS_DIR)../build)
BUILD_DIR := $(BUILD_ROOT)/$(TARGET)/
TARGET_FILE := $(BUILD_DIR)silica.target

# user: given on the command line or in the environment; prompt: picked from the menu;
# host-default: left to host detection (or the menu accepted the default).
TARGET_ORIGIN := $(if $(filter command line environment,$(origin TARGET)),user,$(if $(TARGET_CHOSEN_BY_PROMPT),prompt,host-default))

.PHONY: check-target

check-target:
	@if [ -z "$(TARGET)" ]; then \
		echo "FAIL: could not detect host emit target (uname -s='$(HOST_UNAME_S)' -m='$(HOST_UNAME_M)')." >&2; \
		echo "Pass an explicit emit target, e.g.: make TARGET=apple_silicon_mac" >&2; \
		echo "Allowable targets (emitter/*/ ):" >&2; \
		for t in $(ALLOWED_TARGETS); do echo "  - $$t" >&2; done; \
		if [ -z "$(ALLOWED_TARGETS)" ]; then echo "  (none found under emitter/)" >&2; fi; \
		exit 1; \
	fi
	@echo "$(TARGET)" | grep -Eq '^[A-Za-z0-9_-]+$$' || { \
		echo "FAIL: invalid emit target name '$(TARGET)' (use letters, digits, underscore, hyphen only)." >&2; \
		exit 1; \
	}
	@if [ ! -d "$(EMITTER_ROOT)/$(TARGET)" ]; then \
		echo "FAIL: unknown emit target '$(TARGET)' (no directory emitter/$(TARGET)/)." >&2; \
		echo "Allowable targets:" >&2; \
		for t in $(ALLOWED_TARGETS); do echo "  - $$t" >&2; done; \
		if [ -z "$(ALLOWED_TARGETS)" ]; then echo "  (none found under emitter/)" >&2; fi; \
		echo "Example: make TARGET=apple_silicon_mac" >&2; \
		exit 1; \
	fi
	@if [ ! -f "$(EMITTER_ROOT)/$(TARGET)/emitter_core.silica" ]; then \
		echo "FAIL: emitter/$(TARGET)/ is missing emitter_core.silica." >&2; \
		exit 1; \
	fi

# Project-level emit declaration (real file, in the target's build directory, where the seed reads
# it from its working directory). Recipe may run when check-target is asked for as a prereq path
# elsewhere; only bump mtime when TARGET changes.
$(TARGET_FILE): check-target
	@mkdir -p "$(BUILD_DIR)"
	@tmp="$(TARGET_FILE).tmp"; \
	printf 'emit_target: %s\n' '$(TARGET)' > "$$tmp"; \
	if ! cmp -s "$$tmp" "$(TARGET_FILE)" 2>/dev/null; then \
		mv "$$tmp" "$(TARGET_FILE)"; \
		echo "Wrote $(TARGET_FILE) (emit_target: $(TARGET); source: $(TARGET_ORIGIN))"; \
	else \
		rm -f "$$tmp"; \
	fi
