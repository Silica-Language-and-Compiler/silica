#!/bin/sh
# Compile shared lib/*.silica once, then each trial as its own silica-compiler
# application (one process per remaining unit so RSS resets).
#
# silica.config keeps every unit so `use` resolves. Units that already have a
# sibling .iface (stdlib cache or a lib compiled earlier in this integrate) are
# left out of silica.compile.order and are not re-emitted; the prebuilt .o is
# linked later.
#
# The driver only honors a caller-written silica.compile.order when silica.config
# holds more than 32 units; at or below that it deletes the order and compiles
# every listed unit. Trimming silica.config to {libs, one trial} therefore costs
# a full rebuild of the libs on every trial, so the full list stays in place
# whenever it clears the threshold.
#
# Usage (from wbt_core/): SILICA_COMPILER=... ./compile_per_trial.sh
set -eu

MSG_PREFIX=${MSG_PREFIX:-standard_data_structures_phase1/wbt_core/}
SILICA_COMPILER=${SILICA_COMPILER:?SILICA_COMPILER is required}

if [ ! -s silica.config ]; then
	echo "SKIP: ${MSG_PREFIX}no silica.config"
	exit 0
fi

cp silica.config silica.config.full
cleanup() {
	mv -f silica.config.full silica.config 2>/dev/null || true
	rm -f .compile_trials.list .compile_libs.list .compile_pending.list
}
trap cleanup EXIT INT TERM

grep -v '^lib/' silica.config.full | grep -v '^$' > .compile_trials.list || true
grep '^lib/' silica.config.full > .compile_libs.list || true

# Content-addressed compile cache: restore .sams/.iface for units whose source and
# compiler are unchanged. A restored .iface makes pending_units() skip that lib and
# the phase-2 loop skip that trial, so the compiler is never launched for it.
TRIAL_CACHE_SH=${TRIAL_CACHE_SH:-../trial_cache.sh}
if [ -f "$TRIAL_CACHE_SH" ]; then
	MSG_PREFIX="$MSG_PREFIX" SILICA_COMPILER="$SILICA_COMPILER" \
		sh "$TRIAL_CACHE_SH" restore || true
fi

total_trials=0
if [ -s .compile_trials.list ]; then
	total_trials=$(grep -c '.' .compile_trials.list)
fi

full_units=$(grep -c '.' silica.config.full || true)
keep_full_config=0
if [ "$full_units" -gt 32 ]; then
	keep_full_config=1
fi

# Narrows silica.config only when the full list would fall under the threshold
# that makes the driver ignore silica.compile.order.
write_config() {
	if [ "$keep_full_config" -eq 1 ]; then
		cp silica.config.full silica.config
	else
		{
			cat .compile_libs.list
			if [ $# -gt 0 ]; then
				printf '%s\n' "$1"
			fi
		} > silica.config
	fi
}

# Units that still need a compile this integrate (no sibling .iface yet).
pending_units() {
	: > .compile_pending.list
	while IFS= read -r f || [ -n "$f" ]; do
		[ -n "$f" ] || continue
		if [ ! -f "${f%.silica}.iface" ]; then
			printf '%s\n' "$f" >> .compile_pending.list
		fi
	done
}

run_compiler() {
	label=$1
	expected_units=$2
	prev_left=-1
	stalls=0
	rm -f silica.compile.inprogress silica.compile.crashed
	while true; do
		set +e
		"${SILICA_COMPILER}"
		ec=$?
		set -e
		if [ "$ec" -eq 0 ]; then
			return 0
		fi
		if [ "$ec" -eq 75 ] || [ "$ec" -eq 76 ]; then
			if [ -s silica.compile.order ]; then
				left=$(grep -c '.' silica.compile.order)
			elif [ -f silica.compile.order ]; then
				left=0
			else
				left=$expected_units
			fi
			echo "  ${MSG_PREFIX}reclaim; units left in ${label}: ${left}/${expected_units}"
			if [ "$prev_left" -ge 0 ] && [ "$left" -ge "$prev_left" ]; then
				stalls=$((stalls + 1))
				if [ "$stalls" -ge 3 ]; then
					echo "❌❌ ${MSG_PREFIX}compile order not shrinking for ${label} (stuck at ${left} units)"
					return 75
				fi
			else
				stalls=0
			fi
			prev_left=$left
			continue
		fi
		return "$ec"
	done
}

# --- Phase 1: each lib/*.silica once (stdlib ifaces from the suite cache skip here) ---
if [ ! -s .compile_libs.list ]; then
	echo "${MSG_PREFIX}no lib units"
else
write_config
pending_units < .compile_libs.list
lib_pending=0
if [ -s .compile_pending.list ]; then
	lib_pending=$(grep -c '.' .compile_pending.list)
fi
if [ "$lib_pending" -gt 0 ]; then
	echo "${MSG_PREFIX}compiling ${lib_pending} lib unit(s) once for this integrate"
	cp .compile_pending.list silica.compile.order
	rm -f silica.needs_runtime
	set +e
	run_compiler "lib units" "$lib_pending"
	ec=$?
	set -e
	if [ "$ec" -ne 0 ]; then
		if [ "$ec" -eq 137 ] || [ "$ec" -eq 9 ]; then
			echo "❌❌ ${MSG_PREFIX}compilation killed (exit ${ec}; likely OOM while compiling lib units)"
		else
			echo "❌❌ ${MSG_PREFIX}compilation failed (exit ${ec}) while compiling lib units"
		fi
		exit 1
	fi
	echo "${MSG_PREFIX}lib units compiled; later trials will reuse their .o files"
	# The lib units' atom numbering; every trial starts from it, so a trial's atom indices
	# depend on the libs and itself only, not on the trials compiled before it.
	cp silica.atoms .compile_libs.atoms 2>/dev/null || true
else
	echo "${MSG_PREFIX}all lib units already have .iface; reusing .o files"
fi
fi

# --- Phase 2: each trial only (libs stay in silica.config for `use` / iface lookup) ---
echo "${MSG_PREFIX}per-trial compile: ${total_trials} trial(s); each trial reuses lib .o files"

cached_count=0
done_count=0
fail_ec=0
trial_index=0
trial=""

while IFS= read -r trial || [ -n "$trial" ]; do
	[ -n "$trial" ] || continue
	trial_index=$((trial_index + 1))
	if [ -f "${trial%.silica}.iface" ]; then
		echo "${MSG_PREFIX}trial ${trial_index}/${total_trials}: ${trial} (cached)"
		done_count=$((done_count + 1))
		cached_count=$((cached_count + 1))
		continue
	fi
	write_config "$trial"
	echo "${MSG_PREFIX}trial ${trial_index}/${total_trials}: ${trial} (trial unit only)..."
	rm -f silica.needs_runtime
	if [ -f .compile_libs.atoms ]; then cp .compile_libs.atoms silica.atoms; else rm -f silica.atoms; fi
	printf '%s\n' "$trial" > silica.compile.order
	set +e
	run_compiler "$trial" 1
	fail_ec=$?
	set -e
	if [ "$fail_ec" -ne 0 ]; then
		break
	fi
	echo "${MSG_PREFIX}trial ${trial_index}/${total_trials}: ${trial} done"
	done_count=$((done_count + 1))
done < .compile_trials.list

if [ "$fail_ec" -ne 0 ]; then
	if [ "$fail_ec" -eq 137 ] || [ "$fail_ec" -eq 9 ]; then
		echo "❌❌ ${MSG_PREFIX}compilation killed (exit ${fail_ec}; likely OOM while compiling a trial)"
	else
		echo "❌❌ ${MSG_PREFIX}compilation failed (exit ${fail_ec}) on trial ${trial_index}/${total_trials}: ${trial:-?}"
	fi
	exit 1
fi

if [ -f "$TRIAL_CACHE_SH" ]; then
	cp silica.config.full silica.config
	MSG_PREFIX="$MSG_PREFIX" SILICA_COMPILER="$SILICA_COMPILER" \
		sh "$TRIAL_CACHE_SH" store || true
fi

echo "${MSG_PREFIX}Compiled ${done_count}/${total_trials} trial(s) as separate applications (${cached_count} from cache)"
