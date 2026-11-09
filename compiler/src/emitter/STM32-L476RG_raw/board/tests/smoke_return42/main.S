// Smoke test 1: a `main` written by hand in the shape the emitter produces (the prelude macros of
// shared/arm_vr.silica, FRAME_ENTER / FRAME_LEAVE, the frame record), returning 42. Expected console:
//   \x02SILICA:START\x03\x02SILICA:EXIT:42\x03 [silica] stacks: ...
// Build: sh ../../tools/build_image.sh -o out/smoke_return42 main.S
    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb
.macro MOVI32 r, v
.if ((\v) >= 0) && ((\v) <= 65535)
movw \r, #(\v)
.else
movw \r, #((\v) & 0xffff)
movt \r, #(((\v) >> 16) & 0xffff)
.endif
.endm
.macro XL32 r, off
.if ((\off) >= 0) && ((\off) <= 4095)
ldr \r, [sp, #(\off)]
.else
MOVI32 \r, \off
ldr \r, [sp, \r]
.endif
.endm
.macro XS32 r, off, t
.if ((\off) >= 0) && ((\off) <= 4095)
str \r, [sp, #(\off)]
.else
MOVI32 \t, \off
str \r, [sp, \t]
.endif
.endm
.macro FRAME_ENTER n
.if (\n) <= 4095
subw r10, sp, #(\n)
.else
MOVI32 r10, \n
sub r10, sp, r10
.endif
ldr r11, [r9, #116]
cmp r10, r11
bhs.w 1f
mov r11, lr
MOVI32 r10, \n
bl silica_rt_stack_grow
mov lr, r11
b.w 2f
1:
mov sp, r10
2:
.if ((\n) - 4) <= 4095
str lr, [sp, #((\n) - 4)]
.else
MOVI32 r10, (\n) - 4
str lr, [sp, r10]
.endif
.endm
.macro FRAME_LEAVE n
.if ((\n) - 4) <= 4095
ldr lr, [sp, #((\n) - 4)]
.else
MOVI32 r10, (\n) - 4
ldr lr, [sp, r10]
.endif
.if (\n) <= 4095
addw sp, sp, #(\n)
.else
MOVI32 r10, \n
add sp, sp, r10
.endif
bx lr
.endm
    .text
.set SFRAME, 48
.set SFP, 16
    .section .text.main,"ax",%progbits
    .align 2
    .thumb_func
    .type main, %function
    .global main
main:
    FRAME_ENTER SFRAME
    ldr r10, [r9, #140]
    XS32 r10, SFP+4, r8
    ldr r11, [r9, #112]
    XS32 r11, SFP, r8
    str r11, [r9, #140]
    movw r0, #42
    movw r1, #0
    XL32 r11, SFP+4
    str r11, [r9, #140]
    XL32 r11, SFP
    str r11, [r9, #112]
    FRAME_LEAVE SFRAME
