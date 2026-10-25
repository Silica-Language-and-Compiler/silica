#!/usr/bin/env bash
# Build Silica for every supported platform, from whatever machine you start on.
#
#   bash programmer_tools/build_all_platforms.sh              # asks for each OS-hosted machine
#   bash programmer_tools/build_all_platforms.sh --list       # what this run would do, and stop
#   bash programmer_tools/build_all_platforms.sh --remote linux_aarch64=admin@pix.local \
#        --remote linux_x86_64=lee@nix.local:~/silica         # no questions asked
#   bash programmer_tools/build_all_platforms.sh --local-only # this machine and the raw targets
#   bash programmer_tools/build_all_platforms.sh --targets "apple_silicon_mac ESP32-S3_raw"
#   bash programmer_tools/build_all_platforms.sh --set_targets "apple_silicon_mac linux_x86_64"
#   bash programmer_tools/build_all_platforms.sh --refresh_targets
#   bash programmer_tools/build_all_platforms.sh --no-fixpoint --trials
#
# An OS-hosted platform compiles its own code: macOS on Apple Silicon, Linux on AArch64, Linux on
# x86-64. Each one builds natively on its own machine and reaches its own fixed point there. This
# script does that here, and over ssh on the machines you name. It does not build a cross compiler
# for a hosted platform, with one exception: a hosted machine that has no compiler of its own yet
# needs its first one handed to it, which this script offers to do (build here, emit the assembly
# here, link there).
#
# A raw platform has no OS and cannot host a compiler: ESP32-S3_raw. Its cross compiler is built
# here, on this machine, and its board images are built and flashed separately.
#
# Per machine the work is: build, gen1, gen2, fixed-point check, publish (skip the last four with
# --no-fixpoint). One compiler build at a time per machine; the heaviest unit needs 6-8 GB.
#
# Which platforms are built, and where:
#   .silica_build_hosts in the repository root remembers the platforms and their machines. It is
#   written the first time you are asked, and used silently after that. It is gitignored and must
#   never be committed: it names your machines.
#   no flags            the file, if it exists; otherwise every supported platform, asking for each
#   --targets "<list>"  only those platforms, this run only; the file is read but not rewritten
#   --set_targets "<l>" ask for that list and write (or replace) the file
#   --refresh_targets   ask again for the platforms already in the file and rewrite it
#   Those last two ask and write even with --list, so you can record your machines without building.
#   --remote <t>=<user@host>[:<path>]   one connection on the command line, asked about nothing
#   --local-only        this machine and the raw targets, no remote machines
#
# Every remote connection must be public/private key ssh: the script runs ssh in batch mode and
# never types a password. Set the key up first (ssh-keygen, then ssh-copy-id user@host) and check
# that `ssh -o BatchMode=yes user@host true` succeeds.

set -uo pipefail

REPO="${SILICA_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC_REL="compiler/src"
SRC="$REPO/$SRC_REL"
BIN="$REPO/binaries"
PLATFORM_MK="$REPO/project_makefiles/platform/platforms.mk"
# One list of what never crosses between machines (built artifacts); shared with the other scripts.
. "$(dirname "${BASH_SOURCE[0]}")/sync_excludes.sh"

DO_FIXPOINT=1
DO_TRIALS=0
LOCAL_ONLY=0
LIST_ONLY=0
JOBS=""
SELECTED=""
SET_TARGETS=""
REFRESH=0
HOSTS_FILE="${SILICA_BUILD_HOSTS:-$REPO/.silica_build_hosts}"
declare -a REMOTE_SPECS=()

STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_DIR="${LOG_DIR:-$REPO/../silica_builds/$STAMP}"

usage() {  # every comment line of the header, however long it grows
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-fixpoint) DO_FIXPOINT=0 ;;
        --trials)      DO_TRIALS=1 ;;
        --local-only)  LOCAL_ONLY=1 ;;
        --list)        LIST_ONLY=1 ;;
        --jobs)        JOBS="$2"; shift ;;
        --targets)     SELECTED="$SELECTED $(echo "$2" | tr ',' ' ')"; shift ;;
        --set_targets|--set-targets)
                       SET_TARGETS="$SET_TARGETS $(echo "$2" | tr ',' ' ')"; shift ;;
        --refresh_targets|--refresh-targets) REFRESH=1 ;;
        --remote)      REMOTE_SPECS+=("$2"); shift ;;
        --log-dir)     LOG_DIR="$2"; shift ;;
        -h|--help)     usage 0 ;;
        *)             echo "unknown argument: $1" >&2; usage 1 ;;
    esac
    shift
done

[ -f "$PLATFORM_MK" ] || { echo "platform table missing: $PLATFORM_MK" >&2; exit 1; }

# The table answers one item per line; everything here wants a single space-separated line.
ask_table() { MAKEFLAGS= MAKELEVEL= make -s --no-print-directory -f "$PLATFORM_MK" "$1" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'; }

HOST_PLATFORM="$(ask_table host-platform)"
HOST_TARGET="$(ask_table host-emit-target)"
ALL_TARGETS="$(ask_table emit-targets)"
[ -n "$ALL_TARGETS" ] || ALL_TARGETS="apple_silicon_mac linux_aarch64 linux_x86_64 ESP32-S3_raw"

if [ -z "$HOST_PLATFORM" ] || [ -z "$HOST_TARGET" ]; then
    echo "This host ($(uname -s)/$(uname -m)) has no row in $PLATFORM_MK; add one first." >&2
    exit 1
fi

# A target is hosted when the table names a platform that runs its output; a raw target has none.
is_raw() { [ "$(ask_table "platform-for-$1" 2>/dev/null)" = "-" ] || case "$1" in *_raw) return 0 ;; esac; return 1; }

check_known() {  # $1 = list of targets
    local t
    for t in $1; do
        echo " $ALL_TARGETS " | grep -q " $t " || {
            echo "unknown target: $t (known: $ALL_TARGETS)" >&2; exit 1; }
    done
}

# .silica_build_hosts: one line per platform, "<target> <user@host|local> <repo path>".
FILE_TARGETS=""
read_hosts_file() {
    FILE_TARGETS=""
    [ -f "$HOSTS_FILE" ] || return 1
    local t conn path
    while read -r t conn path; do
        case "$t" in ''|\#*) continue ;; esac
        FILE_TARGETS="$FILE_TARGETS $t"
        case "$conn" in local|ask|-|'') continue ;; esac
        add_remote "$t" "$conn:${path:-~/silica}"
    done < "$HOSTS_FILE"
    [ -n "$FILE_TARGETS" ]
}

write_hosts_file() {  # $1 = target list
    local t conn path i
    {
        echo "# Silica build machines, written by programmer_tools/build_all_platforms.sh."
        echo "# One line per platform: <emit target> <user@host|local> <repository path>."
        echo "# Connections are public/private key ssh. Never commit this file."
        for t in $1; do
            if [ "$t" = "$HOST_TARGET" ] || is_raw "$t"; then conn=local; else conn=ask; fi
            path=-
            if [ ${#R_TARGET[@]} -gt 0 ]; then
                for i in "${!R_TARGET[@]}"; do
                    [ "${R_TARGET[$i]}" = "$t" ] && { conn="${R_CONN[$i]}"; path="${R_PATH[$i]}"; }
                done
            fi
            echo "$t $conn $path"
        done
    } > "$HOSTS_FILE"
    chmod 600 "$HOSTS_FILE" 2>/dev/null
    echo "  remembered in $HOSTS_FILE (gitignored; never commit it)"
}

declare -a R_TARGET=() R_CONN=() R_PATH=()

add_remote() {  # $1 = target, $2 = user@host[:path]
    local t="$1" spec="$2" conn path
    conn="${spec%%:*}"; path="${spec#*:}"
    [ "$path" = "$spec" ] && path="~/silica"
    R_TARGET+=("$t"); R_CONN+=("$conn"); R_PATH+=("$path")
}

have_remote() {  # $1 = target
    local i
    [ ${#R_TARGET[@]} -gt 0 ] || return 1
    for i in "${!R_TARGET[@]}"; do [ "${R_TARGET[$i]}" = "$1" ] && return 0; done
    return 1
}

conn_of() {  # $1 = target; prints user@host:path
    local i
    [ ${#R_TARGET[@]} -gt 0 ] || return 1
    for i in "${!R_TARGET[@]}"; do
        [ "${R_TARGET[$i]}" = "$1" ] && { echo "${R_CONN[$i]}:${R_PATH[$i]}"; return 0; }
    done
    return 1
}

for spec in ${REMOTE_SPECS[@]+"${REMOTE_SPECS[@]}"}; do
    [ -n "$spec" ] || continue
    case "$spec" in
        *=*) add_remote "${spec%%=*}" "${spec#*=}" ;;
        *)   echo "--remote needs <target>=<user@host>[:<path>]: $spec" >&2; exit 1 ;;
    esac
done

# Which platforms, and where their machines are.
SAVE_FILE=0
if [ -n "$SET_TARGETS" ]; then
    check_known "$SET_TARGETS"
    BUILD_TARGETS="$SET_TARGETS"; SAVE_FILE=1
elif [ -n "$SELECTED" ]; then
    check_known "$SELECTED"
    BUILD_TARGETS="$SELECTED"
    read_hosts_file >/dev/null 2>&1 || true     # reuse known machines, do not rewrite the file
elif [ "$REFRESH" = 1 ]; then
    read_hosts_file >/dev/null 2>&1 || true
    BUILD_TARGETS="${FILE_TARGETS:-$ALL_TARGETS}"
    R_TARGET=(); R_CONN=(); R_PATH=()           # ask again
    SAVE_FILE=1
elif read_hosts_file; then
    BUILD_TARGETS="$FILE_TARGETS"
    if [ -t 0 ]; then
        echo; echo "Remembered in $HOSTS_FILE:"
        for t in $FILE_TARGETS; do
            if [ "$t" = "$HOST_TARGET" ]; then echo "  $t   this machine"
            elif is_raw "$t"; then            echo "  $t   a board, cross compiler built here"
            elif c=$(conn_of "$t"); then      echo "  $t   $c"
            else                              echo "  $t   no machine recorded"
            fi
        done
        printf '\nuse these? [Y/n]: '; read -r keep
        case "$keep" in [Nn]*) BUILD_TARGETS=""; PICK_DEFAULT="$FILE_TARGETS"; SAVE_FILE=1 ;; esac
    else
        echo "using $HOSTS_FILE"
    fi
else
    BUILD_TARGETS=""; PICK_DEFAULT=all; SAVE_FILE=1
fi

# Nothing settled yet and someone is watching: ask which platforms, rather than assuming all of them.
if [ -z "$BUILD_TARGETS" ] && [ -t 0 ]; then
    echo; echo "Which platforms? Enter numbers separated by spaces, or 'all'."
    i=0; CHOICES=""
    for t in $ALL_TARGETS; do
        i=$((i+1)); CHOICES="$CHOICES $t"
        if [ "$t" = "$HOST_TARGET" ]; then echo "  $i) $t   this machine, built natively"
        elif is_raw "$t"; then            echo "  $i) $t   a board: its cross compiler is built here"
        else                              echo "  $i) $t   another machine, built there over ssh"
        fi
    done
    printf '\nplatforms [%s]: ' "${PICK_DEFAULT:-all}"
    read -r picks
    if [ -z "$picks" ]; then
        [ "${PICK_DEFAULT:-all}" = all ] && BUILD_TARGETS="$ALL_TARGETS" || BUILD_TARGETS="$PICK_DEFAULT"
    elif [ "$picks" = all ]; then
        BUILD_TARGETS="$ALL_TARGETS"
    else
        for n in $picks; do
            sel=$(echo $CHOICES | awk -v k="$n" '{print $k}')
            [ -n "$sel" ] && BUILD_TARGETS="$BUILD_TARGETS $sel" || echo "  ignoring '$n'"
        done
    fi
fi
[ -n "$BUILD_TARGETS" ] || BUILD_TARGETS="$ALL_TARGETS"

HOSTED_TARGETS=""; RAW_TARGETS=""
for t in $BUILD_TARGETS; do
    if is_raw "$t"; then RAW_TARGETS="$RAW_TARGETS $t"; else HOSTED_TARGETS="$HOSTED_TARGETS $t"; fi
done
BUILD_NATIVE=0
echo " $HOSTED_TARGETS " | grep -q " $HOST_TARGET " && BUILD_NATIVE=1
OTHER_HOSTED="$(echo $HOSTED_TARGETS | tr ' ' '\n' | grep -v "^$HOST_TARGET$" | tr '\n' ' ')"

echo "host platform   : $HOST_PLATFORM"
echo "native target   : $HOST_TARGET$([ "$BUILD_NATIVE" = 1 ] || echo " (not selected)")"
echo "other hosted    :$([ -n "$OTHER_HOSTED" ] && echo " $OTHER_HOSTED" || echo " none")"
echo "raw (cross here):$([ -n "$RAW_TARGETS" ] && echo "$RAW_TARGETS" || echo " none")"
echo "logs            : $LOG_DIR"

# ---------------------------------------------------------------- connections

EXPLICIT=0
{ [ -n "$SET_TARGETS" ] || [ "$REFRESH" = 1 ]; } && EXPLICIT=1

asked=0
if [ "$LOCAL_ONLY" = 0 ] && { [ "$LIST_ONLY" = 0 ] || [ "$EXPLICIT" = 1 ]; }; then
    for t in $OTHER_HOSTED; do
        have_remote "$t" && continue
        if [ ! -t 0 ]; then
            echo "no connection given for $t and nothing to ask on; skipping it"
            continue
        fi
        if [ "$asked" = 0 ]; then
            cat <<'EOF'

Each OS-hosted platform builds on its own machine, over ssh. The connection must be
public/private key ssh: this script runs ssh in batch mode and never types a password.
Set one up first with `ssh-keygen` and `ssh-copy-id user@host`, and check it with
`ssh -o BatchMode=yes user@host true`.
EOF
            asked=1
        fi
        printf '\n%s machine, as user@host (Enter to skip this platform): ' "$t"
        read -r conn
        [ -n "$conn" ] || { echo "  skipping $t"; continue; }
        if ssh -o BatchMode=yes -o ConnectTimeout=10 "$conn" true >/dev/null 2>&1; then
            echo "  key-based ssh to $conn works"
        else
            echo "  warning: ssh -o BatchMode=yes $conn true failed; the build there will fail until the key is in place"
        fi
        printf '  repository path on %s [~/silica]: ' "$conn"
        read -r path
        [ -n "$path" ] || path="~/silica"
        add_remote "$t" "$conn:$path"
    done
fi

if [ "$SAVE_FILE" = 1 ] && { [ "$LIST_ONLY" = 0 ] || [ "$EXPLICIT" = 1 ]; }; then
    write_hosts_file "$BUILD_TARGETS"
fi

if [ "$LIST_ONLY" = 1 ]; then
    echo
    [ "$BUILD_NATIVE" = 1 ] && \
        echo "  $HOST_TARGET: build here$([ "$DO_FIXPOINT" = 1 ] && echo ", then gen1, gen2 and the fixed-point check")"
    for t in $RAW_TARGETS; do echo "  $t: cross compiler built here (no OS, cannot host a compiler)"; done
    for t in $OTHER_HOSTED; do
        if conn="$(conn_of "$t")"; then
            echo "  $t: build and fixed point on $conn"
        elif [ "$LOCAL_ONLY" = 1 ]; then
            echo "  $t: skipped (--local-only)"
        else
            echo "  $t: needs a $t machine; this run would ask, or use --remote $t=user@host"
        fi
    done
    exit 0
fi


mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------- local helpers

# compiler/src compiles with binaries/seed-compiler, so that is the link that must exist.
# binaries/silica-compiler is what applications and the trials use; keep it current too.
seed_here() {
    [ -x "$BIN/update_silica_compiler_link.bash" ] && \
        bash "$BIN/update_silica_compiler_link.bash" >"$LOG_DIR/seed-link.log" 2>&1
    local native
    native="$(ls -t "$BIN"/silica-*-"$HOST_PLATFORM" 2>/dev/null | head -1)"
    [ -e "$BIN/silica-compiler" ] || { [ -n "$native" ] && ln -sf "$(basename "$native")" "$BIN/silica-compiler"; }
    if [ ! -e "$BIN/seed-compiler" ]; then
        local seed; seed="$(ls -t "$BIN"/silica-*-seed-"$HOST_PLATFORM" 2>/dev/null | head -1)"
        [ -n "$seed" ] || seed="$native"
        [ -n "$seed" ] && ln -sf "$(basename "$seed")" "$BIN/seed-compiler"
    fi
    [ -e "$BIN/seed-compiler" ]
}

local_build() {  # $1 = emit target
    local t="$1" log="$LOG_DIR/build-$1.log"
    echo "== build $t (here)"
    ( cd "$SRC" && make clean TARGET="$t" SILICA_TARGET_PROMPT=0 && \
      make build TARGET="$t" SILICA_TARGET_PROMPT=0 ${JOBS:+JOBS=$JOBS} ) >>"$log" 2>&1 || {
        echo "  FAILED (see $log)"; return 1; }
    grep -hE "Installed (selfhost|target).*compiler:" "$log" | tail -1 | sed 's/^/  /' || true
}

local_fixpoint() {
    local log="$LOG_DIR/fixpoint-$HOST_TARGET.log"
    echo "== fixed point for $HOST_TARGET (here)"
    ( cd "$SRC" && make clean SILICA_TARGET_PROMPT=0 && \
      make gen1 SILICA_TARGET_PROMPT=0 ${JOBS:+JOBS=$JOBS} && \
      make gen2 SILICA_TARGET_PROMPT=0 ${JOBS:+JOBS=$JOBS} && \
      make fixpoint SILICA_TARGET_PROMPT=0 ${JOBS:+JOBS=$JOBS} ) >>"$log" 2>&1
    local rc=$?
    if grep -q "0 emitted differently" "$log" && ! grep -q "byte-identical" "$log"; then
        echo "  units match, binary differs: the runtime's own text changed; shifting a generation"
        cp -f "$BIN/silica-gen2" "$BIN/silica-gen1"
        ( cd "$SRC" && make gen2 SILICA_TARGET_PROMPT=0 ${JOBS:+JOBS=$JOBS} && \
          make fixpoint SILICA_TARGET_PROMPT=0 ${JOBS:+JOBS=$JOBS} ) >>"$log" 2>&1; rc=$?
    fi
    grep -hE "units:|fixed point|FAIL" "$log" | tail -3 | sed 's/^/  /'
    [ $rc -eq 0 ] || { echo "  FAILED (see $log)"; return 1; }
    bash "$BIN/install_compiler.bash" seed "$BIN/silica-gen2" 2>&1 | tail -1 | sed 's/^/  /'
}

# ---------------------------------------------------------------- remote helpers

# Syncing a remote machine is programmer_tools/sync_to_hosts.sh (pull goldens back, delete what this
# tree no longer has, push without built artifacts); see its header.

remote_sh() { ssh -o BatchMode=yes "$1" "$2"; }

remote_build_and_fixpoint() {  # $1 = target, $2 = user@host, $3 = remote repo path
    local t="$1" conn="$2" rpath="$3" log="$LOG_DIR/remote-$1.log" rc

    echo "== $t on $conn"
    remote_sh "$conn" "true" >/dev/null 2>&1 || { echo "  cannot reach $conn over ssh"; return 1; }

    # sync_to_hosts.sh: pull this platform's goldens back, delete what this tree no longer has
    # (Lee's rule 2026-10-12; build outputs, binaries/ and this platform's goldens stay), then push.
    echo "  sync sources (sync_to_hosts.sh)"
    bash "$(dirname "${BASH_SOURCE[0]}")/sync_to_hosts.sh" --apply --remote "${t}=${conn}:${rpath}" \
        --list-dir "$LOG_DIR/sync" >>"$log" 2>&1 || { echo "  sync failed (see $log)"; return 1; }

    # The sync now deletes directories this tree no longer has, so this should not appear; it stays
    # as a check (the deleting sync refuses when more than 40% of the host would go).
    if remote_sh "$conn" "test -f $rpath/compiler/src/Makefile && test -d $rpath/compiler/silica-compiler" >/dev/null 2>&1; then
        local stale; stale="$(remote_sh "$conn" "du -sh $rpath/compiler/silica-compiler 2>/dev/null | cut -f1")"
        echo "  note: $conn still holds the pre-rename tree at $rpath/compiler/silica-compiler (${stale:-unknown size})."
        echo "        Nothing builds from it. To reclaim the space, on that machine: rm -rf $rpath/compiler/silica-compiler"
    fi

    if ! remote_sh "$conn" "test -x $rpath/binaries/silica-compiler" >/dev/null 2>&1; then
        echo "  no compiler there yet: handing one over (build here, emit here, link there)"
        ( cd "$SRC" && make clean TARGET="$t" SILICA_TARGET_PROMPT=0 && \
          make build TARGET="$t" SILICA_TARGET_PROMPT=0 INSTALL_SELFHOST=0 ${JOBS:+JOBS=$JOBS} && \
          make bootstrap-assembly BOOTSTRAP_TARGET="$t" SILICA_TARGET_PROMPT=0 ) >>"$log" 2>&1 || {
            echo "  hand-off build failed (see $log)"; return 1; }
        # The emitted assembly lives in compiler/build/<t>/, which the general sync excludes. Send
        # exactly what bootstrap-link needs from it: the .sams and silica.link (no objects, no
        # compiler, no unit symlinks, which point at this machine's paths).
        remote_sh "$conn" "mkdir -p $rpath/compiler/build/$t" >>"$log" 2>&1
        rsync -a --include '*/' --include '*.sams' --include 'silica.link' --exclude '*' \
            "$REPO/compiler/build/$t/" "$conn:$rpath/compiler/build/$t/" >>"$log" 2>&1 || {
            echo "  sync of the emitted assembly failed"; return 1; }
        remote_sh "$conn" "cd $rpath/$SRC_REL && make bootstrap-link" >>"$log" 2>&1 || {
            echo "  bootstrap-link failed on $conn (see $log)"; return 1; }
        echo "  first compiler linked on $conn"
        ( cd "$SRC" && make clean TARGET="$t" SILICA_TARGET_PROMPT=0 ) >/dev/null 2>&1
    fi

    if [ "$DO_FIXPOINT" = 1 ]; then
        echo "  build, gen1, gen2, fixed-point check (this takes hours on a small machine)"
        remote_sh "$conn" "cd $rpath/$SRC_REL && make clean SILICA_TARGET_PROMPT=0 && \
            make gen1 SILICA_TARGET_PROMPT=0 ${JOBS:+JOBS=$JOBS} && \
            make gen2 SILICA_TARGET_PROMPT=0 ${JOBS:+JOBS=$JOBS} && \
            make fixpoint SILICA_TARGET_PROMPT=0 ${JOBS:+JOBS=$JOBS}" >>"$log" 2>&1
        rc=$?
        if grep -q "0 emitted differently" "$log" && ! grep -q "byte-identical" "$log"; then
            echo "  units match, binary differs: shifting a generation on $conn"
            remote_sh "$conn" "cp -f $rpath/binaries/silica-gen2 $rpath/binaries/silica-gen1 && \
                cd $rpath/$SRC_REL && make gen2 SILICA_TARGET_PROMPT=0 && make fixpoint SILICA_TARGET_PROMPT=0" \
                >>"$log" 2>&1; rc=$?
        fi
        grep -hE "units:|fixed point|FAIL" "$log" | tail -3 | sed 's/^/  /'
        [ $rc -eq 0 ] || { echo "  FAILED on $conn (see $log)"; return 1; }
        remote_sh "$conn" "bash $rpath/binaries/install_compiler.bash seed $rpath/binaries/silica-gen2" \
            2>&1 | tail -1 | sed 's/^/  /'
    else
        echo "  build only (--no-fixpoint)"
        remote_sh "$conn" "cd $rpath/$SRC_REL && make clean SILICA_TARGET_PROMPT=0 && \
            make build SILICA_TARGET_PROMPT=0 ${JOBS:+JOBS=$JOBS}" >>"$log" 2>&1 || {
            echo "  FAILED on $conn (see $log)"; return 1; }
    fi

    if [ "$DO_TRIALS" = 1 ]; then
        echo "  trials on $conn"
        remote_sh "$conn" "cd $rpath/trials && make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET=host" \
            >>"$LOG_DIR/remote-trials-$t.log" 2>&1
        remote_sh "$conn" "grep -hE 'success:|fail:' $rpath/trials/.integrate_report" 2>/dev/null | sed 's/^/    /'
    fi
    return 0
}

# ---------------------------------------------------------------- run

declare -a ok=() bad=()

echo
# A seed is only needed when something is compiled on this machine.
BUILD_HERE=0
{ [ "$BUILD_NATIVE" = 1 ] || [ -n "$RAW_TARGETS" ]; } && BUILD_HERE=1

echo "== seed compiler here"
if [ "$BUILD_HERE" = 0 ]; then
    echo "  nothing is built here this run; skipping the seed check"
elif seed_here; then
    echo "  seed: $(basename "$(readlink "$BIN/seed-compiler" 2>/dev/null || echo "$BIN/seed-compiler")")"
else
    cat >&2 <<EOF
No seed compiler for $HOST_PLATFORM in binaries/, so this machine cannot start.
Run this script on a machine that has one and name this machine with
--remote $HOST_TARGET=<user@host>: it will hand a first compiler over.
EOF
    exit 1
fi

if [ "$BUILD_NATIVE" = 1 ]; then
    if [ "$DO_FIXPOINT" = 1 ]; then
        if local_fixpoint; then ok+=("$HOST_TARGET(native,fixed point)"); else bad+=("$HOST_TARGET"); fi
    else
        if local_build "$HOST_TARGET"; then ok+=("$HOST_TARGET(native)"); else bad+=("$HOST_TARGET"); fi
    fi
else
    echo "== $HOST_TARGET not selected; this machine builds only what was asked for"
fi

for t in $RAW_TARGETS; do
    if local_build "$t"; then ok+=("$t(cross)"); else bad+=("$t"); fi
done

# Only the platforms chosen for this run, even when the file remembers more machines.
for t in $OTHER_HOSTED; do
    conn_spec="$(conn_of "$t")" || continue
    conn="${conn_spec%%:*}"; rpath="${conn_spec#*:}"
    if remote_build_and_fixpoint "$t" "$conn" "$rpath"; then ok+=("$t@$conn"); else bad+=("$t@$conn"); fi
done

# No `make clean` here any more: each target builds in its own compiler/build/<target>/, so the
# next build, of any target, is not poisoned by this one and keeps its incremental state.

if [ "$DO_TRIALS" = 1 ]; then
    echo "== trials here"
    ( cd "$REPO/trials" && make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET=host ) \
        >"$LOG_DIR/trials-host.log" 2>&1
    grep -hE "success:|fail:" "$REPO/trials/.integrate_report" 2>/dev/null | sed 's/^/  /'
fi

echo
echo "done:   $([ ${#ok[@]} -gt 0 ] && echo "${ok[*]}" || echo none)"
[ ${#bad[@]} -gt 0 ] && echo "failed: ${bad[*]}"
for t in $OTHER_HOSTED; do
    have_remote "$t" || echo "skipped: $t (no machine given)"
done
echo "binaries in $BIN, logs in $LOG_DIR"
[ ${#bad[@]} -eq 0 ]
