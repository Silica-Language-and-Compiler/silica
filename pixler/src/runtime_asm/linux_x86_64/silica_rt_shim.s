# runtime_asm/linux_x86_64/silica_rt_shim.s - Linux (glibc, x86-64) build of
# ../linux_aarch64/silica_rt_shim.s: the same four routines in Intel-syntax x86-64.
#
# src links NO Rust libraries. The bootstrap crate's libsilica_compiler.a
# used to supply the runtime; these four symbols are the only ones the seed-built
# objects still reference. They are SCAFFOLDING: src's own emitter already
# emits inline implementations (file_io_inline.silica, print_string_inline.silica),
# so once selfhost compiles itself these become dead and this file can be deleted.
#
# ABI (matches the bootstrap crate's C ABI, carried in the emitter's internal convention):
#   SilicaString { tag: u64 (+0, first byte 0xFF), data: *u8 (+8), length: u64 (+16) }
#   SilicaResult { success: bool (+0), data: *u8 (+8) }  -> returned in rdi / rsi ({x0, x1})
# Every string argument is a SilicaString* (tag = all ones). There is no raw-char*
# form: a string is a byte buffer and may contain 0x00 (spec 4.1.6). Path data is
# length-delimited, so it is copied NUL-terminated before the libc calls.
#
# Calling convention: these routines are called from emitted Silica code (and from the
# deviceio thunks) with arguments in rdi rsi and the result in rdi (second word rsi), never
# rax. libc is called SysV style (rsp 16-aligned at the call, result in rax, then moved to
# rdi). Values live across a libc call sit in rbx r12-r15, which libc preserves and which
# every routine here pushes and pops, so each routine is also a valid C-callable function.
# The AArch64 x19..x24 map onto rbx r12 r13 r14 r15 and one frame slot ([rbp - 48]).

.intel_syntax noprefix
.text
.p2align 4

# rdi = ptr -> rdi = data, rsi = len. Clobbers nothing else.
_shim_get_string:
    test rdi, rdi
    jz Lgs_null
    mov rsi, QWORD PTR [rdi + 16]
    mov rdi, QWORD PTR [rdi + 8]
    ret
Lgs_null:
    xor esi, esi
    ret

# rdi = data, rsi = len -> rdi = malloc'd NUL-terminated copy (0 on failure).
_shim_cpath:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [r12 + 1]
    call malloc
    mov rdi, rax
    test rdi, rdi
    jz Lcp_out
    mov r13, rdi
    xor r14d, r14d
Lcp_loop:
    cmp r14, r12
    jae Lcp_term
    movzx edx, BYTE PTR [rbx + r14]
    mov BYTE PTR [r13 + r14], dl
    add r14, 1
    jmp Lcp_loop
Lcp_term:
    mov BYTE PTR [r13 + r12], 0
    mov rdi, r13
Lcp_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

.globl silica_print_string
silica_print_string:
    test rdi, rdi
    jz Lps_ret
    push rbp
    mov rbp, rsp
    call _shim_get_string
    test rdi, rdi
    jz Lps_out
    test rsi, rsi
    jz Lps_out
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1
    call write
Lps_out:
    pop rbp
Lps_ret:
    ret

# rdi = path ptr -> rdi = success, rsi = 0
.globl silica_delete_file_path
silica_delete_file_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    call _shim_get_string
    call _shim_cpath
    test rdi, rdi
    jz Ldf_fail
    mov rbx, rdi
    call unlink
    movsxd r12, eax
    mov rdi, rbx
    call free
    cmp r12, 0
    sete al
    movzx edi, al
    xor esi, esi
    jmp Ldf_out
Ldf_fail:
    xor edi, edi
    xor esi, esi
Ldf_out:
    pop r12
    pop rbx
    pop rbp
    ret

.section .rodata,"a",@progbits
Lmode_append:
    .asciz "a"
Lmode_read:
    .asciz "rb"

.text
.p2align 4

# rdi = path ptr -> rdi = success, rsi = SilicaString*
.globl silica_read_file_path
silica_read_file_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    call _shim_get_string
    call _shim_cpath
    test rdi, rdi
    jz Lrf_fail
    mov rbx, rdi
    mov rdi, rbx
    xor esi, esi
    xor eax, eax
    call open
    cmp eax, 0
    jl Lrf_free_fail
    movsxd r12, eax
    mov edi, r12d
    xor esi, esi
    mov edx, 2
    call lseek
    mov r13, rax
    cmp r13, 0
    jl Lrf_close_fail
    mov edi, r12d
    xor esi, esi
    xor edx, edx
    call lseek
    lea rdi, [r13 + 1]
    call malloc
    test rax, rax
    jz Lrf_close_fail
    mov r14, rax
    mov edi, r12d
    mov rsi, r14
    mov rdx, r13
    call read
    mov r15, rax
    cmp r15, 0
    jge Lrf_term
    xor r15d, r15d
Lrf_term:
    mov BYTE PTR [r14 + r15], 0
    mov edi, r12d
    call close
    mov edi, 24
    call malloc
    test rax, rax
    jz Lrf_freebuf
    mov QWORD PTR [rbp - 48], rax
    mov rdx, -1
    mov QWORD PTR [rax], rdx
    mov QWORD PTR [rax + 8], r14
    mov QWORD PTR [rax + 16], r15
    mov rdi, rbx
    call free
    mov edi, 1
    mov rsi, QWORD PTR [rbp - 48]
    jmp Lrf_out
Lrf_freebuf:
    mov rdi, r14
    call free
    jmp Lrf_free_fail
Lrf_close_fail:
    mov edi, r12d
    call close
Lrf_free_fail:
    mov rdi, rbx
    call free
Lrf_fail:
    xor edi, edi
    xor esi, esi
Lrf_out:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

# rdi = path ptr, rsi = content ptr -> rdi = success, rsi = 0
.globl silica_append_file_path
silica_append_file_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r15, rsi
    call _shim_get_string
    call _shim_cpath
    test rdi, rdi
    jz Laf_fail
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + Lmode_append]
    call fopen
    test rax, rax
    jz Laf_free_fail
    mov r12, rax
    mov rdi, r15
    call _shim_get_string
    mov r13, rdi
    mov r14, rsi
    test r13, r13
    jz Laf_close
    test r14, r14
    jz Laf_close
    mov rdi, r13
    mov esi, 1
    mov rdx, r14
    mov rcx, r12
    call fwrite
Laf_close:
    mov rdi, r12
    call fclose
    mov rdi, rbx
    call free
    mov edi, 1
    xor esi, esi
    jmp Laf_out
Laf_free_fail:
    mov rdi, rbx
    call free
Laf_fail:
    xor edi, edi
    xor esi, esi
Laf_out:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

.section .note.GNU-stack,"",@progbits
