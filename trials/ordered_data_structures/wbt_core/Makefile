LEAF_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
THIS_DIR := $(LEAF_DIR)
LIB_SRC := ../../../compiler/stdlib/data_structures

STDLIB_PREREQ_MK := $(firstword $(wildcard $(LEAF_DIR)../stdlib_prereq.mk $(LEAF_DIR)../../stdlib_prereq.mk $(LEAF_DIR)../../../stdlib_prereq.mk))
include $(STDLIB_PREREQ_MK)

include $(LEAF_DIR)../leaf.mk

# WBT core intentionally enumerates accepted gate trials.  This leaf is used
# for narrow compiler/runtime probes while developing WBT; loose probe files
# must not become part of the stable integrate gate merely because they have a
# `.silica` suffix.
POSITIVE_SILICA := \
	smoke_harness_ready.silica \
	wbt_balance_boundaries.silica \
	wbt_constructor_ordering_bundle.silica \
	wbt_empty_representation.silica \
	wbt_fold_ascending.silica \
	wbt_from_sorted_empty.silica \
	wbt_from_sorted_singleton.silica \
	wbt_from_sorted_two.silica \
	wbt_from_sorted_valid_invalid.silica \
	wbt_from_sorted_count_mismatch.silica \
	wbt_from_sorted_map_invalid_two.silica \
	wbt_from_sorted_shape.silica \
	wbt_from_sorted_shape_large.silica \
	wbt_from_sorted_set_map.silica \
	wbt_from_sorted_ten_plus.silica \
	wbt_from_sorted_linear.silica \
	wbt_from_sorted_persistence.silica \
	wbt_generic_payload_shapes.silica \
	wbt_generic_tuple_map_empty.silica \
	wbt_minimum_maximum.silica \
	wbt_read_only_alloc_free.silica \
	wbt_read_only_empty.silica \
	wbt_rebalance_adversarial.silica \
	wbt_representation_specializations.silica \
	wbt_representation_string_specialization.silica \
	wbt_rotation_double_left.silica \
	wbt_rotation_double_right.silica \
	wbt_rotation_gamma_equality.silica \
	wbt_rotation_single_left.silica \
	wbt_rotation_single_right.silica \
	wbt_search_contains.silica \
	wbt_set_insert_adversarial.silica \
	wbt_set_insert_duplicate.silica \
	wbt_set_insert_orders.silica \
	wbt_set_insert_payload_shapes.silica \
	wbt_set_insert_persistence.silica \
	wbt_set_insert_sharing.silica \
	wbt_set_insert_three_validate.silica \
	wbt_map_canonical_key.silica \
	wbt_map_compare_value_not_called.silica \
	wbt_map_insert_payload_shapes.silica \
	wbt_map_insert_orders.silica \
	wbt_map_insert_replace.silica \
	wbt_map_insert_tuple_value.silica \
	wbt_map_tuple_value_escapes_frame.silica \
	wbt_map_replace_persistence.silica \
	wbt_map_value_pairing.silica \
	wbt_delete_absent.silica \
	wbt_delete_leaf.silica \
	wbt_delete_one_child.silica \
	wbt_delete_two_child.silica \
	wbt_delete_root.silica \
	wbt_delete_extreme.silica \
	wbt_delete_heavier_side.silica \
	wbt_delete_rebalance.silica \
	wbt_delete_persistence.silica \
	wbt_delete_payload_shapes.silica \
	wbt_smart_node_arena.silica \
	wbt_smart_node_production_path.silica \
	wbt_smart_node_size.silica \
	wbt_weight_checked.silica \
	wbt_validate_invariants.silica \
	wbt_validate_malformed_fixture.silica \
	wbt_validate_error_precedence.silica \
	wbt_validate_map_pairing.silica \
	wbt_oracle_harness_smoke.silica \
	wbt_set_exhaustive_trace.silica \
	wbt_map_exhaustive_trace.silica \
	wbt_set_randomized_oracle.silica \
	wbt_map_randomized_oracle.silica \
	wbt_persistence_fanout.silica \
	wbt_complexity_observations.silica

COLLECTION_ERROR_TRIALS := trial_collection_error_wbt_search_invalid_comparator.silica trial_collection_error_wbt_smart_node_overflow.silica trial_collection_error_wbt_balance_missing_child.silica trial_collection_error_wbt_set_insert_invalid_comparator.silica trial_collection_error_wbt_map_insert_invalid_comparator.silica trial_collection_error_wbt_set_delete_invalid_comparator.silica trial_collection_error_wbt_map_delete_invalid_comparator.silica trial_collection_error_wbt_from_sorted_set_invalid_comparator.silica trial_collection_error_wbt_from_sorted_map_invalid_comparator.silica trial_collection_error_wbt_validate_invalid_comparator.silica
ALL_COMPILE_SILICA := $(POSITIVE_SILICA) $(COLLECTION_ERROR_TRIALS)

# One silica-compiler process over the full config OOMs on typical 16GB hosts
# (huge wbt_map/wbt_set ASTs retained across every trial unit). Each trial is
# compiled as its own application: lib/*.silica + that one trial per process.

# §8A.3 exit gate: production WBT modules must contain exactly one node allocation site (inside smart_node).
WBT_PRODUCTION_MODULES := wbt_set wbt_map

.PHONY: lib-sources check-wbt-alloc-rec-gate compile-per-trial

check-wbt-alloc-rec-gate:
	@failed=0; \
	for mod in $(WBT_PRODUCTION_MODULES); do \
		silica="$(LEAF_DIR)lib/$$mod.silica"; \
		sams="$(LEAF_DIR)lib/$$mod.sams"; \
		if [ ! -f "$$silica" ]; then \
			echo "FAIL: $(MSG_PREFIX)missing $$silica (run make lib-sources)"; \
			failed=1; \
			continue; \
		fi; \
		if [ ! -f "$$sams" ]; then \
			echo "FAIL: $(MSG_PREFIX)missing $$sams (compile stdlib modules first)"; \
			failed=1; \
			continue; \
		fi; \
		src_count=$$(grep -c 'alloc_rec' "$$silica" || true); \
		if [ "$$src_count" -ne 1 ]; then \
			echo "FAIL: $(MSG_PREFIX)$$mod.silica has $$src_count alloc_rec sites (expected 1 in smart_node_finish)"; \
			grep -n 'alloc_rec' "$$silica" || true; \
			failed=1; \
		else \
			echo "✅ $(MSG_PREFIX)$$mod.silica single smart_node allocation site"; \
		fi; \
	done; \
	exit $$failed

lib-sources: stdlib-data-structures
	@mkdir -p "$(LEAF_DIR)lib"
	@# Relative (from lib/), so the links stay valid in a tree synced to another host.
	@ln -sfn "../$(LIB_SRC)/wbt_set.silica" "$(LEAF_DIR)lib/wbt_set.silica"
	@ln -sfn "../$(LIB_SRC)/wbt_map.silica" "$(LEAF_DIR)lib/wbt_map.silica"

silica.config: lib-sources
	@cd "$(LEAF_DIR)" && $(TRIAL_SUPPORT_LIB) && { \
		printf '%s\n' $(ALL_COMPILE_SILICA); \
		if [ -d lib ]; then find lib -name '*.silica' | sort; fi; \
	} > silica.config

# Restores full silica.config after per-trial compiles (see compile_per_trial.sh).
WBT_COMPILE_PER_TRIAL = \
	MSG_PREFIX="$(MSG_PREFIX)" \
	SILICA_COMPILER="$(SILICA_COMPILER)" \
	SDS_STDLIB_CACHE="$(SDS_STDLIB_CACHE)" \
	SDS_STDLIB_MODULES="$(SDS_STDLIB_MODULES)" \
	"$(SHELL)" "$(LEAF_DIR)compile_per_trial.sh"

compile-per-trial: lib-sources silica.config
	@$(ENSURE_SILICA_COMPILER)
	@cd "$(LEAF_DIR)" && $(INSTALL_SDS_STDLIB_OBJS)
	@cd "$(LEAF_DIR)" && $(WBT_COMPILE_PER_TRIAL)

assembly: lib-sources silica.config
	@if [ ! -s "$(LEAF_DIR)silica.config" ]; then \
		echo "SKIP: $(MSG_PREFIX)no positive .silica trials"; \
		exit 0; \
	fi
	@$(ENSURE_SILICA_COMPILER)
	@$(INTEGRATE_PRE_CLEAN)
	@cd "$(LEAF_DIR)" && $(INSTALL_SDS_STDLIB_OBJS)
	@echo "Compiling with silica-compiler (one trial per process)..."
	@cd "$(LEAF_DIR)" && $(WBT_COMPILE_PER_TRIAL)
	@cd "$(LEAF_DIR)" && $(INSTALL_SDS_STDLIB_OBJS)
	@echo "✅ $(MSG_PREFIX)Assembly generated"

# integrate: leaf.mk's parallel per-unit sandboxes over the enumerated gate trials
# (positive + collection-error). The §8A.3 allocation-site gate runs once the lib
# units are compiled and before the unit fan-out.
LEAF_UNITS := $(ALL_COMPILE_SILICA)
LEAF_POST_LIB_HOOK = $(MAKE) --no-print-directory -f "$(INTEGRATE_MAKEFILE)" check-wbt-alloc-rec-gate || { printf '%d %d\n' 0 1 > .integrate_counts; exit 1; }
positive-integrate: lib-sources

record-positive-golden: lib-sources silica.config
	@echo "$(MSG_PREFIX)record-positive-golden: starting..."
	@$(ENSURE_SILICA_COMPILER)
	@$(INTEGRATE_PRE_CLEAN)
	@cd "$(LEAF_DIR)" && $(INSTALL_SDS_STDLIB_OBJS)
	@cd "$(LEAF_DIR)" && $(WBT_COMPILE_PER_TRIAL)
	@cd "$(LEAF_DIR)" && $(INSTALL_SDS_STDLIB_OBJS)
	@cd "$(LEAF_DIR)" && for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		[ "$$base" = "__silica_runtime" ] && continue; \
		cp "$$sams" "$$base$(ASCOMP_EXT)"; \
		echo "Recorded $$base$(ASCOMP_EXT)"; \
	done
	@cd "$(LEAF_DIR)" && for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		[ "$$base" = "__silica_runtime" ] && continue; \
		$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "$$base.o"; \
	done
	@if [ -f "$(LEAF_DIR)__silica_runtime.sams" ]; then \
		$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$(LEAF_DIR)__silica_runtime.sams" -o "$(LEAF_DIR)__silica_runtime.o"; \
	fi
	@cd "$(LEAF_DIR)" && for sams in lib/*.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$$(basename "$$sams" .sams); \
		if [ -n "$(SDS_STDLIB_CACHE)" ] && [ -f "$(SDS_STDLIB_CACHE)/lib/$$base.o" ]; then \
			cp -f "$(SDS_STDLIB_CACHE)/lib/$$base.o" "lib/$$base.o"; \
			continue; \
		fi; \
		$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "lib/$$base.o"; \
	done
	@cd "$(LEAF_DIR)" || exit 1; \
	lib_objs=""; \
	for obj in lib/*.o; do [ -f "$$obj" ] && lib_objs="$$lib_objs $$obj"; done; \
	rust_sysroot=$$(rustc --print sysroot 2>/dev/null); \
	rust_target=$$(rustc -vV 2>/dev/null | sed -n 's/^host: //p'); \
	rust_lld="$$rust_sysroot/lib/rustlib/$$rust_target/bin/rust-lld"; \
	macos_sdk=$$(xcrun --sdk macosx --show-sdk-path 2>/dev/null); \
	for trial in $(ALL_COMPILE_SILICA); do \
		base=$${trial%.silica}; \
		[ -f "$$base.o" ] || continue; \
		runtime_obj=""; \
		[ -f "__silica_runtime.o" ] && runtime_obj="__silica_runtime.o"; \
		if test -x "$$rust_lld"; then \
			$$rust_lld -flavor darwin -o "$$base" "$$base.o" $$lib_objs $$runtime_obj \
				-arch arm64 -platform_version macos $(MACOS_MIN_VERSION) $(MACOS_MIN_VERSION) \
				-syslibroot "$$macos_sdk" -lSystem -e main; \
		else \
			$(ASSEMBLER) "$$base.o" $$lib_objs $$runtime_obj -o "$$base" $(LDFLAGS_clang); \
		fi; \
		{ ./$$base 2>&1; echo $$?; } > "$$base.scout"; \
		echo "Recorded $$base.scout"; \
	done
	@cd "$(LEAF_DIR)" && for trial in $(ALL_COMPILE_SILICA); do \
		base=$${trial%.silica}; \
		$(call TRIAL_RM_UNTRACKED,"$$base"); rm -f "$$base.o"; \
	done
	@cd "$(LEAF_DIR)" && rm -f __silica_runtime.o lib/*.o *.iface *.sams lib/*.sams *.sout .integrate_counts
	@echo "✅ $(MSG_PREFIX)record-positive-golden complete"

clean:
	@echo "$(MSG_PREFIX)clean: removing prior artifacts..."
	@cd "$(LEAF_DIR)" && for s in *.sams; do \
		[ -f "$$s" ] || continue; \
		$(call TRIAL_RM_UNTRACKED,"$${s%.sams}"); \
	done
	@cd "$(LEAF_DIR)" && rm -f *.sams lib/wbt_set.sams lib/wbt_map.sams lib/wbt_set.silica lib/wbt_map.silica *.o *.iface lib/*.o __silica_runtime.o smoke_harness_ready wbt_balance_boundaries wbt_empty_representation wbt_generic_payload_shapes wbt_generic_tuple_map_empty wbt_representation_specializations wbt_representation_string_specialization wbt_constructor_ordering_bundle wbt_search_contains wbt_minimum_maximum wbt_fold_ascending wbt_from_sorted_empty wbt_from_sorted_singleton wbt_from_sorted_two wbt_from_sorted_shape wbt_from_sorted_shape_large wbt_from_sorted_set_map wbt_from_sorted_ten_plus wbt_from_sorted_valid_invalid wbt_from_sorted_map_invalid_two wbt_from_sorted_count_mismatch wbt_from_sorted_linear wbt_from_sorted_persistence wbt_read_only_alloc_free wbt_read_only_empty wbt_rebalance_adversarial wbt_rotation_double_left wbt_rotation_double_right wbt_rotation_gamma_equality wbt_rotation_single_left wbt_rotation_single_right wbt_smart_node_arena wbt_smart_node_production_path wbt_smart_node_size wbt_weight_checked wbt_set_insert_adversarial wbt_set_insert_duplicate wbt_set_insert_orders wbt_set_insert_payload_shapes wbt_set_insert_persistence wbt_set_insert_sharing wbt_set_insert_three_validate wbt_map_canonical_key wbt_map_compare_value_not_called wbt_map_insert_payload_shapes wbt_map_insert_orders wbt_map_insert_replace wbt_map_insert_tuple_value wbt_map_tuple_value_escapes_frame wbt_map_replace_persistence wbt_map_value_pairing wbt_delete_absent wbt_delete_leaf wbt_delete_one_child wbt_delete_two_child wbt_delete_root wbt_delete_extreme wbt_delete_heavier_side wbt_delete_rebalance wbt_delete_persistence wbt_delete_payload_shapes wbt_validate_invariants wbt_validate_malformed_fixture wbt_validate_error_precedence wbt_validate_map_pairing wbt_oracle_harness_smoke wbt_set_exhaustive_trace wbt_map_exhaustive_trace wbt_set_randomized_oracle wbt_map_randomized_oracle wbt_persistence_fanout wbt_complexity_observations trial_collection_error_wbt_search_invalid_comparator trial_collection_error_wbt_smart_node_overflow trial_collection_error_wbt_balance_missing_child trial_collection_error_wbt_set_insert_invalid_comparator trial_collection_error_wbt_map_insert_invalid_comparator trial_collection_error_wbt_set_delete_invalid_comparator trial_collection_error_wbt_map_delete_invalid_comparator trial_collection_error_wbt_from_sorted_set_invalid_comparator trial_collection_error_wbt_from_sorted_map_invalid_comparator trial_collection_error_wbt_validate_invalid_comparator *.sout silica.config silica.config.full .compile_trials.list .compile_libs.list .compile_libs.atoms silica.compile.order silica.needs_runtime silica.atoms silica.link .integrate_counts .integrate_results *.checked __silica_runtime.sams.*
	@cd "$(LEAF_DIR)" && rm -rf $(LEAF_SANDBOX)
	@echo "✅ $(MSG_PREFIX)Clean complete"
