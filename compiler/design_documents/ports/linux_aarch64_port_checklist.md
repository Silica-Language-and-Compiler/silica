# `linux_aarch64` port checklist

**Status:** Done through G7; this document is now the record of how the port was made (2026-10-16). `src/emitter/linux_aarch64/` is complete and self-hosts on the Pi: the fixed-point log of the 2026-10-16 build (`/Volumes/2T/silica_builds/20261016-052517/remote-linux_aarch64.log`) ends "349 units compared, 0 emitted differently by gen2 than by gen1 ... gen3 is byte-identical to gen2". The Linux AArch64 goldens are `<stem>.linux_aarch64.ascomp` beside the shared `.scout` files (§4). Later chunks are built in lock-step with Apple Silicon ([ROADMAP.md](../../../ROADMAP.md)); builds, fixed points and trial runs on the Pi go through `programmer_tools/` (`build_all_platforms.sh`, `rebuild_refresh_verify.sh`, `sync_to_hosts.sh`). The sections below keep the pre-port inventory and the measurements of 2026-09-11 (counts of sites and goldens are as measured then), and the original gate plan. This document is a **checklist for one hosted port**, not a specification. Where it disagrees with [silica-specification.md](../silica-specification.md), the specification wins.

**Audience:** whoever adds `emitter/linux_aarch64/` and brings a self-hosting `silica-compiler` up on 64-bit Raspberry Pi OS (or any Debian-family AArch64 host).

**One-line summary:** same ISA, different OS. Instruction selection carries over from `apple_silicon_mac` unchanged; everything Darwin-shaped — syscalls, symbol decoration, relocation syntax, sections, entry point, link flags — does not.

## Related documents

| Document | Role here |
| --- | --- |
| [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) | The **OS-free** port plan. Explicitly **out of scope** here: no board pack, no MMIO, no boot stub |
| [execution-environments-hosted-vs-bare-metal.md](../execution-environments-hosted-vs-bare-metal.md) | Why a hosted port makes **no** per-`Space` hardware promise |
| [memory-effects-aarch64-implementation-plan.md](../memory-effects-aarch64-implementation-plan.md) | `Space` mapping; on hosted Linux the kernel owns the policy |
| [silica-compiler-code-organization.md](../silica-compiler-code-organization.md) | Where emitter sources live |
| [ROADMAP.md](../../../ROADMAP.md) | Ranks Linux AArch64 first in the attention order |

---

## 1. Scope

**In scope:** a `silica-compiler` that runs on 64-bit Raspberry Pi OS and emits ELF objects for the same, self-hosting on the Pi without the Mac in the loop.

**Out of scope, deliberately:**

- Board packs, linker scripts, reset stubs, volatile MMIO. Hosted Linux is a process under a kernel; none of the [OS-free port](../porting_for_os_free_targets.md) apparatus applies. The one exception: when ESP32-S3 reaches FP1, this emitter must reject the poke prims (`map_device`, `peek`, `poke`) with a compile error, in lock-step with Apple Silicon ([porting_for_os_free_targets.md §5.5](../porting_for_os_free_targets.md)). *As built:* the shared pre-emit pass `sir_generator/sir_target_verify.silica` reports E2220 through `emitter_core@unsupported_prim_reason`, and the emitter's `terms/prims/prims.silica` catch-all writes an `.error` line naming the prim.
- Per-`Space` hardware guarantees. On a hosted target `mem(Space)` is discipline and API clarity, not a cache-attribute promise (spec §12.1.1.0).
- Cross-linking from macOS. §6 avoids needing a cross toolchain at all.
- 32-bit ARM. `armv7l` is not this port and not on the roadmap.

**Why first:** this port splits "not Darwin" from "not AArch64." Every later port needs one or the other. Doing them together — as an ESP32-S3-first plan would — means cutting that seam under the worst possible conditions.

---

## 2. Naming

Pick **`linux_aarch64`**. Delete `aarch64_debian` from the candidate list in [`emit_target.mk`](../../src/emit_target.mk) line ~37; two names for one backend is a trap, and nothing in the emitter is Debian-specific.

Keep the two axes separate — [`src/Makefile`](../../src/Makefile) line ~368 already draws this distinction and it must survive:

| Axis | Where it lives | Value for this port |
| --- | --- | --- |
| **Emit target** — what the compiler generates | `emitter/<TARGET>/`, written to `silica.target` | `linux_aarch64` |
| **Host tag** — where the compiler runs | `binaries/silica-NNNNNN-<platform>` | `debian-aarch64` (already in `CANONICAL_PLATFORMS`) |

`debian-aarch64` is already understood by [`binaries/update_silica_compiler_link.bash`](../../../binaries/update_silica_compiler_link.bash). No new wiring is needed in either file beyond the deletion above.

---

## 3. Darwin-ism inventory

Counts are over `emitter/apple_silicon_mac/**/*.silica` (113 source files; `emitter_core.silica` is 2462 lines). `.sams` files in that tree are **generated output**, not sources — do not port them by hand.

### 3.1 Syscalls — 22 sites, 12 files

The inline syscall surface is **exactly one call: `write`.** Everything else reaches the OS through libc (§3.6), so this is far smaller than it first looks.

| | Darwin | Linux AArch64 |
| --- | --- | --- |
| Syscall number register | `X16` | `X8` |
| Trap | `SVC #0x80` | `SVC #0` |
| `write` | `4` | `64` |
| Error convention | carry flag set, positive errno | negative errno in `X0` |

Emitted as `MOV X16, #4` / `SVC #0x80`. Sites:

`terms/print_string_inline.silica` (6) · `print_int64_inline.silica` (3) · `print_atom_inline.silica` (2) · `print_bool_inline.silica` (2) · `string_substring_mmap_nomte.silica` (2) · `print_float16/32/64_inline.silica`, `print_int8/16/32_inline.silica`, `string_concat_mmap_nomte.silica` (1 each)

None of the emitted helpers inspect the syscall result, so the error-convention difference is currently inert. Note it anyway: the first emitted call that *does* check a return value must not assume Darwin's carry-flag convention.

### 3.2 `X8` hazard — audit every `SVC` site

`X8` is used as a general scratch register in the hand-written helper strings (26 occurrences: 17 `MOV X8`, 4 `LDR X8`, 3 `STR X8`, 2 `ADD X8`). On Darwin that is free, because the syscall number lives in `X16`. **On Linux, `MOV X8, #64` clobbers it.**

In the helpers spot-checked during this inventory (`L_pi_helper`, `L_pu_helper`, `L_pf32_helper`, `L_pf64_helper`) `X8` happens to be dead at the syscall — it is read into `X1` or `X2` on the preceding line. That is luck, not a property. **Every one of the 22 sites needs an explicit "is `X8` live here?" check**, and the answer must be recorded, because these are string literals with no register allocator to catch a mistake.

Two related notes: `X8` is also AAPCS64's indirect result location register (XR), which matters if aggregate returns to C are ever added; and `X16`/`X17` remain IP0/IP1 scratch on both platforms, so the two existing `MOV X16, #<computed>` sites (`emitter_core.silica:1901`, `terms/var.silica:274`) are **not** syscall setups and must not be mechanically rewritten by a search-and-replace on `X16`.

### 3.3 Symbols

Narrower than expected. Generated user code is **already undecorated** — `trials/base/test.ascomp` shows `.global main` / `main:`, no underscore. Only the runtime/libc boundary is Darwin-decorated:

- **34 distinct `BL _symbol` callees** — `_malloc`, `_free`, `_abort`, and 31 `_silica_rt_*` / `_silica_*` runtime entry points. Drop the leading underscore.
- Matching `.globl _silica_rt_*` **definitions** inside the runtime-asm emitter files (`terms/*_runtime_asm.silica`, `terms/checked_int64_runtime_asm.silica`, `atoms/…`). Drop it there too, in the same commit — a half-renamed boundary links on neither platform.
- `.extern` directives are a harmless no-op in GNU as; leave or drop.
- Local labels are emitted as `L_pa_helper`, `L_pi_loop`, etc. GNU/ELF wants a **`.L` prefix** for a label to be assembler-local; plain `L_` assembles fine but lands in the symbol table. Cosmetic, but it makes every `nm` and profile noisy — fix it during the port, not after.

### 3.4 Relocations — 317 sites, 31 files

| Darwin | GNU/ELF |
| --- | --- |
| `ADRP X1, sym@PAGE` | `adrp x1, sym` |
| `ADD X1, X1, sym@PAGEOFF` | `add x1, x1, :lo12:sym` |
| `LDR D3, [X8, sym@PAGEOFF]` | `ldr d3, [x8, :lo12:sym]` |

Both `@PAGE`/`@PAGEOFF` forms and the load-with-addend form appear. This is the single largest mechanical edit in the port; it is also the most amenable to being centralized behind one helper function rather than spread across 31 files, and doing so is what makes the ESP32-S3 port cheaper later.

Also delete the Darwin **linker-optimization hints** (`Lloh` labels, `.loh AdrpAdd`) — Mach-O only.

### 3.5 Sections and alignment — 53 sites

| Darwin | GNU/ELF |
| --- | --- |
| `.section __TEXT,__rodata` | `.section .rodata,"a",@progbits` |
| `.section __DATA,__const` | `.section .rodata` (or `.data.rel.ro`) |
| `.section __DATA,__silica_modpfx,cstring_literals` | `.section .rodata.str1.1,"aMS",@progbits,1` |
| — | add `.type sym,%function` and `.size sym,.-sym` |

The module-prefix section at `module_linkage.silica:156` is the one that needs thought rather than translation: it is a Mach-O section with a custom name used for module linkage, and the ELF equivalent should be chosen deliberately.

**Normalize `.align` to `.p2align` everywhere while you are in here.** `.p2align N` means the same thing to both assemblers; `.align` does not, and the existing `.align\t8` / `.align\t4` sites are exactly the kind of thing that silently produces a different layout on the new target.

### 3.6 Hand-written assembly — 3 files

| File | Lines | Disposition |
| --- | --- | --- |
| [`src/main_entry_alias.s`](../../src/main_entry_alias.s) | 5 | **Delete for this target.** Its own comment says why: *"Apple ld expects C entry `_main`."* Linux does not |
| [`src/silica_rt_shim.s`](../../src/silica_rt_shim.s) | 236 | Port. Good news: it calls **libc** (`_malloc`, `_free`, `_write`, `_open`, `_read`, `_lseek`, `_close`, `_unlink`), not raw syscalls — so it ports by dropping underscores and fixing local labels. No syscall-number work |
| [`src/deviceio_link_thunks.s`](../../src/deviceio_link_thunks.s) | 131 | Port. Same treatment: underscores and label prefixes |

Because the shim goes through libc, Linux AArch64's lack of an `open` or `stat` *syscall* (it has only `openat`/`fstatat`) is a **non-issue** — glibc still exports `open()`. It becomes an issue only if file I/O is ever inlined as syscalls the way `write` is.

### 3.7 Entry point, linking, and stack

- **Entry point.** The Darwin link uses `-e main`, bypassing crt. Do that on Linux and glibc never initializes: `malloc` and pthreads are broken from the first call. **Link normally** and let `crt1.o`'s `_start` call `main`.
- **PIE.** Debian defaults to position-independent executables. Link `-no-pie` for first light; GOT-indirect access to preemptible globals (`adrp x0, :got:sym` + `ldr x0, [x0, :got_lo12:sym]`) is a later refinement, not a bring-up blocker.
- **Stack size.** `project_makefiles/Makefile`'s `LDFLAGS_STACK ?= -Wl,-stack_size,0x10000000` is Darwin-only, and the comment explains it is there because modules recurse deeply. On Linux the equivalent is a `setrlimit(RLIMIT_STACK)` at startup or running the real work on a pthread with an explicit stack size. **This will surface as a segfault in a deep parse, not as a link error** — decide it before bring-up rather than debugging it later.
- **Runtime locks.** `__silica_runtime.sams` uses `os_unfair_lock` and Darwin threads. glibc supplies `calloc`/`pthread_create` unchanged; the lock becomes a futex. The ACB already carries a futex sequence word (see the Phase E comment around line 52), so the concept is in place.
- **Assembler and linker.** `clang -c -x assembler` and the `rust-lld -flavor darwin` path in `project_makefiles/Makefile` and the 38 trial Makefiles both assume Darwin. Native `as`/`gcc` on the Pi is the simplest substitute.

---

## 4. Do this before writing any emitter code

`trials/` holds **1357 `.ascomp` goldens** across 38 trial directories, every one of them Darwin assembly text. The comparison is hardcoded:

```make
elif ! diff -Bw -q "$$sams" "$$base.ascomp" > /dev/null 2>&1; then
```

A `linux_aarch64` emitter fails all 1357 on day one, **for the right reason**, which makes them useless as a signal for the entire duration of the port.

Required change, in order:

1. **De-duplicate first.** The integrate rule is copy-pasted into **38 near-identical per-trial `Makefile`s** (they differ, so this is 38 edits, not one). Hoist it into a shared include alongside `trials/Makefile` before adding a target axis, or the axis lands 38 times too.
2. **Add the target axis.** `test.ascomp.linux_aarch64` beside `test.ascomp`, or a per-target subdirectory. Fall back to the unsuffixed name so `apple_silicon_mac` keeps working untouched. *As built:* `<stem>.linux_aarch64.ascomp` (for example `trials/base/test.linux_aarch64.ascomp`), derived by `trials/silica_compiler.mk` as `ASCOMP_EXT`; the Apple goldens keep the plain `.ascomp` name.
3. **Keep the 1207 `.scout` files shared.** Expected *program output* is target-independent. These are the real cross-target conformance suite and the thing that actually proves the port correct — an emitter can produce entirely different assembly and still be right, and `.scout` is what says so.

Getting this wrong is the highest-cost mistake available in this port: it ends in a 1357-file golden regeneration that nobody can meaningfully review.

---

## 5. Host prerequisites

Check on the Pi before starting:

- `uname -m` must print `aarch64`. Raspberry Pi OS still ships a 32-bit image and this is an easy, expensive trap.
- Available RAM against what the macOS build actually peaks at. [`thin_dispatchers_for_compile_ram.md`](../../tutorials_and_howtos/thin_dispatchers_for_compile_ram.md) exists because compile RAM is already a known pain point; a self-host on the Pi is exactly where it resurfaces. Measure the Mac's peak first, then decide about zram or swap.
- `as`, `ld`, and `gcc` present (`build-essential`).

---

## 6. Bootstrap onto the Pi

No cross toolchain on the Mac is required. Because the emit target is baked into the binary (one `emitter_core` per build), one pass produces the Pi-native compiler:

1. **Mac:** `make TARGET=linux_aarch64 assembly` in `src/`. Output `.sams` is now GNU/ELF AArch64 text. It cannot be assembled or run on the Mac — that is expected, not a failure.
2. **Copy** the `.sams` tree to the Pi.
3. **Pi:** assemble and link with native `as`/`gcc`.
4. The result runs on the Pi **and** emits Linux. From here the Pi self-hosts; drop the Mac from the loop.
5. Register the binary in `binaries/` with the `debian-aarch64` tag.

Step 1 is also the first real test of §3: it either produces plausible GNU syntax or it does not, long before anything links.

---

## 7. Verification gates

Each gate is a stop-and-fix point, not a milestone to blow through.

| Gate | Proves |
| --- | --- |
| **G0** | Golden-file axis (§4) merged; `apple_silicon_mac` integrate still fully green |
| **G1** | `make TARGET=linux_aarch64 assembly` completes on the Mac; output assembles with `as` on the Pi |
| **G2** | `trials/base` links and runs on the Pi; `.sout` matches the shared `.scout` |
| **G3** | Print trials pass — validates §3.1 syscall conversion and the §3.2 `X8` audit across all widths |
| **G4** | Deep-recursion trial passes — validates the §3.7 stack decision |
| **G5** | Actor and supervisor trials pass — validates the futex/pthread runtime |
| **G6** | Full `make integrate` green on the Pi against `.ascomp.linux_aarch64` goldens |
| **G7** | **Self-host:** the Pi-hosted compiler rebuilds itself, and the second-generation binary is byte-identical to the first |

G7 is the real completion criterion. G6 only says the output did not change since it was recorded.

---

## 8. Open questions

1. What ELF section replaces `__DATA,__silica_modpfx,cstring_literals` for module linkage (§3.5)?
2. Is the `@PAGE`/`@PAGEOFF` translation centralized behind one helper, or applied across all 31 files? Centralizing costs more now and is what makes the third port cheap.
3. `setrlimit` at startup or a dedicated big-stack pthread for the deep-recursion path (§3.7)?
4. Does `binaries/` need an emit-target slot in the filename scheme? Not for this port — a Linux-emitting compiler runs on Linux and a macOS-emitting one runs on macOS, so the host tag disambiguates. It becomes necessary the moment a **cross**-emitting binary exists, which the ESP32-S3 port will require.
5. Baseline ISA: plain ARMv8.0-A, or may the emitter use LSE atomics? The Pi 5's Cortex-A76 has them; older AArch64 Linux hosts may not.

---

## 9. Design rule

This port is complete when a compiler built on the Pi, from Silica sources, using the Pi-hosted compiler, reproduces itself byte-for-byte and passes the shared `.scout` suite. Assembly-text goldens are a **regression tripwire for one target**, not evidence of a correct port.
