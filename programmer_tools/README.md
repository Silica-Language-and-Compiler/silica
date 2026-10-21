# programmer_tools

Scripts for building Silica across machines, running its trials, and keeping the recorded
expectations honest. Every script prints its own manual with `-h` or `--help`, and the ones that do
anything expensive accept `--list` to show what a run would do without doing it.

## Working on the compiler?

Read **[A change, end to end](https://yenrab.github.io/silica/build-and-test/#a-change-end-to-end)**
first. It gives the order to work in, from making your modification to reaching a new fixed point,
with a table of which steps a given kind of change needs. The scripts below are what it calls.

## Which script do I want?

| I want to | Use |
| --- | --- |
| Build the compiler everywhere it is supported | `build_all_platforms.sh` |
| Run the trials on every platform | `run_trials_all_platforms.sh` |
| Do both, in one command | `build_and_trial_all_platforms.sh` |
| Find out what is really broken after changing the compiler | `rebuild_refresh_verify.sh` |
| Re-record assembly goldens after an intended change | `update_goldens.sh` |
| Copy this tree to the Linux build machines (and only that) | `sync_to_hosts.sh` |
| Run one app through the platform-neutral entry point | `run_app.sh` |

## The machine file

Three of these scripts read `.silica_build_hosts` in the repository root: one line per platform,
`<emit target> <user@host|local> <repository path>`. It is written the first time a script asks, and
reused silently afterwards. **It is gitignored and must never be committed**, because it names your
machines.

Every remote connection is public/private key ssh. The scripts run `ssh` in batch mode and never type
a password, so set a key up first with `ssh-keygen` and `ssh-copy-id user@host`, and check it with
`ssh -o BatchMode=yes user@host true`.

## What each script does

### build_all_platforms.sh
Builds Silica for every supported platform, from whatever machine you start on.

An OS-hosted platform compiles its own code, so it builds natively on its own machine and reaches its
own fixed point there: this script does that here, and over ssh on the machines you name. It does not
cross-build a hosted platform, with one exception, a machine that has no compiler yet, which it
offers to hand a first one to by building here, emitting the assembly here and linking there. A raw
platform such as `ESP32-S3_raw` has no operating system and cannot host a compiler, so its cross
compiler is built here.

Per machine the work is build, gen1, gen2, fixed-point check, publish; `--no-fixpoint` stops after the
build. Platform selection: nothing selects the remembered set, `--targets "<list>"` selects for one
run, `--set_targets "<list>"` asks and rewrites the file, `--refresh_targets` re-asks, `--remote
<target>=<user@host>[:<path>]` names one machine inline, `--local-only` stays on this machine.

### run_trials_all_platforms.sh
Runs the full trial tree on each platform with that platform's own compiler. It never builds
anything: each machine must already have a compiler at `binaries/silica-compiler`, and a raw target is
driven from this machine with the cross compiler built for it.

Remote machines run at the same time as each other; this machine and any board run one after another,
because both take the tree-wide lock at `trials/.integrate.lock`. `--sync` syncs the tree to each
remote machine first with `sync_to_hosts.sh`. `--board` includes a raw target, which
is off by default because the board has to be plugged in. Short names `mac`, `pi`, `nix`, `esp32`,
`all` and `hosted` are accepted anywhere a platform is.

### build_and_trial_all_platforms.sh
The two above in one command: build every indicated platform, then run the full trial tree on each.
Both halves read the same machine file, so platforms named once are used twice. The trials do not run
if a build fails, because a trial result only means something when it came from a compiler that built
cleanly. `--skip-build` and `--skip-trials` run half of it.

### rebuild_refresh_verify.sh
Answers the question "the compiler changed, what is actually broken now?".

Per hosted platform, in order: clean and build; run the whole tree once, which is what produces the
assembly the goldens come from; record the goldens with `update_goldens.sh --apply`, which refreshes
only trials whose program output already matched; run the whole tree again. **The second run is the
answer**: every stale-expectation failure is gone, so whatever is still red is a behaviour difference.

A raw target is built here as a cross compiler and its trials run on the attached board, with no
golden step, because the board harness compares program output only and never assembly. Raw targets
run last, since the board takes this machine's trial lock.

With no `--targets` it asks which platforms to run and, for each hosted machine it does not know, for
the connection; if the machine file already exists it shows what it remembers and lets you keep or
change it, with every answer prefilled. It ends with a per-platform table of PASS, FAIL, BUILD FAILED,
NO MACHINE or UNREACHABLE, and exits non-zero unless every platform passed.

### update_goldens.sh
Re-records `.ascomp` assembly goldens from the `.sams` a trial run left behind.

**It is a dry run by default and needs `--apply` to write anything.** Goldens in this project are
hand-derived and are not auto-regenerated: a golden that changes is a behaviour change in the
compiler, and blessing one in bulk can bless a defect as easily as a fix. The dry run prints every
golden that would change with a per-file added/removed line count, so a three-line drift and a
three-thousand-line rewrite do not look alike.

It never touches `.scout` or `.golden_fail` files, skips `__silica_runtime`, which the harness never
compares, and refuses a `.sams` whose instruction set does not match the platform being blessed, which
is what catches a stale cross-build. `--suite <dir>` or bare paths limit the scope; `--create-missing`
is needed before it will record a golden that does not exist yet.

### sync_to_hosts.sh
The one way this tree reaches the hosted build machines; the three scripts above call it, and an
agent that needs a sync runs it rather than a hand-typed `rsync`. Following Lee's rule (2026-10-12),
a file on the host that this tree no longer has is deleted unless the platform being synced uses it.

**It is a dry run by default and needs `--apply` to change anything.** The dry run writes
`sync_dryrun_<user@host>.txt` (in `--list-dir`, default `$TMPDIR/silica-sync`) listing every path it
would pull back, delete and keep, with the reason for each.

    bash programmer_tools/sync_to_hosts.sh                       # dry run, every remote in .silica_build_hosts
    bash programmer_tools/sync_to_hosts.sh --targets linux_x86_64 --apply
    bash programmer_tools/sync_to_hosts.sh --remote linux_aarch64=admin@pix.local:~/silica --apply

Kept on the host even though this tree lacks them:
- host-local state at the root: `binaries/` (that machine's own compilers; never sent, never
  touched), `.git`, `.silica_build_hosts`, `.claude`, `.claude-memory`, `.scratch`, plus any glob
  listed in the host's own `~/silica/.sync_keep`;
- build output the host generates, while its directory still exists here (the `.gitignore` and
  `sync_excludes.sh` list, `.integrate*` files and the `trials/.integrate_running` lock, `.checked`
  stamps, built trial executables). Cache directories (`compiler/build`, `.stdlib_cache`,
  `.trial_cache`, `.target`, `fixtures/build`, ...) are never listed or touched;
- that platform's own goldens (`<stem>.linux_<arch>.ascomp`, `.golden_fail`, `.golden_warn`,
  `.scout`) whose `<stem>.silica` is still here. These are **pulled back here first**, before
  anything is deleted. `--pull-newer` also pulls ones this tree has whose host copy is newer and a
  different size; the dry run lists them.

Everything else this tree lacks is deleted: trial sources and their `.scout`/`.golden_fail`/marker
files, other platforms' goldens, goldens whose trial is gone, sources, scripts, docs, and stray
directories. Order per host: list (read-only `find` over ssh), classify, pull, delete, push. The
deletions are an explicit list, not an rsync delete mode, because the delete modes made the 4 GB Pi
hold the whole file list in memory and fail; `--apply` also refuses if more than 40% of the host
would go (`--max-delete-pct`). `--push-preview` adds an `rsync -n -i` of the push to a dry run.

The push never sends build output or a run's transient files (the `SYNC_BUILD_EXCLUDES` list in
`sync_excludes.sh`, plus the script's own list): `.sams`, `.iface`, `.o`, `.sout`, `.checked`, built
trial executables, `silica.compile.inprogress` and `silica.compile.crashed`, `.integrate*` (logs,
reports, marks, `.integrate_running/`, `.integrate.lock/`), `*.cur_*`, `*.tmp`,
`.silica.config.units*`, `.cache/`, logs, `.trial_cache`, `.trial_stdlib`, `.target`, `.DS_Store`.
Some files stay on purpose: tracked `*.golden_link_fail.clang.norm` goldens, `trials/.board.lock`, and
`INTEGRATE_PENDING` markers still travel.

Pushing while a trial run or a compile is going on in this tree is safe. A file the run deletes
after rsync has listed it can trigger an error: the Mac's openrsync prints `error: <path>: open (2) in
...: No such file or directory` and exits 23, and GNU rsync prints `file has vanished` and exits 24.
Those errors are only warnings. The push then makes one retry pass, and it succeeds if the only
errors left are vanished files. Any other rsync error fails the push (for example `Permission denied`,
or a write failure on the host), and so does any other exit status (ssh 255, protocol errors). The
retry log is `push_<user@host>.retry.log` next to `push_<user@host>.log`. Before this was added,
on 2026-10-16, a push to pix and nix during a Mac whole-tree run failed on
`silica.compile.inprogress`.

Typing a host path by hand in zsh, write `"${h}:silica/..."`, never `$h:silica/...`: zsh reads
`$h:s...` as a substitution modifier, and that is how `trials/error_enforcement_addition/admin@pix.ca/`
and `ca/tree@nix.localals/` were made. The script is bash and refuses to push while this tree holds
a directory whose name contains `@` or `:`.

### run_app.sh
A platform-neutral entry point for running one app. It is a three-line wrapper: it does nothing itself
except `exec` `run_board_app.sh` from its own directory, passing every argument through unchanged, so
its options, exit status and output are whatever that script defines. The wrapper's own comment says
`run_board_app.sh` is retained for compatibility.

    bash programmer_tools/run_app.sh <arguments for run_board_app.sh>

It reads no `.silica_build_hosts`, selects no target or host, and has no `-h` of its own. In this
tree `run_board_app.sh` is not present in `programmer_tools/`, so until it is supplied the wrapper
cannot run anything. The ESP32-S3 board's app runner is a separate script,
`compiler/src/emitter/ESP32-S3_raw/board/tools/run_app.sh`, which has its own `-h`.

## Subdirectories

- **`defect_batch/`** — artefacts of the September 2026 defect-clearing batch: `merge_lanes.sh` merges
  the lane branches onto main in a safe order, dry by default; `merge_notes.md` lists the known
  collisions; `defect_ledger.md` is the full record of every defect, what was proven and what was
  retracted; `post_merge_harness_queue.md` holds harness work waiting for a quiet tree, including
  `drop_rust_lld.py`, a tested transform that removes the retired Rust linker from the trial makefiles.
- **`train_trial_generator/`** — generates paired Silica trials for model training; see its own README.

## The jsonld files

`silica-builder.jsonld`, `silica-compaid.jsonld` and `silica-error-code-scheme.jsonld` are tool
definitions rather than scripts, and are not run from here.
