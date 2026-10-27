#!/bin/sh
# Batch compile that isolates a rejected unit instead of losing the whole suite.
#
#   compile_isolating.sh <compiler>      (cwd = the suite directory holding silica.config)
#
# Lee's rule: no set of trials fails because one trial in the set fails. A suite compiles all of its
# units in one compiler run, and the compiler stops at the first unit it rejects (syntax error, type
# error, effect error, ... or a hang or crash), so before this script one bad unit meant no unit of
# the suite produced output. Now:
#
#   1. The whole configuration is compiled in one run (the process-per-unit reclaim loop: exit 75 and
#      76 mean "continue"). The all-good case costs exactly what it always did.
#   2. When the run fails, the unit the compiler named (the `file:` line of its SILICA-ERROR-METADATA
#      block, else the unit recorded in silica.compile.inprogress for a hang) is taken out of
#      silica.config, its error is recorded, and the rest compiles again. Repeat until a run
#      succeeds. The remaining units keep their order and their names, so their output is the output
#      they would have had; only the application's atom/shape tables lose what the rejected unit alone
#      contributed.
#   3. silica.config is put back to the full list when the run ends.
#
# Outputs, all in the cwd and all recreated by every run:
#   silica.compile.rejected      one line per rejected unit: <unit>TAB<exit status>TAB<one-line reason>
#   silica.compile.rejected.d/   <unit basename>.txt: the compiler's error text for that unit
# The harness (INTEGRATE_COMPILE_REJECTS in silica_compiler.mk) reports each rejected unit as one
# failure of that unit's own trial and counts it once.
#
# Exit status: 0 when the final run succeeded (with or without rejected units); non-zero (the
# compiler's status) only when a failure could not be attributed to a unit named in silica.config
# (the compiler is missing, it died with no marker, the error names a file outside the suite). The
# caller then fails the whole suite exactly as before.
#
# Knobs: SILICA_COMPILE_TIMEOUT (seconds per compiler process, default 900),
#        SILICA_ISOLATE_MAX (most units isolated in one suite run, default 200).

comp=$1
timeout=${SILICA_COMPILE_TIMEOUT:-900}
maxiso=${SILICA_ISOLATE_MAX:-200}
tab=$(printf '\t')

if [ -z "$comp" ] || [ ! -f silica.config ]; then
	echo "compile_isolating.sh: usage: compile_isolating.sh <compiler> (in a directory with silica.config)" >&2
	exit 2
fi

rm -rf silica.compile.rejected silica.compile.rejected.d silica.config.full
cp silica.config silica.config.full || exit 2
log=silica.compile.attempt.log
rcfile=silica.compile.attempt.rc
isolated=0

# One batch: the reclaim loop. Streams the compiler's output (so the run's log has it) and keeps a copy
# in $log for attribution. Leaves the final status in $rcfile.
run_batch() {
	rm -f silica.compile.inprogress silica.compile.crashed "$log" "$rcfile"
	{
		while :; do
			perl -e 'alarm shift @ARGV; exec @ARGV' "$timeout" "$comp"
			ec=$?
			if [ "$ec" -eq 0 ]; then break; fi
			if [ "$ec" -eq 75 ] || [ "$ec" -eq 76 ]; then
				echo "  (reclaiming memory; continuing next unit)"
				continue
			fi
			if [ "$ec" -eq 142 ]; then
				echo "compiler TIMED OUT after ${timeout}s (compile hang)"
			fi
			break
		done
		echo "$ec" > "$rcfile"
	} 2>&1 | tee "$log"
	rc=$(cat "$rcfile" 2>/dev/null || echo 1)
	return 0
}

restore_config() {
	cp silica.config.full silica.config
	rm -f silica.config.full "$log" "$rcfile"
}

while :; do
	run_batch
	if [ "$rc" -eq 0 ]; then
		restore_config
		exit 0
	fi

	# Attribute the failure to a unit of silica.config.
	named=$(sed -n 's/^file: //p' "$log" | tail -n 1)
	[ -n "$named" ] || named=$(cat silica.compile.inprogress 2>/dev/null | head -n 1)
	unit=""
	if [ -n "$named" ]; then
		nbase=${named##*/}
		# Exact config line first, then the same path or base name.
		unit=$(awk -v n="$named" '$0 == n { print; exit }' silica.config)
		[ -n "$unit" ] || unit=$(awk -v b="$nbase" '{ p = $0; sub(/.*\//, "", p); if (p == b) { print; exit } }' silica.config)
	fi
	if [ -z "$unit" ] || [ "$isolated" -ge "$maxiso" ]; then
		echo "compile_isolating.sh: compiler failed (status $rc) and no unit of silica.config could be blamed (named: '${named:-none}'); the suite cannot be isolated" >&2
		restore_config
		exit "$rc"
	fi

	code=$(sed -n 's/^errorCode: //p' "$log" | tail -n 1)
	line=$(sed -n 's/^line: //p' "$log" | tail -n 1)
	col=$(sed -n 's/^column: //p' "$log" | tail -n 1)
	if [ -n "$code" ]; then
		reason="compile error $code at line ${line:-?} column ${col:-?}"
	elif [ "$rc" -eq 142 ]; then
		reason="compiler timed out after ${timeout}s"
	else
		reason="compiler exited with status $rc"
	fi
	mkdir -p silica.compile.rejected.d
	ubase=${unit##*/}
	# Error text: from the first "Compilation error"-style line to the end, without the long
	# instructions for AI agents the compiler appends (numbered lines and lettered sub-steps).
	awk '/^❌ Compilation error|^❌/ { on = 1 } on { print }' "$log" \
		| grep -v '^[0-9])\|^[A-D]) \|^There is an uncategorized\|^If you are an LLM' \
		| head -n 30 > "silica.compile.rejected.d/$ubase.txt"
	[ -s "silica.compile.rejected.d/$ubase.txt" ] || tail -n 15 "$log" > "silica.compile.rejected.d/$ubase.txt"
	printf '%s\t%s\t%s\n' "$unit" "$rc" "$reason" >> silica.compile.rejected
	echo "compile_isolating.sh: $unit rejected ($reason); compiling the remaining units"

	awk -v u="$unit" '$0 != u' silica.config > silica.config.next && mv silica.config.next silica.config
	isolated=$((isolated + 1))
	if [ ! -s silica.config ]; then
		restore_config
		exit 0
	fi
	# Start the next run from the state a first run starts from.
	rm -f ./*.sams ./*.iface silica.compile.order silica.needs_runtime silica.atoms silica.shapes silica.link __silica_runtime.sams
	if [ -d .trial_stdlib ]; then rm -f .trial_stdlib/*.sams .trial_stdlib/*.iface; fi
done
