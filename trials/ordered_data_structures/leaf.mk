# Shared Makefile fragment for Phase 1 standard-data-structure trial leaves.
# Each leaf Makefile must set LEAF_DIR before including this file:
#   LEAF_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
#   include ../leaf.mk

ifndef LEAF_DIR
$(error LEAF_DIR must be set before including leaf.mk)
endif

THIS_DIR        := $(LEAF_DIR)
include $(LEAF_DIR)../../silica_compiler.mk
# A standalone `make -C <leaf> integrate` fans its units out SDS_JOBS-wide, not JOBS-wide:
# each unit compile re-derives its stdlib dependencies and is memory-bound.
INTEGRATE_JOBS  := $(SDS_JOBS)
TRIAL_DIR       := $(notdir $(patsubst %/,%,$(THIS_DIR)))
MSG_PREFIX      := standard_data_structures_phase1/$(TRIAL_DIR)/

# Linker probes, evaluated once per make instead of once per unit recipe.
LEAF_RUST_SYSROOT := $(shell rustc --print sysroot 2>/dev/null)
LEAF_RUST_TARGET  := $(shell rustc -vV 2>/dev/null | sed -n 's/^host: //p')
LEAF_RUST_LLD     := $(LEAF_RUST_SYSROOT)/lib/rustlib/$(LEAF_RUST_TARGET)/bin/rust-lld
LEAF_MACOS_SDK    := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)

ASSEMBLER       := clang
MACOS_MIN_VERSION ?= 26.0
ASFLAGS_macos   := -mmacosx-version-min=$(MACOS_MIN_VERSION)
LDFLAGS_clang   := -Wl,-e,main -Wl,-macos_version_min,$(MACOS_MIN_VERSION)

# Positive trials: compile, link, run, diff .sams/.ascomp and .sout/.scout.
# Pure-make discovery (no $(shell find)) so `make` starts immediately on slow/network volumes.
# Excluded from silica.config (handled by other harness paths):
#   trial_negative_*            isolated negative compiles
#   trial_compile_fail_*        expected compile failure (error_enforcement_addition/standard_data_structures)
#   trial_collection_error_*    expected deterministic runtime collection error
_ALL_LEAF_SILICA := $(wildcard $(THIS_DIR)*.silica)
_EXCLUDED_SILICA := $(wildcard $(THIS_DIR)trial_negative_*.silica) \
	$(wildcard $(THIS_DIR)trial_compile_fail_*.silica) \
	$(wildcard $(THIS_DIR)trial_collection_error_*.silica)
POSITIVE_SILICA := $(sort $(patsubst $(THIS_DIR)%,%,$(filter-out $(_EXCLUDED_SILICA),$(_ALL_LEAF_SILICA))))

# Remove stale assembly/link artifacts before compile (used inline — not via `clean` prerequisite).
INTEGRATE_PRE_CLEAN = cd "$(THIS_DIR)" && \
	rm -f .integrate_counts .integrate_results *.checked *.sams lib/*.sams *.o lib/*.o *.iface lib/*.iface __silica_runtime.o *.sout \
		silica.compile.order silica.needs_runtime silica.link && \
	rm -rf $(LEAF_SANDBOX) && \
	for s in *.sams; do \
		[ -f "$$s" ] || continue; \
		rm -f "$${s%.sams}"; \
	done

# Root `make integrate` compiles these once into SDS_STDLIB_CACHE and passes both vars.
# Standalone leaf integrate leaves SDS_STDLIB_CACHE empty and compiles lib/ as before.
SDS_STDLIB_MODULES ?= wbt_set wbt_map OrderedMap OrderedSet skew_ral_weights skew_ral_node skew_ral_tree_read skew_ral_tree_write skew_ral_forest skew_ral_index skew_ral_traverse skew_ral_build skew_ral_validate skew_ral_dispatch_access skew_ral_dispatch_bulk skew_ral brodal_okasaki_node brodal_okasaki_compare brodal_okasaki_link brodal_okasaki_forest brodal_okasaki_extract brodal_okasaki_boot brodal_okasaki_validate brodal_okasaki_dispatch_core brodal_okasaki_dispatch_bulk brodal_okasaki tree_binary BinaryTree brodal_okasaki_min brodal_okasaki_max brodal_okasaki_priority Heap PriorityQueue tree_rose Tree SearchTree graph_wbt_core graph_wbt_directed graph_wbt_undirected graph_weighted graph_weighted_undirected graph_csr_core graph_csr_directed graph_csr_undirected graph_csr_weighted graph_csr_weighted_undirected graph_dense_core graph_dense_directed graph_dense_undirected graph_dense_weighted graph_dense_weighted_undirected DirectedGraph UndirectedGraph WeightedGraph

# Copy prebuilt stdlib .o/.sams/.iface into this leaf's lib/ (same relative source= paths).
define INSTALL_SDS_STDLIB_OBJS
if [ -n "$(SDS_STDLIB_CACHE)" ] && [ -d "$(SDS_STDLIB_CACHE)/lib" ]; then \
	mkdir -p lib; \
	for m in $(SDS_STDLIB_MODULES); do \
		if [ -e "lib/$$m.silica" ] || [ -L "lib/$$m.silica" ]; then \
			for ext in o sams iface; do \
				src="$(SDS_STDLIB_CACHE)/lib/$$m.$$ext"; \
				if [ -f "$$src" ]; then cp -f "$$src" "lib/$$m.$$ext"; fi; \
			done; \
		fi; \
	done; \
	for f in silica.atoms silica.shapes; do \
		src="$(SDS_STDLIB_CACHE)/$$f"; \
		[ -f "$$src" ] || continue; \
		if [ -f "$$f" ] && head -c "$$(wc -c < "$$src" | tr -d ' ')" "$$f" | cmp -s - "$$src"; then :; else cp -f "$$src" "$$f"; fi; \
	done; \
fi
endef

# Keep already-compiled units in silica.config for `use` / iface lookup, but
# resume-compile only units that do not yet have a sibling .iface. Lib units
# are listed first so local helpers compile before the trials that use them.
define SEED_SDS_COMPILE_ORDER
if [ -f silica.config ]; then \
	: > silica.compile.order; \
	while IFS= read -r f || [ -n "$$f" ]; do \
		[ -n "$$f" ] || continue; \
		case "$$f" in lib/*) ;; *) continue ;; esac; \
		[ -f "$${f%.silica}.iface" ] || printf '%s\n' "$$f" >> silica.compile.order; \
	done < silica.config; \
	while IFS= read -r f || [ -n "$$f" ]; do \
		[ -n "$$f" ] || continue; \
		case "$$f" in lib/*) continue ;; esac; \
		[ -f "$${f%.silica}.iface" ] || printf '%s\n' "$$f" >> silica.compile.order; \
	done < silica.config; \
fi
endef
# Content-addressed compile cache (trial_cache.sh). Restore runs after the stdlib
# objects are installed and BEFORE SEED_SDS_COMPILE_ORDER: a restored unit gets a
# sibling .iface, so the seed step leaves it out of silica.compile.order and the
# compiler never re-derives it. Store runs after a successful compile.
# Set TRIAL_CACHE=0 to force a full recompile.
TRIAL_CACHE_SH := $(LEAF_DIR)../trial_cache.sh
TRIAL_CACHE_ENV = MSG_PREFIX="$(MSG_PREFIX)" SILICA_COMPILER="$(SILICA_COMPILER)" SDS_STDLIB_CACHE="$(SDS_STDLIB_CACHE)"
TRIAL_CACHE_RESTORE = $(TRIAL_CACHE_ENV) "$(SHELL)" "$(TRIAL_CACHE_SH)" restore
TRIAL_CACHE_STORE   = $(TRIAL_CACHE_ENV) "$(SHELL)" "$(TRIAL_CACHE_SH)" store

.PHONY: all clean assembly objects executables integrate positive-integrate record-positive-golden record-golden help silica.config

.DEFAULT_GOAL := all

silica.config:
	@echo "$(MSG_PREFIX)regenerating silica.config..."
	@cd "$(THIS_DIR)" && $(TRIAL_SUPPORT_LIB) && { \
		printf '%s\n' $(POSITIVE_SILICA); \
		if [ -d lib ]; then find lib \( -type f -o -type l \) -name '*.silica' | sort; fi; \
	} > silica.config

all: executables

assembly: silica.config
	@if [ ! -s "$(THIS_DIR)silica.config" ]; then \
		echo "SKIP: $(MSG_PREFIX)no positive .silica trials"; \
		exit 0; \
	fi
	@$(ENSURE_SILICA_COMPILER)
	@$(INTEGRATE_PRE_CLEAN)
	@cd "$(THIS_DIR)" && $(INSTALL_SDS_STDLIB_OBJS) && $(TRIAL_CACHE_RESTORE) && $(SEED_SDS_COMPILE_ORDER)
	@echo "Compiling with silica-compiler..."
	@cd "$(THIS_DIR)" && $(RUN_SILICA_COMPILER)
	@cd "$(THIS_DIR)" && $(TRIAL_CACHE_STORE)
	@cd "$(THIS_DIR)" && $(INSTALL_SDS_STDLIB_OBJS)
	@echo "✅ $(MSG_PREFIX)Assembly generated"

objects: assembly
	@cd "$(THIS_DIR)" && for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		[ "$$base" = "__silica_runtime" ] && continue; \
		echo "Assembling: $$sams -> $$base.o"; \
		$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "$$base.o"; \
	done
	@if [ -f "$(THIS_DIR)__silica_runtime.sams" ]; then \
		echo "Assembling: __silica_runtime.sams -> __silica_runtime.o"; \
		$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$(THIS_DIR)__silica_runtime.sams" -o "$(THIS_DIR)__silica_runtime.o"; \
	fi
	@cd "$(THIS_DIR)" && for sams in lib/*.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$$(basename "$$sams" .sams); \
		if [ -n "$(SDS_STDLIB_CACHE)" ] && [ -f "$(SDS_STDLIB_CACHE)/lib/$$base.o" ]; then \
			echo "Reusing $(SDS_STDLIB_CACHE)/lib/$$base.o"; \
			cp -f "$(SDS_STDLIB_CACHE)/lib/$$base.o" "lib/$$base.o"; \
			continue; \
		fi; \
		echo "Assembling: $$sams -> lib/$$base.o"; \
		$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "lib/$$base.o"; \
	done

executables: objects
	@cd "$(THIS_DIR)" || exit 1; \
	lib_objs=""; \
	for obj in lib/*.o; do [ -f "$$obj" ] && lib_objs="$$lib_objs $$obj"; done; \
	rust_sysroot=$$(rustc --print sysroot 2>/dev/null); \
	rust_target=$$(rustc -vV 2>/dev/null | sed -n 's/^host: //p'); \
	rust_lld="$$rust_sysroot/lib/rustlib/$$rust_target/bin/rust-lld"; \
	macos_sdk=$$(xcrun --sdk macosx --show-sdk-path 2>/dev/null); \
	for trial in $(POSITIVE_SILICA); do \
		base=$${trial%.silica}; \
		[ -f "$$base.o" ] || continue; \
		runtime_obj=""; \
		[ -f "__silica_runtime.o" ] && runtime_obj="__silica_runtime.o"; \
		if test -x "$$rust_lld"; then \
			$$rust_lld -flavor darwin -o "$$base" "$$base.o" $$lib_objs $$runtime_obj \
				-arch arm64 -platform_version macos $(MACOS_MIN_VERSION) $(MACOS_MIN_VERSION) \
				-syslibroot "$$macos_sdk" -lSystem -e main && echo "  ✅ $(MSG_PREFIX)$$base (rust-lld)"; \
		else \
			$(ASSEMBLER) "$$base.o" $$lib_objs $$runtime_obj -o "$$base" $(LDFLAGS_clang) && echo "  ✅ $(MSG_PREFIX)$$base (clang)"; \
		fi; \
	done

# ----------------------------------------------------------------------------
# integrate: per-unit sandboxed compiles, run in parallel.
#
# Lib units (lib/*.silica without a sibling .iface after the stdlib cache install and
# the trial cache restore) are compiled once, serially, in .sandbox/_lib. Then every
# trial unit is compiled as its own application in a private sandbox, .sandbox/<unit>/:
# the leaf's lib/ is symlinked in, every unit source is symlinked in so silica.config
# validates, and silica.compile.order names just that unit, so the driver parses only
# that unit's `use` closure and emits only that unit. Sandboxes give each parallel
# compile its own silica.config / silica.compile.order / __silica_runtime.sams, so the
# units never touch each other's files.
#
# The driver honours a pre-written compile order only when silica.config lists more
# than 32 units (at or below that it compiles every listed unit in one process), so
# the sandbox config is padded with empty .pad/pad_N.silica entries up to 33. Padding
# entries are never parsed: resume mode parses only the ordered unit's closure.
#
# Each unit appends one line per check to .integrate_results ("PASS<tab>unit<tab>msg",
# "FAIL<tab>unit<tab>msg", "ASCOK<tab>unit") with single short writes, so parallel
# units never interleave; the totals come from that file. A unit's whole output is
# buffered and printed as one block so its ❌❌ line and diff stay together in the log.
# The messages are the ones the serial recipe printed.
# ----------------------------------------------------------------------------
LEAF_UNITS ?= $(POSITIVE_SILICA)
LEAF_UNIT_STAMPS = $(patsubst %.silica,%.checked,$(LEAF_UNITS))
LEAF_PAD_MIN := 33
LEAF_SANDBOX := .sandbox
# Runs after the lib units are compiled and assembled, before the unit fan-out.
LEAF_POST_LIB_HOOK ?= :

# $(call LEAF_SANDBOX_PREPARE,<sandbox dir>,<units to compile>) -- cwd is the leaf.
# Every sandbox of this leaf starts from the leaf's silica.atoms and silica.shapes: the compiler
# numbers a unit's atoms by extending that table (atom_table@build_atom_table_extending) and
# sizes the registries of the runtime module it (re)writes from it (item J). A sandbox that
# started empty numbered the trial unit against the fixed prefix alone and wrote a runtime
# with fewer slots than the lib objects' atom indices (type_interner_roundtrip: the lib's
# :type_surface_cache was atom 28, the sandbox runtime had 27 slots, so the name never
# registered and parse_type reported failure). The tables only ever grow, so an object
# compiled under an earlier state of the table keeps valid indices.
define LEAF_SANDBOX_PREPARE
sb="$(1)"; rm -rf "$$sb"; mkdir -p "$$sb/.pad"; \
if [ -d lib ]; then ln -s ../../lib "$$sb/lib"; fi; \
for f in silica.atoms silica.shapes; do if [ -f "$$f" ]; then cp -f "$$f" "$$sb/$$f"; fi; done; \
: > "$$sb/silica.config"; n=0; \
while IFS= read -r f || [ -n "$$f" ]; do \
	[ -n "$$f" ] || continue; \
	case "$$f" in lib/*) ;; *) ln -s "../../$$f" "$$sb/$$f";; esac; \
	printf '%s\n' "$$f" >> "$$sb/silica.config"; n=$$((n + 1)); \
done < silica.config; \
i=0; while [ $$((n + i)) -lt $(LEAF_PAD_MIN) ]; do \
	i=$$((i + 1)); : > "$$sb/.pad/pad_$$i.silica"; printf '.pad/pad_%s.silica\n' "$$i" >> "$$sb/silica.config"; \
done; \
printf '%s\n' $(2) > "$$sb/silica.compile.order"
endef

# Compile the lib units that still lack an .iface, once, serially.
define LEAF_COMPILE_LIBS
pending=""; \
for f in $$(grep '^lib/' silica.config); do \
	[ -f "$${f%.silica}.iface" ] || pending="$$pending $$f"; \
done; \
if [ -n "$$pending" ]; then \
	np=$$(echo $$pending | wc -w | tr -d ' '); \
	echo "$(MSG_PREFIX)compiling $$np lib unit(s) once for this integrate"; \
	$(call LEAF_SANDBOX_PREPARE,$(LEAF_SANDBOX)/_lib,$$pending); \
	if ( cd "$(LEAF_SANDBOX)/_lib" && $(RUN_SILICA_COMPILER) ); then :; else \
		ec=$$?; \
		if [ $$ec -eq 137 ] || [ $$ec -eq 9 ]; then \
			echo "❌❌ $(MSG_PREFIX)compilation killed (exit $$ec; likely OOM while compiling lib units)"; \
			$(INTEGRATE_DOT_FAIL); \
		else \
			echo "❌❌ $(MSG_PREFIX)compilation failed (exit $$ec) while compiling lib units"; \
			$(INTEGRATE_DOT_FAIL); \
		fi; \
		printf '%d %d\n' 0 1 > .integrate_counts; \
		exit 1; \
	fi; \
	for f in silica.atoms silica.shapes __silica_runtime.sams; do \
		if [ -f "$(LEAF_SANDBOX)/_lib/$$f" ]; then cp -f "$(LEAF_SANDBOX)/_lib/$$f" "$$f"; fi; \
	done; \
	rm -rf "$(LEAF_SANDBOX)/_lib"; \
	echo "$(MSG_PREFIX)lib units compiled; trials reuse their .o files"; \
else \
	echo "$(MSG_PREFIX)all lib units already have .iface; reusing .o files"; \
fi
endef

# Assemble lib/*.sams that have no .o yet (stdlib objects arrive prebuilt from the cache).
define LEAF_ASSEMBLE_LIBS
if [ "$(SILICA_TARGET_IS_HOST)" != 1 ]; then :; else \
for sams in lib/*.sams; do \
	[ -f "$$sams" ] || continue; \
	base=$$(basename "$$sams" .sams); \
	[ -f "lib/$$base.o" ] && continue; \
	echo "Assembling $$sams..."; \
	if ! $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "lib/$$base.o"; then \
		echo "❌❌ $(MSG_PREFIX)lib/$$base assemble failed"; \
		$(INTEGRATE_DOT_FAIL); \
		printf 'FAIL\tlib/%s\tassemble failed\n' "$$base" >> .integrate_results; \
	fi; \
done; \
fi
endef

# One unit, start to finish: compile in a sandbox (unless the trial cache restored it),
# diff .sams vs .ascomp, assemble, link, run, diff .sout vs .scout. Never fails the
# make: every outcome is a results line. $(call LEAF_UNIT_RUN,<unit base>) -- cwd is the leaf.
define LEAF_UNIT_RUN
b="$(1)"; sb="$(LEAF_SANDBOX)/$$b"; res=.integrate_results; rm -rf "$$sb"; \
if [ -f "$$b.sams" ] && [ -f "$$b.iface" ]; then \
	mkdir -p "$$sb"; \
	if [ -f "$$b.runtime.sams" ]; then cp -f "$$b.runtime.sams" "$$sb/__silica_runtime.sams"; \
	elif [ -f __silica_runtime.sams ]; then cp -f __silica_runtime.sams "$$sb/__silica_runtime.sams"; fi; \
else \
	$(call LEAF_SANDBOX_PREPARE,$$sb,$$b.silica); \
	if ( cd "$$sb" && $(RUN_SILICA_COMPILER) ) > "$$sb/compile.log" 2>&1; then :; else \
		ec=$$?; \
		if [ $$ec -eq 137 ] || [ $$ec -eq 9 ]; then \
			echo "❌❌ $(MSG_PREFIX)$$b compilation killed (exit $$ec; likely OOM)"; \
			$(INTEGRATE_DOT_FAIL); \
		else \
			echo "❌❌ $(MSG_PREFIX)$$b compilation failed (exit $$ec)"; \
			$(INTEGRATE_DOT_FAIL); \
		fi; \
		tail -n 30 "$$sb/compile.log" | sed 's/^/        /'; \
		printf 'FAIL\t%s\tcompilation failed (exit %s)\n' "$$b" "$$ec" >> "$$res"; \
		rm -rf "$$sb"; touch "$$b.checked"; exit 0; \
	fi; \
	if [ ! -f "$$sb/$$b.sams" ]; then \
		echo "❌❌ $(MSG_PREFIX)$$b compiled but produced no .sams"; \
		$(INTEGRATE_DOT_FAIL); \
		printf 'FAIL\t%s\tcompiled but produced no .sams\n' "$$b" >> "$$res"; \
		rm -rf "$$sb"; touch "$$b.checked"; exit 0; \
	fi; \
	mv -f "$$sb/$$b.sams" "$$b.sams"; \
	if [ -f "$$sb/$$b.iface" ]; then mv -f "$$sb/$$b.iface" "$$b.iface"; fi; \
	if [ -f "$$sb/__silica_runtime.sams" ]; then cp -f "$$sb/__silica_runtime.sams" "$$b.runtime.sams"; fi; \
	if [ -f "$$sb/__silica_runtime.sams" ] && [ ! -f __silica_runtime.sams ]; then \
		cp -f "$$sb/__silica_runtime.sams" "__silica_runtime.sams.$$b" && mv -f "__silica_runtime.sams.$$b" __silica_runtime.sams; \
	fi; \
fi; \
if [ "$(SILICA_TARGET_IS_HOST)" != 1 ]; then \
	printf 'XTARGET\t%s\n' "$$b" >> "$$res"; \
	rm -rf "$$sb"; touch "$$b.checked"; exit 0; \
fi; \
rt=""; \
if [ -f "$$sb/__silica_runtime.sams" ]; then \
	if $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sb/__silica_runtime.sams" -o "$$sb/__silica_runtime.o"; then \
		rt="$$sb/__silica_runtime.o"; \
	else \
		echo "❌❌ $(MSG_PREFIX)$$b: __silica_runtime assemble failed"; \
		$(INTEGRATE_DOT_FAIL); \
		printf 'FAIL\t%s\t__silica_runtime assemble failed\n' "$$b" >> "$$res"; \
	fi; \
fi; \
if [ ! -f "$$b$(ASCOMP_EXT)" ]; then \
	echo "❌❌ $(MSG_PREFIX)$$b has no .ascomp file (run make record-golden from trial root)"; \
	$(INTEGRATE_DOT_FAIL); \
	printf 'FAIL\t%s\thas no .ascomp file\n' "$$b" >> "$$res"; \
elif ! diff -Bw -q "$$b.sams" "$$b$(ASCOMP_EXT)" > /dev/null 2>&1; then \
	raw=$$(diff -Bw "$$b.sams" "$$b$(ASCOMP_EXT)" | grep -c '^[<>]'); \
	sed -E 's/o[0-9]+/oN/g' "$$b.sams" > "$$sb/norm"; \
	sed -E 's/o[0-9]+/oN/g' "$$b$(ASCOMP_EXT)" > "$$sb/gnorm"; \
	norm=$$(diff -Bw "$$sb/norm" "$$sb/gnorm" | grep -c '^[<>]'); \
	subst=$$(diff -Bw "$$sb/norm" "$$sb/gnorm" | grep '^[<>]' | grep -vc '^[<>][[:space:]]*;'); \
	echo "❌❌ $(MSG_PREFIX)$$b .sams differs from .ascomp -- $$raw diff lines; $$norm after normalising o<N> counters; $$subst of those are code, not comments"; \
	$(INTEGRATE_DOT_FAIL); \
	if [ "$$norm" -eq 0 ]; then \
		echo "        (drift is ENTIRELY SIR/label counter numbering -- generated code is identical)"; \
	else \
		echo "        first real differences (counters normalised):"; \
		diff -Bw "$$sb/norm" "$$sb/gnorm" | head -30 | sed 's/^/        /' || true; \
	fi; \
	printf 'FAIL\t%s\t.sams differs from .ascomp\n' "$$b" >> "$$res"; \
else \
	printf 'ASCOK\t%s\n' "$$b" >> "$$res"; \
fi; \
echo "Assembling $$b.sams..."; \
if ! $(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$b.sams" -o "$$b.o"; then \
	echo "❌❌ $(MSG_PREFIX)$$b assemble failed"; \
	$(INTEGRATE_DOT_FAIL); \
	printf 'FAIL\t%s\tassemble failed\n' "$$b" >> "$$res"; \
	rm -rf "$$sb"; touch "$$b.checked"; exit 0; \
fi; \
lib_objs=""; \
for obj in lib/*.o; do [ -f "$$obj" ] && lib_objs="$$lib_objs $$obj"; done; \
echo "Linking $$b..."; \
linked=0; \
if test -x "$(LEAF_RUST_LLD)"; then \
	"$(LEAF_RUST_LLD)" -flavor darwin -o "$$b" "$$b.o" $$lib_objs $$rt \
		-arch arm64 -platform_version macos $(MACOS_MIN_VERSION) $(MACOS_MIN_VERSION) \
		-syslibroot "$(LEAF_MACOS_SDK)" -lSystem -e main && linked=1; \
else \
	$(ASSEMBLER) "$$b.o" $$lib_objs $$rt -o "$$b" $(LDFLAGS_clang) && linked=1; \
fi; \
rm -rf "$$sb"; \
if [ "$$linked" -ne 1 ] || [ ! -x "$$b" ]; then \
	echo "❌❌ $(MSG_PREFIX)$$b link failed"; \
	$(INTEGRATE_DOT_FAIL); \
	printf 'FAIL\t%s\tlink failed\n' "$$b" >> "$$res"; \
	touch "$$b.checked"; exit 0; \
fi; \
echo "Running $$b..."; \
$(call INTEGRATE_RUN_TRIAL,$(MSG_PREFIX)$$b,$$b.sout,./$$b); \
if [ "$$integrate_killed" = 1 ]; then \
	echo "❌❌ $(MSG_PREFIX)$$b $(INTEGRATE_KILLED_MSG)"; \
	$(INTEGRATE_DOT_FAIL); \
	printf 'FAIL\t%s\tkilled by the watchdog; trial incomplete\n' "$$b" >> "$$res"; \
elif [ -f "$$b.scout" ]; then \
	if ! diff -Bw -q "$$b.sout" "$$b.scout" > /dev/null 2>&1; then \
		echo "❌❌ $(MSG_PREFIX)$$b .sout differs from .scout"; \
		$(INTEGRATE_DOT_FAIL); \
		diff -Bw "$$b.sout" "$$b.scout" || true; \
		printf 'FAIL\t%s\t.sout differs from .scout\n' "$$b" >> "$$res"; \
	else \
		echo "✅✅ $(MSG_PREFIX)$$b output matches .scout"; \
		$(INTEGRATE_DOT_OK); \
		printf 'PASS\t%s\toutput matches .scout\n' "$$b" >> "$$res"; \
	fi; \
else \
	echo "❌❌ $(MSG_PREFIX)$$b has no .scout file (run make record-golden from trial root)"; \
	$(INTEGRATE_DOT_FAIL); \
	printf 'FAIL\t%s\thas no .scout file\n' "$$b" >> "$$res"; \
fi; \
touch "$$b.checked"
endef

# No `leaf-units: $(LEAF_UNIT_STAMPS)` rule: prerequisites on a rule line are expanded
# when make reads the line, i.e. before a leaf Makefile that includes this file has
# overridden POSITIVE_SILICA / LEAF_UNITS. positive-integrate passes the stamps to the
# sub-make on its command line instead, which expands them at recipe time.

# A unit's stamp. Its whole output is buffered to .sandbox/<unit>.out and printed as
# one block, so the ❌❌ line and its diff stay adjacent in the log under -j.
%.checked: %.silica
	@cd "$(THIS_DIR)" && mkdir -p "$(LEAF_SANDBOX)" && \
	( $(call LEAF_UNIT_RUN,$*) ) > "$(LEAF_SANDBOX)/$*.out" 2>&1; \
	cat "$(THIS_DIR)$(LEAF_SANDBOX)/$*.out"; rm -f "$(THIS_DIR)$(LEAF_SANDBOX)/$*.out"

positive-integrate: silica.config
	@echo "$(MSG_PREFIX)positive-integrate: starting..."
	@cd "$(THIS_DIR)" || exit 1; \
	$(INTEGRATE_PRE_CLEAN); \
	$(INSTALL_SDS_STDLIB_OBJS); \
	$(TRIAL_CACHE_RESTORE); \
	if [ ! -s silica.config ]; then \
		echo "SKIP: $(MSG_PREFIX)no positive trials"; \
		printf '%d %d\n' 0 0 > .integrate_counts; \
		exit 0; \
	fi; \
	$(ENSURE_SILICA_COMPILER); \
	mkdir -p "$(LEAF_SANDBOX)"; : > .integrate_results; \
	$(LEAF_COMPILE_LIBS); \
	$(LEAF_ASSEMBLE_LIBS); \
	$(LEAF_POST_LIB_HOOK); \
	nunits=$$(printf '%s\n' $(LEAF_UNITS) | grep -c .); \
	echo "$(MSG_PREFIX)per-unit compile: $$nunits unit(s), each as its own application"
	@[ -s "$(THIS_DIR)silica.config" ] || exit 0; \
	cd "$(THIS_DIR)" && $(MAKE) --no-print-directory -k -f "$(INTEGRATE_MAKEFILE)" $(LEAF_UNIT_STAMPS) || true
	@cd "$(THIS_DIR)" || exit 1; \
	[ -s silica.config ] || exit 0; \
	$(TRIAL_CACHE_STORE); \
	rm -rf "$(LEAF_SANDBOX)"; \
	ok=$$(grep -c '^PASS' .integrate_results); ko=$$(grep -c '^FAIL' .integrate_results); \
	asc_ok=$$(grep -c '^ASCOK' .integrate_results); asc_warn=$$(grep -c '^FAIL.*\.ascomp' .integrate_results); \
	xt=$$(grep -c '^XTARGET' .integrate_results); \
	missing=0; \
	for u in $(LEAF_UNITS); do [ -f "$${u%.silica}.checked" ] || missing=$$((missing + 1)); done; \
	if [ "$$missing" -ne 0 ]; then \
		echo "❌❌ $(MSG_PREFIX)$$missing unit(s) never completed (make aborted; see the log)"; \
		$(INTEGRATE_DOT_FAIL); \
		ko=$$((ko + missing)); \
	fi; \
	echo "$(MSG_PREFIX)assembly: $$asc_ok matched .ascomp, $$asc_warn differed or missing"; \
	if [ "$$xt" -ne 0 ]; then \
		echo "$(MSG_PREFIX)$$xt unit(s) compiled for $(SILICA_EMIT_TARGET); not assembled, not run, and not compared against .ascomp, which holds $(SILICA_HOST_EMIT_TARGET) assembly"; \
		ok=$$((ok + xt)); \
	fi; \
	printf '%d %d\n' "$$ok" "$$ko" > .integrate_counts; \
	[ "$$ko" -eq 0 ]

integrate-run: positive-integrate

record-positive-golden: silica.config
	@echo "$(MSG_PREFIX)record-positive-golden: starting..."
	@$(ENSURE_SILICA_COMPILER)
	@$(INTEGRATE_PRE_CLEAN)
	@cd "$(THIS_DIR)" && $(INSTALL_SDS_STDLIB_OBJS) && $(SEED_SDS_COMPILE_ORDER)
	@cd "$(THIS_DIR)" && $(RUN_SILICA_COMPILER)
	@cd "$(THIS_DIR)" && $(INSTALL_SDS_STDLIB_OBJS)
	@cd "$(THIS_DIR)" && for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		[ "$$base" = "__silica_runtime" ] && continue; \
		cp "$$sams" "$$base$(ASCOMP_EXT)"; \
		echo "Recorded $$base$(ASCOMP_EXT)"; \
	done
	@cd "$(THIS_DIR)" && for sams in *.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$${sams%.sams}; \
		[ "$$base" = "__silica_runtime" ] && continue; \
		$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "$$base.o"; \
	done
	@if [ -f "$(THIS_DIR)__silica_runtime.sams" ]; then \
		$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$(THIS_DIR)__silica_runtime.sams" -o "$(THIS_DIR)__silica_runtime.o"; \
	fi
	@cd "$(THIS_DIR)" && for sams in lib/*.sams; do \
		[ -f "$$sams" ] || continue; \
		base=$$(basename "$$sams" .sams); \
		if [ -n "$(SDS_STDLIB_CACHE)" ] && [ -f "$(SDS_STDLIB_CACHE)/lib/$$base.o" ]; then \
			cp -f "$(SDS_STDLIB_CACHE)/lib/$$base.o" "lib/$$base.o"; \
			continue; \
		fi; \
		$(ASSEMBLER) $(ASFLAGS_macos) -c -x assembler "$$sams" -o "lib/$$base.o"; \
	done
	@cd "$(THIS_DIR)" || exit 1; \
	lib_objs=""; \
	for obj in lib/*.o; do [ -f "$$obj" ] && lib_objs="$$lib_objs $$obj"; done; \
	rust_sysroot=$$(rustc --print sysroot 2>/dev/null); \
	rust_target=$$(rustc -vV 2>/dev/null | sed -n 's/^host: //p'); \
	rust_lld="$$rust_sysroot/lib/rustlib/$$rust_target/bin/rust-lld"; \
	macos_sdk=$$(xcrun --sdk macosx --show-sdk-path 2>/dev/null); \
	for trial in $(POSITIVE_SILICA); do \
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
	@cd "$(THIS_DIR)" && for trial in $(POSITIVE_SILICA); do \
		base=$${trial%.silica}; \
		rm -f "$$base" "$$base.o"; \
	done
	@cd "$(THIS_DIR)" && rm -f __silica_runtime.o lib/*.o *.iface lib/*.iface *.sams lib/*.sams *.sout .integrate_counts
	@echo "✅ $(MSG_PREFIX)record-positive-golden complete"

record-golden: record-positive-golden

clean:
	@echo "$(MSG_PREFIX)clean: removing prior artifacts..."
	@cd "$(THIS_DIR)" && for s in *.sams; do \
		[ -f "$$s" ] || continue; \
		rm -f "$${s%.sams}"; \
	done
	@cd "$(THIS_DIR)" && rm -f *.sams lib/*.sams *.o lib/*.o *.iface lib/*.iface __silica_runtime.o __silica_runtime.sams.* *.checked .integrate_results smoke_harness_ready *.sout silica.config .integrate_counts silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link
	@cd "$(THIS_DIR)" && rm -rf $(LEAF_SANDBOX)
	@echo "✅ $(MSG_PREFIX)Clean complete"

help:
	@echo "Phase 1 leaf trial Makefile ($(TRIAL_DIR))"
	@echo "  all / executables  - build positive trials"
	@echo "  integrate          - compile each unit in its own sandbox (parallel), diff .ascomp, run, diff .scout; then report"
	@echo "  record-positive-golden - capture .ascomp and .scout from current compiler"
	@echo "  record-golden          - alias for record-positive-golden"
	@echo "  clean              - remove build artifacts"
