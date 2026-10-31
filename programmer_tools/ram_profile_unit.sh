#!/bin/sh
# RAM profile of the compiler's own build: one tsv per build, one row per unit.
#
#   ram_profile_unit.sh --init <compiler> <units> <jobs> <make-cmdline>
#       Creates benchmarking/memory_use_reports/data/<UTC timestamp>_<compiler basename>.tsv
#       (never overwrites; a clash gets a -2, -3 ... suffix), writes the header
#       comment block and the column line, and prints the file path on stdout.
#       Prints nothing (and exits 0) when SILICA_RAM_PROFILE=0 or the file cannot
#       be created (one warning line on stderr).
#
#   ram_profile_unit.sh <compiler> [args...]
#       Runs the compiler exactly as given (same args, stdio, exit code) and, if
#       $SILICA_RAM_PROFILE_FILE is set, samples its physical footprint about once
#       a second and appends one row per unit it finished. Units are read from
#       silica.compile.order in the current directory (the compiler removes the
#       lines it finished), as the Makefile batch loop does. Exit 75 (reclaim the
#       heap, run me again) is recorded as exit 0.
#
# Columns: unit lines bytes exit seconds peak_footprint_MB sampling_pid
# Peak: macOS vmmap 'Physical footprint (peak)'; Linux VmHWM. NA when unavailable.
# The profile never fails the build: every profile step ignores its own errors.

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
OUTDIR=${SILICA_RAM_PROFILE_DIR:-$ROOT/benchmarking/memory_use_reports/data}

warn() { echo "ram_profile: warning: $*" >&2; }

if [ "$1" = "--init" ]; then
	[ "${SILICA_RAM_PROFILE:-1}" = "0" ] && exit 0
	comp=$2; units=$3; jobs=$4; cmdline=$5
	name=$(basename "$comp")
	mkdir -p "$OUTDIR" 2>/dev/null || { warn "cannot create $OUTDIR; profile disabled"; exit 0; }
	ts=$(date -u +%Y%m%dT%H%M%SZ)
	f="$OUTDIR/${ts}_${name}.tsv"; n=1
	while ! ( set -C; : > "$f" ) 2>/dev/null; do
		n=$((n + 1)); f="$OUTDIR/${ts}_${name}-$n.tsv"
		if [ "$n" -gt 99 ]; then warn "cannot create a unique profile file; profile disabled"; exit 0; fi
	done
	if command -v sha256sum >/dev/null 2>&1; then sha=$(sha256sum "$comp" 2>/dev/null | cut -d' ' -f1)
	else sha=$(shasum -a 256 "$comp" 2>/dev/null | cut -d' ' -f1); fi
	mem=$(sysctl -n hw.memsize 2>/dev/null)
	[ -z "$mem" ] && mem=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo 2>/dev/null)
	head=$(git -C "$ROOT" rev-parse --short=10 HEAD 2>/dev/null)
	cmdline=$(printf '%s' "$cmdline" | tr '\n\t' '  ')
	{
		echo "# date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "# host: $(hostname)"
		echo "# git_head: ${head:-unknown}"
		echo "# compiler: $comp"
		echo "# compiler_sha256: ${sha:-unknown}"
		echo "# hw_memsize_bytes: ${mem:-unknown}"
		echo "# jobs: $jobs"
		echo "# units: $units"
		echo "# command: $cmdline (peak = max of vmmap 'Physical footprint (peak)' sampled every 1 s; Linux VmHWM)"
		printf 'unit\tlines\tbytes\texit\tseconds\tpeak_footprint_MB\tsampling_pid\n'
	} >> "$f" 2>/dev/null || { warn "cannot write $f; profile disabled"; rm -f "$f" 2>/dev/null; exit 0; }
	echo "$f"
	exit 0
fi

PROF=${SILICA_RAM_PROFILE_FILE:-}
if [ "${SILICA_RAM_PROFILE:-1}" = "0" ] || [ -z "$PROF" ]; then
	exec "$@"
fi

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time' 2>/dev/null || date +%s; }

# Units still queued before this process runs.
before=$(cat silica.compile.order 2>/dev/null)
t0=$(now)
"$@" <&0 &
pid=$!
tmp=$(mktemp "${TMPDIR:-/tmp}/ramprof.XXXXXX" 2>/dev/null)
sample_one() {
	if [ -r "/proc/$pid/status" ]; then
		awk '/^VmHWM:/{printf "%.1f\n", $2/1024; exit}' "/proc/$pid/status" 2>/dev/null
	else
		vmmap -summary "$pid" 2>/dev/null | awk -F': *' '/Physical footprint \(peak\)/{print $2; exit}' | awk '{
			v=$1; n=v+0; u=v; sub(/^[0-9.]+/, "", u);
			if (u ~ /^G/) printf "%.1f\n", n*1024; else if (u ~ /^M/) printf "%.1f\n", n;
			else if (u ~ /^K/) printf "%.2f\n", n/1024; else printf "%.4f\n", n/1048576 }'
	fi
}
sampler=
if [ -n "$tmp" ]; then
	( while kill -0 "$pid" 2>/dev/null; do
		p=$(sample_one)
		[ -n "$p" ] && echo "$p" >> "$tmp"
		sleep 1
	done ) >/dev/null 2>&1 &
	sampler=$!
fi
wait "$pid"; ec=$?
t1=$(now)
[ -n "$sampler" ] && wait "$sampler" 2>/dev/null
secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}' 2>/dev/null)
peak=
[ -n "$tmp" ] && peak=$(sort -n "$tmp" 2>/dev/null | tail -1)
[ -n "$tmp" ] && rm -f "$tmp"
[ -z "$peak" ] && peak=NA

# Attribute the process to the units it finished (normally one); else the head unit.
if [ -n "$before" ]; then
	nb=$(printf '%s\n' "$before" | wc -l | tr -d ' ')
	na=$(wc -l < silica.compile.order 2>/dev/null | tr -d ' ')
	[ -z "$na" ] && na=0
	consumed=$((nb - na))
	if [ "$consumed" -gt 0 ]; then done_units=$(printf '%s\n' "$before" | head -n "$consumed")
	else done_units=$(printf '%s\n' "$before" | head -n 1); fi
	rec=$ec; [ "$ec" -eq 75 ] && rec=0
	printf '%s\n' "$done_units" | while IFS= read -r u; do
		[ -z "$u" ] && continue
		l=$(wc -l < "$u" 2>/dev/null | tr -d ' '); b=$(wc -c < "$u" 2>/dev/null | tr -d ' ')
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$u" "${l:-NA}" "${b:-NA}" "$rec" "$secs" "$peak" "$pid" >> "$PROF" 2>/dev/null \
			|| { warn "cannot append to $PROF"; break; }
	done
fi
exit "$ec"
