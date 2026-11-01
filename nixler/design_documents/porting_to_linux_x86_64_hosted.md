# Porting Silica to Linux x86_64 (hosted)

**Status:** Executed through Phase 5 on 2026-09-19: the backend, the ladder, the hand-off, the native selfhost and the **first Linux x86-64 fixed point** (nix, `binaries/silica-999995-linux-x86_64`, gen3 byte-identical to gen2) are done, with the whole trial tree run natively on nix and its `.linux_x86_64.ascomp` goldens recorded; Phase 6 (droplets and project builds) and the Phase 5 fresh-clone exit gate remain. Phases 0, 1 and 2 were executed 2026-09-18 (§6); Phase 3's source work (the backend as text: shared layer, site conversions, runtime translation, ladder) was done the same day by the virtual-register method without a build. Not normative; [silica-specification.md](silica-specification.md) governs language and ABI semantics. Use this document when adding the `linux_x86_64` emit backend, producing the first Linux x86-64 selfhost compiler, and deploying to Debian-family x86-64 hosts (DigitalOcean droplets).

**Implementation status (2026-10-16).** The path has kept its fixed point through the later chunks: the fixed-point logs under `/Volumes/2T/silica_builds/` end with "gen3 is byte-identical to gen2" for this path on 2026-10-15 (355 units compared, gen2 12,531,136 bytes; the run of 2026-10-16 was still compiling when this was written), and the latest compiler published in the Mac tree's `binaries/` is `silica-999986-linux-x86_64` (2026-10-07). Builds, fixed points and trial runs on the x86-64 machine now go through the platform scripts in `programmer_tools/` (`build_all_platforms.sh`, `rebuild_refresh_verify.sh`, and `sync_to_hosts.sh`, whose sync deletes a file on the host that the tree no longer has unless the platform uses it; the machine list is the gitignored `.silica_build_hosts`), not through the hand-run commands recorded in the phases below. Phase 6 is only partly done: `project_makefiles/platform/platforms.mk` exists, `deploy/linux/install_silica.sh` does not. The source tree is `compiler/src/` (the old `src_selfhost` and `compiler/silica-compiler` names are retired); the phase texts below keep the paths of the day they were executed.

**What changed since the 2026-09-08 plan.** Two facts retired most of its first half:

1. **The Rust bootstrap and the `src/` seed tree are retired.** Every Silica compiler is now built from `src/` by a published Silica compiler (`binaries/silica-compiler`), and a new platform gets its first compiler by a **cross hand-off** from the Mac (§5), not by a bootstrap. There is no way to run any Silica compiler on x86-64 before the x86-64 backend exists, so the old Phase 1 (cargo, LLVM 15, seed chain, text oracle) is gone, and with it the old Phase 0 items for LLVM 15 and cargo.
2. **The trial harness already has the per-target golden axis and host detection.** `trials/silica_compiler.mk` maps a Linux x86_64 host to `linux_x86_64`, derives `ASCOMP_EXT` = `.linux_x86_64.ascomp`, and runs a cross compiler named `silica-compiler-<target>` compile-only. Phase 2's golden handling is therefore mostly done; §6 Phase 2 says what remains.

The AArch64 Linux port is the precedent for everything here: [ports/linux_aarch64_port_checklist.md](ports/linux_aarch64_port_checklist.md), `src/emitter/linux_aarch64/` (its `README.md` lists every Darwin → GNU/ELF change), its runtime shims in `emitter/linux_aarch64/terms/linux_rt_shims_asm.silica` and `src/runtime_asm/linux_aarch64/`. [ROADMAP.md](../../ROADMAP.md) "Later paths" fixes the rule: **Linux x86-64's first fixed point has the behaviours of the current Linux AArch64 fixed point**, and the backend is copied from `linux_aarch64`, not from `apple_silicon_mac`.

**Scope of execution:** the Mac tree (`/Volumes/2T/silica`) is the source of truth and does every compile until Phase 4; the x86-64 machine assembles, links and runs. The machine measured while revising this (`nix`, `ssh lee@nix.local`): Ubuntu 24.04.3 LTS, glibc 2.39, kernel 6.8, AMD Ryzen 5 PRO 3400G (8 threads; AVX2, BMI2, F16C, FMA), 13 GB RAM + 39 GB swap (`free -g`: `Mem: 13 total, 12 available; Swap: 39`), 4 KB pages, `cc` 13.3, GNU `as`/`ld` 2.42, clang 18.1.3, GNU make 4.3, python3, perl, git, rsync. **Not installed:** `lld`, `gdb` (`sudo apt install lld gdb`). Disk: 7.7 GB free of 98 GB (92 % used) — enough for the hand-off tree, not for every trial's `.o` at once.

**Audience:** someone who knows the `src/` batch build (`silica.config`, `emit_target.mk`, `make bootstrap-assembly` / `bootstrap-link`), the trial harness (`trials/silica_compiler.mk`) and the `binaries/` naming.

## Related documents

| Document | Role here |
| --- | --- |
| [ports/linux_aarch64_port_checklist.md](ports/linux_aarch64_port_checklist.md) | The hosted-port precedent: naming axes, Darwin-ism inventory, hand-off (§6 there), gates |
| `src/emitter/linux_aarch64/README.md` | What the GNU/ELF port changed; this port starts from that tree |
| `src/emitter/linux_x86_64/regs/README.md` | The virtual-register home table and frame model (Step 0.5, revised to the VR method 2026-09-18) |
| [direct_machine_object_emitter_future.md](direct_machine_object_emitter_future.md) | Reserves `chip/x86_64`; `platform/` and `regs/` are shaped to become that layer later |
| [porting_for_os_free_targets.md](porting_for_os_free_targets.md) | Board and OS-free ports; scopes hosted ports out, this document covers them |
| [actor_spawn_core_affinity_os_semantics.md](actor_spawn_core_affinity_os_semantics.md) | Linux affinity semantics for the actor runtime |
| [silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md) | Fifi boundary the SysV ABI work must satisfy |
| [silica-specification.md](silica-specification.md) §15.1.2.2, §15.4.13.5 | Runtime-managed actor stacks; x86-64 named as supported, MPK containment deferred (§9) |

---

## 1. Facts that shape the plan

1. **No committed compiler runs on x86-64, and none can until the backend exists.** Every binary in `binaries/` is Mach-O AArch64 (plus Mac-hosted cross compilers such as `silica-compiler-linux_aarch64`). The first x86-64 compiler is produced by the Mac: a Mac-hosted compiler that emits x86-64 text compiles `src/` into x86-64 `.sams`, and nix assembles and links them (§5).
2. **The backend lives in one tree, in the selfhost dialect.** `src/emitter/linux_x86_64/` only; the two-copy problem of the old plan (bootstrap dialect in `src/`, adapter in `src/`) no longer exists.
3. **The emitter is register-bound to AArch64.** Measured on `src/emitter/linux_aarch64` (the tree this port copies):

   | Measure | Count |
   | --- | --- |
   | Silica source files | 115 (`.sams`/`.iface` beside them are generated) |
   | Lines | 35,588 |
   | Files with literal `X<n>` register names | 74 |
   | Literal `X<n>` mentions | 4,817 |
   | Files with `SVC` (write, mmap, munmap, futex) | 14 |
   | Files with `:lo12:` relocations | 33 |
   | Files with `.section` | 16 |
   | Files with no asm at all (target neutral) | 27 |
   | Hand-written runtime `.s` | `runtime_asm/linux_aarch64/silica_rt_shim.s` (237 lines), `deviceio_link_thunks.s` (133) |

   The 88 asm-bearing files are not rewritten: by the virtual-register method (Phase 3) each instruction-emitting site becomes a call into the shared layer with the same operand texts, the 27 neutral files copy verbatim, and only the hand-written runtime chunks are translated by hand. The register model is a home table (regs README §2), not a new allocator.
4. **The compiler needs the actor runtime to run at all.** `main.silica` spawns one actor and runs the whole pipeline inside it on a runtime-managed stack (spec §15.1.2.2); `main` itself never compiles anything. So the hand-off compiler only starts once the actor runtime, its stack fault handler and the futex shims work on x86-64 — Phase 3 must reach its actor step before Phase 4 can begin, and until then every trial is compiled on the Mac.
5. **Trials check assembly goldens per target and program output as the oracle.** Counted 2026-09-18: 13,066 Darwin `.ascomp`, 11,778 `.linux_aarch64.ascomp`, 11,811 `.scout`, 0 `.linux_x86_64.ascomp`. `.scout` is target neutral and is the real oracle for the port; `.linux_x86_64.ascomp` goldens are recorded once a step is stable.
6. **Memory is not tight; disk is.** 13 GB + 39 GB swap covers the largest units (the Mac peaks at 6–8 GB per unit). 7.7 GB of free disk is the constraint: sync only what a step needs.
7. **Two assemblers, one text.** Both GNU `as` 2.42 (through `cc`) and clang 18 are on nix and both must accept every emitted unit, because `cc` is what a droplet has and clang is what the Mac cross-checks with (`clang --target=x86_64-unknown-linux-gnu -c` assembles x86-64 text on macOS, as the AArch64 port did for its target). They disagree in places (`movsx r64, r32`, trailing `//` comments — see the regs README §8); the backend lint assembles with both.

---

## 2. The hand-off chain

```
Mac (source of truth)                                   nix (x86-64, no Silica compiler yet)
──────────────────────                                  ────────────────────────────────────
binaries/silica-compiler (macOS selfhost)
   │  make -C src TARGET=linux_x86_64
   ▼
binaries/silica-compiler-linux_x86_64                   (Phase 3: Mac-hosted, emits x86-64 text; historical, this link was removed on 2026-10-21; the Linux hosts now build and run their own native fixed-point compilers (silica-999966-linux-aarch64 on pix, silica-999974-linux-x86_64 on nix))
   │  make -C trials/<suite> integrate                   .sams  ──rsync──►  assemble, link, run,
   │  (compile-only: emit target ≠ host)                                    diff .sout vs .scout
   │
   │  make -C src bootstrap-assembly BOOTSTRAP_TARGET=linux_x86_64
   ▼
src/**/*.sams (x86-64 text of the whole compiler)  ──rsync──►  make bootstrap-link
                                                                          │  (cc, GNU ld, runtime_asm/linux_x86_64/)
                                                                          ▼
                                                        binaries/silica-NNNNNN-linux-x86_64   (Phase 4)
                                                          │  make -C src build  (native)
                                                          ▼
                                                        gen2 == gen3 fixpoint                  (Phase 5)
```

Droplets receive the committed selfhost binary and need only `cc`/`clang`, `make`, and `-lpthread` (Phase 6).

---

## 3. Vocabulary (decided in Phase 0, then never revisited)

| Concept | Value | Where defined |
| --- | --- | --- |
| Emit target directory | `linux_x86_64` | `src/emitter/linux_x86_64/` (exists as of 2026-09-18 with `regs/README.md` only, which makes `emit_target.mk` list it as an allowed target) |
| Host platform id | `linux-x86_64` (**not** `debian-x86_64` as the 2026-09-08 plan said: `install_compiler.bash` and `update_silica_compiler_link.bash` already produce and accept `linux-x86_64`) | `project_makefiles/platform/platforms.mk` |
| Host default | Linux + x86_64 → emit `linux_x86_64`, run `linux-x86_64` | same file; `emit_target.mk` and `trials/silica_compiler.mk` already compute the same answer inline (the patch beside the table points them at it) |
| Precedent target | `linux_aarch64` (same OS; the backend is copied from it) | `ROADMAP.md` "Later paths" |
| Assembler syntax | GNU as with `.intel_syntax noprefix`: destination first like the ARM text; comments `#`; accepted by GNU as and clang | backend `platform/`; regs README §8 |
| Object format | ELF64; every unit ends with `.section .note.GNU-stack,"",@progbits` | backend `platform/` |
| C ABI at boundaries | System V AMD64 | `regs/README.md` §5.2, `terms/ffi_*` |
| Internal convention | **Virtual registers** (the ESP32-S3 method): the emitter's `X<n>`/`W<n>`/`D<n>`/`SP`/`[X29, #-N]` names are mapped by a home table (`X0`–`X5` = `rdi rsi rdx rcx r8 r9`, `X6`/`X7` = `r14`/`r15`, `X8` = `rbx`, `X9`/`X10` = `r10`/`r11`, `X11`–`X28` and `D8`–`D31` = per-frame slots, `D0`–`D7` = `xmm0`–`7`, `SP` = `rsp` with real pushes, `X29` = `rbp - SVR_AREA`); the result of every call is `rdi` | `regs/README.md`, `shared/x86_vr.silica` |
| CPU baseline | x86-64-v3 (AVX2, F16C, BMI2, FMA); runtime CPUID check once at startup | `regs/README.md` §7 |
| Assembler and linker on Linux | `cc` (GNU as + GNU ld) is the default; clang is the alternative; `-fuse-ld=lld` only when lld is installed (`LINKER_USE_LLD=1`) | `trials/platform/linux_x86_64.mk`, later `project_makefiles/platform/linux_x86_64.mk` |
| Link flags | `-no-pie -rdynamic -lpthread`, `crt1.o` calls `main` (no `-e main`, no `_main` alias, no stack flag) | same |
| Per-target assembly goldens | `<unit>.linux_x86_64.ascomp`; bare `.ascomp` stays Darwin | `ASCOMP_EXT` in `trials/silica_compiler.mk` (already there) |
| Hand-written runtime | `src/runtime_asm/linux_x86_64/silica_rt_shim.s`, `deviceio_link_thunks.s` (SysV), mirroring `runtime_asm/linux_aarch64/` | `src/Makefile` `HOST_RT_ASM` (patch generalises it to `runtime_asm/$(HOST_DEFAULT_TARGET)/`) |

---

## 4. Directory changes

```
compiler/src/
  emitter/linux_x86_64/                    # NEW backend, copied from emitter/linux_aarch64/, selfhost dialect
    regs/README.md                         #   the home table and frame model (Phase 0, revised for the VR method)
    shared/x86_vr.silica x86_isa.silica    #   the shared layer: VR homes, instruction selection, loads/stores, floats
           x86_mem.silica x86_float.silica
    shared/selftest/                       #   run_selftest.sh emits one instance of every helper, assembles it with both assemblers
    ladder/silica_00_return42 .. silica_14_wbt_map   # the bring-up order for the debug phase (README there)
    emitter_core.silica  module_linkage.silica  atoms/ constraints/ control/ effects/ recursion/ terms/
  runtime_asm/linux_x86_64/                # NEW: silica_rt_shim.s, deviceio_link_thunks.s in SysV form
project_makefiles/platform/
  platforms.mk                             # NEW (Phase 0): the one name table; platforms.patch = proposed rewiring
  linux_x86_64.mk, apple_silicon_mac.mk    # Phase 6: project-build toolchain fragments
trials/platform/
  linux_x86_64.mk, apple_silicon_mac.mk    # NEW (Phase 2): trial toolchain fragments, not yet included
trials/base/linux_x86_64_smoke/            # NEW (Phase 2): hand-written hello.sams, Makefile, hello.scout
trials/**/*.linux_x86_64.ascomp            # Phase 3: recorded per ladder step
binaries/silica-NNNNNN-linux-x86_64        # Phase 4 exit: the first x86-64 selfhost, published on nix
deploy/linux/install_silica.sh             # Phase 6
```

Gone from the old plan: `src/emitter/linux_x86_64/`, `tools/ll_opaque_ptr.py`, `deploy/linux/install_deps.sh` (LLVM 15), the `backend-drift` target, `runtime/apple_silicon_mac/` (the Apple `.s` files stay at the `src/` root as today; Linux ones live under `runtime_asm/<target>/`).

---

## 5. Global rules

- **The backend is copied from `linux_aarch64`, then rewritten file by file.** The Apple and AArch64 backends are not touched. The 27 target-neutral files copy verbatim; consolidation into an `emitter_common/` is a later project once three targets run.
- **Program output is the oracle; assembly goldens are per target.** A trial passes when every `.sout` matches its `.scout`; `.linux_x86_64.ascomp` goldens are recorded once a step is stable and then guard regressions. Goldens are never auto-regenerated (project rule): recording is a deliberate copy of a reviewed `.sams`.
- **One name table** (§3), `project_makefiles/platform/platforms.mk`, is the source for host platform ids and emit targets; makefiles include it, bash scripts read it through `make -s -f … host-platform`.
- **No machine register literal outside `shared/` and the hand-written runtime chunks** in the new backend: a converted emitter site names only virtual registers and calls the shared layer. `make lint-backend` (debug phase) greps for `\b(r[a-z0-9]{1,3}|e[a-d]x|e[sd]i|xmm[0-9]+)\b` in emitter sites and assembles a sample of emitted units with both `cc` and `clang`.
- **The stack discipline is AArch64's, shifted:** every emitter push is 16 bytes and `rsp` therefore stays 16-aligned at every `call`; the emitter's `[X29, #-N]` slots sit below the per-frame area of virtual-register homes (`SVR_AREA`), so no slot address changes (regs README §3).
- **No `ulimit`, no stack link flag, ever.** `main` runs on the platform stack and does no work; actors run on runtime-managed stacks. The old plan's `ulimit -s` wrapper and Step 3.8 stack switch are obsolete.
- **The Mac compiles, nix runs, until Phase 4.** Never run `make build`/`gen*`/`fixpoint` or a `TARGET=` build in `src` while someone else's build is running there (project rule); the cross compiler is built once per ladder step and published as `binaries/silica-compiler-linux_x86_64`.

---

## 6. Phases

### Phase 0 — Machine preparation and decisions (done 2026-09-18)

**Step 0.1 — Packages.** Checked on nix: `cc`/`gcc` 13.3, GNU `as`/`ld` 2.42, `clang` 18.1.3 (`/usr/lib/llvm-18`), `make` 4.3, `python3`, `perl`, `git`, `rsync`, `objdump`, `nm` present. Missing: `lld` (so `-fuse-ld=lld` fails; GNU ld is the default) and `gdb`. To add them: `sudo apt install lld gdb` (Ubuntu 24.04 resolves `lld` to `lld-18`; `gdb` 15.1). Neither is required for Phases 0–2.

**Step 0.2 — (removed)** LLVM 15 was only for the retired bootstrap.

**Step 0.3 — Memory.** Already present: `free -g` → `Mem: 13 total, 0 used, 12 free, 12 available; Swap: 39 total, 0 used` (`/swap.img`, 40 GB). `JOBS=8` is fine for assembling; Silica emission is serial anyway.

**Step 0.4 — Name table.** Written: `project_makefiles/platform/platforms.mk` (host rows `uname -s:uname -m:emit target:platform id`, target rows `emit target:platform id`, `SILICA_HOST_EMIT_TARGET`, `SILICA_HOST_PLATFORM`, `silica_platform_for_target`, and `make -s -f … host-platform|host-emit-target|platforms|emit-targets|platform-for-target` for shell callers; GNU make 3.81-compatible, verified on both machines). Nothing includes it yet: the rewiring of `src/emit_target.mk`, `src/Makefile` (`HOST_RT_ASM` per host target, `BOOTSTRAP_TARGET`), `trials/silica_compiler.mk`, `binaries/install_compiler.bash`, `binaries/update_silica_compiler_link.bash` and the representative `trials/base/makefile` is `project_makefiles/platform/platforms.patch`, which passes `git apply --check`; it is not applied because other builds were running in the tree.

**Step 0.5 — Register and frame model.** Written before any lowering code: `src/emitter/linux_x86_64/regs/README.md`. The decisions, in one paragraph: internal calls are SysV for scalars (`rdi rsi rdx rcx r8 r9` / `xmm0–7`, return `rax` / `xmm0`), the 7th and 8th GPR arguments (148 compiler functions need them) travel in a 16-byte outgoing area at the bottom of the caller's fixed frame; the callee-saved chain is `rbx r12 r13 r14 r15` then 8-byte frame slots whose addresses depend only on the slot number, below a 40-byte save area that is always reserved and only filled for the registers the single `frame_plan(fn) -> (registers, slots)` selects; all parameters are shadowed at entry so the argument registers are scratch; call arguments are staged in slots/callee-saved/`rax r10 r11` and loaded in one block before the `call`; floats have no callee-saved home and use slots; the internal aggregate-return pointer arrives in `rax` (`X8`'s role) while FFI follows real SysV classification (hidden pointer in `rdi`, `al` vector count); `float16` is 16 bits in memory, converted with F16C and computed in `float32` (bit-identical results for `+ − × ÷ √`); the actor-stack fault handler reads `RSP` at `ucontext+160` and `RIP` at `+168`; comments are `#`; x86-64-v3 baseline with a startup CPUID check.

**Exit gate (met):** swap present; toolchain inventoried with the one install line; `platforms.mk` written with its consumers' rewiring as a checked patch; `regs/README.md` written before any lowering code.

### Phase 1 — The hand-off: how a platform gets its first compiler (procedure; executed in Phase 4)

There is no bootstrap. A new platform's first native compiler is produced by the Mac and finished on the target, using the two `src/Makefile` targets the AArch64 port introduced:

1. **Mac:** `make -C src TARGET=linux_x86_64` builds a macOS-hosted compiler whose emitter is `emitter/linux_x86_64/` and publishes it as `binaries/silica-NNNNNN-linux_x86_64-macos-applesilicon` with the link `binaries/silica-compiler-linux_x86_64` (`install_compiler.bash target`). It runs on the Mac and emits x86-64 text. (Historical: this link was removed on 2026-10-21; the Linux hosts now build and run their own native fixed-point compilers (silica-999966-linux-aarch64 on pix, silica-999974-linux-x86_64 on nix).)
2. **Mac:** `make -C src bootstrap-assembly` (with `BOOTSTRAP_TARGET=linux_x86_64` once `platforms.patch` is applied; today the target hard-codes `linux_aarch64`) runs that cross compiler over every unit of `src/`, producing the whole compiler as x86-64 `.sams`. Nothing is assembled on the Mac.
3. **Copy** the `src/` tree with its `.sams` and `runtime_asm/linux_x86_64/` to nix (`rsync` into `~/silica`, the same relative layout; the Mac tree stays the source of truth).
4. **nix:** `make -C src bootstrap-link` assembles every `.sams` with `cc`, links with `cc -no-pie -rdynamic` plus `runtime_asm/linux_x86_64/*.s`, and installs the result as `binaries/silica-NNNNNN-linux-x86_64` with `binaries/silica-compiler` pointing at it. No compiler runs during this step.
5. From here nix self-hosts: `make -C src build` (`gen1`, `gen2`, `fixpoint`) runs natively and the Mac drops out of the loop.

(Historical: the `binaries/silica-compiler-linux_x86_64` link was removed on 2026-10-21; nix now runs its own native compiler, so a trial there uses the ordinary `binaries/silica-compiler` link.) The trial harness already supports the same split for programs: with `SILICA_COMPILER=binaries/silica-compiler-linux_x86_64` a trial on the Mac compiles only (`SILICA_TARGET_IS_HOST=0`, "compiling only, not assembling or running"), and the emitted `.sams` are the deliverable for nix.

**No builds were run for this phase.** It is documentation of the procedure, which Phase 4 executes.

### Phase 2 — Linux assemble, link, run path (done 2026-09-18, hand assembly, no backend)

**Step 2.1 — Trial platform fragments.** Written, not yet included anywhere:

- `trials/platform/linux_x86_64.mk`: `ASSEMBLER := clang` (or `cc`), `ASFLAGS := -c -x assembler`, `LINKER := $(ASSEMBLER)`, `LDFLAGS := -no-pie -rdynamic -lpthread` (`-fuse-ld=lld` only with `LINKER_USE_LLD=1`), FFI fixture `CFLAGS := -std=c11 -O2 -fPIC -D_GNU_SOURCE`, `GOLDEN_SUFFIX := .linux_x86_64.ascomp`, `SKIP_TRIALS := cpu_discovery_and_spawn_pinning`, GNU `stat` forms. Every variable a trial makefile assigns after its include is set with `override`, the way `trials/linux_host.mk` does, so it can be included from `silica_compiler.mk` today.
- `trials/platform/apple_silicon_mac.mk`: the macOS values verbatim (`clang`, `-mmacosx-version-min`, the rust-lld-if-present linker, `-Wl,-e,main`, `GOLDEN_SUFFIX := .ascomp`). Its header lists the 43 makefiles that inline those values and the exact lines each would lose (40 × `RUST_SYSROOT/RUST_TARGET/RUST_LLD/MACOS_SDK`, 39 × `LDFLAGS_clang`, 37 × `ASSEMBLER`/`ASFLAGS_macos`, 36 × `LINKER`, 35 × `LDFLAGS_rust-lld`, 34 + 8 × `MACOS_MIN_VERSION`, 4 ffi `ARCH`/`ASFLAGS` variants, 1 `deep_frame_spill_addition` with `-stack_size`). `platforms.patch` shows the deletion on `trials/base/makefile`.

**Step 2.2 — Golden handling: verified, what remains.** Already in `trials/silica_compiler.mk`: `SILICA_HOST_EMIT_TARGET` (`linux_x86_64` on a Linux x86_64 host), `SILICA_EMIT_TARGET` from the compiler's name, `ASCOMP_EXT` (`.linux_x86_64.ascomp`), and compile-only mode when target ≠ host. Still to do, in order:

1. A missing `<unit>.linux_x86_64.ascomp` is a **failure** today (`has no .ascomp file`), not "no golden yet". Since the project never auto-regenerates goldens, this is the intended tripwire once goldens exist, but during Phase 3 it hides the `.scout` result behind an assembly failure. Add a `GOLDEN_MISSING=warn` knob to the shared recipe (one place: the `for sams in *.sams` loop that every suite copies) so a step can be run for its `.scout` oracle before its goldens are recorded.
2. The 43 inline toolchain blocks: apply `platforms.patch`'s include in `silica_compiler.mk`, then delete the lines the Apple fragment lists. Until then `trials/linux_host.mk` already makes every suite work on a Linux host (`cc`, `-no-pie -rdynamic -lpthread`, no macOS flags), so this is tidiness, not a blocker.
3. A "remote run" driver: the Mac compiles, nix runs. `trials/targets/` already has the board driver shape (`<target>.conf`, `trial_target.sh run`, per-target `.sout`/`.scout` overrides, the one-run lock); a `linux_x86_64.conf` whose runner is `rsync` + `ssh lee@nix.local make -C … integrate` would reuse the whole wrapper (progress line, watchdog, report). Alternative for early steps: `rsync` the suite directory and run its makefile on nix by hand, which is what Step 2.3 did.
4. `SKIP_TRIALS` is read by nothing yet; `trials/targets/*.skip` is the existing per-target skip mechanism and is the right home.

**Step 2.3 — Hand-written smoke.** `trials/base/linux_x86_64_smoke/`: `hello.sams` (`.intel_syntax noprefix`, `.text`, `main` that `syscall`s `write(1, "hello from linux_x86_64\n", 24)` and returns 0, `.rodata`, `.L` labels, GNU-stack note, `#` comments), `hello.scout` (the line plus the exit status `0`, the trial convention), and a standalone `Makefile` that includes the Linux fragment and does assemble → link → run → diff without `silica_compiler.mk` (which would demand `binaries/silica-compiler`). It prints `SKIP` and exits 0 on any other host, and it is outside the automatic tree (`trials/Makefile` runs immediate children; `base/` discovers `.silica`). Run on nix (`rsync` of the three directories into `~/silica`, `make integrate`):

```
✅ linux_x86_64_smoke/Clean complete
Assembling hello.sams -> hello.o (clang)
Linking hello (clang -no-pie -rdynamic -lpthread )
Running ./hello
✅✅ linux_x86_64_smoke/hello output matches .scout
```

`hello.sout` = `hello from linux_x86_64` / `0`; `file hello` = `ELF 64-bit LSB executable, x86-64, version 1 (SYSV)`; `nm` shows only `main` and `__libc_start_main` (the `.L` label stayed local). The same file assembles and runs through `cc` (GNU as + GNU ld) too — that second path is what found that GNU as rejects trailing `//` comments.

**Exit gate (met):** the smoke trial passes on nix with clang or cc and make; nothing in the existing trial tree was changed.

### Phase 3 — The `linux_x86_64` backend in `src/` (Mac compiles, nix runs)

**Method (decided 2026-09-18 after evaluation): the ESP32-S3 port's virtual-register approach, not a
rewrite.** The AArch64 emitter's logic — SIR walking, type classification, aggregate promotion, region
ownership, the `outer_reg` bookkeeping, the frame predicates — is kept verbatim. Its register names are
virtual registers on this target; a shared layer maps each VR to a home and expands every AArch64-meaning
operation into x86-64 text, so a site conversion is mechanical: `"    ADD dest, X9, X10"` becomes
`x86_isa@x86_add(dest, "X9", "X10")`. The home table and frame are in
`src/emitter/linux_x86_64/regs/README.md`; the method's origin is
[ports/esp32s3_xtensa_port.md](ports/esp32s3_xtensa_port.md) §2–§4.

**What exists (source, no compiler build; done 2026-09-18):**

1. `shared/x86_vr.silica` (home table, operand texts, VR in/out through the scratch registers),
   `shared/x86_isa.silica` (mov/movi/adr, add/sub/mul/and/orr/eor/bic/neg/mvn, shifts, sdiv/udiv/srem/urem
   with the `rdx` save and the x/0 and INT_MIN/-1 guards, cmp + cset/bcond/csel and the combined forms,
   cbz/cbnz, calls, `x86_call_c` for the C boundary, extensions, barrier), `shared/x86_mem.silica`
   (every AArch64 memory-operand form the emitter writes, all widths, pairs, SP pushes/pops as real `rsp`
   moves through `lea`, `[X29, #-N]` → `[rbp - SVR_AREA - N]`), `shared/x86_float.silica` (xmm
   arithmetic, `ucomisd` conditions with the unordered cases of every AArch64 condition, conversions,
   F16C `float16` computed in `float32`, `is_nan/inf/finite`). All flag-transparent except the
   arithmetic and compares, so a `CMP` survives the moves the emitter puts before its consumer.
2. `shared/selftest/`: `x86_selftest.silica.txt` emits one instance of every helper (register-homed and
   slot-homed operands, immediates, W/S/H views); `run_selftest.sh` builds it with the published macOS
   compiler, runs it, and assembles the 1181-line result with `clang --target=x86_64-linux-gnu` and with
   GNU `as` on nix; `unit_compile.sh <module>` compiles one emitter module plus its transitive `use`
   closure in a scratch directory with the published compiler (how every converted module was checked).
3. `emitter_core.silica` and `control/control.silica`: `push rbp; mov rbp, rsp; sub rsp, SVR_AREA` /
   `leave; ret`; `x86_frame_header` lays out the VR homes a body references after the body is emitted and
   publishes them as `.set` symbols in front of the label; the `STP`/`LDP` pushes of callee-saved VRs
   vanish (they are slots); `main` preserves `rbx r12`–`r15` for `crt1` and returns through `rax`;
   `.intel_syntax noprefix`, `#` comments, `.note.GNU-stack`; the runtime module prelude.
4. Site conversions of every other file that emits machine text (the ESP32-vs-Apple diffs were the
   checklist; files the ESP32 port left identical stay identical), with the memory layouts unchanged
   (8-byte fields, 24-byte list cells, string header `{tag, data@+8, length@+16}`) so the `.scout`
   goldens carry over.
5. The runtime as translated text: `prims_actors_runtime_asm` (split into `_b`/`_c` modules by chunk
   ranges), `prims_actors_stack_asm`, `prims_actors_child_table_asm`, `ffi_fault/guarded/arena/foreign`,
   `canonical_arena`, `ordering_identity`, `checked_int64`, `linux_rt_shims_asm` (futex, lock,
   `cpuid`-backed sysctl shim), the print/string/file helpers, and `runtime_asm/linux_x86_64/{silica_rt_shim.s,
   deviceio_link_thunks.s}`. Every chunk assembles under both assemblers; none has run.
6. The ladder: `emitter/linux_x86_64/ladder/silica_00_return42` … `silica_14_wbt_map` with their
   reference outputs and a README on running each on nix.

**Debug phase (when the Mac is free), in this order:**

| Step | Program / suite | What it settles |
| --- | --- | --- |
| 3.1 | `ladder/silica_00_return42` | the module prelude assembles as a whole unit; `.set` frame header; `main` through `crt1`; `__silica_runtime.sams` assembles and links (pid registry init runs at every entry point) |
| 3.2 | `silica_01_arith`, `silica_02_calls` | calls with results in `rdi`; parameter shadows into slots; `idiv` paths |
| 3.3 | `silica_03_case_bool` | flag transparency between `CMP` and its consumer; short-circuit pushes |
| 3.4 | `silica_04_print`, `silica_05_int64_wide` | the print helpers' `write` syscall path; 64-bit multiply/divide |
| 3.5 | `silica_06_strings` | the mmap string arena (syscall 9) |
| 3.6 | `silica_07_recursion_depth`, `silica_08_stack_guard` | frame size under deep recursion; the fault handler not taking a non-actor SIGSEGV for stack growth, and reporting it as a fatal fault (`[silica] fault at ...`, status 70, [runtime_failure_reporting.md](runtime_failure_reporting.md)) |
| 3.7 | `silica_09_lists` … `silica_11_regions` | lists, records/tuples on frame regions off `rbp - SVR_AREA`, regions/refs/bufs, `L_region_grow` |
| 3.8 | `silica_12_floats` | xmm arithmetic, `ucomisd` conditions, F16C, the digit-exact float printers |
| 3.9 | `silica_13_checked`, `silica_14_wbt_map` | overflow flags, tuple returns, the stdlib map |
| 3.10 | `trials/actors_addition`, `actor_stacks_addition`, `supervisors_addition` | the actor runtime: pthreads, futex shims, the sigaltstack growth handler (`ucontext` RSP `+160` / RIP `+168`), `MAP_FIXED` release, the `rsp` switch — the gate for Phase 4, because the compiler runs its pipeline in an actor |
| 3.11 | `trials/ffi_addition/**` | `x86_call_c` argument/`al` staging, MEMORY-class returns, the guarded and fault runtimes on glibc `sigaction`/`__sigsetjmp` |
| 3.12 | the rest of `trials/` suite by suite (`base`, `int*`, `float*`, `string`, `records`, `tuples`, `list`, `case`, `modules`, `traits`, `effects`, `error/warning enforcement`, `memory_region`, `ordered_data_structures`, `compiler_addition`, `codegen_defects_addition`) | `.scout` conformance; then record `.linux_x86_64.ascomp` goldens (a deliberate copy of a reviewed `.sams`, never auto-regenerated) |

The loop for every step is the one already described: edit backend → cross compiler on the Mac →
compile-only trial run → `rsync` to nix → assemble/link/run/diff there (`objdump -d -M intel`, `gdb`
once installed).

Things that can only be settled by running, in the order the ladder will hit them: the `.set`
redefinition per function inside one unit with hundreds of functions (both assemblers accepted the
probe); the frame header's text scan (`contains(text, "SVR_X19")`) against a body that mentions a home
only in a comment (harmless extra slot) or builds a name it never references; the exit status of `main`
through `rax`; flag transparency at every site that puts an `lea`/`mov` between a `CMP` and a `B.cond`
(the helpers are flag-transparent by construction, but a site that was converted to a flag-setting
`x86_add` between them would break); `x86_cbz` clobbering the flags where AArch64's `CBZ` did not; the
`idiv` `rdx` save when `X2` is the destination; the print helpers' digit algorithms against the
`.scout` files (bit-exact float printing); `ucomisd` condition mapping for `LT`/`LE`/`HI`/`HS` with NaN;
`silica_08_stack_guard` (a platform-stack overflow must not be mistaken for actor growth); the region
runtime's 64 MB blocks; the actor stack fault handler (`sigaltstack` per thread, `siginfo+16`,
`ucontext+160/+168`, `MAP_FIXED` remaps, the timed futex, the usage scan); the futex lock and
condition-variable shims under contention; `dladdr` on `-rdynamic` symbols for the failure banner; the
`cpuid` answers of the sysctl shim; FFI `al` and 7th/8th-argument pushes; the `float16` results versus
the AArch64 goldens.

**Exit gate (historical, the cross-compiler link was removed on 2026-10-21):** `make -C trials integrate SILICA_COMPILER=…/silica-compiler-linux_x86_64` compiles every suite on the Mac and every emitted program passes its `.scout` on nix; every unit has a `.linux_x86_64.ascomp`; `lint-backend` clean.

**Executed 2026-09-18/19.** The ladder ran on nix first with `silica-999997` (14/15; the one miss was app 08,
whose "139" expectation predated the failure-reporting decision — it prints the fault banner and exits 70, like
every other host) and again on 2026-09-19 with `silica-999996` after the boxed-record-layout and
failure-reporting work: **15/15**. Sample suites compiled on the Mac with that cross compiler and run on nix
(base, int64, list, records, tuples, string, float64, case, modules, traits, generic_modules, memory_region,
actors, actor_stacks, supervisors — about 5,700 trials) showed no x86-only failure; the remaining misses were
documented defect stems and trials whose harness runner (the `wait_for_exit` marker driver) the ad-hoc runner
did not provide. The x86-only defects fixed on 2026-09-18 were the indirect tail call reading its target from a
frame slot after `leave` and the FFI tail call running C at `rsp` 8 mod 16; the one the native run later found is
the SysV hidden sret pointer (Phase 5 below).

### Runbook — what happens when the Mac is free

1. **Clean first.** `make -C src clean` — the object stage assembles every `.sams` under the tree
   and links every `.o`, so a tree that still holds another emitter's objects links two emitters.
2. **Build the cross compiler.** `make -C src build TARGET=linux_x86_64 SILICA_COMPILER=binaries/silica-compiler INSTALL_SELFHOST=0`.
   The published macOS selfhost compiles `src/` with `emitter/linux_x86_64/` baked in; the
   result is a Mac-hosted compiler that emits x86-64 and was published as `binaries/silica-compiler-linux_x86_64` (historical: link removed 2026-10-21)
   (`install_compiler.bash target`). `emitter_core.silica` is the one unit that could not be
   compile-checked in advance (memory hog): its new functions were compiled in isolation, the rest of its
   edits are helper calls of the shapes the other modules use; expect the first build to be the check.
3. **Ladder and trials** as the Phase 3 table above, until 3.10 passes (the actor runtime).
4. **Emit the whole compiler.** `make -C src bootstrap-assembly` with `BOOTSTRAP_TARGET=linux_x86_64`.
   Today `src/Makefile` hard-codes `linux_aarch64` there; the generalisation
   (`BOOTSTRAP_TARGET ?= linux_aarch64`, `HOST_RT_ASM := runtime_asm/$(HOST_DEFAULT_TARGET)/…`) is in
   `project_makefiles/platform/platforms.patch` (`git apply --check` passes as of 2026-09-18): apply the
   patch rather than editing the Makefile by hand.
5. **rsync to nix** exactly as done for the Pi, excluding the Apple-generated files:
   `rsync -a --exclude '*.o' --exclude '*.dSYM' --exclude 'silica-compiler' --exclude 'binaries/silica-9*' --exclude '.git' /Volumes/2T/silica/ lee@nix.local:~/silica/`
   (the `.sams` are the deliverable; nix has 7.7 GB free, so never sync object files).
6. **On nix:** `make -C src bootstrap-link` assembles every `.sams` with `cc`, links with
   `cc -no-pie -rdynamic -lpthread` plus `runtime_asm/linux_x86_64/*.s`, and installs
   `binaries/silica-NNNNNN-linux-x86_64` with `binaries/silica-compiler` pointing at it.
7. **gen2 / fixpoint on nix**, with the extra generation the actor runtime text needs
   ([Phase1_TODOs/actor_stack_growth_plan.md](Phase1_TODOs/actor_stack_growth_plan.md) "Implementation
   status"): the compiler links its own actor runtime and that text is emitted by the *building*
   compiler, so an edit to the runtime assembly converges one generation later than an edit to compiler
   code — when `make fixpoint` reports no unit differences but a differing binary, copy the newest build
   to `binaries/silica-gen1`, run `make gen2` and `make fixpoint` again.

### Phase 4 — Hand-off: first native x86-64 selfhost

Execute Phase 1's procedure with the Phase 3 cross compiler: `bootstrap-assembly` on the Mac (`BOOTSTRAP_TARGET=linux_x86_64`), `rsync` to nix, `bootstrap-link` on nix, then `make -C trials integrate` natively on nix with the installed `binaries/silica-compiler`.

**Exit gate:** the native compiler passes the whole trial tree on nix.

**Executed 2026-09-19.** `project_makefiles/platform/platforms.patch` applied (it generalises `bootstrap-assembly`
with `BOOTSTRAP_TARGET ?= linux_aarch64` and `HOST_RT_ASM := runtime_asm/$(HOST_DEFAULT_TARGET)/…`; the Linux
AArch64 default is unchanged). `make bootstrap-assembly BOOTSTRAP_TARGET=linux_x86_64` on the Mac: 342 units +
`__silica_runtime` = 343 `.sams`, 29 min. `rsync` to nix (222 MB without `.sams`, 87 MB of `.sams`), then
`make -C src bootstrap-link` there: every `.sams` assembled with `cc` and linked with
`cc -no-pie -rdynamic` plus `runtime_asm/linux_x86_64/*.s` into `binaries/silica-999999-linux-x86_64`.

One wiring defect came with the patch and was fixed in `binaries/install_compiler.bash` and
`binaries/update_silica_compiler_link.bash`: their `make -s -f platforms.mk host-platform` ran inside a parent
make, so `MAKEFLAGS` (`-w`) leaked "Entering directory" lines into the platform name and the install failed.
Both call sites now run `MAKEFLAGS= MAKELEVEL= make -s --no-print-directory -f …`.

### Phase 5 — Fixpoint and publication

Fixed points exist now on both other hosted paths (macOS 2026-09-12; Linux AArch64 "fixed point 1" on the Raspberry Pi, commit `8dcf493d4`), and `src/Makefile` has the procedure: `make gen1`, `make gen2`, `make fixpoint` (gen3 == gen2 modulo UUID/signature), `trials-gen1`/`trials-gen2`. Run it on nix unchanged. A gen2/gen3 difference means host-dependent output (uninitialised memory, address-dependent ordering) — fix before publishing. Record peak RSS on the largest unit. Publish with `install_compiler.bash selfhost` → `binaries/silica-NNNNNN-linux-x86_64`; commit the binary and the goldens; add the row to the ROADMAP paths table.

**Exit gate:** fresh clone on nix → `binaries/update_silica_compiler_link.bash` → `make -C trials integrate` green, no Mac involved.

**Executed 2026-09-19 (fixed point 1 for this path).** Generations on nix, each 342 units emitted serially:
gen1 48 min, gen2 58 min, gen3 (`make fixpoint`) 57 min, peak RSS 7.3 GB on `emitter_core` (13 GB machine).
`make fixpoint`: **343 units compared, 0 emitted differently by gen2 than by gen1, gen3 byte-identical to gen2.**
Two facts worth keeping: every `.sams` the first native build emitted on nix is byte-identical to the Mac cross
compiler's `bootstrap-assembly` output, and the first native compiler is byte-identical to the bootstrap binary —
the host changes nothing about the emission. Published on nix as `binaries/silica-999995-linux-x86_64`
(`silica-compiler`) and as the seed `silica-999998-seed-linux-x86_64` (same bytes); the same file is in the Mac
tree as `binaries/silica-999995-linux-x86_64`. The Mac's cross compiler is
`binaries/silica-999995-linux_x86_64-macos-applesilicon` (`silica-compiler-linux_x86_64`; historical, the link was removed on 2026-10-21 and the cross compiler is no longer kept).

Trial tree on nix under that compiler (`make integrate TRIAL_TARGET=host JOBS=3 SDS_JOBS=1`): **✅ 34,044,
❌ 74, 35m40s** (Apple reference the same day: 34,005 / 88). Every failure is a documented defect stem
(`sd1/3/8/10/11/12/14/15/16/18/19/20/21`, `emitter_defect_*`, `defect_*`, the `compile_defects_*_addition`
suites, `memory_region_addition/buf_write_out_of_bounds_aborts`, `error_enforcement`'s
`stmt_missing_semicolon_between_binding_*`) or a unit with no golden on any target
(`generic_modules_addition/pair_sets`, `wbt_set`). 11,931 `.linux_x86_64.ascomp` goldens were recorded — only
for units whose trial output matched its `.scout`, never for a defect stem — plus
`stdlib/Supervisor.linux_x86_64.ascomp`; the formal run re-verified every one of them.

Backend defect found by the native run and fixed in `terms/ffi_foreign.silica`: a foreign call returning the
32-byte result record passed the arena buffer only in `X8` (AArch64 style), so the callee wrote the record over
its first argument (three FFI string trials faulted). System V AMD64 takes that buffer as a hidden FIRST integer
argument: `emit_sret_hidden_arg_shift` now moves every integer argument up one home and `X8` into `X0` before the
guarded call, and `c_call_stack_args` counts the hidden argument. `app_sd18_worker_second_message` still faults
(in `silica_rt_lock_lock` on the worker's second message) — the documented SD-18 defect, whose Apple symptom is
the same fault in `os_unfair_lock_lock`.

Two Linux-only harness defects the run exposed (fixed in the Mac tree by the session coordinator, not part of this
backend): the `compare_scout_*.sh` scripts need bash (`set -o pipefail`) but the makefiles start them with
`$(SHELL)`, which is dash on Debian-family hosts; and `error_enforcement_addition`'s `silica.config` recipe
expanded ~11k file names into one shell argument, over Linux's 128 KB `MAX_ARG_STRLEN`. A third, still open:
`src/Makefile`'s `fixpoint` target prints the binary sizes with BSD `stat -f %z` and no GNU fallback, so
that one line reads as a filesystem dump on Linux (the verdict itself is a `cmp` and is unaffected).

### Phase 6 — Droplets and project builds

- `deploy/linux/install_silica.sh`: `apt install build-essential clang make`, clone or pull, run the symlink updater, compile a hello project with `project_makefiles/Makefile`. Idempotent; `sudo` only for apt.
- `project_makefiles/Makefile`: include `project_makefiles/platform/<host emit target>.mk` (assembler, linker, `LDFLAGS_STACK` empty on Linux) instead of its inline macOS values; `silica_link.sh` returns ELF archives.
- Stdlib outputs per target: emit to `stdlib/**/build/<target>/`, `trials/stdlib_prereq.mk` reads from there, and the committed Darwin files at the stdlib root stop being overwritten.
- Docs: `design_documents/README.md`, `tutorials_and_howtos/ffi_wrappers_and_makefiles.md` (SysV notes), the top-level `README.md` platform list; mark this document Implemented.

**Exit gate:** a new droplet goes from image to compiling a Silica project with one script.

---

## 7. Order and dependencies

```
Phase 0 ──► Phase 2 ──► Phase 3 ──► Phase 4 ──► Phase 5 ──► Phase 6
              ▲                        ▲
   Phase 1 (procedure only) ───────────┘
```

Phases 0, 1 and 2 are done. Phase 3 is the long pole; its step 3.8/3.10 (actor runtime) is the gate for Phase 4, because the compiler itself runs inside an actor (Fact 4).

---

## 8. Risks and what retires each (ordered by severity)

| Risk | Retired by |
| --- | --- |
| **Register-pressure mismatch (10 callee-saved → 5) corrupts callers silently.** Every SP-corruption bug so far came from a slot counter that mirrored the wrong predicate | Retired by the virtual-register method: `X19`–`X28` are per-frame slots, the AArch64 predicates and slot counters run unchanged, and no save area exists to land on |
| **Argument registers double as scratch.** The AArch64 "binop with complex operand clobbers X9" family | Unchanged from AArch64: the home table keeps `X0`–`X7` and `X9`/`X10` disjoint (`rdi…r9 r14 r15` vs `r10 r11`), and the helpers' scratch (`rax r12 r13`) is never a VR |
| **The compiler cannot run until the actor runtime works** (Fact 4): the fault-handler stack growth on x86-64 (`ucontext` offsets, `sigaltstack`, `MAP_FIXED` release, `rsp` switch) must be right before the hand-off, with no debugger on nix until gdb is installed | The offsets were verified on nix with a C program before translation (regs README §6); step 3.10 of the debug phase; `sudo apt install gdb`; the AArch64 `prims_actors_stack_asm` was translated line for line |
| **16-byte `rsp` alignment at every `call`.** A misaligned call into glibc faults inside `movaps`, far from the cause | Every emitter push is 16 bytes (AArch64's own rule) and `SVR_AREA` is rounded to 16; hand-written helpers keep `N` a multiple of 16 (the shim trap from the Rust-free work) |
| **Two assemblers disagree** (`movsx r64, r32`, trailing `//`, and whatever else) | `lint-backend` assembles with both `cc` and `clang`; `#` comments; `movsxd` |
| **Seven- and eight-argument functions** (148 in the compiler) | `X6`/`X7` are homed in `r14`/`r15` (registers, as on AArch64), so nothing changes for them; only C callees with 7+ arguments push them (`x86_call_c`) |
| **Partial-register writes** (`al`, `ax`) leave stale upper bits; AArch64 `W` writes zero-extend | Rule: 32-bit forms and `movzx`/`movsx` only; `int8/16_addition` |
| **`float16` results must match the AArch64 `.scout` files** | F16C + `float32` compute is bit-identical for the basic operations; the print helpers are ported digit for digit |
| **PIE default on Ubuntu** | `-no-pie` while data tables hold absolute `.quad` addresses; `rip`-relative code already, so PIE later is a data change |
| **Disk on nix (7.7 GB free)** | Sync per suite; `make clean` between suites; never `rsync` the Mac's `.o`/`.sams` tree wholesale |
| **Host-dependent codegen breaks the fixpoint** | Phase 5 `make fixpoint` |
| **Signal and `setjmp` layouts** | glibc wrappers by name; the only hand-laid struct is `sigaction` (same 152-byte layout on both Linux targets) |
| **`float16` on a droplet without F16C** | x86-64-v3 baseline; runtime CPUID abort |

---

## 9. Out of scope

- **MPK containment** (spec §15.4.13.5). The first hosted port has no hardware memory protection; hosted targets may omit it. Follow-on after Phase 5.
- **Direct object emission** (`chip/x86_64` encoders). Text assembly stays; `platform/` and `regs/` are shaped to be replaced by the encoder layer later.
- **Any Apple or AArch64 backend refactor**, including the `emitter_common/` consolidation of the 27 neutral files.
- **Windows and the RISC-V hosted path** (ROADMAP "Later paths").

---

## Appendix A — OS and ISA surface: `linux_aarch64` → `linux_x86_64`

The Darwin → Linux column of the old appendix is done by the AArch64 port; what remains is ISA-shaped.

| Item | `linux_aarch64` | `linux_x86_64` |
| --- | --- | --- |
| libc calls (`malloc`, `free`, `_exit`, `pthread_*`, `sigaction`, `__sigsetjmp`, `siglongjmp`, `mmap`) | undecorated, `BL sym` | undecorated, `call sym`; `rsp` 16-aligned; `rax` = 0 vector registers before variadic calls |
| Locks, waits | futex shims with `LDAXR`/`STLXR`, `svc` 98 | futex syscall 202, `lock cmpxchg` / `xchg` |
| Thread id | `gettid` 178 | `gettid` 186 |
| `write` | `MOV X8, #64; SVC #0`, `X8` saved around it | `mov eax, 1; syscall`; `rcx`, `r11` clobbered |
| `mmap`, `munmap`, `mprotect` | 222, 215, 226; `MAP_ANONYMOUS = 0x20` | 9, 11, 10; `MAP_PRIVATE\|MAP_ANONYMOUS = 0x22`, `MAP_FIXED = 0x10` |
| Process exit | `exit_group` 94 | `exit_group` 231 |
| Fault bridge | `SIGSEGV` 11 / `SIGBUS` 7, `si_addr` +16, PC `ucontext+440`, SP `+432` | same signals and `si_addr`; `RIP` at `ucontext+168`, `RSP` at `+160`, `RBP` at `+120` |
| Fatal reports (spec §15.4.5.5) | `silica_rt_print_fault_site` + `exit(70)` today; `_exit(70)` as decided 2026-09-19 (spec §15.4.5.5); runtime aborts `silica_rt_abort_with` (`BL`, pc = `X30 - 4`) + `_exit(71)` | the same routines; the abort's pc is the return address `- 5` (`call rel32`); see [runtime_failure_reporting.md](runtime_failure_reporting.md) |
| `sigjmp_buf` | 312 bytes | 200 bytes (448-byte slot unchanged) |
| Topology (`silica_rt_sysctlbyname`) | `sysconf`, `getauxval(AT_HWCAP)` | `sysconf`, `cpuid` leaves 1/7 (no HWCAP on x86) |
| Relocations | `adrp` + `:lo12:` | `lea r, [rip + sym]`, `QWORD PTR [rip + sym]`, `OFFSET sym` |
| Sections | `.rodata,"a",%progbits` … | same names with `@progbits`; `.type sym,@function`; `.size` |
| Comments, locals | `//`, `L_…` | `#`, `.L…` |
| Arch directive | `.arch armv8.2-a+fp16` | none; `.intel_syntax noprefix` |
| Link | `cc -no-pie -rdynamic`, `crt1` → `main` | same, plus `-lpthread` in the trials |
