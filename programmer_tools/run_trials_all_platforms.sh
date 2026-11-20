#!/usr/bin/env bash
# Run the full Silica trial tree on every platform, each with that platform's own compiler.
#
#   bash programmer_tools/run_trials_all_platforms.sh                      # every platform it knows
#   bash programmer_tools/run_trials_all_platforms.sh --list               # what it would run, then stop
#   bash programmer_tools/run_trials_all_platforms.sh --targets linux_x86_64
#   bash programmer_tools/run_trials_all_platforms.sh --remote linux_aarch64=admin@pix.local
#   bash programmer_tools/run_trials_all_platforms.sh --sync --board
#   bash programmer_tools/run_trials_all_platforms.sh --compiler /path/to/silica-compiler
#   bash programmer_tools/run_trials_all_platforms.sh --compiler esp32=/path/to/silica-compiler-ESP32-S3_raw --board
#
# This script never builds a compiler. Each machine must already have its own native compiler at
# <repo>/binaries/TRIAL_BUILD_silica-compiler (the trial compiler: make build TRIAL_BUILD=1, which
# build_all_platforms.sh does after each normal build); a raw target is driven from this machine with
# binaries/TRIAL_BUILD_silica-compiler-<target>. The script refuses to start when one is missing. The
# one suite that tests a normal build uses the normal compiler through SILICA_NORMAL_COMPILER.
# --compiler (below) tests another one.
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
#   --compiler <path>   test this compiler instead of binaries/silica-compiler, on THIS machine's own
#                       (native host) run: SILICA_COMPILER=<absolute path> goes on the make integrate
#                       command line (an environment variable would be ignored). The file must be named
#                       exactly silica-compiler (the trials read the target from the name), be
#                       executable, and exist; otherwise the script refuses and runs nothing. A Mac build
#                       is compiler/build/apple_silicon_mac/silica-compiler.
#   --compiler <target>=<path>   the same per platform; repeatable. Targets take the names above.
#                       Native host: as the bare form. Board (ESP32-S3_raw, STM32-L476RG_raw): the local
#                       file, passed as BOARD_SILICA_COMPILER for that board's run (default
#                       binaries/silica-compiler-<target>); needs --board. Remote machine: a path ON that
#                       machine (a leading ~/ is expanded there), passed as SILICA_COMPILER on its make
#                       command line; its file name must also be silica-compiler. A target that is not
#                       part of this run, an unknown target, or two compilers for one target is an error.
#                       Without --compiler nothing changes. The plan, --list, each log's first line and
#                       the final summary name the compiler used per target.
#
# Short names are accepted anywhere a platform is: mac, pi, nix, esp32, all, hosted.
#
# Remote machines are reached with public/private key ssh in batch mode; no password is ever typed.
# Set the key up with ssh-keygen and ssh-copy-id, and check it with `ssh -o BatchMode=yes host true`.
#
# This machine runs its own trials; when that run finishes, every board selected with --board starts at
# once, in parallel with each other and with the remote machines, which started at the very beginning.
# Each target takes its own per-target lock (trials/.integrate.lock.<target>), one trial run per target.
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
# The two boards run together on this machine once its own run is over, so each gets a share of the
# cores and the memory (16 GB Mac): 5 jobs each, 10 compiles at once, instead of one per core apiece.
JOBS_ESP32_S3_raw="${ESP32_JOBS:-5}"
SDS_ESP32_S3_raw="${ESP32_SDS_JOBS:-1}"
JOBS_STM32_L476RG_raw="${NUCLEO_JOBS:-5}"
SDS_STM32_L476RG_raw="${NUCLEO_SDS_JOBS:-1}"

STAMP="$(date '+%Y%m%d-%H%M%S')"
# Default log location: beside the MAIN checkout, never inside a .claude/worktrees directory (the
# agent-worktree cleanup owns that and has deleted a run's logs mid-run). In a git worktree the main
# checkout is the parent of the common git dir; fall back to $REPO when git cannot say.
MAIN_REPO="$REPO"
if _common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
        && [ -n "$_common" ] && [ -d "$_common" ] && [ "$(basename "$_common")" = ".git" ]; then
    MAIN_REPO="$(dirname "$_common")"
fi
case "$MAIN_REPO" in */.claude/worktrees/*) MAIN_REPO="${MAIN_REPO%%/.claude/worktrees/*}" ;; esac
LOG_DIR="${LOG_DIR:-$MAIN_REPO/../silica_trial_runs/$STAMP}"
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
declare -a COMPILER_SPECS=()

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
        --compiler) [ $# -ge 2 ] || { echo "--compiler needs <path> or <target>=<path>" >&2; exit 1; }
                    COMPILER_SPECS+=("$2"); shift ;;
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

# ---------------------------------------------------------------- --compiler

declare -a C_TARGET=() C_PATH=()

compiler_of() {  # $1 = target; prints the --compiler path given for it, status 1 when none
    local i
    [ ${#C_TARGET[@]} -gt 0 ] || return 1
    for i in "${!C_TARGET[@]}"; do
        [ "${C_TARGET[$i]}" = "$1" ] && { echo "${C_PATH[$i]}"; return 0; }
    done
    return 1
}

cdie() { echo "error: --compiler $1" >&2; exit 1; }

check_local_compiler() {  # $1 = path, $2 = "must be named silica-compiler" (1) or not (0)
    [ -e "$1" ] || cdie "$1: no such file"
    [ -f "$1" ] || cdie "$1: not a file"
    [ -x "$1" ] || cdie "$1: not executable"
    if [ "$2" = 1 ] && [ "$(basename "$1")" != silica-compiler ]; then
        cdie "$1: the file must be named exactly silica-compiler (the trials read the emit target from the name; a differently named file such as silica-NNNNNN-<platform> would be taken for another target). Point at compiler/build/<platform>/silica-compiler or make a link of that name."
    fi
}

for spec in ${COMPILER_SPECS[@]+"${COMPILER_SPECS[@]}"}; do
    ctarget=""; cpath="$spec"
    case "$spec" in
        */*=*) ;;                                  # a path that happens to contain '=': a bare path
        *=*)   ctarget="${spec%%=*}"; cpath="${spec#*=}" ;;
    esac
    [ -n "$cpath" ] || cdie "needs a path: $spec"
    if [ -z "$ctarget" ]; then
        ctarget="$HOST_TARGET"
    else
        ctarget="$(expand_name "$ctarget")"
        case "$ctarget" in *" "*) cdie "needs one platform, not a list: $spec" ;; esac
        echo " $ALL_TARGETS " | grep -q " $ctarget " || cdie "unknown platform '${spec%%=*}' (known: $ALL_TARGETS)"
    fi
    echo " $([ "$RUN_NATIVE" = 1 ] && echo "$HOST_TARGET") $RUN_RAW $RUN_REMOTE " | grep -q " $ctarget " \
        || cdie "names $ctarget, which does not run here (runs:$([ "$RUN_NATIVE" = 1 ] && echo " $HOST_TARGET")$RUN_RAW$RUN_REMOTE; skipped:${SKIPPED:- none})"
    ! compiler_of "$ctarget" >/dev/null || cdie "given twice for $ctarget"
    C_TARGET+=("$ctarget"); C_PATH+=("$cpath")
done

# Local files are checked now, before anything starts; the remote machines' paths are only checked for
# their name (they are checked for existence by the remote make).
if [ ${#C_TARGET[@]} -gt 0 ]; then
    for i in "${!C_TARGET[@]}"; do
        t="${C_TARGET[$i]}"; p="${C_PATH[$i]}"
        if [ "$t" != "$HOST_TARGET" ] && ! is_raw "$t"; then
            conn_of "$t" >/dev/null || cdie "$t has no machine to run on, so '$p' cannot be used"
            [ "$(basename "$p")" = silica-compiler ] || cdie "$p: the file on the remote machine must be named exactly silica-compiler"
            continue
        fi
        case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
        if [ "$t" = "$HOST_TARGET" ]; then check_local_compiler "$p" 1; else check_local_compiler "$p" 0; fi
        C_PATH[$i]="$p"
    done
fi

compiler_label() {  # $1 = target; what that target's run uses, for the plan, the logs and the summary
    local c
    if c="$(compiler_of "$1")"; then echo "$c"; return; fi
    if [ "$1" = "$HOST_TARGET" ]; then echo "$REPO/binaries/silica-compiler (default)"
    elif is_raw "$1"; then echo "$REPO/binaries/silica-compiler-$1 (default)"
    else echo "binaries/silica-compiler on the remote machine (default)"; fi
}

qremote() {  # quote a path for the remote shell; a leading ~/ stays unquoted so the remote shell expands it
    case "$1" in
        "~/"*) printf '~/%q' "${1#"~/"}" ;;
        *)     printf '%q' "$1" ;;
    esac
}

echo "this machine : $HOST_PLATFORM ($HOST_TARGET)"
echo "runs here    :$([ "$RUN_NATIVE" = 1 ] && echo " $HOST_TARGET")$RUN_RAW"
echo "runs remote  :$([ -n "$RUN_REMOTE" ] && echo "$RUN_REMOTE" || echo " none")"
[ -n "$SKIPPED" ] && echo "skipped      :$SKIPPED"
echo "logs         : $LOG_DIR"
if [ ${#C_TARGET[@]} -gt 0 ]; then
    echo "compilers    :"
    for t in $([ "$RUN_NATIVE" = 1 ] && echo "$HOST_TARGET") $RUN_RAW $RUN_REMOTE; do
        echo "  $t: $(compiler_label "$t")"
    done
fi

if [ "$LIST_ONLY" = 1 ]; then
    [ "$RUN_NATIVE" = 1 ] && echo "  $HOST_TARGET: make integrate TRIAL_TARGET=host, here; compiler $(compiler_label "$HOST_TARGET")$(compiler_of "$HOST_TARGET" >/dev/null && echo "  [SILICA_COMPILER on the make command line]")"
    for t in $RUN_RAW; do echo "  $t: make integrate TRIAL_TARGET=$t, here, on the attached board; compiler $(compiler_label "$t")$(compiler_of "$t" >/dev/null && echo "  [BOARD_SILICA_COMPILER]")"; done
    for t in $RUN_REMOTE; do echo "  $t: make integrate TRIAL_TARGET=host on $(conn_of "$t"); compiler $(compiler_label "$t")$(compiler_of "$t" >/dev/null && echo "  [SILICA_COMPILER on the remote make command line]")"; done
    exit 0
fi

if ! mkdir -p "$LOG_DIR" || [ ! -d "$LOG_DIR" ] || [ ! -w "$LOG_DIR" ]; then
    echo "error: cannot create or write the log directory $LOG_DIR (use --log-dir or LOG_DIR=)" >&2
    exit 2
fi

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

# ---------------------------------------------------------------- trial compilers

# The trials are compiled by trial compilers (the trial hook is built only into them). Refuse to start
# when one is missing, before any run begins.
missing=""
[ "$RUN_NATIVE" = 1 ] && [ ! -x "$REPO/binaries/TRIAL_BUILD_silica-compiler" ] \
    && missing="$missing\n  here: $REPO/binaries/TRIAL_BUILD_silica-compiler"
for t in $RUN_RAW; do
    [ -x "$REPO/binaries/TRIAL_BUILD_silica-compiler-$t" ] \
        || missing="$missing\n  here: $REPO/binaries/TRIAL_BUILD_silica-compiler-$t"
done
for t in $RUN_REMOTE; do
    spec="$(conn_of "$t")"
    ssh -o BatchMode=yes "${spec%%:*}" "test -x ${spec#*:}/binaries/TRIAL_BUILD_silica-compiler" >/dev/null 2>&1 \
        || missing="$missing\n  $t: ${spec%%:*}:${spec#*:}/binaries/TRIAL_BUILD_silica-compiler"
done
if [ -n "$missing" ]; then
    printf 'No trial compiler, so no trial run starts. Missing:%b\n' "$missing" >&2
    echo "Build them with: bash programmer_tools/build_all_platforms.sh (or, in compiler/src: make build TRIAL_BUILD=1 [TARGET=<t>] INSTALL_SELFHOST=1 SILICA_TARGET_PROMPT=0)" >&2
    exit 1
fi

# ---------------------------------------------------------------- runs

jobs_for() { eval "echo \"\${JOBS_$(echo "$1" | tr '-' '_'):-}\""; }
sds_for()  { eval "echo \"\${SDS_$(echo "$1" | tr '-' '_'):-1}\""; }

run_remote() {  # $1 = target
    local t="$1" spec conn rpath jobs sds log rc
    spec="$(conn_of "$t")"; conn="${spec%%:*}"; rpath="${spec#*:}"
    jobs="$(jobs_for "$t")"; sds="$(sds_for "$t")"
    log="$LOG_DIR/$t.log"
    local rcomp="" cc
    cc="$(compiler_of "$t")" && rcomp="SILICA_COMPILER=$(qremote "$cc")"
    echo "  start $t on $conn (JOBS=${jobs:-default} SDS_JOBS=$sds) compiler: $(compiler_label "$t")"
    echo "compiler: $(compiler_label "$t")" > "$log"
    ssh -o BatchMode=yes "$conn" \
        "cd $rpath/trials && make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET=host ${jobs:+JOBS=$jobs} SDS_JOBS=$sds${rcomp:+ $rcomp}" \
        >> "$log" 2>&1
    rc=$?
    ssh -o BatchMode=yes "$conn" "cd $rpath/trials && { cat .integrate_report.$t 2>/dev/null || cat .integrate_report; }" > "$LOG_DIR/$t.report" 2>/dev/null
    echo "$rc" > "$LOG_DIR/$t.rc"
    return $rc
}

run_here() {  # $1 = target, $2 = TRIAL_TARGET value
    local t="$1" tt="$2" jobs sds log rc
    jobs="$(jobs_for "$t")"; sds="$(sds_for "$t")"
    log="$LOG_DIR/$t.log"
    # --compiler: the host run gets SILICA_COMPILER on the make command line (the trials ignore the
    # environment); a board run gets BOARD_SILICA_COMPILER in its environment (what trial_target.sh reads).
    local cc="" cmake_arg=() cenv=()
    if cc="$(compiler_of "$t")"; then
        if [ "$t" = "$HOST_TARGET" ]; then cmake_arg=("SILICA_COMPILER=$cc"); else cenv=("BOARD_SILICA_COMPILER=$cc"); fi
    fi
    echo "  start $t here (TRIAL_TARGET=$tt JOBS=${jobs:-default} SDS_JOBS=$sds) compiler: $(compiler_label "$t")"
    echo "compiler: $(compiler_label "$t")" > "$log"
    ( cd "$REPO/trials" && env ${cenv[@]+"${cenv[@]}"} make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET="$tt" \
        ${jobs:+JOBS=$jobs} SDS_JOBS="$sds" ${cmake_arg[@]+"${cmake_arg[@]}"} ) >> "$log" 2>&1
    rc=$?
    # A host run's report is named after the machine's target (macos_applesilicon on the Mac), a board's after the board.
    hk="$t"; [ "$t" = apple_silicon_mac ] && hk=macos_applesilicon
    cp "$REPO/trials/.integrate_report.$hk" "$LOG_DIR/$t.report" 2>/dev/null \
        || cp "$REPO/trials/.integrate_report.$t" "$LOG_DIR/$t.report" 2>/dev/null \
        || cp "$REPO/trials/.integrate_report" "$LOG_DIR/$t.report" 2>/dev/null
    echo "$rc" > "$LOG_DIR/$t.rc"
    return $rc
}

pids=(); tags=()
for t in $RUN_REMOTE; do run_remote "$t" & pids+=($!); tags+=("$t"); done

# The remote machines are already running. This machine's own run goes first; the moment it finishes
# the boards start, all of them at once and while the remote runs are still going (each has its own
# per-target lock, work directory under trials/.target/<target>/, serial port and report). With no
# native run the boards start immediately.
[ "$RUN_NATIVE" = 1 ] && run_here "$HOST_TARGET" host
for t in $RUN_RAW; do run_here "$t" "$t" & pids+=($!); tags+=("$t"); done

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
echo "Compilers used:"
for t in $TARGETS; do
    [ -f "$LOG_DIR/$t.rc" ] && echo "  $t: $(compiler_label "$t")"
done
echo
echo "Every failure should be a documented defect trial; read each report's failure list."
exit "$overall"
