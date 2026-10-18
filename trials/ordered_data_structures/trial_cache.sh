#!/bin/sh
# Content-addressed compile cache for standard_data_structures leaves.
#
# Every trial that says `use wbt_set; use wbt_map;` pays ~115s to re-derive those
# modules from source, and `INTEGRATE_PRE_CLEAN` throws the result away before the
# next integrate. Nothing about that work depends on anything but the compiler and
# the source it reads, so it is cacheable.
#
# Cache key for a unit = sha256 of
#   - the silica-compiler binary (symlink resolved: a new seed invalidates everything)
#   - that unit's own source
#   - every lib/*.silica in the leaf (the whole dependency surface; trials never
#     `use` each other, only lib modules, so this covers what the unit can see)
#   - the atom/shape table basis the leaf starts from: the content of
#     $SDS_STDLIB_CACHE/silica.{atoms,shapes} when the root integrate installs the
#     prebuilt stdlib objects, or "standalone" when the leaf compiles its own lib/.
#     A unit's .sams holds atom indices from the table it was compiled under, so a
#     unit cached by a standalone run (lib/trial_support_int64 numbering :no_reply
#     from 23) must never be restored next to stdlib objects whose table gave 23 to
#     :less. Different basis, different key.
#
# On a hit we restore the unit's .sams AND .iface. Restoring the .iface is what
# makes the hit take effect: SEED_SDS_COMPILE_ORDER (leaf.mk) and pending_units()
# (compile_per_trial.sh) both build the compile order from units that lack a
# sibling .iface, so a restored unit drops out of the order with no other change.
#
# The gate is NOT weakened. A restored .sams is still diffed against its .ascomp
# golden, still assembled, still linked, and the executable is still run and its
# output diffed against .scout. We skip re-deriving assembly we can prove is
# byte-identical; we do not skip checking it.
#
# Usage (from a leaf directory, alongside silica.config):
#   trial_cache.sh restore    # populate .sams/.iface for unchanged units
#   trial_cache.sh store      # record outputs of units compiled this run
#   trial_cache.sh key <unit.silica>
set -eu

CACHE_DIR=${TRIAL_CACHE_DIR:-.trial_cache}
MSG_PREFIX=${MSG_PREFIX:-}
SILICA_COMPILER=${SILICA_COMPILER:?SILICA_COMPILER is required}

# Disable with TRIAL_CACHE=0 to force a full recompile.
if [ "${TRIAL_CACHE:-1}" = "0" ]; then
	exit 0
fi

hash_file() {
	# shasum follows symlinks, so lib/*.silica hash their stdlib targets.
	[ -f "$1" ] || { printf 'missing\n'; return 0; }
	shasum -a 256 "$1" | cut -d' ' -f1
}

# The table basis (see the key comment above). Mirrors the condition under which
# leaf.mk's INSTALL_SDS_STDLIB_OBJS installs the stdlib cache's objects and tables.
table_basis() {
	if [ -n "${SDS_STDLIB_CACHE:-}" ] && [ -d "$SDS_STDLIB_CACHE/lib" ]; then
		printf 'stdlib-cache atoms %s shapes %s\n' \
			"$(hash_file "$SDS_STDLIB_CACHE/silica.atoms")" "$(hash_file "$SDS_STDLIB_CACHE/silica.shapes")"
	else
		printf 'standalone\n'
	fi
}

# Hash of the compiler binary, the table basis, and every lib source in this leaf.
# Computed once per invocation and reused for all units, since it is the same for all.
compute_base_hash() {
	{
		hash_file "$SILICA_COMPILER"
		table_basis
		if [ -d lib ]; then
			for f in lib/*.silica; do
				[ -e "$f" ] || continue
				printf '%s %s\n' "$(basename "$f")" "$(hash_file "$f")"
			done | sort
		fi
	} | shasum -a 256 | cut -d' ' -f1
}

unit_key() {
	printf '%s %s\n' "$BASE_HASH" "$(hash_file "$1")" | shasum -a 256 | cut -d' ' -f1
}

# .trial_cache/<flattened unit path>/<key>.{sams,iface}
unit_cache_dir() {
	printf '%s/%s\n' "$CACHE_DIR" "$(printf '%s' "${1%.silica}" | tr '/' '_')"
}

# Units this leaf builds, from silica.config (libs included).
units() {
	[ -s silica.config ] || return 0
	grep -v '^[[:space:]]*$' silica.config
}

BASE_HASH=$(compute_base_hash)

case "${1:-}" in
key)
	[ $# -ge 2 ] || { echo "usage: trial_cache.sh key <unit.silica>" >&2; exit 2; }
	unit_key "$2"
	;;

restore)
	hits=0
	misses=0
	for unit in $(units); do
		base=${unit%.silica}
		# Already satisfied (e.g. stdlib objects installed from .stdlib_cache).
		[ -f "$base.iface" ] && continue
		dir=$(unit_cache_dir "$unit")
		key=$(unit_key "$unit")
		if [ -f "$dir/$key.sams" ] && [ -f "$dir/$key.iface" ]; then
			cp -f "$dir/$key.sams" "$base.sams"
			cp -f "$dir/$key.iface" "$base.iface"
			# A trial's runtime module is sized by its own atom table (item J), so it is cached
			# with the unit; the leaf runtime stands in only for units that never had one.
			if [ -f "$dir/$key.runtime.sams" ]; then cp -f "$dir/$key.runtime.sams" "$base.runtime.sams"; fi
			hits=$((hits + 1))
		else
			misses=$((misses + 1))
		fi
	done
	# The per-leaf runtime is emitted by the compiler, not by any one unit, so it
	# is keyed on the compiler + all lib sources alone. Without this a run where
	# every unit hits would produce no __silica_runtime.sams to assemble.
	if [ -f "$CACHE_DIR/runtime/$BASE_HASH.sams" ] && [ ! -f "__silica_runtime.sams" ]; then
		cp -f "$CACHE_DIR/runtime/$BASE_HASH.sams" "__silica_runtime.sams"
	fi
	# The leaf's atom and shape tables go with the units compiled under them: a restored
	# .sams keeps indices from the table stored under this key, and every later sandbox
	# extends it. When anything was restored that table replaces the leaf's (the basis is
	# in the key, so it extends the stdlib cache's table the installed objects use); a
	# lib unit compiled now then extends it instead of reusing an index a restored unit
	# already holds.
	for f in atoms shapes; do
		if [ -f "$CACHE_DIR/runtime/$BASE_HASH.$f" ] && { [ "$hits" -gt 0 ] || [ ! -f "silica.$f" ]; }; then
			cp -f "$CACHE_DIR/runtime/$BASE_HASH.$f" "silica.$f"
		fi
	done
	echo "${MSG_PREFIX}compile cache: ${hits} reused, ${misses} to compile"
	;;

store)
	stored=0
	for unit in $(units); do
		base=${unit%.silica}
		[ -f "$base.sams" ] && [ -f "$base.iface" ] || continue
		dir=$(unit_cache_dir "$unit")
		key=$(unit_key "$unit")
		[ -f "$dir/$key.sams" ] && continue
		mkdir -p "$dir"
		# Drop stale keys for this unit so the cache stays bounded.
		rm -f "$dir"/*.sams "$dir"/*.iface "$dir"/*.runtime.sams 2>/dev/null || true
		cp -f "$base.sams" "$dir/$key.sams"
		cp -f "$base.iface" "$dir/$key.iface"
		if [ -f "$base.runtime.sams" ]; then cp -f "$base.runtime.sams" "$dir/$key.runtime.sams"; fi
		stored=$((stored + 1))
	done
	if [ -f "__silica_runtime.sams" ] && [ ! -f "$CACHE_DIR/runtime/$BASE_HASH.sams" ]; then
		mkdir -p "$CACHE_DIR/runtime"
		rm -f "$CACHE_DIR/runtime"/*.sams 2>/dev/null || true
		cp -f "__silica_runtime.sams" "$CACHE_DIR/runtime/$BASE_HASH.sams"
	fi
	# The tables are rewritten every store: they only grow, and the latest covers every unit
	# stored under this key.
	for f in atoms shapes; do
		if [ -f "silica.$f" ]; then mkdir -p "$CACHE_DIR/runtime"; cp -f "silica.$f" "$CACHE_DIR/runtime/$BASE_HASH.$f"; fi
	done
	[ "$stored" -gt 0 ] && echo "${MSG_PREFIX}compile cache: ${stored} unit(s) recorded"
	exit 0
	;;

*)
	echo "usage: trial_cache.sh {restore|store|key <unit.silica>}" >&2
	exit 2
	;;
esac
