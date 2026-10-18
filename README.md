![Silica](./silica_icon_small.png)

# Silica

Silica is a memory-safe, functional systems language. The compiler rejects unsafe or accidental behavior at compile time, with errors you can act on. Effects are explicit, actors pass messages, and memory is region-based with no garbage collector.

Silica is designed for bare metal systems development, but also supports applications hosted by operating systems. The toolchain builds and reproduces itself today on macOS (Apple Silicon), Linux on AArch64 and Linux on x86-64, and cross-compiles for the OS-free ESP32-S3.

[Why Silica](https://yenrab.github.io/silica/) — language goals and how to get involved.

```silica
module main;

fn add(a: int64, b: int64) -> int64 {
    a + b
}

fn main() -> atom {
    case add(20, 1) * 2 of {
        42: int64 -> :ok;
        _: int64 -> :error
    }
}
```

- [Build the compiler](#building-the-compiler) for every platform, some of them, or just this machine, and [run the trials](#running-the-continuous-integration-trials)
- [Language specification](compiler/design_documents/silica-specification.md)
- [Tutorials](compiler/tutorials_and_howtos/)
- [Roadmap](ROADMAP.md)
- [Contributing](CONTRIBUTING.md)

---

![](./silica_icon_emoji.png)**Motto: Secure by default at compile time — fail soft, never fail silent**

---



## Language and runtime

- Effects live in the type system. Memory is organized with regions and per-actor stacks: no shared heap, no GC. See the [language specification](compiler/design_documents/silica-specification.md), [actor stack architecture](compiler/design_documents/silica-specification.md#spec-actor-stack-architecture), and [region handles](compiler/design_documents/silica-specification.md#spec-region-handles-actor-spawn).
- Dead bindings, duplicate work, redundant arithmetic, and similar “the optimizer will fix it” patterns are compile-time errors. See [additional compiler rules](compiler/design_documents/silica-specification-additional.md).
- FFI goes through Fifi, the compiler’s outbound foreign-function layer. Think of a cute poodle that bites: non-Silica code looks approachable and lives outside Silica’s guarantees. Wrappers and anything that depends on them must be named `dangerous_*` all the way to the app root. See the [FFI wrapper specification](compiler/design_documents/silica_ffi_wrapper_specification.md), the [dangerous FFI security model](compiler/design_documents/dangerous_ffi_security_model.md), and [designing apps with foreign functions](compiler/tutorials_and_howtos/designing_apps_with_foreign_functions.md).
- The runtime is lightweight actors, message passing, and let-it-crash isolation (BEAM-like, native), with hardware help such as MTE on AArch64. See [crash containment](compiler/design_documents/runtime_failure_reporting.md). Brokered IPC for untrusted C is proposed as an alternative to in-process FFI; that path would not need `dangerous_*` names. See [brokered IPC](compiler/design_documents/brokered_ipc_isolation_architecture.md).
- Types and syntax stay explicit. There are no generics; polymorphism is traits plus concrete types. Language-level crypto labels and richer proof tooling are proposed: [crypto proposal](compiler/design_documents/crypto-proposal-introduction.md), [formal verification](compiler/design_documents/silica-formal-verification-specification.md).

Related notes: [actor capabilities](compiler/design_documents/silica_actor_capabilities_specification.md) (draft), [memory effects on AArch64 / OS-free targets](compiler/design_documents/memory-effects-aarch64-implementation-plan.md).

## Contributing and roadmap

Working on a self-hosted toolchain plus the runtime around it, in the open, with the spec and the errors meant to stay aligned. How to open issues and PRs is in [CONTRIBUTING.md](CONTRIBUTING.md). [Code organization](compiler/design_documents/silica-compiler-code-organization.md) is a map of the tree.

Development is organised by emitter path — Apple Silicon leads, Linux AArch64 is in lock-step, ESP32-S3 follows at its own pace — and delivered in chunks between milestones: fixed points on the hosted paths, board releases on the raw ones, which cannot host a compiler. See the [roadmap](ROADMAP.md). Compiler-building tools (including JSON-LD agent graphs) live under [compiler-building-tools/](compiler/compiler-building-tools/).

## Documentation

Design docs are working documents and change with the implementation. Start here:

- [Required software](docs/required-software.md): what to install to build the compiler and run the trials, on a host machine and on an ESP32-S3 board

- [Language specification](compiler/design_documents/silica-specification.md) and [additional compiler rules](compiler/design_documents/silica-specification-additional.md)
- Fifi: [§26.3](compiler/design_documents/silica-specification.md#spec-fifi), [FFI wrapper specification](compiler/design_documents/silica_ffi_wrapper_specification.md), [dangerous FFI security model](compiler/design_documents/dangerous_ffi_security_model.md), [macOS guarded FFI crash handling](compiler/design_documents/macos_crash_handling_for_silica.md)
- [Actor capabilities](compiler/design_documents/silica_actor_capabilities_specification.md), [memory effects (AArch64 / OS-free)](compiler/design_documents/memory-effects-aarch64-implementation-plan.md)
- Full index: [design_documents/](compiler/design_documents/)
- Hosted vs OS-free: on a mainstream OS, kernel policy limits what you can assume about memory spaces and core pinning. Short overview: [execution environments](compiler/design_documents/execution-environments-hosted-vs-bare-metal.md).

Tutorials (actors, regions, lists, blocks, and related topics) are in [tutorials_and_howtos/](compiler/tutorials_and_howtos/). Useful starting points:

- Foreign functions: [designing apps with foreign functions](compiler/tutorials_and_howtos/designing_apps_with_foreign_functions.md), then [FFI wrappers and Makefiles](compiler/tutorials_and_howtos/ffi_wrappers_and_makefiles.md)
- App builds: [building apps with project Makefiles](compiler/tutorials_and_howtos/building_apps_with_project_makefiles.md) (drop-in files in `[project_makefiles/](project_makefiles/)`)
- Large apps: [compiling with less RAM](compiler/tutorials_and_howtos/compiling_with_less_ram.md)



## Building the compiler

**You probably do not need to build the compiler.** Building is for people who change the compiler's own code in [compiler/src/](compiler/src/), or who port it to a new platform. To write Silica programs, use the compiler already in [binaries/](binaries/) or download a released one; see [Use the compiler that is already here](https://yenrab.github.io/silica/build-and-test/#use-the-compiler-that-is-already-here) and [Get a released compiler from GitHub](https://yenrab.github.io/silica/build-and-test/#get-a-released-compiler-from-github).

These steps build the self-hosted toolchain ([roadmap](ROADMAP.md) Track 1). The same instructions, with more detail, are on the project site: [Build and test the compiler](https://yenrab.github.io/silica/build-and-test/).

The compiler is written in Silica and builds itself. There is no bootstrap compiler to build and no separate seed source tree: a compiler binary already in `binaries/` (reached through `binaries/seed-compiler`) compiles the sources in [compiler/src/](compiler/src/), and the compiler that comes out compiles them again until the two agree byte for byte — the **fixed point**. Nothing in the build path is written in Rust and nothing needs `cargo`; the retired Rust bootstrap lives only in the repository's history.

### Platforms

A platform is an **emit target**: the directory under [compiler/src/emitter/](compiler/src/emitter/) whose backend a compiler bakes in. The table of record is [project_makefiles/platform/platforms.mk](project_makefiles/platform/platforms.mk).

| Emit target | Runs on | How it is built |
| ----------- | ------- | --------------- |
| `apple_silicon_mac` | macOS on Apple Silicon (`macos-applesilicon`) | OS-hosted: built natively on an Apple Silicon Mac |
| `linux_aarch64` | Linux on AArch64 (`linux-aarch64`) | OS-hosted: built natively on a Linux AArch64 machine |
| `linux_x86_64` | Linux on x86-64 (`linux-x86_64`) | OS-hosted: built natively on a Linux x86-64 machine |
| `ESP32-S3_raw` | nothing — the ESP32-S3 has no OS | Raw: its cross compiler is built on whichever machine you start from |

An OS-hosted platform can run a compiler, so it builds its own and reaches its own fixed point on its own machine. A raw platform cannot run a compiler at all, so the compiler that emits its code is built elsewhere and published as `binaries/silica-compiler-<emit target>`.

### Changing the compiler

The order to work in, from your first edit to a new fixed point, is in
[A change, end to end](https://yenrab.github.io/silica/build-and-test/#a-change-end-to-end).

### The scripts

> **All of them are documented in [programmer_tools/README.md](programmer_tools/README.md)**, including the machine file they share, the key-based ssh they need, and the tools not listed here: the golden refresher and the rebuild-and-verify run.


| Script | What it does |
| ------ | ------------ |
| [`programmer_tools/build_all_platforms.sh`](programmer_tools/build_all_platforms.sh) | Builds Silica for every platform you name, from whatever machine you start on. |
| [`programmer_tools/run_trials_all_platforms.sh`](programmer_tools/run_trials_all_platforms.sh) | Runs the full trial tree on each platform with that platform's own compiler. It never builds a compiler. |
| [`programmer_tools/build_and_trial_all_platforms.sh`](programmer_tools/build_and_trial_all_platforms.sh) | Both, in one command: build every indicated platform, then run the full trial tree on each one. |

Each prints its own manual with `-h`, and shows what a run would do — without doing it — with `--list`.

```bash
bash programmer_tools/build_all_platforms.sh --list                    # the plan, then stop
bash programmer_tools/build_all_platforms.sh                           # every platform
bash programmer_tools/build_all_platforms.sh --targets "apple_silicon_mac linux_x86_64"
bash programmer_tools/build_all_platforms.sh --local-only              # this machine, plus raw cross compilers
bash programmer_tools/build_all_platforms.sh --targets ESP32-S3_raw    # one raw device's cross compiler
bash programmer_tools/build_all_platforms.sh \
    --remote linux_aarch64=admin@pix.local \
    --remote linux_x86_64=lee@nix.local:~/silica                       # hosted platforms, each on its own machine
```

The machine you start from always builds its own native compiler first, whatever the list says; the list chooses which *other* platforms are built, and which raw cross compilers are built here. An OS-hosted platform is never cross-built: the script builds it natively on its own machine, over ssh, and takes it to its fixed point there. The one exception is a hosted machine with no compiler of its own yet — the script builds that target's compiler here, emits the assembly here, copies it over, and links the first binary there.

**Which machines, remembered once.** `build_all_platforms.sh` writes the platforms and their machines to `.silica_build_hosts` in the repository root, one line per platform: `<emit target> <user@host|local> <repository path>`. The first run asks; later runs read it silently, and the other two scripts read the same file. **It is gitignored and must never be committed**: it names your machines. `--targets "<list>"` overrides it for one run, `--set_targets "<list>"` replaces it, and `--refresh_targets` asks again for the platforms already in it.

**ssh must be key-based.** The scripts run `ssh` in batch mode and never type a password. Set a key up with `ssh-keygen` and `ssh-copy-id user@host`, and check it with `ssh -o BatchMode=yes user@host true`.

**Per machine** the work is: build, gen1, gen2, the fixed-point check, and publish. `--no-fixpoint` stops after the build. `--trials` also runs the trial tree, `--jobs N` sets the parallelism, and `--log-dir DIR` sets where the logs go (default `../silica_builds/<timestamp>` beside the repository). One compiler build runs at a time per machine; the heaviest unit needs 6–8 GB of RAM.

The Makefile targets the scripts drive (`make gen1`, `make gen2`, `make fixpoint`, `make TARGET=…` and the rest, in `compiler/src/`) are documented on the site page: [Build and test the compiler](https://yenrab.github.io/silica/build-and-test/).

### Use the compiler that is already here

Nothing above is needed to compile Silica programs. A checkout already carries built compilers in [`binaries/`](binaries/), reached through stable links: `binaries/silica-compiler` is the newest compiler that runs on **this** machine and emits code for it — the one applications use — `binaries/silica-compiler-<emit target>` is the newest compiler that runs here and emits code for another target, for example `binaries/silica-compiler-ESP32-S3_raw`, and `binaries/seed-compiler` is the one used to build the compiler itself. The links never cross.

A compiler binary is named `silica-<NNNNNN>-<platform>` (a cross compiler carries the emit target as an extra token, `silica-<NNNNNN>-<emit_target>-<platform>`). `<platform>` is where the binary **runs**. `<NNNNNN>` is a generation counter that counts **down**: the lowest number is the newest build. Each kind is numbered independently and their links never cross.

The compiler takes no `--version` flag, and the strings inside the binary do not identify it. A build is identified by its file name, so ask the link what it resolves to: `ls -l binaries/silica-compiler`.

- [`binaries/install_compiler.bash`](binaries/install_compiler.bash) installs a freshly built binary into `binaries/` and repoints its stable link at it: `install_compiler.bash selfhost <binary>` for this host, `install_compiler.bash target <emit-target> <binary>` for a cross compiler, `install_compiler.bash seed <binary>` for the compiler that builds the compiler. It works out the next number itself. The build scripts call it for you.
- [`binaries/update_silica_compiler_link.bash`](binaries/update_silica_compiler_link.bash) is the repair path for a missing or stale link. Run it with no arguments: it scans `binaries/`, detects your host platform, picks the newest binary built for it, makes it executable and points `binaries/silica-compiler` at it. If it cannot tell which platform you want it lists what it found and asks. It only ever selects a compiler that runs on this host and emits for it: never a cross compiler and never a `-seed-` build.

### Get a released compiler from GitHub

Published compilers appear on the repository's releases page: [github.com/yenrab/silica/releases](https://github.com/yenrab/silica/releases). If that page is empty, no release has been published yet; build from source with the scripts above, or use the binaries already in the checkout.

A release asset is a compiler binary under the same naming rule as the ones in `binaries/`, so pick the one whose `<platform>` matches the machine you will run it on — `macos-applesilicon`, `linux-aarch64` or `linux-x86_64` — and, for a cross compiler, whose emit-target token matches the device you are building for. Download it into `binaries/`, make it executable, and point the link at it:

```bash
curl -L -o binaries/<asset-name> <the asset's download URL>
chmod +x binaries/<asset-name>
bash binaries/update_silica_compiler_link.bash      # picks the newest for this host platform
ln -sfn <asset-name> binaries/silica-compiler       # or point the link at that exact file
```

Use a relative name in the `ln`, not a path: the link lives in `binaries/` and must resolve inside it.

### Runtime (Track 2): no single documented build yet

[Track 2](ROADMAP.md) is foreign interoperability and, later, brokered IPC. Exact build and link steps for that path are still to be defined. Until then, the self-hosted compiler build above is the supported path.

## Running the Continuous Integration trials

CI trials live under [trials/](trials/). Each suite directory (for example `atoms_addition`, `case_addition`, `error_enforcement_addition`, `ordered_data_structures`) holds Silica sources and golden files: `.ascomp` (expected assembly), `.scout` (expected stdout followed by the exit code), and `.golden_fail` (expected compiler diagnostics for programs that must not compile). The [trials Makefile](trials/Makefile) compiles every trial with the chosen compiler, compares the assembly to `.ascomp`, assembles and links, runs the binary, and compares its output to `.scout` (or the diagnostics to `.golden_fail`). Suites run in parallel; a counter line at the bottom of the terminal shows passes and failures as they happen.

### Run the tree on every platform

```bash
bash programmer_tools/run_trials_all_platforms.sh --list      # what it would run
bash programmer_tools/run_trials_all_platforms.sh             # every platform it knows
bash programmer_tools/run_trials_all_platforms.sh --targets linux_x86_64
bash programmer_tools/run_trials_all_platforms.sh --sync --board
```

This script never builds a compiler: each machine must already have its own native compiler at `<repo>/binaries/silica-compiler`, and a raw target is driven from this machine with the cross compiler this machine built for it. It reads the same `.silica_build_hosts`. `--targets` also takes the short names `mac`, `pi`, `nix`, `esp32`, `all` and `hosted`; `--board` adds an attached board's run (off by default); `--sync` copies trials, stdlib and project makefiles to each remote machine first. Remote machines run at the same time; this machine runs its own trials and then the board, because both take `trials/.integrate.lock`. One summary table is printed at the end, and the exit status is 0 only when every platform passed.

To build and then trial in one command, use [`programmer_tools/build_and_trial_all_platforms.sh`](programmer_tools/build_and_trial_all_platforms.sh); the trials do not run if the builds fail.

### Run the tree or one suite with any compiler

```bash
cd trials
make integrate                                    # default: binaries/silica-compiler (the newest build for this host)
make integrate SILICA_COMPILER=/path/to/compiler  # any binary
make -C case_addition integrate SILICA_COMPILER=/path/to/compiler   # one suite
```

`make integrate` is the Makefile default, so plain `make` in `trials/` does the same. A few suites are not part of the tree run and must be run directly: any suite with an `INTEGRATE_PENDING` marker is skipped (see its README).

### Run the trials on an ESP32-S3 board

The same trials can run on an ESP32-S3 board over USB: compiled by `binaries/silica-compiler-ESP32-S3_raw`, loaded into the board's RAM one at a time, and compared with the same `.scout` goldens. An interactive `make integrate` asks where to run (Enter = this machine); set `TRIAL_TARGET` to skip the question:

```bash
cd trials
make integrate TRIAL_TARGET=ESP32-S3_raw          # the whole tree on the board (takes hours)
make integrate TRIAL_TARGET=both                  # this machine, then the board
make -C case_addition integrate TRIAL_TARGET=ESP32-S3_raw   # one suite on the board
```

Only one trial run, host or board, can be in progress at a time; a second one stops and names the run in progress. The board run writes its report to `trials/.integrate_report.ESP32-S3_raw` and leaves the host's results untouched. How it works, what it skips and its settings: [trials/targets/README.md](trials/targets/README.md). What it needs installed: [Required software](docs/required-software.md).

### Reading a report

`trials/.integrate_report` starts with the totals and then lists each failing trial with its reason (`.sams differs from .ascomp`, `.sout differs from .scout`, `.cur_fail differs from .golden_fail`, `compilation failed`, `missing executable`, and so on).

- **Trust the totals.** If the `fail:` count is higher than the number of listed lines, a suite failed as a whole (for example its batch compile aborted on one trial) and has no per-trial lines; open that suite's `.integrate_log` for the reason.
- **`missing executable (assemble/link failed earlier)`** on hundreds of trials in one suite usually means a single `.sams` in that suite failed to assemble; the `assemble failed` line names it.
- **Assembly drift** (`.sams differs from .ascomp`) with matching runtime output is expected after an emitter change; the report prints the first differing lines. Goldens are never regenerated automatically: copy a trial's `.sams` over its `.ascomp` only after confirming the runtime result, and use `make record-golden SUB_TRIALS=<leaf>` in `ordered_data_structures/` for those leaves.
- `trials/count_trial_files.sh` prints how many golden files (`.ascomp`, `.scout`, `.golden_fail`) the tree holds.

Other useful targets in `trials/`:

- `make clean` — remove generated executables, `.sams`, `.o`, `.sout`, and per-suite counters (keeps the goldens).
- `make help` — list targets and suites.
- `make integrate-ffi` — the success-path FFI application trials only.

The harness needs the same toolchain as the compiler build on whichever machine it runs (see [Required software](docs/required-software.md)). Some suites have their own READMEs.

## License

This project is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for copyright attribution.