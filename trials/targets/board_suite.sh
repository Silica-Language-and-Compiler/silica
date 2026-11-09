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
#   - app directories: in a suite with a common_app.mk (ffi_addition), each app_*/ sub-suite is run in app
#     mode: compiled alone with the trial-support modules and the board's C fixtures
#     (fixtures_board.mk), one image per program with the compiler's silica.link archives, goldens and
#     .wait_for_exit read from the app directory (<stem>.scout.sorted selects the unordered compare).
#   - other subdirectories with their own Makefile are sub-suites; they are skipped and reported;
#     hidden directories (.pid_registry_impl) hold no trials, as for the host's `*.silica` globs.
# Assembly: after each compile, every program's .sams (and each top-level module's of the suite) is compared with
# <stem>.<platform>.ascomp next to the trial, with diff -Bw as the host Makefiles do; a missing golden is a failure
# ("has no .<platform>.ascomp file"), as on the host. Goldens are written by gen_board_ascomp.sh.
# A golden named <stem>.<target>.scout / <stem>.<target>.golden_fail, when present, is used instead
# of the shared one. Such overrides are for real target differences and are written by hand after
# review, never generated.
#
# Environment (exported by trial_target.sh and the integrate wrapper): BOARD_SILICA_COMPILER,
# BOARD_PYTHON, BOARD_TOOLS, BOARD_PORT, BOARD_RT_CACHE, TRIALS_ROOT, SILICA_INTEGRATE_ROOT;
# optional BOARD_IMAGE_EXT (image extension, default bin), BOARD_ONLY_STEM (run one trial only), BOARD_TRIAL_TIMEOUT (seconds a program may run on the board, default 300),
# BOARD_ASCOMP_PLATFORM (the platform name of the assembly goldens, from the conf's TARGET_ASCOMP_PLATFORM;
# unset = no assembly check), BOARD_FAIL_JOBS (parallel compile-failure trials, default 4), SILICA_COMPILE_TIMEOUT.

set -u

MARK_ROOT="${SILICA_INTEGRATE_ROOT:-.}"
TRIAL_TIMEOUT="${BOARD_TRIAL_TIMEOUT:-300}"
COMPILE_TIMEOUT="${SILICA_COMPILE_TIMEOUT:-300}"
# Extension of the image build_image.sh writes and run_on_board.py loads (conf TARGET_IMAGE_EXT: bin for
# the ESP32-S3, elf for the STM32).
IMG_EXT="${BOARD_IMAGE_EXT:-bin}"
# BOARD_ONLY_STEM=<stem> (tools/run_one_trial.sh): stage and run only that program or compile-failure trial.
ONLY="${BOARD_ONLY_STEM:-}"

mark_ok()   { { printf P >> "$MARK_ROOT/.integrate_pass_marks"; } 2>/dev/null || true; }
mark_fail() { { printf F >> "$MARK_ROOT/.integrate_fail_marks"; } 2>/dev/null || true; }

# Program output against its golden, the host Makefiles' way: a trial marked <stem>.scout.multiset is
# compared with the suite's compare_scout_multiset.sh (actor failure reports as a set, pointers folded:
# the order of concurrent actors' output is not fixed); otherwise through the suite's
# compare_scout_normalized.sh when it has one (it folds the addresses in the process-fatal report lines
# of spec §15.4.5.5, which differ between the board and the host); otherwise diff -Bw.
# $3 is the trial stem.
scout_matches() {
    if [ -n "${3:-}" ] && [ -f "$gdir/$3.scout.sorted" ] && [ -f "$src/compare_scout_sorted.sh" ]; then
        bash "$src/compare_scout_sorted.sh" "$1" "$2" > /dev/null 2>&1
    elif [ -n "${3:-}" ] && [ -f "$gdir/$3.scout.multiset" ] && [ -f "$src/compare_scout_multiset.sh" ]; then
        bash "$src/compare_scout_multiset.sh" "$1" "$2" > /dev/null 2>&1
    elif [ -f "$src/compare_scout_normalized.sh" ]; then
        bash "$src/compare_scout_normalized.sh" "$1" "$2" > /dev/null 2>&1
    else
        diff -Bw -q "$1" "$2" > /dev/null 2>&1
    fi
}
scout_diff() {
    if [ -n "${3:-}" ] && [ -f "$gdir/$3.scout.sorted" ] && [ -f "$src/compare_scout_sorted.sh" ]; then
        bash "$src/compare_scout_sorted.sh" "$1" "$2"
    elif [ -n "${3:-}" ] && [ -f "$gdir/$3.scout.multiset" ] && [ -f "$src/compare_scout_multiset.sh" ]; then
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
    # error_enforcement_addition/Makefile stages WireFormat/Carrier for `use` lines
    for tr in WireFormat Carrier; do
        if grep -q "use $tr;" "$src/$stem.silica"; then
            ln -sfn "$TRIALS_ROOT/../compiler/stdlib/$tr.silica" "$tmp/$tr.silica"
            echo "$tr.silica" >> "$tmp/silica.config"
        fi
    done
    # Sidecar .meta files named by wrapper_meta "<rel path>"; the host (error_enforcement_addition/Makefile)
    # links them into its scratch dir at the same relative path from <suite>/ffi_addition/error_app_sidecar_metadata/
    for rel in $(sed -nE 's/^wrapper_meta "([^"]+)";.*/\1/p' "$src/$stem.silica"); do
        meta="$src/ffi_addition/error_app_sidecar_metadata/$rel"
        if [ -f "$meta" ]; then
            mkdir -p "$tmp/$(dirname "$rel")"
            ln -sfn "$meta" "$tmp/$rel"
        fi
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
rm -rf src build apps .integrate_counts .fail_results .skipped_count
mkdir -p src build
ASCOMP_PLATFORM="${BOARD_ASCOMP_PLATFORM:-}"
# Generator mode (gen_board_ascomp.sh): BOARD_ASCOMP_GEN=dry|write compiles only and, instead of checking
# the assembly or running the board, lists (dry) or writes (write) the goldens of the trials whose last
# board result matches their expected output. BOARD_GEN_TRIAL limits it to one stem.
GEN="${BOARD_ASCOMP_GEN:-}"
GEN_TRIAL="${BOARD_GEN_TRIAL:-}"
gen_elig=0
own_modules=()                # the suite's own top-level support modules (assembly-checked like programs)
cdir=src gdir=$src            # compile directory and golden directory (app mode changes them per app)

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
# App directories: a suite with a common_app.mk (ffi_addition) runs its app_*/ sub-suites in app mode
# (see "app directories" below); every other sub-suite is skipped here.
appdirs=()
for d in "${subsuites[@]:-}"; do
    [ -n "$d" ] || continue
    case "$d" in
        app_*) if [ -f "$src/common_app.mk" ]; then appdirs+=("$d"); continue; fi ;;
    esac
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
        [ -z "$ONLY" ] || [ "$ONLY" = "$stem" ] || continue
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
        own_modules+=("$stem")
        ln -s "$src/$f" "src/$f"
        staged=$((staged + 1))
        continue
    fi
    [ -z "$ONLY" ] || [ "$ONLY" = "$stem" ] || continue
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
# Also the form transport_addition's Makefile uses (ln -sfn ../../../compiler/stdlib/<Module>.silica
# .trial_stdlib/<Module>.silica, written relative to .trial_stdlib/): one ../ is dropped to read it from $src.
done < <(sed -n -e 's#.*echo *"\(\.\./\.\./compiler/[^"]*\.silica\)".*#\1#p' -e 's#.*ln -sfn *\.\./\(\.\./\.\./compiler/[^ ]*\.silica\) *\.trial_stdlib/.*#\1#p' "$src/Makefile" 2>/dev/null | LC_ALL=C sort -u)

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
# Each program links only the units it transitively reaches through `use` declarations, plus the
# runtime support unit. Board memory is small and a unit cannot be garbage-collected (each
# compiled unit is one .text section and carries the application's atom table in .rodata), so
# linking every staged module gave unused code a share of the heap and starved the programs.
# A `use` whose .sams is not found is skipped (inlined or unstaged; the compiler resolved it).
#
# Where things are (set by the caller before link_closure / run_program):
#   cdir   the compile directory (relative to $work): its <stem>.sams and the modules' .sams are here
#   gdir   the directory holding the goldens and <stem>.wait_for_exit: $src for a suite's top-level
#          programs, $src/<app> for an app directory (ffi_addition's app_*)
#   closure_programs  " stem stem ... " the entry programs of this compile (never libraries)
#   link_archives     archive paths (relative to $work) placed last on the link line; set by the app mode
#   app_link_sams     .sams the app's Makefile names in APP_LINK_OBJECTS (linked with every program)
cdir=src gdir=$src closure_programs="" left=0
link_archives=() app_link_sams=()

link_closure() {
    local stem=$1 queue=$1 seen cur f s m out=""
    seen=$'\n'"$1"$'\n'
    while [ -n "$queue" ]; do
        cur=${queue%%$'\n'*}
        case "$queue" in *$'\n'*) queue=${queue#*$'\n'} ;; *) queue="" ;; esac
        if [ "$cur" = "$stem" ]; then
            f="$cdir/$stem.silica"
        else
            # A top-level entry program (it has a golden and its own main) is never a library:
            # a suite such as compiler_addition links each entry alone, and a second main
            # fails the link with "multiple definition of `main'".
            case "$closure_programs" in *" $cur "*) continue ;; esac
            s=$(find "$cdir" -name "$cur.sams" | LC_ALL=C sort | head -n 1)
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
    [ -f "$cdir/__silica_runtime.sams" ] && echo "$cdir/__silica_runtime.sams"
    return 0
}

# Generator mode, one unit. A program is eligible when its last board result (<stem>.<target>.sout beside the
# trial) matches its golden by the board run's own comparison (scout_matches, with the <stem>.<target>.scout
# override); a support module when its compile unit has an eligible program. An existing golden is kept.
gen_ascomp() {
    local stem=$1 g=$2 kind=$3 sout golden label="$suite/$stem"
    [ -z "$GEN_TRIAL" ] || [ "$GEN_TRIAL" = "$stem" ] || return 0
    if [ "$kind" = module ]; then
        if [ "$gen_elig" -eq 0 ]; then printf 'GEN-SKIP\t%s\tsupport module; no eligible program in its compile unit\n' "$label"; return 0; fi
    else
        sout="$gdir/$stem.$target.sout"
        golden="$gdir/$stem.scout"
        [ -f "$gdir/$stem.$target.scout" ] && golden="$gdir/$stem.$target.scout"
        if [ ! -f "$sout" ]; then printf 'GEN-SKIP\t%s\tno last board result (%s.%s.sout)\n' "$label" "$stem" "$target"; return 0; fi
        if [ ! -f "$golden" ]; then printf 'GEN-SKIP\t%s\tno .scout golden\n' "$label"; return 0; fi
        if ! scout_matches "$sout" "$golden" "$stem"; then
            printf 'GEN-SKIP\t%s\tlast board result differs from %s\n' "$label" "$(basename "$golden")"; return 0
        fi
        gen_elig=$((gen_elig + 1))
    fi
    if [ -f "$g" ]; then printf 'GEN-KEEP\t%s\t%s exists\n' "$label" "$(basename "$g")"; return 0; fi
    if [ "$GEN" = write ]; then cp "$cdir/$stem.sams" "$g"; printf 'GEN-WRITE\t%s\t%s\n' "$label" "$(basename "$g")"
    else printf 'GEN-WOULD-WRITE\t%s\t%s\n' "$label" "$(basename "$g")"; fi
}

# Assembly golden check for one unit of the current compile, the host's rule (base/makefile integrate-run):
# <stem>.<platform>.ascomp in the golden directory against <stem>.sams with diff -Bw. Counts one ok/ko.
# Nothing is checked when the target has no assembly platform. $1 is the stem.
check_ascomp() {
    local stem=$1 g
    [ -n "$ASCOMP_PLATFORM" ] || return 0
    [ -f "$cdir/$stem.sams" ] || return 0
    g="$gdir/$stem.$ASCOMP_PLATFORM.ascomp"
    if [ -n "$GEN" ]; then gen_ascomp "$stem" "$g" "${2:-program}"; return 0; fi
    if [ ! -f "$g" ]; then
        mark_fail; printf '❌❌ %s%s has no .%s.ascomp file\n' "$prefix" "$stem" "$ASCOMP_PLATFORM"; ko=$((ko + 1))
    elif ! diff -Bw -q "$cdir/$stem.sams" "$g" > /dev/null 2>&1; then
        mark_fail
        printf '❌❌ %s%s .sams differs from .%s.ascomp\n' "$prefix" "$stem" "$ASCOMP_PLATFORM"
        diff -Bw "$cdir/$stem.sams" "$g" || true
        ko=$((ko + 1))
    else
        mark_ok; printf '✅✅ %s%s assembly matches .%s.ascomp\n' "$prefix" "$stem" "$ASCOMP_PLATFORM"; ok=$((ok + 1))
    fi
}

# One program of the current compile: image, board run, golden. Returns 9 when the board is gone and
# the remaining programs must not run; 0 otherwise (the outcome is in $ok / $ko).
run_program() {
    local stem=$1 img m send marker marker_count integrate_killed pid reg rc golden
    local -a extra=()
    if [ -f "$MARK_ROOT/.board_lost" ]; then
        mark_fail
        printf '❌❌ %s%d trials not run: the board became unavailable (%s)\n' "$prefix" "$left" "$(cat "$MARK_ROOT/.board_lost")"
        ko=$((ko + 1))
        return 9
    fi
    left=$((left - 1))
    check_ascomp "$stem"
    [ -z "$GEN" ] || return 0
    if [ ! -f "$cdir/$stem.sams" ]; then
        mark_fail; printf '❌❌ %s%s: no %s.sams was emitted\n' "$prefix" "$stem" "$stem"; ko=$((ko + 1)); return 0
    fi
    img="build/$stem/$stem"
    while IFS= read -r m; do [ -n "$m" ] && extra+=("$m"); done < <(link_closure "$stem")
    # The units the app's Makefile links into every program (APP_LINK_OBJECTS), unless the closure has them
    for m in ${app_link_sams[@]+"${app_link_sams[@]}"}; do
        case " ${extra[*]:-} " in *" $m "*) ;; *) extra+=("$m") ;; esac
    done
    # Archives (C wrappers, spec §20.4) go last: build_image.sh places .a files after every object.
    if ! sh "$BOARD_TOOLS/build_image.sh" -q -r "$BOARD_RT_CACHE" -o "$img" "$cdir/$stem.sams" ${extra[@]+"${extra[@]}"} ${link_archives[@]+"${link_archives[@]}"} > "build/$stem.image.log" 2>&1; then
        mark_fail
        printf '❌❌ %s%s: image build failed (assembler or linker)\n' "$prefix" "$stem"
        grep -m 12 -i 'error\|undefined' "build/$stem.image.log" || head -n 12 "build/$stem.image.log"
        ko=$((ko + 1)); return 0
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
    # The `exit` line also waits for the trial's marker, by the host harness's rule: the
    # .wait_for_exit file's first non-blank line -- a trailing integer is the count (default 1),
    # the rest of the line is the marker, however many words (=== End Silica Actor Failure === 1)
    # -- then 1.5 s of quiet output (run_on_board.py --send-marker). A trial that needs
    # longer than BOARD_EXIT_DELAY to reach its marker (100,000 dispatches take tens of
    # seconds on the board) is then not cut short; a faster one gets `exit` as before.
    send=()
    if [ -f "$gdir/$stem.wait_for_exit" ] || grep -q 'run_integration_exit_after_marker.py" "$(THIS_DIR)" "$$base" "$$base$(SOUT_EXT)" "done"' "$src/Makefile" 2>/dev/null; then
        marker=done marker_count=1
        if [ -f "$gdir/$stem.wait_for_exit" ]; then
            marker=$(awk 'NF { if ($NF ~ /^[0-9]+$/) { m=$0; sub(/[ \t]+[0-9]+$/, "", m); print m } else print $0; exit } END { if (!NR) print "done" }' "$gdir/$stem.wait_for_exit")
            marker_count=$(awk 'NF { if ($NF ~ /^[0-9]+$/) print $NF; else print 1; exit } END { if (!NR) print 1 }' "$gdir/$stem.wait_for_exit")
        fi
        send=(--send 'exit\n' --send-delay "${BOARD_EXIT_DELAY:-5}" --send-marker "$marker" --send-marker-count "$marker_count")
    fi
    integrate_killed=0
    perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' \
        perl -MFcntl=:flock -e '$^F = 255; open(my $f, ">>", shift @ARGV) or die "board lock: $!\n"; flock($f, LOCK_EX) or die "board lock: $!\n"; exec @ARGV or exit 127' \
        "$MARK_ROOT/.board.lock" "$BOARD_PYTHON" "$BOARD_TOOLS/run_on_board.py" --port "$BOARD_PORT" \
        --timeout "$TRIAL_TIMEOUT" ${send[@]+"${send[@]}"} --out "build/$stem.sout" "$img.$IMG_EXT" 2> "build/$stem.run.err" &
    pid=$!
    reg="$MARK_ROOT/.integrate_running/$pid"
    { printf '%s %s\n' "$pid" "$suite/$stem" > "$reg"; } 2>/dev/null
    wait $pid; rc=$?
    [ -f "$reg.killed" ] && integrate_killed=1
    rm -f "$reg" "$reg.killed" 2>/dev/null
    if [ "$integrate_killed" = 1 ]; then
        mark_fail; printf '❌❌ %s%s killed by the watchdog after %s minutes of silence; trial incomplete\n' "$prefix" "$stem" "${SILICA_INTEGRATE_WATCHDOG_MINUTES:-15}"; ko=$((ko + 1)); return 0
    fi
    if [ "$rc" -eq 4 ]; then
        sed -n 's/^run_on_board: //p' "build/$stem.run.err" | head -1 > "$MARK_ROOT/.board_lost"
        [ -s "$MARK_ROOT/.board_lost" ] || echo "the board stopped answering" > "$MARK_ROOT/.board_lost"
        mark_fail
        printf '❌❌ %s%d trials not run: the board became unavailable (%s)\n' "$prefix" "$((left + 1))" "$(cat "$MARK_ROOT/.board_lost")"
        ko=$((ko + 1))
        return 9
    fi
    if [ "$rc" -eq 3 ]; then
        mark_fail
        printf '❌❌ %s%s: no exit marker within %ss (the program hung, or died before reporting)\n' "$prefix" "$stem" "$TRIAL_TIMEOUT"
        head -c 600 "build/$stem.run.err"; echo
        ko=$((ko + 1)); return 0
    fi
    if [ "$rc" -ne 0 ] || [ ! -f "build/$stem.sout" ]; then
        mark_fail; printf '❌❌ %s%s: the board runner failed (exit %s)\n' "$prefix" "$stem" "$rc"; head -n 5 "build/$stem.run.err"; ko=$((ko + 1)); return 0
    fi
    cp "build/$stem.sout" "$gdir/$stem.$target.sout"
    golden="$gdir/$stem.scout"
    [ -f "$gdir/$stem.$target.scout" ] && golden="$gdir/$stem.$target.scout"
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
    return 0
}

if [ "${#programs[@]}" -gt 0 ]; then
    ( cd src && find . -name '*.silica' -not -path './.*' | sed 's|^\./||' | LC_ALL=C sort > silica.config )
    echo "Compiling ${#programs[@]} programs with $(basename "$BOARD_SILICA_COMPILER")..."
    if ! ( cd src && run_compiler ) > build/compile.log 2>&1; then
        mark_fail
        printf '❌❌ %scompilation failed (%s)\n' "$prefix" "$(basename "$BOARD_SILICA_COMPILER")"
        tail -n 40 build/compile.log
        ko=$((ko + 1))
    else
        cdir=src gdir=$src closure_programs=" ${programs[*]} " left=${#programs[@]}
        link_archives=() app_link_sams=()
        gen_elig=0
        for stem in "${programs[@]}"; do
            run_program "$stem" || break
        done
        for stem in ${own_modules[@]+"${own_modules[@]}"}; do check_ascomp "$stem" module; done
    fi
fi

# --- app directories (ffi_addition's app_*/) -----------------------------------------------------
# A suite with a common_app.mk keeps each runnable app in its own directory (<app>/<stem>.silica with
# <stem>.scout, <stem>.wait_for_exit, a Makefile naming APP_LINK_OBJECTS). Each app is compiled alone,
# the way its host Makefile does (common_app.mk / the supervisor and guarded-fault Makefiles):
#   - the app's top-level *.silica, linked in a compile directory (apps/<app>/);
#   - the trial-support modules the programs `use` (lib_trial_support/trial_{support,call,wait}_*) and
#     Supervisor, linked into apps/<app>/.trial_stdlib/ (TRIAL_SUPPORT_CONFIG), plus any
#     compiler/stdlib entry the app's Makefile echoes into silica.config (Supervisor goes to .trial_stdlib);
#   - dangerous_exposure_source -> the board's platform view of the suite's fixtures
#     (fixtures/build/ESP32-S3_raw/dangerous_exposure_source: metas plus the Xtensa archives, built by
#     fixtures_board.mk), so wrapper_meta paths resolve and the compiler's archive existence check passes.
# Then each program's image links its .sams, its `use` closure, the units APP_LINK_OBJECTS names, the
# runtime, and the archives of the compiler-emitted silica.link, archives last. Programs listed in
# the skip file (<suite>/<stem>) are reported as skipped and left out of the compile.
if [ "${#appdirs[@]}" -gt 0 ]; then
    export XTENSA_BIN=${XTENSA_BIN:-$HOME/.espressif/tools/xtensa-esp-elf/esp-16.1.0_20260609/xtensa-esp-elf/bin}
    view="$src/fixtures/build/ESP32-S3_raw/dangerous_exposure_source"
    fixtures_ok=0
    fixtures_started=0
    mkdir -p apps
    for app in "${appdirs[@]}"; do
        adir="$src/$app"
        app_programs=() app_modules=() app_skipped=0
        reason=$(skip_reason "$app")
        if [ -n "$reason" ]; then
            printf 'SKIP: %s%s/ (%s)\n' "$prefix" "$app" "$reason"
            skipped=$((skipped + 1))
            continue
        fi
        for f in $(cd "$adir" && ls ./*.silica 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort); do
            stem=${f%.silica}
            reason=$(skip_reason "$stem")
            if [ -n "$reason" ]; then
                printf 'SKIP: %s%s/%s (%s)\n' "$prefix" "$app" "$stem" "$reason"
                skipped=$((skipped + 1)); app_skipped=$((app_skipped + 1))
                continue
            fi
            if [ -f "$adir/$stem.scout" ] || [ -f "$adir/$stem.$target.scout" ]; then
                app_programs+=("$stem")
            else
                app_modules+=("$stem")
            fi
        done
        if [ "${#app_programs[@]}" -eq 0 ]; then
            [ "$app_skipped" -eq 0 ] && { printf 'SKIP: %s%s/ (no program with a golden)\n' "$prefix" "$app"; skipped=$((skipped + 1)); }
            continue
        fi
        if [ "$fixtures_started" = 0 ]; then
            fixtures_started=1
            if make -s -f "$src/fixtures_board.mk" > build/fixtures_board.log 2>&1; then
                fixtures_ok=1
            else
                mark_fail
                printf '❌❌ %sfixtures: the board C fixtures did not build (%s)\n' "$prefix" "$src/fixtures_board.mk"
                head -n 20 build/fixtures_board.log
                ko=$((ko + 1))
            fi
        fi
        if [ "$fixtures_ok" != 1 ]; then
            printf 'SKIP: %s%s/ (fixtures not built)\n' "$prefix" "$app"
            skipped=$((skipped + ${#app_programs[@]}))
            continue
        fi

        cdir="apps/$app"
        rm -rf "$cdir"; mkdir -p "$cdir"
        for stem in "${app_programs[@]}" ${app_modules[@]+"${app_modules[@]}"}; do
            ln -s "$adir/$stem.silica" "$cdir/$stem.silica"
        done
        ln -sfn "$view" "$cdir/dangerous_exposure_source"
        ( cd "$cdir" && ls ./*.silica | sed 's|^\./||' | LC_ALL=C sort > silica.config )
        # trial-support modules the staged programs use, and Supervisor (private copy, as TRIAL_SUPPORT_CONFIG)
        mods=$(cd "$cdir" && cat ./*.silica | sed -nE 's/^use (trial_(support|call|wait)_[a-z0-9_]+);.*/\1/p' | LC_ALL=C sort -u)
        stdlib_entries=$(sed -n 's#.*echo *"\(\(\.\./\)*compiler/stdlib/[^"]*\.silica\)".*#\1#p' "$adir/Makefile" 2>/dev/null | LC_ALL=C sort -u)
        if [ -n "$mods" ] || [ -n "$stdlib_entries" ]; then
            mkdir -p "$cdir/.trial_stdlib"
            ln -sfn "$TRIALS_ROOT/../compiler/stdlib/Supervisor.silica" "$cdir/.trial_stdlib/Supervisor.silica"
            echo ".trial_stdlib/Supervisor.silica" >> "$cdir/silica.config"
            for m in $mods; do
                ln -sfn "$TRIALS_ROOT/lib_trial_support/$m.silica" "$cdir/.trial_stdlib/$m.silica"
                echo ".trial_stdlib/$m.silica" >> "$cdir/silica.config"
            done
            for e in $stdlib_entries; do
                b=$(basename "$e")
                [ "$b" = "Supervisor.silica" ] && continue
                ln -sfn "$TRIALS_ROOT/../compiler/stdlib/$b" "$cdir/.trial_stdlib/$b"
                echo ".trial_stdlib/$b" >> "$cdir/silica.config"
            done
        fi
        printf 'Compiling %s/ (%d programs) with %s...\n' "$app" "${#app_programs[@]}" "$(basename "$BOARD_SILICA_COMPILER")"
        if ! ( cd "$cdir" && run_compiler ) > "build/$app.compile.log" 2>&1; then
            mark_fail
            printf '❌❌ %s%s/: compilation failed (%s)\n' "$prefix" "$app" "$(basename "$BOARD_SILICA_COMPILER")"
            tail -n 40 "build/$app.compile.log"
            ko=$((ko + 1))
            continue
        fi
        # archives named by the compiler-emitted manifest (paths relative to the compile directory)
        link_archives=()
        if [ -f "$cdir/silica.link" ]; then
            while IFS= read -r m; do [ -n "$m" ] && link_archives+=("$cdir/$m"); done < <(awk -F'"' '/^archive:/ { print $2 }' "$cdir/silica.link")
        fi
        app_link_sams=()
        for m in $(sed -n 's/^APP_LINK_OBJECTS[[:space:]]*:=[[:space:]]*//p' "$adir/Makefile" 2>/dev/null); do
            [ -f "$cdir/${m%.o}.sams" ] && app_link_sams+=("$cdir/${m%.o}.sams")
        done
        gdir=$adir closure_programs=" ${app_programs[*]} "
        gen_elig=0
        left=${#app_programs[@]}
        for stem in "${app_programs[@]}"; do
            run_program "$stem" || break
        done
        for stem in ${app_modules[@]+"${app_modules[@]}"}; do check_ascomp "$stem" module; done
        [ -f "$MARK_ROOT/.board_lost" ] && break
    done
    cdir=src gdir=$src link_archives=() app_link_sams=()
fi

# --- compile-failure trials: each compiled alone, in parallel ------------------------------------
if [ "${#failtrials[@]}" -gt 0 ] && [ -z "$GEN" ]; then
    : > .fail_results
    echo "Compile-failure trials: ${#failtrials[@]} (compiled alone, ${BOARD_FAIL_JOBS:-4} at a time)..."
    printf '%s\n' "${failtrials[@]}" | xargs -P "${BOARD_FAIL_JOBS:-4}" -I{} bash "$0" --fail-one "$target" "$suite" "$work" {}
    ok=$((ok + $(grep -c '^PASS' .fail_results)))
    ko=$((ko + $(grep -c '^FAIL' .fail_results)))
fi

if [ "${#programs[@]}" -eq 0 ] && [ "${#failtrials[@]}" -eq 0 ] && [ "${#appdirs[@]}" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    echo "SKIP: ${prefix} no trials found"
fi
finish
