# Not an integrate sub-suite: these programs are accepted by the shared compiler and refused by the
# STM32-L476RG_raw emitter with an assembler `.error` line, which surfaces when the .sams is assembled, not in the
# compiler's output (compile exits 0, "Compilation complete."). The board driver skips directories with a
# Makefile. `make check SILICA_COMPILER=<board compiler>` compiles the programs and expects every .sams to carry
# the memory-space .error line (see README.md); the check runs by hand, it is not part of integrate.
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../../silica_compiler.mk

.PHONY: all compile check integrate integrate-run clean help

all: help

silica.config:
	@cd "$(THIS_DIR)" && { \
		find "$$PWD" -maxdepth 1 -type f -name '*.silica' | sed "s|^$$PWD/||" | LC_ALL=C sort; \
	} > silica.config && $(TRIAL_SUPPORT_CONFIG)

compile: clean silica.config
	@cd "$(THIS_DIR)" && $(RUN_SILICA_COMPILER)
	@echo "grep '\\.error' *.sams to see the refusals"

# Each refuse_*.sams must contain an .error line naming the space and "is not available on NUCLEO-L476RG";
# the trial-support .sams (.trial_stdlib/) must contain none. Prints one line per program.
check: compile
	@cd "$(THIS_DIR)" && bad=0; for s in refuse_*.silica; do b=$${s%.silica}; \
		if grep -q "^\\.error \"memory space '.*' is not available on NUCLEO-L476RG; this board provides: " $$b.sams; then \
			echo "refused: $$b"; grep '^\.error' $$b.sams | sort -u; \
		else echo "NOT refused: $$b"; bad=1; fi; done; \
	if grep -l '^\.error' .trial_stdlib/*.sams 2>/dev/null; then echo "unexpected .error in trial support"; bad=1; fi; \
	exit $$bad

integrate-run:
	@echo "refusals/: nothing to integrate (assembler refusals, see README.md)"; printf '%d %d\n' 0 0 > "$(THIS_DIR).integrate_counts"

clean:
	@rm -rf "$(THIS_DIR)"*.sams "$(THIS_DIR)"*.iface "$(THIS_DIR)silica.config" "$(THIS_DIR).integrate_counts" "$(THIS_DIR)"__silica_runtime.sams "$(THIS_DIR)"silica.compile.order "$(THIS_DIR)"silica.needs_runtime "$(THIS_DIR)"silica.link "$(THIS_DIR).trial_stdlib"

help:
	@echo "refusals: make check SILICA_COMPILER=<board compiler>  (or make compile, then grep .error *.sams)"
