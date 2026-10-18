#!/usr/bin/env bash
# sync_to_hosts.sh -- push this checkout to the hosted build machines, deleting what this checkout
# no longer has. The one sync every agent and every platform script uses (Lee's rule, 2026-10-12).
#
# Usage:
#   programmer_tools/sync_to_hosts.sh [options]          dry run: classify, write the lists, change nothing
#   programmer_tools/sync_to_hosts.sh --apply [options]  pull goldens back, delete, then push
#
# Options:
#   --apply                 do it (the default is a dry run that only lists)
#   --targets "t1 t2"       emit targets to sync (default: every remote line of .silica_build_hosts)
#   --remote t=user@host[:path]   a one-run machine for target t (path defaults to ~/silica)
#   --list-dir DIR          where the per-host lists go (default: ${TMPDIR:-/tmp}/silica-sync)
#   --pull-newer            also pull this platform's goldens that the Mac has but the host has newer
#                           (default: pull only goldens the Mac does not have at all)
#   --no-push               pull and delete only (with --apply)
#   --push-preview          in a dry run, also run the push as rsync -n -i and save what it would send
#   --max-delete-pct N      refuse --apply when more than N% of the host's entries would go (default 40)
#   -h, --help              this header
#
# The rule. A file on the host that this checkout does not have is deleted, unless the platform being
# synced uses it. "Uses it" means exactly one of these:
#   1. host-local state at the repository root: binaries/ (each host's own Linux compilers and
#      seed links; never sent, never touched), .silica_build_hosts, .git, .claude, .claude-memory,
#      .scratch, .sync_keep, and any path matched by a glob in the host's own
#      ~/silica/.sync_keep (one glob per line, relative to the repository root).
#   2. build output the host generates, when the directory it sits in still exists here: the
#      .gitignore / sync_excludes.sh list (*.o *.a *.so *.dylib *.sams *.iface *.sout *.cur_* *.checked *.norm
#      *.mklog *.elf *.map *.log *.tmp *.pyc, silica.config/.target/.link/.atoms/.shapes/
#      .needs_runtime/.compile.order/.compile.inprogress, .silica.config.units*, .integrate* files and
#      directories (trials/.integrate_running is a live run's lock), dangerous_exposure_source)
#      and built trial executables (execute bit, no dot in the name). The whole-directory caches
#      compiler/build, compiler/.src_fixpoint, .stdlib_cache, .trial_cache, .trial_stdlib, .target,
#      __pycache__ and fixtures/build are never listed and never touched.
#   3. this platform's own goldens (<stem>.<target>.ascomp / .golden_fail / .golden_warn / .scout)
#      whose trial source <stem>.silica is still here. They are pulled back here BEFORE anything
#      is deleted, so a golden captured on the host and not yet copied back is never lost.
# Everything else missing here is deleted: trial sources, .scout, .golden_fail, markers (.multiset,
# .sorted, .wait_for_exit, .normalized), other platforms' goldens, this platform's goldens whose trial
# is gone, Makefiles, scripts, docs, stdlib and compiler sources, and stray directories -- including
# build output inside a directory that no longer exists here.
#
# Order per host: list (read-only ssh find) -> classify -> [apply:] pull goldens -> delete -> push.
# The push is rsync -a with SYNC_BUILD_EXCLUDES (built artifacts and a run's transient files, such as
# silica.compile.inprogress, .integrate*, *.tmp, never cross machines); symlinks travel as links,
# exactly as written (the tree's links are relative). binaries/ is never sent.
#
# Pushing while a run is going on in this tree. Trials and compiles create and delete files as they
# go, so a file in rsync's list can be gone when the sender opens it (openrsync, the Mac's rsync:
# "error: <path>: open (2) ... No such file or directory", exit 23; GNU rsync: "file has vanished",
# exit 24). Those are warnings: the push runs one retry pass to pick up anything the first pass
# missed, and succeeds when the only errors left are vanished files. Any other rsync error, or any
# other exit status, fails the push (push_one, classify_push_log).
#
# Why deletions are computed here and not with rsync --delete: the Mac's rsync is openrsync
# (protocol 29, no incremental recursion), and the delete modes made the 4 GB Pi build the whole
# ~230,000-entry list in memory and fail ("error allocating core memory buffers"). The host is
# listed with GNU find, classified here, and the deletions are an explicit list sent to xargs rm, so
# the dry-run list is exactly what --apply removes.
#
# Mangled-directory guard. trials/error_enforcement_addition/admin@pix.ca/trocalals/... and
# .../ca/tree@nix.localals/... came from an agent command typed into zsh as `rsync ... $h:silica/trials/`:
# zsh reads `$h:s` as the :s history modifier (delimiter "i", pattern "l", replacement "ca/tr"), so the
# destination lost its colon, became a local path, and a later push (which never deleted) carried it
# to both hosts. This script is bash, braces every ${conn}:${rpath}, checks each destination has the
# user@host:path form, refuses to push while this tree holds a directory whose name contains @ or :,
# and deletes such directories on the host because this tree does not have them.
# Typing a host sync by hand in zsh: write "${h}:silica/...", never $h:silica/...

set -u
[ -n "${BASH_VERSION:-}" ] || { echo "sync_to_hosts.sh: run with bash" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${SILICA_REPO:-$(cd "$HERE/.." && pwd)}"
. "$HERE/sync_excludes.sh"

APPLY=0; TARGETS=""; REMOTES=(); LIST_DIR="${TMPDIR:-/tmp}/silica-sync"; PULL_NEWER=0; DO_PUSH=1; MAX_PCT=40; PREVIEW=0
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --targets) TARGETS="$2"; shift ;;
        --targets=*) TARGETS="${1#*=}" ;;
        --remote) REMOTES+=("$2"); shift ;;
        --remote=*) REMOTES+=("${1#*=}") ;;
        --list-dir) LIST_DIR="$2"; shift ;;
        --list-dir=*) LIST_DIR="${1#*=}" ;;
        --pull-newer) PULL_NEWER=1 ;;
        --no-push) DO_PUSH=0 ;;
        --push-preview) PREVIEW=1 ;;
        --max-delete-pct) MAX_PCT="$2"; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (see -h)" >&2; exit 2 ;;
    esac
    shift
done
mkdir -p "$LIST_DIR" || exit 2

# The exclusions of the push: build products (SYNC_BUILD_EXCLUDES) plus local working state.
PUSH_EX=( "${SYNC_BUILD_EXCLUDES[@]}"
          --exclude '.git' --exclude '*.tmp' --exclude '/binaries/' --exclude '/.silica_build_hosts'
          --exclude '/.sync_keep'
          --exclude '.claude' --exclude '.claude-memory' --exclude '.codex_artifacts'
          --exclude '.cursor' --exclude '/.vscode' --exclude '.scratch'
          --exclude 'board_backups' --exclude '*.pptx' --exclude '*.ndjson'
          --exclude '.target' --exclude '*.elf' --exclude '*.map' --exclude '*.image.log'
          --exclude '.stdlib_cache' --exclude '.trial_cache' --exclude '.trial_stdlib' --exclude '*.log' )

# ------------------------------------------------------------------ machines
# bash 3.2 (macOS) has no associative arrays: CONNS is a list of "target=user@host:path" lines.

CONNS=""; ALL_REMOTE=""
for r in "${REMOTES[@]+"${REMOTES[@]}"}"; do
    t="${r%%=*}"; spec="${r#*=}"
    case "$spec" in *:*) ;; *) spec="$spec:~/silica" ;; esac
    CONNS="$CONNS$t=$spec
"
    TARGETS="${TARGETS:+$TARGETS }$t"
done
if [ -f "$REPO/.silica_build_hosts" ]; then
    while read -r t c p _; do
        case "$t" in ''|\#*) continue ;; esac
        case "$c" in *@*) ;; *) continue ;; esac
        CONNS="$CONNS$t=$c:${p:-~/silica}
"
        ALL_REMOTE="${ALL_REMOTE:+$ALL_REMOTE }$t"
    done < "$REPO/.silica_build_hosts"
fi
conn_of() { printf '%s' "$CONNS" | sed -n "s/^$1=//p" | head -1; }
[ -n "$TARGETS" ] || TARGETS="$ALL_REMOTE"
[ -n "${TARGETS// /}" ] || { echo "no remote targets: give --targets with .silica_build_hosts, or --remote t=user@host" >&2; exit 2; }

# ------------------------------------------------------------------ checks on this tree

[ -f "$REPO/compiler/src/Makefile" ] && [ -f "$REPO/trials/Makefile" ] && [ -f "$REPO/compiler/stdlib/data_structures/silica.config" ] || {
    echo "refusing: $REPO does not look like a complete Silica checkout (a deleting sync from it would empty the hosts)" >&2; exit 2; }
stray="$(cd "$REPO" && find trials compiler docs project_makefiles programmer_tools -maxdepth 5 \
          \( -name .target -o -name build -o -name .scratch \) -prune -o -type d \( -name '*@*' -o -name '*:*' \) -print 2>/dev/null)"
if [ -n "$stray" ]; then
    echo "refusing: this tree holds directories whose names contain @ or : (a mangled destination from an"
    echo "earlier hand-typed sync, see the header). Remove them here first:"
    echo "$stray" | sed 's/^/    /'
    exit 2
fi

# ------------------------------------------------------------------ per host

sync_one() {  # $1 = target
    local t="$1" spec conn rpath tag list rep rc
    spec="$(conn_of "$t")"
    [ -n "$spec" ] || { echo "== $t: no machine (add it to .silica_build_hosts or give --remote $t=user@host)"; return 1; }
    conn="${spec%%:*}"; rpath="${spec#*:}"
    [[ "$conn" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$ ]] || { echo "== $t: '$conn' is not user@host"; return 1; }
    case "$rpath" in ""|"/"|"~"|"~/"|/home|/home/*/|"$HOME") echo "== $t: refusing suspicious remote path '$rpath'"; return 1 ;; esac
    tag="$conn"
    echo "== $t on ${conn}:${rpath}"
    # A busy Pi can be slow to answer; three tries before giving up.
    local try ok=0
    for try in 1 2 3; do ssh -o BatchMode=yes -o ConnectTimeout=30 "$conn" true 2>/dev/null && { ok=1; break; }; done
    [ $ok = 1 ] || { echo "  cannot reach $conn over key-based ssh"; return 1; }
    ssh -o BatchMode=yes "$conn" "test -f ${rpath}/compiler/src/Makefile" 2>/dev/null || {
        echo "  ${conn}:${rpath} has no compiler/src/Makefile: not a Silica tree; a first sync there is a plain push"
        if [ "$APPLY" = 1 ] && [ "$DO_PUSH" = 1 ]; then push_one "$conn" "$rpath" "$t"; return $?; fi
        return 0; }

    # 1. list the host (read-only). Whole-directory caches are pruned: never listed, never touched.
    list="$LIST_DIR/hostlist_${tag}.bin"
    echo "  listing the host"
    ssh -o BatchMode=yes "$conn" "cd ${rpath} && find . -mindepth 1 \\( -path ./binaries -o -path ./.git \
        -o -path ./compiler/build -o -path ./compiler/.src_fixpoint -o -name .stdlib_cache -o -name .trial_cache \
        -o -name .trial_stdlib -o -name .target -o -name __pycache__ -o -path '*/fixtures/build' \\) -prune \
        -o -printf '%y %m %s %T@ %p\\0' 2>/dev/null; printf 'KEEPFILE\\0'; cat .sync_keep 2>/dev/null | tr '\\n' '\\0'" > "$list" || {
        echo "  listing failed"; return 1; }

    # 2. classify
    if [ "$APPLY" = 1 ]; then rep="$LIST_DIR/sync_applied_${tag}.txt"; else rep="$LIST_DIR/sync_dryrun_${tag}.txt"; fi
    python3 - "$REPO" "$list" "$t" "$LIST_DIR/sync_${tag}" "$rep" "$PULL_NEWER" "${conn}:${rpath}" <<'PY' || { echo "  classification failed"; return 1; }
import sys, os, re, fnmatch, collections
repo, listfile, plat, base, report, pull_newer, dest = sys.argv[1:8]
pull_newer = pull_newer == "1"
raw = open(listfile, "rb").read().split(b"\0")
entries, keep_globs, in_keep = [], [], False
for rec in raw:
    if not rec: continue
    s = rec.decode("utf-8", "surrogateescape")
    if s == "KEEPFILE": in_keep = True; continue
    if in_keep:
        s = s.strip()
        if s and not s.startswith("#"): keep_globs.append(s.lstrip("./"))
        continue
    ty, mode, size, mtime, path = s.split(" ", 4)
    entries.append((ty, int(mode, 8), int(size), float(mtime), path[2:]))

def here(p): return os.path.lexists(os.path.join(repo, p))
def here_dir(p): return p == "" or os.path.isdir(os.path.join(repo, p))

HOST_LOCAL_TOP = {"binaries", ".git", ".silica_build_hosts", ".sync_keep", ".claude", ".claude-memory", ".scratch"}
BUILD_GLOBS = ["*.o", "*.a", "*.so", "*.dylib", "*.sams", "*.iface", "*.sout", "*.cur_*", "*.checked", "*.norm",
               "*.gnorm", "*.mklog", "*.elf", "*.map", "*.log", "*.tmp", "*.ll", "*.bc", "*.pyc",
               "*.atom_rotext.expect", "silica.config", "silica.target", ".silica.config.units*",
               "silica.link", "silica.atoms", "silica.shapes", "silica.needs_runtime",
               "silica.compile.order", "silica.compile.inprogress", "silica.compile.crashed", ".integrate*",
               ".cache", ".DS_Store", ".gen1_emission_stamp", "silica-compiler-gen3",
               "dangerous_exposure_source"]
golden_re = re.compile(r"^(?P<stem>.+)\.(?P<plat>[A-Za-z0-9_-]+)\.(?P<kind>ascomp|golden_fail|golden_warn|scout)$")

cls = {}          # path -> (verdict, reason)
# Build-output directories (trials/.integrate_running is a live integrate's lock) whose parent is here:
# kept with everything under them.
keep_dirs = set(p for ty, mode, size, mtime, p in entries
                if ty == "d" and not here(p) and here_dir(os.path.dirname(p))
                and any(fnmatch.fnmatchcase(os.path.basename(p), g) for g in BUILD_GLOBS))
def under_keep_dir(p):
    d = p
    while d:
        if d in keep_dirs: return True
        d = os.path.dirname(d)
    return False
pull = []
newer = []        # this platform's goldens on both sides, host copy newer and different in size or time
for ty, mode, size, mtime, p in entries:
    if here(p):
        if ty == "f":
            m = golden_re.match(os.path.basename(p))
            if m and m.group("plat") == plat:
                st = os.lstat(os.path.join(repo, p))
                if mtime > st.st_mtime + 2 and size != st.st_size:
                    newer.append(p)
        continue
    top = p.split("/", 1)[0]
    parent = os.path.dirname(p)
    b = os.path.basename(p)
    if top in HOST_LOCAL_TOP:
        cls[p] = ("keep", "host-local"); continue
    if any(fnmatch.fnmatchcase(p, g) or fnmatch.fnmatchcase(p, g.rstrip("/") + "/*") for g in keep_globs):
        cls[p] = ("keep", "host .sync_keep"); continue
    if under_keep_dir(p):
        cls[p] = ("keep", "build output (directory)"); continue
    if ty == "d":
        cls[p] = ("deldir", "directory not here"); continue
    if not here_dir(parent):
        cls[p] = ("delete", "directory not here"); continue
    m = golden_re.match(b)
    if m and m.group("plat") == plat:
        stem = m.group("stem"); d = parent
        src = os.path.join(d, stem + ".silica") if d else stem + ".silica"
        if here(src) or stem == "__silica_runtime" or here_dir(os.path.join(d, stem)):
            cls[p] = ("keep", "this platform's golden, trial here: pulled back"); pull.append(p); continue
        cls[p] = ("delete", "this platform's golden, trial gone"); continue
    if m:
        cls[p] = ("delete", "golden of another platform (%s), not here" % m.group("plat")); continue
    if any(fnmatch.fnmatchcase(b, g) for g in BUILD_GLOBS):
        cls[p] = ("keep", "build output"); continue
    if ty == "f" and (mode & 0o111) and "." not in b:
        cls[p] = ("keep", "built executable"); continue
    cls[p] = ("delete", "not here")

# A directory that is not here goes unless something kept lies under it.
kept = [p for p, (v, _) in cls.items() if v == "keep"]
kept_anc = set()
for p in kept:
    d = os.path.dirname(p)
    while d:
        kept_anc.add(d); d = os.path.dirname(d)
for p, (v, r) in list(cls.items()):
    if v == "deldir" and p in kept_anc:
        cls[p] = ("keep", "directory holds kept files")

if pull_newer:
    pull.extend(newer)
del_files = sorted(p for p, (v, _) in cls.items() if v == "delete")
del_dirs = sorted((p for p, (v, _) in cls.items() if v == "deldir"), key=lambda s: (-s.count("/"), s))
for p in del_files + del_dirs + pull:
    assert not p.startswith("/") and ".." not in p.split("/") and p, p

open(base + ".delete_files", "wb").write(b"".join(p.encode("utf-8", "surrogateescape") + b"\0" for p in del_files))
open(base + ".delete_dirs", "wb").write(b"".join(p.encode("utf-8", "surrogateescape") + b"\0" for p in del_dirs))
open(base + ".pull", "w", encoding="utf-8", errors="surrogateescape").write("".join(p + "\n" for p in pull))

total = len(entries)
n_del = len(del_files) + len(del_dirs)
reasons = collections.Counter((v, r) for v, r in cls.values())
with open(report, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write("sync %s -> %s (target %s)\n" % (repo, dest, plat))
    f.write("host entries listed: %d (caches pruned: compiler/build, .src_fixpoint, .stdlib_cache, .trial_cache, .trial_stdlib, .target, __pycache__, fixtures/build; binaries/ and .git never touched)\n" % total)
    f.write("absent here: %d   delete: %d files + %d dirs (%.1f%% of host entries)   keep: %d   pull back first: %d\n\n"
            % (len(cls), len(del_files), len(del_dirs), 100.0 * n_del / max(total, 1), len(kept), len(pull)))
    f.write("by verdict and reason:\n")
    for (v, r), n in sorted(reasons.items()):
        f.write("  %-7s %7d  %s\n" % (v, n, r))
    def section(title, items):
        f.write("\n## %s (%d)\n" % (title, len(items)))
        for i in items: f.write(i + "\n")
    # Directories removed whole: list the directory once, not every file under it.
    gone = set(del_dirs)
    def under_gone(p):
        d = os.path.dirname(p)
        while d:
            if d in gone: return True
            d = os.path.dirname(d)
        return False
    top_dirs = [d for d in del_dirs if not under_gone(d)]
    section("PULL BACK to this tree before deleting", pull)
    if not pull_newer:
        section("NOT PULLED: %s goldens here and on the host, host copy newer and a different size (the push "
                "overwrites them with this tree's copy; --pull-newer pulls them first)" % plat, newer)
    section("DELETE directories (whole trees; count of files under each)",
            ["%s/  (%d files)" % (d, sum(1 for x in del_files if x.startswith(d + "/"))) for d in sorted(top_dirs)])
    section("DELETE files (outside the directories above)", [p + "    [" + cls[p][1] + "]" for p in del_files if not under_gone(p)])
    section("KEEP (absent here, used by %s)" % plat, sorted(p + "    [" + cls[p][1] + "]" for p in kept))
print("  absent here %d: delete %d files + %d dirs (%.1f%%), keep %d, pull back %d -> %s"
      % (len(cls), len(del_files), len(del_dirs), 100.0 * n_del / max(total, 1), len(kept), len(pull), report))
open(base + ".pct", "w").write("%d\n" % int(100.0 * n_del / max(total, 1)))
PY

    if [ "$APPLY" != 1 ]; then
        [ "$PREVIEW" = 1 ] && push_one "$conn" "$rpath" "$t" -n -i
        return 0
    fi

    local pct; pct="$(cat "$LIST_DIR/sync_${tag}.pct")"
    if [ "$pct" -gt "$MAX_PCT" ]; then
        echo "  refusing: $pct% of the host's entries would be deleted (limit $MAX_PCT%, --max-delete-pct). Read $rep."
        return 1
    fi
    # 3. pull this platform's goldens back first
    if [ -s "$LIST_DIR/sync_${tag}.pull" ]; then
        echo "  pulling back $(wc -l < "$LIST_DIR/sync_${tag}.pull" | tr -d ' ') goldens"
        rsync -a --files-from="$LIST_DIR/sync_${tag}.pull" "${conn}:${rpath}/" "$REPO/" || { echo "  pull failed: nothing deleted"; return 1; }
    fi
    # 4. delete, files then directories deepest first
    if [ -s "$LIST_DIR/sync_${tag}.delete_files" ]; then
        ssh -o BatchMode=yes "$conn" "cd ${rpath} && xargs -0 -r rm -f --" < "$LIST_DIR/sync_${tag}.delete_files" || { echo "  delete failed"; return 1; }
    fi
    if [ -s "$LIST_DIR/sync_${tag}.delete_dirs" ]; then
        ssh -o BatchMode=yes "$conn" "cd ${rpath} && xargs -0 -r rmdir --ignore-fail-on-non-empty --" < "$LIST_DIR/sync_${tag}.delete_dirs" || true
    fi
    echo "  deleted $(tr -cd '\0' < "$LIST_DIR/sync_${tag}.delete_files" | wc -c | tr -d ' ') files, $(tr -cd '\0' < "$LIST_DIR/sync_${tag}.delete_dirs" | wc -c | tr -d ' ') directories"
    # 5. push
    [ "$DO_PUSH" = 1 ] && push_one "$conn" "$rpath" "$t"
}

# One rsync pass of the push. $1 = user@host, $2 = remote path, $3 = log, then extra rsync flags.
# The executable excludes are recomputed per pass, so a retry sees trials linked since the first one.
push_pass() {
    local conn="$1" rpath="$2" log="$3" exfile rc
    shift 3
    exfile="$(mktemp "${TMPDIR:-/tmp}/silica-sync-exe.XXXXXX")"
    sync_exe_excludes "$REPO/trials" "/trials" > "$exfile"
    rsync -a "$@" "${PUSH_EX[@]}" --exclude-from="$exfile" "$REPO/" "${conn}:${rpath}/" > "$log" 2>&1; rc=$?
    rm -f "$exfile"
    return $rc
}

# Classify a push log after a non-zero exit. Prints "VANISHED <n> GONE <g> OTHER <m>" on the first
# line, then the OTHER lines. A "vanished" line is a source file under this tree that was in rsync's
# file list but was gone when the sender opened it: a run here (trials, a compile) deleted it
# mid-push. Recognised forms:
#   openrsync (macOS /usr/bin/rsync, exit 23):
#       rsync(PID): error: /path: open (2) in /root: No such file or directory   (also stat/lstat)
#   GNU rsync (exit 24, or 23 when mixed with other errors):
#       file has vanished: "/path"
#       rsync: [sender] send_files failed to open "/path": No such file or directory (2)
#       rsync: [sender] link_stat "/path" failed: No such file or directory (2)
# GNU's closing summaries ("rsync warning: some files vanished ... (code 24)", "rsync error: some
# files/attrs were not transferred ... (code 23)") are ignored. Every other rsync diagnostic is OTHER.
# GONE counts the vanished paths that still do not exist (the rest were recreated, e.g. the next
# unit's silica.compile.inprogress; the retry pass sends those).
classify_push_log() {  # $1 = log
    python3 - "$1" "$REPO" <<'PY2'
import sys, re, os
log, repo = sys.argv[1], os.path.realpath(sys.argv[2])
diag = re.compile(r'^(rsync\(\d+\): |rsync: |rsync error: |rsync warning: |file has vanished: )')
forms = [re.compile(r'^rsync\(\d+\): error: (.+): (?:open|stat|lstat) \(2\)(?: in .*)?: No such file or directory$'),
         re.compile(r'^file has vanished: "(.+)"$'),
         re.compile(r'^rsync: (?:\[sender\] )?send_files failed to open "(.+)": No such file or directory \(2\)$'),
         re.compile(r'^rsync: (?:\[sender\] )?link_stat "(.+)" failed: No such file or directory \(2\)$')]
summary = re.compile(r'^rsync (?:warning: some files vanished before they could be transferred \(code 24\)'
                     r'|error: some files/attrs were not transferred \(see previous errors\) \(code 23\))')
van = gone = 0; other = []
for line in open(log, encoding="utf-8", errors="replace"):
    s = line.rstrip("\n")
    if not diag.match(s) or summary.match(s): continue
    path = None
    for f in forms:
        m = f.match(s)
        if m: path = m.group(1); break
    if path is not None:
        rp = os.path.realpath(os.path.join(repo, path))
        if rp == repo or rp.startswith(repo + os.sep):
            van += 1
            if not os.path.lexists(rp): gone += 1
            continue
    other.append(s)
print("VANISHED %d GONE %d OTHER %d" % (van, gone, len(other)))
for s in other: print(s)
PY2
}

# Push, tolerating source files that vanish mid-push (a trial or compile run in this tree deletes its
# transient files while rsync reads the tree). Exit 0, or exit 23/24 with only vanished-file
# diagnostics, is a success; after vanishings one retry pass picks up anything the first pass missed,
# and vanishings in the retry are a warning too. Any other rsync error, any other exit status
# (ssh failure 255, protocol errors, ...), or exit 23/24 with no vanished line, is fatal.
push_one() {  # $1 = user@host, $2 = remote path, $3 = target, then extra rsync flags (-n -i: preview)
    local conn="$1" rpath="$2" rc log="$LIST_DIR/push_${1}.log" pass cl van gone oth
    shift 3
    [ $# -gt 0 ] && log="$LIST_DIR/push_preview_${conn}.txt"
    echo "  pushing${1:+ (preview $*)} (log $log)"
    for pass in 1 2; do
        local plog="$log"
        [ $pass = 2 ] && plog="${log%.*}.retry.${log##*.}"
        push_pass "$conn" "$rpath" "$plog" "$@"; rc=$?
        [ $rc -eq 0 ] && break
        if [ $rc -ne 23 ] && [ $rc -ne 24 ]; then
            echo "  push FAILED (rsync exit $rc, pass $pass)"; tail -3 "$plog" | sed 's/^/    /'; return 1
        fi
        cl="$(classify_push_log "$plog")" || { echo "  push FAILED (rsync exit $rc; could not read $plog)"; return 1; }
        read -r _ van _ gone _ oth <<< "$(printf '%s\n' "$cl" | head -1)"
        if [ "$oth" -ne 0 ] || [ "$van" -eq 0 ]; then
            echo "  push FAILED (rsync exit $rc, pass $pass): $oth error(s) other than vanished files"
            printf '%s\n' "$cl" | sed -n '2,6p' | sed 's/^/    /'
            [ "$van" -ne 0 ] && echo "    ($van vanished-file lines too; see $plog)"
            return 1
        fi
        echo "  warning: $van source file(s) vanished during pass $pass (a run in this tree deleted them;" \
             "$gone still gone), rsync exit $rc; see $plog"
        [ $pass = 1 ] && echo "  retrying the push once to pick up anything missed"
    done
    if [ $# -gt 0 ]; then echo "  push preview: $(grep -c '' "$log") lines in $log"; else echo "  pushed"; fi
}

overall=0
[ "$APPLY" = 1 ] || echo "DRY RUN: nothing is pulled, deleted or pushed (add --apply). Lists in $LIST_DIR"
for t in $TARGETS; do sync_one "$t" || overall=1; done
exit $overall
