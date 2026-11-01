#!/bin/sh
# Per-stage wall-clock timing for ONE silica-compiler invocation (one compilation unit).
#
# The compiler already announces each pipeline stage on stdout ("Lexing...",
# "Type checking...", "Emitting...", ...). This attributes elapsed wall time to
# each of those stages, so you can see where a unit's time actually goes without
# adding any instrumentation to the compiler itself.
#
# Works against any build: the Rust bootstrap, the seed, or the self-hosted
# compiler. Use it to compare them on the same unit.
#
# Usage, from a directory containing silica.config and silica.compile.order:
#   stage_timing.sh                       # uses binaries/silica-compiler
#   stage_timing.sh /path/to/some-compiler
#
# Note: the compiler exits 75 between units to reclaim memory. This script runs
# it ONCE on purpose, so the numbers describe a single unit. Point
# silica.compile.order at the one unit you want to profile.
set -u

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
COMPILER=${1:-$REPO_ROOT/binaries/silica-compiler}

if [ ! -x "$COMPILER" ]; then
	echo "stage_timing: not executable: $COMPILER" >&2
	exit 2
fi
if [ ! -s silica.config ]; then
	echo "stage_timing: no silica.config in $(pwd)" >&2
	exit 2
fi

echo "compiler: $COMPILER"
echo "unit(s):  $(tr '\n' ' ' < silica.compile.order 2>/dev/null || echo '(whole config)')"
echo

# perl for timestamps: macOS /bin/date has no %N.
"$COMPILER" 2>&1 | perl -ne '
    use Time::HiRes qw(time);
    BEGIN { $start = time; $prev = $start; @rows = (); }
    chomp;
    next if /^\s*$/;
    my $now = time;
    push @rows, [$now - $prev, $_];
    $prev = $now;
    END {
        # A stage label owns the time between it and the next line printed.
        printf "%9s  %s\n", "SECONDS", "STAGE";
        printf "%9s  %s\n", "-------", "-----";
        for my $i (0 .. $#rows - 1) {
            my $dur   = $rows[$i + 1][0];
            my $label = $rows[$i][1];
            $label =~ s/^\s+|\s+$//g;
            next if $dur < 0.005 && $label !~ /\.\.\.$/;
            printf "%9.2f  %s\n", $dur, $label;
        }
        printf "%9s  %s\n", "-------", "-----";
        printf "%9.2f  TOTAL\n", $prev - $start;
    }
'
ec=$?
echo
echo "(exit $ec; 75 = unit done, more units remain in silica.compile.order)"
