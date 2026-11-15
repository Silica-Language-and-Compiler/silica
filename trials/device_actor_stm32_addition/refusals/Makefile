# Not an integrate sub-suite: these programs are accepted by the shared compiler and refused by the
# STM32-L476RG_raw emitter with an assembler `.error` line, which surfaces when the image is built, not in
# the compiler's output. The board driver skips directories with a Makefile; this one only offers
# `make compile` for looking at the .sams by hand with the board compiler.
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../../silica_compiler.mk

.PHONY: all compile integrate integrate-run clean help

all: help

silica.config:
	@cd "$(THIS_DIR)" && { \
		echo "../../../compiler/stdlib/DeviceDescription.silica"; \
		echo "../../../compiler/stdlib/Register32.silica"; \
		echo "../../../compiler/stdlib/Register64.silica"; \
		echo "device_map_outside_window.silica"; \
		echo "device_peek_register64.silica"; \
	} > silica.config

compile: clean silica.config
	@cd "$(THIS_DIR)" && $(RUN_SILICA_COMPILER)
	@echo "grep '\\.error' *.sams to see the refusals"

integrate-run:
	@echo "refusals/: nothing to integrate (assembler refusals, see README.md)"; printf '%d %d\n' 0 0 > "$(THIS_DIR).integrate_counts"

clean:
	@rm -f "$(THIS_DIR)"*.sams "$(THIS_DIR)"*.iface "$(THIS_DIR)silica.config" "$(THIS_DIR).integrate_counts" "$(THIS_DIR)"__silica_runtime.sams "$(THIS_DIR)"silica.compile.order "$(THIS_DIR)"silica.needs_runtime "$(THIS_DIR)"silica.link

help:
	@echo "refusals: make compile SILICA_COMPILER=<board compiler>, then grep .error *.sams"
