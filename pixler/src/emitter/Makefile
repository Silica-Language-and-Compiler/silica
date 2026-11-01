# Emitter sources are compiled by the parent config-driven batch
# (silica.config → seed). TARGET selects which emitter/<TARGET>/ tree
# the parent includes; defaults to the current host platform.

EMITTER_MK_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
THIS_DIR := $(abspath $(EMITTER_MK_DIR)/..)/
include $(THIS_DIR)emit_target.mk

.DEFAULT_GOAL := help
.PHONY: all clean help --help

all: help
	@echo ""
	@echo "Emitter sources are not built here; use the parent Makefile."
	@echo "  make -C .. assembly TARGET=$(TARGET)"
	@echo "  make -C .. build TARGET=$(TARGET)"

clean:
	@find . \( -name '*.ll' -o -name '*.bc' -o -name '*.o' -o -name '*.sams' \) -delete
	@echo "Emitter clean complete (object/assembly artifacts only)."
	@echo "Parent silica.target / silica.config are owned by: make -C .. clean"

--help: help
help:
	@echo "emitter/ — platform emit backends for src"
	@echo ""
	@echo "Usage:"
	@echo "  make -C .. help"
	@echo "  make -C .. build [TARGET=<emit-target>]"
	@echo "  make -C emitter help"
	@echo "  make -C emitter -- --help"
	@echo ""
	@echo "Emit target (TARGET)"
	@echo "  Each subdirectory of emitter/ is one emit backend (e.g. apple_silicon_mac)."
	@echo "  The parent Makefile includes emitter/\$$TARGET/**/*.silica in"
	@echo "  silica.config.compiler and writes ../silica.target."
	@echo "  Default: current host platform when TARGET is unset."
	@echo ""
	@echo "  Host:   $(HOST_UNAME_S) $(HOST_UNAME_M)"
	@echo "  Active: TARGET=$(TARGET)  (source: $(TARGET_ORIGIN))"
	@echo ""
	@echo "  Allowable emit targets:"
	@for t in $(ALLOWED_TARGETS); do \
		if [ "$$t" = "$(TARGET)" ]; then echo "    * $$t  (selected)"; \
		else echo "      $$t"; fi; \
	done
	@if [ -z "$(ALLOWED_TARGETS)" ]; then echo "      (none found)"; fi
	@echo ""
	@echo "  Examples:"
	@echo "    make -C ..                          # host-default TARGET"
	@echo "    make -C .. TARGET=apple_silicon_mac     # explicit backend"
	@echo "    make -C .. all-targets              # build each allowable TARGET"
	@echo ""
	@echo "This directory's Makefile only cleans local .sams/.o artifacts."
	@echo "Full project help: make -C .. help"
