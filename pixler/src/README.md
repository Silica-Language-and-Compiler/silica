# `compiler/src/` — the Silica compiler

This is the compiler, written in Silica. It is the only compiler source tree: there is no bootstrap
compiler and no separate seed tree. A compiler binary in [`../../binaries/`](../../binaries/),
reached through `binaries/seed-compiler`, compiles these sources, and the compiler that comes out
compiles them again until the two agree byte for byte — the **fixed point**. A build that reaches
its fixed point becomes the next `seed-compiler`.

## Building it

The scripts are documented in [../../programmer_tools/README.md](../../programmer_tools/README.md).
Building this tree is only needed when you change the compiler itself or port it to a new platform.
Writing Silica programs needs nothing here: use the compiler in [`../../binaries/`](../../binaries/)
or a released one.


Use the scripts in [`../../programmer_tools/`](../../programmer_tools/); each prints its own manual
with `-h` and shows what a run would do with `--list`.

```bash
bash programmer_tools/build_all_platforms.sh --local-only   # this machine, plus raw cross compilers
bash programmer_tools/build_all_platforms.sh                # every platform it knows
```

They drive the `Makefile` here. Working on the compiler itself, you will also use it directly:

| Command | What it does |
| ------- | ------------ |
| `make` / `make build` | Full build with `binaries/seed-compiler`: config → compile → objects → link → install. |
| `make gen1` | Build with `binaries/seed-compiler`; keep the result as `binaries/silica-gen1`. |
| `make gen2` | Build again with `binaries/silica-gen1`; keep the result as `binaries/silica-gen2`. |
| `make fixpoint` | Build gen3 with gen2; pass only if gen3 is byte-identical to gen2. Must follow a fresh `make gen2`. |
| `make trials-gen1` / `trials-gen2` / `trials-both` | Run the whole trial tree against a generation. |
| `make TARGET=<name>` | Bake the backend from `emitter/<name>/` into the binary. |
| `make clean`, `make help` | As usual; `make help` lists the active emit target and the allowable `TARGET` values. |

The build is config-driven, like the trials: regenerate `silica.config.compiler`, copy it to
`silica.config`, run the compiler with no argv, then `.sams` → `.o` → link. The compiler binary is
a staleness input, so there is no incremental path between generations: every unit is recompiled.

Full details, including the platform scripts, the emit-target prompt and what the fixed-point check
checks: [Build and test the compiler](https://yenrab.github.io/silica/build-and-test/).

## Emit targets

`emitter/<target>/` holds one code-generation backend each. The platform table of record is
[`../../project_makefiles/platform/platforms.mk`](../../project_makefiles/platform/platforms.mk).
A backend other than the host's is published as `binaries/silica-compiler-<target>`, never as
`binaries/silica-compiler`.

## Edit discipline

**Crafted edits only.** No tree-wide batch rewriters, bulk regex migrations, or unattended
multi-file dialect passes. Change one scoped API or module at a time, and review before the next
step. A reported compile error means one reported site to fix, not a rename of its siblings.
