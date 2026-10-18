#!/usr/bin/env bash
# Run the full Silica trial tree on every platform, each with that platform's own compiler.
#
#   bash programmer_tools/run_trials_all_platforms.sh                      # every platform it knows
#   bash programmer_tools/run_trials_all_platforms.sh --list               # what it would run, then stop
#   bash programmer_tools/run_trials_all_platforms.sh --targets linux_x86_64
#   bash programmer_tools/run_trials_all_platforms.sh --remote linux_aarch64=admin@pix.local
#   bash programmer_tools/run_trials_all_platforms.sh --sync --board
#
# This script never builds a compiler. Each machine must already have its own native compiler at
# <repo>/binaries/silica-compiler; a raw target is driven from this machine with the cross compiler
# this machine built for it.
#
# Which platforms, and where their machines are:
#   .silica_build_hosts in the repository root, the file programmer_tools/build_all_platforms.sh
#   writes, names the platforms and their machines. It is read here and never written. It is
#   gitignored and must never be committed.
#   no flags            every platform in that file; without the file, this machine only
#   --targets "<list>"  only those platforms (emit-target names, or the short names below)
#   --remote <t>=<user@host>[:<path>]   a machine for one platform, for this run only
#   --board             also run a raw target's trials on an attached board (off by default)
#   --sync              first sync this tree to each remote machine with sync_to_hosts.sh (pulls
#                       that platform's goldens back, deletes what this tree no longer has, pushes;
#                       built artifacts excluded: see sync_excludes.sh)
#   --sync-only         do that copy and stop; no trial runs
#
# Short names are accepted anywhere a platform is: mac, pi, nix, esp32, all, hosted.
#
# Remote machines are reached with public/private key ssh in batch mode; no password is ever typed.
# Set the key up with ssh-keygen and ssh-copy-id, and check it with `ssh -o BatchMode=yes host true`.
#
# This machine runs its own trials, and the board runs after it: both take trials/.integrate.lock,
# one trial run per machine. Remote machines run at the same time as each other.
#
# Logs and each platform's .integrate_report land in the log directory, and one summary table is
# printed at the end. The exit status is 0 only when every platform passed.

set -uo pipefail

REPO="${SILICA_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$(dirname "${BASH_SOURCE[0]}")/sync_excludes.sh"
PLATFORM_MK="$REPO/project_makefiles/platform/platforms.mk"
HOSTS_FILE="${SILICA_BUILD_HOSTS:-$REPO/.silica_build_hosts}"

DEFAULT_PATH="${SILICA_REMOTE_PATH:-~/silica}"
JOBS_apple_silicon_mac="${MAC_JOBS:-}"        # empty = the Makefile's default (one per core)
SDS_apple_silicon_mac="${MAC_SDS_JOBS:-2}"    # ordered_data_structures is memory-bound
JOBS_linux_aarch64="${PI_JOBS:-2}"            # 4 GB board
SDS_linux_aarch64="${PI_SDS_JOBS:-1}"
JOBS_linux_x86_64="${NIX_JOBS:-3}"            # 13 GB, 8 cores
SDS_linux_x86_64="${NIX_SDS_JOBS:-1}"

STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_DIR="${LOG_DIR:-$REPO/../silica_trial_runs/$STAMP}"
DO_SYNC=0
SYNC_ONLY=0
DO_BOARD=0
LIST_ONLY=0
SELECTED=""

usage() {  # every comment line of the header, however long it grows
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
    exit "${1:-0}"
}

declare -a REMOTE_SPECS=()

# mac/pi/nix/esp32 are the names this script has always taken; keep them working.
expand_name() {
    case "$1" in
        mac)    echo apple_silicon_mac ;;
        pi)     echo linux_aarch64 ;;
        nix)    echo linux_x86_64 ;;
        esp32)  echo ESP32-S3_raw ;;
        all)    echo "$ALL_TARGETS" ;;
        hosted) echo "$HOSTED_ALL" ;;
        *)      echo "$1" ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --sync)     DO_SYNC=1 ;;
        --sync-only) DO_SYNC=1; SYNC_ONLY=1 ;;
        --board)    DO_BOARD=1 ;;
        --list)     LIST_ONLY=1 ;;
        --log-dir)  LOG_DIR="$2"; shift ;;
        --targets)  SELECTED="$SELECTED $(echo "$2" | tr ',' ' ')"; shift ;;
        --remote)   REMOTE_SPECS+=("$2"); shift ;;
        --mac-jobs) JOBS_apple_silicon_mac="$2"; shift ;;
        --pi-jobs)  JOBS_linux_aarch64="$2"; shift ;;
        --nix-jobs) JOBS_linux_x86_64="$2"; shift ;;
        -h|--help)  usage 0 ;;
        -*)         echo "unknown argument: $1" >&2; usage 1 ;;
        *)          SELECTED="$SELECTED $1" ;;
    esac
    shift
done

[ -f "$PLATFORM_MK" ] || { echo "platform table missing: $PLATFORM_MK" >&2; exit 1; }

ask_table() { MAKEFLAGS= MAKELEVEL= make -s --no-print-directory -f "$PLATFORM_MK" "$1" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'; }

HOST_PLATFORM="$(ask_table host-platform)"
HOST_TARGET="$(ask_table host-emit-target)"
ALL_TARGETS="$(ask_table emit-targets)"
[ -n "$ALL_TARGETS" ] || ALL_TARGETS="apple_silicon_mac linux_aarch64 linux_x86_64 ESP32-S3_raw"
[ -n "$HOST_TARGET" ] || { echo "This host ($(uname -s)/$(uname -m)) has no row in $PLATFORM_MK." >&2; exit 1; }

is_raw() { [ "$(ask_table "platform-for-$1" 2>/dev/null)" = "-" ] || case "$1" in *_raw) return 0 ;; esac; return 1; }

HOSTED_ALL=""
for t in $ALL_TARGETS; do is_raw "$t" || HOSTED_ALL="$HOSTED_ALL $t"; done

# ---------------------------------------------------------------- machines

declare -a R_TARGET=() R_CONN=() R_PATH=()

add_remote() {  # $1 = target, $2 = user@host[:path]
    local t="$1" spec="$2" conn path
    conn="${spec%%:*}"; path="${spec#*:}"
    [ "$path" = "$spec" ] && path="$DEFAULT_PATH"
    R_TARGET+=("$t"); R_CONN+=("$conn"); R_PATH+=("$path")
}

conn_of() {  # $1 = target; prints user@host:path
    local i
    [ ${#R_TARGET[@]} -gt 0 ] || return 1
    for i in "${!R_TARGET[@]}"; do
        [ "${R_TARGET[$i]}" = "$1" ] && { echo "${R_CONN[$i]}:${R_PATH[$i]}"; return 0; }
    done
    return 1
}

FILE_TARGETS=""
if [ -f "$HOSTS_FILE" ]; then
    while read -r t conn path; do
        case "$t" in ''|\#*) continue ;; esac
        FILE_TARGETS="$FILE_TARGETS $t"
        case "$conn" in local|ask|-|'') continue ;; esac
        add_remote "$t" "$conn:${path:-$DEFAULT_PATH}"
    done < "$HOSTS_FILE"
fi

# Machines named on the command line win over the file.
for spec in ${REMOTE_SPECS[@]+"${REMOTE_SPECS[@]}"}; do
    case "$spec" in
        *=*) add_remote "${spec%%=*}" "${spec#*=}" ;;
        *)   echo "--remote needs <target>=<user@host>[:<path>]: $spec" >&2; exit 1 ;;
    esac
done
# The old environment overrides still work when the file says nothing.
[ -n "${PI_HOST:-}" ]  && ! conn_of linux_aarch64 >/dev/null && add_remote linux_aarch64 "$PI_HOST:${PI_REPO:-$DEFAULT_PATH}"
[ -n "${NIX_HOST:-}" ] && ! conn_of linux_x86_64  >/dev/null && add_remote linux_x86_64  "$NIX_HOST:${NIX_REPO:-$DEFAULT_PATH}"

# ---------------------------------------------------------------- platforms

TARGETS=""
if [ -n "$SELECTED" ]; then
    for name in $SELECTED; do TARGETS="$TARGETS $(expand_name "$name")"; done
elif [ -n "$FILE_TARGETS" ]; then
    TARGETS="$FILE_TARGETS"
    echo "using $HOSTS_FILE"
else
    TARGETS="$HOST_TARGET"
    if [ ${#R_TARGET[@]} -gt 0 ]; then
        for i in "${!R_TARGET[@]}"; do TARGETS="$TARGETS ${R_TARGET[$i]}"; done
    fi
fi

for t in $TARGETS; do
    echo " $ALL_TARGETS " | grep -q " $t " || { echo "unknown platform: $t (known: $ALL_TARGETS)" >&2; exit 1; }
done

RUN_NATIVE=0; RUN_RAW=""; RUN_REMOTE=""; SKIPPED=""
for t in $TARGETS; do
    if [ "$t" = "$HOST_TARGET" ]; then
        RUN_NATIVE=1
    elif is_raw "$t"; then
        if [ "$DO_BOARD" = 1 ]; then RUN_RAW="$RUN_RAW $t"; else SKIPPED="$SKIPPED $t(no --board)"; fi
    elif conn_of "$t" >/dev/null; then
        RUN_REMOTE="$RUN_REMOTE $t"
    else
        SKIPPED="$SKIPPED $t(no machine)"
    fi
done

echo "this machine : $HOST_PLATFORM ($HOST_TARGET)"
echo "runs here    :$([ "$RUN_NATIVE" = 1 ] && echo " $HOST_TARGET")$RUN_RAW"
echo "runs remote  :$([ -n "$RUN_REMOTE" ] && echo "$RUN_REMOTE" || echo " none")"
[ -n "$SKIPPED" ] && echo "skipped      :$SKIPPED"
echo "logs         : $LOG_DIR"

if [ "$LIST_ONLY" = 1 ]; then
    [ "$RUN_NATIVE" = 1 ] && echo "  $HOST_TARGET: make integrate TRIAL_TARGET=host, here"
    for t in $RUN_RAW; do echo "  $t: make integrate TRIAL_TARGET=$t, here, on the attached board"; done
    for t in $RUN_REMOTE; do echo "  $t: make integrate TRIAL_TARGET=host on $(conn_of "$t")"; done
    exit 0
fi

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------- sync (optional)

# Built artifacts never cross machines (sync_excludes.sh): no .o/.a/.so/.dylib, no trial outputs or
# executables, no fixtures/build, no compiler/build. Goldens, .ascomp files, sources and scripts do.

sync_to() {  # $1 = user@host, $2 = remote repo, $3 = target
    # The whole tree through sync_to_hosts.sh (Lee's rule 2026-10-12): this platform's goldens are
    # pulled back first, files this tree no longer has are deleted (build outputs, binaries/ and
    # this platform's goldens stay), then the tree is pushed. It used to copy trials, stdlib,
    # project_makefiles and the board sources trials read, and never deleted anything.
    echo "  sync -> $1"
    bash "$(dirname "${BASH_SOURCE[0]}")/sync_to_hosts.sh" --apply --remote "${3}=${1}:${2}" \
        --list-dir "$LOG_DIR/sync"
}

if [ "$DO_SYNC" = 1 ] && [ -n "$RUN_REMOTE" ]; then
    echo "Syncing trials, stdlib, project makefiles and board sources (build products excluded)"
    for t in $RUN_REMOTE; do
        spec="$(conn_of "$t")"
        sync_to "${spec%%:*}" "${spec#*:}" "$t" || { echo "sync for $t failed" >&2; exit 1; }
    done
fi

[ "$SYNC_ONLY" = 1 ] && { echo "sync only: done"; exit 0; }

# ---------------------------------------------------------------- runs

jobs_for() { eval "echo \"\${JOBS_$(echo "$1" | tr '-' '_'):-}\""; }
sds_for()  { eval "echo \"\${SDS_$(echo "$1" | tr '-' '_'):-1}\""; }

run_remote() {  # $1 = target
    local t="$1" spec conn rpath jobs sds log rc
    spec="$(conn_of "$t")"; conn="${spec%%:*}"; rpath="${spec#*:}"
    jobs="$(jobs_for "$t")"; sds="$(sds_for "$t")"
    log="$LOG_DIR/$t.log"
    echo "  start $t on $conn (JOBS=${jobs:-default} SDS_JOBS=$sds)"
    ssh -o BatchMode=yes "$conn" \
        "cd $rpath/trials && make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET=host ${jobs:+JOBS=$jobs} SDS_JOBS=$sds" \
        > "$log" 2>&1
    rc=$?
    ssh -o BatchMode=yes "$conn" "cat $rpath/trials/.integrate_report" > "$LOG_DIR/$t.report" 2>/dev/null
    echo "$rc" > "$LOG_DIR/$t.rc"
    return $rc
}

run_here() {  # $1 = target, $2 = TRIAL_TARGET value
    local t="$1" tt="$2" jobs sds log rc
    jobs="$(jobs_for "$t")"; sds="$(sds_for "$t")"
    log="$LOG_DIR/$t.log"
    echo "  start $t here (TRIAL_TARGET=$tt JOBS=${jobs:-default} SDS_JOBS=$sds)"
    ( cd "$REPO/trials" && make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET="$tt" \
        ${jobs:+JOBS=$jobs} SDS_JOBS="$sds" ) > "$log" 2>&1
    rc=$?
    cp "$REPO/trials/.integrate_report" "$LOG_DIR/$t.report" 2>/dev/null
    echo "$rc" > "$LOG_DIR/$t.rc"
    return $rc
}

pids=(); tags=()
for t in $RUN_REMOTE; do run_remote "$t" & pids+=($!); tags+=("$t"); done

# This machine, then the board: both take trials/.integrate.lock.
[ "$RUN_NATIVE" = 1 ] && run_here "$HOST_TARGET" host
for t in $RUN_RAW; do run_here "$t" "$t"; done

if [ ${#pids[@]} -gt 0 ]; then
    for i in "${!pids[@]}"; do wait "${pids[$i]}"; echo "  done ${tags[$i]}"; done
fi

# ---------------------------------------------------------------- summary

echo
printf '%-20s %-7s %-9s %-9s %s\n' PLATFORM STATUS PASSED FAILED REPORT
overall=0
for t in $TARGETS; do
    rc_file="$LOG_DIR/$t.rc"; rep="$LOG_DIR/$t.report"
    if [ ! -f "$rc_file" ]; then
        printf '%-20s %-7s %-9s %-9s %s\n' "$t" "NOT RUN" - - -
        continue
    fi
    rc="$(cat "$rc_file")"
    pass="$(grep -m1 'success:' "$rep" 2>/dev/null | tr -dc '0-9')"
    fail="$(grep -m1 'fail:'    "$rep" 2>/dev/null | tr -dc '0-9')"
    status=PASS; [ "$rc" = 0 ] || { status=FAIL; overall=1; }
    printf '%-20s %-7s %-9s %-9s %s\n' "$t" "$status" "${pass:-?}" "${fail:-?}" "$rep"
done

echo
echo "Every failure should be a documented defect trial; read each report's failure list."
exit "$overall"
