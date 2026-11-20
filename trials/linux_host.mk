# Linux host overrides for the trials harness (included from silica_compiler.mk).
#
# The per-trial makefiles are written for macOS: clang with -mmacosx-version-min, Apple ld flags,
# and BSD stat. `override` is required because those makefiles assign the same variables *after*
# they include silica_compiler.mk, so a plain assignment here would be discarded.
ifeq ($(shell uname -s),Linux)
  override ASSEMBLER := cc
  override ASFLAGS_macos :=
  override MACOS_SDK :=
  override LINKER := cc
  override RUST_LLD := /nonexistent
  # ordered_data_structures/leaf.mk probes its own rust-lld and links it -flavor darwin.
  override LEAF_RUST_LLD := /nonexistent
  # crt1.o calls main, so no -e main. -no-pie because emitted data tables hold absolute addresses.
  # -rdynamic: the actor failure banner resolves the running behavior's name with dladdr,
  # and glibc's dladdr only sees .dynsym. Without it every banner says <unknown behavior>.
  override LDFLAGS_clang := -no-pie -rdynamic -lpthread
  override LDFLAGS_rust-lld :=
endif
