# `runtime_asm/linux_x86_64/` — hand-written runtime assembly, Linux x86-64

Linked into `silica-compiler` when `src/` is built on a Linux x86-64 host (Debian-family
glibc system such as nix.local). `src/Makefile` lists these files in `HOST_RT_ASM` for this
platform; the macOS equivalents stay at the `src/` root and the AArch64 Linux ones in
`../linux_aarch64/`.

| File | Counterpart of | Differences |
| --- | --- | --- |
| `silica_rt_shim.s` | `../linux_aarch64/silica_rt_shim.s` | Intel-syntax x86-64; SysV calls into libc (`rsp` 16-aligned at every call, results moved from `rax` to `rdi`); `{x0, x1}` results are `{rdi, rsi}`; `x19..x24` live in `rbx r12 r13 r14 r15` and one frame slot |
| `deviceio_link_thunks.s` | `../linux_aarch64/deviceio_link_thunks.s` | ELF symbol names; mmap is syscall 9 with `MAP_PRIVATE\|MAP_ANONYMOUS` = `0x22`, failure is a negative `rax`; the raw syscall clobbers `rcx`/`r11` |

Conventions shared with the emitter (`emitter/linux_x86_64/shared/x86_vr.silica`): emitted Silica
code passes arguments in `rdi rsi rdx rcx r8 r9` (then `r14 r15`), takes every result in `rdi`
(never `rax`) and assumes nothing but `rbp`/`rsp` survives a call. The thunks therefore answer in
`rdi`, and the shim routines answer `{success, data}` in `{rdi, rsi}`. Both files also preserve
`rbx r12-r15` like SysV callees, so every routine is C-callable too. Both files are assembled by
GNU `as` and by `clang --target=x86_64-linux-gnu -c -x assembler`, and end with
`.section .note.GNU-stack,"",@progbits`.

No `main_entry_alias.s` here: glibc's `crt1.o` calls `main` directly.

Keep each file in step with its macOS and AArch64 counterparts. A change to one without the others
links on one platform only.
