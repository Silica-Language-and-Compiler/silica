# runtime_asm/linux_x86_64/deviceio_link_thunks.s - Linux (glibc, x86-64) build of
# ../linux_aarch64/deviceio_link_thunks.s: ELF symbol names and the Linux x86-64 mmap syscall
# (9, MAP_PRIVATE|MAP_ANONYMOUS = 0x22, -errno on failure).
#
# The thunks are called from emitted Silica code with the internal convention: arguments in
# rdi rsi ..., result in rdi, and the caller assumes nothing survives except rbp/rsp. They call
# the silica_*_path shim routines, which answer {x0, x1} = {rdi, rsi}. main_read_lines keeps
# the AArch64 x19..x22 in rbx r12 r13 r14 (pushed, so the thunk is also C-callable); the raw
# syscall clobbers rcx and r11, neither of which is live across it.
.intel_syntax noprefix
.text
.p2align 4

.globl main_print
.globl diagnostics_core_print
.globl main_compile_pipeline_print
.globl main_parse_print
.globl main_unit_print
main_print:
diagnostics_core_print:
main_compile_pipeline_print:
main_parse_print:
main_unit_print:
    push rbp
    mov rbp, rsp
    call silica_print_string
    xor edi, edi
    pop rbp
    ret

.globl main_file_exists
.globl module_iface_file_exists
.globl ffi_link_manifest_file_exists
.globl ffi_sidecar_loader_file_exists
.globl main_driver_file_exists
.globl main_hygiene_file_exists
.globl main_lists_file_exists
main_file_exists:
module_iface_file_exists:
ffi_link_manifest_file_exists:
ffi_sidecar_loader_file_exists:
main_driver_file_exists:
main_hygiene_file_exists:
main_lists_file_exists:
    push rbp
    mov rbp, rsp
    call silica_read_file_path
    and rdi, 1
    pop rbp
    ret

.globl main_read_lines
.globl module_iface_read_lines
.globl ffi_sidecar_loader_read_lines
.globl lexer_runner_read_lines
.globl main_driver_read_lines
main_read_lines:
module_iface_read_lines:
ffi_sidecar_loader_read_lines:
lexer_runner_read_lines:
main_driver_read_lines:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    call silica_read_file_path
    mov rbx, rdi          # success bits
    mov r12, rsi          # SilicaString*
    mov r10, rbx
    and r10, 1
    jz rl_fail
    test r12, r12
    jz rl_fail
    mov r13, QWORD PTR [r12 + 8]    # data
    mov r14, QWORD PTR [r12 + 16]   # length
    # mmap(0, length + 25, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
    lea rsi, [r14 + 25]
    xor edi, edi
    mov edx, 3
    mov r10d, 0x22
    mov r8, -1
    xor r9d, r9d
    mov eax, 9
    syscall
    # check mmap fail: the raw Linux syscall returns -errno
    test rax, rax
    js rl_fail
    mov rbx, rax
    # build the SilicaString descriptor in place: tag / data / length
    mov r10, -1
    mov QWORD PTR [rbx], r10
    lea r10, [rbx + 24]
    mov QWORD PTR [rbx + 8], r10
    mov QWORD PTR [rbx + 16], r14
    mov r11, r13
    mov rcx, r14
rl_cp:
    test rcx, rcx
    jz rl_cp_done
    movzx eax, BYTE PTR [r11]
    add r11, 1
    mov BYTE PTR [r10], al
    add r10, 1
    sub rcx, 1
    jmp rl_cp
rl_cp_done:
    mov BYTE PTR [r10], 0
    mov rdi, rbx
    jmp rl_ret
rl_fail:
    xor edi, edi
rl_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

.globl main_delete_file
.globl module_iface_delete_file
.globl build_output_delete_file
.globl main_hygiene_delete_file
.globl main_lists_delete_file
main_delete_file:
module_iface_delete_file:
build_output_delete_file:
main_hygiene_delete_file:
main_lists_delete_file:
    push rbp
    mov rbp, rsp
    call silica_delete_file_path
    and rdi, 1
    pop rbp
    ret

.globl main_append_file
.globl module_iface_append_file
.globl build_output_append_file
.globl main_hygiene_append_file
.globl main_lists_append_file
main_append_file:
module_iface_append_file:
build_output_append_file:
main_hygiene_append_file:
main_lists_append_file:
    push rbp
    mov rbp, rsp
    call silica_append_file_path
    and rdi, 1
    pop rbp
    ret

.section .note.GNU-stack,"",@progbits
