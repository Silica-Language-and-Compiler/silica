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

# Build and run ONE hand-run pin app on the ESP32-S3 e-badge (macOS). See README.md here.
#
#   run_hand_app.sh [options] <app>
#
# <app> is device_grounded_35, device_power_36, device_twopin_35_drives or device_twopin_36_drives (the
# .silica file in this directory, with or without the extension).
#
# Steps: compile with the installed binaries/silica-compiler-ESP32-S3_raw (the sources are copied to a
# temporary directory), build the RAM image, check that no other board run is active (a trial run's lock,
# the board lock, processes using the board's tools or serial port), write 'RUN STARTING, jumper must be IN
# between <pins>' to the status file, pause 15 s (the jumper goes in during the pause or before), check again,
# load the image and stream the console. On the line 'PULL THE JUMPER' (and again at '10 s left') it plays
# a sound and posts a notification; at 'DONE' it does so once more and writes
# 'DONE: <p> PASS, <f> FAIL' to the status file. The PASS/FAIL counts are the step lines ending
# ': PASS' / ': FAIL' (not the SUMMARY line's numbers).
#
# Options:
#   --build-only      compile and build the image only; no checks, no status file, nothing touches the board
#   --pause S         seconds between the status line and the load (default 15)
#   --timeout S       seconds the program may run before the run counts as hung (default 150)
#   --port P          serial port (default $BOARD_PORT, else the target's default port, else the only one)
#   --keep            keep the temporary build directory
#   -h, --help        this text
#
# Environment: BOARD_PYTHON (Python with esptool + pyserial), BOARD_PORT, SILICA_COMPILER / BOARD_SILICA_COMPILER,
# HAND_STATUS_FILE (default: the scratchpad esp_status.txt below).
#
# Exit status: 0 the run printed DONE with no FAIL step; 1 a FAIL step; 2 usage or a precondition failed;
# 3 the program did not finish; 4 the board is unavailable; 5 compile failure; 6 image build failure; 7 the
# board is in use by another run.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BOARD=$(cd "$HERE/../../.." && pwd)                 # .../ESP32-S3_raw/board
COMPILER_ROOT=$(cd "$BOARD/../../../.." && pwd)     # compiler/
REPO=$(cd "$COMPILER_ROOT/.." && pwd)
TRIALS="$REPO/trials"
TARGET=ESP32-S3_raw
TOOLS="$BOARD/tools"
STATUS=${HAND_STATUS_FILE:-/private/tmp/claude-501/-Volumes-2T-silica/e3b4f0ea-081d-496d-bfaa-fe5a90e42862/scratchpad/esp_status.txt}

die() { echo "run_hand_app: $1" >&2; exit "${2:-2}"; }
st() { local m="$*"; echo "$(date '+%H:%M:%S') $m" >> "$STATUS"; echo "[status] $m" >&2; }
notify() {   # $1 = message: a sound and a macOS notification
    ( afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 & ) 2>/dev/null
    osascript -e "display notification \"$1\" with title \"ESP32 hand test\"" >/dev/null 2>&1 || true
}

pause=15 timeout=150 port=${BOARD_PORT:-} keep=0 build_only=0 app=""
while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) build_only=1; shift ;;
        --pause)   [ $# -ge 2 ] || die "--pause needs a value"; pause=$2; shift 2 ;;
        --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; timeout=$2; shift 2 ;;
        --port)    [ $# -ge 2 ] || die "--port needs a value"; port=$2; shift 2 ;;
        --keep)    keep=1; shift ;;
        -h|--help) sed -n '16,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1 (see --help)" ;;
        *)  [ -z "$app" ] || die "one app at a time ($app, $1)"; app=${1%.silica}; shift ;;
    esac
done
[ -n "$app" ] || die "which app? device_grounded_35 | device_power_36 | device_twopin_35_drives | device_twopin_36_drives"
case "$app" in
    device_grounded_35)       wiring="GPIO35 (J3 pin 8, silk U1TX) and GND (J3 pin 6, silk GND)" ;;
    device_power_36)          wiring="GPIO36 (J3 pin 10, silk U1RX) and 3V3 (J11 pin 4, silk 3.3V; NOT 5Vn)" ;;
    device_twopin_35_drives|device_twopin_36_drives)
                              wiring="GPIO35 (J3 pin 8, silk U1TX) and GPIO36 (J3 pin 10, silk U1RX)" ;;
    *) die "unknown app '$app'" ;;
esac
src="$HERE/$app.silica"
[ -f "$src" ] || die "no $src"

# --- tools --------------------------------------------------------------------------------------------
IDF_PYTHON="$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python"
if [ -n "${BOARD_PYTHON:-}" ]; then py=$BOARD_PYTHON; elif [ -x "$IDF_PYTHON" ]; then py=$IDF_PYTHON; else py=python3; fi
export BOARD_PYTHON="$py"
compiler=${SILICA_COMPILER:-${BOARD_SILICA_COMPILER:-$REPO/binaries/silica-compiler-$TARGET}}
[ -x "$compiler" ] || die "no $TARGET compiler at $compiler (set SILICA_COMPILER)"
[ -f "$COMPILER_ROOT/stdlib/Supervisor.silica" ] || die "no compiler/stdlib/Supervisor.silica"
[ -f "$TRIALS/lib_trial_support/trial_wait_int64.silica" ] || die "no trials/lib_trial_support/trial_wait_int64.silica"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/silica_hand.XXXXXX") || die "cannot create a temporary directory"
cleanup() {
    bash "$TRIALS/targets/trial_target.sh" unlock $$ >/dev/null 2>&1
    if [ "$keep" = 1 ]; then echo "run_hand_app: kept $tmp" >&2; else rm -rf "$tmp"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$tmp/src" "$tmp/image"

# --- compile -----------------------------------------------------------------------------------------
cp "$src" "$tmp/src/$app.silica"
cp "$COMPILER_ROOT/stdlib/Supervisor.silica" "$TRIALS/lib_trial_support/trial_wait_int64.silica" "$tmp/src/"
printf '%s.silica\ntrial_wait_int64.silica\nSupervisor.silica\n' "$app" > "$tmp/src/silica.config"
echo "run_hand_app: compiling $app with $compiler" >&2
(
    cd "$tmp/src" || exit 1
    while true; do "$compiler"; ec=$?; case "$ec" in 75|76) continue ;; *) exit "$ec" ;; esac; done
) > "$tmp/compile.log" 2>&1
ec=$?
if [ "$ec" -ne 0 ]; then tail -n 40 "$tmp/compile.log" >&2; die "compilation failed (exit $ec)" 5; fi
for f in "$app" trial_wait_int64 Supervisor __silica_runtime; do [ -f "$tmp/src/$f.sams" ] || die "the compiler emitted no $f.sams" 5; done

# --- image -------------------------------------------------------------------------------------------
echo "run_hand_app: building the image" >&2
if ! sh "$TOOLS/build_image.sh" -r "$tmp/rt" --prepare > "$tmp/rt.log" 2>&1; then cat "$tmp/rt.log" >&2; die "cannot assemble the board runtime" 6; fi
if ! ( cd "$tmp/src" && sh "$TOOLS/build_image.sh" -r "$tmp/rt" -o "$tmp/image/$app" "$app.sams" trial_wait_int64.sams Supervisor.sams __silica_runtime.sams ) > "$tmp/image.log" 2>&1; then
    cat "$tmp/image.log" >&2; die "image build failed" 6
fi
sed 's/^/  /' "$tmp/image.log" >&2
if [ "$build_only" = 1 ]; then echo "run_hand_app: built $app (--build-only: the board was not touched)" >&2; exit 0; fi

# --- the board must be free --------------------------------------------------------------------------
if [ -z "$port" ]; then
    TARGET_PORT_DEFAULT=""; . "$TRIALS/targets/$TARGET.conf"
    if [ -n "$TARGET_PORT_DEFAULT" ] && [ -e "$TARGET_PORT_DEFAULT" ]; then port=$TARGET_PORT_DEFAULT; fi
fi
board_busy() {   # prints the reason and returns 0 while another run may be using the board
    local p
    if ! bash "$TRIALS/targets/trial_target.sh" check "hand $app" "$TARGET" 2>&1; then return 0; fi
    p=$(ps -axo pid=,command= | grep -E "ESP32-S3_raw/board/tools/(run_on_board|run_app|run_pin_tests|usb_console_check)|esptool|board_suite\.sh|run_one_trial\.sh|stream_on_board" \
        | grep -v grep | awk -v me="$$" '$1 != me' | head -3)
    if [ -n "$p" ]; then echo "another process uses the board tools:"; echo "$p"; return 0; fi
    if [ -n "$port" ] && [ -e "$port" ] && command -v lsof >/dev/null 2>&1; then
        p=$(lsof "$port" 2>/dev/null | tail -n +2 | head -3)
        if [ -n "$p" ]; then echo "the serial port $port is open in another process:"; echo "$p"; return 0; fi
    fi
    return 1
}
if r=$(board_busy); then echo "$r" >&2; die "the board is in use by another run; nothing was loaded" 7; fi
bash "$TRIALS/targets/trial_target.sh" lock $$ "hand $app" "$TARGET" || die "could not take the $TARGET trial lock" 7

st "RUN STARTING, jumper must be IN between $wiring ($app); loading in $pause s"
echo "run_hand_app: the jumper must be IN between $wiring. Loading in $pause s (Ctrl-C to stop)." >&2
notify "Jumper must be IN: $wiring. Loading in $pause s."
sleep "$pause"
# the lock is ours now, so the trial-lock check would report ourselves: re-check processes and the port only
p=$(ps -axo pid=,command= | grep -E "ESP32-S3_raw/board/tools/(run_on_board|run_app|run_pin_tests|usb_console_check)|esptool|board_suite\.sh|run_one_trial\.sh|stream_on_board" \
    | grep -v grep | awk -v me="$$" '$1 != me' | head -3)
if [ -n "$p" ]; then st "ABORTED: another board process appeared during the pause: $p"; die "another board process is running; nothing was loaded" 7; fi
if [ -n "$port" ] && [ -e "$port" ] && command -v lsof >/dev/null 2>&1 && [ -n "$(lsof "$port" 2>/dev/null | tail -n +2)" ]; then
    st "ABORTED: the serial port $port is open in another process"; die "serial port busy; nothing was loaded" 7
fi
st "loading the board now ($app)"

# --- run, streaming the console ---------------------------------------------------------------------
runner=("$py" "$HERE/stream_on_board.py" --timeout "$timeout" --out "$tmp/$app.sout")
[ -n "$port" ] && runner+=(--port "$port")
runner+=("$tmp/image/$app.bin")
: > "$tmp/console.txt"
pulled=0 tenleft=0 donecnt=0
# flock on trials/.board.lock for the life of the run (not waiting: a busy board is an error), as run_app.sh does
perl -MFcntl=:flock -e '
    $^F = 255; $| = 1;
    my $lock = shift @ARGV;
    open(my $f, ">>", $lock) or die "run_hand_app: board lock $lock: $!\n";
    flock($f, LOCK_EX | LOCK_NB) or do { print STDERR "run_hand_app: the board lock is held by another run\n"; exit 7 };
    exec @ARGV or exit 127;
' "$TRIALS/.board.lock" "${runner[@]}" 2> "$tmp/run.err" | while IFS= read -r line; do
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$tmp/console.txt"
    case "$line" in
        *"PULL THE JUMPER"*)
            if [ "$pulled" = 0 ]; then
                pulled=1; st "PULL THE JUMPER NOW (30 s window)"; notify "PULL THE JUMPER NOW"
            fi
            case "$line" in *" 10 s left"*) if [ "$tenleft" = 0 ]; then tenleft=1; notify "PULL THE JUMPER: 10 s left"; fi ;; esac ;;
        DONE) notify "DONE" ;;
    esac
done
rc=${PIPESTATUS[0]}
cat "$tmp/run.err" >&2
p=$(grep -c ': PASS$' "$tmp/console.txt"); f=$(grep -c ': FAIL$' "$tmp/console.txt")
if grep -qx 'DONE' "$tmp/console.txt"; then
    st "DONE: $p PASS, $f FAIL ($(grep -m1 '^SUMMARY' "$tmp/console.txt" || echo 'no SUMMARY line')); exit status $rc"
    [ "$rc" = 0 ] || exit "$rc"
    [ "$f" = 0 ] && [ "$p" != 0 ] && exit 0
    exit 1
fi
st "ENDED WITHOUT DONE: $p PASS, $f FAIL, run_on_board exit $rc"
case "$rc" in 0) exit 3 ;; *) exit "$rc" ;; esac
