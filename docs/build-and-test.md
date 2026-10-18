---
title: Build and test the compiler
layout: default
permalink: /build-and-test/
---

# Build and test the compiler

How to build Silica for every platform, for some of them, or for just the machine in front of you; how to run the trials on each platform; how to use the compiler that is already in the checkout without building anything; and where released compilers appear on GitHub.

These steps build the self-hosted toolchain ([roadmap](https://github.com/yenrab/silica/blob/main/ROADMAP.md) Track 1). This page mirrors the [README](https://github.com/yenrab/silica#building-the-compiler); the repository copy is the one kept in step with the Makefiles.

## You probably do not need to build the compiler

Building is for people who **change the compiler's own code** in `compiler/src/`, or who are porting
it to a new platform. If you are writing Silica programs, you do not need any of this: use the
compiler that is already in the checkout, or download a released one. Both are one section away, in
[Use the compiler that is already here](#use-the-compiler-that-is-already-here) and
[Get a released compiler from GitHub](#get-a-released-compiler-from-github).

Everything between here and those two sections is for compiler work.

## The compiler builds itself

Silica's compiler is written in Silica. There is no bootstrap compiler to build and no separate seed source tree: a compiler binary already in `binaries/` compiles the sources in [compiler/src/](https://github.com/yenrab/silica/tree/main/compiler/src/), and the compiler that comes out compiles them again until the two agree byte for byte. That last step is the **fixed point**, and it is what a finished build means. The binary that starts the chain is reached through `binaries/seed-compiler`, and a finished build becomes the next one.

Nothing in the build path is written in Rust, and nothing needs `cargo`. The retired Rust bootstrap lives only in the repository's history.

## Platforms

A platform is an **emit target**: the directory under [compiler/src/emitter/](https://github.com/yenrab/silica/tree/main/compiler/src/emitter/) whose backend a compiler bakes in. The table of record is [project_makefiles/platform/platforms.mk](https://github.com/yenrab/silica/blob/main/project_makefiles/platform/platforms.mk).

| Emit target | Runs on | How it is built |
| ----------- | ------- | --------------- |
| `apple_silicon_mac` | macOS on Apple Silicon (`macos-applesilicon`) | OS-hosted: built natively on an Apple Silicon Mac |
| `linux_aarch64` | Linux on AArch64 (`linux-aarch64`) | OS-hosted: built natively on a Linux AArch64 machine |
| `linux_x86_64` | Linux on x86-64 (`linux-x86_64`) | OS-hosted: built natively on a Linux x86-64 machine |
| `ESP32-S3_raw` | nothing — the ESP32-S3 has no OS | Raw: its cross compiler is built on whichever machine you start from |

An **OS-hosted** platform can run a compiler, so it builds its own and reaches its own fixed point on its own machine. A **raw** platform cannot run a compiler at all, so the compiler that emits its code is built elsewhere and published as `binaries/silica-compiler-<emit target>`.

## The scripts

> **Every tool in `programmer_tools/` is described in its own reference: [programmer_tools/README.md](https://github.com/yenrab/silica/blob/main/programmer_tools/README.md).** It covers what each script is for, the machine file they share, the key-based ssh they require, and the two scripts this page does not cover, the golden refresher and the rebuild-and-verify run.


| Script | What it does |
| ------ | ------------ |
| [`programmer_tools/build_all_platforms.sh`](https://github.com/yenrab/silica/blob/main/programmer_tools/build_all_platforms.sh) | Builds Silica for every platform you name, from whatever machine you start on. |
| [`programmer_tools/run_trials_all_platforms.sh`](https://github.com/yenrab/silica/blob/main/programmer_tools/run_trials_all_platforms.sh) | Runs the full trial tree on each platform with that platform's own compiler. It never builds a compiler. |
| [`programmer_tools/build_and_trial_all_platforms.sh`](https://github.com/yenrab/silica/blob/main/programmer_tools/build_and_trial_all_platforms.sh) | Both, in one command: build every indicated platform, then run the full trial tree on each one. |
| [`programmer_tools/rebuild_refresh_verify.sh`](https://github.com/yenrab/silica/blob/main/programmer_tools/rebuild_refresh_verify.sh) | Per platform: rebuild, run the whole tree, re-record the assembly goldens of trials whose output already matched, run the tree again. Steps 5 and 6 of [A change, end to end](#a-change-end-to-end). |
| [`programmer_tools/sync_to_hosts.sh`](https://github.com/yenrab/silica/blob/main/programmer_tools/sync_to_hosts.sh) | Pushes this checkout to the remote build machines, deleting what the checkout no longer has and pulling each platform's goldens back first. A dry run unless you pass `--apply`. The other scripts call it for you (`--sync`). |

Each script prints its own manual with `-h` or `--help`. The build and trial scripts also list what a run would do, without doing it, with `--list`; `sync_to_hosts.sh` is a dry run until you pass `--apply`.

### Which machines, remembered once

`build_all_platforms.sh` writes the platforms and their machines to `.silica_build_hosts` in the repository root, one line per platform: `<emit target> <user@host|local> <repository path>`. The first run asks; later runs read it silently. `run_trials_all_platforms.sh` and `build_and_trial_all_platforms.sh` read the same file and never write it.

**`.silica_build_hosts` is gitignored and must never be committed**: it names your machines.

| Flag | Effect on the platform list |
| ---- | --------------------------- |
| *(none)* | The file, if it exists; otherwise every supported platform, asking for each machine |
| `--targets "<list>"` | Only those platforms, this run only; the file is read but not rewritten |
| `--set_targets "<list>"` | Ask for that list and write (or replace) the file |
| `--refresh_targets` | Ask again for the platforms already in the file, and rewrite it |
| `--remote <target>=<user@host>[:<path>]` | One machine on the command line; the path defaults to `~/silica` |
| `--local-only` | This machine and the raw targets; no remote machines |

`--set_targets` and `--refresh_targets` ask and write even with `--list`, so you can record your machines without building anything.

### ssh must be key-based

Every remote connection is public/private key ssh. The scripts run `ssh` in batch mode and never type a password. Set a key up first and check it:

```bash
ssh-keygen                       # if you have no key yet
ssh-copy-id user@host
ssh -o BatchMode=yes user@host true
```

If that last command succeeds without prompting, the scripts can use the machine.

## A change, end to end

This is the order to work in when you are fixing a defect or adding a feature to the compiler.

### The short version

```
# 1. make your code modifications in compiler/src/ (all four emitters for a codegen change)

# 2. build, and re-run your scratch repro against the new compiler
make -C compiler/src clean SILICA_TARGET_PROMPT=0
make -C compiler/src build  SILICA_TARGET_PROMPT=0

# 3. run the suite your trial lives in
cd trials/<suite> && make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET=host && cd ../..

# 4. add or rename the trial that proves the change

# 5. whole tree on this machine, goldens recorded, tree run again
bash programmer_tools/rebuild_refresh_verify.sh --targets apple_silicon_mac

# 6. the other platforms (asks which, if you leave --targets off)
bash programmer_tools/rebuild_refresh_verify.sh --targets "linux_aarch64 linux_x86_64"
bash programmer_tools/rebuild_refresh_verify.sh --targets ESP32-S3_raw    # board attached

# 7. the fixed point, last, on a green tree
bash programmer_tools/build_all_platforms.sh
```

Each step below says why it exists and what its output means.

### 1. Make your code modifications

Compiler sources are in [`compiler/src/`](https://github.com/yenrab/silica/tree/main/compiler/src/).
Two rules save the most time:

- **Reproduce before you edit.** Put a `silica.config` in a scratch directory with the one program
  that shows the problem and run the existing compiler on it. That takes milliseconds, where a build
  takes twenty minutes and a trial run takes hours.
- **A code-generation change belongs in every emitter it applies to**, `apple_silicon_mac`,
  `linux_aarch64`, `linux_x86_64` and `ESP32-S3_raw`. Apple Silicon leads and Linux is required to
  stay in lock-step, so a fix in one backend is not finished.

Do not use a builtin you have just added anywhere in the compiler's own sources. The compiler is
built by an existing compiler, which does not know it yet, and the build fails before your change can
prove anything. It becomes usable one generation later.

### 2. Build and prove the one program

```
make -C compiler/src clean SILICA_TARGET_PROMPT=0
make -C compiler/src build SILICA_TARGET_PROMPT=0
```

Then run your scratch repro again with the compiler that just came out. Clean first every time: the
up-to-date check does not know which target produced the existing output, so a build after one for a
different target silently mixes them.

### 3. Prove the suite

```
cd trials/<the suite your trial lives in>
make integrate SILICA_TARGET_PROMPT=0 TRIAL_TARGET=host
```

Read `.integrate_report`. Failures come in three kinds and they mean different things: `.sout differs`
is a real behaviour difference, `.sams differs` is a recorded assembly expectation that no longer
matches, and `has no .ascomp` is a golden that was never recorded.

### 4. Give the change a trial

A defect trial is named for the defect; once it passes, rename it for the behaviour it proves. A gap
you found and did not fix still gets a trial, so the next person meets it as a red line rather than a
surprise. If your change makes an existing trial's program illegal, rewrite the program and
regenerate its golden from real output; never widen a golden to make a difference disappear.

### 5. One platform, whole tree, with goldens

```
bash programmer_tools/rebuild_refresh_verify.sh --targets apple_silicon_mac
```

It builds, runs the whole tree, records the assembly goldens for trials whose output already matched,
and runs the tree again. **The second run is the one that matters**: everything still failing there is
a behaviour difference rather than a stale expectation.

Read the goldens it changed before you commit them. An assembly golden that moves is a change in
emitted code, and blessing one in bulk can bless a defect as easily as a fix.

### 6. The other platforms

```
bash programmer_tools/rebuild_refresh_verify.sh --targets "linux_aarch64 linux_x86_64"
```

Each machine gets the sources, builds there, runs its own tree and records its own goldens, because
Linux assembly goldens can only be made on Linux. With no `--targets` the script asks which platforms
to do and, for any machine it does not know, for a `user@host` over key-based ssh.

A board is different: it has no assembly goldens at all, so it is built here as a cross compiler and
only its programs' output is compared.

```
bash programmer_tools/rebuild_refresh_verify.sh --targets ESP32-S3_raw     # the board must be attached
```

### 7. The fixed point

```
bash programmer_tools/build_all_platforms.sh
```

Each hosted machine builds gen1, gen2 and gen3 and compares: a fixed point is reached when gen3 is
byte-identical to gen2, which is what proves the compiler reproduces itself. Raw paths have no fixed
point, because the board cannot host a compiler; their milestone is a green board release.

Do this last, on a tree whose trials are green. The chain takes hours per machine and will happily
reach a fixed point on a compiler that emits wrong code.

### Which steps for which change

| Your change | Steps |
| --- | --- |
| A fix in the lexer, parser, type checker or effect checker | 1-5 on this machine, then 6 for the other platforms, then 7. The front end is shared, so one fix serves every backend. |
| A code-generation fix | The same, but write it in all four emitters in step 1, and expect step 5 to change many goldens. |
| A change in one backend only | 1-5 on that platform. If it is a Linux backend, step 5 runs there rather than here. |
| A board-only change | 1, 2 with `TARGET=ESP32-S3_raw`, then step 6's board form. No goldens, no fixed point. |
| A trial, golden or harness change | 3 and 5. No fixed point is needed: the compiler did not change. |

## Build for every platform

```bash
bash programmer_tools/build_all_platforms.sh --list   # the plan, then stop
bash programmer_tools/build_all_platforms.sh          # do it
```

The first run asks for each OS-hosted machine other than this one, checks the ssh key, and remembers the answers in `.silica_build_hosts`. Every later run needs no arguments.

## Build for some platforms

```bash
bash programmer_tools/build_all_platforms.sh --targets "apple_silicon_mac linux_x86_64"
```

`--targets` applies to that run only. To make a shorter list the standing default, record it instead:

```bash
bash programmer_tools/build_all_platforms.sh --set_targets "apple_silicon_mac linux_x86_64"
```

The machine you start from always builds its own native compiler first, whatever the list says; the list chooses which *other* platforms are built, and which raw cross compilers are built here.

## Build for just this machine

```bash
bash programmer_tools/build_all_platforms.sh --local-only
```

`--local-only` builds this machine's native target and every raw target's cross compiler here, and contacts no other machine. To build the native compiler and nothing else, name it and nothing else:

```bash
bash programmer_tools/build_all_platforms.sh --targets linux_x86_64   # on a Linux x86-64 machine
```

The script prints the machine it is on and the target it will build natively (`host platform` and `native target`) before it starts, so you can check you named the right one.

## Build a hosted platform on its own machine

An OS-hosted platform is never cross-built. Name its machine and the script does the work over ssh:

```bash
bash programmer_tools/build_all_platforms.sh \
    --remote linux_aarch64=admin@pix.local \
    --remote linux_x86_64=lee@nix.local:~/silica
```

For each such machine the script syncs the sources (never binaries or build products), then builds, takes the compiler to its fixed point and publishes it **there**.

One exception exists to the never-cross-build rule: a hosted machine that has no compiler of its own yet needs a first one handed to it. When the script finds no `binaries/silica-compiler` on the far side, it builds that target's compiler here, emits the assembly here, copies it over, and links the binary there. After that the machine builds its own compilers.

## Build a cross compiler for a raw device

A raw target has no OS and cannot host a compiler, so its cross compiler is always built on the machine you are sitting at:

```bash
bash programmer_tools/build_all_platforms.sh --targets ESP32-S3_raw
```

This machine still builds its own native compiler first; the raw cross compiler is built after it. The result is published as `binaries/silica-compiler-ESP32-S3_raw` on this machine, and its numbered binary is `binaries/silica-<NNNNNN>-ESP32_S3_raw-<platform>` (the emit target's hyphens become underscores in the file name). To run a Silica program on the board, see [Run a Silica program on the board](#run-a-silica-program-on-the-board); what the board needs installed is in [Required software]({{ '/required-software/' | relative_url }}).

## Run a Silica program on the board

The sample programs for the ESP32-S3 board are under `compiler/src/emitter/ESP32-S3_raw/board/apps/` (`silica_00_return42` to `silica_22_device_buzzer`, plus the `asm_*` bring-up programs). One script builds an app in a temporary directory, loads it into the board's RAM and compares the output with the app's `expected.scout`:

```bash
B=compiler/src/emitter/ESP32-S3_raw/board
$B/tools/run_app.sh silica_04_print
$B/tools/run_app.sh --build-only silica_14_wbt_map     # compile and build the image; the board is not touched
$B/tools/run_app.sh --help                             # options, environment and exit statuses
```

It uses `binaries/silica-compiler-ESP32-S3_raw` unless `SILICA_COMPILER` names another cross compiler; a cross compiler older than the board runtime in the tree compiles but does not link, so build one from the current tree first (above). The Xtensa toolchain and the ESP-IDF Python environment come from [Required software]({{ '/required-software/' | relative_url }}); `BOARD_PYTHON`, `XTENSA_BIN`, `ESPTOOL`, `BOARD_PORT` and `BOARD_MAC` point the tools elsewhere. The script takes the board lock the board trial runs use, so it will not start while one is in progress. Most apps from `silica_16` on drive LEDs, the display or the buzzer; run those while watching the board. The README in that `board/` directory has the full list, what each app prints and how it ends.

## What a build does on each machine

Per machine the work is: build, gen1, gen2, the fixed-point check, and publish. `--no-fixpoint` stops after the build and skips the last four. One compiler build runs at a time per machine; the heaviest unit needs 6–8 GB of RAM.

| Flag | What it changes |
| ---- | --------------- |
| `--no-fixpoint` | Build only: no gen1, gen2, fixed-point check or publish |
| `--trials` | Run the trial tree after the build, on each machine that was built |
| `--jobs N` | Parallel jobs for the compiles |
| `--list` | Print the plan and stop |
| `--log-dir DIR` | Where the per-machine logs go (default: `../silica_builds/<timestamp>` beside the repository) |

The run ends with a `done:` / `failed:` line, names any platform it skipped for want of a machine, and says where the binaries and logs are.

## Run the trials on every platform

```bash
bash programmer_tools/run_trials_all_platforms.sh --list     # what it would run
bash programmer_tools/run_trials_all_platforms.sh            # every platform it knows
bash programmer_tools/run_trials_all_platforms.sh --targets linux_x86_64
bash programmer_tools/run_trials_all_platforms.sh --remote linux_aarch64=admin@pix.local
bash programmer_tools/run_trials_all_platforms.sh --sync --board
```

This script never builds a compiler. Each machine must already have its own native compiler at `<repo>/binaries/silica-compiler`; a raw target is driven from this machine with the cross compiler this machine built for it.

- `--targets "<list>"` takes emit-target names, or the short names `mac`, `pi`, `nix`, `esp32`, `all` and `hosted`, which are accepted anywhere a platform is.
- `--board` also runs a raw target's trials on an attached board; board runs are off by default.
- `--sync` copies trials, stdlib and project makefiles to each remote machine first — never binaries or build products.
- `--log-dir DIR` sets where logs and reports land (default: `../silica_trial_runs/<timestamp>`).
- `--mac-jobs`, `--pi-jobs` and `--nix-jobs` set the parallelism for those machines.

Remote machines run at the same time as each other. This machine runs its own trials and then the board, because both take `trials/.integrate.lock` — one trial run per machine. The script prints one summary table at the end and exits 0 only when every platform passed.

## Build and then run the trials, in one command

```bash
bash programmer_tools/build_and_trial_all_platforms.sh --list
bash programmer_tools/build_and_trial_all_platforms.sh
bash programmer_tools/build_and_trial_all_platforms.sh --targets "apple_silicon_mac linux_x86_64"
bash programmer_tools/build_and_trial_all_platforms.sh --local-only --board
```

It runs `build_all_platforms.sh` and then `run_trials_all_platforms.sh`, and both steps read the same `.silica_build_hosts`, so the platforms you name or record once are used twice. It takes the same platform flags as the build script (`--targets`, `--set_targets`, `--refresh_targets`, `--remote`, `--local-only`) plus `--board`, `--sync`, `--jobs`, `--no-fixpoint`, `--skip-build`, `--skip-trials`, `--list` and `--log-dir DIR` (build logs in `DIR/build`, trial logs and reports in `DIR/trials`; the default is `../silica_releases/<timestamp>`).

The trials do not run if the builds fail: a trial result only means something when it came from a compiler that built cleanly. Run the trials script on its own if you want them anyway. The exit status is 0 only when every build and every trial run passed.

## Use the compiler that is already here

Nothing above is needed to compile Silica programs. A checkout already carries built compilers in [`binaries/`](https://github.com/yenrab/silica/tree/main/binaries/), and applications and the trial tree reach them through stable links:

| Link | What it points at |
| ---- | ----------------- |
| `binaries/silica-compiler` | The newest compiler that runs on **this** machine and emits code for it. This is the one applications use. |
| `binaries/silica-compiler-<emit target>` | The newest compiler that runs here and emits code for another target, for example `binaries/silica-compiler-ESP32-S3_raw`. |
| `binaries/seed-compiler` | The compiler used to **build the compiler**. It advances only when a build reaches its fixed point. Nothing else uses it. |

A compiler binary is named `silica-<NNNNNN>-<platform>`, for example `silica-999970-macos-applesilicon`. `<platform>` is where the binary **runs**; a cross compiler carries the emit target as an extra token, `silica-<NNNNNN>-<emit_target>-<platform>`, and a compiler published for building the compiler carries `seed`, `silica-<NNNNNN>-seed-<platform>`. `<NNNNNN>` is a generation counter that counts **down**: the lowest number is the newest build. Each kind is numbered independently and their links never cross.

The compiler takes no `--version` flag, and the strings inside the binary do not identify it. A build is identified by its **file name**, so ask the link what it resolves to:

```bash
ls -l binaries/silica-compiler
readlink binaries/silica-compiler
```

Two scripts maintain those links:

- **[`binaries/install_compiler.bash`](https://github.com/yenrab/silica/blob/main/binaries/install_compiler.bash)** installs a freshly built binary into `binaries/` and repoints its stable link at it. It takes the kind, then the path to the binary: `install_compiler.bash selfhost <binary>` publishes a compiler for this host and moves `binaries/silica-compiler` to it; `install_compiler.bash target <emit-target> <binary>` publishes a cross compiler and moves `binaries/silica-compiler-<emit-target>`; `install_compiler.bash seed <binary>` publishes the compiler that builds the compiler and moves `binaries/seed-compiler`. It works out the next number itself (one below the lowest existing number for that kind). The build scripts call it for you.
- **[`binaries/update_silica_compiler_link.bash`](https://github.com/yenrab/silica/blob/main/binaries/update_silica_compiler_link.bash)** is the repair path for a missing or stale `silica-compiler` link. It scans `binaries/` for versioned binaries, detects your host platform, picks the newest one built for it, makes it executable and points `binaries/silica-compiler` at it. Run it with no arguments; if it cannot tell which platform you want, it lists the platforms it found and asks. It only ever selects a compiler that runs on this host and emits for it: never a cross compiler, and never a `-seed-` build, because compiling applications with the wrong one is exactly the mistake the separate links exist to prevent.

## Get a released compiler from GitHub

The repository is [github.com/yenrab/silica](https://github.com/yenrab/silica) and its releases are at [github.com/yenrab/silica/releases](https://github.com/yenrab/silica/releases). That page is where published compilers appear. If it is empty, no release has been published yet; build from source with the scripts above, or use the binaries already in the checkout.

A release asset is a compiler binary under the same naming rule as the ones in `binaries/`, so pick the one whose `<platform>` matches the machine you will run it on — `macos-applesilicon`, `linux-aarch64` or `linux-x86_64` — and, for a cross compiler, whose emit-target token matches the device you are building for. `binaries/update_silica_compiler_link.bash` will tell you what this machine's platform id is.

Download it into `binaries/`, make it executable, and point the link at it:

```bash
curl -L -o binaries/<asset-name> <the asset's download URL>
chmod +x binaries/<asset-name>
bash binaries/update_silica_compiler_link.bash
```

`update_silica_compiler_link.bash` picks the newest binary for your host platform, which is the downloaded one when its number is the lowest present. To point the link at a specific file instead:

```bash
ln -sfn <asset-name> binaries/silica-compiler
```

Use a relative name, not a path: the link lives in `binaries/` and must resolve inside it.

## The make targets behind the scripts

The scripts drive the Makefile in [compiler/src/](https://github.com/yenrab/silica/tree/main/compiler/src/). You need these directly only when working on the compiler itself.

| Command (run in `compiler/src/`) | What it does |
| -------------------------------- | ------------ |
| `make` / `make build` | Full build with `binaries/seed-compiler`: config → compile → objects → link → install. |
| `make gen1` | Build the compiler with `binaries/seed-compiler`, and keep the result as `binaries/silica-gen1`. |
| `make gen2` | Build it again with `binaries/silica-gen1`, and keep the result as `binaries/silica-gen2`. Every unit is recompiled: the compiler binary is a staleness input, so there is no incremental path between generations. |
| `make fixpoint` | Build gen3 with gen2 and pass only if gen3 is byte-identical to gen2 (see below). |
| `make trials-gen1` / `make trials-gen2` / `make trials-both` | Run the whole trial tree against a generation, keeping each report as `trials/.integrate_report.gen1` or `.gen2`. |
| `make assembly` / `make objects` / `make executables` | Compile only / assemble `.sams` → `.o` / link. |
| `make clean` | Remove generated artifacts (`.sams`, `.o`, configs, iface caches, the local executable). |
| `make all` | `clean`, then `build`. |
| `make help` | List targets, the active emit target, and allowable `TARGET` values. |
| `make TARGET=<name>` | Bake a specific backend from `emitter/<name>/` (writes `silica.target`). A backend other than the host's is published as `binaries/silica-compiler-<name>`, never as `binaries/silica-compiler`. |
| `make all-targets` | Clean and build once per allowable emit target. |
| `make EXECUTABLE=<name>` | Override the output binary name (default: `silica-compiler`). |
| `make build SILICA_COMPILER=<binary>` | Compile with any compiler binary (this is what `gen2` does with `silica-gen1`). |
| `INSTALL_SELFHOST=0` | On either generation: build and keep the `silica-genN` copy without touching the numbered install or the `silica-compiler` link. |

**Emit target.** With more than one backend under `emitter/`, an interactive `make` first asks which one to bake in:

```
Select the emit target (emitter/<name>/ to bake into silica-compiler):
  1) ESP32-S3_raw
  2) apple_silicon_mac  [default: host]
  3) linux_aarch64
Number or name [apple_silicon_mac]:
```

Answer with a number or a name; an empty answer takes the host default. The choice is written to `silica.target` and passed to the sub-makes, so you are asked once per build. `make TARGET=<name>` skips the question, `SILICA_TARGET_PROMPT=0` always takes the host default (this is what the scripts pass), and builds without a terminal (CI, `nohup`, pipes) take the host default silently. `make help` and `make clean` never ask. `TARGET` is a code-generation backend baked into the binary, not a runtime switch and not the `binaries/` host platform tag.

**The fixed point.** `make fixpoint` builds gen3 — `compiler/src` compiled by `binaries/silica-gen2` — and passes only if gen3 is byte-identical to gen2. Passing the trials shows gen2 compiles programs correctly; the fixed point shows the compiler reproduces itself with nothing inherited from the compiler that started the chain.

It must run right after `make gen2`: the `.sams` left in `compiler/src/` are then gen1's emission of the sources, and `make gen2` stamps them. The target refuses to run if that stamp is missing or any `.sams` was rewritten since, saves those `.sams` to `compiler/.src_fixpoint/gen1_sams/`, builds gen3 with gen2, and prints how many units gen2 emits differently from gen1 (with the first differing lines, `o<N>` node counters normalised) and both binary sizes. gen3 is linked at the same path as gen2, `compiler/src/silica-compiler`, because Apple's linker derives the binary's UUID and signature identifier from the output path; it is not installed and is kept as `silica-compiler-gen3`. Running it again needs a fresh `make gen2`.

## Prerequisites

The complete list, with versions, install commands and the ESP32-S3 board tools, is on its own page: [Required software]({{ '/required-software/' | relative_url }}).

| Requirement | Role |
| ----------- | ---- |
| A Silica compiler for this host | `binaries/silica-compiler`. Present in the checkout; `binaries/update_silica_compiler_link.bash` repairs the link for your host platform. Every build starts from one. |
| GNU Make | Drives every build and the trial tree. |
| Clang | Assembles `.sams` → `.o` and links. On Apple Silicon with Homebrew LLVM, the Makefiles prefer `/opt/homebrew/opt/llvm/bin/clang` when present. |
| `rsync` and key-based `ssh` | Only for building or running trials on another machine. |

## Runtime (Track 2): no single documented build yet

[Track 2](https://github.com/yenrab/silica/blob/main/ROADMAP.md) is foreign interoperability and, later, brokered IPC. Exact build and link steps for that path are still to be defined. Until then, the self-hosted compiler build above is the supported path.

## The trial tree

CI trials live under [trials/](https://github.com/yenrab/silica/tree/main/trials/). Each suite directory (for example `atoms_addition`, `case_addition`, `error_enforcement_addition`, `ordered_data_structures`) holds Silica sources and golden files: `.ascomp` (expected assembly), `.scout` (expected stdout followed by the exit code), and `.golden_fail` (expected compiler diagnostics for programs that must not compile). The [trials Makefile](https://github.com/yenrab/silica/blob/main/trials/Makefile) compiles every trial with the chosen compiler, compares the assembly to `.ascomp`, assembles and links, runs the binary, and compares its output to `.scout` (or the diagnostics to `.golden_fail`). Suites run in parallel; a counter line at the bottom of the terminal shows passes and failures as they happen.

## Run the tree or one suite with any compiler

```bash
cd trials
make integrate                                    # default: binaries/silica-compiler (the newest build for this host)
make integrate SILICA_COMPILER=/path/to/compiler  # any binary
make -C case_addition integrate SILICA_COMPILER=/path/to/compiler   # one suite
```

`make integrate` is the Makefile default, so plain `make` in `trials/` does the same. A few suites are not part of the tree run and must be run directly: any suite with an `INTEGRATE_PENDING` marker is skipped (see its README).

## Run the trials on an ESP32-S3 board

The same trials can run on an ESP32-S3 board over USB: compiled by `binaries/silica-compiler-ESP32-S3_raw`, loaded into the board's RAM one at a time, and compared with the same `.scout` goldens. An interactive `make integrate` asks where to run (Enter = this machine); set `TRIAL_TARGET` to skip the question:

```bash
cd trials
make integrate TRIAL_TARGET=ESP32-S3_raw          # the whole tree on the board (takes hours)
make integrate TRIAL_TARGET=both                  # this machine, then the board
make -C case_addition integrate TRIAL_TARGET=ESP32-S3_raw   # one suite on the board
```

Only one trial run, host or board, can be in progress at a time; a second one stops and names the run in progress. The board run writes its report to `trials/.integrate_report.ESP32-S3_raw` and leaves the host's results untouched. How it works, what it skips and its settings: [trials/targets/README.md](https://github.com/yenrab/silica/blob/main/trials/targets/README.md). What it needs installed: [Required software]({{ '/required-software/' | relative_url }}).

## Reading a report

`trials/.integrate_report` starts with the totals and then lists each failing trial with its reason (`.sams differs from .ascomp`, `.sout differs from .scout`, `.cur_fail differs from .golden_fail`, `compilation failed`, `missing executable`, and so on).

- **Trust the totals.** If the `fail:` count is higher than the number of listed lines, a suite failed as a whole (for example its batch compile aborted on one trial) and has no per-trial lines; open that suite's `.integrate_log` for the reason.
- **`missing executable (assemble/link failed earlier)`** on hundreds of trials in one suite usually means a single `.sams` in that suite failed to assemble; the `assemble failed` line names it.
- **Assembly drift** (`.sams differs from .ascomp`) with matching runtime output is expected after an emitter change; the report prints the first differing lines. Goldens are never regenerated automatically: copy a trial's `.sams` over its `.ascomp` only after confirming the runtime result, and use `make record-golden SUB_TRIALS=<leaf>` in `ordered_data_structures/` for those leaves.
- `trials/count_trial_files.sh` prints how many golden files (`.ascomp`, `.scout`, `.golden_fail`) the tree holds.

Other useful targets in `trials/`:

- `make clean` — remove generated executables, `.sams`, `.o`, `.sout`, and per-suite counters (keeps the goldens).
- `make help` — list targets and suites.
- `make integrate-ffi` — the success-path FFI application trials only.

The harness needs the same toolchain as the compiler build on whichever machine it runs (see [Required software]({{ '/required-software/' | relative_url }})). Some suites have their own READMEs.
