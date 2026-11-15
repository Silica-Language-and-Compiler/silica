# ffi_addition fixtures for the STM32-L476RG_raw board target (Cortex-M4, bare metal, no C library);
# fixtures_board.mk's counterpart (the board driver uses fixtures_board_<target>.mk when it exists).
#
#   make -f trials/ffi_addition/fixtures_board_STM32-L476RG_raw.mk        build the four archives and the platform view
#   make -f trials/ffi_addition/fixtures_board_STM32-L476RG_raw.mk clean
#
# Standalone on purpose (it does not include silica_compiler.mk): the board driver
# (trials/targets/board_suite.sh) runs it once per run before compiling the ffi_addition apps.
# The tree it produces is the board's view of dangerous_exposure_source, the same shape fixtures.mk
# makes for the hosts, so every silica.link "archive:" line and the compiler's existence check
# (dangerous_exposure_source/lib/lib<name>.a) work unchanged:
#
#   fixtures/build/STM32-L476RG_raw/obj/*.o
#   fixtures/build/STM32-L476RG_raw/dangerous_exposure_source/lib/*.a   Thumb-2 archives
#   fixtures/build/STM32-L476RG_raw/dangerous_exposure_source/{abi,legacy,net,other,text}   symlinks to the shared metas
#
# Sources: fixtures/board/STM32-L476RG_raw/src/ (board versions) plus the host sources that are plain
# freestanding C (silica_legacy_math.c, silica_supervisor_trial_guarded_fault.c, silica_abi_types.c,
# silica_net.c). Only <stdint.h>/<stddef.h>/<stdbool.h> are used; memcpy and friends come from
# board/runtime/rt_support.S. Flags are build_image.sh's CFLAGS (softfp, -ffixed-r9: see there).

SILICA_HOST_EMIT_TARGET := STM32-L476RG_raw
include $(dir $(abspath $(lastword $(MAKEFILE_LIST))))fixtures_paths.mk

ARM_BIN ?= $(patsubst %/,%,$(dir $(shell command -v arm-none-eabi-gcc 2>/dev/null || echo /opt/homebrew/bin/arm-none-eabi-gcc)))
BOARD_CC := $(ARM_BIN)/arm-none-eabi-gcc
BOARD_AR := $(ARM_BIN)/arm-none-eabi-ar
BOARD_CFLAGS_FIXTURE := -c -mcpu=cortex-m4 -mthumb -mfpu=fpv4-sp-d16 -mfloat-abi=softfp -Os -ffreestanding -fno-builtin -ffixed-r9 -ffunction-sections -fdata-sections -Wall -Wextra

BOARD_SRC := $(FFI_FIXTURES_DIR)/board/STM32-L476RG_raw/src
HOST_SRC := $(FFI_SRC_DIR)
OBJ := $(FFI_BUILD_DIR)
LIB := $(FFI_LIB_DIR)

LEGACY_AR := $(LIB)/libsilica_legacy_math.a
TEXT_AR := $(LIB)/libsilica_text.a
ABI_AR := $(LIB)/libsilica_abi_types.a
NET_AR := $(LIB)/libsilica_net.a

.PHONY: all clean
all: $(LEGACY_AR) $(TEXT_AR) $(ABI_AR) $(NET_AR)

$(OBJ) $(LIB):
	@mkdir -p $@

# The platform view's links to the shared .meta/.h directories. ln -sfn, never ln -sf (BSD ln follows
# an existing link to a directory and would write the new link inside the shared fixtures).
$(FFI_SOURCE_VIEW)/.links: | $(LIB)
	@for d in abi legacy net other text; do ln -sfn ../../../dangerous_exposure_source/$$d "$(FFI_SOURCE_VIEW)/$$d"; done
	@touch $@

$(OBJ)/silica_legacy_math.o: $(HOST_SRC)/silica_legacy_math.c | $(OBJ)
	$(BOARD_CC) $(BOARD_CFLAGS_FIXTURE) $< -o $@
$(OBJ)/silica_supervisor_trial_guarded_fault.o: $(HOST_SRC)/silica_supervisor_trial_guarded_fault.c | $(OBJ)
	$(BOARD_CC) $(BOARD_CFLAGS_FIXTURE) $< -o $@
$(OBJ)/silica_ffi_fault_board.o: $(BOARD_SRC)/silica_ffi_fault_board.c | $(OBJ)
	$(BOARD_CC) $(BOARD_CFLAGS_FIXTURE) $< -o $@
$(OBJ)/silica_text_board.o: $(BOARD_SRC)/silica_text_board.c | $(OBJ)
	$(BOARD_CC) $(BOARD_CFLAGS_FIXTURE) $< -o $@
$(OBJ)/silica_abi_types.o: $(HOST_SRC)/silica_abi_types.c | $(OBJ)
	$(BOARD_CC) $(BOARD_CFLAGS_FIXTURE) $< -o $@
$(OBJ)/silica_net.o: $(HOST_SRC)/silica_net.c | $(OBJ)
	$(BOARD_CC) $(BOARD_CFLAGS_FIXTURE) $< -o $@

$(LEGACY_AR): $(OBJ)/silica_legacy_math.o $(OBJ)/silica_ffi_fault_board.o $(OBJ)/silica_supervisor_trial_guarded_fault.o | $(FFI_SOURCE_VIEW)/.links
	@rm -f $@
	$(BOARD_AR) rcs $@ $^
$(TEXT_AR): $(OBJ)/silica_text_board.o | $(FFI_SOURCE_VIEW)/.links
	@rm -f $@
	$(BOARD_AR) rcs $@ $^
$(ABI_AR): $(OBJ)/silica_abi_types.o | $(FFI_SOURCE_VIEW)/.links
	@rm -f $@
	$(BOARD_AR) rcs $@ $^
$(NET_AR): $(OBJ)/silica_net.o | $(FFI_SOURCE_VIEW)/.links
	@rm -f $@
	$(BOARD_AR) rcs $@ $^

clean:
	@rm -rf "$(FFI_PLATFORM_DIR)"
