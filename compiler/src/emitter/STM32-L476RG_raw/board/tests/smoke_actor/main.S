// Smoke test 2: the actor path the base trials take, written by hand against the runtime's emitted-code
// contract: main spawns a cast-style worker (its convention word 0x5C1AC0F2 before the entry), casts it
// one message (an int64), and waits in wait_for_exit; the worker's behaviour calls cast_exit(7) and
// answers (:no_reply, state). Expected: ...SILICA:EXIT:7...
// Build: sh ../../tools/build_image.sh -o out/smoke_actor main.S
    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb
    .text
    .section .rodata.silica_registry, "a"
    .align 2
    .global silica_rt_reply_tag
silica_rt_reply_tag:
    .word -1
    .global silica_rt_no_reply_tag
silica_rt_no_reply_tag:
    .word 23
    .section .text.main,"ax",%progbits
    .align 2
    .thumb_func
    .type main, %function
    .global main
main:
    push {r4, lr}
    // spawn(X0 init = 0, X1 beh = worker, W2 core = 0, X3 tramp = 0, X4 policy = 0, X6 desc = 0)
    movw r0, #0
    movw r1, #0
    movw r2, #:lower16:worker
    movt r2, #:upper16:worker
    movw r3, #0
    movw r4, #0
    movw r5, #0
    movw r10, #0
    str r10, [r9, #0]
    str r10, [r9, #8]
    str r10, [r9, #24]
    bl silica_rt_actor_spawn
    // cast(X0 ref, X1 msg = 5, X2 bytes = 0, X3 block = 0)
    movw r2, #5
    movw r3, #0
    movw r4, #0
    movw r5, #0
    bl silica_rt_actor_cast
    bl silica_rt_wait_for_exit
    pop {r4, pc}

    .section .text.worker,"ax",%progbits
    .align 2
    .4byte 0x5C1AC0F2
    .thumb_func
    .type worker, %function
worker:
    // X0 = message (r0:r1), X1 = state (r2:r3), X2 = reply slot. Result: a (:no_reply, state) tuple
    // in this frame: the atom index 23 at +0, the state at +8.
    push {r4, lr}
    sub sp, sp, #16
    movw r4, #23
    str r4, [sp, #0]
    movw r4, #0
    str r4, [sp, #4]
    str r2, [sp, #8]
    str r3, [sp, #12]
    add r0, r0, #2             // cast_exit(message + 2) = 7
    adc r1, r1, #0
    bl silica_rt_cast_exit
    mov r0, sp
    movw r1, #0
    add sp, sp, #16
    pop {r4, pc}
