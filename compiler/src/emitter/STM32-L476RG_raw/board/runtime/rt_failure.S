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

// Actor failure handling and reports for the bare-metal STM32L476RG (group 2 of the actor port): the
// ESP32-S3 runtime's rt_actors.S "Ending an actor", the failure report and its FailureReporter delivery,
// on one Cortex-M4 core. design_documents/runtime_failure_reporting.md §1, §3.2, §6, §7 is the contract;
// the ESP32-S3 runtime is the reference for every observable behaviour.
//
//   The exit path        silica_rt_actor_exit(acb, root note): the notice to the supervisor's ingress,
//                        the failure report (to the registered FailureReporter by a cast, else on the
//                        console), the death result for the call being served and every queued call
//                        (the caller raises actor_not_found), the rest of the mailbox dropped, the
//                        registered name freed, the ACB marked dead.
//   Who runs it          the scheduler, on its own stack, for an actor that ended where it stood (a trap
//                        or a CPU fault: status ST_FAULTED) or at its dispatch boundary (stop_self: alive
//                        cleared, status ST_BOUNDARY); the killer, in its own context, for an actor that
//                        was not running (kill_abnormal, remove_actor of a parked, suspended or queued
//                        actor). On the ESP32-S3 a trap runs the path on the dying actor's stack before it
//                        yields; here it yields first and the scheduler runs the same path with nothing in
//                        between, so the order of every effect is the same and the path never runs inside
//                        the runtime reserve of a stack that has just run out.
//   Traps                silica_rt_actor_trap(tag, detail), silica_rt_actor_trap_explicit(atom): the
//                        running actor ends at once (badarith, case_clause, a convention mismatch, a name
//                        already held, kill/remove naming the caller, actor_not_found, fail_self, the
//                        bounds and allocation failures of §1). In main the same sites are the
//                        language-level failure of §15.4.5.5 (the atom's name, the pending reports, status
//                        1) or the runtime abort of the site (status 71).
//   CPU faults           silica_rt_actor_fault_hook, called by rt_vectors.S on the fault stack: a HardFault,
//                        MemManage, BusFault or UsageFault taken in thread mode while an actor is the
//                        running context ends that actor with :memory_fault (tag 3) and resumes the
//                        scheduler through an exception return; anything else (main, the scheduler, a fault
//                        inside an interrupt handler) returns, and the fault is process-fatal (status 70).
//
// Reason tags (§7): 0 :normal, 2 :language_error, 3 :memory_fault, 4 (:explicit, atom); ACB_REASON_ATOM
// holds the atom for tag 4 and the detail for tag 2 (1 division by zero, 2 no case arm matched).
//
// Calling conventions: the entries emitted code calls (kill_abnormal, fail_self, stop_self_*, the
// failure_* accessors, badarith ...) keep every register but r10, r11, lr and the X0 result (ENTRY_SAVE);
// everything else here is AAPCS.

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

#define REPORT_BUF_SIZE  768
#define REPORT_PUTS_STOP 740            /* the numeric helpers after a puts always have room */
#define DRAIN_STEPS      1000           /* ~1 ms each (one SysTick): the hosts wait up to 2 s, the ESP32-S3 1 s */
#define NOTICE_SIZE      48

    .section .bss.silica_rt_failure, "aw", %nobits
    .balign 8
silica_rt_report_buf:
    .space  REPORT_BUF_SIZE
silica_rt_report_len:
    .space  4
    // the report the FailureReporter is handling: +0 the string block (0: none), +4 escaped
    .global silica_rt_report_owner
silica_rt_report_owner:
    .space  8
    // reports handed to the reporter and not yet taken by its dispatch: 8-byte nodes (+0 next, +4 the
    // report string), oldest first
    .global silica_rt_report_list
silica_rt_report_list:
    .space  4
    // deaths between the notice to the supervisor and their queued or written report
    .global silica_rt_report_inflight
silica_rt_report_inflight:
    .space  4

    .section .text.silica_rt_failure, "ax", %progbits

// =============================================================================================
// Ending the running actor where it stands.

// silica_rt_actor_trap(r0 = reason tag, r1 = detail): a language-level failure (badarith, case_clause,
// a convention mismatch ...) inside the running actor. Never returns. Called only with an actor current.
    FUNC silica_rt_actor_trap
    mov     r2, r0
    bl      silica_rt_current               // (clobbers r0 only)
    strb    r2, [r0, #ACB_REASON_TAG]
    strh    r1, [r0, #ACB_REASON_ATOM]
    b.w     rt_end_where_it_stands
    .size   silica_rt_actor_trap, . - silica_rt_actor_trap

// silica_rt_actor_trap_explicit(r0 = atom): the running actor fails with (:explicit, atom), tag 4.
    FUNC silica_rt_actor_trap_explicit
    mov     r1, r0
    bl      silica_rt_current
    strh    r1, [r0, #ACB_REASON_ATOM]
    movw    r2, #4
    strb    r2, [r0, #ACB_REASON_TAG]
    b.w     rt_end_where_it_stands
    .size   silica_rt_actor_trap_explicit, . - silica_rt_actor_trap_explicit

// rt_end_where_it_stands(r0 = the running actor): ended (alive cleared, status ST_FAULTED), its dispatch
// abandoned; the scheduler runs its exit path on the scheduler's stack (rt_actors.S silica_rt_sched_loop).
    LFUNC rt_end_where_it_stands
    movw    r1, #0
    strb    r1, [r0, #ACB_ALIVE]
    movw    r1, #ST_FAULTED
    strb    r1, [r0, #ACB_STATUS]
    bl      silica_rt_yield_to_sched        // never switched back to
1:  b.w     1b
    .size   rt_end_where_it_stands, . - rt_end_where_it_stands

// rt_in_actor() -> r0 = the running actor's ACB, or 0 in main and the scheduler. Clobbers r0, r12.
    LFUNC rt_in_actor
    MOV32   r0, silica_rt_cores
    ldr     r0, [r0, #CORE_CURRENT]
    ldrb    r12, [r0, #ACB_KIND]
    cmp     r12, #KIND_ACTOR
    it      ne
    movne   r0, #0
    bx      lr
    .size   rt_in_actor, . - rt_in_actor

// silica_rt_convention_mismatch / silica_rt_language_error_current / silica_rt_registry_name_taken: a
// call()/cast() whose target was spawned with the other calling convention (§16.2.6.4; nothing was
// enqueued), kill_abnormal / remove_actor naming the calling actor (§15.1.2.3), a registered spawn whose
// name is held (§20.3.1). In an actor: :language_error, tag 2; in main: "language_error", status 1.
    FUNC silica_rt_convention_mismatch
    .thumb_func
    .global silica_rt_language_error_current
silica_rt_language_error_current:
    .thumb_func
    .global silica_rt_registry_name_taken
silica_rt_registry_name_taken:
    bl      rt_in_actor
    cmp     r0, #0
    beq.w   1f
    movw    r0, #2
    movw    r1, #0
    bl      silica_rt_actor_trap
1:  MOV32   r0, silica_rt_language_error_msg
    b.w     silica_rt_main_fail_exit
    .size   silica_rt_convention_mismatch, . - silica_rt_convention_mismatch

// silica_rt_actor_not_found(): a cast / call / registered form named an ended actor or an unheld name, or
// a call's target ended before replying (§16.1.1, §20.3.1). In an actor: (:explicit, :actor_not_found);
// in main: "actor_not_found", status 1.
    FUNC silica_rt_actor_not_found
    bl      rt_in_actor
    cmp     r0, #0
    beq.w   1f
    MOV32   r0, silica_registry_atom_actor_not_found
    ldr     r0, [r0]
    bl      silica_rt_actor_trap_explicit
1:  MOV32   r0, silica_rt_actor_not_found_msg
    b.w     silica_rt_main_fail_exit
    .size   silica_rt_actor_not_found, . - silica_rt_actor_not_found

// badarith / case_clause (emitted code): in an actor :language_error with the detail for the report's
// reason line; in main the atom's name, the pending reports, status 1.
    FUNC silica_rt_badarith
    bl      rt_in_actor
    cmp     r0, #0
    beq.w   1f
    movw    r0, #2
    movw    r1, #1                          // detail 1: integer division by zero
    bl      silica_rt_actor_trap
1:  MOV32   r0, silica_rt_badarith_msg
    b.w     silica_rt_main_fail_exit
    .size   silica_rt_badarith, . - silica_rt_badarith

    FUNC silica_rt_case_clause
    bl      rt_in_actor
    cmp     r0, #0
    beq.w   1f
    movw    r0, #2
    movw    r1, #2                          // detail 2: no case arm matched
    bl      silica_rt_actor_trap
1:  MOV32   r0, silica_rt_case_clause_msg
    b.w     silica_rt_main_fail_exit
    .size   silica_rt_case_clause, . - silica_rt_case_clause

// Bounds and allocation failures (region_memory_safety_design.md §8, Q9 (a)): inside an actor they end
// the ACTOR with (:explicit, atom); in main they are the runtime abort of the site, status 71, reported
// at the call into the entry (lr is restored before silica_rt_abort_body reads it). The atom words are
// emitted into every image (emitter_core xt_runtime_registry_words; weak -1 defaults below).
.macro FAILURE_ENTRY name, atomword, reason
    FUNC \name
    push    {r0, lr}
    bl      rt_in_actor
    cmp     r0, #0
    beq.w   1f
    MOV32   r0, \atomword
    ldr     r0, [r0]
    bl      silica_rt_actor_trap_explicit
1:  pop     {r0, lr}
    MOV32   r0, \reason
    b.w     silica_rt_abort_body
    .size   \name, . - \name
.endm
    FAILURE_ENTRY silica_rt_buf_bounds_failed, silica_registry_atom_buf_bounds, silica_rt_reason_buf_bounds
    FAILURE_ENTRY silica_rt_buf_invalid_failed, silica_registry_atom_buf_invalid, silica_rt_reason_buf_invalid
    FAILURE_ENTRY silica_rt_region_alloc_failed, silica_registry_atom_out_of_memory, silica_rt_reason_out_of_memory
    FAILURE_ENTRY silica_rt_list_index_failed, silica_registry_atom_list_index, silica_rt_reason_list_index

// silica_rt_actor_unknown: the emitter's fallback name for a runtime prim it does not know
// (prims_actors.silica); no emitted code reaches it. A runtime abort if anything ever does.
    FUNC silica_rt_actor_unknown
    MOV32   r0, silica_rt_unknown_prim_msg
    b.w     silica_rt_abort_body
    .size   silica_rt_actor_unknown, . - silica_rt_actor_unknown

// =============================================================================================
// The entries that end an actor (spec §15.1.2.3).

// silica_rt_end_actor(r0 = acb, r1 = reason tag): request the end. The running actor (a self stop) ends
// at its dispatch boundary: alive is cleared and the scheduler runs the exit path when the behaviour has
// returned (so a call it is serving still gets its reply). An actor that is not running -- parked,
// suspended in a call, or queued -- is in the middle of nothing: its exit path runs here, in the caller's
// context; a parked or suspended one is recycled now, a queued one keeps its ACB (status DEAD) until the
// scheduler pops it. The tag is kept when one was already recorded. AAPCS.
// silica_rt_end_actor_leaf(r0 = acb, r1 = reason tag): the same for silica_rt_sup_shutdown_children
// (rt_supervisors.S), through the exit path without the shutdown of children (silica_rt_actor_exit_body),
// so no exit path nests in another.
    FUNC silica_rt_end_actor_leaf
    push    {r4, r5, lr}
    movw    r5, #1
    b.w     rt_end_common
    .size   silica_rt_end_actor_leaf, . - silica_rt_end_actor_leaf

    FUNC silica_rt_end_actor
    push    {r4, r5, lr}
    movw    r5, #0
    .thumb_func
rt_end_common:
    mov     r4, r0
    ldrb    r2, [r4, #ACB_KIND]
    cmp     r2, #KIND_ACTOR
    bne.w   9f
    ldrb    r2, [r4, #ACB_ALIVE]
    cmp     r2, #0
    beq.w   9f
    ldrb    r2, [r4, #ACB_REASON_TAG]
    cmp     r2, #0
    it      eq
    strbeq  r1, [r4, #ACB_REASON_TAG]
    movw    r2, #0
    strb    r2, [r4, #ACB_ALIVE]
    ldrb    r2, [r4, #ACB_STATUS]
    cmp     r2, #ST_IDLE
    beq.w   2f
    cmp     r2, #ST_SUSPENDED
    beq.w   2f
    cmp     r2, #ST_WAIT_INGRESS
    beq.w   2f
    cmp     r2, #ST_READY
    beq.w   3f
    pop     {r4, r5, pc}                    // running (itself): the boundary ends it
2:  movw    r2, #ST_RUNNING
    strb    r2, [r4, #ACB_STATUS]
    mov     r0, r4
    movw    r1, #1                          // ended by remove_actor / kill_abnormal: the root note
    bl      rt_exit_full_or_leaf
    mov     r0, r4
    bl      silica_rt_actor_recycle
    pop     {r4, r5, pc}
3:  movw    r2, #ST_RUNNING
    strb    r2, [r4, #ACB_STATUS]
    mov     r0, r4
    movw    r1, #1
    bl      rt_exit_full_or_leaf
    mov     r0, r4
    bl      silica_rt_actor_release         // status DEAD: the scheduler frees the ACB when it pops it
9:  pop     {r4, r5, pc}
    .size   silica_rt_end_actor, . - silica_rt_end_actor

// rt_exit_full_or_leaf(r0 = acb, r1 = root note, r5 = 1 leaf): silica_rt_actor_exit, or its body alone.
    LFUNC rt_exit_full_or_leaf
    cmp     r5, #0
    beq.w   silica_rt_actor_exit
    b.w     silica_rt_actor_exit_body
    .size   rt_exit_full_or_leaf, . - rt_exit_full_or_leaf

// remove_actor(X0 reference) -> 0: the actor ends normally (tag 0) at its next boundary; a parked one ends
// now. Naming the calling actor fails the caller with :language_error, nothing changed on it.
    FUNC silica_rt_remove_actor
    ENTRY_SAVE
    bl      rt_ref_acb_or_0
    cmp     r0, #0
    beq.w   9f
    mov     r4, r0
    bl      rt_in_actor
    cmp     r0, r4
    beq.w   8f
    mov     r0, r4
    movw    r1, #0
    bl      silica_rt_end_actor
9:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
8:  bl      silica_rt_language_error_current
    .size   silica_rt_remove_actor, . - silica_rt_remove_actor

// kill_abnormal(X0 reference) -> 0 and kill_abnormal_named(X0 registry atom) -> 0: the actor ends with
// (:explicit, :killed), tag 4 (§15.4.11.2). Naming the calling actor fails the caller with
// :language_error (a call it is serving gets no reply). A supervised victim's supervisor handles its
// pending exit notices before the return (silica_rt_supervisor_drain_ingress, below in rt_kill_common).
    FUNC silica_rt_actor_kill_abnormal_named
    ENTRY_SAVE
    mov     r1, r0
    REG_TABLE r0, silica_pid_registry_ref
    REG_BOUND r1, r12
    bhs.w   1f
    ldr     r0, [r0, r1, lsl #2]            // the table holds the ACB: its holder when alive
    cmp     r0, #0
    beq.w   rt_kill_common
    ldrb    r1, [r0, #ACB_ALIVE]
    cmp     r1, #0
    it      eq
    moveq   r0, #0
    b.w     rt_kill_common
1:  movw    r0, #0
    b.w     rt_kill_common
    .size   silica_rt_actor_kill_abnormal_named, . - silica_rt_actor_kill_abnormal_named

    FUNC silica_rt_actor_kill_abnormal
    ENTRY_SAVE
    bl      rt_ref_acb_or_0
    b.w     rt_kill_common
    .size   silica_rt_actor_kill_abnormal, . - silica_rt_actor_kill_abnormal

// rt_kill_common: after ENTRY_SAVE, r0 = the victim's ACB or 0. A supervised victim's supervisor handles
// its pending exit notices (the restart logic, the exit report) before the return, in this context
// (silica_rt_supervisor_drain_ingress, rt_supervisors.S), as on the ESP32-S3.
    LFUNC rt_kill_common
    cmp     r0, #0
    beq.w   9f
    mov     r4, r0
    bl      rt_in_actor
    cmp     r0, r4
    beq.w   8f
    ldr     r5, [r4, #ACB_SUP]              // r5 = the victim's supervisor (read before the ACB can go)
    MOV32   r0, silica_registry_atom_killed
    ldr     r0, [r0]
    strh    r0, [r4, #ACB_REASON_ATOM]
    mov     r0, r4
    movw    r1, #4
    bl      silica_rt_end_actor
    cmp     r5, #0
    beq.w   9f
    ldrb    r0, [r5, #ACB_ALIVE]
    cmp     r0, #0
    beq.w   9f
    mov     r0, r5
    bl      silica_rt_supervisor_drain_ingress
9:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
8:  bl      silica_rt_language_error_current
    .size   rt_kill_common, . - rt_kill_common

// rt_ref_acb_or_0(r0:r1 = reference) -> r0 = the live ACB with that identity, or 0 (rt_actors.S
// silica_rt_ref_acb, §15.1.4). Clobbers r0, r1.
    LFUNC rt_ref_acb_or_0
    b.w     silica_rt_ref_acb
    .size   rt_ref_acb_or_0, . - rt_ref_acb_or_0

// fail_self(X0 reason atom): the running actor fails at once with (:explicit, reason): the dispatch is
// abandoned, a call it is serving gets the death result, queued casts are dropped. Never returns. With no
// current actor it is the language-level failure of §15.4.5.5.
    FUNC silica_rt_fail_self
    ENTRY_SAVE
    mov     r4, r0
    bl      rt_in_actor
    cmp     r0, #0
    beq.w   1f
    mov     r0, r4
    bl      silica_rt_actor_trap_explicit
1:  bl      silica_rt_language_error_current
    .size   silica_rt_fail_self, . - silica_rt_fail_self

// stop_self_normal() -> 0: stop_self(:normal). The running actor ends at its dispatch boundary with
// :normal, tag 0: the dispatch runs to completion and a call it is serving still gets its reply.
    FUNC silica_rt_stop_self_normal
    ENTRY_SAVE
    bl      rt_in_actor
    cmp     r0, #0
    beq.w   1f
    movw    r1, #0
    bl      silica_rt_end_actor
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
1:  bl      silica_rt_language_error_current
    .size   silica_rt_stop_self_normal, . - silica_rt_stop_self_normal

// stop_self_explicit(X0 reason atom) -> 0: stop_self((:explicit, reason)), at the boundary as above.
    FUNC silica_rt_stop_self_explicit
    ENTRY_SAVE
    mov     r4, r0
    bl      rt_in_actor
    cmp     r0, #0
    beq.w   1f
    strh    r4, [r0, #ACB_REASON_ATOM]
    movw    r1, #4
    bl      silica_rt_end_actor
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
1:  bl      silica_rt_language_error_current
    .size   silica_rt_stop_self_explicit, . - silica_rt_stop_self_explicit

// =============================================================================================
// The exit path.

// silica_rt_actor_exit(r0 = acb, r1 = root note): see the head of the file. r1 = 1 when the actor was
// ended by remove_actor / kill_abnormal / stop_self (the hosts print the root note only then, never for
// a failure). An ending supervisor shuts its children down first (spec §15.4.8.4, §15.4.12.2;
// rt_supervisors.S silica_rt_sup_shutdown_children): their names are free before its own exit reaches its
// supervisor, which may restart it at once, and their reports precede its own. It is marked ended first,
// so its restart logic starts nothing more. AAPCS.
    FUNC silica_rt_actor_exit
    ldr     r2, [r0, #ACB_SB]
    cmp     r2, #0
    beq.w   silica_rt_actor_exit_body
    push    {r0, r1, r4, lr}
    movw    r2, #0
    strb    r2, [r0, #ACB_ALIVE]
    bl      silica_rt_sup_shutdown_children
    pop     {r0, r1, r4, lr}
    b.w     silica_rt_actor_exit_body
    .size   silica_rt_actor_exit, . - silica_rt_actor_exit

// silica_rt_actor_exit_body(r0 = acb, r1 = root note): the exit path without the children's shutdown, for
// a child that silica_rt_sup_shutdown_children ends (it has no live child left by then). AAPCS.
// r4 = acb, r5 = root note, r6 = reports queued for this actor as the FailureReporter, r7 = 1 when the
// actor has no supervisor (the root note may print), r8 = a node.
    FUNC silica_rt_actor_exit_body
    push    {r4-r8, lr}
    mov     r4, r0
    mov     r5, r1
    movw    r6, #0
    movw    r7, #0
    strb    r6, [r4, #ACB_ALIVE]
    // a supervisor that ends inside its start trampoline (its init failed) is marked
    ldr     r0, [r4, #ACB_SB]
    cmp     r0, #0
    beq.w   1f
    ldr     r1, [r0, #SB_TRAMP]
    cmp     r1, #0
    beq.w   1f
    ldr     r1, [r0, #SB_TRAMP_RAN]
    tst     r1, #TR_RAN
    bne.w   1f
    orr     r1, r1, #TR_INIT_DEAD
    str     r1, [r0, #SB_TRAMP_RAN]
1:  // a call this actor was suspended in must not wake it, nor place its reply into its stack
    ldr     r0, [r4, #ACB_WAIT_NODE]
    cmp     r0, #0
    beq.w   2f
    str     r6, [r0, #MSG_CALLER]
    str     r6, [r4, #ACB_WAIT_NODE]
2:  // a supervisor whose exit was reported synchronously already (rt_supervisors.S rt_sup_fail) reports
    // nothing here
    ldr     r0, [r4, #ACB_SB]
    cmp     r0, #0
    beq.w   21f
    ldr     r0, [r0, #SB_SYNC_REPORTED]
    cmp     r0, #0
    bne.w   3f
21: // the death is in flight until its report is queued or written (the exit drain waits for it)
    MOV32   r1, silica_rt_report_inflight
    ldr     r0, [r1]
    add     r0, r0, #1
    str     r0, [r1]
    mov     r0, r4
    bl      silica_rt_deliver_exit
    mov     r7, r0
    // a root actor's note goes out before its report reaches a registered FailureReporter, which may end
    // the program (cast_exit) once it has the report; no second note below then
    cmp     r7, #0
    beq.w   22f
    cmp     r5, #0
    beq.w   22f
    MOV32   r0, silica_rt_root_failure_reporter
    ldr     r0, [r0]
    cmp     r0, #0
    beq.w   22f
    MOV32   r0, silica_rt_root_exit_msg
    bl      silica_rt_puts
    movw    r7, #0
22: mov     r0, r4
    bl      silica_rt_actor_deliver_unwind_report
    MOV32   r1, silica_rt_report_inflight
    ldr     r0, [r1]
    sub     r0, r0, #1
    str     r0, [r1]
3:  // a spawner waiting for this supervisor's start resumes once the report is queued
    mov     r0, r4
    bl      rt_spawn_waiter_wake
    // the node being served: a call completes with the death result; a cast's (or a report's) node goes
    // back here, once (its dispatch never returns)
    ldr     r8, [r4, #ACB_ACTIVE_CALL]
    cmp     r8, #0
    beq.w   4f
    movw    r0, #0
    str     r0, [r4, #ACB_ACTIVE_CALL]
    ldr     r0, [r8, #MSG_KIND]
    cmp     r0, #1
    bne.w   31f
    mov     r0, r8
    bl      silica_rt_node_release_payload
    mov     r0, r8
    bl      silica_rt_complete_death
    b.w     4f
31: ldr     r0, [r8, #MSG_PAYLOAD_OWNED]
    cmp     r0, #2
    bne.w   32f
    movw    r0, #1                          // the report: the owner record cleared, then its block back
    str     r0, [r8, #MSG_PAYLOAD_OWNED]    // as any message copy's
    ldr     r0, [r8, #MSG_PAYLOAD]
    bl      silica_rt_report_end
32: mov     r0, r8
    bl      silica_rt_node_release_payload
    mov     r0, r8
    bl      silica_rt_free_node
4:  // the mailbox: queued calls complete with the death result, other messages are dropped with their
    // copies; a report queued for this actor as the FailureReporter is kept aside and written below
    ldr     r8, [r4, #ACB_MB_HEAD]
    cmp     r8, #0
    beq.w   5f
    ldr     r0, [r8, #MSG_NEXT]
    str     r0, [r4, #ACB_MB_HEAD]
    ldr     r0, [r8, #MSG_PAYLOAD_OWNED]
    cmp     r0, #2
    bne.w   41f
    str     r6, [r8, #MSG_NEXT]
    mov     r6, r8
    b.w     4b
41: mov     r0, r8
    bl      silica_rt_node_release_payload
    ldr     r0, [r8, #MSG_KIND]
    cmp     r0, #1
    bne.w   42f
    mov     r0, r8
    bl      silica_rt_complete_death
    b.w     4b
42: mov     r0, r8
    bl      silica_rt_free_node
    b.w     4b
5:  movw    r0, #0
    str     r0, [r4, #ACB_MB_TAIL]
    // the supervision ingress: notices never served go back, their payloads too
    ldr     r1, [r4, #ACB_SB]
    cmp     r1, #0
    beq.w   6f
    ldr     r8, [r1, #SB_IN_HEAD]
    str     r0, [r1, #SB_IN_HEAD]
    str     r0, [r1, #SB_IN_TAIL]
    str     r0, [r1, #SB_IN_DEPTH]
51: cmp     r8, #0
    beq.w   6f
    ldr     r0, [r8, #MSG_INGRESS_KIND]
    cmp     r0, #0
    bne.w   52f
    ldr     r0, [r8, #MSG_PAYLOAD]
    bl      silica_rt_exit_payload_free
52: mov     r0, r8
    ldr     r8, [r8, #MSG_NEXT]
    bl      silica_rt_free_node
    b.w     51b
6:  // the reports queued for this actor as the FailureReporter: each written to the console once and
    // taken off the pending list, then its block (the mailbox buffer) and its node go back
    cmp     r6, #0
    beq.w   7f
    mov     r8, r6
    ldr     r6, [r6, #MSG_NEXT]
    ldr     r0, [r8, #MSG_PAYLOAD]
    bl      silica_rt_report_write_block
    movw    r0, #1
    str     r0, [r8, #MSG_PAYLOAD_OWNED]
    mov     r0, r8
    bl      silica_rt_node_release_payload
    mov     r0, r8
    bl      silica_rt_free_node
    b.w     6b
7:  // the root note: a root actor ended by remove_actor / kill_abnormal / stop_self (never a failure)
    cmp     r7, #0
    beq.w   71f
    cmp     r5, #0
    beq.w   71f
    MOV32   r0, silica_rt_root_exit_msg
    bl      silica_rt_puts
71: // the registered name (§20.3.1): the slot is cleared only while it still names this actor
    ldrh    r1, [r4, #ACB_REG_NAME]
    cmp     r1, #0
    beq.w   72f
    sub     r1, r1, #1
    movw    r0, #0
    strh    r0, [r4, #ACB_REG_NAME]
    REG_BOUND r1, r2
    bhs.w   72f
    REG_TABLE r2, silica_pid_registry_ref
    bl      rt_forget_in
    REG_TABLE r2, silica_dangerous_pid_registry_ref
    bl      rt_forget_in
    REG_TABLE r2, silica_device_pid_registry_ref
    bl      rt_forget_in
72: // the state chain goes back with the actor (rt_state.S)
    mov     r0, r4
    bl      silica_rt_state_chain_free_all
    movw    r0, #0
    str     r0, [r4, #ACB_STATE]
    str     r0, [r4, #ACB_STATE + 4]
    // a supervisor's rows go back (left to the last walker that holds them, rt_supervisors.S)
    mov     r0, r4
    bl      silica_rt_child_table_free
    // the child-table row is stamped for the supervisor's cascade
    ldr     r0, [r4, #ACB_ROW]
    cmp     r0, #0
    beq.w   8f
    movw    r1, #1
    str     r1, [r0, #ROW_EXIT_DONE]
8:  movw    r0, #ST_DEAD
    strb    r0, [r4, #ACB_STATUS]
    pop     {r4-r8, pc}
    .size   silica_rt_actor_exit_body, . - silica_rt_actor_exit_body

// rt_forget_in(r1 = atom, r2 = table, r4 = acb): the slot is cleared when it names this actor. Clobbers r0.
    LFUNC rt_forget_in
    ldr     r0, [r2, r1, lsl #2]
    cmp     r0, r4
    bne.w   9f
    movw    r0, #0
    str     r0, [r2, r1, lsl #2]
9:  bx      lr
    .size   rt_forget_in, . - rt_forget_in

// rt_spawn_waiter_wake(r0 = acb): the spawner suspended in spawn_common until this supervisor's start
// trampoline ran is woken (once): by actor_main after the trampoline, or here when the actor died first.
    LFUNC rt_spawn_waiter_wake
    ldr     r1, [r0, #ACB_SB]
    cmp     r1, #0
    beq.w   9f
    ldr     r0, [r1, #SB_SPAWN_WAITER]
    cmp     r0, #0
    beq.w   9f
    movw    r2, #0
    str     r2, [r1, #SB_SPAWN_WAITER]
    b.w     silica_rt_wake
9:  bx      lr
    .size   rt_spawn_waiter_wake, . - rt_spawn_waiter_wake

// silica_rt_deliver_exit(r0 = acb) -> r0: 0 when the actor has a supervisor (its exit notice is queued in
// the supervisor's ingress, or dropped because the supervisor is dead: spec §15.4.10.4, silently), 1 when
// it has none (a root actor: the caller may print the root note). The notice is a 48-byte block: +0 the
// ACB, +8 the reason tag, +16 the reason atom, +24 the agent type atom, +32 1 when the actor ended inside
// its start trampoline (the supervisor matches the row by the ACB), +40 the ended actor's identity. The
// supervisor's restart logic consumes it (rt_supervisors.S; rt_actors.S actor_main, drain_ingress).
    FUNC silica_rt_deliver_exit
    push    {r4-r6, lr}
    mov     r4, r0
    ldr     r6, [r4, #ACB_SUP]
    cmp     r6, #0
    beq.w   8f
    ldrb    r0, [r6, #ACB_ALIVE]
    cmp     r0, #0
    beq.w   9f                              // a dead supervisor: nothing is queued
    movw    r0, #NOTICE_SIZE
    bl      silica_rt_alloc_or_null
    cmp     r0, #0
    beq.w   9f                              // no memory for the notice: the supervisor is not told
    mov     r5, r0
    str     r4, [r5, #0]
    ldrb    r0, [r4, #ACB_REASON_TAG]
    str     r0, [r5, #8]
    ldrh    r0, [r4, #ACB_REASON_ATOM]
    str     r0, [r5, #16]
    ldrh    r0, [r4, #ACB_AGENT]
    str     r0, [r5, #24]
    ldr     r0, [r4, #ACB_ID]
    str     r0, [r5, #40]
    ldr     r0, [r4, #ACB_ID + 4]
    str     r0, [r5, #44]
    ldr     r1, [r4, #ACB_SB]
    cmp     r1, #0
    beq.w   1f
    ldr     r0, [r1, #SB_TRAMP_RAN]
    tst     r0, #TR_INIT_DEAD
    beq.w   1f
    orr     r0, r0, #TR_NOTICE
    str     r0, [r1, #SB_TRAMP_RAN]
    movw    r0, #1
    str     r0, [r5, #32]
1:  bl      silica_rt_alloc_node
    movw    r1, #2
    str     r1, [r0, #MSG_KIND]
    str     r5, [r0, #MSG_PAYLOAD]
    mov     r1, r0
    mov     r0, r6
    bl      silica_rt_enqueue_ingress
9:  movw    r0, #0
    pop     {r4-r6, pc}
8:  movw    r0, #1
    pop     {r4-r6, pc}
    .size   silica_rt_deliver_exit, . - silica_rt_deliver_exit

// silica_rt_enqueue_ingress(r0 = acb, r1 = node) -> r0 = 0 queued, 1 the target is dead (the node and its
// payload are then the caller's). The ingress is bounded (1024: silica_rt_abort_ingress_full); the target
// becomes ready. AAPCS.
#define INGRESS_LIMIT    1024
    FUNC silica_rt_enqueue_ingress
    push    {r4, r5, lr}
    mov     r4, r0
    mov     r5, r1
    ldrb    r0, [r4, #ACB_ALIVE]
    cmp     r0, #0
    beq.w   8f
    mov     r0, r4
    bl      silica_rt_sb_require
    ldr     r1, [r0, #SB_IN_DEPTH]
    cmp     r1, #INGRESS_LIMIT
    bhs.w   7f
    add     r1, r1, #1
    str     r1, [r0, #SB_IN_DEPTH]
    movw    r1, #0
    str     r1, [r5, #MSG_NEXT]
    ldr     r1, [r0, #SB_IN_TAIL]
    cmp     r1, #0
    beq.w   1f
    str     r5, [r1, #MSG_NEXT]
    str     r5, [r0, #SB_IN_TAIL]
    b.w     2f
1:  str     r5, [r0, #SB_IN_HEAD]
    str     r5, [r0, #SB_IN_TAIL]
2:  mov     r0, r4
    bl      silica_rt_make_ready            // (a supervision_wait_and_drain_one waiter too: ST_WAIT_INGRESS)
    movw    r0, #0
    pop     {r4, r5, pc}
7:  bl      silica_rt_abort_ingress_full
8:  movw    r0, #1
    pop     {r4, r5, pc}
    .size   silica_rt_enqueue_ingress, . - silica_rt_enqueue_ingress

// silica_rt_exit_payload_free(r0 = notice or 0): the notice block goes back; one that holds its actor
// (+32: the actor ended inside its start trampoline) lets go of it (silica_rt_tramp_release, which may
// recycle that ACB). AAPCS.
    FUNC silica_rt_exit_payload_free
    cmp     r0, #0
    beq.w   9f
    push    {r4, r5, r6, lr}
    ldr     r4, [r0, #32]
    ldr     r5, [r0, #0]
    bl      silica_rt_free
    cmp     r4, #0
    beq.w   1f
    mov     r0, r5
    movw    r1, #TR_NOTICE
    bl      silica_rt_tramp_release
1:  pop     {r4, r5, r6, pc}
9:  bx      lr
    .size   silica_rt_exit_payload_free, . - silica_rt_exit_payload_free

// silica_rt_root_report_and_note(r0 = a root supervisor's ACB): its failure report and the root note. With
// a registered FailureReporter the note goes first (the reporter may end the program once it has the
// report); without one the report is written here and the note follows it. AAPCS.
    FUNC silica_rt_root_report_and_note
    push    {r4, lr}
    mov     r4, r0
    MOV32   r0, silica_rt_root_failure_reporter
    ldr     r0, [r0]
    cmp     r0, #0
    beq.w   1f
    MOV32   r0, silica_rt_root_exit_msg
    bl      silica_rt_puts
    mov     r0, r4
    bl      silica_rt_actor_deliver_unwind_report
    pop     {r4, pc}
1:  mov     r0, r4
    bl      silica_rt_actor_deliver_unwind_report
    MOV32   r0, silica_rt_root_exit_msg
    bl      silica_rt_puts
    pop     {r4, pc}
    .size   silica_rt_root_report_and_note, . - silica_rt_root_report_and_note

// The failure payload accessors (emitted code; the payload is the notice above, from
// supervision_wait_and_drain_one): failure_reason_tag / _atom / failure_agent_type -> X0, failure_release
// -> :ok after the block goes back.
    FUNC silica_rt_actor_failure_reason_tag
    cmp     r0, #0
    it      ne
    ldrne   r0, [r0, #8]
    movw    r1, #0
    bx      lr
    .size   silica_rt_actor_failure_reason_tag, . - silica_rt_actor_failure_reason_tag

// reason tag -> failure_reason atom: 0 :normal, 2 :language_error, 3 :memory_fault, 4 :explicit, else
// :unknown (the fixed atom prefix has no :foreign_fault).
    FUNC silica_rt_actor_failure_reason_atom
    cmp     r0, #0
    beq.w   7f
    ldr     r1, [r0, #8]
    movw    r0, #ATOM_NORMAL
    cmp     r1, #0
    beq.w   9f
    movw    r0, #ATOM_LANGUAGE_ERROR
    cmp     r1, #2
    beq.w   9f
    movw    r0, #ATOM_MEMORY_FAULT
    cmp     r1, #3
    beq.w   9f
    movw    r0, #ATOM_EXPLICIT
    cmp     r1, #4
    beq.w   9f
7:  movw    r0, #ATOM_UNKNOWN
9:  movw    r1, #0
    bx      lr
    .size   silica_rt_actor_failure_reason_atom, . - silica_rt_actor_failure_reason_atom

    FUNC silica_rt_actor_failure_agent_type
    cmp     r0, #0
    it      ne
    ldrne   r0, [r0, #24]
    movw    r1, #0
    bx      lr
    .size   silica_rt_actor_failure_agent_type, . - silica_rt_actor_failure_agent_type

    FUNC silica_rt_actor_failure_release
    ENTRY_SAVE
    bl      silica_rt_free
    movw    r0, #ATOM_OK
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_actor_failure_release, . - silica_rt_actor_failure_release

// =============================================================================================
// CPU faults in an actor (spec §15.4.4, runtime_failure_reporting.md §3.2 and §6).

// silica_rt_actor_fault_hook(r0 = cause code, r1 = faulting pc, r2 = fault address or 0, r3 = EXC_RETURN):
// called by rt_vectors.S silica_rt_fault_common on the fault stack, interrupts masked. Returns when the
// fault is the process's -- a cause other than HardFault / MemManage / BusFault / UsageFault, a fault taken
// in handler mode (an interrupt handler's), or no actor running (main, the scheduler) -- and the caller
// reports it as a fatal fault, status 70. Otherwise the running actor ends with :memory_fault (tag 3;
// the cause + 1, the pc and the address saved in the ACB for the device-actor report lines) and this does
// not return: the fault status is cleared, the report depth counted back, and an exception return resumes
// the scheduler's saved context in thread mode (a basic frame built under its saved sp, whose pc is its
// resume address), which runs the actor's exit path (status ST_FAULTED). The context the fault abandoned
// is never resumed; its chunks go back with the actor.
    FUNC silica_rt_actor_fault_hook
    cmp     r0, #3
    blo.w   9f
    cmp     r0, #6
    bhi.w   9f
    and     r12, r3, #0xC                   // EXC_RETURN bit 3: back to thread mode, bit 2: on MSP
    cmp     r12, #8
    bne.w   9f
    MOV32   r12, silica_rt_actors_ready
    ldr     r12, [r12]
    cmp     r12, #0
    beq.w   9f
    MOV32   r12, silica_rt_cores
    ldr     r12, [r12, #CORE_CURRENT]
    cmp     r12, #0
    beq.w   9f
    ldrb    r3, [r12, #ACB_KIND]
    cmp     r3, #KIND_ACTOR
    bne.w   9f
    ldrb    r3, [r12, #ACB_ALIVE]
    cmp     r3, #0
    beq.w   9f                              // a fault on an exit path already under way: the process's
    // A fault raised while the actor's foreign call was running (rt_ffi.S silica_rt_ffi_call keeps
    // VRG_FFI at 1 for the call) is the C code's, whatever the cause -- a bad address, an undefined
    // instruction, a bus error, a C stack run into the FFI chunk's band (MPU region 1): the actor ends
    // with failure_reason :foreign_fault, tag 5, as the hosted guarded region ends it (porting §9.1
    // rule 2). The word is cleared, the band guard switched off and CCR.DIV_0_TRP (which a wrapper may
    // have set to trap a division by zero; the runtime keeps it off) cleared: the context is abandoned.
    ldr     r3, [r9, #VRG_FFI]
    cmp     r3, #0
    beq.w   1f
    movw    r3, #0
    str     r3, [r9, #VRG_FFI]
    MOV32   r4, 0xE000ED98                  // MPU_RNR: region 1, RASR 0
    movw    r3, #1
    str     r3, [r4]
    movw    r3, #0
    str     r3, [r4, #8]
    MOV32   r4, SCB_CCR
    ldr     r3, [r4]
    bic     r3, r3, #0x10
    str     r3, [r4]
    dsb     sy
    isb     sy
    movw    r3, #5
    b.w     2f
1:  movw    r3, #3
2:  strb    r3, [r12, #ACB_REASON_TAG]
    add     r3, r0, #1
    strb    r3, [r12, #ACB_FAULT_CAUSE]
    str     r1, [r12, #ACB_FAULT_EPC]
    str     r2, [r12, #ACB_FAULT_VADDR]
    movw    r3, #0
    strb    r3, [r12, #ACB_ALIVE]
    movw    r3, #ST_FAULTED
    strb    r3, [r12, #ACB_STATUS]
    // the fault is handled: its status bits cleared (write one to clear), the report depth counted back
    MOV32   r3, SCB_CFSR
    ldr     r0, [r3]
    str     r0, [r3]
    MOV32   r3, SCB_HFSR
    ldr     r0, [r3]
    str     r0, [r3]
    MOV32   r3, silica_rt_fatal_depth
    ldr     r0, [r3]
    sub     r0, r0, #1
    str     r0, [r3]
    // the scheduler becomes the running context again
    MOV32   r3, silica_rt_cores
    ldr     r4, [r3, #CORE_SCHED]
    str     r4, [r3, #CORE_CURRENT]
    mov     r0, r4
    bl      silica_rt_publish_context
    ldr     r0, [r4, #ACB_CTX_A1]           // its saved sp
    ldr     r1, [r4, #ACB_CTX_A0]           // its resume address (silica_rt_ctx_resume)
    bic     r1, r1, #1                      // an exception return takes the bare address
    movw    r3, #0
    movt    r3, #0x0100                     // xPSR: the Thumb bit
    sub     r2, r0, #32                     // the 8-word frame, 8-byte aligned under the saved sp;
    tst     r0, #7                          // xPSR bit 9 tells the return to add the 4 alignment bytes
    itt     ne
    subne   r2, r2, #4
    orrne   r3, r3, #0x200
    movw    r0, #0
    str     r0, [r2, #0]                    // r0-r3, r12, lr: unused by the resume
    str     r0, [r2, #4]
    str     r0, [r2, #8]
    str     r0, [r2, #12]
    str     r0, [r2, #16]
    str     r0, [r2, #20]
    str     r1, [r2, #24]                   // pc
    str     r3, [r2, #28]                   // xPSR
    msr     msp, r2
    mvn     lr, #6                          // EXC_RETURN 0xFFFFFFF9: thread mode, MSP, basic frame
    cpsie   i
    bx      lr
9:  bx      lr
    .size   silica_rt_actor_fault_hook, . - silica_rt_actor_fault_hook

// =============================================================================================
// The failure report (spec §15.4.6.4, runtime_failure_reporting.md §7): composed into a buffer, then
// cast to the registered root FailureReporter or written on the console:
//   \n=== Silica Actor Failure ===\nactor_id:        N\nagent_type_atom: N\nreason:          R
//   \nreason_tag:      N\nsupervisor_acb:  0x........\ncall_stack:\n  #0  <behaviour symbol>
//   \n  #1  _actor_thread_main\n=== End Silica Actor Failure ===\n
// (a device actor that ended on a CPU exception adds exccause / epc / excvaddr after reason_tag).

// rt_report_puts(r0 = C string): append. Clobbers r0-r3, r12.
    LFUNC rt_report_puts
    MOV32   r1, silica_rt_report_len
    ldr     r2, [r1]
    MOV32   r3, silica_rt_report_buf
1:  ldrb    r12, [r0], #1
    cmp     r12, #0
    beq.w   2f
    cmp     r2, #REPORT_PUTS_STOP
    bhs.w   2f
    strb    r12, [r3, r2]
    add     r2, r2, #1
    b.w     1b
2:  str     r2, [r1]
    bx      lr
    .size   rt_report_puts, . - rt_report_puts

// rt_report_hex(r0 = value): "0x" and 8 hex digits. Clobbers r0-r3, r12.
    LFUNC rt_report_hex
    push    {r4, lr}
    MOV32   r1, silica_rt_report_len
    ldr     r2, [r1]
    MOV32   r3, silica_rt_report_buf
    add     r3, r3, r2
    add     r2, r2, #10
    str     r2, [r1]
    movw    r12, #48
    strb    r12, [r3], #1
    movw    r12, #120
    strb    r12, [r3], #1
    movw    r4, #8
1:  lsr     r12, r0, #28
    cmp     r12, #10
    ite     lo
    addlo   r12, r12, #48
    addhs   r12, r12, #87
    strb    r12, [r3], #1
    lsl     r0, r0, #4
    subs    r4, r4, #1
    bne.w   1b
    pop     {r4, pc}
    .size   rt_report_hex, . - rt_report_hex

// rt_report_udec64(r0 = low word, r1 = high word): unsigned decimal (rt_console.S print_u64_raw's
// division). Clobbers r0-r3, r12.
    LFUNC rt_report_udec64
    push    {r4-r7, lr}
    sub     sp, sp, #24
    add     r4, sp, #24
    mov     r6, r0
    mov     r7, r1
1:  movw    r5, #10
    udiv    r0, r7, r5
    mls     r1, r0, r5, r7
    mov     r7, r0
    lsr     r2, r6, #16
    orr     r2, r2, r1, lsl #16
    udiv    r3, r2, r5
    mls     r1, r3, r5, r2
    uxth    r2, r6
    orr     r2, r2, r1, lsl #16
    udiv    r0, r2, r5
    mls     r1, r0, r5, r2
    orr     r6, r0, r3, lsl #16
    add     r1, r1, #48
    strb    r1, [r4, #-1]!
    orrs    r0, r6, r7
    bne.w   1b
    // append [r4, sp + 24)
    MOV32   r1, silica_rt_report_len
    ldr     r2, [r1]
    MOV32   r3, silica_rt_report_buf
    add     r5, sp, #24
2:  cmp     r4, r5
    bhs.w   3f
    ldrb    r12, [r4], #1
    strb    r12, [r3, r2]
    add     r2, r2, #1
    b.w     2b
3:  str     r2, [r1]
    add     sp, sp, #24
    pop     {r4-r7, pc}
    .size   rt_report_udec64, . - rt_report_udec64

// rt_report_dec(r0 = signed 32-bit value): decimal. Clobbers r0-r3, r12.
    LFUNC rt_report_dec
    push    {r4, lr}
    cmp     r0, #0
    bge.w   1f
    push    {r0}
    MOV32   r0, silica_rt_minus_str
    bl      rt_report_puts
    pop     {r0}
    rsb     r0, r0, #0
1:  movw    r1, #0
    bl      rt_report_udec64
    pop     {r4, pc}
    .size   rt_report_dec, . - rt_report_dec

// silica_rt_report_reason(r0 = acb): the reason line's text (spec §15.4.13, §15.4.6.4): the failure_reason
// variant the tag names, spelled as a program spells it (:normal, :language_error, :memory_fault,
// (:explicit, :atom) with the atom's name from the image's silica_rt_atom_names), or :unknown for a tag the
// runtime does not give; a language error whose site recorded a detail adds an em dash and the detail.
// AAPCS.
    FUNC silica_rt_report_reason
    push    {r4, r5, r6, lr}
    ldrb    r4, [r0, #ACB_REASON_TAG]
    ldrh    r5, [r0, #ACB_REASON_ATOM]
    cmp     r4, #0
    beq.w   10f
    cmp     r4, #2
    beq.w   20f
    cmp     r4, #3
    beq.w   30f
    cmp     r4, #4
    beq.w   40f
    cmp     r4, #5
    beq.w   50f
9:  MOV32   r0, silica_rt_rline_unknown
    bl      rt_report_puts
    pop     {r4, r5, r6, pc}
10: MOV32   r0, silica_rt_rline_normal
    bl      rt_report_puts
    pop     {r4, r5, r6, pc}
20: MOV32   r0, silica_rt_rline_language_error
    bl      rt_report_puts
    cmp     r5, #1
    beq.w   21f
    cmp     r5, #2
    beq.w   22f
    pop     {r4, r5, r6, pc}
21: MOV32   r6, silica_rt_rline_detail_div_zero
    b.w     23f
22: MOV32   r6, silica_rt_rline_detail_case
23: MOV32   r0, silica_rt_rline_detail_sep
    bl      rt_report_puts
    mov     r0, r6
    bl      rt_report_puts
    pop     {r4, r5, r6, pc}
30: MOV32   r0, silica_rt_rline_memory_fault
    bl      rt_report_puts
    pop     {r4, r5, r6, pc}
40: MOV32   r0, silica_rt_atom_name_count   // an index the table does not hold prints :unknown
    ldr     r0, [r0]
    cmp     r5, r0
    bhs.w   9b
    MOV32   r0, silica_rt_atom_names
    ldr     r6, [r0, r5, lsl #2]
    MOV32   r0, silica_rt_rline_explicit_open
    bl      rt_report_puts
    mov     r0, r6
    bl      rt_report_puts
    MOV32   r0, silica_rt_banner_rp
    bl      rt_report_puts
    pop     {r4, r5, r6, pc}
50: MOV32   r0, silica_rt_rline_foreign_fault
    bl      rt_report_puts
    pop     {r4, r5, r6, pc}
    .size   silica_rt_report_reason, . - silica_rt_report_reason

// rt_report_device_fault(r0 = acb): the device-actor fault lines (after reason_tag) when the actor is a
// device actor and a CPU exception was captured. The labels are the ESP32-S3 board's, so the block keeps
// one shape on both boards; the cause is the Cortex-M exception number (3 HardFault, 4 MemManage,
// 5 BusFault, 6 UsageFault), epc the faulting pc, excvaddr MMFAR / BFAR when valid, else 0.
    LFUNC rt_report_device_fault
    push    {r4, r5, lr}
    mov     r4, r0
    ldrb    r0, [r4, #ACB_DEVICE]
    cmp     r0, #0
    beq.w   9f
    ldrb    r5, [r4, #ACB_FAULT_CAUSE]
    cmp     r5, #0
    beq.w   9f
    sub     r5, r5, #1
    MOV32   r0, silica_rt_banner_exc
    bl      rt_report_puts
    mov     r0, r5
    bl      rt_report_dec
    sub     r5, r5, #3
    cmp     r5, #3
    bhi.w   1f
    MOV32   r0, silica_rt_banner_lp
    bl      rt_report_puts
    MOV32   r0, silica_rt_exc_names
    ldr     r0, [r0, r5, lsl #2]
    bl      rt_report_puts
    MOV32   r0, silica_rt_banner_rp
    bl      rt_report_puts
1:  MOV32   r0, silica_rt_banner_epc
    bl      rt_report_puts
    ldr     r0, [r4, #ACB_FAULT_EPC]
    bl      rt_report_hex
    MOV32   r0, silica_rt_banner_vaddr
    bl      rt_report_puts
    ldr     r0, [r4, #ACB_FAULT_VADDR]
    bl      rt_report_hex
9:  pop     {r4, r5, pc}
    .size   rt_report_device_fault, . - rt_report_device_fault

// silica_rt_actor_deliver_unwind_report(r0 = the dying actor): compose the report; a registered, alive,
// cast-capable root FailureReporter other than the dying actor receives it by a cast (its mailbox buffer
// is one heap block holding a Silica string header and the text, MSG_PAYLOAD_OWNED 2, listed until
// handle_report takes it, so the exit drain prints what the reporter never handled); otherwise the text
// goes to the console now. A dying reporter unregisters itself. No back-pressure: the dying actor never
// waits. AAPCS. r4 = acb, r5 = length, r6 = the reporter's ACB, r7 = the block's bytes, r8 = the block.
    FUNC silica_rt_actor_deliver_unwind_report
    push    {r4-r8, lr}
    mov     r4, r0
    MOV32   r1, silica_rt_report_len
    movw    r0, #0
    str     r0, [r1]
    MOV32   r0, silica_rt_banner_head
    bl      rt_report_puts
    ldr     r0, [r4, #ACB_ID]               // the actor's identity, as an integer
    ldr     r1, [r4, #ACB_ID + 4]
    bl      rt_report_udec64
    MOV32   r0, silica_rt_banner_agent
    bl      rt_report_puts
    ldrh    r0, [r4, #ACB_AGENT]
    bl      rt_report_dec
    MOV32   r0, silica_rt_banner_reason_text
    bl      rt_report_puts
    mov     r0, r4
    bl      silica_rt_report_reason
    MOV32   r0, silica_rt_banner_reason
    bl      rt_report_puts
    ldrb    r0, [r4, #ACB_REASON_TAG]
    bl      rt_report_dec
    mov     r0, r4
    bl      rt_report_device_fault
    MOV32   r0, silica_rt_banner_sup
    bl      rt_report_puts
    ldr     r0, [r4, #ACB_SUP]
    bl      rt_report_hex
    MOV32   r0, silica_rt_banner_stack
    bl      rt_report_puts
    ldr     r0, [r4, #ACB_BEH]
    cmp     r0, #0
    beq.w   1f
    bl      silica_rt_behaviour_name
    b.w     2f
1:  MOV32   r0, silica_rt_behaviour_unknown
2:  bl      rt_report_puts
    MOV32   r0, silica_rt_banner_tail
    bl      rt_report_puts
    MOV32   r1, silica_rt_report_len
    ldr     r5, [r1]
    MOV32   r1, silica_rt_report_buf
    movw    r0, #0
    strb    r0, [r1, r5]                    // NUL after the text (the buffer keeps spare bytes)
    // the reporter
    MOV32   r0, silica_rt_root_failure_reporter
    ldr     r0, [r0]
    cmp     r0, #0
    beq.w   5f
    MOV32   r1, silica_rt_root_failure_reporter_id
    ldr     r0, [r1, #0]
    ldr     r2, [r4, #ACB_ID]
    cmp     r0, r2
    bne.w   3f
    ldr     r0, [r1, #4]
    ldr     r2, [r4, #ACB_ID + 4]
    cmp     r0, r2
    beq.w   4f                              // the dying actor is the reporter
3:  ldr     r0, [r1, #0]
    ldr     r1, [r1, #4]
    bl      rt_ref_acb_or_0
    cmp     r0, #0
    beq.w   5f                              // an ended reporter: no failure of the dying actor's
    mov     r6, r0
    ldr     r0, [r6, #ACB_CONV]
    and     r0, r0, #3
    cmp     r0, #1
    beq.w   5f                              // a call-only reporter (§16.2.6.4): written instead
    add     r7, r5, #(24 + 1 + 15)          // header 24, the text, its NUL, rounded to 16
    bic     r7, r7, #15
    mov     r0, r7
    bl      silica_rt_alloc_or_null         // zeroed
    cmp     r0, #0
    beq.w   5f                              // no memory for the block: written instead
    mov     r8, r0
    mvn     r0, #0
    str     r0, [r8, #0]                    // the string tag
    str     r0, [r8, #4]
    add     r0, r8, #24
    str     r0, [r8, #8]                    // data
    str     r5, [r8, #16]                   // length
    MOV32   r1, silica_rt_report_buf
    mov     r2, r5
    bl      memcpy
    mov     r0, r8
    bl      silica_rt_report_list_add
    bl      silica_rt_alloc_node
    movw    r1, #0
    str     r1, [r0, #MSG_KIND]
    str     r1, [r0, #MSG_NEXT]
    str     r8, [r0, #MSG_PAYLOAD]
    str     r8, [r0, #MSG_BUF_BLOCK]
    str     r7, [r0, #MSG_BUF_BYTES]
    movw    r1, #2
    str     r1, [r0, #MSG_PAYLOAD_OWNED]    // a report: report_begin at its dispatch
    ldr     r1, [r6, #ACB_MB_TAIL]
    cmp     r1, #0
    beq.w   31f
    str     r0, [r1, #MSG_NEXT]
    str     r0, [r6, #ACB_MB_TAIL]
    b.w     32f
31: str     r0, [r6, #ACB_MB_HEAD]
    str     r0, [r6, #ACB_MB_TAIL]
32: mov     r0, r6
    bl      silica_rt_make_ready
    b.w     9f
4:  MOV32   r1, silica_rt_root_failure_reporter
    movw    r0, #0
    str     r0, [r1]
5:  MOV32   r0, silica_rt_report_buf
    mov     r2, r5
    bl      silica_rt_write                 // (an emitted-code entry: X0 = bytes, X1 = count)
9:  pop     {r4-r8, pc}
    .size   silica_rt_actor_deliver_unwind_report, . - silica_rt_actor_deliver_unwind_report

// =============================================================================================
// The reports the FailureReporter holds, and the exit drain.

// silica_rt_report_begin(r0 = report): handle_report is about to run on it (rt_actors.S actor_main): the
// owner record names it, then it leaves the pending list (in that order: the drain never misses it).
    FUNC silica_rt_report_begin
    MOV32   r1, silica_rt_report_owner
    str     r0, [r1, #0]
    movw    r2, #0
    str     r2, [r1, #4]
    b.w     silica_rt_report_list_take
    .size   silica_rt_report_begin, . - silica_rt_report_begin

// silica_rt_report_end(r0 = report) -> r0 = 1 to keep it (sent on, or not the recorded one), 0 released.
    FUNC silica_rt_report_end
    MOV32   r1, silica_rt_report_owner
    ldr     r2, [r1, #0]
    cmp     r2, r0
    bne.w   1f
    movw    r2, #0
    str     r2, [r1, #0]
    ldr     r0, [r1, #4]
    bx      lr
1:  movw    r0, #1
    bx      lr
    .size   silica_rt_report_end, . - silica_rt_report_end

// silica_rt_report_list_add(r0 = report) -> r0 = 1 listed, 0 no memory (it is then simply not listed).
    FUNC silica_rt_report_list_add
    push    {r4, lr}
    mov     r4, r0
    movw    r0, #8
    bl      silica_rt_alloc_or_null
    cmp     r0, #0
    beq.w   9f
    movw    r1, #0
    str     r1, [r0, #0]
    str     r4, [r0, #4]
    MOV32   r1, silica_rt_report_list
1:  ldr     r2, [r1]
    cmp     r2, #0
    beq.w   2f
    mov     r1, r2
    b.w     1b
2:  str     r0, [r1]
    movw    r0, #1
9:  pop     {r4, pc}
    .size   silica_rt_report_list_add, . - silica_rt_report_list_add

// silica_rt_report_list_take(r0 = report) -> r0 = 1 when it was listed (it is not any more), 0 when not.
    FUNC silica_rt_report_list_take
    MOV32   r1, silica_rt_report_list
1:  ldr     r2, [r1]
    cmp     r2, #0
    beq.w   8f
    ldr     r3, [r2, #4]
    cmp     r3, r0
    beq.w   2f
    mov     r1, r2
    b.w     1b
2:  ldr     r3, [r2, #0]
    str     r3, [r1]
    push    {r4, lr}
    mov     r0, r2
    bl      silica_rt_free
    movw    r0, #1
    pop     {r4, pc}
8:  movw    r0, #0
    bx      lr
    .size   silica_rt_report_list_take, . - silica_rt_report_list_take

// silica_rt_report_write_block(r0 = report block): a report queued for a FailureReporter that ended before
// handling it goes to the console once (data at +8, length at +16) and off the pending list. The block is
// the caller's to free.
    FUNC silica_rt_report_write_block
    push    {r4, lr}
    mov     r4, r0
    bl      silica_rt_report_list_take
    ldr     r0, [r4, #8]
    ldr     r2, [r4, #16]
    bl      silica_rt_write
    pop     {r4, pc}
    .size   silica_rt_report_write_block, . - silica_rt_report_write_block

// silica_rt_report_drain_at_exit(): main has returned (rt_start.S, before silica_rt_exit) or failed
// (silica_rt_main_fail_exit). Each report handed to the reporter is printed once (§15.4.13.4): while a
// death's report is still being made, or one is pending or being handled and the reporter is alive, main
// gives the core to the actors (it goes to the back of the ready queue) and then sleeps until the next
// tick, DRAIN_STEPS times at most; what is still pending then goes to the console, oldest first. A
// report the reporter is handling when the wait ends is the reporter's to print. AAPCS.
    FUNC silica_rt_report_drain_at_exit
    push    {r4, r5, lr}
    bl      silica_rt_current
    mov     r5, r0
    ldrb    r0, [r5, #ACB_KIND]
    cmp     r0, #KIND_MAIN
    bne.w   6f
    movw    r4, #DRAIN_STEPS
1:  MOV32   r0, silica_rt_report_inflight
    ldr     r0, [r0]
    cmp     r0, #0
    bne.w   5f
    MOV32   r0, silica_rt_report_list
    ldr     r0, [r0]
    MOV32   r1, silica_rt_report_owner
    ldr     r1, [r1]
    orrs    r0, r0, r1
    beq.w   6f
    MOV32   r0, silica_rt_root_failure_reporter
    ldr     r0, [r0]
    cmp     r0, #0
    beq.w   6f
    MOV32   r0, silica_rt_root_failure_reporter_id
    ldr     r1, [r0, #4]
    ldr     r0, [r0]
    bl      rt_ref_acb_or_0
    cmp     r0, #0
    beq.w   6f
5:  cmp     r4, #0
    beq.w   6f
    sub     r4, r4, #1
    movw    r0, #ST_SUSPENDED
    strb    r0, [r5, #ACB_STATUS]
    mov     r0, r5
    bl      silica_rt_make_ready
    bl      silica_rt_yield_to_sched
    wfi                                     // the next tick (or the console's receive interrupt)
    b.w     1b
6:  MOV32   r1, silica_rt_report_list
    ldr     r4, [r1]
    movw    r0, #0
    str     r0, [r1]
7:  cmp     r4, #0
    beq.w   9f
    ldr     r1, [r4, #4]
    ldr     r0, [r1, #8]
    ldr     r2, [r1, #16]
    bl      silica_rt_write
    ldr     r4, [r4, #0]
    b.w     7b
9:  pop     {r4, r5, pc}
    .size   silica_rt_report_drain_at_exit, . - silica_rt_report_drain_at_exit

// silica_rt_main_fail_exit(r0 = the failure atom's name, a line): main's language-level failure
// (§15.4.5.5): the name on the console, then the reports still pending or being made (as the hosts' exit
// drain prints them after it), then exit status 1. Runs on main's stack where it failed. Never returns.
    FUNC silica_rt_main_fail_exit
    bl      silica_rt_puts
    bl      silica_rt_report_drain_at_exit
    movw    r0, #1
    bl      silica_rt_exit
1:  b.w     1b
    .size   silica_rt_main_fail_exit, . - silica_rt_main_fail_exit

    .ltorg

// =============================================================================================
    .section .rodata.silica_rt_failure, "a", %progbits
    .global silica_rt_root_exit_msg
silica_rt_root_exit_msg:
    .asciz  "[silica] root actor exited (no supervisor)\n"
silica_rt_language_error_msg:
    .asciz  "language_error\n"
silica_rt_actor_not_found_msg:
    .asciz  "actor_not_found\n"
silica_rt_badarith_msg:
    .asciz  "badarith\n"
silica_rt_case_clause_msg:
    .asciz  "case_clause\n"
silica_rt_unknown_prim_msg:
    .asciz  "unknown actor runtime entry"
silica_rt_minus_str:
    .asciz  "-"
silica_rt_banner_head:
    .asciz  "\n=== Silica Actor Failure ===\nactor_id:        "
silica_rt_banner_agent:
    .asciz  "\nagent_type_atom: "
silica_rt_banner_reason_text:
    .asciz  "\nreason:          "
silica_rt_banner_reason:
    .asciz  "\nreason_tag:      "
silica_rt_rline_normal:          .asciz ":normal"
silica_rt_rline_language_error:  .asciz ":language_error"
silica_rt_rline_memory_fault:    .asciz ":memory_fault"
silica_rt_rline_explicit_open:   .asciz "(:explicit, "
silica_rt_rline_unknown:         .asciz ":unknown"
silica_rt_rline_foreign_fault:   .asciz ":foreign_fault"
silica_rt_rline_detail_sep:      .asciz " \342\200\224 "
silica_rt_rline_detail_div_zero: .asciz "integer division by zero"
silica_rt_rline_detail_case:     .asciz "no case arm matched"
silica_rt_banner_exc:
    .asciz  "\nexccause:        "
silica_rt_banner_epc:
    .asciz  "\nepc:             "
silica_rt_banner_vaddr:
    .asciz  "\nexcvaddr:        "
silica_rt_banner_lp:
    .asciz  " ("
silica_rt_banner_rp:
    .asciz  ")"
silica_rt_exc_n3:  .asciz "HardFault"
silica_rt_exc_n4:  .asciz "MemManage"
silica_rt_exc_n5:  .asciz "BusFault"
silica_rt_exc_n6:  .asciz "UsageFault"
    .balign 4
silica_rt_exc_names:
    .word   silica_rt_exc_n3, silica_rt_exc_n4, silica_rt_exc_n5, silica_rt_exc_n6
silica_rt_banner_sup:
    .asciz  "\nsupervisor_acb:  "
silica_rt_banner_stack:
    .asciz  "\ncall_stack:\n  #0  "
silica_rt_banner_tail:
    .asciz  "\n  #1  _actor_thread_main\n=== End Silica Actor Failure ===\n"

// Weak defaults for the atom words and the atom-name table every compiler-emitted runtime unit defines
// (emitter_core xt_runtime_registry_words): -1 (no such atom) and no names, for hand-written images.
    .section .rodata.silica_failure_default, "a", %progbits
    .balign 4
    .weak   silica_registry_atom_killed
silica_registry_atom_killed:
    .word   -1
    .weak   silica_registry_atom_out_of_memory
silica_registry_atom_out_of_memory:
    .word   -1
    .weak   silica_registry_atom_buf_bounds
silica_registry_atom_buf_bounds:
    .word   -1
    .weak   silica_registry_atom_buf_invalid
silica_registry_atom_buf_invalid:
    .word   -1
    .weak   silica_registry_atom_list_index
silica_registry_atom_list_index:
    .word   -1
    .weak   silica_rt_atom_name_count
silica_rt_atom_name_count:
    .word   0
    .weak   silica_rt_atom_names
silica_rt_atom_names:
    .word   0
