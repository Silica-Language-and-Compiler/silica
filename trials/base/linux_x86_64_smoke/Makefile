# trials/base/linux_x86_64_smoke -- the plan's Step 2.3 hand-written smoke trial.
#
# There is no Silica source here and no compiler is run: hello.sams is hand-written x86-64 text
# in the form the linux_x86_64 backend will emit. `make integrate` assembles it, links it, runs it
# and compares its output (plus exit status, trial convention) with hello.scout, using only
# clang or cc and make. It is deliberately standalone: it does not include silica_compiler.mk,
# because that wrapper insists on binaries/silica-compiler, which does not exist on an x86-64
# host until the port has produced one.
#
# It is also outside the automatic trial tree on purpose: trials/Makefile runs the immediate
# children of trials/ and base/ discovers *.silica files, so this directory is inert for both.
#
#   make integrate                       # on a Linux x86-64 host
#   make integrate PLATFORM=linux_x86_64 # explicit; any other host prints SKIP and exits 0
#   make clean
#
# Run on nix 2026-09-18:
#   Assembling hello.sams -> hello.o (clang)
#   Linking hello (clang -no-pie -rdynamic -lpthread)
#   Running ./hello
#   ✅✅ linux_x86_64_smoke/hello output matches .scout

THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
MSG_PREFIX := linux_x86_64_smoke/

HOST_UNAME_S := $(shell uname -s 2>/dev/null)
HOST_UNAME_M := $(shell uname -m 2>/dev/null)
ifeq ($(HOST_UNAME_S)/$(HOST_UNAME_M),Linux/x86_64)
PLATFORM ?= linux_x86_64
else
PLATFORM ?=
endif

ifeq ($(PLATFORM),linux_x86_64)
include $(THIS_DIR)../../platform/linux_x86_64.mk
endif

.DEFAULT_GOAL := all
.PHONY: all assembly objects executables run integrate clean help

all: executables

# Stage 1 (assembly) is the hand-written file itself.
assembly:
	@test -f "$(THIS_DIR)hello.sams" || { echo "❌❌ $(MSG_PREFIX)hello.sams missing"; exit 1; }

objects: assembly
	@echo "Assembling hello.sams -> hello.o ($(ASSEMBLER))"
	@cd "$(THIS_DIR)" && $(ASSEMBLER) $(ASFLAGS) hello.sams -o hello.o

executables: objects
	@echo "Linking hello ($(LINKER) $(LDFLAGS))"
	@cd "$(THIS_DIR)" && $(LINKER) hello.o $(LDFLAGS) -o hello

run: executables
	@cd "$(THIS_DIR)" && ./hello

# Output then exit status, the same shape INTEGRATE_RUN_TRIAL writes for every trial.
integrate:
ifeq ($(PLATFORM),linux_x86_64)
	@$(MAKE) --no-print-directory -f "$(THIS_DIR)Makefile" clean
	@rm -f "$(THIS_DIR).integrate_counts"; \
	cd "$(THIS_DIR)" && \
	if ! $(MAKE) --no-print-directory -f "$(THIS_DIR)Makefile" executables; then \
		echo "❌❌ $(MSG_PREFIX)hello assemble or link failed"; \
		printf '%d %d\n' 0 1 > .integrate_counts; exit 1; \
	fi; \
	echo "Running ./hello"; \
	./hello > hello$(SOUT_EXT) 2>&1; rc=$$?; printf '%s\n' "$$rc" >> hello$(SOUT_EXT); \
	if diff -Bw -q hello$(SOUT_EXT) hello.scout > /dev/null 2>&1; then \
		echo "✅✅ $(MSG_PREFIX)hello output matches .scout"; \
		printf '%d %d\n' 1 0 > .integrate_counts; \
	else \
		echo "❌❌ $(MSG_PREFIX)hello .sout differs from .scout"; \
		diff -Bw hello$(SOUT_EXT) hello.scout || true; \
		printf '%d %d\n' 0 1 > .integrate_counts; exit 1; \
	fi
else
	@echo "SKIP: $(MSG_PREFIX)hello.sams is Linux x86-64 ELF text; this host is $(HOST_UNAME_S)/$(HOST_UNAME_M) (run it on nix: rsync this directory and trials/platform/ there, then make integrate)"
endif

clean:
	@cd "$(THIS_DIR)" && rm -f hello.o hello hello$(SOUT_EXT) .integrate_counts
	@echo "✅ $(MSG_PREFIX)Clean complete"

help:
	@echo "linux_x86_64_smoke -- hand-written x86-64 smoke trial (no compiler involved)"
	@echo "  make integrate   assemble, link, run, diff against hello.scout (Linux x86-64 only)"
	@echo "  make run         build and run"
	@echo "  make clean"
