# Build prebuilt C wrapper static libraries for ffi_addition trials.
# Included by ffi_addition/Makefile and common_app.mk (app integrate targets).

include $(dir $(abspath $(lastword $(MAKEFILE_LIST))))fixtures_paths.mk

FFI_CC := clang
FFI_ARCH := arm64
# macOS needs -arch/-mmacosx-version-min; the Linux driver rejects both, and glibc hides
# mkstemp and friends under strict -std=c11 unless _GNU_SOURCE is defined.
ifeq ($(shell uname -s),Darwin)
  FFI_HOST_CFLAGS := -arch $(or $(FFI_ARCH),$(ARCH)) -mmacosx-version-min=$(or $(MACOS_MIN_VERSION),26.0)
else
  FFI_HOST_CFLAGS := -D_GNU_SOURCE
endif
FFI_CFLAGS := -std=c11 -Wall -Wextra -O2 $(FFI_HOST_CFLAGS) \
	-I$(FFI_SHARED_SOURCE)/legacy \
	-I$(FFI_SHARED_SOURCE)/text \
	-I$(FFI_SHARED_SOURCE)/net

FFI_LEGACY_OBJ := $(FFI_BUILD_DIR)/silica_legacy_math.o
FFI_FAULT_OBJ := $(FFI_BUILD_DIR)/silica_ffi_fault.o
# Entry point the supervised-failure trials call: it faults on purpose so the supervisor
# has something to consume and restart. Part of the legacy archive because the wrapper
# meta declares it there, so a new trial of that shape needs no per-trial C build.
FFI_SUPERVISOR_FAULT_OBJ := $(FFI_BUILD_DIR)/silica_supervisor_trial_guarded_fault.o
FFI_TEXT_OBJ := $(FFI_BUILD_DIR)/silica_text.o
FFI_NET_OBJ := $(FFI_BUILD_DIR)/silica_net.o
FFI_ABI_TYPES_OBJ := $(FFI_BUILD_DIR)/silica_abi_types.o
# The language's socket wrappers (compiler/stdlib/net, transport_serialization_design.md §6.3): the
# hosted carriers' Fifi library, built here so the transport app trials link it like a fixture.
FFI_STDLIB_NET_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../compiler/stdlib/net)
FFI_SOCKETS_OBJ := $(FFI_BUILD_DIR)/silica_sockets.o

FFI_LEGACY_ARCHIVE := $(FFI_LIB_DIR)/libsilica_legacy_math.a
FFI_TEXT_ARCHIVE := $(FFI_LIB_DIR)/libsilica_text.a
FFI_NET_ARCHIVE := $(FFI_LIB_DIR)/libsilica_net.a
FFI_ABI_TYPES_ARCHIVE := $(FFI_LIB_DIR)/libsilica_abi_types.a
FFI_SOCKETS_ARCHIVE := $(FFI_LIB_DIR)/libsilica_sockets.a

FFI_WRAPPER_ARCHIVES := $(FFI_LEGACY_ARCHIVE) $(FFI_TEXT_ARCHIVE) $(FFI_NET_ARCHIVE) $(FFI_ABI_TYPES_ARCHIVE) $(FFI_SOCKETS_ARCHIVE)

.PHONY: ffi-wrapper-archives

# Every trial directory runs this target, in parallel under JOBS: the link is made only when absent
# or wrong, and a loss of the race (ln -sfn is an unlink then a symlink) is accepted when the link
# stands at the end.
ffi-wrapper-archives: $(FFI_WRAPPER_ARCHIVES)
	@[ "$$(readlink "$(FFI_SOURCE_VIEW)/sockets")" = "$(FFI_STDLIB_NET_DIR)" ] || ln -sfn "$(FFI_STDLIB_NET_DIR)" "$(FFI_SOURCE_VIEW)/sockets" 2>/dev/null || test -L "$(FFI_SOURCE_VIEW)/sockets"
	@test -f "$(FFI_LEGACY_ARCHIVE)" && test -f "$(FFI_TEXT_ARCHIVE)" && test -f "$(FFI_NET_ARCHIVE)" && test -f "$(FFI_ABI_TYPES_ARCHIVE)" && test -f "$(FFI_SOCKETS_ARCHIVE)"

$(FFI_BUILD_DIR):
	@mkdir -p $(FFI_BUILD_DIR)

# The platform's view of dangerous_exposure_source: its own lib/ plus links to the shared sources.
# ln -sfn, never ln -sf: BSD ln follows an existing link to a directory and would write the new link
# inside the shared fixtures.
$(FFI_LIB_DIR):
	@mkdir -p $(FFI_LIB_DIR)
	@for d in abi legacy net other text; do ln -sfn ../../../dangerous_exposure_source/$$d "$(FFI_SOURCE_VIEW)/$$d"; done
	@ln -sfn "$(FFI_STDLIB_NET_DIR)" "$(FFI_SOURCE_VIEW)/sockets"

$(FFI_LEGACY_OBJ): $(FFI_SRC_DIR)/silica_legacy_math.c | $(FFI_BUILD_DIR)
	$(FFI_CC) $(FFI_CFLAGS) -c $< -o $@

$(FFI_TEXT_OBJ): $(FFI_SRC_DIR)/silica_text.c | $(FFI_BUILD_DIR)
	$(FFI_CC) $(FFI_CFLAGS) -c $< -o $@

$(FFI_NET_OBJ): $(FFI_SRC_DIR)/silica_net.c | $(FFI_BUILD_DIR)
	$(FFI_CC) $(FFI_CFLAGS) -c $< -o $@

$(FFI_ABI_TYPES_OBJ): $(FFI_SRC_DIR)/silica_abi_types.c | $(FFI_BUILD_DIR)
	$(FFI_CC) $(FFI_CFLAGS) -c $< -o $@

$(FFI_FAULT_OBJ): $(FFI_SRC_DIR)/silica_ffi_fault.c | $(FFI_BUILD_DIR)
	$(FFI_CC) $(FFI_CFLAGS) -c $< -o $@

$(FFI_SUPERVISOR_FAULT_OBJ): $(FFI_SRC_DIR)/silica_supervisor_trial_guarded_fault.c | $(FFI_BUILD_DIR)
	$(FFI_CC) $(FFI_CFLAGS) -c $< -o $@

$(FFI_LEGACY_ARCHIVE): $(FFI_LEGACY_OBJ) $(FFI_FAULT_OBJ) $(FFI_SUPERVISOR_FAULT_OBJ) | $(FFI_LIB_DIR)
	ar rcs $@ $^

$(FFI_TEXT_ARCHIVE): $(FFI_TEXT_OBJ) | $(FFI_LIB_DIR)
	ar rcs $@ $^

$(FFI_NET_ARCHIVE): $(FFI_NET_OBJ) | $(FFI_LIB_DIR)
	ar rcs $@ $^

$(FFI_ABI_TYPES_ARCHIVE): $(FFI_ABI_TYPES_OBJ) | $(FFI_LIB_DIR)
	ar rcs $@ $^

$(FFI_SOCKETS_OBJ): $(FFI_STDLIB_NET_DIR)/silica_sockets.c | $(FFI_BUILD_DIR)
	$(FFI_CC) $(FFI_CFLAGS) -c $< -o $@

$(FFI_SOCKETS_ARCHIVE): $(FFI_SOCKETS_OBJ) | $(FFI_LIB_DIR)
	ar rcs $@ $^
