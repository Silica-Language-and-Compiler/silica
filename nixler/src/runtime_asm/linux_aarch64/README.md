# `runtime_asm/linux_aarch64/` — hand-written runtime assembly, Linux AArch64

Linked into `silica-compiler` when `src/` is built on a Linux host (64-bit Raspberry Pi OS or
any Debian-family AArch64 system). `src/Makefile` lists these files in `HOST_RT_ASM`; the
macOS equivalents stay at the `src/` root.

| File | Linux counterpart of | Differences |
| --- | --- | --- |
| `silica_rt_shim.s` | `../../silica_rt_shim.s` | ELF symbol names (no leading `_`), `.rodata`, `:lo12:` relocations |
| `deviceio_link_thunks.s` | `../../deviceio_link_thunks.s` | ELF symbol names; mmap is syscall 222 with `MAP_PRIVATE\|MAP_ANONYMOUS` = `0x22`, failure is a negative return |

No `main_entry_alias.s` here: glibc's `crt1.o` calls `main` directly.

Keep each file in step with its macOS counterpart. A change to one without the other links on one
platform only.
