# `emitter/linux_aarch64/` — Linux AArch64 (64-bit Raspberry Pi OS) emitter

Ported from `emitter/apple_silicon_mac/` (same ISA, different OS). Build with
`make TARGET=linux_aarch64` in `src/`; the resulting `silica-compiler` emits GNU/ELF
AArch64 assembly text (`.sams`) for `as`/`gcc` on a Debian-family AArch64 host. Instruction
selection is unchanged; everything Darwin-shaped was replaced. Design notes and the gate plan:
`design_documents/ports/linux_aarch64_port_checklist.md`.

## What changed relative to `apple_silicon_mac`

| Area | Darwin | Here |
| --- | --- | --- |
| Relocations | `sym@PAGE` / `sym@PAGEOFF`, `.loh` hints | `sym` / `:lo12:sym`; no hints |
| Sections | `__TEXT,__text`, `__TEXT,__rodata`, `__TEXT,__cstring`, `__DATA,__bss`, `__DATA,__const`, `__DATA_CONST,__const`, `__DATA,__data`, `__DATA,__silica_modpfx` | `.text`, `.rodata`, `.rodata`, `.bss`, `.data.rel.ro`, `.data.rel.ro`, `.data`, `.rodata.silica_modpfx` |
| Directives | `.align N` (power of two), `.comm sym,len,log2`, `.subsections_via_symbols` | `.p2align N`, `.comm sym,len,bytes`, dropped |
| Comments | `; text` | `// text` (`;` separates statements in GNU as) |
| Symbols | `_silica_*`, `_malloc`, `_free`, C symbols `_name` | undecorated (`mach_o_c_symbol` is the identity) |
| Syscalls | `MOV X16, #4; SVC #0x80` (write), Darwin mmap/munmap numbers, `MAP_ANON = 0x1000` | `MOV X8, #64; SVC #0` with X8 saved/restored around it (X8 is scratch in the hand-written helpers), mmap 222 / munmap 215, `MAP_ANONYMOUS = 0x20`, failure = negative return |
| Darwin-only runtime APIs | `os_unfair_lock_*`, `__ulock_wait/wake`, `sysctlbyname`, `pthread_mach_thread_np` + `thread_policy_set`, `pthread_set_qos_class_np` | shims in `terms/linux_rt_shims_asm.silica` (futex mutex, futex wait/wake, sysconf/HWCAP-backed sysctl table, `pthread_setaffinity_np`, no-op QoS) |
| Fault bridge | Darwin `stack_t`, 16-byte `struct sigaction`, `SA_ONSTACK|SA_SIGINFO = 65`, SIGBUS = 10, PC via `uc_mcontext->__ss.__pc`, `si_addr` at +24 | Linux layouts in `terms/ffi_fault_runtime_asm.silica`: 152-byte `struct sigaction`, flags `0x08000004`, SIGBUS = 7, PC at `ucontext+440`, `si_addr` at +16 |
| setjmp | `_sigsetjmp` / `_siglongjmp` | `__sigsetjmp` / `siglongjmp` (glibc; the 448-byte slot holds glibc's 312-byte `sigjmp_buf`) |
| `select(2)` timeval | 8-byte `tv_sec` + 4-byte `tv_usec` | two 8-byte fields |

`.sams` emitted for this target assemble with `clang --target=aarch64-unknown-linux-gnu -c` on macOS,
which is how the port was checked without a Linux box; they cannot be linked or run on macOS.

## Linking on the Pi

Link normally (crt1 calls `main`; no `_main` alias) with `-no-pie`: pointer tables live in
`.data.rel.ro`, but the emitter still writes absolute `.quad` addresses. Raise the stack limit
in the shell before running the compiler (`ulimit -s unlimited`); the Darwin `-stack_size`
link flag has no Linux equivalent. `src/Makefile` does all of this when the host is
Linux (`HOST_RT_ASM`, `LDFLAGS_STACK`).

## Bootstrap

Historical: the Mac-hosted cross-compiler link `silica-compiler-linux_aarch64` was removed on 2026-10-21; the Pi now builds and runs its own native compiler (silica-999966-linux-aarch64). The steps below are the original bring-up method.

1. macOS: `make TARGET=linux_aarch64 EXECUTABLE=silica-compiler-linux_aarch64 INSTALL_SELFHOST=0`
   builds a macOS-hosted cross compiler that emits Linux assembly.
2. Run it over `src/` (its `silica.config`) to produce the Linux `.sams` tree, copy the
   tree plus `src/runtime_asm/linux_aarch64/` to the Pi.
3. Pi: `make objects executables` (or assemble/link by hand) → a Pi-native `silica-compiler`
   that emits Linux. From there the Pi self-hosts.

## Verification done so far (2026-09-11, macOS host only)

- Cross compiler `src/silica-compiler-linux_aarch64` built from this tree (seed:
  `binaries/silica-999989-macos-applesilicon`; the newer 999990 selfhost crashes in the effect checker
  on `control.silica` for both emitter trees, so it is a compiler bug, not a port issue).
- 390 emitted `.sams` files from 18 `trials/` directories (base, actors, strings, floats 16/32/64,
  int64, lists, records, case, memory regions, recursion, ...) all assemble with
  `clang --target=aarch64-unknown-linux-gnu -c`. Not linked or run: no Linux box was available.
- `../../../design_documents/ports/pi_bundle_base/` holds the emitted `trials/base` program plus the
  emitted runtime, with a `build_on_pi.sh` that assembles, links and runs it on the Pi. It lives
  outside `src/` on purpose: the build assembles every `.sams` under that tree and links
  every `.o`, so a trial program parked inside it collides with the compiler's own `main`.
- Emitting the compiler's own `.sams` tree with the cross compiler stops at
  `emitter/linux_aarch64/control/control.silica` with the same effect-checker crash (it is built
  from the current sources, which carry the bug). Once that fix lands, `make assembly
  TARGET=linux_aarch64 SILICA_COMPILER=./silica-compiler-linux_aarch64` produces the tree for the Pi.

## Known gaps

- Trial Makefiles under `trials/` still link with Apple `-e main` flags; golden `.ascomp` files are Darwin text.
- Every module prelude declares `.arch armv8.2-a+fp16` (float16 prims emit half-precision FCMP/FDIV); pre-ARMv8.2 hosts are not targeted.
- Actor priorities map to no-ops; core pinning honours numeric core ids only.
- `hw.*cachesize` answers come from `sysconf(3)`, which returns 0 on most AArch64 glibc builds, so cache levels report empty.
