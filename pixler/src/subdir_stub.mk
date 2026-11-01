# Shared stub for src leaf directories (lexer, parser, …).
# Set COMPONENT_NAME before including. Emit TARGET is owned by the parent.

.DEFAULT_GOAL := help
.PHONY: all clean help --help

all: help
	@echo ""
	@echo "$(COMPONENT_NAME): compiled by parent src/Makefile (config-driven)."
	@echo "Run: make -C .. assembly"
	@echo "     make -C .. build [TARGET=<emit-target>]"

clean:
	@find . \( -name '*.ll' -o -name '*.bc' -o -name '*.o' -o -name '*.sams' \) -delete 2>/dev/null || true
	@echo "$(COMPONENT_NAME) clean complete"

--help: help
help:
	@echo "$(COMPONENT_NAME)/ — sources built by parent src/Makefile"
	@echo ""
	@echo "Usage:"
	@echo "  make -C .. help"
	@echo "  make -C .. build [TARGET=<emit-target>]"
	@echo "  make -C $(COMPONENT_NAME) help"
	@echo "  make -C $(COMPONENT_NAME) -- --help"
	@echo ""
	@echo "These modules are listed in ../silica.config.compiler and compiled by"
	@echo "the parent seed batch. Emit target (TARGET / silica.target) and"
	@echo "emitter/<TARGET>/ selection are configured only at the parent:"
	@echo "  make -C .. help"
