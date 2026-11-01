# Building an application with the project Makefiles

This how-to shows how to build a **general Silica application** with `silica-compiler` using the drop-in Makefiles under [`project_makefiles/`](../../project_makefiles/) at the repository root. Those files are a sanitized form of the self-hosted compiler’s config-driven build: topological `silica.config`, process-per-unit reclaim, assemble `.sams`, then link.

You do **not** need the compiler sources, the emitters, or any of the platform build scripts for an ordinary app. You need `silica-compiler` on your machine, **GNU Make**, and **Clang**.

For why leaf-to-root batches and exit `75` matter for RAM, see [compiling_with_less_ram.md](./compiling_with_less_ram.md). For FFI archives and `dangerous_*` layout, see [ffi_wrappers_and_makefiles.md](./ffi_wrappers_and_makefiles.md).

---

## What you copy

From [`project_makefiles/`](../../project_makefiles/), put these files in your **application source root** (the directory that will contain `main.silica` and `silica.config`):

| File | Role |
| --- | --- |
| `Makefile` | Root build: config → compile → assemble → link |
| `silica_compiler.mk` | Locates `silica-compiler` and defines the reclaim loop |
| `topo_silica_config.sh` | Discovers `.silica` units and topo-sorts them by `use` |
| `silica_link.sh` | Optional: reads `silica.link` archive lines for the linker (FFI) |
| `subdir_stub.mk` | Shared help/clean stub for subdirectory Makefiles |

Optionally, for each subdirectory that holds `.silica` modules:

| File | Role |
| --- | --- |
| `Makefile.subdir` | Copy into the subdirectory **as** `Makefile` (rename on copy) |

The subdirectory Makefile auto-detects its component name from the directory name and only provides local `help` / `clean`. The **parent** root Makefile still owns compile, assemble, and link.

Keep the scripts executable after copy:

```bash
chmod +x topo_silica_config.sh silica_link.sh
```

---

## Prerequisites

| Requirement | Role |
| --- | --- |
| **`silica-compiler`** | On `PATH`, or pass `SILICA_COMPILER=/path/to/silica-compiler` on every `make` |
| **GNU Make** | Drives the project `Makefile` |
| **Clang** | Assembles `.sams` → `.o` and links the executable |

On Apple Silicon with Homebrew LLVM, the root Makefile prefers `/opt/homebrew/opt/llvm/bin/clang` when that binary exists.

---

## Minimal project layout

A small multi-module app might look like this after you drop in the Makefiles:

```text
my_app/
  Makefile                 ← from project_makefiles/Makefile
  silica_compiler.mk
  topo_silica_config.sh
  silica_link.sh
  subdir_stub.mk
  main.silica              ← application entry (linked last)
  helpers.silica
  util/
    Makefile               ← from project_makefiles/Makefile.subdir
    strings.silica
```

Rules of thumb:

1. **`main.silica` at the project root** — the link step expects `main.o`. The topo script forces `main.silica` last in `silica.config` when that file exists.
2. **One module per `.silica` file** — module basename must be unique across the tree (no two `foo.silica` in different directories).
3. **Acyclic `use`** — dependencies before dependents; cycles fail the topo sort.
4. **Subdirectory Makefiles are optional** — they do not compile anything themselves; they point you back to `make -C .. build`.

---

## Install the files

From the Silica repository (adjust paths if your app lives elsewhere):

```bash
APP=~/src/my_app
mkdir -p "$APP/util"

cp project_makefiles/Makefile \
   project_makefiles/silica_compiler.mk \
   project_makefiles/topo_silica_config.sh \
   project_makefiles/silica_link.sh \
   project_makefiles/subdir_stub.mk \
   "$APP/"

cp project_makefiles/Makefile.subdir "$APP/util/Makefile"

chmod +x "$APP/topo_silica_config.sh" "$APP/silica_link.sh"
```

Then add your Silica sources under `$APP` (and under `util/` as needed).

---

## Build

```bash
cd ~/src/my_app
make help          # targets, compiler path, executable name
make               # same as make build
```

Plain `make` / `make build`:

1. Regenerates `silica.config` when unit membership or sources change (topo sort of `use`).
2. Runs `silica-compiler` with process-per-unit reclaim (exit `75` → restart → next unit; `0` → done).
3. Assembles every `.sams` with Clang.
4. Links all `.o` files into one executable.

Default executable name is the **directory basename** of the project root (`my_app` in the layout above). Override with:

```bash
make EXECUTABLE=hello
```

Point at a specific compiler binary:

```bash
make SILICA_COMPILER=/path/to/silica-compiler
```

### Useful targets

| Command | What it does |
| --- | --- |
| `make` / `make build` | Full pipeline: config → compile → objects → link |
| `make assembly` | Compile only (produce / refresh `.sams`) |
| `make objects` | Assemble `.sams` → `.o` |
| `make executables` | Link the executable |
| `make silica.config` | Create or refresh the topo-sorted unit list |
| `make silica.config.regen` | Force-regenerate the unit list |
| `make clean` | Remove generated artifacts (`.sams`, `.o`, configs, iface caches, executable) |
| `make all` | `clean`, then `build` |
| `make help` | List targets and resolved paths |

From a subdirectory that has the stub Makefile:

```bash
make -C util help    # reminds you to build from the parent
make -C util clean   # deletes local .sams/.o only
make -C .. build     # real build
```

---

## What the root Makefile does for you

### `silica.config`

`topo_silica_config.sh` finds every `*.silica` under the project (skipping `.git` and `_wd_probe`), builds a dependency graph from `use` lines, and emits leaf-to-root order with `main.silica` last. The Makefile copies that into `silica.config`, which `silica-compiler` reads from the working directory (no argv).

You normally do **not** hand-edit `silica.config`; regenerate with `make silica.config` or `make silica.config.regen` after adding or removing modules.

### Incremental compile

Before invoking the compiler, the Makefile drops stale or orphan `.sams` / `.iface` files (missing source, or source newer than artifacts). Units that still have up-to-date `.sams` are skipped. Only the remainder is written to `silica.compile.order` for this run.

### Process-per-unit reclaim

Between units, `silica-compiler` may exit with status `75` so the OS can reclaim host heap. The Makefile restarts the compiler until exit `0` (batch done) or a hard failure. Do not treat `75` as failure and do not force one long-lived process for large graphs unless you have measured that you have the RAM—see [compiling_with_less_ram.md](./compiling_with_less_ram.md).

### Link

All project `.o` files are linked together (including nested paths). If the compile step wrote a `silica.link` manifest (typical for FFI archives), `silica_link.sh` appends those archives to the link line. The entry object must be `main.o` from root `main.silica`.

---

## Small example

`helpers.silica`:

```silica
module helpers;

export add/2;

fn add(a: int64, b: int64) -> int64 {
    a + b
}
```

`main.silica`:

```silica
module main;

use helpers;

fn main() -> int64 {
    helpers@add(40, 2)
}
```

```bash
cd my_app
make EXECUTABLE=hello
./hello
echo $?    # 42 on success for this toy
```

Generated (do not commit unless you want to) include `silica.config`, `*.sams`, `*.o`, and the executable.

Example `silica.config` after topo sort:

```text
helpers.silica
main.silica
```

---

## Checklist

- [ ] Root has `Makefile`, `silica_compiler.mk`, `topo_silica_config.sh`, `silica_link.sh`, `subdir_stub.mk`
- [ ] Scripts are executable (`chmod +x`)
- [ ] `silica-compiler` is on `PATH` or you pass `SILICA_COMPILER=…`
- [ ] Application entry is root `main.silica`
- [ ] Every module basename is unique; `use` graph is a DAG
- [ ] Optional: each source subdirectory has `Makefile` copied from `Makefile.subdir`
- [ ] `make help` shows the compiler path and executable name you expect
- [ ] `make` produces the executable; `make clean` removes build products

---

## Related reading

- [compiling_with_less_ram.md](./compiling_with_less_ram.md) — compilation units, leaf-to-root, reclaim loop, splitting large modules  
- [open_recursion_callbacks.md](./open_recursion_callbacks.md) — split recursive algorithms without circular `use`  
- [ffi_wrappers_and_makefiles.md](./ffi_wrappers_and_makefiles.md) — FFI wrappers, sidecars, and link archives  
- [designing_apps_with_foreign_functions.md](./designing_apps_with_foreign_functions.md) — app structure around `dangerous_*` workers  
- Drop-in files: [`project_makefiles/`](../../project_makefiles/) at the repository root  
