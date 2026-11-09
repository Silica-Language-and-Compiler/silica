# project_makefiles/platform/platforms.mk -- the one platform name table.
#
# Two axes, kept separate everywhere (src/Makefile, install_compiler.bash):
#
#   emit target    what a compiler generates code FOR:   emitter/<target>/, silica.target
#   host platform  where a compiler binary RUNS:         binaries/silica-NNNNNN-<platform>
#
# One row per (uname -s, uname -m) host. A host's default emit target is the one whose code
# runs on that host; a board target (ESP32-S3_raw) has no host row, only an emit-target row.
#
# Consumers (see platforms.patch beside this file for the proposed rewiring; nothing includes
# this file yet):
#   src/emit_target.mk         TARGET_CANDIDATES := $(SILICA_HOST_EMIT_TARGET)
#   trials/silica_compiler.mk           SILICA_HOST_EMIT_TARGET, ASCOMP_EXT, platform fragment
#   binaries/install_compiler.bash      platform="$(make -s -f .../platforms.mk host-platform)"
#   binaries/update_silica_compiler_link.bash   CANONICAL_PLATFORMS from `make -s ... platforms`
#
# Written for GNU make 3.81 (the macOS make): no $(file), no !=, no .RECIPEPREFIX.

SILICA_PLATFORMS_MK_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# uname_s:uname_m:emit_target:host_platform     ("-" = no emitter for that host yet)
SILICA_HOST_ROWS := \
	Darwin:arm64:apple_silicon_mac:macos-applesilicon \
	Darwin:x86_64:-:macos-x86_64 \
	Linux:aarch64:linux_aarch64:linux-aarch64 \
	Linux:arm64:linux_aarch64:linux-aarch64 \
	Linux:x86_64:linux_x86_64:linux-x86_64

# emit_target:host_platform_that_runs_its_output    ("-" = a board, nothing hosts it)
SILICA_TARGET_ROWS := \
	apple_silicon_mac:macos-applesilicon \
	linux_aarch64:linux-aarch64 \
	linux_x86_64:linux-x86_64 \
	ESP32-S3_raw:- \
	STM32-L476RG_raw:-

# emit_target:golden_name    the name a target's per-target trial goldens carry, <stem>.<name>.ascomp /
# .scout / .golden_fail (trials/silica_compiler.mk ASCOMP_EXT), when it is not the target's own name:
# the ST NUCLEO-L476RG board target records its assembly goldens as <stem>.st_nucleo.ascomp
# (Lee, 2026-11-07). A target without a row uses its emit-target name, as before.
SILICA_GOLDEN_NAME_ROWS := \
	STM32-L476RG_raw:st_nucleo

# $(call silica_golden_name_for_target,<emit target>) -> the golden name (the target itself by default).
silica_golden_name_for_target = $(or $(word 2,$(subst :, ,$(firstword $(filter $(1):%,$(SILICA_GOLDEN_NAME_ROWS))))),$(1))

SILICA_EMIT_TARGETS := $(foreach r,$(SILICA_TARGET_ROWS),$(word 1,$(subst :, ,$(r))))
SILICA_HOST_PLATFORMS := $(sort $(foreach r,$(SILICA_HOST_ROWS),$(word 4,$(subst :, ,$(r)))))

# $(call silica_platform_for_target,<emit target>) -> host platform id, or "-" for a board.
silica_platform_for_target = $(word 2,$(subst :, ,$(firstword $(filter $(1):%,$(SILICA_TARGET_ROWS)))))

# $(call silica_target_for_platform,<host platform>) -> emit target, or "-" when none exists.
silica_target_for_platform = $(word 1,$(subst :, ,$(firstword $(filter %:$(1),$(SILICA_TARGET_ROWS)))))

# Host detection. SILICA_HOST_UNAME_S / _M may be preset (tests, cross checks).
SILICA_HOST_UNAME_S ?= $(shell uname -s 2>/dev/null)
SILICA_HOST_UNAME_M ?= $(shell uname -m 2>/dev/null)
_silica_host_row := $(firstword $(filter $(SILICA_HOST_UNAME_S):$(SILICA_HOST_UNAME_M):%,$(SILICA_HOST_ROWS)))
SILICA_HOST_EMIT_TARGET := $(filter-out -,$(word 3,$(subst :, ,$(_silica_host_row))))
SILICA_HOST_PLATFORM := $(word 4,$(subst :, ,$(_silica_host_row)))

# The toolchain fragment for an emit target's code: <this dir>/<emit target>.mk (project builds)
# and trials/platform/<emit target>.mk (trials). Only the trials fragments exist today.
SILICA_HOST_PLATFORM_FRAGMENT := $(if $(SILICA_HOST_EMIT_TARGET),$(SILICA_PLATFORMS_MK_DIR)$(SILICA_HOST_EMIT_TARGET).mk,)

# Shell consumers (bash cannot include a makefile):
#   make -s -f project_makefiles/platform/platforms.mk host-platform      -> linux-x86_64
#   make -s -f project_makefiles/platform/platforms.mk host-emit-target   -> linux_x86_64
#   make -s -f project_makefiles/platform/platforms.mk platforms          -> one id per line
#   make -s -f project_makefiles/platform/platforms.mk emit-targets       -> one target per line
#   make -s -f project_makefiles/platform/platforms.mk platform-for-target TARGET=linux_x86_64
#   make -s -f project_makefiles/platform/platforms.mk golden-name-for-target TARGET=STM32-L476RG_raw -> st_nucleo
.PHONY: host-platform host-emit-target platforms emit-targets platform-for-target golden-name-for-target
host-platform:
	@printf '%s\n' '$(SILICA_HOST_PLATFORM)'
host-emit-target:
	@printf '%s\n' '$(SILICA_HOST_EMIT_TARGET)'
platforms:
	@printf '%s\n' $(SILICA_HOST_PLATFORMS)
emit-targets:
	@printf '%s\n' $(SILICA_EMIT_TARGETS)
platform-for-target:
	@printf '%s\n' '$(call silica_platform_for_target,$(TARGET))'
golden-name-for-target:
	@printf '%s\n' '$(call silica_golden_name_for_target,$(TARGET))'
