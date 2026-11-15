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

// Supervisors for the bare-metal STM32L476RG (spec §15.4.8-§15.4.13; group 3 of the actor port,
// 2026-11-09). The ESP32-S3 runtime's rt_supervisors.S (and the supervision parts of its rt_actors.S) is
// the reference for every observable behaviour; this is that file on one Cortex-M4 core.
//
//   The start          silica_rt_supervisor_materialize_init_children: the per-supervisor start trampoline
//                      (module_linkage.silica) hands the init result here on the supervisor's first
//                      schedule: the flags into the supervision block, one row and one child per spec, in
//                      the list's order, each child registered under its id.
//   Restarts           silica_rt_supervisor_maybe_restart: the restart policy (:permanent, :transient after
//                      an abnormal exit, else a tombstone), the restart intensity (allowed restarts in the
//                      time frame, seconds of the SysTick clock; a breach ends the supervisor with
//                      (:explicit, :restart_intensity_breach), a root supervisor reporting first), the
//                      strategy (:one_for_one, :one_for_all, :rest_for_one). Run by the supervisor's own
//                      loop for each exit notice in its ingress (rt_actors.S actor_main), by a drain in a
//                      caller's context (kill_abnormal, the call_supervisor operations), and by
//                      supervision_wait_and_drain_one.
//   Shutdown           silica_rt_sup_shutdown_children: an ending supervisor's subtree is ended deepest
//                      first (rt_failure.S silica_rt_actor_exit calls it before the exit path), each child
//                      killed (shutdown 0) or stopped with (:explicit, :shutdown).
//   Operations         start_child, call_supervisor's :add_child / :remove_child / :terminate_child /
//                      :restart_child / :which_children / :count_children / :get_child* /
//                      :set_report_sink, the exit reports to the sink, the trial accessors and hooks.
//
// One core, no preemption: the ESP32's scheduler lock and its spin waits on another core's exit are gone.
// An actor that is not running ends synchronously in the caller's context (rt_failure.S
// silica_rt_end_actor), so its row's exit_done is stamped when end_actor returns; the running actor ends
// at its boundary, and nothing waits for it. A walk of a supervisor's rows that may park (a respawned
// child supervisor suspends the caller until its start trampoline ran) brackets itself with
// rt_ct_enter / rt_ct_leave, so an end of the supervisor meanwhile leaves its rows and ACB to the walker.
//
// Identities (§15.1.4, rt_actors.S "Actor identity"): an actor_ref is the actor's identity, never its ACB.
// A row holds its child's ACB in ROW_CHILD (the runtime's own handle) and its identity in ROW_CID (what
// the operations answer); "no child" is all ones, as on the ESP32-S3. ROW_SPOS / ROW_SNEXT are the row
// child's spawner record, kept across its restarts. References that come in (a supervisor, a sink) are
// resolved by rt_sup_ref_acb.
//
// Layouts: rt_defs.h (ROW_*, SPEC_*, SB_*). The child table is a singly linked list of 112-byte rows at
// SB_CT_HEAD, in the init list's order (rows appended), SB_CT_LEN the high-water row count; a row whose
// child is 0 is a tombstone.

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

#define SHAPE_CHILD_INFO 65536
#define ATOM_PERMANENT   9
#define ATOM_TRANSIENT   10
#define ATOM_ONE_FOR_ALL 13
#define ATOM_REST_FOR_ONE 14
#define EXIT_REPORT_SIZE 64

    .section .rodata.silica_rt_supervisors, "a", %progbits
silica_rt_duplicate_child_id_msg:
    .asciz  "duplicate_child_id\n"

    .section .text.silica_rt_supervisors, "ax", %progbits

// =============================================================================================
// Small helpers (AAPCS).

// rt_now_seconds() -> r0: seconds since the start (the SysTick millisecond count / 1000).
    LFUNC rt_now_seconds
    push    {r4, lr}
    bl      silica_rt_now_ms
    movw    r1, #1000
    udiv    r0, r0, r1
    pop     {r4, pc}
    .size   rt_now_seconds, . - rt_now_seconds

// rt_cur() -> r0 = the running context's ACB (main's pseudo-ACB in main). Clobbers r0.
    LFUNC rt_cur
    MOV32   r0, silica_rt_cores
    ldr     r0, [r0, #CORE_CURRENT]
    bx      lr
    .size   rt_cur, . - rt_cur

// rt_cur_actor() -> r0 = the running actor's ACB, 0 in main and the scheduler. Clobbers r0, r1.
    LFUNC rt_cur_actor
    MOV32   r0, silica_rt_cores
    ldr     r0, [r0, #CORE_CURRENT]
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #KIND_ACTOR
    it      ne
    movne   r0, #0
    bx      lr
    .size   rt_cur_actor, . - rt_cur_actor

// rt_sup_ref_acb(r0:r1 = reference) -> r0 = the live ACB with that identity, or 0 (rt_actors.S
// silica_rt_ref_acb, §15.1.4). Clobbers r0, r1.
    LFUNC rt_sup_ref_acb
    b.w     silica_rt_ref_acb
    .size   rt_sup_ref_acb, . - rt_sup_ref_acb

// rt_sup_acb(r0:r1 = the supervisor's reference) -> r0 = its ACB. A supervisor that has ended (or never
// existed) raises actor_not_found (§16.1.1.1: call_supervisor is a call). Never returns 0.
    LFUNC rt_sup_acb
    push    {r4, lr}
    bl      rt_sup_ref_acb
    cmp     r0, #0
    beq.w   1f
    pop     {r4, pc}
1:  bl      silica_rt_actor_not_found       // never returns
    .size   rt_sup_acb, . - rt_sup_acb

// rt_yield_if_ready(): a call's yield point (the ESP32-S3's silica_rt_yield_if_ready): when another
// context is ready, the running one goes to the back of the ready queue and gives the core away. The
// scheduler never yields. Keeps r4-r11.
    LFUNC rt_yield_if_ready
    push    {r4, lr}
    MOV32   r1, silica_rt_cores
    ldr     r4, [r1, #CORE_CURRENT]
    ldr     r2, [r1, #CORE_SCHED]
    cmp     r4, r2
    beq.w   9f
    ldr     r2, [r1, #CORE_RQ_HEAD]         // any of the three ready queues (high, normal, low)
    ldr     r3, [r1, #CORE_RQ_HEAD + 4]
    orr     r2, r2, r3
    ldr     r3, [r1, #CORE_RQ_HEAD + 8]
    orrs    r2, r2, r3
    beq.w   9f
    movw    r0, #ST_SUSPENDED
    strb    r0, [r4, #ACB_STATUS]
    mov     r0, r4
    bl      silica_rt_make_ready
    bl      silica_rt_yield_to_sched
9:  pop     {r4, pc}
    .size   rt_yield_if_ready, . - rt_yield_if_ready

// rt_reg_store(r0 = table base, r1 = atom, r2 = acb): the registry takes the name unless a live actor holds it
// (register_actor_named's rule, §20.3.1). Clobbers r0, r3, r12.
    LFUNC rt_reg_store
    REG_BOUND r1, r3
    bhs.w   9f
    ldr     r3, [r0, r1, lsl #2]
    cmp     r3, #0
    beq.w   1f
    ldrb    r12, [r3, #ACB_ALIVE]
    cmp     r12, #0
    bne.w   9f
1:  str     r2, [r0, r1, lsl #2]
    add     r3, r1, #1
    strh    r3, [r2, #ACB_REG_NAME]
9:  bx      lr
    .size   rt_reg_store, . - rt_reg_store

// =============================================================================================
// Rows.

// rt_ct_enter(r0 = sup) / rt_ct_leave(r0 = sup): bracket a walk of a supervisor's rows that may park or
// end the supervisor meanwhile (SB_CT_USERS). A supervisor that ends while the count is not 0 leaves its
// rows (SB_CT_PENDING bit 0) and its ACB (bit 1) to the last walker. sup 0 is a no-op. Keep r4-r11.
    LFUNC rt_ct_enter
    cmp     r0, #0
    beq.w   9f
    ldr     r1, [r0, #ACB_SB]
    cmp     r1, #0
    beq.w   9f
    ldr     r2, [r1, #SB_CT_USERS]
    add     r2, r2, #1
    str     r2, [r1, #SB_CT_USERS]
9:  bx      lr
    .size   rt_ct_enter, . - rt_ct_enter

    LFUNC rt_ct_leave
    push    {r4, r5, r6, lr}
    mov     r4, r0
    cmp     r4, #0
    beq.w   9f
    ldr     r5, [r4, #ACB_SB]
    cmp     r5, #0
    beq.w   9f
    ldr     r1, [r5, #SB_CT_USERS]
    cmp     r1, #0
    beq.w   9f                              // never entered: nothing to leave
    sub     r1, r1, #1
    str     r1, [r5, #SB_CT_USERS]
    cmp     r1, #0
    bne.w   9f
    ldr     r6, [r5, #SB_CT_PENDING]
    cmp     r6, #0
    beq.w   9f
    movw    r1, #0
    str     r1, [r5, #SB_CT_PENDING]
    tst     r6, #1
    beq.w   1f
    mov     r0, r4
    bl      silica_rt_child_table_free      // no walker is left: this time it frees
1:  tst     r6, #2
    beq.w   9f
    mov     r0, r4
    bl      silica_rt_free_acb
9:  pop     {r4, r5, r6, pc}
    .size   rt_ct_leave, . - rt_ct_leave

// silica_rt_child_table_free(r0 = acb): run when the supervisor ends (rt_failure.S exit path). The chain
// is detached, the anchors cleared, every live child still pointing at its row (ACB_ROW) cut loose, then
// each row goes back to the heap. While a walker holds the rows the free is left to the last one. AAPCS.
    FUNC silica_rt_child_table_free
    push    {r4, r5, r6, lr}
    ldr     r4, [r0, #ACB_SB]
    cmp     r4, #0
    beq.w   9f
    ldr     r1, [r4, #SB_CT_USERS]
    cmp     r1, #0
    beq.w   1f
    ldr     r1, [r4, #SB_CT_PENDING]
    orr     r1, r1, #1
    str     r1, [r4, #SB_CT_PENDING]
    b.w     9f
1:  ldr     r5, [r4, #SB_CT_HEAD]           // r5 = the detached chain
    movw    r1, #0
    str     r1, [r4, #SB_CT_HEAD]
    str     r1, [r4, #SB_CT_LEN]
    mov     r6, r5
2:  cmp     r6, #0
    beq.w   3f
    ldr     r2, [r6, #ROW_CHILD]
    cmp     r2, #0
    beq.w   21f
    ldr     r3, [r2, #ACB_ROW]
    cmp     r3, r6
    it      eq
    streq   r1, [r2, #ACB_ROW]              // an orphaned child no longer stamps this row at its end
21: ldr     r6, [r6, #ROW_NEXT]
    b.w     2b
3:  cmp     r5, #0
    beq.w   9f
    ldr     r6, [r5, #ROW_NEXT]
    mov     r0, r5
    bl      silica_rt_free
    mov     r5, r6
    b.w     3b
9:  pop     {r4, r5, r6, pc}
    .size   silica_rt_child_table_free, . - silica_rt_child_table_free

// rt_row_release_child(r0 = row): the row's child slot is given up (a tombstone, or a respawn about to
// take the row); the old child's ACB_ROW is cleared if it still names this row. Clobbers r1, r2.
    LFUNC rt_row_release_child
    ldr     r1, [r0, #ROW_CHILD]
    cmp     r1, #0
    beq.w   1f
    ldr     r2, [r1, #ACB_ROW]
    cmp     r2, r0
    bne.w   1f
    movw    r2, #0
    str     r2, [r1, #ACB_ROW]
1:  movw    r2, #0
    str     r2, [r0, #ROW_CHILD]
    str     r2, [r0, #ROW_CHILD + 4]
    str     r2, [r0, #ROW_STOPPING]
    bx      lr
    .size   rt_row_release_child, . - rt_row_release_child

// rt_append_row(r0 = sup) -> r0 = a new zeroed row at the tail (the caller made the block); len unchanged.
    LFUNC rt_append_row
    push    {r4, lr}
    mov     r4, r0
    movw    r0, #ROW_SIZE
    bl      silica_rt_alloc
    ldr     r1, [r4, #ACB_SB]
    ldr     r2, [r1, #SB_CT_HEAD]
    cmp     r2, #0
    bne.w   1f
    str     r0, [r1, #SB_CT_HEAD]
    pop     {r4, pc}
1:  ldr     r3, [r2, #ROW_NEXT]
    cmp     r3, #0
    beq.w   2f
    mov     r2, r3
    b.w     1b
2:  str     r0, [r2, #ROW_NEXT]
    pop     {r4, pc}
    .size   rt_append_row, . - rt_append_row

// rt_row_at(r0 = acb, r1 = index) -> r0 = row or 0. Clobbers r1.
    LFUNC rt_row_at
    ldr     r0, [r0, #ACB_SB]
    cmp     r0, #0
    beq.w   9f
    ldr     r0, [r0, #SB_CT_HEAD]
1:  cmp     r0, #0
    beq.w   9f
    cmp     r1, #0
    beq.w   9f
    ldr     r0, [r0, #ROW_NEXT]
    sub     r1, r1, #1
    b.w     1b
9:  bx      lr
    .size   rt_row_at, . - rt_row_at

// rt_live_row_by_id(r0 = sup, r1 = id) -> r0 = the live row with that id, or 0. Clobbers r2.
    LFUNC rt_live_row_by_id
    ldr     r0, [r0, #ACB_SB]
    cmp     r0, #0
    beq.w   9f
    ldr     r0, [r0, #SB_CT_HEAD]
1:  cmp     r0, #0
    beq.w   9f
    ldr     r2, [r0, #ROW_CHILD]
    cmp     r2, #0
    beq.w   2f
    ldr     r2, [r0, #ROW_ID]
    cmp     r2, r1
    beq.w   9f
2:  ldr     r0, [r0, #ROW_NEXT]
    b.w     1b
9:  bx      lr
    .size   rt_live_row_by_id, . - rt_live_row_by_id

// rt_row_child_ref(r0 = row or 0) -> r0:r1 = the row's child reference (ROW_CID), or all ones for no row
// or a tombstone.
    LFUNC rt_row_child_ref
    cmp     r0, #0
    beq.w   1f
    ldr     r1, [r0, #ROW_CHILD]
    cmp     r1, #0
    beq.w   1f
    ldr     r1, [r0, #ROW_CID + 4]
    ldr     r0, [r0, #ROW_CID]
    bx      lr
1:  mvn     r0, #0
    mvn     r1, #0
    bx      lr
    .size   rt_row_child_ref, . - rt_row_child_ref

// rt_fill_row_from_spec(r0 = row, r1 = spec): the visible fields and the hidden trampoline / descriptor;
// a fresh row state (no child, not stopping, exit_done clear). Clobbers r2.
    LFUNC rt_fill_row_from_spec
    movw    r2, #0
    str     r2, [r0, #ROW_CHILD]
    str     r2, [r0, #ROW_CHILD + 4]
    str     r2, [r0, #ROW_EXIT_DONE]
    str     r2, [r0, #ROW_STOPPING]
    str     r2, [r0, #ROW_SPOS]
    str     r2, [r0, #ROW_SNEXT]
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

// silica_rt_supervisor_spawn_child_row(r0 = row, r1 = sup) -> r0 = the child's ACB (the ESP32's
// ..._by_flavor): the row's previous child lets go of the row, exit_done is cleared, the child is spawned
// with the row's initial state, behaviour, agent type, trampoline and descriptor under the supervisor
// (whose policy it inherits). A child supervisor that ended inside its start trampoline (its init failed)
// gives the row its ACB, which its exit notice is matched by, and nothing else: no name, nothing written
// into it. Otherwise its id is registered (in the dangerous registry as well for a :dangerous child).
// The row holds the child now: the spawner's hold (TR_SPAWNER) ends. AAPCS.
    FUNC silica_rt_supervisor_spawn_child_row
    push    {r4-r7, lr}
    mov     r4, r0                          // r4 = row
    mov     r5, r1                          // r5 = sup
    bl      rt_row_release_child
    movw    r0, #0
    str     r0, [r4, #ROW_EXIT_DONE]
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
    bl      silica_rt_spawn_common          // (a child supervisor: returns once its trampoline ran)
    add     sp, sp, #EXTRA_SIZE
    mov     r6, r0                          // r6 = child
    ldr     r0, [r6, #ACB_ID]               // the child's identity (§15.1.4)
    str     r0, [r4, #ROW_CID]
    ldr     r0, [r6, #ACB_ID + 4]
    str     r0, [r4, #ROW_CID + 4]
    str     r6, [r4, #ROW_CHILD]
    movw    r0, #0
    str     r0, [r4, #ROW_CHILD + 4]
    ldr     r0, [r6, #ACB_SB]
    cmp     r0, #0
    beq.w   1f
    ldr     r0, [r0, #SB_TRAMP_RAN]
    tst     r0, #TR_INIT_DEAD
    bne.w   8f
1:  str     r5, [r6, #ACB_SUP]
    str     r4, [r6, #ACB_ROW]
    ldr     r0, [r4, #ROW_FLAVOR]
    cmp     r0, #ATOM_DANGEROUS
    bne.w   2f
    REG_TABLE r0, silica_dangerous_pid_registry_ref
    ldr     r1, [r4, #ROW_ID]
    mov     r2, r6
    bl      rt_reg_store
2:  REG_TABLE r0, silica_pid_registry_ref
    ldr     r1, [r4, #ROW_ID]
    mov     r2, r6
    bl      rt_reg_store
8:  mov     r0, r6
    movw    r1, #TR_SPAWNER
    bl      silica_rt_tramp_release
    mov     r0, r6
    pop     {r4-r7, pc}
    .size   silica_rt_supervisor_spawn_child_row, . - silica_rt_supervisor_spawn_child_row

// =============================================================================================
// The start.

// silica_rt_supervisor_materialize_init_children(X0 supervisor ACB, X1 init result tuple) -> X0 = 0. The
// tuple holds the supervisor_flags record (a pointer in slot 0, or the three fields flat in slots 0-2 for
// older shapes) and the child-spec list handle (slot 1, or slot 3 in the flat shape). One row and one
// child per spec, in the list's order. §20.3.1: a child whose id a live actor holds is not started and
// the supervisor's init fails with :language_error (silica_rt_registry_name_taken).
    FUNC silica_rt_supervisor_materialize_init_children
    ENTRY_SAVE
    mov     r4, r0                          // r4 = supervisor
    mov     r5, r2                          // r5 = the tuple
    mov     r0, r4
    bl      silica_rt_sb_require
    mov     r6, r0                          // r6 = the supervision block
    mov     r0, r4
    bl      rt_ct_enter
    cmp     r5, #0
    beq.w   9f
    ldr     r0, [r5, #0]
    cmp     r0, #4096
    blo.w   1f
    ldr     r1, [r0, #8]                    // slot 0 is the flags record (shape word at 0, fields from 8)
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
    add     r7, r5, r7                      // r7 = the spec in this cell
    mov     r0, r4
    bl      rt_append_row
    mov     r1, r7
    mov     r7, r0                          // r7 = row
    bl      rt_fill_row_from_spec
    ldr     r0, [r7, #ROW_ID]
    bl      silica_rt_registry_name_held
    cmp     r0, #0
    bne.w   8f
    mov     r0, r7
    mov     r1, r4
    bl      silica_rt_supervisor_spawn_child_row
    ldr     r6, [r4, #ACB_SB]
    ldr     r0, [r6, #SB_CT_LEN]
    add     r0, r0, #1
    str     r0, [r6, #SB_CT_LEN]
    ldr     r5, [r5, #SPEC_LIST_CHUNK]      // next chunk (one cell per chunk)
    movw    r7, #0
    sub     r8, r8, #1
    b.w     3b
8:  mov     r0, r4
    bl      rt_ct_leave
    bl      silica_rt_registry_name_taken   // never returns
9:  mov     r0, r4
    bl      rt_ct_leave
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_supervisor_materialize_init_children, . - silica_rt_supervisor_materialize_init_children

// rt_start_child_in(r0 = sup, r1 = spec) -> r0:r1 = the child's reference (all ones when its id is held):
// the first tombstone row is reused, else a row is appended.
    LFUNC rt_start_child_in
    push    {r4-r8, lr}
    mov     r4, r0                          // r4 = sup
    mov     r5, r1                          // r5 = spec
    bl      silica_rt_sb_require            // the running actor becomes a supervisor if it was not one
    mov     r0, r4
    bl      rt_ct_enter
    ldr     r6, [r4, #ACB_SB]
    ldr     r6, [r6, #SB_CT_HEAD]
    movw    r7, #0                          // r7 = appended
1:  cmp     r6, #0
    beq.w   2f
    ldr     r0, [r6, #ROW_CHILD]
    cmp     r0, #0
    beq.w   3f
    ldr     r6, [r6, #ROW_NEXT]
    b.w     1b
2:  mov     r0, r4
    bl      rt_append_row
    mov     r6, r0
    movw    r7, #1
3:  mov     r0, r6
    mov     r1, r5
    bl      rt_fill_row_from_spec
    ldr     r0, [r6, #ROW_ID]
    bl      silica_rt_registry_name_held
    cmp     r0, #0
    beq.w   4f
    movw    r0, #0                          // held: no child; the row is a tombstone the next start reuses
    b.w     5f
4:  mov     r0, r6
    mov     r1, r4
    bl      silica_rt_supervisor_spawn_child_row
    mov     r0, r6
5:  bl      rt_row_child_ref
    mov     r5, r0
    mov     r8, r1
    cmp     r7, #0
    beq.w   9f
    ldr     r2, [r4, #ACB_SB]
    ldr     r3, [r2, #SB_CT_LEN]
    add     r3, r3, #1
    str     r3, [r2, #SB_CT_LEN]
9:  mov     r0, r4
    bl      rt_ct_leave
    mov     r0, r5
    mov     r1, r8
    pop     {r4-r8, pc}
    .size   rt_start_child_in, . - rt_start_child_in

// start_child(X0 spec) -> X0 the child, in the running supervisor (all ones in main).
    FUNC silica_rt_supervisor_start_child
    ENTRY_SAVE
    mov     r4, r0
    bl      rt_cur_actor
    cmp     r0, #0
    beq.w   9f
    mov     r1, r4
    bl      rt_start_child_in
    ENTRY_RET_X0
9:  mvn     r0, #0
    mvn     r1, #0
    ENTRY_RET_X0
    .size   silica_rt_supervisor_start_child, . - silica_rt_supervisor_start_child

// add_child(X0 sup, X1 spec) -> X0 the child (call_supervisor :add_child). §20.3.1: an id a live actor
// holds starts no child; the asking actor fails with (:explicit, :duplicate_child_id).
    FUNC silica_rt_supervisor_add_child
    ENTRY_SAVE
    mov     r5, r2                          // r5 = spec
    bl      rt_sup_acb
    mov     r4, r0                          // r4 = sup
    bl      silica_rt_supervisor_drain_ingress
    ldr     r0, [r5, #SPEC_ID]
    bl      silica_rt_registry_name_held
    cmp     r0, #0
    beq.w   1f
    bl      rt_duplicate_child_id           // never returns
1:  mov     r0, r4
    mov     r1, r5
    bl      rt_start_child_in
    ENTRY_RET_X0
    .size   silica_rt_supervisor_add_child, . - silica_rt_supervisor_add_child

// rt_duplicate_child_id(): the running actor fails with (:explicit, :duplicate_child_id); in main the
// language-level failure (the atom's name, the pending reports, status 1). Never returns.
    LFUNC rt_duplicate_child_id
    bl      rt_cur_actor
    cmp     r0, #0
    beq.w   1f
    MOV32   r0, silica_registry_atom_duplicate_child_id
    ldr     r0, [r0]
    bl      silica_rt_actor_trap_explicit
1:  MOV32   r0, silica_rt_duplicate_child_id_msg
    b.w     silica_rt_main_fail_exit
    .size   rt_duplicate_child_id, . - rt_duplicate_child_id

// rt_sup_end_elsewhere(r0 = sup): a supervisor whose end is decided outside its own context ends in its
// own: marked ended and made ready, so the scheduler runs its exit path (which shuts its children down
// and reports). Clobbers r0-r2.
    LFUNC rt_sup_end_elsewhere
    movw    r1, #0
    strb    r1, [r0, #ACB_ALIVE]
    b.w     silica_rt_make_ready
    .size   rt_sup_end_elsewhere, . - rt_sup_end_elsewhere

// rt_sup_fail(r0 = sup, r1 = the failure atom): the supervisor fails with (:explicit, atom), tag 4 (a
// restart found its child's name held, or the restart intensity was breached). Decided in a caller's
// context it ends in its own (rt_sup_end_elsewhere). In its own context: a root supervisor reports its
// own failure here, after its children are shut down (claiming SB_SYNC_REPORTED so its exit path does
// not report again) and the root note follows; it then ends at its boundary. A supervised one ends at
// its boundary and its exit, with this reason, reaches its parent. r2 = 1 (the breach): alive is cleared
// before the shutdown so its restart logic starts nothing more; 0 (a duplicate id): as the ESP32-S3.
    LFUNC rt_sup_fail
    push    {r4, r5, r6, lr}
    mov     r4, r0
    mov     r6, r2
    strh    r1, [r4, #ACB_REASON_ATOM]
    movw    r0, #4
    strb    r0, [r4, #ACB_REASON_TAG]
    bl      rt_cur
    cmp     r0, r4
    beq.w   1f
    mov     r0, r4
    bl      rt_sup_end_elsewhere
    pop     {r4, r5, r6, pc}
1:  ldr     r0, [r4, #ACB_SUP]
    cmp     r0, #0
    bne.w   2f
    ldr     r5, [r4, #ACB_SB]
    cmp     r5, #0
    beq.w   2f
    ldr     r0, [r5, #SB_SYNC_REPORTED]
    cmp     r0, #0
    bne.w   2f
    movw    r0, #1
    str     r0, [r5, #SB_SYNC_REPORTED]
    cmp     r6, #0
    beq.w   11f
    movw    r0, #0
    strb    r0, [r4, #ACB_ALIVE]
11: mov     r0, r4                          // its children first, so their reports precede its own
    bl      silica_rt_sup_shutdown_children
    mov     r0, r4
    bl      silica_rt_root_report_and_note
    cmp     r6, #0
    bne.w   9f                              // alive already 0: the exit path runs at its boundary
2:  mov     r0, r4
    movw    r1, #4
    bl      silica_rt_end_actor
9:  pop     {r4, r5, r6, pc}
    .size   rt_sup_fail, . - rt_sup_fail

// rt_respawn_row(r0 = row, r1 = sup) -> r0 = 0 the row's child was started, 1 its id is held by a live
// actor: no child, the row is a tombstone and the supervisor has failed (:duplicate_child_id).
    LFUNC rt_respawn_row
    push    {r4, r5, r6, lr}
    mov     r4, r0
    mov     r5, r1
    ldr     r0, [r4, #ROW_ID]
    bl      silica_rt_registry_name_held
    cmp     r0, #0
    beq.w   1f
    mov     r0, r4
    bl      rt_row_release_child
    mov     r0, r5
    MOV32   r1, silica_registry_atom_duplicate_child_id
    ldr     r1, [r1]
    movw    r2, #0
    bl      rt_sup_fail
    movw    r0, #1
    pop     {r4, r5, r6, pc}
1:  mov     r0, r4
    mov     r1, r5
    bl      silica_rt_supervisor_spawn_child_row
    movw    r0, #0
    pop     {r4, r5, r6, pc}
    .size   rt_respawn_row, . - rt_respawn_row

// =============================================================================================
// Exit notices.

// silica_rt_supervisor_drain_ingress(r0 = sup): every structured exit notice waiting in the supervisor's
// ingress runs the restart logic now, in the caller's context, and is reported to the sink. AAPCS.
    FUNC silica_rt_supervisor_drain_ingress
    push    {r4-r7, lr}
    mov     r4, r0
    cmp     r4, #0
    beq.w   9f
    bl      rt_ct_enter
1:  ldr     r5, [r4, #ACB_SB]
    cmp     r5, #0
    beq.w   8f
    ldr     r6, [r5, #SB_IN_HEAD]           // r6 = the node
    cmp     r6, #0
    beq.w   8f
    ldr     r0, [r6, #MSG_NEXT]
    str     r0, [r5, #SB_IN_HEAD]
    cmp     r0, #0
    it      eq
    streq   r0, [r5, #SB_IN_TAIL]
    ldr     r0, [r5, #SB_IN_DEPTH]
    cmp     r0, #0
    itt     ne
    subne   r0, r0, #1
    strne   r0, [r5, #SB_IN_DEPTH]
    ldr     r0, [r6, #MSG_INGRESS_KIND]
    cmp     r0, #0
    bne.w   4f
    ldr     r7, [r6, #MSG_PAYLOAD]          // r7 = the notice
    cmp     r7, #0
    beq.w   4f
    mov     r0, r4
    mov     r1, r7
    bl      rt_handle_notice
    mov     r0, r7
    bl      silica_rt_exit_payload_free
4:  mov     r0, r6
    bl      silica_rt_free_node
    b.w     1b
8:  mov     r0, r4
    bl      rt_ct_leave
9:  pop     {r4-r7, pc}
    .size   silica_rt_supervisor_drain_ingress, . - silica_rt_supervisor_drain_ingress

// silica_rt_supervisor_handle_notice(r0 = sup, r1 = notice): the restart logic for one exit notice, then
// the exit report to the sink (spec §15.4.10.5). The notice stays the caller's. AAPCS.
    FUNC silica_rt_supervisor_handle_notice
    .thumb_func
rt_handle_notice:
    push    {r4, r5, r6, lr}
    mov     r4, r0
    mov     r5, r1
    ldr     r0, [r5, #0]
    mov     r1, r4
    ldr     r2, [r5, #8]
    bl      silica_rt_supervisor_maybe_restart
    mov     r2, r0                          // the row the notice was matched to (0: none)
    mov     r3, r1                          // 1 when its child was restarted
    mov     r0, r4
    mov     r1, r5
    bl      silica_rt_sup_exit_report
    pop     {r4, r5, r6, pc}
    .size   silica_rt_supervisor_handle_notice, . - silica_rt_supervisor_handle_notice

// rt_drop_pending_exit(r0 = sup, r1 = child): the exit notice a deliberately stopped child left in the
// supervisor's ingress is removed, so no restart follows.
    LFUNC rt_drop_pending_exit
    push    {r4-r7, lr}
    ldr     r4, [r0, #ACB_SB]               // r4 = the supervision block
    cmp     r4, #0
    beq.w   9f
    add     r5, r4, #SB_IN_HEAD             // r5 = &link to the current node (MSG_NEXT is 0)
    ldr     r6, [r5]
1:  cmp     r6, #0
    beq.w   9f
    ldr     r2, [r6, #MSG_INGRESS_KIND]
    cmp     r2, #0
    bne.w   2f
    ldr     r7, [r6, #MSG_PAYLOAD]
    cmp     r7, #0
    beq.w   2f
    ldr     r2, [r7, #0]
    cmp     r2, r1
    beq.w   3f
2:  mov     r5, r6
    ldr     r6, [r6, #MSG_NEXT]
    b.w     1b
3:  ldr     r2, [r6, #MSG_NEXT]
    str     r2, [r5]
    cmp     r2, #0
    bne.w   4f
    add     r3, r4, #SB_IN_HEAD             // the removed node was the tail
    cmp     r5, r3
    it      eq
    moveq   r5, #0
    str     r5, [r4, #SB_IN_TAIL]
4:  ldr     r2, [r4, #SB_IN_DEPTH]
    cmp     r2, #0
    itt     ne
    subne   r2, r2, #1
    strne   r2, [r4, #SB_IN_DEPTH]
    mov     r0, r7
    bl      silica_rt_exit_payload_free
    mov     r0, r6
    bl      silica_rt_free_node
9:  pop     {r4-r7, pc}
    .size   rt_drop_pending_exit, . - rt_drop_pending_exit

// silica_rt_sup_shutdown_children(r0 = sup): the coordinated shutdown of an ending supervisor's live
// children (spec §15.4.8.4, §15.4.12.2), from its exit path (rt_failure.S silica_rt_actor_exit) and, for a
// root supervisor that fails by itself, before its report. Deepest first, one child at a time: each round
// finds the last live row of the deepest supervisor below sup that still has one (a child supervisor with
// live children is descended into), marks it stopping, ends its child (shutdown 0: (:explicit, :killed);
// shutdown > 0: (:explicit, :shutdown), unless it already has a reason) through silica_rt_end_actor_leaf,
// whose exit path shuts down nothing again, and settles the row (a tombstone). The running actor itself is
// never chosen (it ends at its boundary). By the return every child's name is free (§20.3.1). AAPCS.
// r4 = sup, r5 = the supervisor whose table is searched, r6 = the row, r7 = the running context.
    FUNC silica_rt_sup_shutdown_children
    push    {r4-r8, lr}
    mov     r4, r0
    ldr     r0, [r4, #ACB_SB]
    cmp     r0, #0
    beq.w   9f
    bl      rt_cur
    mov     r7, r0
10: mov     r5, r4
11: mov     r0, r5
    bl      rt_last_live_row
    cmp     r0, #0
    beq.w   15f
    mov     r6, r0
    ldr     r8, [r6, #ROW_CHILD]
    ldrb    r0, [r8, #ACB_ALIVE]            // a child supervisor with a live row of its own: descend
    cmp     r0, #0
    beq.w   14f
    ldr     r0, [r8, #ACB_SB]
    cmp     r0, #0
    beq.w   14f
    mov     r0, r8
    bl      rt_last_live_row
    cmp     r0, #0
    beq.w   14f
    mov     r5, r8
    b.w     11b
14: mov     r0, r5                          // the row's table is held while its child ends
    bl      rt_ct_enter
    movw    r0, #1
    str     r0, [r6, #ROW_STOPPING]
    ldrb    r0, [r8, #ACB_KIND]
    cmp     r0, #KIND_ACTOR
    bne.w   23f
    ldrb    r0, [r8, #ACB_ALIVE]
    cmp     r0, #0
    beq.w   21f
    ldrb    r0, [r8, #ACB_REASON_TAG]
    cmp     r0, #0
    bne.w   21f
    MOV32   r0, silica_registry_atom_killed // shutdown 0 (or negative): (:explicit, :killed)
    ldr     r1, [r6, #ROW_SHUTDOWN + 4]
    cmp     r1, #0
    blt.w   20f
    bne.w   19f
    ldr     r1, [r6, #ROW_SHUTDOWN]
    cmp     r1, #0
    beq.w   20f
19: MOV32   r0, silica_registry_atom_shutdown   // shutdown > 0: (:explicit, :shutdown)
20: ldr     r0, [r0]
    strh    r0, [r8, #ACB_REASON_ATOM]
21: mov     r0, r8
    movw    r1, #4
    bl      silica_rt_end_actor_leaf
23: mov     r0, r6
    bl      rt_row_release_child
    mov     r0, r5
    bl      rt_ct_leave
    b.w     10b
15: cmp     r5, r4
    bne.w   10b                             // a child's last row went meanwhile: search again
9:  pop     {r4-r8, pc}
    .size   silica_rt_sup_shutdown_children, . - silica_rt_sup_shutdown_children

// rt_last_live_row(r0 = sup) -> r0 = its last row whose child is set, not the running context (r7 of the
// caller) and not ended yet (exit_done), or 0. Clobbers r1-r3.
    LFUNC rt_last_live_row
    ldr     r1, [r0, #ACB_SB]
    movw    r0, #0
    cmp     r1, #0
    beq.w   9f
    ldr     r1, [r1, #SB_CT_HEAD]
1:  cmp     r1, #0
    beq.w   9f
    ldr     r2, [r1, #ROW_CHILD]
    cmp     r2, #0
    beq.w   2f
    cmp     r2, r7
    beq.w   2f
    ldr     r3, [r1, #ROW_EXIT_DONE]
    cmp     r3, #0
    it      eq
    moveq   r0, r1
2:  ldr     r1, [r1, #ROW_NEXT]
    b.w     1b
9:  bx      lr
    .size   rt_last_live_row, . - rt_last_live_row

// rt_stop_child(r0 = sup, r1 = row): end the child in a row (spec §15.4.12.2 sequential stop); its exit
// notice is dropped and exit_done cleared. The row is marked stopping, so a notice served later restarts
// nothing; the caller settles the row. A child that is the running actor ends at its boundary.
    LFUNC rt_stop_child
    push    {r4, r5, r6, lr}
    mov     r4, r0
    mov     r5, r1
    ldr     r6, [r5, #ROW_CHILD]
    cmp     r6, #0
    beq.w   9f
    movw    r0, #1
    str     r0, [r5, #ROW_STOPPING]
    mov     r0, r6
    movw    r1, #0
    bl      silica_rt_end_actor
    mov     r0, r4
    mov     r1, r6
    bl      rt_drop_pending_exit
    movw    r0, #0
    str     r0, [r5, #ROW_EXIT_DONE]
9:  pop     {r4, r5, r6, pc}
    .size   rt_stop_child, . - rt_stop_child

// =============================================================================================
// silica_rt_supervisor_maybe_restart(r0 = dead child, r1 = sup, r2 = reason tag) -> r0 = the row the
// notice was matched to (0: no row, a row being stopped by a caller, or an ended supervisor), r1 = 1 when
// that row's child was restarted (§15.4.12; see the head of the file). AAPCS.
// r4 = sup, r5 = row, r6 = reason tag, r7 = the supervision block, r8 = an iterator.
    FUNC silica_rt_supervisor_maybe_restart
    push    {r4-r8, lr}
    mov     r4, r1
    mov     r6, r2
    ldr     r7, [r4, #ACB_SB]
    cmp     r7, #0
    beq.w   90f
    ldrb    r1, [r4, #ACB_ALIVE]            // an ended supervisor restarts and tombstones nothing: its
    cmp     r1, #0                          // children are being shut down
    beq.w   90f
    ldr     r5, [r7, #SB_CT_HEAD]
1:  cmp     r5, #0
    beq.w   90f
    ldr     r1, [r5, #ROW_CHILD]
    cmp     r1, r0
    beq.w   2f
    ldr     r5, [r5, #ROW_NEXT]
    b.w     1b
2:  ldr     r1, [r5, #ROW_STOPPING]         // a row being stopped by a caller is that caller's to settle
    cmp     r1, #0
    bne.w   90f
    // policy
    ldr     r1, [r5, #ROW_RESTART]
    cmp     r1, #ATOM_PERMANENT
    beq.w   3f
    cmp     r1, #ATOM_TRANSIENT
    bne.w   80f
    cmp     r6, #0
    beq.w   80f
3:  // restart intensity
    ldr     r2, [r7, #SB_ALLOWED]
    ldr     r3, [r7, #SB_TIMEFRAME]
    orrs    r1, r2, r3
    beq.w   4f
    cmp     r2, #0
    beq.w   70f
    bl      rt_now_seconds
    add     r0, r0, #1                      // now + 1 (0 marks "no window yet")
    ldr     r7, [r4, #ACB_SB]
    ldr     r2, [r7, #SB_ALLOWED]
    ldr     r3, [r7, #SB_TIMEFRAME]
    ldr     r1, [r7, #SB_WINDOW]
    cmp     r1, #0
    beq.w   31f
    sub     r1, r0, r1
    cmp     r3, r1
    blo.w   31f                             // outside the window: a new one
    ldr     r1, [r7, #SB_RESTARTS]
    add     r1, r1, #1
    cmp     r2, r1
    blo.w   70f                             // count > allowed
    str     r1, [r7, #SB_RESTARTS]
    b.w     4f
31: str     r0, [r7, #SB_WINDOW]
    movw    r1, #1
    str     r1, [r7, #SB_RESTARTS]
    cmp     r2, r1
    blo.w   70f
4:  // strategy
    ldr     r7, [r4, #ACB_SB]
    ldr     r1, [r7, #SB_STRATEGY]
    cmp     r1, #ATOM_ONE_FOR_ALL
    beq.w   5f
    cmp     r1, #ATOM_REST_FOR_ONE
    beq.w   6f
    mov     r0, r5
    mov     r1, r4
    bl      rt_respawn_row
    cmp     r0, #0
    bne.w   91f
    b.w     92f
5:  // one_for_all: stop every other live child, then respawn every row that has a child
    ldr     r8, [r7, #SB_CT_HEAD]
51: cmp     r8, #0
    beq.w   52f
    cmp     r8, r5
    beq.w   511f
    ldr     r0, [r8, #ROW_CHILD]
    cmp     r0, #0
    beq.w   511f
    mov     r0, r4
    mov     r1, r8
    bl      rt_stop_child
511: ldr    r8, [r8, #ROW_NEXT]
    b.w     51b
52: ldr     r7, [r4, #ACB_SB]
    ldr     r8, [r7, #SB_CT_HEAD]
53: cmp     r8, #0
    beq.w   92f
    ldr     r0, [r8, #ROW_CHILD]
    cmp     r0, #0
    beq.w   531f
    mov     r0, r8
    mov     r1, r4
    bl      rt_respawn_row
    cmp     r0, #0
    bne.w   91f
531: ldr    r8, [r8, #ROW_NEXT]
    b.w     53b
6:  // rest_for_one: stop and tombstone the rows after the dead one, then respawn from it on
    ldr     r8, [r5, #ROW_NEXT]
61: cmp     r8, #0
    beq.w   62f
    ldr     r0, [r8, #ROW_CHILD]
    cmp     r0, #0
    beq.w   611f
    mov     r0, r4
    mov     r1, r8
    bl      rt_stop_child
    mov     r0, r8
    bl      rt_row_release_child
611: ldr    r8, [r8, #ROW_NEXT]
    b.w     61b
62: mov     r8, r5
63: cmp     r8, #0
    beq.w   92f
    mov     r0, r8
    mov     r1, r4
    bl      rt_respawn_row
    cmp     r0, #0
    bne.w   91f
    ldr     r8, [r8, #ROW_NEXT]
    b.w     63b
70: // the restart intensity is breached: the supervisor fails with (:explicit, :restart_intensity_breach)
    mov     r0, r4
    MOV32   r1, silica_registry_atom_restart_breach
    ldr     r1, [r1]
    movw    r2, #1
    bl      rt_sup_fail
    b.w     91f
80: // no restart: a tombstone
    mov     r0, r5
    bl      rt_row_release_child
    b.w     91f
90: movw    r0, #0
    movw    r1, #0
    pop     {r4-r8, pc}
91: mov     r0, r5                          // the row; its child was not restarted
    movw    r1, #0
    pop     {r4-r8, pc}
92: mov     r0, r5                          // the row; its child was restarted
    movw    r1, #1
    pop     {r4-r8, pc}
    .size   silica_rt_supervisor_maybe_restart, . - silica_rt_supervisor_maybe_restart

// silica_rt_sup_exit_report(r0 = sup, r1 = notice, r2 = row, r3 = restarted): the exit report of spec
// §15.4.10.5, cast to the supervisor's report sink (SB_SINK, named by :set_report_sink or inherited at
// spawn) after every exit notice the restart logic handled; nothing when the notice matched no row or no
// sink is named. The record { child, child_id, failure_reason, restarted, new_child } is a shape word
// (silica_registry_shape_exit_report) and one 8-byte slot per field; failure_reason is the fixed atom for
// tags 0, 2 and 3, a pointer to the pair (:explicit, atom) at +48 of the same 64-byte block for tag 4,
// :unknown otherwise. The block is the message's mailbox buffer (the receiver's dispatch frees it); a sink
// that has ended or is call-only gets nothing. The supervisor never waits (no back-pressure). AAPCS.
    FUNC silica_rt_sup_exit_report
    push    {r4-r8, lr}
    cmp     r2, #0
    beq.w   9f
    ldr     r12, [r0, #ACB_SB]
    cmp     r12, #0
    beq.w   9f
    mov     r4, r1                          // r4 = notice
    mov     r5, r2                          // r5 = row
    mov     r6, r3                          // r6 = restarted
    ldr     r0, [r12, #SB_SINK]
    ldr     r1, [r12, #SB_SINK + 4]
    orrs    r12, r1, r0
    beq.w   9f
    bl      rt_sup_ref_acb
    cmp     r0, #0
    beq.w   9f                              // the sink has ended
    ldr     r1, [r0, #ACB_CONV]
    and     r1, r1, #3
    cmp     r1, #1
    beq.w   9f                              // call-only (§16.2.6.4)
    mov     r7, r0                          // r7 = the sink's ACB
    movw    r0, #EXIT_REPORT_SIZE
    bl      silica_rt_alloc                 // zeroed
    mov     r8, r0                          // r8 = the record
    ldr     r1, [r4, #8]                    // the reason tag -> the failure_reason word
    movw    r2, #ATOM_NORMAL
    cmp     r1, #0
    beq.w   2f
    movw    r2, #ATOM_LANGUAGE_ERROR
    cmp     r1, #2
    beq.w   2f
    movw    r2, #ATOM_MEMORY_FAULT
    cmp     r1, #3
    beq.w   2f
    movw    r2, #ATOM_UNKNOWN
    cmp     r1, #4
    bne.w   2f
    movw    r2, #ATOM_EXPLICIT              // (:explicit, atom): the pair at +48
    str     r2, [r8, #48]
    ldr     r2, [r4, #16]
    str     r2, [r8, #56]
    add     r2, r8, #48
2:  str     r2, [r8, #24]                   // failure_reason
    MOV32   r1, silica_registry_shape_exit_report
    ldr     r1, [r1]
    str     r1, [r8, #0]
    ldr     r1, [r4, #40]                   // child: the ended child's identity
    str     r1, [r8, #8]
    ldr     r2, [r4, #44]
    str     r2, [r8, #12]
    ldr     r3, [r5, #ROW_ID]               // child_id
    str     r3, [r8, #16]
    str     r6, [r8, #32]                   // restarted
    cmp     r6, #0
    beq.w   3f
    ldr     r1, [r5, #ROW_CID]              // new_child: the row's current child when restarted
    ldr     r2, [r5, #ROW_CID + 4]
3:  str     r1, [r8, #40]
    str     r2, [r8, #44]
    // the cast: a node on the sink's mailbox carrying the block as its message copy
    bl      silica_rt_alloc_node
    str     r8, [r0, #MSG_PAYLOAD]
    movw    r1, #0
    str     r1, [r0, #MSG_PAYLOAD + 4]
    str     r1, [r0, #MSG_KIND]
    str     r1, [r0, #MSG_NEXT]
    str     r8, [r0, #MSG_BUF_BLOCK]
    movw    r1, #EXIT_REPORT_SIZE
    str     r1, [r0, #MSG_BUF_BYTES]
    movw    r1, #1
    str     r1, [r0, #MSG_PAYLOAD_OWNED]
    ldr     r1, [r7, #ACB_MB_TAIL]
    cmp     r1, #0
    beq.w   4f
    str     r0, [r1, #MSG_NEXT]
    str     r0, [r7, #ACB_MB_TAIL]
    b.w     5f
4:  str     r0, [r7, #ACB_MB_HEAD]
    str     r0, [r7, #ACB_MB_TAIL]
5:  mov     r0, r7
    bl      silica_rt_make_ready
9:  pop     {r4-r8, pc}
    .size   silica_rt_sup_exit_report, . - silica_rt_sup_exit_report

// set_report_sink(X0 sup, X1 sink) -> X0 = 0, or -2 (the operation's error answer) when the sink names no
// live actor or a call-only one (§15.4.10.5: reports are casts). Exits already in the ingress are handled
// first (§15.4.9.4), before the sink is named, so they are not reported.
    FUNC silica_rt_supervisor_set_report_sink
    ENTRY_SAVE
    bl      rt_sup_acb
    mov     r4, r0                          // r4 = sup
    bl      rt_ct_enter
    mov     r0, r4
    bl      silica_rt_supervisor_drain_ingress
    ldr     r0, [sp, #8]                    // X1 = the sink's reference
    ldr     r1, [sp, #12]
    bl      rt_sup_ref_acb
    cmp     r0, #0
    beq.w   8f
    ldr     r1, [r0, #ACB_CONV]
    and     r1, r1, #3
    cmp     r1, #1
    beq.w   8f
    mov     r0, r4
    bl      silica_rt_sb_require
    ldr     r1, [sp, #8]
    str     r1, [r0, #SB_SINK]
    ldr     r1, [sp, #12]
    str     r1, [r0, #SB_SINK + 4]
    movw    r5, #0
    movw    r6, #0
    b.w     9f
8:  mvn     r5, #1
    mvn     r6, #0
9:  mov     r0, r4
    bl      rt_ct_leave
    mov     r0, r5
    mov     r1, r6
    ENTRY_RET_X0
    .size   silica_rt_supervisor_set_report_sink, . - silica_rt_supervisor_set_report_sink

// =============================================================================================
// Trial accessors and hooks.

// child_table_first_ref() -> X0 the running supervisor's first live child (all ones for none).
    FUNC silica_rt_child_table_first_ref
    ENTRY_SAVE
    bl      rt_cur_actor
    cmp     r0, #0
    beq.w   9f
    ldr     r0, [r0, #ACB_SB]
    cmp     r0, #0
    beq.w   9f
    ldr     r0, [r0, #SB_CT_HEAD]
1:  cmp     r0, #0
    beq.w   9f
    ldr     r1, [r0, #ROW_CHILD]
    cmp     r1, #0
    bne.w   9f
    ldr     r0, [r0, #ROW_NEXT]
    b.w     1b
9:  bl      rt_row_child_ref
    ENTRY_RET_X0
    .size   silica_rt_child_table_first_ref, . - silica_rt_child_table_first_ref

// child_table_row_ref(X0 index) -> X0 the child of that row (all ones for a tombstone / no row).
    FUNC silica_rt_child_table_row_ref
    ENTRY_SAVE
    mov     r4, r0
    bl      rt_cur_actor
    cmp     r0, #0
    beq.w   9f
    cmp     r4, #0
    blt.w   9f
    ldr     r2, [r0, #ACB_SB]
    cmp     r2, #0
    beq.w   9f
    ldr     r2, [r2, #SB_CT_LEN]
    cmp     r4, r2
    bhs.w   9f
    mov     r1, r4
    bl      rt_row_at
    bl      rt_row_child_ref
    ENTRY_RET_X0
9:  mvn     r0, #0
    mvn     r1, #0
    ENTRY_RET_X0
    .size   silica_rt_child_table_row_ref, . - silica_rt_child_table_row_ref

// supervision_ingress_enqueue(X0 actor, X1 inline int64) -> :ok (trial hook: the payload is not a
// structured notice, so the target's behaviour runs on it).
    FUNC silica_rt_actor_supervision_ingress_enqueue
    ENTRY_SAVE
    bl      rt_sup_ref_acb
    cmp     r0, #0
    beq.w   9f
    mov     r4, r0
    bl      silica_rt_alloc_node
    mov     r5, r0
    movw    r1, #2
    str     r1, [r5, #MSG_KIND]
    movw    r1, #1
    str     r1, [r5, #MSG_INGRESS_KIND]
    ldr     r1, [sp, #8]
    str     r1, [r5, #MSG_PAYLOAD]
    ldr     r1, [sp, #12]
    str     r1, [r5, #MSG_PAYLOAD + 4]
    mov     r0, r4
    mov     r1, r5
    bl      silica_rt_enqueue_ingress
    cmp     r0, #0
    beq.w   9f
    mov     r0, r5
    bl      silica_rt_free_node
9:  movw    r0, #ATOM_OK
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_actor_supervision_ingress_enqueue, . - silica_rt_actor_supervision_ingress_enqueue

// supervision_wait_and_drain_one() -> X0 the failure payload: the running actor waits (ST_WAIT_INGRESS)
// until an exit notice is in its ingress, runs the restart logic on it and returns the payload (the
// program releases it with failure_release); its hold on an actor that ended in its start ends here.
    FUNC silica_rt_actor_supervision_wait_and_drain_one
    ENTRY_SAVE
    bl      rt_cur_actor
    mov     r4, r0
    cmp     r4, #0
    beq.w   9f
1:  ldr     r5, [r4, #ACB_SB]
    cmp     r5, #0
    beq.w   11f
    ldr     r6, [r5, #SB_IN_HEAD]
    cmp     r6, #0
    bne.w   2f
11: movw    r0, #ST_WAIT_INGRESS
    strb    r0, [r4, #ACB_STATUS]
    bl      silica_rt_yield_to_sched
    b.w     1b
2:  ldr     r0, [r6, #MSG_NEXT]
    str     r0, [r5, #SB_IN_HEAD]
    cmp     r0, #0
    it      eq
    streq   r0, [r5, #SB_IN_TAIL]
    ldr     r0, [r5, #SB_IN_DEPTH]
    sub     r0, r0, #1
    str     r0, [r5, #SB_IN_DEPTH]
    ldr     r7, [r6, #MSG_PAYLOAD]          // r7 = payload
    ldr     r0, [r6, #MSG_INGRESS_KIND]
    cmp     r0, #0
    bne.w   4f
    cmp     r7, #0
    beq.w   4f
    ldr     r0, [r7, #0]
    cmp     r0, #0
    beq.w   4f
    mov     r0, r4
    mov     r1, r7
    bl      rt_handle_notice
    ldr     r0, [r7, #32]                   // the program gets the payload; its hold on the actor ends
    cmp     r0, #0
    beq.w   4f
    movw    r0, #0
    str     r0, [r7, #32]
    ldr     r0, [r7, #0]
    movw    r1, #TR_NOTICE
    bl      silica_rt_tramp_release
4:  mov     r0, r6
    bl      silica_rt_free_node
    mov     r0, r7
    movw    r1, #0
    ENTRY_RET_X0
9:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_actor_supervision_wait_and_drain_one, . - silica_rt_actor_supervision_wait_and_drain_one

// add_child(X0 parent, X1 child) -> 0: the child's exits go to the parent's ingress (the parent's
// supervision block comes with the first notice, silica_rt_enqueue_ingress).
    FUNC silica_rt_actor_add_child
    ENTRY_SAVE
    mov     r4, r0
    ldr     r0, [sp, #8]
    ldr     r1, [sp, #12]
    bl      rt_sup_ref_acb
    mov     r5, r0
    mov     r0, r4
    ldr     r1, [sp, #4]
    bl      rt_sup_ref_acb
    cmp     r0, #0
    beq.w   9f
    cmp     r5, #0
    beq.w   9f
    str     r0, [r5, #ACB_SUP]
9:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_actor_add_child, . - silica_rt_actor_add_child

// =============================================================================================
// call_supervisor operations (the SIR generator lowers call_supervisor to these). Each is a call's
// yield point, then resolves the supervisor (actor_not_found when it has ended) and handles the exits
// waiting in its ingress first.

// rt_op_prologue(r0:r1 = the supervisor's reference) -> r0 = sup, entered and drained. Keeps r4-r11.
    LFUNC rt_op_prologue
    push    {r4, r5, r6, lr}
    mov     r4, r0
    mov     r5, r1
    bl      rt_yield_if_ready
    mov     r0, r4
    mov     r1, r5
    bl      rt_sup_acb
    mov     r4, r0
    bl      rt_ct_enter
    mov     r0, r4
    bl      silica_rt_supervisor_drain_ingress
    mov     r0, r4
    pop     {r4, r5, r6, pc}
    .size   rt_op_prologue, . - rt_op_prologue

// count_children(X0 sup) -> X0 its live rows.
    FUNC silica_rt_supervisor_count_children
    ENTRY_SAVE
    bl      rt_op_prologue
    mov     r4, r0
    movw    r5, #0
    ldr     r1, [r4, #ACB_SB]
    cmp     r1, #0
    beq.w   9f
    ldr     r1, [r1, #SB_CT_HEAD]
1:  cmp     r1, #0
    beq.w   9f
    ldr     r2, [r1, #ROW_CHILD]
    cmp     r2, #0
    it      ne
    addne   r5, r5, #1
    ldr     r1, [r1, #ROW_NEXT]
    b.w     1b
9:  mov     r0, r4
    bl      rt_ct_leave
    mov     r0, r5
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_supervisor_count_children, . - silica_rt_supervisor_count_children

// get_child(X0 sup, X1 id) -> X0 the live child the row with that id holds (all ones for none).
    FUNC silica_rt_supervisor_get_child
    ENTRY_SAVE
    bl      rt_op_prologue
    mov     r4, r0
    ldr     r1, [sp, #8]
    bl      rt_live_row_by_id
    bl      rt_row_child_ref
    mov     r5, r0
    mov     r6, r1
    mov     r0, r4
    bl      rt_ct_leave
    mov     r0, r5
    mov     r1, r6
    ENTRY_RET_X0
    .size   silica_rt_supervisor_get_child, . - silica_rt_supervisor_get_child

// get_child_info(X0 sup, X1 id) -> X0 { id, agent_type, child, restart } (40 B: shape word, four slots,
// in the running frame's dynamic part; an empty record with child all ones when no live row has the id).
    FUNC silica_rt_supervisor_get_child_info
    ENTRY_SAVE
    bl      rt_op_prologue
    mov     r4, r0
    ldr     r7, [sp, #8]                    // r7 = id
    mov     r1, r7
    bl      rt_live_row_by_id
    mov     r5, r0                          // r5 = row or 0
    movw    r0, #40
    bl      silica_rt_frame_alloc
    mov     r6, r0                          // r6 = the record
    MOV32   r1, SHAPE_CHILD_INFO
    str     r1, [r6, #0]
    mvn     r1, #0
    str     r1, [r6, #24]
    str     r1, [r6, #28]
    cmp     r5, #0
    beq.w   9f
    str     r7, [r6, #8]
    ldr     r1, [r5, #ROW_AGENT]
    cmp     r1, #ATOM_UNKNOWN
    it      eq
    ldreq   r1, [r5, #ROW_ID]
    str     r1, [r6, #16]
    mov     r0, r5
    bl      rt_row_child_ref
    str     r0, [r6, #24]
    str     r1, [r6, #28]
    ldr     r1, [r5, #ROW_RESTART]
    cmp     r1, #0
    it      eq
    moveq   r1, #ATOM_PERMANENT
    str     r1, [r6, #32]
9:  mov     r0, r4
    bl      rt_ct_leave
    mov     r0, r6
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_supervisor_get_child_info, . - silica_rt_supervisor_get_child_info

// get_child_id / _agent_type / _restart (X0 sup, X1 id) -> X0 the live row's field, or 0.
.macro ROW_FIELD name, field
    FUNC \name
    ENTRY_SAVE
    bl      rt_op_prologue
    mov     r4, r0
    ldr     r1, [sp, #8]
    bl      rt_live_row_by_id
    movw    r5, #0
    cmp     r0, #0
    it      ne
    ldrne   r5, [r0, #\field]
    mov     r0, r4
    bl      rt_ct_leave
    mov     r0, r5
    movw    r1, #0
    ENTRY_RET_X0
    .size   \name, . - \name
.endm
    ROW_FIELD silica_rt_supervisor_get_child_id, ROW_ID
    ROW_FIELD silica_rt_supervisor_get_child_agent_type, ROW_AGENT
    ROW_FIELD silica_rt_supervisor_get_child_restart, ROW_RESTART

// which_children(X0 sup) -> X0 List[{ id, agent_type, child, restart }]: one 40-byte record (shape word,
// four slots) per 56-byte chunk (the next chunk at 48), the 24-byte handle (count, chunk, cursor 0), newest
// first, in the running frame's dynamic part (the call site adopts it).
    FUNC silica_rt_supervisor_which_children
    ENTRY_SAVE
    bl      rt_op_prologue
    mov     r4, r0
    movw    r7, #0                          // r7 = the list handle so far
    ldr     r5, [r4, #ACB_SB]
    cmp     r5, #0
    beq.w   9f
    ldr     r5, [r5, #SB_CT_HEAD]
1:  cmp     r5, #0
    beq.w   9f
    ldr     r0, [r5, #ROW_CHILD]
    cmp     r0, #0
    beq.w   8f
    movw    r0, #56
    bl      silica_rt_frame_alloc
    mov     r6, r0                          // r6 = chunk
    MOV32   r1, SHAPE_CHILD_INFO
    str     r1, [r6, #0]
    ldr     r1, [r5, #ROW_ID]
    str     r1, [r6, #8]
    ldr     r1, [r5, #ROW_AGENT]
    str     r1, [r6, #16]
    ldr     r1, [r5, #ROW_CID]
    str     r1, [r6, #24]
    ldr     r1, [r5, #ROW_CID + 4]
    str     r1, [r6, #28]
    ldr     r1, [r5, #ROW_RESTART]
    str     r1, [r6, #32]
    cmp     r7, #0
    beq.w   2f
    ldr     r1, [r7, #8]
    str     r1, [r6, #48]
2:  movw    r0, #24
    bl      silica_rt_frame_alloc
    movw    r1, #1
    cmp     r7, #0
    beq.w   3f
    ldr     r1, [r7, #0]
    add     r1, r1, #1
3:  str     r1, [r0, #0]
    str     r6, [r0, #8]
    mov     r7, r0
8:  ldr     r5, [r5, #ROW_NEXT]
    b.w     1b
9:  mov     r0, r4
    bl      rt_ct_leave
    mov     r0, r7
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_supervisor_which_children, . - silica_rt_supervisor_which_children

// terminate_child / remove_child (X0 sup, X1 id) -> X0 = 0, or -2 when the running actor is a row child of
// this supervisor naming its own row (it would end itself and wait for an exit only it can complete; the
// lowering turns -2 into the error reply and nothing is stopped).
    FUNC silica_rt_supervisor_terminate_child
    .thumb_func
    .global silica_rt_supervisor_remove_child
silica_rt_supervisor_remove_child:
    ENTRY_SAVE
    bl      rt_sup_acb
    mov     r4, r0
    bl      rt_ct_enter
    ldr     r7, [sp, #8]                    // r7 = id
    mov     r0, r4
    mov     r1, r7
    bl      rt_live_row_by_id
    cmp     r0, #0
    beq.w   1f
    ldr     r5, [r0, #ROW_CHILD]
    bl      rt_cur_actor
    cmp     r5, r0
    bne.w   1f
    mvn     r5, #1
    mvn     r6, #0
    b.w     9f
1:  mov     r0, r4
    bl      silica_rt_supervisor_drain_ingress
    mov     r0, r4
    mov     r1, r7
    bl      rt_live_row_by_id
    cmp     r0, #0
    beq.w   2f
    mov     r5, r0
    mov     r1, r0
    mov     r0, r4
    bl      rt_stop_child
    mov     r0, r5
    bl      rt_row_release_child
2:  movw    r5, #0
    movw    r6, #0
9:  mov     r0, r4
    bl      rt_ct_leave
    mov     r0, r5
    mov     r1, r6
    ENTRY_RET_X0
    .size   silica_rt_supervisor_terminate_child, . - silica_rt_supervisor_terminate_child

// The reply fields of :terminate_child / :remove_child / :restart_child for the -2 answer (the error
// shape: tag :error, error :language_error, child 0); the atoms are the image's words
// (silica_rt_sup_error_tag, silica_rt_sup_self_error_atom). Leaves: X1 (r2:r3) is kept.
// sup_op_tag(X0 answer, X1 the operation's own tag) -> X1, or :error for the -2 answer.
    FUNC silica_rt_sup_op_tag
    cmn     r0, #2
    bne.w   1f
    cmn     r1, #1
    bne.w   1f
    MOV32   r0, silica_rt_sup_error_tag
    ldr     r0, [r0]
    asr     r1, r0, #31
    bx      lr
1:  mov     r0, r2
    mov     r1, r3
    bx      lr
    .size   silica_rt_sup_op_tag, . - silica_rt_sup_op_tag

// sup_op_error(X0 answer, X1 the operation's own error atom) -> X1, or :language_error for -2.
    FUNC silica_rt_sup_op_error
    cmn     r0, #2
    bne.w   1f
    cmn     r1, #1
    bne.w   1f
    MOV32   r0, silica_rt_sup_self_error_atom
    ldr     r0, [r0]
    asr     r1, r0, #31
    bx      lr
1:  mov     r0, r2
    mov     r1, r3
    bx      lr
    .size   silica_rt_sup_op_error, . - silica_rt_sup_op_error

// sup_op_child(X0 :restart_child's answer) -> the answer, or 0 for -2.
    FUNC silica_rt_sup_op_child
    cmn     r0, #2
    bne.w   1f
    cmn     r1, #1
    bne.w   1f
    movw    r0, #0
    movw    r1, #0
1:  bx      lr
    .size   silica_rt_sup_op_child, . - silica_rt_sup_op_child

// restart_child(X0 sup, X1 id) -> X0 the restarted child (all ones when the id is unknown), or -2 when the
// running actor is a row child of this supervisor whose restart would stop its own row: its own id named,
// or under :one_for_all any id a row bears.
    FUNC silica_rt_supervisor_restart_child
    ENTRY_SAVE
    bl      rt_sup_acb
    mov     r4, r0                          // r4 = sup
    bl      rt_ct_enter
    ldr     r7, [sp, #8]                    // r7 = id
    // the self check: the row of this supervisor whose child is the running actor, if any
    bl      rt_cur_actor
    cmp     r0, #0
    beq.w   4f
    ldr     r5, [r4, #ACB_SB]
    cmp     r5, #0
    beq.w   4f
    ldr     r5, [r5, #SB_CT_HEAD]
41: cmp     r5, #0
    beq.w   4f
    ldr     r1, [r5, #ROW_CHILD]
    cmp     r1, r0
    beq.w   42f
    ldr     r5, [r5, #ROW_NEXT]
    b.w     41b
42: ldr     r1, [r5, #ROW_ID]
    cmp     r1, r7
    beq.w   7f
    ldr     r1, [r4, #ACB_SB]
    ldr     r1, [r1, #SB_STRATEGY]
    cmp     r1, #ATOM_ONE_FOR_ALL
    bne.w   4f
    ldr     r5, [r4, #ACB_SB]
    ldr     r5, [r5, #SB_CT_HEAD]
43: cmp     r5, #0
    beq.w   4f
    ldr     r1, [r5, #ROW_ID]
    cmp     r1, r7
    beq.w   7f
    ldr     r5, [r5, #ROW_NEXT]
    b.w     43b
7:  mvn     r5, #1
    mvn     r6, #0
    b.w     99f
4:  mov     r0, r4
    bl      silica_rt_supervisor_drain_ingress
    ldr     r5, [r4, #ACB_SB]               // the row with this id, live or tombstoned
    cmp     r5, #0
    beq.w   98f
    ldr     r5, [r5, #SB_CT_HEAD]
1:  cmp     r5, #0
    beq.w   98f
    ldr     r1, [r5, #ROW_ID]
    cmp     r1, r7
    beq.w   2f
    ldr     r5, [r5, #ROW_NEXT]
    b.w     1b
2:  ldr     r1, [r4, #ACB_SB]
    ldr     r1, [r1, #SB_STRATEGY]
    cmp     r1, #ATOM_ONE_FOR_ALL
    beq.w   5f
    ldr     r1, [r5, #ROW_CHILD]
    cmp     r1, #0
    beq.w   3f
    mov     r0, r4
    mov     r1, r5
    bl      rt_stop_child
3:  mov     r0, r5
    mov     r1, r4
    bl      rt_respawn_row                  // §20.3.1: a taken name fails the supervisor, no child
    mov     r0, r5
    bl      rt_row_child_ref
    mov     r5, r0
    mov     r6, r1
    b.w     99f
5:  // one_for_all: stop every live child, then respawn every row; r8 = the row with the id once respawned
    movw    r8, #0
    ldr     r5, [r4, #ACB_SB]
    ldr     r5, [r5, #SB_CT_HEAD]
51: cmp     r5, #0
    beq.w   52f
    ldr     r1, [r5, #ROW_CHILD]
    cmp     r1, #0
    beq.w   511f
    mov     r0, r4
    mov     r1, r5
    bl      rt_stop_child
511: ldr    r5, [r5, #ROW_NEXT]
    b.w     51b
52: ldr     r5, [r4, #ACB_SB]
    ldr     r5, [r5, #SB_CT_HEAD]
53: cmp     r5, #0
    beq.w   8f
    mov     r0, r5
    mov     r1, r4
    bl      rt_respawn_row
    cmp     r0, #0
    bne.w   8f
    ldr     r1, [r5, #ROW_ID]
    cmp     r1, r7
    it      eq
    moveq   r8, r5
    ldr     r5, [r5, #ROW_NEXT]
    b.w     53b
8:  mov     r0, r8
    bl      rt_row_child_ref
    mov     r5, r0
    mov     r6, r1
    b.w     99f
98: mvn     r5, #0
    mvn     r6, #0
99: mov     r0, r4
    bl      rt_ct_leave
    mov     r0, r5
    mov     r1, r6
    ENTRY_RET_X0
    .size   silica_rt_supervisor_restart_child, . - silica_rt_supervisor_restart_child

    .ltorg

// Weak defaults for the image words the compiler emits into every runtime unit (emitter_core
// xt_runtime_registry_words), for hand-written images: -1 (no such atom), shape 0.
    .section .rodata.silica_sup_default, "a", %progbits
    .balign 4
    .weak   silica_registry_atom_duplicate_child_id
silica_registry_atom_duplicate_child_id:
    .word   -1
    .weak   silica_registry_atom_shutdown
silica_registry_atom_shutdown:
    .word   -1
    .weak   silica_registry_atom_restart_breach
silica_registry_atom_restart_breach:
    .word   -1
    .weak   silica_registry_shape_exit_report
silica_registry_shape_exit_report:
    .word   0
    .weak   silica_rt_sup_error_tag
silica_rt_sup_error_tag:
    .word   -1
    .weak   silica_rt_sup_self_error_atom
silica_rt_sup_self_error_atom:
    .word   ATOM_LANGUAGE_ERROR
