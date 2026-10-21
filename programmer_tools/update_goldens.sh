#!/usr/bin/env bash
# Refresh the .ascomp assembly goldens under trials/ from the .sams a trial run left behind,
# for this machine's platform, for the other OS-hosted platforms over ssh, and for a raw
# target (ESP32-S3_raw) from the cross-compiled output this machine produced.
#
#   bash programmer_tools/update_goldens.sh                       # DRY RUN over every known platform
#   bash programmer_tools/update_goldens.sh --suite list_addition # DRY RUN over one suite
#   bash programmer_tools/update_goldens.sh --suite list_addition --apply
#   bash programmer_tools/update_goldens.sh --targets "apple_silicon_mac linux_x86_64" --apply
#   bash programmer_tools/update_goldens.sh --platform linux_x86_64 --remote linux_x86_64=lee@nix.local:~/silica
#   bash programmer_tools/update_goldens.sh --local-only --list
#   bash programmer_tools/update_goldens.sh trials/case_addition trials/negation_addition
#
# THE DEFAULT IS A DRY RUN. Nothing is written without --apply. A dry run prints every golden
# that would change with a per-file "+added -removed" line count, and a per-platform summary.
#
# WHY THIS SCRIPT IS DELIBERATELY AWKWARD
#   Goldens in this project are hand-derived and are not auto-regenerated: a golden that changes
#   is a BEHAVIOUR CHANGE in the compiler, and blessing it in bulk can bless a real defect just as
#   easily as a real improvement. This script exists so that a bulk refresh is possible after a
#   reviewed, intended change, not so that it becomes routine. Review the diffs it prints, then
#   review `git diff` after --apply, the same way you would review compiler source.
#
# WHAT IT COMPARES, AND HOW A GOLDEN IS MADE
#   A trial's golden is a PLAIN COPY of the .sams the compiler emitted: the trial makefiles do
#   `diff -Bw <stem>.sams <stem><ASCOMP_EXT>` (trials/silica_compiler.mk defines ASCOMP_EXT), and
#   the two `record` targets that exist do `cp <stem>.sams <stem><ASCOMP_EXT>`. There is no
#   filtering and no banner folding on the assembly side. This script does exactly that copy, and
#   uses `diff -Bw` to decide whether a copy is needed, so its answer matches the harness's.
#
# GOLDEN NAMES PER PLATFORM (trials/silica_compiler.mk, ASCOMP_EXT)
#   apple_silicon_mac   <stem>.ascomp                  (the bare name is the original Darwin golden)
#   linux_aarch64       <stem>.linux_aarch64.ascomp
#   linux_x86_64        <stem>.linux_x86_64.ascomp
#   ESP32-S3_raw        <stem>.ESP32-S3_raw.ascomp     (none exist yet: the board target does not
#                                                       compare assembly, see trials/targets/README.md)
#
# WHAT IT NEVER TOUCHES (all of this is hand-derived, or is not a golden at all)
#   *.scout and its variants (*.scout.multiset, *.scout.sorted, *.scout.normalized) - expected
#     program output and exit status, derived by hand.
#   *.<target>.scout - a reviewed, hand-recorded difference of that target from the Mac (the harness
#     reads it in place of the plain .scout there: trials/silica_compiler.mk SCOUT_FOR).
#   *.golden_fail, *.<target>.golden_fail, *.no_golden_fail - expected compiler diagnostics,
#     derived by hand (exit codes shift when literals are added; they are not mechanical).
#   *.sout, *.cur_fail - a run's actual output, never a golden.
#   __silica_runtime.ascomp - the runtime's assembly. Every trial makefile skips __silica_runtime
#     in its .ascomp loop, so these goldens are never compared by the harness and are already
#     stale in the tree. --include-runtime refreshes them anyway; the default leaves them alone.
#   A golden that has no current .sams beside it. Those are reported, never guessed at.
#   A missing golden. Recording a trial's first golden is hand work; --create-missing opts in, and
#     the dry run tells you how many there would be. One exception, the pairing rule the ad-hoc
#     refresher trials/tmp_refresh_ascomp_from_sams.sh already used and this script keeps: a trial
#     that has the bare <stem>.ascomp is a trial that compares assembly, so a HOSTED target may
#     create its own <stem>.<target>.ascomp beside it without the flag. A RAW target never does:
#     the board compares no assembly at all, so thousands of Xtensa goldens would be noise.
#   Anything outside trials/. The ten .ascomp files under compiler/ (the stdlib's Supervisor,
#     wbt_map, wbt_set and runtime goldens) are the compiler's own and are left alone.
#   A .sams whose architecture does not match the target it was asked to bless. That is the
#     "stale target .sams" trap: a cross build leaves the previous target's .sams in place. Such
#     a file is reported loudly and skipped, never copied.
#
# WHERE THE .sams COME FROM
#   This script never compiles and never builds a compiler. "Current .sams" means the files the
#   last trial run left in the tree:
#     native platform   trials/<suite>/**/<stem>.sams  (a suite's `integrate` cleans first and
#                       leaves its .sams behind; a tree-wide `make clean` removes them)
#     other hosted      the same files on that machine, pulled here with rsync over key-based ssh
#                       into a staging directory, then compared against the local golden
#     raw target        trials/.target/<target>/<suite>/src/**/<stem>.sams, the board run's work
#                       area, produced here by binaries/silica-compiler-<target>
#   If a suite has no .sams, run its trials first (`make -C trials/<suite> integrate`).
#
# WHICH PLATFORMS, AND WHERE THEIR MACHINES ARE
#   .silica_build_hosts in the repository root - the file programmer_tools/build_all_platforms.sh
#   writes - names the platforms and their machines, one line per platform:
#   "<emit target> <user@host|local> <repository path>", # starts a comment. It is read here and
#   never written. It is gitignored and must never be committed: it names your machines.
#     no flags            every platform in that file; without the file, this machine and any raw
#                         target whose work area exists
#     --targets "<list>"  only those platforms (comma or space separated)
#     --platform <t>      the same thing, one at a time
#     --remote <t>=<user@host>[:<path>]   a machine for one platform, for this run only
#     --local-only        this machine and the raw targets, no remote machines
#   Short names are accepted anywhere a platform is: mac, pi, nix, esp32, all, hosted.
#   Every remote connection is public/private key ssh: ssh runs in batch mode and never types a
#   password. Set it up with ssh-keygen and ssh-copy-id, and check it with
#   `ssh -o BatchMode=yes user@host true`.
#
# SCOPE
#   --suite <dir>   limit to one suite, repeatable. A bare path argument does the same, so
#                   `update_goldens.sh trials/case_addition` and `--suite case_addition` agree.
#                   Without a scope the whole trials tree is swept, which takes a minute or two
#                   just to walk (12,000 .sams, 37,000 goldens).
#
# FLAGS
#   --apply            write the goldens. Without it nothing is written.
#   --suite <dir>      limit the scope (repeatable); bare paths do the same
#   --targets "<l>"    limit the platforms
#   --platform <t>     limit to one platform (repeatable)
#   --remote <t>=<c>[:<p>]   one connection, for this run
#   --local-only       no remote machines
#   --include-runtime  also refresh __silica_runtime.ascomp (the harness never compares it)
#   --create-missing   also write a golden that does not exist yet
#   --keep-fetched     leave the rsync staging directory behind, for inspection
#   --list             print what this run would look at, then stop
#   -h, --help         this header
#
# SUPERSEDES
#   trials/tmp_refresh_ascomp_from_sams.sh, a single-platform tool with no dry run that copies
#   every *.sams over its sibling golden, including __silica_runtime, and follows symlinked
#   directories while it walks. Everything it does, this script does with a dry run first.

set -uo pipefail

REPO="${SILICA_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TRIALS="$REPO/trials"
PLATFORM_MK="$REPO/project_makefiles/platform/platforms.mk"
HOSTS_FILE="${SILICA_BUILD_HOSTS:-$REPO/.silica_build_hosts}"
DEFAULT_PATH="${SILICA_REMOTE_PATH:-~/silica}"

APPLY=0
LOCAL_ONLY=0
LIST_ONLY=0
INCLUDE_RUNTIME=0
CREATE_MISSING=0
KEEP_FETCHED=0
SELECTED=""
declare -a REMOTE_SPECS=()
declare -a SCOPES=()

usage() {  # every comment line of the header, however long it grows
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
    exit "${1:-0}"
}

# ---------------------------------------------------------------- arguments

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)           APPLY=1 ;;
        --local-only)      LOCAL_ONLY=1 ;;
        --list)            LIST_ONLY=1 ;;
        --include-runtime) INCLUDE_RUNTIME=1 ;;
        --create-missing)  CREATE_MISSING=1 ;;
        --keep-fetched)    KEEP_FETCHED=1 ;;
        --suite)           SCOPES+=("$2"); shift ;;
        --targets)         SELECTED="$SELECTED $(echo "$2" | tr ',' ' ')"; shift ;;
        --platform)        SELECTED="$SELECTED $(echo "$2" | tr ',' ' ')"; shift ;;
        --remote)          REMOTE_SPECS+=("$2"); shift ;;
        -h|--help)         usage 0 ;;
        -*)                echo "unknown argument: $1" >&2; usage 1 ;;
        *)                 SCOPES+=("$1") ;;
    esac
    shift
done

[ -f "$PLATFORM_MK" ] || { echo "platform table missing: $PLATFORM_MK" >&2; exit 1; }
[ -d "$TRIALS" ] || { echo "no trials directory: $TRIALS" >&2; exit 1; }

# The table answers one item per line; everything here wants a single space-separated line.
ask_table() { MAKEFLAGS= MAKELEVEL= make -s --no-print-directory -f "$PLATFORM_MK" "$1" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'; }

HOST_TARGET="$(ask_table host-emit-target)"
ALL_TARGETS="$(ask_table emit-targets)"
[ -n "$ALL_TARGETS" ] || ALL_TARGETS="apple_silicon_mac linux_aarch64 linux_x86_64 ESP32-S3_raw"
if [ -z "$HOST_TARGET" ]; then
    echo "This host ($(uname -s)/$(uname -m)) has no row in $PLATFORM_MK; add one first." >&2
    exit 1
fi

HOSTED_ALL=""
for t in $ALL_TARGETS; do case "$t" in *_raw) ;; *) HOSTED_ALL="$HOSTED_ALL $t" ;; esac; done

# The same short names programmer_tools/run_trials_all_platforms.sh takes.
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

is_raw() { case "$1" in *_raw) return 0 ;; esac; return 1; }

check_known() {
    local t
    for t in $1; do
        echo " $ALL_TARGETS " | grep -q " $t " || {
            echo "unknown target: $t (known: $ALL_TARGETS)" >&2; exit 1; }
    done
}

# ---------------------------------------------------------------- connections

declare -a R_TARGET=() R_CONN=() R_PATH=()

add_remote() {  # $1 = target, $2 = user@host[:path]
    local t="$1" spec="$2" conn path
    conn="${spec%%:*}"; path="${spec#*:}"
    [ "$path" = "$spec" ] && path="$DEFAULT_PATH"
    [ -n "$path" ] || path="$DEFAULT_PATH"
    R_TARGET+=("$t"); R_CONN+=("$conn"); R_PATH+=("$path")
}

conn_of() {  # $1 = target; prints user@host:path
    local i
    [ ${#R_TARGET[@]} -gt 0 ] || return 1
    for i in $(seq 0 $(( ${#R_TARGET[@]} - 1 ))); do
        [ "${R_TARGET[$i]}" = "$1" ] && { echo "${R_CONN[$i]}:${R_PATH[$i]}"; return 0; }
    done
    return 1
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
        case "$path" in ''|-) path="$DEFAULT_PATH" ;; esac
        add_remote "$t" "$conn:$path"
    done < "$HOSTS_FILE"
    [ -n "$FILE_TARGETS" ]
}

for spec in ${REMOTE_SPECS[@]+"${REMOTE_SPECS[@]}"}; do
    [ -n "$spec" ] || continue
    case "$spec" in
        *=*) add_remote "${spec%%=*}" "${spec#*=}" ;;
        *)   echo "--remote needs <target>=<user@host>[:<path>]: $spec" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------- which platforms

EXPANDED=""
for n in $SELECTED; do EXPANDED="$EXPANDED $(expand_name "$n")"; done

if [ -n "$EXPANDED" ]; then
    check_known "$EXPANDED"
    TARGETS="$EXPANDED"
    read_hosts_file >/dev/null 2>&1 || true      # reuse known machines, never rewrite the file
elif read_hosts_file; then
    TARGETS="$FILE_TARGETS"
    echo "using $HOSTS_FILE"
else
    TARGETS="$HOST_TARGET"
    for t in $ALL_TARGETS; do
        is_raw "$t" && [ -d "$TRIALS/.target/$t" ] && TARGETS="$TARGETS $t"
    done
    echo "no $HOSTS_FILE: this machine only"
fi

# ---------------------------------------------------------------- scope

# A scope is a suite name or a path; both become a path relative to trials/.
declare -a SCOPE_REL=()
for s in ${SCOPES[@]+"${SCOPES[@]}"}; do
    rel="$s"
    rel="${rel#./}"
    rel="${rel#"$REPO/"}"
    rel="${rel#trials/}"
    rel="${rel%/}"
    case "$rel" in
        ''|.) continue ;;
        /*)   echo "scope must be inside the repository: $s" >&2; exit 1 ;;
    esac
    if [ ! -d "$TRIALS/$rel" ]; then
        echo "no such trial or suite: trials/$rel" >&2; exit 1
    fi
    SCOPE_REL+=("$rel")
done
if [ ${#SCOPE_REL[@]} -eq 0 ]; then SCOPE_REL=("."); fi

scope_label() {
    if [ "${SCOPE_REL[0]}" = "." ]; then echo "the whole trials tree"; else echo "trials/${SCOPE_REL[*]}"; fi
}

# ---------------------------------------------------------------- helpers

golden_ext() {  # trials/silica_compiler.mk: ASCOMP_EXT
    if [ "$1" = apple_silicon_mac ]; then echo ".ascomp"; else echo ".$1.ascomp"; fi
}

# The architecture a .sams was emitted for, from its own text. Guards the stale-target trap:
# a cross build leaves the previous target's .sams in the tree, and copying one of those over a
# golden records another platform's assembly. Only the first 200 lines are read.
#   linux_x86_64      .intel_syntax noprefix
#   ESP32-S3_raw      the XADDR macro / a literal pool (Xtensa)
#   apple_silicon_mac Mach-O section directive, or underscore-prefixed globals
#   linux_aarch64     everything else that is AArch64 (plain .text, .arch armv8..., no underscores)
sams_arch() {
    awk '
        /\.intel_syntax/                          { a = "x86_64";      exit }
        /\.macro XADDR|\.literal_position|\.literal[ \t]/ { a = "xtensa"; exit }
        /__TEXT,__text/                           { a = "macho_arm64"; exit }
        /^[ \t]*\.(extern|globl|global)[ \t]+_/   { a = "macho_arm64"; exit }
        NR > 200                                  { exit }
        END { if (a == "") a = "elf_arm64"; print a }
    ' "$1" 2>/dev/null
}

arch_for_target() {
    case "$1" in
        apple_silicon_mac) echo macho_arm64 ;;
        linux_aarch64)     echo elf_arm64 ;;
        linux_x86_64)      echo x86_64 ;;
        ESP32-S3_raw)      echo xtensa ;;
        *)                 echo unknown ;;
    esac
}

FIND_PRUNE='-name .target -o -name .cache -o -name .trial_cache -o -name .stdlib_cache -o -name .integrate_running -o -name .git'

find_sams() {  # $1 = root, then scope-relative dirs
    local root="$1"; shift
    local rel
    for rel in "$@"; do
        [ -d "$root/$rel" ] || continue
        find "$root/$rel" \( $FIND_PRUNE \) -prune -o -type f -name '*.sams' -print 2>/dev/null
    done
}

# ---------------------------------------------------------------- the work

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/silica_goldens.XXXXXX")" || exit 1
cleanup() { [ "$KEEP_FETCHED" = 1 ] || rm -rf "$TMPROOT"; }
trap cleanup EXIT

SUMMARY="$TMPROOT/summary"
: > "$SUMMARY"
TOTAL_CHANGED=0
TOTAL_WRITTEN=0
TOTAL_WRONG_ARCH=0
PROBLEMS=0

# Pull one remote platform's .sams into a staging mirror of trials/.
fetch_remote() {  # $1 = target, $2 = user@host, $3 = remote repo path, $4 = stage dir
    local t="$1" conn="$2" rpath="$3" stage="$4" rel rc=0
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$conn" true >/dev/null 2>&1 || {
        echo "  cannot reach $conn over key-based ssh (ssh -o BatchMode=yes $conn true fails)"; return 1; }
    for rel in "${SCOPE_REL[@]}"; do
        mkdir -p "$stage/$rel"
        rsync -a --prune-empty-dirs \
            --exclude '.target/' --exclude '.cache/' --exclude '.trial_cache/' \
            --exclude '.stdlib_cache/' --exclude '.git/' \
            --include '*/' --include '*.sams' --exclude '*' \
            -e 'ssh -o BatchMode=yes' \
            "$conn:$rpath/trials/$rel/" "$stage/$rel/" || rc=1
    done
    return $rc
}

# One platform: walk its .sams, map each to a golden, classify, and (with --apply) copy.
process_target() {  # $1 = target, $2 = sams root, $3 = mapping mode (direct|board)
    local t="$1" root="$2" mode="$3"
    local ext want_arch sams rel gold base dir stem mac_gold d add del arch
    local changed=0 same=0 missing=0 paired=0 runtime=0 wrongarch=0 written=0 unmapped=0

    ext="$(golden_ext "$t")"
    want_arch="$(arch_for_target "$t")"

    echo
    echo "── $t  (golden suffix $ext, .sams under ${root#$REPO/})"

    while IFS= read -r sams; do
        [ -n "$sams" ] || continue
        rel="${sams#$root/}"
        base="${rel##*/}"
        if [ "$base" = "__silica_runtime.sams" ] && [ "$INCLUDE_RUNTIME" = 0 ]; then
            runtime=$((runtime + 1)); continue
        fi
        if [ "$mode" = board ]; then
            # <suite>/src/<rest>.sams -> trials/<suite>/<rest><ext>
            case "$rel" in
                */src/*) rel="${rel%%/src/*}/${rel#*/src/}" ;;
                *)       unmapped=$((unmapped + 1)); continue ;;
            esac
        fi
        dir="${rel%/*}"; [ "$dir" = "$rel" ] && dir="."
        stem="${rel##*/}"; stem="${stem%.sams}"
        case "$dir" in
            .) gold="$TRIALS/$stem$ext";      mac_gold="$TRIALS/$stem.ascomp" ;;
            *) gold="$TRIALS/$dir/$stem$ext"; mac_gold="$TRIALS/$dir/$stem.ascomp" ;;
        esac

        if [ ! -f "$gold" ]; then
            # The pairing rule the ad-hoc refresher used: a trial that has the bare .ascomp is a
            # trial that compares assembly, so every hosted target it is built for wants its own
            # golden. That is a creation, not a recording, so it is allowed without a flag -- but
            # only for a hosted target, never for a raw one (the board compares no assembly).
            if [ "$ext" != ".ascomp" ] && [ -f "$mac_gold" ] && ! is_raw "$t"; then
                arch="$(sams_arch "$sams")"
                if [ "$arch" != "$want_arch" ]; then
                    wrongarch=$((wrongarch + 1))
                    echo "  !! WRONG ARCHITECTURE  ${sams#$REPO/} is $arch, not $want_arch; skipped"
                    continue
                fi
                paired=$((paired + 1))
                echo "  new      ${gold#$REPO/}   (paired with the existing $stem.ascomp)"
                if [ "$APPLY" = 1 ]; then cp "$sams" "$gold" && written=$((written + 1)); fi
                continue
            fi
            if [ "$CREATE_MISSING" = 1 ]; then
                arch="$(sams_arch "$sams")"
                if [ "$arch" != "$want_arch" ]; then
                    wrongarch=$((wrongarch + 1))
                    echo "  !! WRONG ARCHITECTURE  ${sams#$REPO/} is $arch, not $want_arch; skipped"
                    continue
                fi
                paired=$((paired + 1))
                echo "  new      ${gold#$REPO/}   (--create-missing: this trial had no golden)"
                if [ "$APPLY" = 1 ]; then cp "$sams" "$gold" && written=$((written + 1)); fi
            else
                missing=$((missing + 1))
            fi
            continue
        fi

        if cmp -s "$sams" "$gold"; then same=$((same + 1)); continue; fi
        d="$(diff -Bw "$gold" "$sams" 2>/dev/null)"
        if [ -z "$d" ]; then same=$((same + 1)); continue; fi   # whitespace only: the harness passes
        arch="$(sams_arch "$sams")"
        if [ "$arch" != "$want_arch" ]; then
            wrongarch=$((wrongarch + 1))
            echo "  !! WRONG ARCHITECTURE  ${sams#$REPO/} is $arch, not $want_arch; skipped"
            continue
        fi
        add="$(printf '%s\n' "$d" | grep -c '^>')"; add="${add:-0}"
        del="$(printf '%s\n' "$d" | grep -c '^<')"; del="${del:-0}"
        changed=$((changed + 1))
        printf '  +%-6s -%-6s %s\n' "$add" "$del" "${gold#$REPO/}"
        if [ "$APPLY" = 1 ]; then cp "$sams" "$gold" && written=$((written + 1)); fi
    done <<EOF
$(find_sams "$root" "${SCOPE_REL[@]}")
EOF

    if [ $((changed + same + missing + paired + runtime)) -eq 0 ]; then
        echo "  no .sams found: run the trials for $t first"
    fi
    [ "$runtime" -gt 0 ] && echo "  ($runtime __silica_runtime.sams left alone; the harness never compares them)"
    [ "$unmapped" -gt 0 ] && echo "  ($unmapped .sams outside a <suite>/src/ work area, not mapped to a golden)"
    [ "$missing" -gt 0 ] && [ "$CREATE_MISSING" = 0 ] && \
        echo "  ($missing .sams have no golden of any kind; --create-missing would record them)"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$t" "$changed" "$paired" "$same" "$missing" "$wrongarch" "$written" >> "$SUMMARY"
    TOTAL_CHANGED=$((TOTAL_CHANGED + changed + paired))
    TOTAL_WRITTEN=$((TOTAL_WRITTEN + written))
    TOTAL_WRONG_ARCH=$((TOTAL_WRONG_ARCH + wrongarch))
}

# ---------------------------------------------------------------- plan

echo "repository      : $REPO"
echo "native target   : $HOST_TARGET"
echo "platforms       :$(for t in $TARGETS; do printf ' %s' "$t"; done)"
echo "scope           : $(scope_label)"
echo "mode            : $([ "$APPLY" = 1 ] && echo 'APPLY (goldens will be written)' || echo 'dry run (nothing is written)')"

PLAN=""
for t in $TARGETS; do
    if [ "$t" = "$HOST_TARGET" ]; then
        PLAN="$PLAN
  $t: local trials/ (this machine's own .sams)"
    elif is_raw "$t"; then
        if [ -d "$TRIALS/.target/$t" ]; then
            PLAN="$PLAN
  $t: local trials/.target/$t (cross-compiled here)"
        else
            PLAN="$PLAN
  $t: no work area at trials/.target/$t; run its trials here first - skipped"
        fi
    elif [ "$LOCAL_ONLY" = 1 ]; then
        PLAN="$PLAN
  $t: skipped (--local-only)"
    elif spec="$(conn_of "$t")"; then
        PLAN="$PLAN
  $t: .sams pulled from ${spec%%:*} (${spec#*:}/trials) over ssh"
    else
        PLAN="$PLAN
  $t: needs a $t machine; use --remote $t=user@host - skipped"
    fi
done
printf '%s\n' "$PLAN"

if [ "$LIST_ONLY" = 1 ]; then exit 0; fi
if [ "${SCOPE_REL[0]}" = "." ]; then
    echo
    echo "(sweeping the whole trials tree; walking 12,000 .sams takes a minute or two)"
fi

# ---------------------------------------------------------------- run

for t in $TARGETS; do
    if [ "$t" = "$HOST_TARGET" ]; then
        process_target "$t" "$TRIALS" direct
    elif is_raw "$t"; then
        if [ -d "$TRIALS/.target/$t" ]; then
            process_target "$t" "$TRIALS/.target/$t" board
        else
            echo; echo "── $t: no work area at trials/.target/$t; skipped"
        fi
    elif [ "$LOCAL_ONLY" = 1 ]; then
        continue
    elif spec="$(conn_of "$t")"; then
        conn="${spec%%:*}"; rpath="${spec#*:}"
        stage="$TMPROOT/$t"
        mkdir -p "$stage"
        echo; echo "── $t: fetching .sams from $conn:$rpath/trials"
        if fetch_remote "$t" "$conn" "$rpath" "$stage"; then
            process_target "$t" "$stage" direct
        else
            echo "  fetch failed; $t skipped"
            PROBLEMS=1
        fi
    else
        echo; echo "── $t: no machine given (--remote $t=user@host); skipped"
    fi
done

# ---------------------------------------------------------------- summary

echo
echo "════════════════════════════════════════════════════════════════════════════"
if [ -s "$SUMMARY" ]; then
    printf '  %-20s %8s %8s %10s %10s %11s %8s\n' \
        platform changed new unchanged "no-golden" "wrong-arch" written
    while IFS="$(printf '\t')" read -r t changed paired same missing wrongarch written; do
        printf '  %-20s %8s %8s %10s %10s %11s %8s\n' \
            "$t" "$changed" "$paired" "$same" "$missing" "$wrongarch" "$written"
    done < "$SUMMARY"
else
    echo "  no platform produced any .sams to compare"
fi
echo "════════════════════════════════════════════════════════════════════════════"

if [ "$TOTAL_WRONG_ARCH" -gt 0 ]; then
    echo
    echo "!! $TOTAL_WRONG_ARCH .sams did not match the architecture of the platform they were"
    echo "!! asked to bless, and were skipped. That is the stale-target trap: a cross build left"
    echo "!! the previous target's .sams in the tree. Run 'make clean' in trials/ and re-run the"
    echo "!! trials for that platform before refreshing its goldens."
    PROBLEMS=1
fi

echo
if [ "$APPLY" = 1 ]; then
    echo "**  $TOTAL_WRITTEN golden(s) were WRITTEN (created or rewritten)."
else
    echo "**  $TOTAL_CHANGED golden(s) WOULD change. Nothing was written: re-run with --apply."
fi
echo "**"
echo "**  A CHANGED GOLDEN IS A BEHAVIOUR CHANGE IN THE COMPILER AND MUST BE REVIEWED AS ONE."
echo "**  Goldens in this project are hand-derived; refreshing one in bulk can bless a defect"
echo "**  just as easily as a fix. Read 'git diff' over these files before committing them, and"
echo "**  re-run the trials afterwards so the harness confirms what you blessed."
echo

exit "$PROBLEMS"
