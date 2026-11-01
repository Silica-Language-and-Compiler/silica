# `emitter/linux_x86_64/regs/` — register and frame model (System V AMD64)

**Status:** decided 2026-09-18 (Step 0.5 of
[porting_to_linux_x86_64_hosted.md](../../../../design_documents/porting_to_linux_x86_64_hosted.md)),
**revised the same day to the virtual-register method** once the ESP32-S3 port had shown that the
emitter's register-bound logic ports as a *home table* rather than as a rewritten allocator. The
first version of this file planned a new allocator (`frame_plan`, a 40-byte save area, staged call
arguments); that plan is withdrawn. What survives from it is everything about the C boundary (§5),
the OS surface (§6), the CPU baseline (§7) and the assembler text (§8).

**One sentence:** the emitter keeps naming values `X0`–`X30`, `W<n>`, `D/S/H<n>`, `SP`, `XZR` and
`[X29, #-N]` exactly as on AArch64; on this target those are **virtual registers** that
`shared/x86_vr.silica` maps to homes (a machine register or a per-frame slot), and
`shared/x86_isa.silica`, `x86_mem.silica`, `x86_float.silica` expand each AArch64-meaning operation
into x86-64 text — so every register decision the emitter has ever debugged stays valid, and no
converted file spells a machine register.

## 1. Why a home table and not a new allocator

The AArch64 emitter is register-bound in its text: `outer_reg` strings such as `|name=X21`,
`|_tuple_sret=X20`, `[X29, #-48]` are read back by `var@is_reg_bound`, `find_reg_pref_binding` and
friends; the frame is a set of pressure predicates that decide which `X19`–`X28` pairs a function
saves. Rewriting that against SysV's five callee-saved registers would have replayed every
SP-corruption defect in the project's memory. The virtual-register method (proved by the
`ESP32-S3_raw` port, [esp32s3_xtensa_port.md](../../../../design_documents/ports/esp32s3_xtensa_port.md) §2–§4)
leaves the logic alone: a site conversion is `"    ADD dest, X9, X10"` → `x86_isa@x86_add(dest, "X9", "X10")`.

## 2. Home table

| VR | Home | Why |
| --- | --- | --- |
| `X0`–`X5` | `rdi rsi rdx rcx r8 r9` | the SysV argument registers: a Silica call stages nothing, and calls into C need no moves for the first six arguments |
| `X6`, `X7` | `r14`, `r15` | the 7th and 8th arguments (148 compiler functions have them); SysV would put them on the stack, the internal convention keeps them in registers |
| `X8` | `rbx` | the aggregate-return (`sret`) pointer; must cross a call |
| `X9`, `X10` | `r10`, `r11` | the binary-prim operand temps |
| `X11`–`X28` | frame slots `[rbp - SVR_X<nn>]` | 8 bytes each; `X19`–`X28` get callee-saved semantics for free (each frame has its own copy), `X11`–`X17` are per-frame temps |
| `X29` | value `rbp - SVR_AREA` | the top of the emitter's `[X29, #-N]` slot area; `[X29, #-N]` is `[rbp - SVR_AREA - N]`; read-only |
| `X30` | none | the return address is `[rbp + 8]`; only `control.silica` deals with it |
| `SP` | `rsp` | real pushes and pops; every AArch64 push is 16 bytes, so `rsp` stays 16-aligned at every `call` |
| `XZR`/`WZR` | reads 0, writes discarded | |
| `D0`–`D7` (`S`/`H` alias the low bits) | `xmm0`–`xmm7` | SysV float arguments and result |
| `D8`–`D31` | frame slots `[rbp - SVR_D<nn>]` | `D8`–`D15` callee-saved for free |
| scratch | `rax`, `r12`, `r13`, `xmm8`–`xmm11` | helpers only; nothing is live in them between helpers |

**The result of every call is `X0` = `rdi`, not `rax`.** Internal calls are SysV for the arguments
and `rdi` for the result; `x86_isa@x86_call_c` moves `rax` into `rdi` after a C call. Nothing
survives a call except `rbp`, `rsp` and the frame (the callee-saved VRs are slots), so the runtime
routines written by hand may clobber every register and keep their own state in their frames; calls
INTO Silica code clobber `rbx`, `r12`–`r15` (homes and scratch).

Ordinal carry-over of fixed roles is therefore automatic: `X19` (first shadowed parameter), `X20`
(tuple `sret` hold, actor reply buffer), `X21` (second GPR parameter shadow) are slots; the markers
(`|_tuple_sret=`, `|_callee_sret=`, `|_broot=`, `|_aggb=`) keep their names and values unchanged.

**W writes.** A `W` destination is written with a 32-bit `mov` (zero-extending) into its register, or
as a zero-extended 8-byte store into its slot; 8/16-bit sub-registers are only ever *stored* to
memory (`STRB`/`STRH`), never written as registers.

## 3. Frame

```
[rbp + 8]                 return address
[rbp]                     caller's rbp                 (the standard x86-64 chain: gdb, dladdr walk it)
[rbp - 8 .. rbp - SVR_AREA)   VR homes the body references: SVR_X<nn>, SVR_D<nn>, SVR_CS0..4 (main only)
[rbp - SVR_AREA - N]      the emitter's [X29, #-N] slots, aggregate regions, case-bind slots ...
                          allocated by the emitter's own SUB SP (frame_spill_alloc), exactly as on AArch64
rsp                       moves with the emitter's pushes ([SP, #-16]! / [SP], #16) and slabs
```

- Prologue (`control@function_prologue`): `push rbp; mov rbp, rsp; sub rsp, SVR_AREA`. Epilogue:
  `leave; ret` (`LDP X29, X30, [SP], #16` required `SP == X29` there, which `leave` enforces). Tail
  transfer: `leave; jmp`.
- `SVR_AREA` and the `SVR_*` offsets are `.set` symbols `emitter_core@x86_frame_header` emits in front
  of each function after its body is known (both assemblers accept per-function redefinition and
  absolute symbols in displacements): only homes the body references get a slot; `SVR_AREA` is
  rounded to 16 so the alignment discipline is untouched.
- The `STP X19, X20, [SP, #-16]!` … pushes and their `LDP` pops of the AArch64 prologue/epilogue are
  emitted as nothing: slot-homed VRs need no save. The emitter's own slot area (`frame_spill_alloc`)
  and every `[SP, #k]` reference are unchanged, so the AArch64 layout carries over shifted by
  `SVR_AREA`.
- Program `main` is called by glibc's `crt1` under the C ABI: `control@function_prologue_main_with_effects`
  parks `rbx r12 r13 r14 r15` in five reserved slots (`SVR_CS0`–`SVR_CS4`) and the main epilogue
  restores them and moves the result into `rax`. `main` never tail-transfers.
- Nothing of the earlier plan's "fixed 40-byte save area", `frame_plan`, "arguments staged then
  loaded" or "the 7th/8th arguments in an outgoing area" exists.

## 4. Flags and the helper contract

x86 arithmetic sets the flags where AArch64's plain `ADD`/`SUB`/`MOV`/`LDR` do not, and the emitter
does put moves, loads, stores, frame-address computations and SP pushes between a `CMP` and its
`B.cond`/`CSET`/`CSEL`. Rule: every helper that stands for a non-flag-setting AArch64 instruction is
**flag-transparent** (`mov`/`lea`/`movzx`/`movsx`/`movq`/`setcc`/`cmovcc` only; `ADD SP, SP, #n` and
`SUB X16, X29, #n` are `lea`). The flag-setting helpers are the arithmetic ones (`x86_add` … `x86_bic`,
shifts, division) and `x86_cmp`/`x86_fcmp`. After an `FCMP` the consumer must be the float variant
(`x86_fcset`/`x86_fbcond`): `ucomisd`'s ZF/PF/CF encode the four outcomes differently from NZCV, and
the AArch64 conditions that include or exclude "unordered" are reproduced with `PF` tests.

Division: `idiv` needs `rdx:rax`; `rdx` is `X2`, so it is saved around the operation, and the two cases
x86 faults on (`x / 0`, `INT_MIN / -1`) are tested first and given the AArch64 results (0 and wrap).
Shifts by a register go through `cl` with `rcx` (`X3`) saved.

## 5. The C boundary (System V AMD64 at every foreign call)

- `x86_isa@x86_call_c(sym, nfp, nstack)`: the first six integer arguments are already in place (`X0`–`X5`
  homes = SysV), `X6`/`X7` are pushed for a 7- or 8-argument callee, `al` = the number of vector
  registers used, `rsp` is 16-aligned at the `call` (the AArch64 16-byte push discipline guarantees
  it), and the result is moved from `rax` to `rdi`. `abort`, `free`, `malloc` and the foreign
  bindings of `ffi_foreign` go through it.
- Aggregate returns to C (MEMORY class, the 32-byte foreign result records): the hidden pointer is
  `rdi`, shifting the integer arguments: `ffi_foreign@emit_sret_hidden_arg_shift` moves `X(n-1)` →
  `Xn` … `X0` → `X1` and the arena buffer `X8` → `X0` right before the guarded call, and
  `c_call_stack_args` counts the hidden argument (until 2026-09-19 the buffer went only in `X8`,
  AArch64-style, and C wrote the record over the first argument); internal aggregate returns keep
  `X8` = `rbx`.
- Signal handlers, thread start routines and `pthread_key` destructors are C-called: `rdi rsi rdx`
  arguments, `rax` result, `rbx rbp r12`–`r15` preserved.

## 6. Threads, signals, TLS, actor stacks

- pthreads and TLS through glibc exactly as `linux_aarch64` (`pthread_key_*`, no `fs:` access).
- Locks and waits are the `linux_rt_shims_asm` futex shims with `lock cmpxchg` / `xchg`, futex syscall 202.
- Actor stacks keep the `prims_actors_stack_asm` design: one inaccessible reservation per actor, a
  synchronous `SIGSEGV` handler on a per-thread `sigaltstack` commits chunks, releases are `MAP_FIXED`
  remaps to `PROT_NONE`, and the runtime switches `rsp` onto the actor stack (ACB `#480` holds the
  runtime `rsp`). Layouts, verified on nix with a C program on 2026-09-18:

  | Item | Linux x86-64 |
  | --- | --- |
  | `siginfo_t.si_addr` | `+16` (size 128; `si_signo` 0, `si_errno` 4, `si_code` 8) |
  | `ucontext_t` (968 B) | `gregs[]` at `+40`: `RDI +104`, `RBP +120`, `RAX +144`, `RSP +160`, `RIP +168`, `ERR +192`, `TRAPNO +200`, `CR2 +216`; `uc_stack +16` |
  | `struct sigaction` | 152 B: handler `+0`, mask `+8`, flags `+136`, restorer `+144`; `SA_SIGINFO\|SA_ONSTACK = 0x08000004` |
  | `stack_t` | 24 B: `ss_sp +0`, `ss_flags +8`, `ss_size +16`; `MINSIGSTKSZ` 8192 |
  | signals | `SIGSEGV` 11, `SIGBUS` 7, `SIGILL` 4, `SIGFPE` 8 |
  | `sigjmp_buf` | 200 B (the 448-byte slot still fits); `__sigsetjmp` / `siglongjmp` by name |
  | `struct sysinfo` | 112 B: `totalram +32`, `totalswap +64`, `mem_unit` (u32) `+104` |
  | `struct timeval` / `timespec` | two 8-byte fields |
  | `sysconf` | `_SC_PAGESIZE` 30, `_SC_NPROCESSORS_ONLN` 84, `_SC_PHYS_PAGES` 85, cache sizes 188/191/194 |
  | syscalls | `write` 1, `mmap` 9, `mprotect` 10, `munmap` 11, `madvise` 28, `sigaltstack` 131, `gettid` 186, `futex` 202, `sched_setaffinity` 203, `clock_gettime` 228, `exit_group` 231 |
  | `mmap` flags | `MAP_PRIVATE\|MAP_ANONYMOUS = 0x22`, `MAP_FIXED 0x10`, `MAP_NORESERVE 0x4000`; `MADV_FREE 8` |

- The `main` thread is not an actor (spec §15.1.2.2) and stays on the platform stack; no `ulimit`,
  no linker stack flag. The compiler's pipeline runs in an actor, so **the compiler cannot run on
  x86-64 until the actor stack runtime works there** — this orders the debug phase (see the plan).

## 7. CPU baseline

x86-64-v2 plus F16C: SSE2 scalar float, SSE4.1 `roundsd` (`FRINTZ`), F16C `vcvtph2ps`/`vcvtps2ph`
for `float16` (computed in `float32`; bit-identical for `+ − × ÷ √`). No BMI2/AVX2/LZCNT is emitted
(shifts go through `cl`). nix (Ryzen 5 PRO 3400G) and the DigitalOcean classes have F16C; a CPUID
check at startup is still to do (debug phase).

## 8. Assembler text (summary; the shared layer owns the syntax)

- First line of every unit: `.intel_syntax noprefix`. Destination first.
- **Comments are `#`.** GNU `as` accepts a `//` at the start of a line but rejects a trailing
  `// text` after an instruction (measured on nix 2026-09-18); clang accepts both. Emitted text uses `#`.
- Both GNU `as` 2.42 and clang 18 must accept every unit: `shared/selftest/run_selftest.sh` emits one
  instance of every helper and assembles the result with both (1181 lines, clean on 2026-09-18).
  `movsxd r64, r32`, never `movsx r64, r32`. `%progbits` and `@progbits` are both accepted; emitted
  text uses `@progbits`.
- Sections as on `linux_aarch64` (`.text`, `.rodata`, `.data.rel.ro`, `.bss`, `.rodata.silica_modpfx`);
  `.section .note.GNU-stack,"",@progbits` closes every unit; definitions `.globl` so `-rdynamic`
  exports them for the failure banner's `dladdr`; labels keep the `L_…` spelling of the AArch64 tree.
- Link `-no-pie -rdynamic -lpthread` through `cc` with `crt1.o` calling `main`.

## 9. Lint (debug phase)

A converted emitter file must contain no machine register literal
(`\b(r[a-z0-9]{1,3}|e[a-d]x|e[sd]i|xmm[0-9]+)\b`) and no AArch64 mnemonic inside an emitted string;
the hand-written runtime chunks (`*_asm.silica`, `print_*_inline`, `string_*`, the `L_*` helper bodies
in `prims_list`/`prims_memory`, `module_linkage`'s trampolines) are the only places machine registers
appear. Every emitted unit must assemble with both assemblers.
