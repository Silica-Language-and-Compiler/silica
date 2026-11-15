# FFI trial harness

Phase 0 provides linkable C wrapper fixtures for outbound FFI compiler work.

## Layout

```text
ffi_addition/
  fixtures/
    dangerous_exposure_source/
      legacy/ … text/ … net/ …          # shared .meta / .h sources
    src/                                # C sources (not compiled by Silica)
    build/<platform>/                   # built here, per platform, never synced (see below)
      obj/*.o
      dangerous_exposure_source/lib/*.a   # + links to the shared sources
  app_sidecar_legacy_math_add/          # runnable app: sidecar metadata + legacy math add
  app_cast_worker_legacy_add/           # runnable app: spawn_dangerous worker + external_danger behavior
  app_cast_worker_registered_legacy_add/  # runnable app: spawn_dangerous_registered + cast/worker e2e
  app_ffi_result_cast_add/              # runnable app: FFI result cast with tainted int64
  app_foreign_abi_valid/                # runnable apps: legacy Silica-side ABI smoke tests
  app_foreign_abi_types_e2e/            # runtime link + guarded worker for libsilica_abi_types.a
  app_foreign_three_int64_result_e2e/   # three int64 arguments and a struct result: eight argument words on the ESP32-S3
  abi_addition/                         # compile-only ABI success trials (spec §5–§9 data shapes)
  app_e2e_scalar_string_echo/           # runnable apps: scalar add + string echo e2e
  module_addition/                      # compile-only module naming trial (phase 3)
  common_app.mk                         # shared integrate recipe for app_* trials
  Makefile
  README.md
```

Expected-failure FFI cases live under `trials/error_enforcement_addition/ffi_addition/` (`error_app_*` directories).

## App trials

Each `app_*` directory is a self-contained runnable program (or small set of programs) with:

- `Makefile` `integrate` target — compile, verify `silica.link`, link, run, diff `.sout` vs `.scout`
- `silica.link.scout` when the app uses foreign bindings
- `.scout` output goldens and optional `.wait_for_exit` markers

| Directory | What it exercises |
| --------- | ----------------- |
| `app_sidecar_legacy_math_add` | Sidecar `wrapper_meta` loads; legacy math foreign call via FFI worker |
| `app_cast_worker_legacy_add` | `spawn_dangerous` + `external_danger` worker behavior; `dangerous_legacy_stub@add` |
| `app_cast_worker_registered_legacy_add` | `spawn_dangerous_registered(:dangerous_legacy_worker)` + cast/worker e2e (same 4/done golden as unregistered) |
| `app_ffi_result_cast_add` | Tainted int64 delivered by FFI result cast inside worker |
| `app_foreign_abi_valid` | Scalar and net-port ABI declarations compile and run |
| `app_foreign_abi_types_e2e` | Runtime link + cast/worker for `libsilica_abi_types.a` (int64/boolean/record/tagged_result decls; guarded `:foreign_fault` golden) |
| `app_foreign_three_int64_result_e2e` | Three `int64` arguments and a tagged result: on the ESP32-S3 a hidden result pointer and three aligned pairs, eight argument words, the last two on the C stack (`10203` / `done` golden; left out on the STM32, whose emitter takes six) |
| `abi_addition/` | Compile-success matrix for documented C ABI data shapes (§5.4–§9): integers, floats, boolean, inline records, tagged results, string ptr+len and two-layer adapters |
| `app_e2e_scalar_string_echo` | Full cast/worker e2e: int64 add and string echo through C wrappers |
| `app_legacy_math_add_guarded` | Phase 11: single `silica_legacy_math_add_int64` call through guarded runtime boundary |
| `app_legacy_math_add_twice` | Phase 11: two sequential guarded legacy-math calls (reentrant depth reset) |
| `app_process_fatal_paths` | Spec §15.4.5.5 paths a program cannot reach from Silica source, driven by a C probe linked after the runtime: a fault before `main` (handlers installed by the startup code), a fault inside the fault handler (last-resort report), and a guarded foreign fault with no current actor; all `[silica] fault at` + 70 |

## Phase 0

```bash
make -C compiler/trials/ffi_addition phase-0
```

## Phase 9: `silica.link` emission, archive validation, and Makefile link integration

After a successful compile of all units in `silica.config`, `silica-compiler`:

1. Verifies each `link_library` archive exists under `dangerous_exposure_source/lib/` (step 3 — compile-time `E4034` if missing).
2. Writes `silica.link` listing deduped `link_library` / `archive` pairs and required `foreign c_wrapper` symbols.

App trials diff `silica.link` against `silica.link.scout`.

At Stage 3 link, `trials/silica_link.sh` reads `archive:` lines from `silica.link` and passes those static archives directly to `rust-lld` / `clang`. App trial Makefiles no longer set manual `-L` / `-l` flags.

```bash
make -C compiler/trials/ffi_addition phase-9
make -C compiler/trials/ffi_addition phase-11
make -C compiler/trials integrate-ffi
```

Phase 11 adds `_silica_rt_ffi_guarded_enter` / `_silica_rt_ffi_guarded_exit` around every emitted `foreign c_wrapper` call. Per-thread guarded-call metadata lives in `__silica_runtime.sams` (see `ffi_guarded_runtime_asm.silica`).

Compile/link **failure** goldens for Phase 9 live under `error_enforcement_addition/ffi_addition/` and run via that harness's `integrate` target (included in top-level `make integrate` through `error_enforcement_addition`):

| Failure | Golden |
| ------- | ------ |
| Missing prebuilt archive at compile time | `error_app_sidecar_metadata/dangerous_sidecar_missing_archive` |
| Missing foreign symbol at link time | `error_app_sidecar_metadata/dangerous_missing_foreign_symbol_at_link` (paired goldens: `.golden_link_fail.clang` vs `.golden_link_fail.rust-lld`, chosen like other trials when `rust-lld` exists) |

## Running the full success-path suite

```bash
make -C compiler/trials/ffi_addition all
```

`all` runs `phase-9` (all app integrates with `.scout` / `silica.link.scout` goldens). App `integrate` targets depend on `fixtures`, which compiles C wrapper sources into `fixtures/build/<platform>/dangerous_exposure_source/lib/*.a` via `fixtures.mk`. `<platform>` is the host's emit target (`apple_silicon_mac`, `linux_aarch64`, `linux_x86_64`), named as `ASCOMP_EXT` names it, so a tree synced between machines never reuses another platform's archives: each machine builds its own on first use, with no manual `make fixtures`. Each app's `dangerous_exposure_source` link (made with `ln -sfn`) points at the platform's view of that directory, so the `silica.link` goldens do not change. Paths are defined once, in `fixtures_paths.mk`.

`make fixtures` or `make -C compiler/trials/ffi_addition fixtures` builds the wrapper archives alone.

## Running all app trials

```bash
make -C compiler/trials/ffi_addition integrate
```

## Rebuilding fixtures

```bash
make -C compiler/trials/ffi_addition clean
make -C compiler/trials/ffi_addition fixtures
```

Archives are built for **macOS AArch64** (`-arch arm64`) using `clang` and `ar`.
