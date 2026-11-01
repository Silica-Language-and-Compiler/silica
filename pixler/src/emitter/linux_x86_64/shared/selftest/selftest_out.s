    .intel_syntax noprefix
    .text
.set SVR_AREA, 400
.set SVR_X11, 8
.set SVR_X12, 16
.set SVR_X13, 24
.set SVR_X14, 32
.set SVR_X15, 40
.set SVR_X16, 48
.set SVR_X17, 56
.set SVR_X18, 64
.set SVR_X19, 72
.set SVR_X20, 80
.set SVR_X21, 88
.set SVR_X22, 96
.set SVR_X23, 104
.set SVR_X24, 112
.set SVR_X25, 120
.set SVR_X26, 128
.set SVR_X27, 136
.set SVR_X28, 144
.set SVR_D08, 160
.set SVR_D09, 168
.set SVR_D10, 176
.set SVR_D11, 184
.set SVR_D12, 192
.set SVR_D13, 200
.set SVR_D14, 208
.set SVR_D15, 216
.set SVR_D16, 224
.set SVR_D17, 232
.set SVR_D18, 240
.set SVR_D19, 248
.set SVR_D20, 256
.set SVR_D21, 264
.set SVR_D22, 272
.set SVR_D23, 280
.set SVR_D24, 288
.set SVR_D25, 296
.set SVR_D26, 304
.set SVR_D27, 312
.set SVR_D28, 320
.set SVR_D29, 328
.set SVR_D30, 336
.set SVR_D31, 344
.set SVR_CS0, 360
.set SVR_CS1, 368
.set SVR_CS2, 376
.set SVR_CS3, 384
.set SVR_CS4, 392
    .globl selftest_fn
selftest_fn:
    push rbp
    mov rbp, rsp
    sub rsp, SVR_AREA
    mov rdi, 42
    mov QWORD PTR [rbp - SVR_X19], 42
    mov rax, 9223372036854775807
    mov QWORD PTR [rbp - SVR_X20], rax
    mov edi, 4294967295
    mov eax, 4294967295
    mov QWORD PTR [rbp - SVR_X21], rax
    mov rdi, 18446744073709551615
    mov rax, 18446744073709551615
    mov QWORD PTR [rbp - SVR_X22], rax
    mov eax, 4294967289
    mov QWORD PTR [rbp - SVR_X22], rax
    mov rdi, rsi
    mov rdi, QWORD PTR [rbp - SVR_X19]
    mov QWORD PTR [rbp - SVR_X19], rdi
    mov rax, QWORD PTR [rbp - SVR_X20]
    mov QWORD PTR [rbp - SVR_X19], rax
    mov edi, esi
    mov eax, esi
    mov QWORD PTR [rbp - SVR_X19], rax
    mov rdi, rsp
    mov rbx, rsp
    lea rax, [rbp - SVR_AREA]
    mov QWORD PTR [rbp - SVR_X16], rax
    lea rax, [rbp - SVR_AREA]
    mov rdi, rax
    mov rdi, 0
    mov rdi, -5
    mov r10d, 7
    movq xmm8, xmm1
    movq xmm0, xmm8
    movq xmm8, xmm1
    movq QWORD PTR [rbp - SVR_D09], xmm8
    movq xmm8, QWORD PTR [rbp - SVR_D09]
    movq xmm0, xmm8
    movd eax, xmm1
    movd xmm0, eax
    movd eax, xmm1
    mov QWORD PTR [rbp - SVR_D09], rax
    movd eax, xmm1
    movzx eax, ax
    movd xmm0, eax
    movd eax, xmm1
    movzx eax, ax
    mov QWORD PTR [rbp - SVR_D17], rax
    mov rax, rdi
    movq xmm8, rax
    movq xmm0, xmm8
    mov rax, QWORD PTR [rbp - SVR_X19]
    movq xmm8, rax
    movq QWORD PTR [rbp - SVR_D09], xmm8
    movq rax, xmm0
    mov rdi, rax
    mov rax, QWORD PTR [rbp - SVR_D09]
    mov QWORD PTR [rbp - SVR_X19], rax
    movd eax, xmm0
    mov edi, eax
    mov eax, edi
    movd xmm0, eax
    mov eax, ebx
    movzx eax, ax
    mov QWORD PTR [rbp - SVR_D17], rax
    mov eax, DWORD PTR [rbp - SVR_D17]
    movzx eax, ax
    mov ebx, eax
    pxor xmm8, xmm8
    movq xmm0, xmm8
    lea rdi, [rip + selftest_fn]
    lea rax, [rip + selftest_fn]
    mov QWORD PTR [rbp - SVR_X16], rax
    lea rbx, [rip + selftest_fn]
    mov rax, r10
    add rax, r11
    mov rdi, rax
    mov rax, QWORD PTR [rbp - SVR_X20]
    add rax, QWORD PTR [rbp - SVR_X21]
    mov QWORD PTR [rbp - SVR_X19], rax
    mov rax, rdi
    add rax, 16
    mov rdi, rax
    mov rax, QWORD PTR [rbp - SVR_X19]
    mov r12, 4294967296
    add rax, r12
    mov rdi, rax
    mov eax, r10d
    add eax, r11d
    mov edi, eax
    mov eax, DWORD PTR [rbp - SVR_X20]
    add eax, 3
    mov QWORD PTR [rbp - SVR_X19], rax
    lea r11, [rsp + 32]
    lea rax, [rsp + 32]
    mov QWORD PTR [rbp - SVR_X19], rax
    lea rsp, [rsp + 48]
    mov r12, QWORD PTR [rbp - SVR_X16]
    lea rsp, [rsp + r12]
    lea rdi, [rbp - SVR_AREA - 16]
    mov rax, r10
    sub rax, r11
    mov rdi, rax
    lea rax, [rbp - SVR_AREA - 4000]
    mov QWORD PTR [rbp - SVR_X16], rax
    lea rax, [rbp - SVR_AREA]
    mov r12, QWORD PTR [rbp - SVR_X17]
    sub rax, r12
    mov QWORD PTR [rbp - SVR_X16], rax
    lea rdi, [rbp - SVR_AREA - 8]
    lea rsp, [rsp + -48]
    mov r12, QWORD PTR [rbp - SVR_X16]
    neg r12
    lea rsp, [rsp + r12]
    mov eax, DWORD PTR [rbp - SVR_X19]
    sub eax, 1
    mov edi, eax
    mov rax, rdi
    add rax, rsi
    mov rdx, rax
    mov rax, r10
    sub rax, 1
    mov r10, rax
    jo 1f
    setno al
    movzx eax, al
    mov edi, eax
    mov rax, r10
    imul rax, r11
    mov rdi, rax
    mov rax, QWORD PTR [rbp - SVR_X19]
    imul rax, 24
    mov QWORD PTR [rbp - SVR_X19], rax
    mov eax, r10d
    imul eax, r11d
    mov edi, eax
    mov rax, r10
    and rax, 15
    mov rdi, rax
    mov rax, QWORD PTR [rbp - SVR_X19]
    and rax, -16
    mov QWORD PTR [rbp - SVR_X19], rax
    mov rax, rdi
    mov r12, 9223372036854775807
    and rax, r12
    mov rdi, rax
    mov rax, r10
    and rax, -16
    mov r10, rax
    mov rax, r10
    and rax, 15
    mov r10, rax
    mov rdi, -9223372036854775808
    mov rax, r10
    or rax, r11
    mov rdi, rax
    mov eax, r10d
    xor eax, r11d
    mov QWORD PTR [rbp - SVR_X19], rax
    mov r12, r11
    not r12
    mov rax, r10
    and rax, r12
    mov rdi, rax
    mov r12d, r11d
    not r12d
    mov eax, r10d
    and eax, r12d
    mov edi, eax
    mov rax, r10
    neg rax
    mov rdi, rax
    mov eax, r10d
    neg eax
    mov QWORD PTR [rbp - SVR_X19], rax
    mov rax, r10
    not rax
    mov rdi, rax
    mov eax, DWORD PTR [rbp - SVR_X19]
    not eax
    mov edi, eax
    mov rax, r10
    shl rax, 3
    mov rdi, rax
    mov rax, QWORD PTR [rbp - SVR_X19]
    push rcx
    mov rcx, r11
    shl rax, cl
    pop rcx
    mov QWORD PTR [rbp - SVR_X19], rax
    mov rax, r10
    push rcx
    shl rax, cl
    pop rcx
    mov rdi, rax
    mov eax, r10d
    shr eax, 5
    mov edi, eax
    mov rax, r10
    push rcx
    mov rcx, r11
    shr rax, cl
    pop rcx
    mov rdi, rax
    mov rax, r10
    sar rax, 63
    mov rdi, rax
    mov eax, r10d
    push rcx
    mov rcx, r11
    sar eax, cl
    pop rcx
    mov QWORD PTR [rbp - SVR_X19], rax
    mov rax, r10
    mov rdi, rax
    mov rax, r10
    mov r12, r11
    push rdx
    cmp r12, -1
    jne 90f
    neg rax
    mov edx, 0
    jmp 92f
90:
    test r12, r12
    jne 91f
    mov rdx, rax
    mov eax, 0
    jmp 92f
91:
    cqo
    idiv r12
92:
    mov r13, rax
    pop rdx
    mov rdi, r13
    mov rax, r10
    mov r12, r11
    push rdx
    cmp r12, -1
    jne 90f
    neg rax
    mov edx, 0
    jmp 92f
90:
    test r12, r12
    jne 91f
    mov rdx, rax
    mov eax, 0
    jmp 92f
91:
    cqo
    idiv r12
92:
    mov r13, rax
    pop rdx
    mov rdx, r13
    mov rax, r10
    mov r12, r11
    push rdx
    test r12, r12
    jne 91f
    mov rdx, rax
    mov eax, 0
    jmp 92f
91:
    mov edx, 0
    div r12
92:
    mov r13, rax
    pop rdx
    mov QWORD PTR [rbp - SVR_X19], r13
    mov rax, r10
    mov r12, r11
    push rdx
    cmp r12, -1
    jne 90f
    neg rax
    mov edx, 0
    jmp 92f
90:
    test r12, r12
    jne 91f
    mov rdx, rax
    mov eax, 0
    jmp 92f
91:
    cqo
    idiv r12
92:
    mov r13, rdx
    pop rdx
    mov rdi, r13
    mov rax, r10
    mov r12, r11
    push rdx
    test r12, r12
    jne 91f
    mov rdx, rax
    mov eax, 0
    jmp 92f
91:
    mov edx, 0
    div r12
92:
    mov r13, rdx
    pop rdx
    mov rdi, r13
    mov eax, r10d
    mov r12d, r11d
    push rdx
    cmp r12d, -1
    jne 90f
    neg eax
    mov edx, 0
    jmp 92f
90:
    test r12d, r12d
    jne 91f
    mov edx, eax
    mov eax, 0
    jmp 92f
91:
    cdq
    idiv r12d
92:
    mov r13, rax
    pop rdx
    mov edi, r13d
    mov eax, r10d
    mov r12d, r11d
    push rdx
    test r12d, r12d
    jne 91f
    mov edx, eax
    mov eax, 0
    jmp 92f
91:
    mov edx, 0
    div r12d
92:
    mov r13, rax
    pop rdx
    mov edi, r13d
    mov eax, r10d
    mov r12d, r11d
    push rdx
    cmp r12d, -1
    jne 90f
    neg eax
    mov edx, 0
    jmp 92f
90:
    test r12d, r12d
    jne 91f
    mov edx, eax
    mov eax, 0
    jmp 92f
91:
    cdq
    idiv r12d
92:
    mov r13, rdx
    pop rdx
    mov eax, r13d
    mov QWORD PTR [rbp - SVR_X19], rax
    mov eax, r10d
    mov r12d, r11d
    push rdx
    test r12d, r12d
    jne 91f
    mov edx, eax
    mov eax, 0
    jmp 92f
91:
    mov edx, 0
    div r12d
92:
    mov r13, rdx
    pop rdx
    mov edx, r13d
    cmp r10, r11
    sete al
    movzx eax, al
    mov edi, eax
    cmp r10, 0
    jne 1f
    mov rax, QWORD PTR [rbp - SVR_X19]
    cmp rax, QWORD PTR [rbp - SVR_X20]
    setl al
    movzx eax, al
    mov QWORD PTR [rbp - SVR_X21], rax
    cmp r10d, r11d
    setbe al
    movzx eax, al
    mov QWORD PTR [rbp - SVR_X19], rax
    cmp DWORD PTR [rbp - SVR_X19], 7
    ja 1f
    mov rax, 0
    cmp rax, rdi
    mov r12, 4294967296
    cmp rdi, r12
    lea r12, [rbp - SVR_AREA]
    cmp rdi, r12
    lea rax, [rbp - SVR_AREA]
    cmp rax, rdi
    mov rax, r11
    mov r12, r10
    cmovge rax, r12
    mov rdi, rax
    mov rax, 0
    mov r12, 1
    cmovg rax, r12
    mov QWORD PTR [rbp - SVR_X19], rax
    mov rax, 0
    mov r12, r10
    cmovle rax, r12
    mov edi, eax
    cmp r10, r11
    sete al
    movzx eax, al
    mov edi, eax
    cmp r10, 255
    jb 1f
    cmp r10, r11
    mov rax, r11
    mov r12, r10
    cmovs rax, r12
    mov rdi, rax
    cmp r10d, r11d
    setns al
    movzx eax, al
    mov edi, eax
    mov rax, QWORD PTR [rbp - SVR_X19]
    cmp rax, QWORD PTR [rbp - SVR_X20]
    setae al
    movzx eax, al
    mov edi, eax
    mov rax, QWORD PTR [rbp - SVR_X19]
    cmp rax, QWORD PTR [rbp - SVR_X20]
    setae al
    movzx eax, al
    mov edi, eax
    mov rax, QWORD PTR [rbp - SVR_X19]
    cmp rax, QWORD PTR [rbp - SVR_X20]
    setb al
    movzx eax, al
    mov edi, eax
    test rdi, rdi
    je 1f
    cmp QWORD PTR [rbp - SVR_X19], 0
    jne 1f
    test edi, edi
    je 1f
    cmp DWORD PTR [rbp - SVR_X19], 0
    jne 1f
    lea rax, [rbp - SVR_AREA]
    test rax, rax
    je 1f
    jmp 1f
1:
    call selftest_fn
    call selftest_fn
    call __divdi3
    call r10
    call QWORD PTR [rbp - SVR_X17]
    mov eax, 0
    call malloc
    mov rdi, rax
    push rax
    push r14
    mov eax, 0
    call free
    lea rsp, [rsp + 16]
    mov rdi, rax
    push r15
    push r14
    mov eax, 2
    call abort
    lea rsp, [rsp + 16]
    mov rdi, rax
    mfence
    movsx rax, r10b
    mov rdi, rax
    movsx eax, WORD PTR [rbp - SVR_X19]
    mov edi, eax
    movzx eax, r10b
    mov edi, eax
    movzx eax, WORD PTR [rbp - SVR_X19]
    mov rdi, rax
    movsxd rax, r10d
    mov rdi, rax
    mov eax, r10d
    mov QWORD PTR [rbp - SVR_X19], rax
    movsxd rax, DWORD PTR [rbp - SVR_X19]
    mov rdi, rax
    mov eax, 0
    mov edi, eax
    mov rdi, QWORD PTR [rsi]
    mov rdi, QWORD PTR [rsi + 8]
    mov rax, QWORD PTR [rsi - 8]
    mov QWORD PTR [rbp - SVR_X19], rax
    mov r12, QWORD PTR [rbp - SVR_X19]
    mov rdi, QWORD PTR [r12]
    mov r12, QWORD PTR [rbp - SVR_X20]
    mov rax, QWORD PTR [r12 + 16]
    mov QWORD PTR [rbp - SVR_X19], rax
    mov rdi, QWORD PTR [rsi + rdx*1]
    mov rdi, QWORD PTR [rsi + rdx*8]
    mov r12, QWORD PTR [rbp - SVR_X20]
    mov r13, QWORD PTR [rbp - SVR_X21]
    mov rax, QWORD PTR [r12 + r13*4]
    mov QWORD PTR [rbp - SVR_X19], rax
    mov r12, QWORD PTR [rbp - SVR_X19]
    mov rdi, QWORD PTR [r12 + rdx*2]
    mov rdi, QWORD PTR [rbx]
    mov rdi, QWORD PTR [rsp + 16]
    mov rdi, QWORD PTR [rsp]
    lea rsp, [rsp + 16]
    mov rax, QWORD PTR [rsp]
    mov QWORD PTR [rbp - SVR_X19], rax
    lea rsp, [rsp + 16]
    mov rdi, QWORD PTR [rsi]
    lea rsi, [rsi + 8]
    mov r12, QWORD PTR [rbp - SVR_X19]
    mov rdi, QWORD PTR [r12]
    mov r12, QWORD PTR [rbp - SVR_X19]
    lea r12, [r12 + 8]
    mov QWORD PTR [rbp - SVR_X19], r12
    lea rsi, [rsi + 8]
    mov rdi, QWORD PTR [rsi]
    mov r12, QWORD PTR [rbp - SVR_X19]
    lea r12, [r12 + -8]
    mov QWORD PTR [rbp - SVR_X19], r12
    mov r12, QWORD PTR [rbp - SVR_X19]
    mov rdi, QWORD PTR [r12]
    mov rdi, QWORD PTR [rbp - SVR_AREA - 16]
    mov rax, QWORD PTR [rbp - SVR_AREA - 4000]
    mov QWORD PTR [rbp - SVR_X19], rax
    mov edi, DWORD PTR [rsi]
    mov eax, DWORD PTR [rsi + 4]
    mov QWORD PTR [rbp - SVR_X19], rax
    movq xmm0, QWORD PTR [rsi]
    mov rax, QWORD PTR [rbp - SVR_AREA - 24]
    mov QWORD PTR [rbp - SVR_D09], rax
    movd xmm0, DWORD PTR [rsi + 4]
    mov eax, DWORD PTR [rsi]
    mov QWORD PTR [rbp - SVR_D09], rax
    movzx eax, WORD PTR [rsi]
    movd xmm0, eax
    movzx eax, WORD PTR [rsi + 2]
    mov QWORD PTR [rbp - SVR_D17], rax
    movq xmm3, QWORD PTR [rbx]
    mov rsp, QWORD PTR [rdi]
    mov QWORD PTR [rsi], rdi
    mov rax, QWORD PTR [rbp - SVR_X19]
    mov QWORD PTR [rsi + 8], rax
    mov r12, QWORD PTR [rbp - SVR_X19]
    mov QWORD PTR [r12], rdi
    mov rax, QWORD PTR [rbp - SVR_X19]
    mov r12, QWORD PTR [rbp - SVR_X20]
    mov r13, QWORD PTR [rbp - SVR_X21]
    mov QWORD PTR [r12 + r13*8], rax
    mov QWORD PTR [rsi], 0
    mov DWORD PTR [rsi + 4], 0
    lea rsp, [rsp - 16]
    mov QWORD PTR [rsp], rdi
    mov rax, QWORD PTR [rbp - SVR_X19]
    lea rsp, [rsp - 16]
    mov QWORD PTR [rsp], rax
    mov QWORD PTR [rsp + 8], rdi
    mov QWORD PTR [rsi], rdi
    lea rsi, [rsi + 8]
    mov QWORD PTR [rbp - SVR_AREA - 16], rdi
    mov rax, QWORD PTR [rbp - SVR_X19]
    mov QWORD PTR [rbp - SVR_AREA - 4000], rax
    lea rax, [rbp - SVR_AREA]
    mov QWORD PTR [rsi], rax
    mov QWORD PTR [rsi], rsp
    mov DWORD PTR [rsi], edi
    mov eax, DWORD PTR [rbp - SVR_X19]
    mov DWORD PTR [rsi], eax
    movq QWORD PTR [rsi], xmm0
    mov rax, QWORD PTR [rbp - SVR_D09]
    mov QWORD PTR [rbp - SVR_AREA - 24], rax
    movd DWORD PTR [rsi], xmm0
    mov eax, DWORD PTR [rbp - SVR_D09]
    mov DWORD PTR [rsi], eax
    movd eax, xmm0
    mov WORD PTR [rsi], ax
    movzx eax, WORD PTR [rbp - SVR_D17]
    mov WORD PTR [rsi], ax
    movzx eax, BYTE PTR [rsi]
    mov edi, eax
    movzx eax, BYTE PTR [rsi + rdx*1]
    mov QWORD PTR [rbp - SVR_X19], rax
    movsx eax, BYTE PTR [rsi]
    mov edi, eax
    movsx rax, BYTE PTR [rsi]
    mov QWORD PTR [rbp - SVR_X19], rax
    movzx eax, WORD PTR [rsi + 2]
    mov edi, eax
    movsx eax, WORD PTR [rsi]
    mov QWORD PTR [rbp - SVR_X19], rax
    movsx rax, WORD PTR [rsi]
    mov rdi, rax
    movsxd rax, DWORD PTR [rsi]
    mov rdi, rax
    movsxd rax, DWORD PTR [rsi + 4]
    mov QWORD PTR [rbp - SVR_X19], rax
    mov BYTE PTR [rsi], dil
    mov eax, DWORD PTR [rbp - SVR_X19]
    mov BYTE PTR [rsi + 1], al
    mov BYTE PTR [rsi], 0
    mov eax, DWORD PTR [rbp - SVR_X12]
    mov BYTE PTR [r11], al
    lea r11, [r11 + 1]
    mov WORD PTR [rsi], di
    mov eax, DWORD PTR [rbp - SVR_X19]
    mov WORD PTR [rsi], ax
    mov WORD PTR [rsi], 0
    mov rdi, QWORD PTR [rsp]
    mov rsi, QWORD PTR [rsp + 8]
    lea rsp, [rsp + 16]
    lea rsp, [rsp - 16]
    mov QWORD PTR [rsp], rdi
    mov QWORD PTR [rsp + 8], rsi
    mov rax, QWORD PTR [rsp]
    mov QWORD PTR [rbp - SVR_X19], rax
    mov rax, QWORD PTR [rsp + 8]
    mov QWORD PTR [rbp - SVR_X20], rax
    lea rsp, [rsp + 16]
    lea rsp, [rsp - 16]
    mov rax, QWORD PTR [rbp - SVR_X19]
    mov QWORD PTR [rsp], rax
    mov rax, QWORD PTR [rbp - SVR_X20]
    mov QWORD PTR [rsp + 8], rax
    lea rsp, [rsp - 16]
    mov rax, QWORD PTR [rbp - SVR_X16]
    mov QWORD PTR [rsp], rax
    mov rax, QWORD PTR [rbp - SVR_X17]
    mov QWORD PTR [rsp + 8], rax
    mov rax, QWORD PTR [rsp]
    mov QWORD PTR [rbp - SVR_X16], rax
    mov rax, QWORD PTR [rsp + 8]
    mov QWORD PTR [rbp - SVR_X17], rax
    lea rsp, [rsp + 16]
    lea rsp, [rsp - 16]
    mov rax, QWORD PTR [rbp - SVR_D08]
    mov QWORD PTR [rsp], rax
    mov rax, QWORD PTR [rbp - SVR_D09]
    mov QWORD PTR [rsp + 8], rax
    mov rax, QWORD PTR [rsp]
    mov QWORD PTR [rbp - SVR_D08], rax
    mov rax, QWORD PTR [rsp + 8]
    mov QWORD PTR [rbp - SVR_D09], rax
    lea rsp, [rsp + 16]
    mov QWORD PTR [rsp + 16], rsi
    mov QWORD PTR [rsp + 16 + 8], rdx
    mov QWORD PTR [rdi], 0
    mov QWORD PTR [rdi + 8], 0
    mov r12, QWORD PTR [rbp - SVR_X19]
    mov rdi, QWORD PTR [r12]
    mov rsi, QWORD PTR [r12 + 8]
    mov r12, QWORD PTR [rbp - SVR_X19]
    mov rax, QWORD PTR [rbp - SVR_X21]
    mov QWORD PTR [r12], rax
    mov rax, QWORD PTR [rbp - SVR_X20]
    mov QWORD PTR [r12 + 8], rax
    lea rsp, [rsp - 16]
    mov QWORD PTR [rsp], rdi
    mov rax, QWORD PTR [rsp]
    mov QWORD PTR [rbp - SVR_X19], rax
    lea rsp, [rsp + 16]
    mov QWORD PTR [rbp - SVR_CS0], rbx
    mov QWORD PTR [rbp - SVR_CS1], r12
    mov QWORD PTR [rbp - SVR_CS2], r13
    mov QWORD PTR [rbp - SVR_CS3], r14
    mov QWORD PTR [rbp - SVR_CS4], r15
    mov rbx, QWORD PTR [rbp - SVR_CS0]
    mov r12, QWORD PTR [rbp - SVR_CS1]
    mov r13, QWORD PTR [rbp - SVR_CS2]
    mov r14, QWORD PTR [rbp - SVR_CS3]
    mov r15, QWORD PTR [rbp - SVR_CS4]
    movq xmm8, xmm1
    movq xmm9, xmm2
    addsd xmm8, xmm9
    movq xmm0, xmm8
    movq xmm8, xmm1
    movq xmm9, QWORD PTR [rbp - SVR_D10]
    subsd xmm8, xmm9
    movq QWORD PTR [rbp - SVR_D09], xmm8
    movq xmm8, xmm1
    movq xmm9, xmm2
    mulss xmm8, xmm9
    movd eax, xmm8
    movd xmm0, eax
    movq xmm8, xmm1
    movq xmm9, QWORD PTR [rbp - SVR_D10]
    divss xmm8, xmm9
    movd eax, xmm8
    mov QWORD PTR [rbp - SVR_D09], rax
    movq xmm8, xmm1
    vcvtph2ps xmm8, xmm8
    movq xmm9, xmm2
    vcvtph2ps xmm9, xmm9
    addss xmm8, xmm9
    vcvtps2ph xmm8, xmm8, 0
    movd eax, xmm8
    movzx eax, ax
    movd xmm0, eax
    movq xmm8, xmm1
    vcvtph2ps xmm8, xmm8
    movq xmm9, QWORD PTR [rbp - SVR_D16]
    vcvtph2ps xmm9, xmm9
    divss xmm8, xmm9
    vcvtps2ph xmm8, xmm8, 0
    movd eax, xmm8
    movzx eax, ax
    mov QWORD PTR [rbp - SVR_D17], rax
    movq xmm8, xmm1
    mov rax, -9223372036854775808
    movq xmm9, rax
    pxor xmm8, xmm9
    movq xmm0, xmm8
    movq xmm8, xmm1
    mov eax, 2147483648
    movd xmm9, eax
    pxor xmm8, xmm9
    movq xmm0, xmm8
    movq xmm8, xmm1
    mov eax, 32768
    movd xmm9, eax
    pxor xmm8, xmm9
    movq xmm0, xmm8
    movq xmm8, xmm1
    mov rax, 9223372036854775807
    movq xmm9, rax
    pand xmm8, xmm9
    movq QWORD PTR [rbp - SVR_D16], xmm8
    movq xmm8, xmm1
    mov eax, 2147483647
    movd xmm9, eax
    pand xmm8, xmm9
    movq QWORD PTR [rbp - SVR_D16], xmm8
    movq xmm8, xmm1
    mov eax, 32767
    movd xmm9, eax
    pand xmm8, xmm9
    movq QWORD PTR [rbp - SVR_D16], xmm8
    movq xmm8, xmm1
    sqrtsd xmm8, xmm8
    movq xmm0, xmm8
    movq xmm8, xmm1
    vcvtph2ps xmm8, xmm8
    sqrtss xmm8, xmm8
    vcvtps2ph xmm8, xmm8, 0
    movd eax, xmm8
    movzx eax, ax
    movd xmm0, eax
    movq xmm8, xmm1
    movq xmm9, xmm2
    ucomisd xmm8, xmm9
    sete al
    setnp r12b
    and al, r12b
    movzx eax, al
    mov edi, eax
    setne al
    setp r12b
    or al, r12b
    movzx eax, al
    mov edi, eax
    setb al
    setnp r12b
    and al, r12b
    movzx eax, al
    mov edi, eax
    setb al
    movzx eax, al
    mov edi, eax
    setae al
    movzx eax, al
    mov edi, eax
    seta al
    movzx eax, al
    mov edi, eax
    setbe al
    movzx eax, al
    mov edi, eax
    seta al
    setp r12b
    or al, r12b
    movzx eax, al
    mov edi, eax
    setbe al
    setnp r12b
    and al, r12b
    movzx eax, al
    mov edi, eax
    setae al
    setp r12b
    or al, r12b
    movzx eax, al
    mov edi, eax
    setae al
    setp r12b
    or al, r12b
    movzx eax, al
    mov edi, eax
    setp al
    movzx eax, al
    mov edi, eax
    setnp al
    movzx eax, al
    mov QWORD PTR [rbp - SVR_X19], rax
    setae al
    setp r12b
    or al, r12b
    movzx eax, al
    mov edi, eax
    movq xmm8, xmm1
    movq xmm9, QWORD PTR [rbp - SVR_D09]
    ucomiss xmm8, xmm9
    jp 93f
    je 2f
93:
    jne 2f
    jp 2f
    jp 93f
    jb 2f
93:
    jb 2f
    jae 2f
    ja 2f
    jbe 2f
    ja 2f
    jp 2f
    jp 93f
    jbe 2f
93:
    jae 2f
    jp 2f
    jae 2f
    jp 2f
    jp 2f
    jnp 2f
    movq xmm8, xmm1
    vcvtph2ps xmm8, xmm8
    movq xmm9, QWORD PTR [rbp - SVR_D17]
    vcvtph2ps xmm9, xmm9
    ucomiss xmm8, xmm9
    movq xmm8, xmm1
    movq xmm9, xmm2
    ucomisd xmm8, xmm9
    seta al
    movzx eax, al
    mov edi, eax
    movq xmm8, xmm1
    movq xmm9, xmm2
    ucomiss xmm8, xmm9
    jp 93f
    jb 2f
93:
    movq xmm8, xmm1
    movq xmm9, xmm2
    ucomisd xmm8, xmm9
    sete al
    setnp r12b
    and al, r12b
    mov QWORD PTR [rbp - SVR_X16], r11
    mov QWORD PTR [rbp - SVR_X17], r10
    test al, al
    mov rax, QWORD PTR [rbp - SVR_X16]
    cmovne rax, QWORD PTR [rbp - SVR_X17]
    mov rdi, rax
2:
    movq xmm8, xmm1
    cvtss2sd xmm8, xmm8
    movq xmm0, xmm8
    movq xmm8, xmm1
    cvtsd2ss xmm8, xmm8
    movd eax, xmm8
    movd xmm0, eax
    movq xmm8, xmm1
    vcvtph2ps xmm8, xmm8
    movd eax, xmm8
    movd xmm0, eax
    movq xmm8, xmm1
    vcvtps2ph xmm8, xmm8, 0
    movd eax, xmm8
    movzx eax, ax
    movd xmm0, eax
    movq xmm8, xmm1
    vcvtph2ps xmm8, xmm8
    cvtss2sd xmm8, xmm8
    movq QWORD PTR [rbp - SVR_D09], xmm8
    movq xmm8, xmm1
    cvtsd2ss xmm8, xmm8
    vcvtps2ph xmm8, xmm8, 0
    movd eax, xmm8
    movzx eax, ax
    mov QWORD PTR [rbp - SVR_D17], rax
    movq xmm8, xmm1
    movq xmm0, xmm8
    mov rax, rdi
    pxor xmm8, xmm8
    cvtsi2sd xmm8, rax
    movq xmm0, xmm8
    mov eax, DWORD PTR [rbp - SVR_X19]
    pxor xmm8, xmm8
    cvtsi2ss xmm8, eax
    movd eax, xmm8
    movd xmm0, eax
    mov rax, rdi
    pxor xmm8, xmm8
    cvtsi2ss xmm8, rax
    vcvtps2ph xmm8, xmm8, 0
    movd eax, xmm8
    movzx eax, ax
    movd xmm0, eax
    mov eax, edi
    pxor xmm8, xmm8
    cvtsi2sd xmm8, eax
    movq QWORD PTR [rbp - SVR_D09], xmm8
    mov rax, rdi
    pxor xmm8, xmm8
    test rax, rax
    js 94f
    cvtsi2sd xmm8, rax
    jmp 95f
94:
    mov r12, rax
    shr r12, 1
    and eax, 1
    or r12, rax
    cvtsi2sd xmm8, r12
    addsd xmm8, xmm8
95:
    movq xmm0, xmm8
    mov eax, edi
    pxor xmm8, xmm8
    cvtsi2ss xmm8, rax
    movd eax, xmm8
    movd xmm0, eax
    mov rax, QWORD PTR [rbp - SVR_X19]
    pxor xmm8, xmm8
    test rax, rax
    js 94f
    cvtsi2ss xmm8, rax
    jmp 95f
94:
    mov r12, rax
    shr r12, 1
    and eax, 1
    or r12, rax
    cvtsi2ss xmm8, r12
    addss xmm8, xmm8
95:
    vcvtps2ph xmm8, xmm8, 0
    movd eax, xmm8
    movzx eax, ax
    movd xmm0, eax
    mov eax, edi
    pxor xmm8, xmm8
    cvtsi2sd xmm8, rax
    movq xmm0, xmm8
    movq xmm8, xmm0
    cvttsd2si rax, xmm8
    mov rdi, rax
    movq xmm8, xmm0
    cvttss2si eax, xmm8
    mov edi, eax
    movq xmm8, xmm0
    vcvtph2ps xmm8, xmm8
    cvttss2si eax, xmm8
    mov edi, eax
    movq xmm8, QWORD PTR [rbp - SVR_D09]
    cvttsd2si rax, xmm8
    mov QWORD PTR [rbp - SVR_X19], rax
    movq xmm8, xmm0
    mov rax, 4890909195324358656
    movq xmm9, rax
    ucomisd xmm8, xmm9
    jae 96f
    cvttsd2si rax, xmm8
    jmp 97f
96:
    subsd xmm8, xmm9
    cvttsd2si rax, xmm8
    mov r12, -9223372036854775808
    xor rax, r12
97:
    mov rdi, rax
    movq xmm8, xmm0
    mov eax, 1325400064
    movd xmm9, eax
    ucomiss xmm8, xmm9
    jae 96f
    cvttss2si eax, xmm8
    jmp 97f
96:
    subss xmm8, xmm9
    cvttss2si eax, xmm8
    mov r12d, 2147483648
    xor eax, r12d
97:
    mov edi, eax
    movq xmm8, xmm1
    vcvtph2ps xmm8, xmm8
    mov eax, 1325400064
    movd xmm9, eax
    ucomiss xmm8, xmm9
    jae 96f
    cvttss2si eax, xmm8
    jmp 97f
96:
    subss xmm8, xmm9
    cvttss2si eax, xmm8
    mov r12d, 2147483648
    xor eax, r12d
97:
    mov QWORD PTR [rbp - SVR_X19], rax
    movq xmm8, xmm1
    mov eax, 1593835520
    movd xmm9, eax
    ucomiss xmm8, xmm9
    jae 96f
    cvttss2si rax, xmm8
    jmp 97f
96:
    subss xmm8, xmm9
    cvttss2si rax, xmm8
    mov r12, -9223372036854775808
    xor rax, r12
97:
    mov rdi, rax
    movq xmm8, xmm1
    roundsd xmm8, xmm8, 3
    movq xmm0, xmm8
    movq xmm8, xmm1
    roundss xmm8, xmm8, 3
    movd eax, xmm8
    mov QWORD PTR [rbp - SVR_D09], rax
    movq xmm8, xmm1
    vcvtph2ps xmm8, xmm8
    roundss xmm8, xmm8, 3
    vcvtps2ph xmm8, xmm8, 0
    movd eax, xmm8
    movzx eax, ax
    movd xmm0, eax
    movq xmm8, xmm1
    movq xmm9, xmm1
    ucomisd xmm8, xmm9
    setp al
    movzx eax, al
    mov edi, eax
    movq xmm8, xmm1
    mov rax, 9223372036854775807
    movq xmm9, rax
    pand xmm8, xmm9
    mov rax, 9218868437227405312
    movq xmm9, rax
    ucomisd xmm8, xmm9
    sete al
    setnp r12b
    and al, r12b
    movzx eax, al
    mov edi, eax
    movq xmm8, xmm1
    mov rax, 9223372036854775807
    movq xmm9, rax
    pand xmm8, xmm9
    mov rax, 9218868437227405312
    movq xmm9, rax
    ucomisd xmm8, xmm9
    setb al
    setnp r12b
    and al, r12b
    movzx eax, al
    mov QWORD PTR [rbp - SVR_X19], rax
    movq xmm8, xmm1
    movq xmm9, xmm1
    ucomiss xmm8, xmm9
    setp al
    movzx eax, al
    mov edi, eax
    movq xmm8, xmm1
    mov eax, 2147483647
    movd xmm9, eax
    pand xmm8, xmm9
    mov eax, 2139095040
    movd xmm9, eax
    ucomiss xmm8, xmm9
    sete al
    setnp r12b
    and al, r12b
    movzx eax, al
    mov edi, eax
    movq xmm8, xmm1
    vcvtph2ps xmm8, xmm8
    mov eax, 2147483647
    movd xmm9, eax
    pand xmm8, xmm9
    mov eax, 2139095040
    movd xmm9, eax
    ucomiss xmm8, xmm9
    setb al
    setnp r12b
    and al, r12b
    movzx eax, al
    mov edi, eax
    movq xmm8, xmm1
    vcvtph2ps xmm8, xmm8
    mov eax, 2147483647
    movd xmm9, eax
    pand xmm8, xmm9
    mov eax, 2139095040
    movd xmm9, eax
    ucomiss xmm8, xmm9
    sete al
    setnp r12b
    and al, r12b
    movzx eax, al
    mov edi, eax
    movd eax, xmm8
    movd xmm0, eax
    vcvtps2ph xmm8, xmm8, 0
    movd eax, xmm8
    movzx eax, ax
    mov QWORD PTR [rbp - SVR_D09], rax
    jmp QWORD PTR [rbp - SVR_X17]
    jmp r10
    leave
    ret
    .section .note.GNU-stack,"",@progbits
