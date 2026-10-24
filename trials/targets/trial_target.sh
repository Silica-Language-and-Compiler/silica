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
#   trial_target.sh check  <label>                   exit 1 (with a message) while another run holds the lock
#   trial_target.sh lock   <pid> <label> <target>     take the trial lock for process <pid>
#   trial_target.sh unlock <pid>                      release it, if <pid> holds it
#   trial_target.sh status                            print who holds the lock, if anyone
#   trial_target.sh choose                            menu on the terminal; prints host | <target> | both
#   trial_target.sh run <target|both> <dir> <make>    run the trials of <dir> (trials/ or one suite) there
#
# Only one trial run -- of any target -- may be in progress at a time: the runs share the suite
# directories, and a host run and a board run would also compete for memory. The lock is the
# directory trials/.integrate.lock (mkdir is atomic); its `owner` file names the holder. A lock
# whose holder process no longer exists is stale and is taken over.

set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
trials_root=$(cd "$here/.." && pwd)
repo_root=$(cd "$trials_root/.." && pwd)
lock_dir="$trials_root/.integrate.lock"

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

board_targets() {
    local f
    for f in "$here"/*.conf; do
        [ -f "$f" ] && basename "$f" .conf
    done
}

tty_ok() {
    { : </dev/tty; } 2>/dev/null && { : >/dev/tty; } 2>/dev/null
}

# Prints "<pid>\t<target>\t<label>\t<start>" of a live holder, or nothing.
lock_holder() {
    local opid otarget olabel ostart
    [ -d "$lock_dir" ] || return 0
    IFS=$'\t' read -r opid otarget olabel ostart < "$lock_dir/owner" 2>/dev/null || return 0
    if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\n' "$opid" "$otarget" "$olabel" "$ostart"
    fi
}

refuse() {
    local opid otarget olabel ostart
    IFS=$'\t' read -r opid otarget olabel ostart <<< "$1"
    printf '❌❌ another trial run is in progress: %s (target %s, started %s, pid %s).\n' "$olabel" "$otarget" "$ostart" "$opid" >&2
    printf '   Trial runs cannot overlap. Wait for it to finish or stop it (Ctrl-C in its terminal).\n' >&2
    printf '   If that process no longer exists, the lock is taken over automatically; to clear it by hand: rm -rf %s\n' "$lock_dir" >&2
    exit 1
}

cmd_check() {
    local h
    h=$(lock_holder)
    [ -z "$h" ] || refuse "$h"
}

cmd_lock() {
    local pid=$1 label=$2 target=$3 attempt h age
    for attempt in 1 2 3; do
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\t%s\t%s\t%s\n' "$pid" "$target" "$label" "$(date '+%Y-%m-%d %H:%M:%S')" > "$lock_dir/owner"
            return 0
        fi
        h=$(lock_holder)
        [ -z "$h" ] || refuse "$h"
        # No live holder. A lock directory whose owner file is not written yet may belong to a run
        # that is starting this very moment: give it a few seconds before calling it stale.
        if [ ! -f "$lock_dir/owner" ]; then
            age=$(( $(date +%s) - $(mtime_of "$lock_dir") ))
            if [ "$age" -lt 5 ]; then sleep 2; continue; fi
        fi
        rm -rf "$lock_dir"
    done
    die "could not take the trial lock $lock_dir"
}

cmd_unlock() {
    local pid=$1 opid rest
    [ -f "$lock_dir/owner" ] || return 0
    IFS=$'\t' read -r opid rest < "$lock_dir/owner" 2>/dev/null || return 0
    if [ "$opid" = "$pid" ]; then rm -rf "$lock_dir"; fi
    return 0
}

cmd_status() {
    local h opid otarget olabel ostart
    h=$(lock_holder)
    if [ -z "$h" ]; then echo "no trial run in progress"; return 0; fi
    IFS=$'\t' read -r opid otarget olabel ostart <<< "$h"
    printf 'trial run in progress: %s (target %s, started %s, pid %s)\n' "$olabel" "$otarget" "$ostart" "$opid"
}

# The menu. Without a usable terminal, or with no board target defined, the answer is host.
cmd_choose() {
    local targets=() t i answer n
    while IFS= read -r t; do [ -n "$t" ] && targets+=("$t"); done < <(board_targets)
    if [ "${#targets[@]}" -eq 0 ] || ! tty_ok; then echo host; return 0; fi
    n=${#targets[@]}
    while :; do
        {
            printf 'Select the trial target (make integrate):\n'
            printf '  1) host  [default]   %s, binaries/silica-compiler\n' "$(host_label)"
            i=1
            for t in "${targets[@]}"; do
                i=$((i + 1))
                # shellcheck disable=SC1090
                desc=$(TARGET_DESCRIPTION=""; . "$here/$t.conf"; printf '%s' "$TARGET_DESCRIPTION")
                printf '  %d) %s   %s, binaries/silica-compiler-%s\n' "$i" "$t" "$desc" "$t"
            done
            if [ "$n" -eq 1 ]; then
                printf '  %d) both   host, then %s (one after the other)\n' $((n + 2)) "${targets[0]}"
            else
                printf '  %d) both   host, then every board target (one after the other)\n' $((n + 2))
            fi
            printf 'Number or name [host]: '
        } >/dev/tty
        read -r answer </dev/tty || { echo host; return 0; }
        case "$answer" in
            ""|1|host) echo host; return 0 ;;
            both|$((n + 2))) echo both; return 0 ;;
        esac
        i=1
        for t in "${targets[@]}"; do
            i=$((i + 1))
            if [ "$answer" = "$i" ] || [ "$answer" = "$t" ]; then echo "$t"; return 0; fi
        done
        printf 'Unknown choice "%s"; pick one of the listed numbers or names.\n' "$answer" >/dev/tty
    done
}

# Board port: $BOARD_PORT, else the single candidate; with several, ask (terminal) or fail.
choose_port() {
    local py=$1 runner=$2 ports=() p i answer
    if [ -n "${BOARD_PORT:-}" ]; then echo "$BOARD_PORT"; return 0; fi
    while IFS= read -r p; do [ -n "$p" ] && ports+=("$p"); done < <("$py" "$runner" --list-ports)
    if [ "${#ports[@]}" -eq 0 ]; then
        die "no board found: no USB serial port. Is the board plugged in and switched on? (Or set BOARD_PORT.)"
    fi
    if [ "${#ports[@]}" -eq 1 ]; then echo "${ports[0]}"; return 0; fi
    tty_ok || die "several serial ports (${ports[*]}); set BOARD_PORT=<port> to choose the board."
    while :; do
        {
            printf 'Several serial ports; which one is the board?\n'
            i=0
            for p in "${ports[@]}"; do i=$((i + 1)); printf '  %d) %s\n' "$i" "$p"; done
            printf 'Number: '
        } >/dev/tty
        read -r answer </dev/tty || die "no port chosen"
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
    TARGET_DESCRIPTION=""; TARGET_BOARD_DIR=""; TARGET_PYTHON=""
    # shellcheck disable=SC1090
    . "$conf"
    local board_dir="$repo_root/$TARGET_BOARD_DIR"
    local tools="$board_dir/tools"
    local py="${BOARD_PYTHON:-$TARGET_PYTHON}"
    local compiler="${BOARD_SILICA_COMPILER:-$repo_root/binaries/silica-compiler-$target}"
    local mirror="$trials_root/.target/$target"
    local reqs="docs/required-software.md"

    # --- preflight: everything that can fail is checked before anything is compiled ---
    [ -x "$compiler" ] || die "missing $compiler.
   Build and publish it: cd compiler/src && make TARGET=$target
   (or point BOARD_SILICA_COMPILER at a built compiler)."
    [ -x "$py" ] || die "no Python with esptool at $py (the ESP-IDF Python environment; see $reqs, or set BOARD_PYTHON)."
    "$py" -c 'import esptool, serial' 2>/dev/null || die "$py cannot import esptool and pyserial (see $reqs)."
    [ -f "$tools/run_on_board.py" ] && [ -f "$tools/build_image.sh" ] || die "board tools missing under $tools"

    local suites=() s
    while IFS= read -r s; do [ -n "$s" ] && suites+=("$s"); done < <(suites_of "$dir")

    local port probe
    port=$(choose_port "$py" "$tools/run_on_board.py") || exit 1
    probe=$("$py" "$tools/run_on_board.py" --probe --port "$port" ${BOARD_MAC:+--expect-mac "$BOARD_MAC"} 2>&1) \
        || die "board check failed: ${probe#run_on_board: }"

    rm -rf "$mirror"
    mkdir -p "$mirror"
    sh "$tools/build_image.sh" -r "$mirror/.rt" --prepare > "$mirror/.rt.log" 2>&1 \
        || die "cannot assemble the board runtime (is the Xtensa toolchain installed? see $reqs):
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

    export TRIAL_TARGET="$target" BOARD_PORT="$port" BOARD_SILICA_COMPILER="$compiler" BOARD_PYTHON="$py" \
        BOARD_TOOLS="$tools" BOARD_RT_CACHE="$mirror/.rt" TRIALS_ROOT="$trials_root"
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

cmd_run() {
    local target=$1 dir=$2 make=$3 st=0 t
    # Every run started from here is marked, and a marked run never dispatches again, so no
    # combination of settings can make trial runs start each other in a loop.
    export SILICA_INTEGRATE_DISPATCHED=1
    case "$target" in
        both)
            "$make" --no-print-directory -C "$dir" integrate TRIAL_TARGET=host || st=1
            while IFS= read -r t; do
                [ -n "$t" ] || continue
                ( run_board "$t" "$dir" "$make" ) || st=1
            done < <(board_targets)
            return $st
            ;;
        *)
            run_board "$target" "$dir" "$make"
            ;;
    esac
}

case "${1:-}" in
    check)  shift; cmd_check "$@" ;;
    lock)   shift; cmd_lock "$@" ;;
    unlock) shift; cmd_unlock "$@" ;;
    status) cmd_status ;;
    choose) cmd_choose ;;
    run)    shift; cmd_run "$@" ;;
    *) echo "usage: trial_target.sh check|lock|unlock|status|choose|run ..." >&2; exit 2 ;;
esac
