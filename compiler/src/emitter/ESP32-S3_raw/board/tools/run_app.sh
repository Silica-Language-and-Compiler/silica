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

# Build one board app and run it on the ESP32-S3 board.
#
#   run_app.sh [options] <app>
#
# <app> is a directory under board/apps (silica_21_device_led_row, asm_00_hello, ...) or a path to
# such a directory. A Silica app (apps/silica_*) is compiled with an ESP32-S3_raw compiler together
# with the files its extra_sources.txt lists (one path per line, relative to compiler/, in
# dependency order); an assembly app (apps/asm_*) is its main.S. The image is built with
# build_image.sh, loaded into the board's RAM and run with run_on_board.py (nothing is written to
# flash unless --flash is given), and the console output is printed in .sout form: the program's
# output, then its exit status on its own line. When the app has an expected.scout, the run is
# compared with it through compare_sout.sh (fatal-report addresses folded) and the result reported.
#
# Everything is built in a temporary directory: the sources are COPIED there and compiled there, so
# no .sams / .iface lands next to the real sources (compiling a tracked file in place, by its own
# path, writes the ESP32 outputs over the host's tracked ones). The directory is removed at the end
# unless --keep is given.
#
# Options:
#   --send TEXT        write TEXT to the console once the program has started (run_on_board.py
#                      --send; Python escapes, e.g. --send 'exit\n' ends a main waiting in
#                      wait_for_exit with status 0)
#   --send-delay S     seconds after the start marker before --send is written (default 1)
#   --timeout S        seconds the program may run before the run counts as hung (default 60)
#   --port P           the board's serial port (default $BOARD_PORT, else the one USB serial port)
#   --flash            write the image to flash at 0x0 and run it from there (default: RAM)
#   --build-only       compile and build the image, do not touch the board
#   --keep             keep the temporary directory (its path is printed)
#   -h, --help         this text
#
# Environment:
#   SILICA_COMPILER    the ESP32-S3_raw compiler (also read: BOARD_SILICA_COMPILER). Default: the
#                      published binaries/silica-compiler-ESP32-S3_raw, else the local build
#                      compiler/build/ESP32-S3_raw/silica-compiler.
#   BOARD_PYTHON       Python with esptool and pyserial (default: the ESP-IDF 6.2 environment,
#                      ~/.espressif/python_env/idf6.2_py3.14_env/bin/python)
#   BOARD_PORT, BOARD_MAC, XTENSA_BIN, ESPTOOL   as for run_on_board.py and build_image.sh
#
# The board is used under the same lock as the board trial runs (trials/.board.lock, flock), and
# the script refuses to start while a board trial run holds trials/.integrate.lock.
#
# Exit status: 0 the run matched expected.scout (or ran, when there is none); 1 the output differs
# from expected.scout; 2 usage; 3 no exit marker before the timeout; 4 the board is unavailable;
# 5 compile failure; 6 image build failure; 7 a board trial run is in progress.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BOARD=$(cd "$HERE/.." && pwd)
APPS="$BOARD/apps"
COMPILER_ROOT=$(cd "$BOARD/../../../.." && pwd)      # compiler/
REPO=$(cd "$COMPILER_ROOT/.." && pwd)
TRIALS="$REPO/trials"

usage() { sed -n "/^# Build one board app/,/^$/p" "$0" | sed "s/^# \{0,1\}//"; }
die() { echo "run_app: $1" >&2; exit "${2:-2}"; }

send="" send_set=0 send_delay="" timeout="" port="" flash=0 build_only=0 keep=0 app=""
while [ $# -gt 0 ]; do
    case "$1" in
        --send)       [ $# -ge 2 ] || die "--send needs a value"; send=$2; send_set=1; shift 2 ;;
        --send-delay) [ $# -ge 2 ] || die "--send-delay needs a value"; send_delay=$2; shift 2 ;;
        --timeout)    [ $# -ge 2 ] || die "--timeout needs a value"; timeout=$2; shift 2 ;;
        --port)       [ $# -ge 2 ] || die "--port needs a value"; port=$2; shift 2 ;;
        --flash)      flash=1; shift ;;
        --build-only) build_only=1; shift ;;
        --keep)       keep=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           die "unknown option $1 (see --help)" ;;
        *)            [ -z "$app" ] || die "one app at a time ($app, $1)"; app=$1; shift ;;
    esac
done
[ -n "$app" ] || { usage >&2; exit 2; }

# --- the app ---------------------------------------------------------------------------------------
if [ -d "$APPS/$app" ]; then
    appdir="$APPS/$app"
elif [ -d "$app" ]; then
    appdir=$(cd "$app" && pwd)
else
    die "no app '$app' (expected a directory under $APPS)"
fi
name=$(basename "$appdir")

silica_srcs=()
for f in "$appdir"/*.silica; do [ -f "$f" ] && silica_srcs+=("$f"); done
kind=""
if [ "${#silica_srcs[@]}" -gt 0 ]; then
    kind=silica
elif [ -f "$appdir/main.S" ]; then
    kind=asm
else
    die "$appdir has neither .silica sources nor a main.S"
fi

# --- tools -----------------------------------------------------------------------------------------
IDF_PYTHON="$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python"
if [ -n "${BOARD_PYTHON:-}" ]; then
    py=$BOARD_PYTHON
elif [ -x "$IDF_PYTHON" ]; then
    py=$IDF_PYTHON
else
    py=python3
fi
export BOARD_PYTHON="$py"      # build_image.sh runs main_stack_bound.py with it

compiler=""
if [ "$kind" = silica ]; then
    compiler=${SILICA_COMPILER:-${BOARD_SILICA_COMPILER:-}}
    if [ -z "$compiler" ]; then
        if [ -e "$REPO/binaries/silica-compiler-ESP32-S3_raw" ]; then
            compiler="$REPO/binaries/silica-compiler-ESP32-S3_raw"
        else
            compiler="$COMPILER_ROOT/build/ESP32-S3_raw/silica-compiler"
        fi
    fi
    [ -x "$compiler" ] || die "no ESP32-S3_raw compiler at $compiler (set SILICA_COMPILER)"
    case "$compiler" in /*) ;; *) compiler="$(cd "$(dirname "$compiler")" && pwd)/$(basename "$compiler")" ;; esac
fi

# --- temporary directory -----------------------------------------------------------------------------
tmpbase=${TMPDIR:-/tmp}
tmp=$(mktemp -d "${tmpbase%/}/silica_run_app.XXXXXX") || die "cannot create a temporary directory" 2
cleanup() {
    if [ "$keep" = 1 ]; then
        echo "run_app: kept $tmp" >&2
    else
        rm -rf "$tmp"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$tmp/src" "$tmp/image"

# --- compile (Silica apps) ---------------------------------------------------------------------------
sources=()
if [ "$kind" = silica ]; then
    : > "$tmp/src/silica.config"
    seen=$'\n'
    add_source() {   # copy one source into the build directory and list it in silica.config
        local f=$1 b
        b=$(basename "$f")
        case "$seen" in *$'\n'"$b"$'\n'*) die "two sources named $b (the build directory is flat)" ;; esac
        seen="$seen$b"$'\n'
        cp "$f" "$tmp/src/$b" || die "cannot copy $f" 5
        printf '%s\n' "$b" >> "$tmp/src/silica.config"
    }
    if [ -f "$appdir/extra_sources.txt" ]; then
        while IFS= read -r rel || [ -n "$rel" ]; do
            rel=${rel%$'\r'}
            case "$rel" in ''|'#'*) continue ;; esac
            [ -f "$COMPILER_ROOT/$rel" ] || die "extra_sources.txt names $rel, not found under $COMPILER_ROOT" 5
            add_source "$COMPILER_ROOT/$rel"
        done < "$appdir/extra_sources.txt"
    fi
    for f in "${silica_srcs[@]}"; do add_source "$f"; done

    echo "run_app: compiling $name with $compiler" >&2
    (
        cd "$tmp/src" || exit 1
        while true; do       # exit 75/76: the compiler's reclaim loop, continue with the next unit
            "$compiler"; ec=$?
            case "$ec" in 75|76) continue ;; *) exit "$ec" ;; esac
        done
    ) > "$tmp/compile.log" 2>&1
    ec=$?
    if [ "$ec" -ne 0 ]; then
        tail -n 40 "$tmp/compile.log" >&2
        die "compilation failed (exit $ec); --keep keeps the build directory and its compile.log" 5
    fi
    # the app's units first, then the extra sources in dependency order, then the runtime unit
    for f in "${silica_srcs[@]}"; do
        s="$tmp/src/$(basename "${f%.silica}").sams"
        [ -f "$s" ] || die "the compiler emitted no $(basename "$s")" 5
        sources+=("$s")
    done
    while IFS= read -r b; do
        s="$tmp/src/${b%.silica}.sams"
        case " ${sources[*]} " in *" $s "*) continue ;; esac
        [ -f "$s" ] && sources+=("$s")
    done < "$tmp/src/silica.config"
    for s in "$tmp/src"/*.sams; do
        [ -f "$s" ] || continue
        case " ${sources[*]} " in *" $s "*) ;; *) sources+=("$s") ;; esac
    done
else
    sources=("$appdir/main.S")
fi

# --- image -------------------------------------------------------------------------------------------
img="$tmp/image/$name"
echo "run_app: building the image" >&2
# from the app's directory, so an assembly app's .include (asm_10_pin_hunt's pins.inc) resolves;
# build_image.sh writes only under $tmp
if ! ( cd "$appdir" && sh "$HERE/build_image.sh" -r "$tmp/rtcache" -o "$img" "${sources[@]}" ) > "$tmp/image.log" 2>&1; then
    cat "$tmp/image.log" >&2
    die "image build failed" 6
fi
sed 's/^/  /' "$tmp/image.log" >&2
if [ "$build_only" = 1 ]; then
    if [ "$keep" = 1 ]; then
        echo "run_app: image $img.bin (--build-only: not run)" >&2
    else
        echo "run_app: the image built (--build-only: not run; add --keep to keep it)" >&2
    fi
    exit 0
fi

# --- board -------------------------------------------------------------------------------------------
# A board trial run holds trials/.integrate.lock for its whole length and takes the board lock per
# trial only, so check the run lock too: between two trials the board lock is free.
owner="$TRIALS/.integrate.lock/owner"
if [ -f "$owner" ]; then
    IFS=$'\t' read -r opid otarget _ < "$owner"
    if [ -n "${opid:-}" ] && [ "${otarget:-host}" != host ] && kill -0 "$opid" 2>/dev/null; then
        die "a board trial run is in progress (target $otarget, pid $opid); try again when it ends" 7
    fi
fi

runner=("$py" "$HERE/run_on_board.py")
[ -n "$port" ] && runner+=(--port "$port")
[ -n "$timeout" ] && runner+=(--timeout "$timeout")
[ "$send_set" = 1 ] && runner+=(--send "$send")
[ -n "$send_delay" ] && runner+=(--send-delay "$send_delay")
[ "$flash" = 1 ] && runner+=(--flash)
runner+=(--out "$tmp/$name.sout" "$img.bin")

echo "run_app: running $name on the board" >&2
# flock on trials/.board.lock, held for the life of run_on_board.py ($^F keeps the descriptor open
# across exec, as board_suite.sh does)
perl -MFcntl=:flock -e '
    $^F = 255;
    my $lock = shift @ARGV;
    open(my $f, ">>", $lock) or die "run_app: board lock $lock: $!\n";
    unless (flock($f, LOCK_EX | LOCK_NB)) {
        print STDERR "run_app: waiting for the board lock ($lock)\n";
        flock($f, LOCK_EX) or die "run_app: board lock: $!\n";
    }
    exec @ARGV or exit 127;
' "$TRIALS/.board.lock" "${runner[@]}"
rc=$?
if [ "$rc" -ne 0 ]; then
    case "$rc" in
        3) echo "run_app: no exit marker before the timeout (the program hung, waits for input -- try --send 'exit\\n' -- or died before reporting)" >&2 ;;
        4) echo "run_app: the board is unavailable" >&2 ;;
    esac
    exit "$rc"
fi

cat "$tmp/$name.sout"
golden="$appdir/expected.scout"
if [ ! -f "$golden" ]; then
    echo "run_app: $name has no expected.scout; nothing to compare" >&2
    exit 0
fi
if sh "$HERE/compare_sout.sh" "$tmp/$name.sout" "$golden" > "$tmp/compare.diff" 2>&1; then
    echo "run_app: MATCH: the output equals $name/expected.scout" >&2
    exit 0
fi
echo "run_app: MISMATCH: the output differs from $name/expected.scout (< board, > expected):" >&2
cat "$tmp/compare.diff" >&2
exit 1
