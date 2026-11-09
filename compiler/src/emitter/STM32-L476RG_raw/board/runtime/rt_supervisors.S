/*
   Copyright 2026 Lee Scott Barney

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

// Supervisors for the bare-metal STM32L476RG runtime (spec §15.4.9-§15.4.13; the ESP32-S3 port's
// rt_supervisors.S is the reference).
//
// STAGE 1 OF THE PORT: the start of a supervisor and its children. The per-supervisor start trampoline
// the emitter writes (module_linkage.silica) calls init/1 on the supervisor's first schedule and hands
// its result here: silica_rt_supervisor_materialize_init_children(X0 supervisor ACB, X1 the init
// result tuple) fills the supervision block (strategy, allowed restarts, time frame) and starts one
// child per spec of the returned list, each registered under its id. Restarts, shutdown, the child
// table queries and the call_supervisor operations are not ported yet (rt_stubs.S: a program that
// reaches one ends with "runtime entry not yet ported", status 71).
//
// Layouts (rt_defs.h): the init result tuple holds the supervisor_flags record (a pointer in slot 0, or
// the three fields flat in slots 0-2 for older shapes) and the child-spec list handle (slot 1, or slot
// 3 in the flat shape). A child spec is an 88-byte record laid out inline in its list cell, one cell
// per chunk (SPEC_*; the next chunk at SPEC_LIST_CHUNK).

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

#define EXTRA_TRAMP   0
#define EXTRA_POLICY  4
#define EXTRA_AGENT   8
#define EXTRA_ROW     12
#define EXTRA_SUP     16
#define EXTRA_DESC    20
#define EXTRA_INIT    24
#define EXTRA_BEH     32
#define EXTRA_CORE    36
#define EXTRA_SIZE    40

    .section .text.silica_rt_supervisors, "ax", %progbits

// rt_fill_row_from_spec(r0 = row, r1 = spec). Clobbers r2.
    LFUNC rt_fill_row_from_spec
    movw    r2, #0
    str     r2, [r0, #ROW_CHILD]
    str     r2, [r0, #ROW_CHILD + 4]
    ldr     r2, [r1, #SPEC_ID]
    str     r2, [r0, #ROW_ID]
    ldr     r2, [r1, #SPEC_AGENT]
    str     r2, [r0, #ROW_AGENT]
    ldr     r2, [r1, #SPEC_INIT]
    str     r2, [r0, #ROW_INIT]
    ldr     r2, [r1, #SPEC_INIT + 4]
    str     r2, [r0, #ROW_INIT + 4]
    ldr     r2, [r1, #SPEC_BEH]
    str     r2, [r0, #ROW_BEH]
    ldr     r2, [r1, #SPEC_BEH + 4]
    str     r2, [r0, #ROW_BEH + 4]
    ldr     r2, [r1, #SPEC_RESTART]
    str     r2, [r0, #ROW_RESTART]
    ldr     r2, [r1, #SPEC_SHUTDOWN]
    str     r2, [r0, #ROW_SHUTDOWN]
    ldr     r2, [r1, #SPEC_SHUTDOWN + 4]
    str     r2, [r0, #ROW_SHUTDOWN + 4]
    ldr     r2, [r1, #SPEC_FLAVOR]
    str     r2, [r0, #ROW_FLAVOR]
    ldr     r2, [r1, #SPEC_TRAMP]
    str     r2, [r0, #ROW_TRAMP]
    ldr     r2, [r1, #SPEC_DESC]
    str     r2, [r0, #ROW_DESC]
    bx      lr
    .size   rt_fill_row_from_spec, . - rt_fill_row_from_spec

// rt_spawn_child_row(r0 = row, r1 = supervisor) -> r0 = the child's ACB: the child inherits the
// supervisor's policy (spawn_common), takes the row and the supervisor, and its id is registered.
    LFUNC rt_spawn_child_row
    push    {r4-r6, lr}
    mov     r4, r0
    mov     r5, r1
    sub     sp, sp, #EXTRA_SIZE
    ldr     r0, [r4, #ROW_TRAMP]
    str     r0, [sp, #EXTRA_TRAMP]
    movw    r0, #0
    str     r0, [sp, #EXTRA_POLICY]
    str     r0, [sp, #EXTRA_CORE]
    ldr     r0, [r4, #ROW_AGENT]
    str     r0, [sp, #EXTRA_AGENT]
    str     r4, [sp, #EXTRA_ROW]
    str     r5, [sp, #EXTRA_SUP]
    ldr     r0, [r4, #ROW_DESC]
    str     r0, [sp, #EXTRA_DESC]
    ldr     r0, [r4, #ROW_INIT]
    str     r0, [sp, #EXTRA_INIT]
    ldr     r0, [r4, #ROW_INIT + 4]
    str     r0, [sp, #EXTRA_INIT + 4]
    ldr     r0, [r4, #ROW_BEH]
    str     r0, [sp, #EXTRA_BEH]
    mov     r0, sp
    bl      silica_rt_spawn_common
    add     sp, sp, #EXTRA_SIZE
    mov     r6, r0
    str     r6, [r4, #ROW_CHILD]
    movw    r0, #0
    str     r0, [r4, #ROW_CHILD + 4]
    str     r6, [r4, #ROW_CID]
    str     r0, [r4, #ROW_CID + 4]
    str     r5, [r6, #ACB_SUP]
    str     r4, [r6, #ACB_ROW]
    ldr     r0, [r4, #ROW_ID]
    mov     r1, r6
    bl      silica_rt_registry_enter
    mov     r0, r6
    pop     {r4-r6, pc}
    .size   rt_spawn_child_row, . - rt_spawn_child_row

// silica_rt_supervisor_materialize_init_children(X0 supervisor ACB, X1 init result tuple) -> X0 = 0.
    FUNC silica_rt_supervisor_materialize_init_children
    ENTRY_SAVE
    mov     r4, r0                          // r4 = supervisor
    mov     r5, r2                          // r5 = the tuple
    mov     r0, r4
    bl      silica_rt_sb_require
    mov     r6, r0                          // r6 = the supervision block
    cmp     r5, #0
    beq.w   9f
    ldr     r0, [r5, #0]
    cmp     r0, #4096
    blo.w   1f
    // slot 0 is the flags record (shape word at 0, fields from 8)
    ldr     r1, [r0, #8]
    str     r1, [r6, #SB_STRATEGY]
    ldr     r1, [r0, #16]
    str     r1, [r6, #SB_ALLOWED]
    ldr     r1, [r0, #24]
    str     r1, [r6, #SB_TIMEFRAME]
    ldr     r7, [r5, #8]                    // r7 = the list handle
    b.w     2f
1:  str     r0, [r6, #SB_STRATEGY]
    ldr     r1, [r5, #8]
    str     r1, [r6, #SB_ALLOWED]
    ldr     r1, [r5, #16]
    str     r1, [r6, #SB_TIMEFRAME]
    ldr     r7, [r5, #24]
2:  cmp     r7, #0
    beq.w   9f
    ldr     r8, [r7, #0]                    // r8 = remaining count
    ldr     r5, [r7, #8]                    // r5 = chunk
    ldr     r7, [r7, #16]                   // r7 = cursor (first chunk only)
3:  cmp     r8, #0
    beq.w   9f
    cmp     r5, #0
    beq.w   9f
    add     r1, r5, r7                      // the spec in this cell
    push    {r1}
    movw    r0, #ROW_SIZE
    bl      silica_rt_alloc
    pop     {r1}
    mov     r7, r0                          // r7 = row (the cursor is 0 from here on)
    bl      rt_fill_row_from_spec
    // §20.3.1: a child whose id a live actor or supervisor already holds is not started
    ldr     r0, [r7, #ROW_ID]
    bl      silica_rt_registry_name_held
    cmp     r0, #0
    bne.w   8f
    // the row joins the child table
    ldr     r0, [r6, #SB_CT_HEAD]
    str     r0, [r7, #ROW_NEXT]
    str     r7, [r6, #SB_CT_HEAD]
    ldr     r0, [r6, #SB_CT_LEN]
    add     r0, r0, #1
    str     r0, [r6, #SB_CT_LEN]
    mov     r0, r7
    mov     r1, r4
    bl      rt_spawn_child_row
    ldr     r5, [r5, #SPEC_LIST_CHUNK]      // next chunk (one cell per chunk)
    movw    r7, #0
    sub     r8, r8, #1
    b.w     3b
8:  bl      silica_rt_registry_name_taken
9:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_supervisor_materialize_init_children, . - silica_rt_supervisor_materialize_init_children

// count_children(X0 supervisor reference) -> X0: the rows of its table.
    FUNC silica_rt_supervisor_count_children
    ENTRY_SAVE
    movw    r1, #0
    cmp     r0, #0
    beq.w   9f
    ldr     r0, [r0, #ACB_SB]
    cmp     r0, #0
    beq.w   9f
    ldr     r0, [r0, #SB_CT_LEN]
    ENTRY_RET_X0
9:  movw    r0, #0
    ENTRY_RET_X0
    .size   silica_rt_supervisor_count_children, . - silica_rt_supervisor_count_children
