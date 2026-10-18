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

# One suite of a board trial run (called by board_suite.mk; see README.md in this directory).
#
#   board_suite.sh <target> <suite> <work-dir>
#   board_suite.sh --fail-one <target> <suite> <work-dir> <stem>     (internal: one compile-failure trial)
#
# Reads trials/<suite>/ and writes only the board's own outputs there (<stem>.<target>.sout and
# <stem>.<target>.cur_fail, never tracked); everything else goes to <work-dir>
# (trials/.target/<target>/<suite>/).
#
# The suite's layout is read, not configured, and matches what the host Makefiles do:
#   - program trials: the top-level <stem>.silica files; <stem>.scout is the golden. All the suite's
#     sources (subdirectories such as lib/ and traits/ included) are compiled in one run, as on the
#     host; each program's image links its .sams with the modules it reaches through `use` and the runtime.
#   - compile-failure trials: a top-level <stem>.silica with <stem>.golden_fail, compiled alone
#     (a one-line silica.config), the compiler output compared with the golden, as on the host.
#   - a top-level <stem>.no_golden_fail marks a file that is not a trial (as on the host).
#   - subdirectories with their own Makefile are sub-suites; they are skipped and reported;
#     hidden directories (.pid_registry_impl) hold no trials, as for the host's `*.silica` globs.
# A golden named <stem>.<target>.scout / <stem>.<target>.golden_fail, when present, is used instead
# of the shared one. Such overrides are for real target differences and are written by hand after
# review, never generated.
#
# Environment (exported by trial_target.sh and the integrate wrapper): BOARD_SILICA_COMPILER,
# BOARD_PYTHON, BOARD_TOOLS, BOARD_PORT, BOARD_RT_CACHE, TRIALS_ROOT, SILICA_INTEGRATE_ROOT;
# optional BOARD_TRIAL_TIMEOUT (seconds a program may run on the board, default 300),
# BOARD_FAIL_JOBS (parallel compile-failure trials, default 4), SILICA_COMPILE_TIMEOUT.

set -u

MARK_ROOT="${SILICA_INTEGRATE_ROOT:-.}"
TRIAL_TIMEOUT="${BOARD_TRIAL_TIMEOUT:-300}"
COMPILE_TIMEOUT="${SILICA_COMPILE_TIMEOUT:-300}"

mark_ok()   { { printf P >> "$MARK_ROOT/.integrate_pass_marks"; } 2>/dev/null || true; }
mark_fail() { { printf F >> "$MARK_ROOT/.integrate_fail_marks"; } 2>/dev/null || true; }

# Program output against its golden, the host Makefiles' way: a trial marked <stem>.scout.multiset is
# compared with the suite's compare_scout_multiset.sh (actor failure reports as a set, pointers folded:
# the order of concurrent actors' output is not fixed); otherwise through the suite's
# compare_scout_normalized.sh when it has one (it folds the addresses in the process-fatal report lines
# of spec §15.4.5.5, which differ between the board and the host); otherwise diff -Bw.
# $3 is the trial stem.
scout_matches() {
    if [ -n "${3:-}" ] && [ -f "$src/$3.scout.multiset" ] && [ -f "$src/compare_scout_multiset.sh" ]; then
        bash "$src/compare_scout_multiset.sh" "$1" "$2" > /dev/null 2>&1
    elif [ -f "$src/compare_scout_normalized.sh" ]; then
        bash "$src/compare_scout_normalized.sh" "$1" "$2" > /dev/null 2>&1
    else
        diff -Bw -q "$1" "$2" > /dev/null 2>&1
    fi
}
scout_diff() {
    if [ -n "${3:-}" ] && [ -f "$src/$3.scout.multiset" ] && [ -f "$src/compare_scout_multiset.sh" ]; then
        bash "$src/compare_scout_multiset.sh" "$1" "$2"
    elif [ -f "$src/compare_scout_normalized.sh" ]; then
        bash "$src/compare_scout_normalized.sh" "$1" "$2"
    else
        diff -Bw "$1" "$2"
    fi
}

# The compiler's reclaim loop (exit 75/76 = continue with the next unit), with the per-unit alarm.
run_compiler() {
    local ec
    rm -f silica.compile.inprogress silica.compile.crashed
    while true; do
        perl -e 'alarm shift @ARGV; exec @ARGV' "$COMPILE_TIMEOUT" "$BOARD_SILICA_COMPILER"
        ec=$?
        [ $ec -eq 0 ] && return 0
        { [ $ec -eq 75 ] || [ $ec -eq 76 ]; } && continue
        [ $ec -eq 142 ] && echo "❌❌ compiler TIMED OUT after ${COMPILE_TIMEOUT}s (compile hang)"
        return $ec
    done
}

# --- one compile-failure trial (run in parallel through xargs) ---------------------------------
if [ "${1:-}" = "--fail-one" ]; then
    target=$2 suite=$3 work=$4 stem=$5
    src="$TRIALS_ROOT/$suite"
    prefix="[$target] $suite/"
    tmp=$(mktemp -d)
    ln -s "$src/$stem.silica" "$tmp/$stem.silica"
    echo "$stem.silica" > "$tmp/silica.config"
    # Item M: the trial-support module the trial uses, then Supervisor (TRIAL_SUPPORT_IN_TMP's order)
    for m in $(sed -nE 's/^use (trial_[a-z0-9_]+);.*/\1/p' "$src/$stem.silica"); do
        ln -sfn "$TRIALS_ROOT/lib_trial_support/$m.silica" "$tmp/$m.silica"
        ln -sfn "$TRIALS_ROOT/../compiler/stdlib/Supervisor.silica" "$tmp/Supervisor.silica"
        printf '%s\n' "$m.silica" Supervisor.silica >> "$tmp/silica.config"
    done
    ( cd "$tmp" && run_compiler ) > "$work/build/$stem.cur_fail" 2>&1
    rm -rf "$tmp"
    cp "$work/build/$stem.cur_fail" "$src/$stem.$target.cur_fail"
    golden="$src/$stem.golden_fail"
    [ -f "$src/$stem.$target.golden_fail" ] && golden="$src/$stem.$target.golden_fail"
    if diff -q "$work/build/$stem.cur_fail" "$golden" > /dev/null 2>&1; then
        mark_ok
        printf '✅✅ %s%s\n' "$prefix" "$stem"
        printf 'PASS\t%s\n' "$stem" >> "$work/.fail_results"
        rm -f "$work/build/$stem.cur_fail"
    else
        mark_fail
        { printf '❌❌ %s%s: .cur_fail differs from %s\n' "$prefix" "$stem" "$(basename "$golden")"
          diff "$work/build/$stem.cur_fail" "$golden" || true; } > "$work/build/$stem.msg"
        cat "$work/build/$stem.msg"
        printf 'FAIL\t%s\n' "$stem" >> "$work/.fail_results"
    fi
    exit 0
fi

target=$1 suite=$2 work=${3%/}
src="$TRIALS_ROOT/$suite"
prefix="[$target] $suite/"
ok=0 ko=0 skipped=0

cd "$work" || exit 1
rm -rf src build .integrate_counts .fail_results .skipped_count
mkdir -p src build

finish() {
    printf '%d\n' "$skipped" > "$work/.skipped_count"
    printf '%d %d\n' "$ok" "$ko" > "$work/.integrate_counts"
    [ "$ko" -eq 0 ]
    exit $?
}

# --- the suite's layout --------------------------------------------------------------------------
# Sub-suites: subdirectories holding their own Makefile.
subsuites=()
while IFS= read -r d; do [ -n "$d" ] && subsuites+=("$d"); done < <(
    cd "$src" && find . -mindepth 2 \( -name Makefile -o -name makefile \) | sed 's|^\./||; s|/[^/]*$||' | LC_ALL=C sort -u)
for d in "${subsuites[@]:-}"; do
    [ -n "$d" ] || continue
    printf 'SKIP: %s%s/ (sub-suite with its own Makefile; not run by the board driver yet)\n' "$prefix" "$d"
    skipped=$((skipped + 1))
done
in_subsuite() {
    local f=$1 d
    for d in "${subsuites[@]:-}"; do
        [ -n "$d" ] || continue
        case "$f" in "$d"/*) return 0 ;; esac
    done
    return 1
}

# Skip list entries for this suite (stem<TAB>reason), from trial_target.sh.
skip_reason() {
    awk -F'\t' -v s="$1" '$1 == s { print $2; exit }' "$work/.skip_trials" 2>/dev/null
}

programs=() modules=() failtrials=() staged=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    in_subsuite "$f" && continue
    case "$f" in
        */*)            # a module in a subdirectory (lib/, traits/, ...): compiled with the programs
            mkdir -p "src/$(dirname "$f")"
            ln -s "$src/$f" "src/$f"
            staged=$((staged + 1))
            continue ;;
    esac
    stem=${f%.silica}
    reason=$(skip_reason "$stem")
    if [ -n "$reason" ]; then
        printf 'SKIP: %s%s (%s)\n' "$prefix" "$stem" "$reason"
        skipped=$((skipped + 1))
        continue
    fi
    if [ -f "$src/$stem.golden_fail" ] || [ -f "$src/$stem.$target.golden_fail" ]; then
        failtrials+=("$stem")
        continue
    fi
    if [ -f "$src/$stem.no_golden_fail" ] && [ ! -f "$src/$stem.scout" ]; then
        continue            # not a trial (as on the host)
    fi
    # A top-level source with no expected output is a support module, not a program: it has no main,
    # and the programs in the suite link against it. Stage it so they can, but never build an image
    # from it, which is what produced "undefined reference to `main'" for every such module, and
    # "undefined reference to <Module>_<fn>" for the programs that needed one.
    if [ ! -f "$src/$stem.scout" ] && [ ! -f "$src/$stem.$target.scout" ]; then
        modules+=("$stem")
        ln -s "$src/$f" "src/$f"
        staged=$((staged + 1))
        continue
    fi
    programs+=("$stem")
    ln -s "$src/$f" "src/$f"
    staged=$((staged + 1))
done < <(cd "$src" && find . -type f -name '*.silica' -not -path './.*' | sed 's|^\./||' | LC_ALL=C sort)
# -type f, as the host Makefiles' `find "$PWD" -type f -name '*.silica'`: a suite's lib/ may hold
# symlinks to the stdlib modules its Makefile also names by path (compile_defects_priority_queue_
# supervisor_addition). Staging those too compiled every such module twice, and the two objects
# defined every function of the module again (ld: multiple definition of `brodal_okasaki_...`).

# Standard-library modules the suite's Makefile adds to its silica.config (echo "../../compiler/stdlib/
# <Module>.silica"): compiled with the programs as support modules, the way the host does.
while IFS= read -r m; do
    [ -n "$m" ] || continue
    f="$src/$m"
    [ -f "$f" ] || continue
    b=$(basename "$f" .silica)
    [ -e "src/$b.silica" ] && continue
    ln -s "$f" "src/$b.silica"
    modules+=("$b")
    staged=$((staged + 1))
done < <(sed -n 's#.*echo *"\(\.\./\.\./compiler/[^"]*\.silica\)".*#\1#p' "$src/Makefile" 2>/dev/null | LC_ALL=C sort -u)

# Item M: the trial-support modules the suite's programs use (trials/lib_trial_support), and the
# Supervisor trait they implement, staged as support modules the way TRIAL_SUPPORT_CONFIG adds them
# to the host's silica.config. link_closure then links each program with the one it `use`s.
while IFS= read -r m; do
    [ -n "$m" ] || continue
    [ -e "src/$m.silica" ] && continue
    ln -s "$TRIALS_ROOT/lib_trial_support/$m.silica" "src/$m.silica"
    modules+=("$m")
    staged=$((staged + 1))
    if [ ! -e src/Supervisor.silica ] && ! find src -name Supervisor.silica | grep -q .; then
        ln -s "$TRIALS_ROOT/../compiler/stdlib/Supervisor.silica" src/Supervisor.silica
        modules+=("Supervisor")
        staged=$((staged + 1))
    fi
done < <(cd "$src" && cat ./*.silica 2>/dev/null | sed -nE 's/^use (trial_(support|wait|call)_[a-z0-9_]+);.*/\1/p' | LC_ALL=C sort -u)

# --- program trials: one compile, then image + board run + golden per program -------------------
if [ "${#programs[@]}" -gt 0 ]; then
    ( cd src && find . -name '*.silica' -not -path './.*' | sed 's|^\./||' | LC_ALL=C sort > silica.config )
    echo "Compiling ${#programs[@]} programs with $(basename "$BOARD_SILICA_COMPILER")..."
    if ! ( cd src && run_compiler ) > build/compile.log 2>&1; then
        mark_fail
        printf '❌❌ %scompilation failed (%s)\n' "$prefix" "$(basename "$BOARD_SILICA_COMPILER")"
        tail -n 40 build/compile.log
        ko=$((ko + 1))
    else
        # Each program links only the units it transitively reaches through `use` declarations, plus the
        # runtime support unit. Board memory is small and a unit cannot be garbage-collected (each
        # compiled unit is one .text section and carries the application's atom table in .rodata), so
        # linking every staged module gave unused code a share of the heap and starved the programs.
        # A `use` whose .sams is not found is skipped (inlined or unstaged; the compiler resolved it).
        link_closure() {
            local stem=$1 queue=$1 seen cur f s m out=""
            seen=$'\n'"$1"$'\n'
            while [ -n "$queue" ]; do
                cur=${queue%%$'\n'*}
                case "$queue" in *$'\n'*) queue=${queue#*$'\n'} ;; *) queue="" ;; esac
                if [ "$cur" = "$stem" ]; then
                    f="src/$stem.silica"
                else
                    # A top-level entry program (it has a golden and its own main) is never a library:
                    # a suite such as compiler_addition links each entry alone, and a second main
                    # fails the link with "multiple definition of `main'".
                    case " ${programs[*]} " in *" $cur "*) continue ;; esac
                    s=$(find src -name "$cur.sams" | LC_ALL=C sort | head -n 1)
                    [ -n "$s" ] || continue
                    out+="$s"$'\n'
                    f="${s%.sams}.silica"
                fi
                [ -f "$f" ] || continue
                while IFS= read -r m; do
                    case "$seen" in *$'\n'"$m"$'\n'*) continue ;; esac
                    seen+="$m"$'\n'
                    queue+="${queue:+$'\n'}$m"
                done < <(sed -E 's|//.*||' "$f" | sed -nE 's/^[[:space:]]*use[[:space:]]+([A-Za-z_][A-Za-z0-9_, \t]*)[[:space:]]*;.*/\1/p' | tr -s ', \t' '\n\n\n' | sed '/^$/d')
            done
            [ -n "$out" ] && printf '%s' "$out" | LC_ALL=C sort
            [ -f src/__silica_runtime.sams ] && echo "src/__silica_runtime.sams"
            return 0
        }
        left=${#programs[@]}
        for stem in "${programs[@]}"; do
            if [ -f "$MARK_ROOT/.board_lost" ]; then
                mark_fail
                printf '❌❌ %s%d trials not run: the board became unavailable (%s)\n' "$prefix" "$left" "$(cat "$MARK_ROOT/.board_lost")"
                ko=$((ko + 1))
                break
            fi
            left=$((left - 1))
            if [ ! -f "src/$stem.sams" ]; then
                mark_fail; printf '❌❌ %s%s: no %s.sams was emitted\n' "$prefix" "$stem" "$stem"; ko=$((ko + 1)); continue
            fi
            img="build/$stem/$stem"
            extra=()
            while IFS= read -r m; do [ -n "$m" ] && extra+=("$m"); done < <(link_closure "$stem")
            if ! sh "$BOARD_TOOLS/build_image.sh" -q -r "$BOARD_RT_CACHE" -o "$img" "src/$stem.sams" ${extra[@]+"${extra[@]}"} > "build/$stem.image.log" 2>&1; then
                mark_fail
                printf '❌❌ %s%s: image build failed (assembler or linker)\n' "$prefix" "$stem"
                grep -m 12 -i 'error\|undefined' "build/$stem.image.log" || head -n 12 "build/$stem.image.log"
                ko=$((ko + 1)); continue
            fi
            # The board runs one trial at a time for the whole run (flock on .board.lock). The run is
            # registered like every host trial so the integrate watchdog can stop it.
            # $^F: perl closes every descriptor above 2 on exec, which released the lock the moment
            # run_on_board.py started; two suites then opened the port together and the second one
            # found it busy (the run reported the board as lost after ~60 trials). Raising $^F keeps
            # the lock descriptor open, and so the lock held, for the life of the exec'd process.
            # A trial with a <stem>.wait_for_exit marker ends only on the `exit` line (spec §15.1.2.5;
            # on the board standard input is the console). The host harness writes it after the
            # marker text appears; run_on_board.py can write it a fixed delay after the start marker,
            # so the delay must cover the trial's run up to its marker: BOARD_EXIT_DELAY seconds
            # (default 5).
            # A suite whose host Makefile runs every trial through run_integration_exit_after_marker.py
            # with the marker "done" (supervisors_addition, record_shapes_actors_addition) gets the
            # `exit` line for every trial, as on the host.
            send=()
            if [ -f "$src/$stem.wait_for_exit" ] || grep -q 'run_integration_exit_after_marker.py" "$(THIS_DIR)" "$$base" "$$base.sout" "done"' "$src/Makefile" 2>/dev/null; then
                send=(--send 'exit\n' --send-delay "${BOARD_EXIT_DELAY:-5}")
            fi
            integrate_killed=0
            perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' \
                perl -MFcntl=:flock -e '$^F = 255; open(my $f, ">>", shift @ARGV) or die "board lock: $!\n"; flock($f, LOCK_EX) or die "board lock: $!\n"; exec @ARGV or exit 127' \
                "$MARK_ROOT/.board.lock" "$BOARD_PYTHON" "$BOARD_TOOLS/run_on_board.py" --port "$BOARD_PORT" \
                --timeout "$TRIAL_TIMEOUT" ${send[@]+"${send[@]}"} --out "build/$stem.sout" "$img.bin" 2> "build/$stem.run.err" &
            pid=$!
            reg="$MARK_ROOT/.integrate_running/$pid"
            { printf '%s %s\n' "$pid" "$suite/$stem" > "$reg"; } 2>/dev/null
            wait $pid; rc=$?
            [ -f "$reg.killed" ] && integrate_killed=1
            rm -f "$reg" "$reg.killed" 2>/dev/null
            if [ "$integrate_killed" = 1 ]; then
                mark_fail; printf '❌❌ %s%s killed by the watchdog after %s minutes of silence; trial incomplete\n' "$prefix" "$stem" "${SILICA_INTEGRATE_WATCHDOG_MINUTES:-15}"; ko=$((ko + 1)); continue
            fi
            if [ "$rc" -eq 4 ]; then
                sed -n 's/^run_on_board: //p' "build/$stem.run.err" | head -1 > "$MARK_ROOT/.board_lost"
                [ -s "$MARK_ROOT/.board_lost" ] || echo "the board stopped answering" > "$MARK_ROOT/.board_lost"
                mark_fail
                printf '❌❌ %s%d trials not run: the board became unavailable (%s)\n' "$prefix" "$((left + 1))" "$(cat "$MARK_ROOT/.board_lost")"
                ko=$((ko + 1))
                break
            fi
            if [ "$rc" -eq 3 ]; then
                mark_fail
                printf '❌❌ %s%s: no exit marker within %ss (the program hung, or died before reporting)\n' "$prefix" "$stem" "$TRIAL_TIMEOUT"
                head -c 600 "build/$stem.run.err"; echo
                ko=$((ko + 1)); continue
            fi
            if [ "$rc" -ne 0 ] || [ ! -f "build/$stem.sout" ]; then
                mark_fail; printf '❌❌ %s%s: the board runner failed (exit %s)\n' "$prefix" "$stem" "$rc"; head -n 5 "build/$stem.run.err"; ko=$((ko + 1)); continue
            fi
            cp "build/$stem.sout" "$src/$stem.$target.sout"
            golden="$src/$stem.scout"
            [ -f "$src/$stem.$target.scout" ] && golden="$src/$stem.$target.scout"
            if [ ! -f "$golden" ]; then
                mark_fail; printf '❌❌ %s%s has no .scout file\n' "$prefix" "$stem"; ko=$((ko + 1))
            elif scout_matches "build/$stem.sout" "$golden" "$stem"; then
                mark_ok; printf '✅✅ %s%s output matches %s\n' "$prefix" "$stem" "$(basename "$golden")"; ok=$((ok + 1))
                rm -rf "build/$stem" "build/$stem".*        # keep the artefacts of failures only
            else
                mark_fail
                printf '❌❌ %s%s .sout differs from %s\n' "$prefix" "$stem" "$(basename "$golden")"
                scout_diff "build/$stem.sout" "$golden" "$stem" || true
                if [ -s "build/$stem.run.err" ]; then printf '   (board diagnostic: %s)\n' "$(head -n 1 "build/$stem.run.err")"; fi
                ko=$((ko + 1))
            fi
        done
    fi
fi

# --- compile-failure trials: each compiled alone, in parallel ------------------------------------
if [ "${#failtrials[@]}" -gt 0 ]; then
    : > .fail_results
    echo "Compile-failure trials: ${#failtrials[@]} (compiled alone, ${BOARD_FAIL_JOBS:-4} at a time)..."
    printf '%s\n' "${failtrials[@]}" | xargs -P "${BOARD_FAIL_JOBS:-4}" -I{} bash "$0" --fail-one "$target" "$suite" "$work" {}
    ok=$((ok + $(grep -c '^PASS' .fail_results)))
    ko=$((ko + $(grep -c '^FAIL' .fail_results)))
fi

if [ "${#programs[@]}" -eq 0 ] && [ "${#failtrials[@]}" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    echo "SKIP: ${prefix} no trials found"
fi
finish
