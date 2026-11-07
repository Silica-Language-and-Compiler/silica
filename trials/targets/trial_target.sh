#!/usr/bin/env bash
# Copyright 2026 Lee Scott Barney
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Trial targets for `make integrate` (see README.md in this directory). Called by the integrate
# wrapper in ../silica_compiler.mk; not meant to be run by hand, except `status`.
#
#   trial_target.sh lock   <pid> <label> <target>     take the trial lock of <target> for process <pid>
#   trial_target.sh check  <label> [<target>]         exit 1 (with a message) while another run holds <target>'s lock
#   trial_target.sh unlock <pid>                      release every lock <pid> holds
#   trial_target.sh status                            print who holds which lock
#   trial_target.sh hostbusy [<own pid>]              exit 0 and print the pid while a live process other than <own pid>
#                                                     holds THIS machine's host lock; exit 1 when it is free or <own pid>'s
#   trial_target.sh choose                            menu on the terminal; prints a selection (see below)
#   trial_target.sh normalize <selection>             print `host` or the canonical target list; exit 1 on an unknown name
#   trial_target.sh run <selection> <dir> <make>      run the trials of <dir> (trials/ or one suite) there
#
# A selection is host, a board target (a <name>.conf here), a remote hosted machine (linux_aarch64,
# linux_x86_64: a line of .silica_build_hosts), `all` (host + the remotes + the boards), `both`
# (host + the boards), or a comma/space list of those. Several targets run IN PARALLEL.
#
# One trial run per TARGET, not one in total: each target has its own lock directory,
# trials/.integrate.lock.<target> (mkdir is atomic); the host's key is the machine's own target name
# (macos_applesilicon on the Mac, linux_aarch64 / linux_x86_64 on the Linux machines). Its `owner` file
# names the holder; a lock whose holder process no longer exists is stale and is taken over. Two runs
# of the SAME target are refused (they share the suite directories); runs of different targets overlap.

set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
trials_root=$(cd "$here/.." && pwd)
repo_root=$(cd "$trials_root/.." && pwd)
hosts_file="${SILICA_BUILD_HOSTS:-$repo_root/.silica_build_hosts}"

# The emit-target name of the machine running the trials (the key platforms.mk and .silica_build_hosts use).
native_emit() {
    case "$(uname -s):$(uname -m)" in
        Darwin:arm64)              echo apple_silicon_mac ;;
        Linux:x86_64)              echo linux_x86_64 ;;
        Linux:aarch64|Linux:arm64) echo linux_aarch64 ;;
        *)                         echo "$(uname -s)_$(uname -m)" ;;
    esac
}

# The key a host run names its files after: macos_applesilicon on the Mac, else the emit target.
# Keep in step with SOUT_TARGET in ../silica_compiler.mk.
host_key() {
    case "$(native_emit)" in
        apple_silicon_mac) echo macos_applesilicon ;;
        *)                 native_emit ;;
    esac
}

# Name of the machine running the trials, for the menu and notices.
host_label() {
    case "$(uname -s):$(uname -m)" in
        Darwin:arm64)           echo "this Mac (Apple Silicon)" ;;
        Darwin:*)               echo "this Mac" ;;
        Linux:x86_64)           echo "this machine (Linux x86-64)" ;;
        Linux:aarch64|Linux:arm64) echo "this machine (Linux AArch64)" ;;
        *)                      echo "this machine" ;;
    esac
}

# Seconds since the file or directory was modified; 0 if it cannot be read (GNU stat, then BSD).
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

die() {
    printf '❌❌ %s\n' "$*" >&2
    exit 1
}

# A missing prerequisite of one target. A single-target run stops with it (status 1). Inside a
# multi-target run (TRIAL_ALLOW_SKIP=1) it ends only that target with status 77, which the combined
# summary reports as SKIPPED with this reason; the other targets carry on.
SKIP_RC=77
pdie() {
    printf '❌❌ %s\n' "$*" >&2
    if [ "${TRIAL_ALLOW_SKIP:-}" = 1 ]; then exit "$SKIP_RC"; fi
    exit 1
}

board_targets() {
    local f
    for f in "$here"/*.conf; do
        [ -f "$f" ] && basename "$f" .conf
    done
}

# The remote hosted machines this tree can drive: the hosted Linux targets other than this machine.
remote_targets() {
    local t
    for t in linux_aarch64 linux_x86_64; do
        [ "$t" = "$(native_emit)" ] || echo "$t"
    done
}

is_board()  { [ -f "$here/$1.conf" ]; }
is_remote() { local t; for t in $(remote_targets); do [ "$t" = "$1" ] && return 0; done; return 1; }

# Short description of a remote target for the menu; never prints the machine's address.
remote_desc() {
    case "$1" in
        linux_aarch64) echo "Linux AArch64 (pix), remote hosted: sync, then its own binaries/silica-compiler" ;;
        linux_x86_64)  echo "Linux x86-64 (nix), remote hosted: sync, then its own binaries/silica-compiler" ;;
        *)             echo "remote hosted machine" ;;
    esac
}

# "<user@host> <path>" of a remote target from .silica_build_hosts (read, never printed by this script
# except inside a command it runs); fails when the file has no such machine.
remote_machine() {
    local t conn path
    [ -f "$hosts_file" ] || return 1
    while read -r t conn path; do
        case "$t" in ''|\#*) continue ;; esac
        if [ "$t" = "$1" ]; then
            case "$conn" in local|ask|-|'') return 1 ;; esac
            printf '%s %s\n' "$conn" "${path:-~/silica}"
            return 0
        fi
    done < "$hosts_file"
    return 1
}

# Canonical names: host, a remote, or a board. host_key and the native emit name mean host.
canon_token() {
    case "$1" in
        host|"$(host_key)"|"$(native_emit)"|macos_applesilicon|apple_silicon_mac|mac) echo host ;;
        *) echo "$1" ;;
    esac
}

# Expand a selection (comma/space separated) to one canonical target per line, without repeats.
# `all` = host, the remotes, the boards; `both` = host, the boards. An unknown name is an error.
expand_selection() {
    local sel=${1//,/ } tok t out="" known
    [ -n "${sel// /}" ] || sel=host
    for tok in $sel; do
        case "$tok" in
            all)  for t in host $(remote_targets) $(board_targets); do out="$out $t"; done ;;
            both) for t in host $(board_targets); do out="$out $t"; done ;;
            *)
                t=$(canon_token "$tok")
                if [ "$t" != host ] && ! is_remote "$t" && ! is_board "$t"; then
                    known="host $(remote_targets | tr '\n' ' ')$(board_targets | tr '\n' ' ')all both"
                    printf '❌❌ unknown trial target '"'"'%s'"'"' (defined: %s)\n' "$tok" "$known" >&2
                    return 1
                fi
                out="$out $t"
                ;;
        esac
    done
    printf '%s\n' $out | awk '!seen[$0]++'
}

# The lock key of a canonical target: the host's own key, else the target's name.
key_of() { if [ "$1" = host ]; then host_key; else echo "$1"; fi; }
lock_dir_of() { echo "$trials_root/.integrate.lock.$(key_of "$(canon_token "$1")")"; }

tty_ok() {
    [ "${TRIAL_NONINTERACTIVE:-}" != 1 ] || return 1
    { : </dev/tty; } 2>/dev/null && { : >/dev/tty; } 2>/dev/null
}

# Prints "<pid>\t<target>\t<label>\t<start>" of a live holder of lock directory $1, or nothing.
lock_holder() {
    local d=$1 opid otarget olabel ostart
    [ -d "$d" ] || return 0
    IFS=$'\t' read -r opid otarget olabel ostart < "$d/owner" 2>/dev/null || return 0
    if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\n' "$opid" "$otarget" "$olabel" "$ostart"
    fi
}

busy_message() {  # $1 = holder line, $2 = lock dir
    local opid otarget olabel ostart
    IFS=$'\t' read -r opid otarget olabel ostart <<< "$1"
    printf '❌❌ another trial run of target %s is in progress: %s (started %s, pid %s).\n' "$otarget" "$olabel" "$ostart" "$opid" >&2
    printf '   Two runs of one target cannot overlap (runs of other targets can). Wait for it to finish or stop it (Ctrl-C in its terminal).\n' >&2
    printf '   If that process no longer exists, the lock is taken over automatically; to clear it by hand: rm -rf %s\n' "$2" >&2
}

cmd_check() {
    local label=${1:-} t=${2:-host} d h
    d=$(lock_dir_of "$t")
    h=$(lock_holder "$d")
    if [ -n "$h" ]; then busy_message "$h" "$d"; exit 1; fi
}

# Take the lock of canonical target $3 for process $1. Returns 0 taken, 1 busy (message printed).
try_lock() {
    local pid=$1 label=$2 target=$3 d attempt h age key
    key=$(key_of "$target")
    d=$(lock_dir_of "$target")
    for attempt in 1 2 3; do
        if mkdir "$d" 2>/dev/null; then
            printf '%s\t%s\t%s\t%s\n' "$pid" "$key" "$label" "$(date '+%Y-%m-%d %H:%M:%S')" > "$d/owner"
            return 0
        fi
        h=$(lock_holder "$d")
        if [ -n "$h" ]; then busy_message "$h" "$d"; return 1; fi
        # No live holder. A lock directory whose owner file is not written yet may belong to a run
        # that is starting this very moment: give it a few seconds before calling it stale.
        if [ ! -f "$d/owner" ]; then
            age=$(( $(date +%s) - $(mtime_of "$d") ))
            if [ "$age" -lt 5 ]; then sleep 2; continue; fi
        fi
        rm -rf "$d"
    done
    printf '❌❌ could not take the trial lock %s\n' "$d" >&2
    return 1
}

cmd_lock() {
    local pid=$1 label=$2 target=${3:-host}
    try_lock "$pid" "$label" "$(canon_token "$target")" || exit 1
}

# Release every lock <pid> holds (one per target it locked).
cmd_unlock() {
    local pid=$1 d opid rest
    for d in "$trials_root"/.integrate.lock.*; do
        [ -d "$d" ] || continue
        [ -f "$d/owner" ] || continue
        IFS=$'\t' read -r opid rest < "$d/owner" 2>/dev/null || continue
        if [ "$opid" = "$pid" ]; then rm -rf "$d"; fi
    done
    return 0
}

cmd_status() {
    local d h opid otarget olabel ostart any=0
    for d in "$trials_root"/.integrate.lock.*; do
        [ -d "$d" ] || continue
        h=$(lock_holder "$d")
        [ -n "$h" ] || continue
        any=1
        IFS=$'\t' read -r opid otarget olabel ostart <<< "$h"
        printf 'trial run in progress: %s (target %s, started %s, pid %s)\n' "$olabel" "$otarget" "$ostart" "$opid"
    done
    [ "$any" = 1 ] || echo "no trial run in progress"
    return 0
}

# `hostbusy [<own pid>]`: is this machine's host run in progress? Exit 0 and print the holder's pid when a
# live process other than <own pid> holds the host lock (a nested run, a board or remote run, or any other
# caller counts as "other"); exit 1 when the lock is free, stale, or held by <own pid> itself. Used by
# ensure-silica-compiler (../silica_compiler.mk) to leave binaries/silica-compiler alone during a host run.
cmd_hostbusy() {
    local own=${1:-} h pid
    h=$(lock_holder "$(lock_dir_of host)")
    [ -n "$h" ] || return 1
    pid=${h%%$'\t'*}
    [ -z "$own" ] || [ "$pid" != "$own" ] || return 1
    printf '%s\n' "$pid"
}

# The menu: every target, then `all`. Without a usable terminal the answer is host. The answer is one
# name, a number, or several of them separated by spaces or commas.
cmd_choose() {
    local names=() descs=() t i answer n tok pick sel
    names+=(host); descs+=("$(host_label), binaries/silica-compiler  [default]")
    for t in $(remote_targets); do names+=("$t"); descs+=("$(remote_desc "$t")"); done
    for t in $(board_targets); do
        # shellcheck disable=SC1090
        descs+=("$(TARGET_DESCRIPTION=""; . "$here/$t.conf"; printf '%s, binaries/silica-compiler-%s' "$TARGET_DESCRIPTION" "$t")")
        names+=("$t")
    done
    n=${#names[@]}
    if ! tty_ok; then echo host; return 0; fi
    while :; do
        {
            printf 'Select the trial target (make integrate):\n'
            for i in $(seq 1 "$n"); do
                printf '  %d) %s   %s\n' "$i" "${names[$((i - 1))]}" "${descs[$((i - 1))]}"
            done
            printf '  %d) all   every target above, at the same time (the host run, the remote runs and the boards)\n' $((n + 1))
            printf '  (several: "2 3 5" or "linux_x86_64,ESP32-S3_raw"; `both` = host + the boards. Runs of different targets overlap.)\n'
            printf 'Number(s) or name(s) [host]: '
        } >/dev/tty
        read -r answer </dev/tty || { echo host; return 0; }
        answer=${answer//,/ }
        [ -n "${answer// /}" ] && [ "$answer" != "1" ] || { echo host; return 0; }
        sel="" pick=1
        for tok in $answer; do
            if [ "$tok" = "$((n + 1))" ]; then tok=all
            elif [ "$tok" -ge 1 ] 2>/dev/null && [ "$tok" -le "$n" ] 2>/dev/null; then tok=${names[$((tok - 1))]}; fi
            if ! expand_selection "$tok" >/dev/null 2>&1; then
                printf 'Unknown choice "%s"; pick one of the listed numbers or names.\n' "$tok" >/dev/tty
                pick=0; break
            fi
            sel="$sel $tok"
        done
        [ "$pick" = 1 ] && { echo $sel; return 0; }
    done
}

cmd_normalize() {
    local list
    list=$(expand_selection "${1:-host}") || exit 1
    if [ "$list" = host ]; then echo host; else echo $list; fi
}

# Board port: $BOARD_PORT, else the target's TARGET_PORT_DEFAULT when that exists, else the single
# candidate; with several, ask (terminal) or fail. $3 is TARGET_PORT_DEFAULT (may be empty).
choose_port() {
    local py=$1 runner=$2 default=${3:-} ports=() p i answer
    if [ -n "${BOARD_PORT:-}" ]; then echo "$BOARD_PORT"; return 0; fi
    if [ -n "$default" ] && [ -e "$default" ]; then echo "$default"; return 0; fi
    while IFS= read -r p; do [ -n "$p" ] && ports+=("$p"); done < <("$py" "$runner" --list-ports)
    if [ "${#ports[@]}" -eq 0 ]; then
        pdie "no board found: no USB serial port. Is the board plugged in and switched on? (Or set BOARD_PORT.)"
    fi
    if [ "${#ports[@]}" -eq 1 ]; then echo "${ports[0]}"; return 0; fi
    tty_ok || pdie "several serial ports (${ports[*]}); set BOARD_PORT=<port> to choose the board."
    while :; do
        {
            printf 'Several serial ports; which one is the board?\n'
            i=0
            for p in "${ports[@]}"; do i=$((i + 1)); printf '  %d) %s\n' "$i" "$p"; done
            printf 'Number: '
        } >/dev/tty
        read -r answer </dev/tty || pdie "no port chosen"
        i=0
        for p in "${ports[@]}"; do
            i=$((i + 1))
            if [ "$answer" = "$i" ] || [ "$answer" = "$p" ]; then echo "$p"; return 0; fi
        done
    done
}

# The suites of <dir>: every suite of the tree for trials/ (or the ones TRIAL_SUITES names), else
# the one suite <dir> names.
suites_of() {
    local dir=$1 rel d
    if [ "$dir" = "$trials_root" ] && [ -n "${TRIAL_SUITES:-}" ]; then
        for d in $TRIAL_SUITES; do
            [ -f "$trials_root/$d/Makefile" ] || [ -f "$trials_root/$d/makefile" ] || die "TRIAL_SUITES: no suite named $d"
            echo "$d"
        done
        return 0
    fi
    if [ "$dir" = "$trials_root" ]; then
        for d in "$trials_root"/*/; do
            d=${d%/}
            [ -f "$d/Makefile" ] || [ -f "$d/makefile" ] || continue
            basename "$d"
        done | LC_ALL=C sort
        return 0
    fi
    rel=${dir#"$trials_root"/}
    case "$rel" in
        */*|"$dir") die "board trials run from trials/ or from a top-level suite directory, not $dir" ;;
    esac
    [ -f "$dir/Makefile" ] || [ -f "$dir/makefile" ] || die "$dir has no Makefile"
    echo "$rel"
}

run_board() {
    local target=$1 dir=$2 make=$3
    local conf="$here/$target.conf"
    [ -f "$conf" ] || die "unknown trial target '$target' (defined: host $(board_targets | tr '\n' ' '))"
    TARGET_DESCRIPTION=""; TARGET_BOARD_DIR=""; TARGET_PYTHON=""; TARGET_ASCOMP_PLATFORM=""
    TARGET_IMAGE_EXT="bin"; TARGET_PORT_DEFAULT=""; TARGET_PY_MODULES="esptool serial"; TARGET_TOOLS=""
    # shellcheck disable=SC1090
    . "$conf"
    local board_dir="$repo_root/$TARGET_BOARD_DIR"
    local tools="$board_dir/tools"
    local py="${BOARD_PYTHON:-$TARGET_PYTHON}"
    local compiler="${BOARD_SILICA_COMPILER:-$repo_root/binaries/silica-compiler-$target}"
    local mirror="$trials_root/.target/$target"
    local reqs="docs/required-software.md"

    # --- preflight: everything that can fail is checked before anything is compiled ---
    [ -x "$compiler" ] || pdie "missing $compiler.
   Build and publish it: cd compiler/src && make TARGET=$target
   (or point BOARD_SILICA_COMPILER at a built compiler)."
    [ -x "$py" ] || pdie "no Python with ${TARGET_PY_MODULES// / and } at $py (see $reqs, or set BOARD_PYTHON)."
    "$py" -c "import ${TARGET_PY_MODULES// /, }" 2>/dev/null || pdie "$py cannot import ${TARGET_PY_MODULES// / and } (see $reqs)."
    local tool
    for tool in $TARGET_TOOLS; do
        command -v "$tool" > /dev/null 2>&1 || pdie "$tool not found on PATH (needed by trial target $target; see $reqs)."
    done
    [ -f "$tools/run_on_board.py" ] && [ -f "$tools/build_image.sh" ] || pdie "board tools missing under $tools"

    local suites=() s
    while IFS= read -r s; do [ -n "$s" ] && suites+=("$s"); done < <(suites_of "$dir")

    local port probe
    port=$(choose_port "$py" "$tools/run_on_board.py" "$TARGET_PORT_DEFAULT") || exit $?
    probe=$("$py" "$tools/run_on_board.py" --probe --port "$port" ${BOARD_MAC:+--expect-mac "$BOARD_MAC"} 2>&1) \
        || pdie "board check failed: ${probe#run_on_board: }"

    rm -rf "$mirror"
    mkdir -p "$mirror"
    sh "$tools/build_image.sh" -r "$mirror/.rt" --prepare > "$mirror/.rt.log" 2>&1 \
        || pdie "cannot assemble the board runtime (is the target's toolchain installed? see $reqs):
$(head -5 "$mirror/.rt.log")"

    # --- skip list: whole suites and single trials ---
    local skipfile="$here/$target.skip" entry reason run_suites=() skipped_suites=()
    : > "$mirror/.skipped_suites"
    for s in "${suites[@]}"; do
        reason=""
        if [ -f "$skipfile" ]; then
            reason=$(awk -v s="$s" '!/^[[:space:]]*#/ && NF >= 1 && $1 == s { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }' "$skipfile")
            [ -n "$reason" ] || reason=$(awk -v s="$s" '!/^[[:space:]]*#/ && NF == 1 && $1 == s { print "listed in '"$target"'.skip"; exit }' "$skipfile")
        fi
        # INTEGRATE_PENDING keeps a suite out of whole-tree runs only; a suite named by TRIAL_SUITES
        # or run from its own directory is run (board-only suites such as device_actor_addition).
        if [ -z "$reason" ] && [ "$dir" = "$trials_root" ] && [ -z "${TRIAL_SUITES:-}" ] \
            && [ -f "$trials_root/$s/INTEGRATE_PENDING" ]; then
            reason="INTEGRATE_PENDING (see $s/README.md)"
        fi
        if [ -n "$reason" ]; then
            skipped_suites+=("$s")
            printf '%s\t%s\n' "$s" "$reason" >> "$mirror/.skipped_suites"
        else
            run_suites+=("$s")
            mkdir -p "$mirror/$s"
            : > "$mirror/$s/.skip_trials"
            if [ -f "$skipfile" ]; then
                awk -v s="$s" '!/^[[:space:]]*#/ && index($1, s "/") == 1 { stem = substr($1, length(s) + 2); $1 = ""; sub(/^[[:space:]]+/, ""); printf "%s\t%s\n", stem, $0 }' \
                    "$skipfile" > "$mirror/$s/.skip_trials"
            fi
            {
                printf '# Generated by trials/targets/trial_target.sh for one %s trial run; do not edit.\n' "$target"
                printf 'TRIAL_MIRROR := 1\nTRIAL_TARGET := %s\nBOARD_SUITE := %s\n' "$target" "$s"
                printf 'INTEGRATE_LABEL_OVERRIDE := %s/%s\n' "$target" "$s"
                printf 'include %s/board_suite.mk\n' "$here"
            } > "$mirror/$s/Makefile"
        fi
    done
    {
        printf '# Generated by trials/targets/trial_target.sh for one %s trial run; do not edit.\n' "$target"
        printf 'TRIAL_MIRROR := 1\nTRIAL_TARGET := %s\n' "$target"
        printf 'BOARD_SUITES := %s\n' "${run_suites[*]:-}"
        printf 'BOARD_SKIPPED_SUITES := %s\n' "${skipped_suites[*]:-}"
        printf 'INTEGRATE_LABEL_OVERRIDE := %s\n' "$target"
        printf 'include %s/board_root.mk\n' "$here"
    } > "$mirror/Makefile"

    printf 'Trial target %s: %s\n' "$target" "$TARGET_DESCRIPTION"
    printf '  compiler: %s -> %s\n' "$compiler" "$(readlink "$compiler" 2>/dev/null || echo "$compiler")"
    printf '  board:    %s\n' "$probe"
    printf '  suites:   %d to run, %d skipped (%s)\n' "${#run_suites[@]}" "${#skipped_suites[@]}" "targets/$target.skip"
    printf '  outputs:  <suite>/<trial>.%s.sout next to each trial; report: trials/.integrate_report.%s\n' "$target" "$target"
    if [ "${#run_suites[@]}" -gt 1 ]; then
        printf '  A board run of the whole tree takes hours; the host is kept awake while it runs (where caffeinate or systemd-inhibit exists).\n'
    fi

    # BOARD_ASCOMP=off: output only, no assembly-golden check (a target whose .ascomp goldens are not written yet)
    local ascomp_platform="$TARGET_ASCOMP_PLATFORM"
    [ "${BOARD_ASCOMP:-}" != off ] || ascomp_platform=""
    export TRIAL_TARGET="$target" BOARD_PORT="$port" BOARD_SILICA_COMPILER="$compiler" BOARD_PYTHON="$py" \
        BOARD_TOOLS="$tools" BOARD_RT_CACHE="$mirror/.rt" TRIALS_ROOT="$trials_root" \
        BOARD_ASCOMP_PLATFORM="$ascomp_platform" BOARD_IMAGE_EXT="$TARGET_IMAGE_EXT"
    # TRIAL_TARGET goes on the command line: a TRIAL_TARGET given to the user's make is passed down
    # in MAKEFLAGS and would override both the environment and the generated makefile.
    local st
    if command -v caffeinate > /dev/null 2>&1; then
        caffeinate -i "$make" --no-print-directory -C "$mirror" integrate TRIAL_TARGET="$target"
    elif command -v systemd-inhibit > /dev/null 2>&1; then
        systemd-inhibit --what=idle:sleep --why="silica trials" "$make" --no-print-directory -C "$mirror" integrate TRIAL_TARGET="$target"
    else
        "$make" --no-print-directory -C "$mirror" integrate TRIAL_TARGET="$target"
    fi
    st=$?
    if [ -f "$mirror/.integrate_report" ]; then
        cp "$mirror/.integrate_report" "$trials_root/.integrate_report.$target"
        [ "$dir" != "$trials_root" ] && cp "$mirror/.integrate_report" "$dir/.integrate_report.$target"
    fi
    return $st
}

# The suites of <dir> are chosen by suites_of above. The rest of this file runs a selection.

# ---------------------------------------------------------------- remote hosted machines

# Per-machine parallelism, as programmer_tools/run_trials_all_platforms.sh uses it (4 GB Pi, 13 GB nix).
remote_jobs() {  # $1 = target; prints "<JOBS> <SDS_JOBS>"
    case "$1" in
        linux_aarch64) echo "${PI_JOBS:-2} ${PI_SDS_JOBS:-1}" ;;
        linux_x86_64)  echo "${NIX_JOBS:-3} ${NIX_SDS_JOBS:-1}" ;;
        *)             echo " 1" ;;
    esac
}

# ssh -o BatchMode=yes to the machine; a clear message (never a password prompt or a hang) when key
# authentication fails. The machine's address is replaced in ssh's message.
remote_ssh_check() {  # $1 = target, $2 = conn
    local err rc=0
    err=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$2" true 2>&1 < /dev/null) || rc=$?
    [ "$rc" -eq 0 ] && return 0
    err=$(printf '%s' "$err" | tail -n 1 | sed "s|$2|<machine>|g; s|${2#*@}|<machine>|g")
    pdie "ssh key authentication to the $1 machine failed (ssh -o BatchMode=yes <the $1 machine in .silica_build_hosts> true, status $rc): ${err:-no message}
   Set the key up with ssh-keygen and ssh-copy-id; no password is ever typed here."
}

# Run <dir>'s trials on the remote machine of target $1: check ssh, sync this tree with
# programmer_tools/sync_to_hosts.sh, run `make integrate` there with the machine's own compiler (its own
# host run, its own lock), stream its output, and copy its report to .integrate_report.<target> here.
# TRIAL_REMOTE_SYNC=0 skips the sync; SILICA_REMOTE_DRY_RUN=1 checks ssh, runs the sync as a dry run
# (nothing changes on either side) and prints the remote command instead of running it.
run_remote() {
    local target=$1 dir=$2 line conn rpath rel mirror jobs sds suites_arg="" cmd st rrep rc_sync=0
    line=$(remote_machine "$target") || pdie "no machine for $target in .silica_build_hosts (a line '$target <user@host> <path>'); add it, or give SILICA_BUILD_HOSTS"
    conn=${line%% *}; rpath=${line#* }
    remote_ssh_check "$target" "$conn" || exit $?
    [ -f "$repo_root/programmer_tools/sync_to_hosts.sh" ] || pdie "programmer_tools/sync_to_hosts.sh is missing"
    mirror="$trials_root/.target/$target"
    mkdir -p "$mirror"
    rel=${dir#"$repo_root"/}
    read -r jobs sds <<< "$(remote_jobs "$target")"
    [ -z "${TRIAL_SUITES:-}" ] || suites_arg=" TRIAL_SUITES='${TRIAL_SUITES}'"
    cmd="cd $rpath/$rel && make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET=host${jobs:+ JOBS=$jobs} SDS_JOBS=${sds:-1}$suites_arg"

    printf 'Trial target %s: %s\n' "$target" "$(remote_desc "$target")"
    printf '  machine:  reached with ssh -o BatchMode=yes (key authentication)\n'
    printf '  outputs:  the remote log streams below and is kept in trials/.target/%s/.integrate_log; report: trials/.integrate_report.%s\n' "$target" "$target"

    if [ "${TRIAL_REMOTE_SYNC:-1}" != 0 ]; then
        printf '  sync:     programmer_tools/sync_to_hosts.sh %s--targets %s\n' "$([ "${SILICA_REMOTE_DRY_RUN:-}" = 1 ] || printf -- '--apply ')" "$target"
        bash "$repo_root/programmer_tools/sync_to_hosts.sh" $([ "${SILICA_REMOTE_DRY_RUN:-}" = 1 ] || echo --apply) \
            --targets "$target" --list-dir "$mirror/sync" || rc_sync=$?
        [ "$rc_sync" -eq 0 ] || { printf '❌❌ sync to the %s machine failed (status %s); not running the trials there.\n' "$target" "$rc_sync" >&2; return 1; }
    else
        printf '  sync:     skipped (TRIAL_REMOTE_SYNC=0)\n'
    fi
    if [ "${SILICA_REMOTE_DRY_RUN:-}" = 1 ]; then
        printf '  dry run:  would run on the %s machine: %s\n' "$target" "$cmd"
        return 0
    fi

    : > "$mirror/.integrate_log"
    ssh -o BatchMode=yes -o ServerAliveInterval=30 "$conn" "$cmd" 2>&1 < /dev/null | tee -a "$mirror/.integrate_log"
    st=${PIPESTATUS[0]}

    # The remote's own report is named after its native target (its host run), the plain name on an older tree.
    rrep="$mirror/.integrate_report.remote"
    ssh -o BatchMode=yes "$conn" "cd $rpath/$rel && { cat .integrate_report.$target 2>/dev/null || cat .integrate_report; }" > "$rrep" 2>/dev/null < /dev/null
    if [ ! -s "$rrep" ]; then
        { printf '════ integrate report: %s ════\n' "$target"
          printf 'success: ✅✅ 0\nfail: ❌❌ 1\nelapsed: -\nfailures:\n    (the remote run produced no report; ssh/make status %s; see %s)\n' "$st" "$mirror/.integrate_log"
          printf 'log: %s\n' "$mirror/.integrate_log"; } > "$rrep"
        [ "$st" -ne 0 ] || st=1
    fi
    cp "$rrep" "$trials_root/.integrate_report.$target"
    [ "$dir" = "$trials_root" ] || cp "$rrep" "$dir/.integrate_report.$target"
    return "$st"
}

# ---------------------------------------------------------------- one target, then the selection

run_one_target() {  # $1 = canonical target, $2 = dir, $3 = make
    case "$1" in
        host)
            "$3" --no-print-directory -C "$2" integrate TRIAL_TARGET=host
            ;;
        *)
            if is_board "$1"; then run_board "$1" "$2" "$3"
            elif is_remote "$1"; then run_remote "$1" "$2"
            else die "unknown trial target '$1'"; fi
            ;;
    esac
}

report_of() {  # $1 = canonical target, $2 = dir
    echo "$2/.integrate_report.$(key_of "$1")"
}

# Counts a report states: "<pass> <fail>" (digits only; ? when it has none).
report_counts() {
    local p f
    p=$(grep -m1 'success:' "$1" 2>/dev/null | tr -dc '0-9'); f=$(grep -m1 'fail:' "$1" 2>/dev/null | tr -dc '0-9')
    echo "${p:-?} ${f:-?}"
}

cmd_run() {
    local sel=$1 dir=$2 make=$3 list t n i st=0 key
    local -a targets=() pids=() logs=() rcs=() started=()
    list=$(expand_selection "$sel") || exit 1
    while IFS= read -r t; do [ -n "$t" ] && targets+=("$t"); done <<< "$list"
    n=${#targets[@]}
    # Every run started from here is marked, and a marked run never dispatches again, so no
    # combination of settings can make trial runs start each other in a loop.
    export SILICA_INTEGRATE_DISPATCHED=1

    # One trial run per target: take every selected target's lock with this process's pid; the runs
    # started below share them through SILICA_INTEGRATE_LOCK_PID. A busy target stops a single-target run
    # and is skipped (with the holder named) in a multi-target run.
    local label=trials; [ "$dir" = "$trials_root" ] || label=${dir#"$trials_root"/}
    local -a run_targets=() skipped=() skip_why=()
    for t in "${targets[@]}"; do
        if try_lock "$$" "$label" "$t" 2> "${TMPDIR:-/tmp}/.trial_lock.$$"; then
            run_targets+=("$t")
        elif [ "$n" -eq 1 ]; then
            cat "${TMPDIR:-/tmp}/.trial_lock.$$" >&2; rm -f "${TMPDIR:-/tmp}/.trial_lock.$$"; exit 1
        else
            skipped+=("$t"); skip_why+=("$(sed -n 's/^❌❌ //p' "${TMPDIR:-/tmp}/.trial_lock.$$" | head -n 1)")
        fi
    done
    rm -f "${TMPDIR:-/tmp}/.trial_lock.$$"
    export SILICA_INTEGRATE_LOCK_PID=$$
    trap 'for p in ${pids[@]+"${pids[@]}"}; do pkill -TERM -P "$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null; done; bash "$here/trial_target.sh" unlock $$; exit 130' INT TERM
    trap 'bash "$here/trial_target.sh" unlock $$' EXIT

    if [ "${#run_targets[@]}" -eq 1 ] && [ "$n" -eq 1 ]; then
        # One target: in the foreground, on the terminal, exactly as before.
        ( run_one_target "${run_targets[0]}" "$dir" "$make" ); st=$?
        [ "$st" -ne "$SKIP_RC" ] || st=1
        return $st
    fi

    # Several targets: all at once, each with its own log; prerequisites missing -> skipped with the reason.
    export TRIAL_ALLOW_SKIP=1 TRIAL_NONINTERACTIVE=1
    printf 'Running %d targets at the same time: %s\n' "${#run_targets[@]}" "${run_targets[*]:-none}"
    case " ${run_targets[*]:-} " in *" host "*)
        printf 'Memory: the host run peaks at 6-8 GB; the remote and board runs add little on this machine.\n' ;;
    esac
    for t in "${run_targets[@]}"; do
        key=$(key_of "$t")
        mkdir -p "$trials_root/.target/$key"
        rm -f "$(report_of "$t" "$dir")"
        [ "$dir" = "$trials_root" ] || rm -f "$(report_of "$t" "$trials_root")"
        logs+=("$trials_root/.target/$key/.all.log")
        ( run_one_target "$t" "$dir" "$make" ) > "$trials_root/.target/$key/.all.log" 2>&1 < /dev/null &
        pids+=($!); started+=("$(date +%s)")
        printf '  started %-18s log %s\n' "$t" "$trials_root/.target/$key/.all.log"
    done
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}"; rcs+=($?)
        printf '  finished %-17s status %s\n' "${run_targets[$i]}" "${rcs[$i]}"
    done

    # Combined summary.
    local rc rep cnt pass fail status detail overall=0
    printf '\n%-20s %-8s %-9s %-9s %s\n' TARGET STATUS PASSED FAILED 'REPORT / REASON'
    for i in "${!run_targets[@]}"; do
        t=${run_targets[$i]}; rc=${rcs[$i]}; rep=$(report_of "$t" "$dir")
        if [ "$rc" -eq "$SKIP_RC" ]; then
            detail=$(sed -n 's/^❌❌ //p' "${logs[$i]}" | head -n 1)
            printf '%-20s %-8s %-9s %-9s %s\n' "$t" SKIPPED - - "$detail"
            continue
        fi
        read -r pass fail <<< "$(report_counts "$rep")"
        if [ "$rc" -eq 0 ]; then status=PASS; else status=FAIL; overall=1; fi
        printf '%-20s %-8s %-9s %-9s %s\n' "$t" "$status" "$pass" "$fail" "$rep"
    done
    for i in "${!skipped[@]}"; do
        printf '%-20s %-8s %-9s %-9s %s\n' "${skipped[$i]}" SKIPPED - - "${skip_why[$i]}"
    done
    printf '\nFull logs: trials/.target/<target>/.all.log. A skipped target is not a failure; read each failing report.\n'
    return $overall
}

case "${1:-}" in
    check)     shift; cmd_check "$@" ;;
    lock)      shift; cmd_lock "$@" ;;
    unlock)    shift; cmd_unlock "$@" ;;
    status)    cmd_status ;;
    hostbusy)  cmd_hostbusy "${2:-}" ;;
    choose)    cmd_choose ;;
    normalize) shift; cmd_normalize "$@" ;;
    run)       shift; cmd_run "$@" ;;
    *) echo "usage: trial_target.sh check|lock|unlock|status|hostbusy|choose|normalize|run ..." >&2; exit 2 ;;
esac
