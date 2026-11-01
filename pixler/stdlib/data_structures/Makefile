# stdlib/data_structures — compiler-private representation cores (Layer 2+).
# Batch-build all modules listed in silica.config.

SILICA_COMPILER_SRC := ../../src
SILICA_COMPILER := $(SILICA_COMPILER_SRC)/silica-compiler

WBT_CORE_FILES := \
	wbt_set.silica \
	wbt_map.silica

# §15 skew binary random-access list: leaves, then thin dispatchers, then the facade.
SKEW_RAL_FILES := \
	skew_ral_weights.silica \
	skew_ral_node.silica \
	skew_ral_tree_read.silica \
	skew_ral_tree_write.silica \
	skew_ral_forest.silica \
	skew_ral_index.silica \
	skew_ral_traverse.silica \
	skew_ral_build.silica \
	skew_ral_validate.silica \
	skew_ral_dispatch_access.silica \
	skew_ral_dispatch_bulk.silica \
	skew_ral.silica

# §16 Brodal–Okasaki queue: leaves, then thin dispatchers, then the facade.
BRODAL_OKASAKI_FILES := \
	brodal_okasaki_node.silica \
	brodal_okasaki_compare.silica \
	brodal_okasaki_link.silica \
	brodal_okasaki_forest.silica \
	brodal_okasaki_extract.silica \
	brodal_okasaki_boot.silica \
	brodal_okasaki_validate.silica \
	brodal_okasaki_dispatch_core.silica \
	brodal_okasaki_dispatch_bulk.silica \
	brodal_okasaki.silica

.PHONY: all clean silica.config

ifdef QUIET
  ECHO := @true
else
  ECHO := @echo
endif

silica.config:
	@printf '%s\n' $(WBT_CORE_FILES) $(SKEW_RAL_FILES) $(BRODAL_OKASAKI_FILES) > silica.config

all: silica.config
	@if [ ! -x "$(SILICA_COMPILER)" ]; then \
		echo "FAIL: build silica-compiler: make -C $(SILICA_COMPILER_SRC)"; \
		exit 1; \
	fi
	@$(ECHO) "Compiling stdlib/data_structures..."
	@cd "$(dir $(abspath $(lastword $(MAKEFILE_LIST))))" && "$(SILICA_COMPILER)"
	@touch "$(dir $(abspath $(lastword $(MAKEFILE_LIST))))/.stdlib-built"

clean:
	@cd "$(dir $(abspath $(lastword $(MAKEFILE_LIST))))" && rm -f *.sams lib/*.sams *.o lib/*.o silica.config .stdlib-built

.DEFAULT_GOAL := all
