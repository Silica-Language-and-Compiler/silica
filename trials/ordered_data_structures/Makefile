# Phase 1 standard data structures — dependency-ordered trial root (Layer 0 §6.2)
#
# First-time golden capture (after binaries/silica-compiler is available):
#   make record-golden
#
# Build only (default):
#   make
#   make all
#
# Normal integration:
#   make integrate
#
# Each `make all` / `make integrate` / `make record-golden` compiles the shared
# stdlib data structures once into .stdlib_cache/lib/*.o and reuses those
# objects (and their .iface files) for every trial in every leaf.

THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)../silica_compiler.mk
# This suite is memory-bound (every unit compile re-derives its stdlib dependencies):
# a standalone `make integrate` here fans out SDS_JOBS-wide, and the trials root passes
# -j$(SDS_JOBS) so the same cap holds inside the tree-wide run.
INTEGRATE_JOBS := $(SDS_JOBS)

SUB_TRIALS := \
	compiler_substrate \
	wbt_core \
	skew_ral_core \
	brodal_okasaki_core \
	binary_tree_core \
	ordered_collections \
	heap_collections \
	tree_collections \
	search_tree_collections \
	self_host_maps \
	live_graphs \
	graph_live_core \
	graph_csr_core \
	graph_dense_core \
	graph_collections \
	terminal_structures \
	snapshot_graphs \
	cross_representation

STDLIB_SRC := $(abspath $(THIS_DIR)../../compiler/stdlib/data_structures)
SDS_STDLIB_CACHE := $(THIS_DIR).stdlib_cache
SDS_STDLIB_MODULES := wbt_set wbt_map OrderedMap OrderedSet skew_ral_weights skew_ral_node skew_ral_tree_read skew_ral_tree_write skew_ral_forest skew_ral_index skew_ral_traverse skew_ral_build skew_ral_validate skew_ral_dispatch_access skew_ral_dispatch_bulk skew_ral brodal_okasaki_node brodal_okasaki_compare brodal_okasaki_link brodal_okasaki_forest brodal_okasaki_extract brodal_okasaki_boot brodal_okasaki_validate brodal_okasaki_dispatch_core brodal_okasaki_dispatch_bulk brodal_okasaki tree_binary BinaryTree brodal_okasaki_min brodal_okasaki_max brodal_okasaki_priority Heap PriorityQueue tree_rose Tree SearchTree graph_wbt_core graph_wbt_directed graph_wbt_undirected graph_weighted graph_weighted_undirected graph_csr_core graph_csr_directed graph_csr_undirected graph_csr_weighted graph_csr_weighted_undirected graph_dense_core graph_dense_directed graph_dense_undirected graph_dense_weighted graph_dense_weighted_undirected DirectedGraph UndirectedGraph WeightedGraph

ASSEMBLER := clang
MACOS_MIN_VERSION ?= 26.0
ASFLAGS_macos := -mmacosx-version-min=$(MACOS_MIN_VERSION)

# Command-line vars are exported into leaf recipes and compile_per_trial.sh.
SDS_LEAF_MAKEFLAGS = \
	SILICA_COMPILER="$(SILICA_COMPILER)" \
	SDS_STDLIB_CACHE="$(SDS_STDLIB_CACHE)" \
	SDS_STDLIB_MODULES="$(SDS_STDLIB_MODULES)"

.PHONY: all integrate-run sds-leaves record-golden clean help stdlib-objs gate-stdlib $(SUB_TRIALS) $(SUB_TRIALS:%=sds-leaf-%)

.DEFAULT_GOAL := all

# Compile each shared stdlib module once for this all/integrate/record-golden run.
stdlib-objs:
	@echo "=== standard_data_structures: compile stdlib data structures once ==="
	@$(ENSURE_SILICA_COMPILER)
	@rm -rf "$(SDS_STDLIB_CACHE)"
	@mkdir -p "$(SDS_STDLIB_CACHE)/lib"
	@for m in $(SDS_STDLIB_MODULES); do \
		if [ ! -f "$(STDLIB_SRC)/$$m.silica" ]; then \
			echo "FAIL: missing $(STDLIB_SRC)/$$m.silica"; \
			exit 1; \
		fi; \
		: "relative from .stdlib_cache/lib, so the link survives a sync to another host"; \
		ln -sfn "../../../../compiler/stdlib/data_structures/$$m.silica" "$(SDS_STDLIB_CACHE)/lib/$$m.silica"; \
	done
	@{ \
		for m in $(SDS_STDLIB_MODULES); do \
			printf 'lib/%s.silica\n' "$$m"; \
		done; \
	} > "$(SDS_STDLIB_CACHE)/silica.config"
	@cp "$(SDS_STDLIB_CACHE)/silica.config" "$(SDS_STDLIB_CACHE)/silica.compile.order"
	@cd "$(SDS_STDLIB_CACHE)" && $(RUN_SILICA_COMPILER)
	@if [ "$(SILICA_TARGET_IS_HOST)" = 1 ]; then \
		cd "$(SDS_STDLIB_CACHE)" && for sams in lib/*.sams; do \
			[ -f "$$sams" ] || continue; \
			base=$$(basename "$$sams" .sams); \
			echo "Assembling $$sams -> lib/$$base.o"; \
			$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "lib/$$base.o" || exit 1; \
		done; \
	else \
		echo "  $(SILICA_CROSS_NOTE)"; \
	fi
	@missing=0; ext=o; \
	[ "$(SILICA_TARGET_IS_HOST)" = 1 ] || ext=sams; \
	for m in $(SDS_STDLIB_MODULES); do \
		if [ ! -f "$(SDS_STDLIB_CACHE)/lib/$$m.$$ext" ]; then \
			echo "FAIL: stdlib compile did not produce $(SDS_STDLIB_CACHE)/lib/$$m.$$ext"; \
			missing=1; \
		fi; \
	done; \
	[ "$$missing" -eq 0 ]
	@if [ "$(SILICA_TARGET_IS_HOST)" = 1 ]; then \
		echo "✅ standard_data_structures: reusing .stdlib_cache/lib/*.o for every trial"; \
	else \
		echo "✅ standard_data_structures: compiled .stdlib_cache/lib/*.sams for $(SILICA_EMIT_TARGET)"; \
	fi

# Fast assembly-drift report for bringing up a new compiler.
#
# .ascomp is canonical: `integrate` fails on any mismatch, and so does this target.
# It answers the same question far faster and with better triage -- it normalises the
# o<N> label counters and separates code drift from comment drift -- so run it FIRST
# against a new compiler and let the trial fan-out confirm rather than debug.
#
# The four shared stdlib goldens live in stdlib_goldens/ and are symlinked into each
# leaf's lib/, so there is exactly one copy to regenerate.
#
# The four shared stdlib modules are 13,776 lines producing ~779KB of recorded
# assembly, and wbt_map/wbt_set goldens are byte-identical in both leaves that
# carry them -- emission does not depend on the surrounding silica.config. So
# these four units exercise far more of the compiler than any single trial while
# costing a tiny fraction of the 107-trial fan-out.
#
# Run this FIRST against a new compiler; run `integrate` once it passes, so the
# trial fan-out confirms rather than debugs.
#
#   make gate-stdlib
#   make gate-stdlib SILICA_COMPILER=/path/to/self-hosted-compiler
gate-stdlib: stdlib-objs
	@echo "=== standard_data_structures: stdlib golden gate ==="
	@ok=0; ko=0; \
	for m in $(SDS_STDLIB_MODULES); do \
		sams="$(SDS_STDLIB_CACHE)/lib/$$m.sams"; \
		case "$$m" in \
			OrderedMap|OrderedSet) golden="$(THIS_DIR)ordered_collections/lib/$$m$(ASCOMP_EXT)";; \
			skew_ral*) golden="$(THIS_DIR)skew_ral_core/lib/$$m$(ASCOMP_EXT)";; \
			brodal_okasaki_min|brodal_okasaki_max|brodal_okasaki_priority|Heap|PriorityQueue) golden="$(THIS_DIR)heap_collections/lib/$$m$(ASCOMP_EXT)";; \
			brodal_okasaki*) golden="$(THIS_DIR)brodal_okasaki_core/lib/$$m$(ASCOMP_EXT)";; \
			tree_binary|BinaryTree) golden="$(THIS_DIR)binary_tree_core/lib/$$m$(ASCOMP_EXT)";; \
			tree_rose|Tree) golden="$(THIS_DIR)tree_collections/lib/$$m$(ASCOMP_EXT)";; \
			SearchTree) golden="$(THIS_DIR)search_tree_collections/lib/$$m$(ASCOMP_EXT)";; \
			graph_wbt_*|graph_weighted*) golden="$(THIS_DIR)graph_live_core/lib/$$m$(ASCOMP_EXT)";; \
			graph_csr_*) golden="$(THIS_DIR)graph_csr_core/lib/$$m$(ASCOMP_EXT)";; \
			graph_dense_*) golden="$(THIS_DIR)graph_dense_core/lib/$$m$(ASCOMP_EXT)";; \
			DirectedGraph|UndirectedGraph|WeightedGraph) golden="$(THIS_DIR)graph_collections/lib/$$m$(ASCOMP_EXT)";; \
			*) golden="$(THIS_DIR)wbt_core/lib/$$m$(ASCOMP_EXT)";; \
		esac; \
		if [ ! -f "$$sams" ]; then \
			echo "❌❌ gate-stdlib: $$m produced no assembly"; ko=$$((ko + 1)); continue; \
			$(INTEGRATE_DOT_FAIL); \
		fi; \
		if [ ! -f "$$golden" ]; then \
			echo "❌❌ gate-stdlib: $$m has no golden at $$golden"; ko=$$((ko + 1)); continue; \
			$(INTEGRATE_DOT_FAIL); \
		fi; \
		if diff -Bw -q "$$sams" "$$golden" > /dev/null 2>&1; then \
			echo "✅✅ gate-stdlib: $$m matches its golden exactly"; ok=$$((ok + 1)); continue; \
			$(INTEGRATE_DOT_OK); \
		fi; \
		raw=$$(diff -Bw "$$sams" "$$golden" | grep -c '^[<>]'); \
		sed -E 's/o[0-9]+/oN/g' "$$sams"   > "$$sams.norm"; \
		sed -E 's/o[0-9]+/oN/g' "$$golden" > "$$sams.gnorm"; \
		norm=$$(diff -Bw "$$sams.norm" "$$sams.gnorm" | grep -c '^[<>]'); \
		subst=$$(diff -Bw "$$sams.norm" "$$sams.gnorm" | grep '^[<>]' | grep -vc '^[<>][[:space:]]*;'); \
		echo "❌❌ gate-stdlib: $$m differs -- $$raw diff lines; $$norm after normalising o<N> counters; $$subst of those are code, not comments"; \
		$(INTEGRATE_DOT_FAIL); \
		if [ "$$norm" -eq 0 ]; then \
			echo "        (drift is ENTIRELY SIR/label counter numbering -- generated code is identical)"; \
		else \
			echo "        first real differences (counters normalised):"; \
			diff -Bw "$$sams.norm" "$$sams.gnorm" | head -30 | sed 's/^/        /' || true; \
		fi; \
		rm -f "$$sams.norm" "$$sams.gnorm"; \
		ko=$$((ko + 1)); \
	done; \
	echo "gate-stdlib: $$ok matched, $$ko differed"; \
	[ "$$ko" -eq 0 ]

all: stdlib-objs
	@failed=0; \
	for sub in $(SUB_TRIALS); do \
		echo "=== standard_data_structures_phase1/$$sub (all) ==="; \
		$(MAKE) -C "$(THIS_DIR)$$sub" all $(SDS_LEAF_MAKEFLAGS) || failed=1; \
	done; \
	exit $$failed

# integrate (wrapper in silica_compiler.mk) -> integrate-run: compile the shared stdlib
# once, then run every leaf concurrently (each leaf fans its units out further). Each
# leaf prints its own report as it finishes; this level sums their .integrate_counts.
integrate-run: stdlib-objs
	@cd "$(THIS_DIR)" && rm -f $(SUB_TRIALS:%=%/.integrate_counts)
	@cd "$(THIS_DIR)" && $(MAKE) --no-print-directory -f "$(INTEGRATE_MAKEFILE)" sds-leaves || true
	@cd "$(THIS_DIR)" && $(call INTEGRATE_SUM_CHILDREN,$(SUB_TRIALS)); \
	[ "$$ko" -eq 0 ] && [ "$$failed" -eq 0 ]

sds-leaves: $(SUB_TRIALS:%=sds-leaf-%)

$(SUB_TRIALS:%=sds-leaf-%): sds-leaf-%:
	@$(call INTEGRATE_CHILD,$*,$(SDS_LEAF_MAKEFLAGS))

record-golden: stdlib-objs
	@failed=0; \
	for sub in $(SUB_TRIALS); do \
		echo "=== record-golden: $$sub ==="; \
		$(MAKE) -C "$(THIS_DIR)$$sub" record-golden $(SDS_LEAF_MAKEFLAGS) || failed=1; \
	done; \
	exit $$failed

clean:
	@for sub in $(SUB_TRIALS); do \
		$(MAKE) -C "$(THIS_DIR)$$sub" clean SILICA_COMPILER="$(SILICA_COMPILER)" || true; \
	done
	@rm -rf "$(SDS_STDLIB_CACHE)"
	@rm -f "$(THIS_DIR).integrate_counts"
	@echo "✅ standard_data_structures_phase1/ clean complete"

help:
	@echo "Phase 1 standard data structures trial root"
	@echo "  all             - compile stdlib once, then build all leaves (default)"
	@echo "  integrate       - compile stdlib once, then run all leaves in parallel (SDS_JOBS=$(SDS_JOBS)); report per leaf and overall"
	@echo "  record-golden   - compile stdlib once, then capture .ascomp/.scout/.golden_fail"
	@echo "  stdlib-objs     - compile shared stdlib .o files into .stdlib_cache/"
	@echo "  gate-stdlib     - FAST gate: 4 stdlib modules must match their .ascomp goldens"
	@echo "  clean           - clean all leaves and the stdlib object cache"
	@echo "  Subdirs: $(SUB_TRIALS)"
