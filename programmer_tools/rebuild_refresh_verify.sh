#!/usr/bin/env bash
# Rebuild, re-record the assembly goldens, and find out what is actually broken.
#
#   bash programmer_tools/rebuild_refresh_verify.sh                    # every machine it knows
#   bash programmer_tools/rebuild_refresh_verify.sh --targets apple_silicon_mac
#   bash programmer_tools/rebuild_refresh_verify.sh --skip-build       # sources unchanged since the last build
#   bash programmer_tools/rebuild_refresh_verify.sh --skip-build --use-build
#        # trials use each machine's compiler/build/<target>/silica-compiler instead of
#        # binaries/silica-compiler (for builds made with INSTALL_SELFHOST=0, which install nothing)
#   bash programmer_tools/rebuild_refresh_verify.sh --list
#
# On each OS-hosted platform, in order:
#   0. on a remote machine, rsync this repository there first, so it builds what you have in front of
#      you rather than whatever it happened to hold; --skip-sync trusts what is already there
#   0b. if a remote machine has no compiler of its own, send the newest matching native one from
#      this checkout's binaries/, and after a successful build copy the new one back here
#   1. build the compiler from compiler/src, after a clean, unless --skip-build
#   2. run the whole trial tree once, which is what produces the .sams the goldens come from
#   3. record the goldens, with programmer_tools/update_goldens.sh --apply, which refreshes only
#      trials whose run output already matched and never touches .scout or .golden_fail
#   4. run the whole tree again
# Step 4 is the answer you want: after step 3 every assembly-golden difference is gone, so what is
# left failing is a real behaviour difference, not a recorded expectation that went stale.
#
# With no --targets it asks which platforms to do, one question, and then asks for the connection of
# each hosted machine it does not already know. Connections are remembered in .silica_build_hosts in
# the repository root, the same file the build script writes, so it only asks once; --targets and
# --remote <target>=<user@host>[:<path>] skip the questions. --no-ask refuses to prompt at all.
# Every remote connection is public/private key ssh: the script runs ssh in batch mode and never types
# a password. Set a key up with ssh-keygen and ssh-copy-id, and check it with
# `ssh -o BatchMode=yes user@host true`.
# A raw target (ESP32-S3_raw) is built here as a cross compiler and its trials run on the board
# attached to this machine. It has no golden step: the board harness compares program output only,
# never assembly, so there is nothing to record. Its run needs the board plugged in, and it takes the
# same tree-wide lock as this machine's own run, so the two never overlap.
#
# Each platform prints a before line and an after line. The exit status is 0 only when every
# platform's second run passed.

set -uo pipefail

REPO="${SILICA_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$(dirname "${BASH_SOURCE[0]}")/sync_excludes.sh"
PLATFORM_MK="$REPO/project_makefiles/platform/platforms.mk"
HOSTS_FILE="${SILICA_BUILD_HOSTS:-$REPO/.silica_build_hosts}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_DIR="${LOG_DIR:-$REPO/../silica_refresh/$STAMP}"
DO_BUILD=1; USE_BUILD=0; LIST_ONLY=0; SELECTED=""; ASK=1; DO_SYNC=1
declare -a REMOTE_SPECS=()

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) DO_BUILD=0 ;;
        --skip-sync)  DO_SYNC=0 ;;
        --use-build)  USE_BUILD=1 ;;
        --list)       LIST_ONLY=1 ;;
        --targets)    SELECTED="$SELECTED $(echo "$2" | tr ',' ' ')"; ASK=0; shift ;;
        --no-ask)     ASK=0 ;;
        --remote)     REMOTE_SPECS+=("$2"); shift ;;
        --log-dir)    LOG_DIR="$2"; shift ;;
        -h|--help)    usage 0 ;;
        *)            echo "unknown argument: $1" >&2; usage 1 ;;
    esac
    shift
done

ask_table() { MAKEFLAGS= MAKELEVEL= make -s --no-print-directory -f "$PLATFORM_MK" "$1" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'; }
HOST_TARGET="$(ask_table host-emit-target)"
ALL_TARGETS="$(ask_table emit-targets)"
is_raw() { case "$1" in *_raw) return 0 ;; esac; return 1; }

declare -a R_T=() R_C=() R_P=()
add_remote() { local t="$1" spec="$2" c p; c="${spec%%:*}"; p="${spec#*:}"; [ "$p" = "$spec" ] && p="~/silica"; R_T+=("$t"); R_C+=("$c"); R_P+=("$p"); }
conn_of() { local i; [ ${#R_T[@]} -gt 0 ] || return 1; for i in $(seq 0 $((${#R_T[@]}-1))); do [ "${R_T[$i]}" = "$1" ] && { echo "${R_C[$i]}:${R_P[$i]}"; return 0; }; done; return 1; }

FILE_TARGETS=""
if [ -f "$HOSTS_FILE" ]; then
    while read -r t conn path; do
        case "$t" in ''|\#*) continue ;; esac
        FILE_TARGETS="$FILE_TARGETS $t"
        case "$conn" in local|ask|-|'') continue ;; esac
        add_remote "$t" "$conn:${path:-~/silica}"
    done < "$HOSTS_FILE"
fi
for spec in ${REMOTE_SPECS[@]+"${REMOTE_SPECS[@]}"}; do add_remote "${spec%%=*}" "${spec#*=}"; done

write_hosts_file() {  # $1 = target list
    local t conn path i
    {
        echo "# Silica build machines. One line per platform: <emit target> <user@host|local> <path>."
        echo "# Connections are public/private key ssh. Gitignored; never commit it."
        for t in $1; do
            conn=local; path=-
            if [ ${#R_T[@]} -gt 0 ]; then
                for i in $(seq 0 $((${#R_T[@]}-1))); do
                    [ "${R_T[$i]}" = "$t" ] && { conn="${R_C[$i]}"; path="${R_P[$i]}"; }
                done
            fi
            [ "$conn" = local ] && [ "$t" != "$HOST_TARGET" ] && ! is_raw "$t" && conn=ask
            echo "$t $conn $path"
        done
    } > "$HOSTS_FILE"
    chmod 600 "$HOSTS_FILE" 2>/dev/null
    echo "  remembered in $HOSTS_FILE (gitignored; never commit it)"
}

TARGETS="${SELECTED:-$FILE_TARGETS}"
REASK=0

# Something remembered: show it, and let it be changed rather than silently reused.
if [ -z "$SELECTED" ] && [ -n "$FILE_TARGETS" ] && [ "$ASK" = 1 ] && [ -t 0 ]; then
    echo
    echo "Remembered in $HOSTS_FILE:"
    for t in $FILE_TARGETS; do
        if [ "$t" = "$HOST_TARGET" ]; then echo "  $t   this machine"
        elif is_raw "$t"; then            echo "  $t   a board, connected to this machine"
        elif c=$(conn_of "$t"); then      echo "  $t   $c"
        else                              echo "  $t   no machine recorded"
        fi
    done
    printf '\nuse these? [Y/n]: '
    read -r keep
    case "$keep" in [Nn]*) REASK=1; TARGETS="" ;; esac
fi

# Nothing chosen and nothing remembered, or the remembered plan was rejected: ask, once.
if [ -z "$TARGETS" ] && [ "$ASK" = 1 ] && [ -t 0 ]; then
    echo
    echo "Which platforms? Enter numbers separated by spaces, or 'all'."
    i=0; CHOICES=""
    for t in $ALL_TARGETS; do
        i=$((i+1)); CHOICES="$CHOICES $t"
        if [ "$t" = "$HOST_TARGET" ]; then echo "  $i) $t   this machine"
        elif is_raw "$t"; then            echo "  $i) $t   a board, which must be plugged into this machine"
        else                              echo "  $i) $t   another machine, reached over ssh"
        fi
    done
    DEFAULT_PICKS="${FILE_TARGETS:-all}"
    printf '\nplatforms [%s]: ' "$(echo $DEFAULT_PICKS)"
    read -r picks
    if [ -z "$picks" ]; then
        if [ "$DEFAULT_PICKS" = all ]; then picks=all; else TARGETS="$DEFAULT_PICKS"; picks=""; fi
    fi
    if [ -z "$picks" ]; then
        :
    elif [ "$picks" = all ]; then
        TARGETS="$ALL_TARGETS"
    else
        for n in $picks; do
            sel=$(echo $CHOICES | awk -v k="$n" '{print $k}')
            [ -n "$sel" ] && TARGETS="$TARGETS $sel" || echo "  ignoring '$n'"
        done
    fi
fi
[ -n "$TARGETS" ] || TARGETS="$ALL_TARGETS"
# Hosted platforms first, raw last: the board run takes this machine's trial lock, and a cross build
# must not sit between a native build and its run.
PLAN=""; RAW_PLAN=""
for t in $TARGETS; do
    if is_raw "$t"; then RAW_PLAN="$RAW_PLAN $t"; else PLAN="$PLAN $t"; fi
done

# Ask for any hosted machine we do not know yet, and say what the connection has to be.
asked=0
if [ "$ASK" = 1 ] && [ -t 0 ]; then
    for t in $PLAN; do
        [ "$t" = "$HOST_TARGET" ] && continue
        known=$(conn_of "$t" 2>/dev/null || true)
        [ -n "$known" ] && [ "$REASK" = 0 ] && continue
        if [ "$asked" = 0 ]; then
            cat <<'EOF'

Each other OS-hosted platform builds and runs on its own machine, over ssh. The connection must be
public/private key ssh: this script runs ssh in batch mode and never types a password. Set one up
with `ssh-keygen` and `ssh-copy-id user@host`, then check it with `ssh -o BatchMode=yes user@host true`.
EOF
            asked=1
        fi
        if [ -n "$known" ]; then
            printf '\n%s machine, as user@host [%s]: ' "$t" "${known%%:*}"
        else
            printf '\n%s machine, as user@host (Enter to skip this platform): ' "$t"
        fi
        read -r c
        if [ -z "$c" ]; then
            [ -n "$known" ] && { echo "  keeping ${known%%:*}"; continue; }
            echo "  skipping $t"; continue
        fi
        if ssh -o BatchMode=yes -o ConnectTimeout=10 "$c" true >/dev/null 2>&1; then
            echo "  key-based ssh to $c works"
        else
            echo "  warning: ssh -o BatchMode=yes $c true failed; this platform will fail until the key is in place"
        fi
        defpath="~/silica"; [ -n "$known" ] && defpath="${known#*:}"
        printf '  repository path on %s [%s]: ' "$c" "$defpath"
        read -r rp; [ -n "$rp" ] || rp="$defpath"
        add_remote "$t" "$c:$rp"
        NEW_CONNS=1
    done
    if [ -n "$RAW_PLAN" ]; then
        echo
        for t in $RAW_PLAN; do
            echo "$t is a board: it must be connected to this machine before its trials run."
        done
        printf 'board connected? [Y/n]: '
        read -r yn
        case "$yn" in [Nn]*) echo "  dropping the board from this run"; RAW_PLAN="" ;; esac
    fi
    [ "${NEW_CONNS:-0}" = 1 ] && write_hosts_file "$PLAN $RAW_PLAN"
fi

echo "platforms : $PLAN${RAW_PLAN:+ $RAW_PLAN (board)}"
echo "build     : $([ "$DO_BUILD" = 1 ] && echo yes || echo 'no (--skip-build)')"
echo "logs      : $LOG_DIR"
[ -f "$HOSTS_FILE" ] || echo "note      : no $HOSTS_FILE, so remote machines are unknown; record them once with
            build_all_platforms.sh --set_targets \"<list>\", or pass --remote <target>=<user@host> here"
if [ "$LIST_ONLY" = 1 ]; then
    for t in $PLAN; do
        if [ "$t" = "$HOST_TARGET" ]; then echo "  $t: build and run here, then record goldens and run again"
        else echo "  $t: the same four steps on $(conn_of "$t" || echo '<no machine known>')"; fi
    done
    for t in $RAW_PLAN; do echo "  $t: cross compiler built here, trials run on the attached board, no goldens"; done
    exit 0
fi

mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/summary.tsv"; : > "$SUMMARY"
note() {  # platform, verdict, passed, failed, where
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$SUMMARY"
}
split_counts() {  # report file -> "passed failed"
    p=$(grep -m1 'success:' "$1" 2>/dev/null | tr -dc '0-9'); f=$(grep -m1 'fail:' "$1" 2>/dev/null | tr -dc '0-9')
    echo "${p:-?} ${f:-?}"
}
counts() { grep -m1 'success:' "$1" 2>/dev/null | tr -dc '0-9'; printf '/'; grep -m1 'fail:' "$1" 2>/dev/null | tr -dc '0-9'; }

overall=0
# Each platform is one function so the remote ones can run at the same time: they are different
# machines and nothing here is shared but this terminal. Their output is captured per platform and
# printed whole, in plan order, so two machines never interleave mid-sentence.
do_host() {
    local t="$1"
    if [ "$DO_BUILD" = 1 ]; then
        echo "  build"
        ( cd "$REPO/compiler/src" && make clean SILICA_TARGET_PROMPT=0 && make build SILICA_TARGET_PROMPT=0 ) \
            >"$LOG_DIR/$t-build.log" 2>&1 || { echo "  BUILD FAILED, see $LOG_DIR/$t-build.log"; note "$t" "BUILD FAILED" - - here; return 1; }
    fi
    echo "  first run"
    ( cd "$REPO/trials" && make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET=host ${USE_BUILD:+$( [ "$USE_BUILD" = 1 ] && echo "SILICA_COMPILER=$REPO/compiler/build/$t/silica-compiler")} ) >"$LOG_DIR/$t-run1.log" 2>&1
    echo "  before: $(counts "$REPO/trials/.integrate_report")"
    echo "  recording goldens"
    bash "$REPO/programmer_tools/update_goldens.sh" --targets "$t" --local-only --apply >"$LOG_DIR/$t-goldens.log" 2>&1
    grep -E 'golden\(s\) were WRITTEN|WOULD change' "$LOG_DIR/$t-goldens.log" | tail -1 | sed 's/^/  /'
    echo "  second run"
    ( cd "$REPO/trials" && make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET=host ${USE_BUILD:+$( [ "$USE_BUILD" = 1 ] && echo "SILICA_COMPILER=$REPO/compiler/build/$t/silica-compiler")} ) >"$LOG_DIR/$t-run2.log" 2>&1
    rc=$?
    echo "  after:  $(counts "$REPO/trials/.integrate_report")"
    strays=$(grep '❌❌ ' "$REPO/trials/.integrate_report" 2>/dev/null | grep -c '\[[A-Za-z0-9_-]*\] ')
    if [ "${strays:-0}" -gt 0 ]; then
        echo "  WARNING: $strays failure line(s) in this report carry another target's label, so they"
        echo "           came from an earlier board run, not from this host run. Treat the count above"
        echo "           as unreliable and read the per-suite reports instead."
    fi
    grep '❌❌ ' "$REPO/trials/.integrate_report" 2>/dev/null | grep -v '^fail:' | grep -v '\[[A-Za-z0-9_-]*\] ' | head -20 | sed 's/^/    /'
    set -- $(split_counts "$REPO/trials/.integrate_report")
    if [ $rc -eq 0 ]; then note "$t" PASS "$1" "$2" here; else note "$t" FAIL "$1" "$2" here; overall=1; fi
}

do_remote() {
    local t="$1"
    spec="$(conn_of "$t")" || { echo "  no machine known for $t; give it with --remote $t=user@host"; note "$t" "NO MACHINE" - - -; return 1; }
    conn="${spec%%:*}"; rpath="${spec#*:}"
    ssh -o BatchMode=yes "$conn" true 2>/dev/null || { echo "  cannot reach $conn over key-based ssh"; note "$t" UNREACHABLE - - "$conn"; return 1; }
    if [ "$DO_SYNC" = 1 ]; then
        # sync_to_hosts.sh (Lee's rule 2026-10-12) replaces the old clear-then-copy: it pulls this
        # platform's goldens back, deletes exactly the files this tree no longer has (computed here,
        # sent as a list; no rsync delete mode, so no 96,000-entry list on the receiver), and keeps
        # build outputs, binaries/ and this platform's goldens. Then it pushes.
        echo "  sync sources to $conn (sync_to_hosts.sh)"
        bash "$(dirname "${BASH_SOURCE[0]}")/sync_to_hosts.sh" --apply --remote "${t}=${conn}:${rpath}" \
            --list-dir "$LOG_DIR/sync" >"$LOG_DIR/$t-sync.log" 2>&1
        rsync_rc=$?
        if [ $rsync_rc -ne 0 ]; then
            echo "  SYNC FAILED (sync_to_hosts.sh exit $rsync_rc), see $LOG_DIR/$t-sync.log"
            tail -2 "$LOG_DIR/$t-sync.log" | sed 's/^/    /'
            note "$t" "SYNC FAILED" - - "$conn"; return 1
        fi
    fi
    # A half-finished sync leaves the directory skeleton with no sources in it, and make then
    # reports "No rule to make target 'clean'", which says nothing about the real cause.
    if ! ssh -o BatchMode=yes "$conn" "test -f $rpath/compiler/src/Makefile && test -f $rpath/trials/Makefile" 2>/dev/null; then
        echo "  the source tree on $conn is incomplete: compiler/src/Makefile or trials/Makefile is missing"
        echo "  re-run without --skip-sync, and check disk space there: ssh $conn df -h ~"
        note "$t" "TREE INCOMPLETE" - - "$conn"; return 1
    fi
    # binaries/ is excluded from the sync and never cleared, so a machine keeps its own
    # compilers. If it has none, send the newest matching native compiler from this checkout:
    # that makes a wiped or brand-new machine recoverable from here rather than needing a
    # hand-off build. The tag is the native one, silica-<n>-linux-aarch64, not the cross name.
    htag=$(echo "$t" | tr '_' '-')
    if ! ssh -o BatchMode=yes "$conn" "test -x $rpath/binaries/seed-compiler" 2>/dev/null; then
        seed=$(ls -t "$REPO/binaries"/silica-*-"$htag" 2>/dev/null | grep -v -- '-macos-' | head -1)
        if [ -n "$seed" ]; then
            echo "  $conn has no seed; sending $(basename "$seed")"
            ssh -o BatchMode=yes "$conn" "mkdir -p $rpath/binaries" 2>/dev/null
            if scp -q "$seed" "$conn:$rpath/binaries/$(basename "$seed")" 2>>"$LOG_DIR/$t-seed.log"; then
                ssh -o BatchMode=yes "$conn" "cd $rpath/binaries && chmod +x $(basename "$seed") && ln -sfn $(basename "$seed") seed-compiler && ln -sfn $(basename "$seed") silica-compiler" \
                    >>"$LOG_DIR/$t-seed.log" 2>&1
            else
                echo "  could not send a seed; the build will fail. See $LOG_DIR/$t-seed.log"
            fi
        else
            echo "  no native compiler for $t in binaries/ to send; that machine needs a hand-off build"
        fi
    fi
    if [ "$DO_BUILD" = 1 ]; then
        echo "  build on $conn"
        ssh -o BatchMode=yes "$conn" "cd $rpath/compiler/src && make clean SILICA_TARGET_PROMPT=0 && make build SILICA_TARGET_PROMPT=0" \
            >"$LOG_DIR/$t-build.log" 2>&1 || { echo "  BUILD FAILED on $conn, see $LOG_DIR/$t-build.log"; note "$t" "BUILD FAILED" - - "$conn"; return 1; }
        # Bring the new compiler home, so binaries/ here holds every platform's latest and the
        # next run of this script can seed that machine again from scratch.
        built=$(ssh -o BatchMode=yes "$conn" "readlink $rpath/binaries/silica-compiler 2>/dev/null || basename \$(ls -t $rpath/binaries/silica-*-$htag 2>/dev/null | head -1)" 2>/dev/null | tr -d '\r')
        if [ -n "$built" ] && [ ! -f "$REPO/binaries/$built" ]; then
            if scp -q "$conn:$rpath/binaries/$built" "$REPO/binaries/$built" 2>>"$LOG_DIR/$t-seed.log"; then
                echo "  brought back binaries/$built"
            else
                echo "  could not copy $built back; see $LOG_DIR/$t-seed.log"
            fi
        fi
    fi
    local use_build_arg=""
    [ "$USE_BUILD" = 1 ] && use_build_arg=' SILICA_COMPILER=$PWD/../compiler/build/'"$t"'/silica-compiler'
    echo "  first run on $conn"
    ssh -o BatchMode=yes "$conn" "cd $rpath/trials && make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET=host$use_build_arg" >"$LOG_DIR/$t-run1.log" 2>&1
    echo "  before: $(ssh -o BatchMode=yes "$conn" "grep -m1 'success:' $rpath/trials/.integrate_report; grep -m1 'fail:' $rpath/trials/.integrate_report" 2>/dev/null | tr -dc '0-9/' )"
    echo "  recording goldens on $conn"
    ssh -o BatchMode=yes "$conn" "cd $rpath && bash programmer_tools/update_goldens.sh --targets $t --local-only --apply" >"$LOG_DIR/$t-goldens.log" 2>&1
    grep -E 'golden\(s\) were WRITTEN|WOULD change' "$LOG_DIR/$t-goldens.log" | tail -1 | sed 's/^/  /'
    echo "  second run on $conn"
    ssh -o BatchMode=yes "$conn" "cd $rpath/trials && make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET=host$use_build_arg" >"$LOG_DIR/$t-run2.log" 2>&1
    rc=$?
    ssh -o BatchMode=yes "$conn" "grep -E 'success:|fail:' $rpath/trials/.integrate_report; grep '❌❌ ' $rpath/trials/.integrate_report | grep -v '^fail:' | head -20" 2>/dev/null | tee "$LOG_DIR/$t-after.txt" | sed 's/^/    /'
    set -- $(split_counts "$LOG_DIR/$t-after.txt")
    if [ $rc -eq 0 ]; then note "$t" PASS "$1" "$2" "$conn"; else note "$t" FAIL "$1" "$2" "$conn"; overall=1; fi
}

overall=0
declare -a PAR_PID=() PAR_T=()
for t in $PLAN; do
    if [ "$t" = "$HOST_TARGET" ]; then continue; fi
    echo "starting $t in the background (its output appears in full when it finishes)"
    ( SUMMARY="$LOG_DIR/$t-summary.tsv"; : > "$SUMMARY"; do_remote "$t"; echo "$?" > "$LOG_DIR/$t.rc" ) \
        > "$LOG_DIR/$t-console.txt" 2>&1 &
    PAR_PID+=("$!"); PAR_T+=("$t")
done

# This machine runs in the foreground while they work.
for t in $PLAN; do
    [ "$t" = "$HOST_TARGET" ] || continue
    echo; echo "################ $t"
    do_host "$t" || overall=1
done

if [ ${#PAR_PID[@]} -gt 0 ]; then
    for i in $(seq 0 $((${#PAR_PID[@]}-1))); do
        wait "${PAR_PID[$i]}"
        t="${PAR_T[$i]}"
        echo; echo "################ $t"
        cat "$LOG_DIR/$t-console.txt"
        cat "$LOG_DIR/$t-summary.tsv" >> "$SUMMARY" 2>/dev/null
        [ "$(cat "$LOG_DIR/$t.rc" 2>/dev/null || echo 1)" = 0 ] || overall=1
    done
fi

for t in $RAW_PLAN; do
    echo; echo "################ $t (board)"
    if [ "$DO_BUILD" = 1 ]; then
        echo "  cross compiler, built here"
        ( cd "$REPO/compiler/src" && make clean TARGET="$t" SILICA_TARGET_PROMPT=0 && make build TARGET="$t" SILICA_TARGET_PROMPT=0 ) \
            >"$LOG_DIR/$t-build.log" 2>&1 || { echo "  BUILD FAILED, see $LOG_DIR/$t-build.log"; note "$t" "BUILD FAILED" - - "cross, here"; overall=1; continue; }
        grep -hE "Installed (selfhost|target).*compiler:" "$LOG_DIR/$t-build.log" | tail -1 | sed 's/^/  /'
    fi
    echo "  trials on the board (it must be attached)"
    ( cd "$REPO/trials" && make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET="$t" ) >"$LOG_DIR/$t-run.log" 2>&1
    rc=$?
    # A board run writes trials/.integrate_report.<target>; the plain file belongs to the host run.
    BOARD_REPORT="$REPO/trials/.integrate_report.$t"
    [ -f "$BOARD_REPORT" ] || BOARD_REPORT="$REPO/trials/.integrate_report"
    echo "  result: $(counts "$BOARD_REPORT")"
    grep '❌❌ ' "$BOARD_REPORT" 2>/dev/null | grep -v '^fail:' | head -20 | sed 's/^/    /'
    set -- $(split_counts "$BOARD_REPORT")
    if [ $rc -eq 0 ]; then note "$t" PASS "$1" "$2" board; else note "$t" FAIL "$1" "$2" board; overall=1; fi
done

echo
printf '%-20s %-13s %-9s %-8s %s\n' PLATFORM RESULT PASSED FAILED WHERE
while IFS=$'\t' read -r a b c d e; do printf '%-20s %-13s %-9s %-8s %s\n' "$a" "$b" "$c" "$d" "$e"; done < "$SUMMARY"
echo
echo "Goldens were recorded only for trials whose run output already matched, so anything still"
echo "failing above is a behaviour difference. Logs: $LOG_DIR"
[ -n "$RAW_PLAN" ] && echo "The tree now holds a raw target's output; this script cleans before every build, but a build by hand needs 'make clean' first." 
exit "$overall"
