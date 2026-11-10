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

// Actor runtime for the bare-metal STM32L476RG: the cooperative scheduler of silica-specification.md
// §15.1.2 / §23.1.1 on one Cortex-M4 core, with the entry points the emitter's
// terms/prims/prims_actors.silica calls (the same `silica_rt_*` names and the same ACB, chunk and
// message layouts as the ESP32-S3 runtime, board/runtime/rt_actors.S there, which is the reference
// for every observable behaviour here; design_documents/ports/esp32s3_xtensa_port.md §8).
//
// STAGE 1 OF THE PORT (the base trial suite): what is here is spawn (plain, registered, supervisor
// with its start trampoline, children of a supervisor), cast and the registered casts, the mailbox
// and the dispatch loop, run_behaviour with the convention word, wait_for_exit / cast_exit, the exit
// line on the console, the registries as tables, the FailureReporter registration, growable machine
// and auxiliary stacks (chunk chains) with the emitted-code growth entries, and the context switch.
// Messaging (2026-11-09): call / call_registered with replies placed into the caller's stack
// (rt_state.S silica_rt_reply_place), recv, the registry actor of get_registry_actor, behaviour_name.
// Failure handling (2026-11-09): an actor's end, kill/fail/stop, traps, CPU faults in an actor and the
// failure reports are rt_failure.S; the scheduler loop below runs the exit path of an actor that ended
// where it stood (ST_FAULTED) or at its boundary.
// Timers, priorities and dispatch-order policies (2026-11-10, groups 4 and 5): send_after / cancel_timer /
// timer_prepare over the SysTick millisecond, three ready queues and the four policies of the ESP32-S3.
// Group 6 (2026-11-10): the stack release policies at the dispatch boundary and the :release_when_idle
// scan, get_actor_memory_usage, get_cpu_topology / get_core_capabilities / get_performance_cores.
// Not here yet: links and monitors beyond the benign returns (supervision itself is rt_supervisors.S),
// the enforcement of a lowered stack reservation (stack_policy(n, ...) with n > 0 is recorded and
// reported, chunks grow until the heap is exhausted).
// Identities (2026-11-10, spec §15.1.4): an actor_ref is the actor's 64-bit identity, position << 32 |
// child number, never an ACB address ("Actor identity" below).
//
// Model. There is no OS. Every context -- `main`, each actor, and the scheduler -- is a machine stack
// plus an auxiliary (emitter `SP`) stack, and switches happen only where the specification allows: at
// a dispatch boundary (the behaviour returned) or where the running context suspends to wait
// (`wait_for_exit`, a spawner waiting for a supervisor's start trampoline, an actor with an empty
// mailbox). Nothing is preempted: the only interrupt is SysTick, which touches its counter and nothing
// else. The scheduler loop pops the next ready context, records it as current, publishes its stack
// limits in the register block and switches to it; the context switches back when it parks, suspends
// or reaches its boundary.
//
// Context switch. silica_rt_ctx_switch(save, load) keeps the resume address (lr), sp, the emitter SP
// and the frame floor in the ACB and loads the other context's. Every register the emitted code keeps
// live across a runtime call is on the saved context's own stack (ENTRY_SAVE), so nothing else is
// saved. A context is first entered through a landing routine (silica_rt_ctx_prepare) with a fresh
// stack: the actor's loop is entered afresh at every dispatch, on the first chunk of its chain.
//
// Stacks (spec §15.1.2.2). An actor's machine stack and its auxiliary stack are each a chain of heap
// chunks that starts small and grows on demand ("Growable stacks" below): a chunk is a 16-byte-aligned
// heap block with a 64-byte header (chain links, size, the entering frame's return address and the
// caller's sp, the limit, the top, the index) and a 64-byte band, the frames or slabs above, filled
// downward from the top. Nothing is taken at spawn: the scheduler gives an actor its first chunks when
// it dispatches it (2 KB machine, 512 B auxiliary), and at each dispatch boundary it gives back what its
// stack_policy algorithm does not keep ("Stack release policies" below). Growth is where emitted code checks its limits:
// every prologue compares its would-be sp with VRG_MLIMIT (the current chunk's band top plus
// _silica_rt_depth_reserve, the deepest runtime chain emitted code can call), every auxiliary
// reservation the new SP with VRG_ALIMIT. There is no guard watchpoint on this port: the limit checks
// are the guard. `main` is not an actor: its two stacks are fixed, sized by the linker script, and a
// limit it crosses is a fatal fault (status 70).
//
// Result and status conventions follow the reference: spawn -> the actor's reference, cast -> 1,
// send -> 0, register -> 0, wait_for_exit -> the first cast_exit value (or 0 for an "exit" line),
// cast_exit -> 1 when its request was recorded, 0 when an earlier one was.

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

#define SCHED_STACK_SIZE 1024
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
// Dispatch-order policies (set_scheduler_policy) and the tiers' weights: "Ready queues and
// dispatch-order policies" below.
#define POLICY_PRIORITY_FIFO 0
#define POLICY_ROUND_ROBIN   1
#define POLICY_WEIGHTED_FAIR 2
#define POLICY_LOTTERY       3
#define POLICY_COUNT         4
#define WEIGHT_HIGH          4
#define WEIGHT_NORMAL        2
#define WEIGHT_LOW           1
// Stack release algorithms (the low nibble of ACB_POLICY; terms/prims/prims_actors.silica
// emit_stack_policy) and their parameters: "Stack release policies" below.
#define ALG_RELEASE_ON_RETURN  1
#define ALG_KEEP_LAST_MESSAGE  2
#define ALG_TRACK_RECENT_PEAK  3
#define ALG_RELEASE_WHEN_IDLE  4
#define ALG_KEEP_HIGH_WATER    5
#define RING_SIZE              32
#define IDLE_RELEASE_MS        1000     // :release_when_idle: a second without a message
#define IDLE_SCAN_MS           250      // the scheduler scans its idle actors at most every quarter second
// Reserved shape numbers of the records this runtime builds (atoms/record_shape.silica,
// runtime_shape_lexemes: 65536 + the table position) and the atoms they name.
#define SHAPE_CORE_INFO        65537
#define SHAPE_CPU_TOPOLOGY     65538
#define SHAPE_NUMA_NODE        65539
#define SHAPE_MEMORY_RANGE     65540
#define SHAPE_CACHE_HIERARCHY  65541
#define SHAPE_ACTOR_MEMORY     65543
#define ATOM_PERFORMANCE       1
// Timer records (silica_rt_timer_prepare / send_after, "Clocks and timers" below): the ESP32-S3's layout.
#define TMR_NEXT        0
#define TMR_ID          4       // the timer number (8 B; never reused)
#define TMR_DL          12      // the deadline in SysTick milliseconds (8 B)
#define TMR_TGT         20      // the target reference (8 B: its identity)
#define TMR_MSG         28      // the message word (8 B)
#define TMR_OWNED       36      // the message's mailbox buffer block, 0 inline
#define TMR_THUNK       40      // its bytes
#define TMR_SIZE        48

    .section .bss.silica_rt_actors, "aw", %nobits
    .balign 16
    .global silica_rt_cores
silica_rt_cores:
    .space  CORE_SIZE
    .global silica_rt_main_acb
silica_rt_main_acb:
    .space  ACB_SIZE
silica_rt_sched_acb:
    .space  ACB_SIZE
    .global silica_rt_main_mchunk
silica_rt_main_mchunk:
    .space  CH_HEADER
    .global silica_rt_main_achunk
silica_rt_main_achunk:
    .space  CH_HEADER
    .balign 16
silica_rt_sched_stack_bottom:
    .space  SCHED_STACK_SIZE
silica_rt_sched_stack_top:
    .global silica_rt_actors_ready
silica_rt_actors_ready:
    .space  4
    .global silica_rt_exit_flag
silica_rt_exit_flag:
    .space  4
    .global silica_rt_exit_request
silica_rt_exit_request:
    .space  8
    .global silica_rt_wait_root_acb
silica_rt_wait_root_acb:
    .space  4
    .global silica_rt_root_failure_reporter
silica_rt_root_failure_reporter:
    .space  4
    .global silica_rt_root_failure_reporter_id
silica_rt_root_failure_reporter_id:
    .space  8
    .global silica_rt_region_dump_limit
silica_rt_region_dump_limit:
    .space  8
silica_rt_acb_free:
    .space  4
silica_rt_node_free:
    .space  4
silica_rt_registry_acb:                     // the plain registry's actor, made on first request
    .space  4
silica_rt_acb_all:                          // the chain of every ACB taken from the heap (ACB_ALL_NEXT)
    .space  4
silica_rt_idle_scan_at:                     // SysTick ms of the last :release_when_idle scan
    .space  4
    // identity (§15.1.4; "Actor identity" below)
    .global silica_rt_next_position
silica_rt_next_position:                    // set to 1 by silica_rt_actors_init (main is position 0)
    .space  4
    .global silica_rt_spawn_rec_override
silica_rt_spawn_rec_override:               // a spawner record that numbers the next spawn instead (0 none)
    .space  4
    .global silica_rt_main_spawner
silica_rt_main_spawner:                     // position + 1 = 1, set by silica_rt_actors_init
    .space  8
    .global silica_rt_runtime_spawner
silica_rt_runtime_spawner:                  // position 0xFFFFFFFE (+ 1), set by silica_rt_actors_init
    .space  8
    .balign 8
    .global silica_rt_dead_acb
silica_rt_dead_acb:                         // what a spawn returns for a supervisor that ended in its start
    .space  ACB_SIZE                        // trampoline (spawn_common): never alive, never recycled
    .balign 8
    .global silica_rt_ticks_ms
silica_rt_ticks_ms:
    .space  8
    // the registries' tables (heap blocks of silica_rt_reg_slots words, made by silica_rt_actors_init)
    .global silica_pid_registry_ref
silica_pid_registry_ref:
    .space  4
    .global silica_dangerous_pid_registry_ref
silica_dangerous_pid_registry_ref:
    .space  4
    .global silica_device_pid_registry_ref
silica_device_pid_registry_ref:
    .space  4
    .global silica_rt_reg_slots
silica_rt_reg_slots:
    .space  4

// The wall clock: the loader may write the host's Unix time in milliseconds into the 8 bytes after the
// tag (board/tools/run_on_board.py); current_time adds the millisecond count from there. Zero when the
// loader wrote nothing (milliseconds since the start, then).
    .section .data.silica_rt_wall_clock, "aw", %progbits
    .balign 8
    .ascii  "SILICA:WALLCLOCK"
    .global silica_rt_wall_clock
silica_rt_wall_clock:
    .word   0, 0

    .weak   silica_rt_reply_tag
    .weak   silica_rt_no_reply_tag

    .section .text.silica_rt_actors, "ax", %progbits

// ---------------------------------------------------------------------------------------------
// Initialisation (idempotent; called by rt_start.S and by the first entry that needs it).
    FUNC silica_rt_actors_init
    push    {r4-r7, lr}
    MOV32   r4, silica_rt_actors_ready
    ldr     r0, [r4]
    cmp     r0, #0
    bne.w   9f
    movw    r0, #1
    str     r0, [r4]
    MOV32   r4, silica_rt_cores
    MOV32   r5, silica_rt_sched_acb
    MOV32   r6, silica_rt_main_acb
    str     r5, [r4, #CORE_SCHED]
    str     r6, [r4, #CORE_CURRENT]         // main runs until something else does
    movw    r0, #WEIGHT_HIGH                // weighted fair starts a round at the high tier (tier 0)
    str     r0, [r4, #CORE_WF_CREDIT]
    movw    r0, #1                          // main's pseudo-ACB is a normal-priority context
    strb    r0, [r6, #ACB_PRIO]
    movw    r0, #KIND_SCHED
    strb    r0, [r5, #ACB_KIND]
    movw    r0, #1
    strb    r0, [r5, #ACB_ALIVE]
    mov     r0, r5
    MOV32   r1, silica_rt_sched_landing
    MOV32   r2, silica_rt_sched_stack_top
    bl      silica_rt_ctx_prepare
    // main's pseudo-ACB and its two fixed stacks as chunk headers
    movw    r0, #KIND_MAIN
    strb    r0, [r6, #ACB_KIND]
    movw    r0, #1
    strb    r0, [r6, #ACB_ALIVE]
    movw    r0, #ST_RUNNING
    strb    r0, [r6, #ACB_STATUS]
    MOV32   r7, silica_rt_main_mchunk
    str     r7, [r6, #ACB_MCHAIN]
    str     r7, [r6, #ACB_MCUR]
    MOV32   r0, _silica_heap_end
    str     r0, [r7, #CH_BAND]
    MOV32   r1, _silica_rt_depth_reserve
    add     r0, r0, r1
    add     r0, r0, #64
    str     r0, [r7, #CH_LIMIT]
    MOV32   r0, _silica_stack_top
    str     r0, [r7, #CH_TOP]
    movw    r0, #1
    str     r0, [r7, #CH_INDEX]
    MOV32   r7, silica_rt_main_achunk
    str     r7, [r6, #ACB_ACHAIN]
    str     r7, [r6, #ACB_ACUR]
    MOV32   r0, silica_rt_aux_stack_bottom
    str     r0, [r7, #CH_BAND]
    add     r0, r0, #64
    str     r0, [r7, #CH_LIMIT]
    MOV32   r0, silica_rt_aux_stack_top
    str     r0, [r7, #CH_TOP]
    movw    r0, #1
    str     r0, [r7, #CH_INDEX]
    // the registries: one slot per atom of the image (silica_registry_slots), at least REG_SLOTS_MIN
    MOV32   r0, silica_registry_slots
    ldr     r4, [r0]
    cmp     r4, #REG_SLOTS_MIN
    it      lo
    movlo   r4, #REG_SLOTS_MIN
    MOV32   r0, silica_rt_reg_slots
    str     r4, [r0]
    lsl     r4, r4, #2
    mov     r0, r4
    bl      silica_rt_alloc                 // zeroed
    MOV32   r1, silica_pid_registry_ref
    str     r0, [r1]
    mov     r0, r4
    bl      silica_rt_alloc
    MOV32   r1, silica_dangerous_pid_registry_ref
    str     r0, [r1]
    mov     r0, r4
    bl      silica_rt_alloc
    MOV32   r1, silica_device_pid_registry_ref
    str     r0, [r1]
    // identity (§15.1.4): main is position 0, the runtime's own actors position 0xFFFFFFFE, and the
    // first position handed out is 1
    movw    r0, #1
    MOV32   r1, silica_rt_next_position
    str     r0, [r1]
    MOV32   r1, silica_rt_main_spawner
    str     r0, [r1]
    mvn     r0, #0
    MOV32   r1, silica_rt_runtime_spawner
    str     r0, [r1]
9:  pop     {r4-r7, pc}
    .size   silica_rt_actors_init, . - silica_rt_actors_init

// silica_rt_current() -> r0 = the running context's ACB (AAPCS).
    FUNC silica_rt_current
    MOV32   r0, silica_rt_cores
    ldr     r0, [r0, #CORE_CURRENT]
    bx      lr
    .size   silica_rt_current, . - silica_rt_current

// silica_rt_current_actor() -> X0 = the running actor's ACB, or 0 in main / the scheduler.
    FUNC silica_rt_current_actor
    ENTRY_SAVE
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #0
    it      ne
    movne   r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_current_actor, . - silica_rt_current_actor

// self() -> X0 = the running actor's reference (its identity; all ones in main, no actor's).
    FUNC silica_rt_actor_self
    ENTRY_SAVE
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #KIND_ACTOR
    it      ne
    movne   r0, #0
    bl      silica_rt_acb_ident
    ENTRY_RET_X0
    .size   silica_rt_actor_self, . - silica_rt_actor_self

// ---------------------------------------------------------------------------------------------
// Blocks: ACBs and message nodes from the heap, recycled through free lists.
// Every ACB ever taken from the heap is on the chain silica_rt_acb_all (ACB_ALL_NEXT; kept across the free
// list and the zeroing of a reused ACB): the :release_when_idle scan walks it (silica_rt_actor_idle_scan).
    FUNC silica_rt_alloc_acb
    push    {r4, r5, lr}
    MOV32   r4, silica_rt_acb_free
    ldr     r0, [r4]
    cmp     r0, #0
    beq.w   1f
    ldr     r1, [r0, #ACB_FREE_NEXT]
    str     r1, [r4]
    ldr     r5, [r0, #ACB_ALL_NEXT]
    mov     r4, r0
    movw    r1, #ACB_SIZE
    bl      silica_rt_zero_block
    mov     r0, r4
    str     r5, [r0, #ACB_ALL_NEXT]
    b.w     2f
1:  movw    r0, #ACB_SIZE
    bl      silica_rt_alloc
    MOV32   r1, silica_rt_acb_all
    ldr     r2, [r1]
    str     r2, [r0, #ACB_ALL_NEXT]
    str     r0, [r1]
2:  mvn     r1, #0                          // no identity until its spawn gives it one: all ones,
    str     r1, [r0, #ACB_ID]               // which no actor has (silica_rt_ref_acb never finds it)
    str     r1, [r0, #ACB_ID + 4]
    pop     {r4, r5, pc}
    .size   silica_rt_alloc_acb, . - silica_rt_alloc_acb

// silica_rt_free_acb(r0 = acb): the ACB and its supervision block go back. A supervisor's ACB is recycled
// exactly once, by the last of its holders (the ESP32-S3's SB_TRAMP_RAN bits): its own end (here), its
// spawner (TR_SPAWNER, from spawn until the spawner has the reference in hand; for a row child until the
// row holds it, rt_supervisors.S spawn_child_row) and, for one that ended inside its start trampoline,
// its exit notice (TR_NOTICE, until a supervisor has handled it: the row is matched by the ACB). While a
// holder remains it is marked TR_OWN_DONE and left to silica_rt_tramp_release; while a walker holds its
// rows (SB_CT_USERS) it is left to the last walker (SB_CT_PENDING bit 1). AAPCS.
    FUNC silica_rt_free_acb
    push    {r4, lr}
    mov     r4, r0
    // The actor has ended: its pending timers are cancelled (spec §22.14.2) and their buffers given back
    // (a due timer would find no actor by the identity anyway).
    bl      silica_rt_timers_purge
    ldr     r0, [r4, #ACB_SB]
    cmp     r0, #0
    beq.w   2f
    ldr     r1, [r0, #SB_TRAMP_RAN]
    tst     r1, #(TR_SPAWNER | TR_NOTICE)
    beq.w   1f
    orr     r1, r1, #TR_OWN_DONE
    str     r1, [r0, #SB_TRAMP_RAN]
    pop     {r4, pc}
1:  ldr     r1, [r0, #SB_CT_USERS]
    cmp     r1, #0
    beq.w   11f
    ldr     r1, [r0, #SB_CT_PENDING]
    orr     r1, r1, #2
    str     r1, [r0, #SB_CT_PENDING]
    pop     {r4, pc}
11: movw    r1, #0
    str     r1, [r4, #ACB_SB]
    bl      silica_rt_free
2:  ldr     r0, [r4, #ACB_RING]             // the usage ring (:track_recent_peak) goes back with the ACB
    cmp     r0, #0
    beq.w   21f
    movw    r1, #0
    str     r1, [r4, #ACB_RING]
    bl      silica_rt_free
21: movw    r0, #ST_DEAD
    strb    r0, [r4, #ACB_STATUS]
    mvn     r0, #0                          // recycled: its identity no longer resolves (§15.1.4)
    str     r0, [r4, #ACB_ID]
    str     r0, [r4, #ACB_ID + 4]
    MOV32   r1, silica_rt_acb_free
    ldr     r2, [r1]
    str     r2, [r4, #ACB_FREE_NEXT]
    str     r4, [r1]
    pop     {r4, pc}
    .size   silica_rt_free_acb, . - silica_rt_free_acb

// silica_rt_tramp_release(r0 = acb, r1 = hold): a holder of a supervisor's ACB (TR_SPAWNER or TR_NOTICE)
// lets go. When the actor has ended and was left to its holders (TR_OWN_DONE) and this was the last one,
// the ACB is recycled now. acb 0 or an actor without a supervision block: nothing to do. AAPCS.
    FUNC silica_rt_tramp_release
    cmp     r0, #0
    beq.w   9f
    ldr     r2, [r0, #ACB_SB]
    cmp     r2, #0
    beq.w   9f
    ldr     r3, [r2, #SB_TRAMP_RAN]
    bic     r3, r3, r1
    str     r3, [r2, #SB_TRAMP_RAN]
    tst     r3, #(TR_SPAWNER | TR_NOTICE)
    bne.w   9f
    tst     r3, #TR_OWN_DONE
    bne.w   silica_rt_free_acb
9:  bx      lr
    .size   silica_rt_tramp_release, . - silica_rt_tramp_release

    FUNC silica_rt_alloc_node
    push    {r4, lr}
    MOV32   r4, silica_rt_node_free
    ldr     r0, [r4]
    cmp     r0, #0
    beq.w   1f
    ldr     r1, [r0, #MSG_NEXT]
    str     r1, [r4]
    movw    r1, #MSG_SIZE
    bl      silica_rt_zero_block
    pop     {r4, pc}
1:  movw    r0, #MSG_SIZE
    bl      silica_rt_alloc
    pop     {r4, pc}
    .size   silica_rt_alloc_node, . - silica_rt_alloc_node

    FUNC silica_rt_free_node
    MOV32   r1, silica_rt_node_free
    ldr     r2, [r1]
    str     r2, [r0, #MSG_NEXT]
    str     r0, [r1]
    bx      lr
    .size   silica_rt_free_node, . - silica_rt_free_node

// rt_node_release_payload(r0 = node): the message copy a cast, send or call carried (its mailbox
// buffer) goes back to the heap when the node is dropped without a dispatch (an unknown target, an
// actor's end, a supervisor without a behaviour). Keeps r0.
    FUNC silica_rt_node_release_payload
    .thumb_func
rt_node_release_payload:
    push    {r4, lr}
    mov     r4, r0
    movw    r1, #0
    str     r1, [r4, #MSG_PAYLOAD_OWNED]
    ldr     r0, [r4, #MSG_BUF_BLOCK]
    cmp     r0, #0
    beq.w   9f
    str     r1, [r4, #MSG_BUF_BLOCK]
    str     r1, [r4, #MSG_BUF_BYTES]
    bl      silica_rt_free
9:  mov     r0, r4
    pop     {r4, pc}
    .size   silica_rt_node_release_payload, . - silica_rt_node_release_payload

// rt_complete_death(r0 = node): a call completes with reply set 2 (the target ended before replying;
// the caller raises actor_not_found, spec §16.1.1) and its caller is woken (the caller frees the node);
// a caller that ended while it waited leaves the node to be freed here.
    FUNC silica_rt_complete_death
    .thumb_func
rt_complete_death:
    push    {r4, lr}
    mov     r4, r0
    ldr     r1, [r4, #MSG_REPLY_SET]
    cmp     r1, #0
    bne.w   9f
    movw    r1, #0
    str     r1, [r4, #MSG_REPLY]
    str     r1, [r4, #MSG_REPLY + 4]
    movw    r1, #2
    str     r1, [r4, #MSG_REPLY_SET]
    ldr     r0, [r4, #MSG_CALLER]
    cmp     r0, #0
    beq.w   8f
    bl      silica_rt_wake
    pop     {r4, pc}
8:  mov     r0, r4
    bl      silica_rt_free_node
9:  pop     {r4, pc}
    .size   silica_rt_complete_death, . - silica_rt_complete_death

// silica_rt_sb_require(r0 = acb) -> r0 = its supervision block, allocated on demand.
    FUNC silica_rt_sb_require
    push    {r4, lr}
    mov     r4, r0
    ldr     r0, [r4, #ACB_SB]
    cmp     r0, #0
    bne.w   1f
    movw    r0, #SB_SIZE
    bl      silica_rt_alloc
    str     r0, [r4, #ACB_SB]
1:  pop     {r4, pc}
    .size   silica_rt_sb_require, . - silica_rt_sb_require

// ---------------------------------------------------------------------------------------------
// Ready queues and dispatch-order policies (group 5, 2026-11-10; the ESP32-S3's rt_actors.S
// "Dispatch-order policies" and design_documents/ports/esp32s3_xtensa_port.md §8.10, on one core).
// Three FIFO ready queues, one per priority level (set_actor_priority, §22.10: ACB_PRIO 0 low,
// 1 normal, 2 high; queue index 2 - ACB_PRIO, so index 0 is high). One policy is in force for the
// whole program (silica_rt_sched_policy, set_scheduler_policy); it decides only which READY context
// runs next, never when a running one stops (nothing preempts between the yield points of §15.1.2):
//   PRIORITY_FIFO   the default: the head of the highest-priority non-empty queue.
//   ROUND_ROBIN     every push lands in the normal queue whatever the priority: strict arrival order.
//   WEIGHTED_FAIR   deficit round robin over the three tiers, unit cost per dispatch, quanta high 4,
//                   normal 2, low 1; an empty tier forfeits its quantum; FIFO within a tier.
//   LOTTERY         a tier holds weight x (contexts queued in it) tickets; a xorshift32 draw picks
//                   the tier in proportion and its head runs.
// A change takes effect at the next push or pop and leaves queued contexts where they are (a context
// whose priority changes while it is queued keeps its place until its next push). main's pseudo-ACB
// is a normal-priority context like any other (silica_rt_actors_init). Interrupts never touch the
// queues (SysTick only counts, the USART only fills its ring), so no lock is needed on one core.
// POLICY_* and WEIGHT_* are defined at the top of this file.

    .section .bss.silica_rt_actors, "aw", %nobits
    .balign 4
silica_rt_sched_policy:                     // POLICY_* in force; zero = PRIORITY_FIFO
    .space  4
silica_rt_lottery_state:                    // xorshift32 state, seeded at the first draw
    .space  4

    .section .text.silica_rt_actors, "ax", %progbits

// silica_rt_make_ready(r0 = acb): a parked, suspended or waiting context becomes ready: onto the tail
// of the queue of its priority (under ROUND_ROBIN, of the normal queue). A context that is ready or
// running already is left alone (a running actor re-queues itself at its boundary when its mailbox is
// not empty). Clobbers r1 and r2 only.
    FUNC silica_rt_make_ready
    .thumb_func
    .global silica_rt_wake
silica_rt_wake:
    ldrb    r1, [r0, #ACB_STATUS]
    cmp     r1, #ST_READY
    beq.w   9f
    cmp     r1, #ST_RUNNING
    beq.w   9f
    cmp     r1, #ST_DEAD
    beq.w   9f
    cmp     r1, #ST_FAULTED                 // ended where it stood: only its exit path is left (rt_failure.S)
    beq.w   9f
    movw    r1, #ST_READY
    strb    r1, [r0, #ACB_STATUS]
    movw    r1, #0
    str     r1, [r0, #ACB_NEXT_READY]
    push    {r3}                            // the single-queue version clobbered r1/r2 only: callers keep r3
    MOV32   r2, silica_rt_sched_policy
    ldr     r2, [r2]
    movw    r3, #1                          // round robin: arrival order in the normal queue
    cmp     r2, #POLICY_ROUND_ROBIN
    beq.w   3f
    ldrb    r3, [r0, #ACB_PRIO]             // 0 low, 1 normal, 2 high -> queue index 2 - prio
    cmp     r3, #3
    it      hs
    movhs   r3, #1
    rsb     r3, r3, #2
3:  MOV32   r2, silica_rt_cores
    add     r2, r2, r3, lsl #2              // &head; &tail = +12, &len = +40
    pop     {r3}
    ldr     r1, [r2, #CORE_RQ_LEN]
    add     r1, r1, #1
    str     r1, [r2, #CORE_RQ_LEN]
    ldr     r1, [r2, #CORE_RQ_TAIL]
    cmp     r1, #0
    beq.w   1f
    str     r0, [r1, #ACB_NEXT_READY]
    str     r0, [r2, #CORE_RQ_TAIL]
    bx      lr
1:  str     r0, [r2, #CORE_RQ_HEAD]
    str     r0, [r2, #CORE_RQ_TAIL]
9:  bx      lr
    .size   silica_rt_make_ready, . - silica_rt_make_ready

// rt_rq_take(r1 = queue index) -> r0 = the head of that queue, which must not be empty. Clobbers r1-r3.
    LFUNC rt_rq_take
    MOV32   r2, silica_rt_cores
    add     r2, r2, r1, lsl #2
    ldr     r0, [r2, #CORE_RQ_HEAD]
    ldr     r3, [r0, #ACB_NEXT_READY]
    str     r3, [r2, #CORE_RQ_HEAD]
    cmp     r3, #0
    it      eq
    streq   r3, [r2, #CORE_RQ_TAIL]
    ldr     r3, [r2, #CORE_RQ_LEN]
    sub     r3, r3, #1
    str     r3, [r2, #CORE_RQ_LEN]
    bx      lr
    .size   rt_rq_take, . - rt_rq_take

// silica_rt_rq_pop() -> r0 = the next ready context under the policy in force, or 0. AAPCS.
    LFUNC silica_rt_rq_pop
    push    {r4-r6, lr}
    MOV32   r4, silica_rt_cores
    MOV32   r0, silica_rt_sched_policy
    ldr     r0, [r0]
    cmp     r0, #POLICY_WEIGHTED_FAIR
    beq.w   20f
    cmp     r0, #POLICY_LOTTERY
    beq.w   30f
    // PRIORITY_FIFO (and ROUND_ROBIN, whose pushes all land in the normal queue): the head of the
    // highest-priority non-empty queue
    movw    r1, #0
1:  ldr     r0, [r4, r1, lsl #2]
    cmp     r0, #0
    bne.w   9f
    add     r1, r1, #1
    cmp     r1, #3
    blo.w   1b
    movw    r0, #0
    pop     {r4-r6, pc}
9:  bl      rt_rq_take
    pop     {r4-r6, pc}
20: // WEIGHTED_FAIR: serve the current tier while it has credit and contexts; otherwise the next tier
    // starts with its quantum (an empty tier forfeits its turn). Some queue is non-empty, so at most
    // three tier changes reach a tier that runs.
    ldr     r0, [r4, #CORE_RQ_HEAD]
    ldr     r1, [r4, #CORE_RQ_HEAD + 4]
    orr     r0, r0, r1
    ldr     r1, [r4, #CORE_RQ_HEAD + 8]
    orrs    r0, r0, r1
    it      eq
    popeq   {r4-r6, pc}                     // r0 = 0: nothing ready
    ldr     r1, [r4, #CORE_WF_TIER]
    ldr     r5, [r4, #CORE_WF_CREDIT]
22: ldr     r0, [r4, r1, lsl #2]
    cmp     r0, #0
    beq.w   23f
    cmp     r5, #0
    beq.w   23f
    sub     r5, r5, #1
    str     r1, [r4, #CORE_WF_TIER]
    str     r5, [r4, #CORE_WF_CREDIT]
    b.w     9b
23: add     r1, r1, #1
    cmp     r1, #3
    it      hs
    movhs   r1, #0
    movw    r5, #WEIGHT_HIGH
    cmp     r1, #0
    beq.w   22b
    movw    r5, #WEIGHT_NORMAL
    cmp     r1, #1
    beq.w   22b
    movw    r5, #WEIGHT_LOW
    b.w     22b
30: // LOTTERY: tickets = weight x contexts queued, per tier; draw in [0, total) and find the tier
    ldr     r5, [r4, #CORE_RQ_LEN]
    lsl     r5, r5, #2                      // WEIGHT_HIGH x high
    ldr     r6, [r4, #CORE_RQ_LEN + 4]
    lsl     r6, r6, #1                      // WEIGHT_NORMAL x normal
    ldr     r3, [r4, #CORE_RQ_LEN + 8]      // WEIGHT_LOW x low
    add     r3, r3, r5
    adds    r3, r3, r6                      // total tickets
    itt     eq
    moveq   r0, #0
    popeq   {r4-r6, pc}
    // xorshift32 (Marsaglia 2003: 13, 17, 5), not cryptographic; seeded the first time from the
    // SysTick current value and the millisecond count, kept non-zero by the OR.
    MOV32   r12, silica_rt_lottery_state
    ldr     r0, [r12]
    cmp     r0, #0
    bne.w   32f
    MOV32   r0, SYSTICK_CVR
    ldr     r0, [r0]
    MOV32   r1, silica_rt_ticks_ms
    ldr     r1, [r1]
    eor     r0, r0, r1, lsl #17
    orr     r0, r0, #1
32: eor     r0, r0, r0, lsl #13
    eor     r0, r0, r0, lsr #17
    eor     r0, r0, r0, lsl #5
    str     r0, [r12]
    udiv    r2, r0, r3
    mls     r0, r2, r3, r0                  // the draw
    movw    r1, #0
    cmp     r0, r5
    blo.w   9b                              // below the high tier's tickets: high
    sub     r0, r0, r5
    movw    r1, #1
    cmp     r0, r6
    blo.w   9b                              // then the normal tier's
    movw    r1, #2                          // else low (its count is non-zero, or total would be smaller)
    b.w     9b
    .size   silica_rt_rq_pop, . - silica_rt_rq_pop

// silica_rt_ctx_prepare(r0 = acb, r1 = landing routine, r2 = stack top): the first entry of a context
// lands in the routine with a fresh stack; the routine reads the ACB from CORE_CURRENT.
    FUNC silica_rt_ctx_prepare
    orr     r1, r1, #1
    str     r1, [r0, #ACB_CTX_A0]
    str     r2, [r0, #ACB_CTX_A1]
    bx      lr
    .size   silica_rt_ctx_prepare, . - silica_rt_ctx_prepare

// rt_publish_context(r0 = acb): the register block takes this context's SP, floor and limits (the
// scheduler has no chunks: its limits are left as they are, it runs no emitted code).
    FUNC silica_rt_publish_context
    .thumb_func
rt_publish_context:
    ldr     r1, [r0, #ACB_CTX_VSP]
    str     r1, [r9, #VRG_VSP]
    ldr     r1, [r0, #ACB_CTX_FLOOR]
    str     r1, [r9, #VRG_FLOOR]
    ldr     r1, [r0, #ACB_MCUR]
    cmp     r1, #0
    beq.w   9f
    str     r1, [r9, #VRG_MCHUNK]
    ldr     r2, [r1, #CH_LIMIT]
    str     r2, [r9, #VRG_MLIMIT]
    ldr     r1, [r0, #ACB_ACUR]
    cmp     r1, #0
    beq.w   9f
    str     r1, [r9, #VRG_ACHUNK]
    ldr     r2, [r1, #CH_LIMIT]
    str     r2, [r9, #VRG_ALIMIT]
    ldr     r2, [r1, #CH_PREV]
    cmp     r2, #0
    bne.w   1f
    movw    r2, #0xFFFF                     // the first chunk (or main): a release never pops it
    movt    r2, #0xFFFF
    str     r2, [r9, #VRG_ATOP]
    bx      lr
1:  ldr     r2, [r1, #CH_TOP]
    ldr     r3, [r1, #CH_MIRROR]
    sub     r2, r2, r3
    str     r2, [r9, #VRG_ATOP]
9:  bx      lr
    .size   silica_rt_publish_context, . - silica_rt_publish_context

// silica_rt_ctx_switch(r0 = save, r1 = load): returns when the saved context is switched back to.
    FUNC silica_rt_ctx_switch
    push    {r4-r8, r10, r11, lr}           // the saving context's registers, on its own stack
    str     sp, [r0, #ACB_CTX_A1]
    MOV32   r2, silica_rt_ctx_resume
    orr     r2, r2, #1
    str     r2, [r0, #ACB_CTX_A0]
    ldr     r2, [r9, #VRG_VSP]
    str     r2, [r0, #ACB_CTX_VSP]
    ldr     r2, [r9, #VRG_FLOOR]
    str     r2, [r0, #ACB_CTX_FLOOR]
    MOV32   r2, silica_rt_cores
    str     r1, [r2, #CORE_CURRENT]
    mov     r4, r1
    mov     r0, r1
    bl      rt_publish_context
    ldr     r2, [r4, #ACB_CTX_A1]
    mov     sp, r2
    ldr     pc, [r4, #ACB_CTX_A0]
    .size   silica_rt_ctx_switch, . - silica_rt_ctx_switch

// Where a saved context resumes: its registers back from its own stack, then the return into the
// routine that switched away.
    LFUNC silica_rt_ctx_resume
    pop     {r4-r8, r10, r11, pc}
    .size   silica_rt_ctx_resume, . - silica_rt_ctx_resume

// silica_rt_yield_to_sched(): the running context gives the core to the scheduler; returns when it
// is dispatched again.
    FUNC silica_rt_yield_to_sched
    push    {r4, lr}
    bl      silica_rt_current
    MOV32   r1, silica_rt_cores
    ldr     r1, [r1, #CORE_SCHED]
    bl      silica_rt_ctx_switch
    pop     {r4, pc}
    .size   silica_rt_yield_to_sched, . - silica_rt_yield_to_sched

// The scheduler's landing and loop (on the scheduler's own stack).
    FUNC silica_rt_sched_landing
    bl      silica_rt_sched_loop
1:  b.w     1b
    .size   silica_rt_sched_landing, . - silica_rt_sched_landing

    FUNC silica_rt_sched_loop
    push    {r4-r7, lr}
    MOV32   r4, silica_rt_cores
1:  // the console's receive side: an "exit" line ends the program (§15.1.2.5)
    bl      silica_rt_console_poll_exit_line
    cmp     r0, #0
    beq.w   2f
    movw    r0, #0
    movw    r1, #0
    bl      silica_rt_exit_request_record
2:  // timers whose deadline has passed (spec §22.14.2): a dispatch boundary or an idle pass, never
    // inside a dispatch (§15.1.2); the wfi below wakes at every SysTick, so a due timer is cast within
    // a millisecond of its deadline when the core is idle
    bl      silica_rt_timers_fire
    // :release_when_idle actors a second after their last message (at most every quarter second)
    bl      silica_rt_actor_idle_scan
    bl      silica_rt_rq_pop
    mov     r5, r0
    cmp     r5, #0
    bne.w   3f
    movw    r0, #0
    str     r0, [r4, #CORE_BUSY]
    wfi                                     // nothing ready: sleep until the next tick (the UART is polled)
    b.w     1b
3:  ldrb    r0, [r5, #ACB_STATUS]
    cmp     r0, #ST_DEAD
    beq.w   7f                              // ended while queued: its exit path ran, the ACB is left
    cmp     r0, #ST_FAULTED
    beq.w   71f
    ldrb    r0, [r5, #ACB_ALIVE]
    cmp     r0, #0
    beq.w   72f                             // ended while queued, exit path not run yet
    movw    r0, #ST_RUNNING
    strb    r0, [r5, #ACB_STATUS]
    movw    r0, #1
    str     r0, [r4, #CORE_BUSY]
    // an actor at a dispatch boundary has no context: it gets its chunks (unless it kept them) and
    // is entered afresh at the top of its loop
    ldr     r0, [r5, #ACB_CTX_A0]
    cmp     r0, #0
    bne.w   4f
    mov     r0, r5
    bl      silica_rt_actor_stacks_prepare
4:  MOV32   r0, silica_rt_sched_acb
    mov     r1, r5
    bl      silica_rt_ctx_switch
    // the context suspended, reached its boundary or ended
    MOV32   r0, silica_rt_sched_acb
    str     r0, [r4, #CORE_CURRENT]
    ldrb    r0, [r5, #ACB_STATUS]
    cmp     r0, #ST_DEAD
    beq.w   7f
    cmp     r0, #ST_FAULTED
    beq.w   71f                             // a trap or a CPU fault ended it where it stood
    cmp     r0, #ST_BOUNDARY
    bne.w   1b
    // the boundary: the loop is entered afresh next time; a waiting message re-queues the actor. Its
    // stacks are empty: what its stack_policy algorithm does not keep goes back first (spec §15.1.2.2)
    movw    r0, #0
    str     r0, [r5, #ACB_CTX_A0]
    mov     r0, r5
    bl      silica_rt_actor_release_policy
    ldrb    r0, [r5, #ACB_ALIVE]
    cmp     r0, #0
    beq.w   72f                             // ended at its boundary (stop_self): the exit path, here
    ldr     r0, [r5, #ACB_MB_HEAD]
    cmp     r0, #0
    bne.w   5f
    ldr     r0, [r5, #ACB_SB]
    cmp     r0, #0
    beq.w   6f
    ldr     r0, [r0, #SB_IN_HEAD]
    cmp     r0, #0
    beq.w   6f
5:  movw    r0, #ST_IDLE
    strb    r0, [r5, #ACB_STATUS]
    mov     r0, r5
    bl      silica_rt_make_ready
    b.w     1b
6:  movw    r0, #ST_IDLE
    strb    r0, [r5, #ACB_STATUS]
    b.w     1b
71: // the exit path on behalf of a context that will never run again, on this stack (rt_failure.S):
    movw    r1, #0                          // a failure (trap, CPU fault): no root note
    b.w     73f
72: movw    r1, #1                          // ended by stop_self / remove_actor / kill_abnormal
73: movw    r0, #ST_RUNNING                 // (a wake-up meanwhile is ignored)
    strb    r0, [r5, #ACB_STATUS]
    MOV32   r0, silica_rt_sched_acb
    str     r0, [r4, #CORE_CURRENT]
    mov     r0, r5
    bl      silica_rt_actor_exit
7:  // ended: its chunks and ACB go back
    mov     r0, r5
    bl      silica_rt_actor_recycle
    b.w     1b
    .size   silica_rt_sched_loop, . - silica_rt_sched_loop

// silica_rt_actor_release(r0 = acb): an ended actor's chains and state chain go back
// to the heap; the ACB stays (an ended actor still in the ready queue keeps it until the scheduler pops
// it). Idempotent: every pointer it frees is cleared. AAPCS.
    FUNC silica_rt_actor_release
    push    {r4, lr}
    mov     r4, r0
    ldrb    r0, [r4, #ACB_KIND]
    cmp     r0, #KIND_ACTOR
    bne.w   9f
    ldr     r0, [r4, #ACB_MCHAIN]
    bl      silica_rt_chunks_free_from
    ldr     r0, [r4, #ACB_ACHAIN]
    bl      silica_rt_chunks_free_from
    movw    r0, #0
    str     r0, [r4, #ACB_MCHAIN]
    str     r0, [r4, #ACB_MCUR]
    str     r0, [r4, #ACB_ACHAIN]
    str     r0, [r4, #ACB_ACUR]
    // (the supervision block goes back with the ACB, silica_rt_free_acb: a supervisor's holders and its
    // rows' walkers read it until then)
    mov     r0, r4                          // the state chain and the release log (rt_state.S)
    bl      silica_rt_state_chain_free_all
    movw    r0, #0
    str     r0, [r4, #ACB_STATE]
    str     r0, [r4, #ACB_STATE + 4]
    movw    r0, #ST_DEAD
    strb    r0, [r4, #ACB_STATUS]
9:  pop     {r4, pc}
    .size   silica_rt_actor_release, . - silica_rt_actor_release

// silica_rt_actor_recycle(r0 = acb): the release, then the ACB itself goes back.
    FUNC silica_rt_actor_recycle
    push    {r4, lr}
    mov     r4, r0
    ldrb    r0, [r4, #ACB_KIND]
    cmp     r0, #KIND_ACTOR
    bne.w   9f
    mov     r0, r4
    bl      silica_rt_actor_release
    mov     r0, r4
    bl      silica_rt_free_acb
9:  pop     {r4, pc}
    .size   silica_rt_actor_recycle, . - silica_rt_actor_recycle

// ---------------------------------------------------------------------------------------------
// Stack release policies (spec §15.1.2.2; the ESP32-S3's silica_rt_actor_release_policy and
// silica_rt_actor_idle_scan on one core). At the dispatch boundary the scheduler gives back the chunks the
// actor's algorithm does not keep, in the chunk sizes the stack grew by. ACB_PEAK holds how many chunks
// of each chain this dispatch reached (machine bits 0-7, auxiliary 8-15; stack_grow / aux_grow raise
// them, stacks_prepare starts them at 1) and the ring index (16-23); what an algorithm keeps is a prefix
// of each chain:
//   1 release_on_return   nothing
//   2 keep_last_message   what this dispatch reached (also an unset algorithm, 0)
//   3 track_recent_peak   the most any of the last 32 dispatches reached (the ring, ACB_RING: one byte a
//                         dispatch, machine chunks in the low nibble, auxiliary in the high, saturated at 15)
//   4 release_when_idle   everything, stamped (ACB_LAST_MSG, SysTick ms); silica_rt_actor_idle_scan frees
//                         it once a second has passed without a message
//   5 keep_high_water     everything
// The lowered reservation (the policy word's top bits) is not enforced (rt_actors.S silica_rt_chunk_next).

// rt_chain_bytes(r0 = chunk) -> r0 = the bytes of that chunk and every chunk above it. Leaf: r0, r1, r12.
    LFUNC rt_chain_bytes
    mov     r1, r0
    movw    r0, #0
1:  cmp     r1, #0
    beq.w   9f
    ldr     r12, [r1, #CH_SIZE]
    add     r0, r0, r12
    ldr     r1, [r1, #CH_NEXT]
    b.w     1b
9:  bx      lr
    .size   rt_chain_bytes, . - rt_chain_bytes

// rt_chain_trim(r0 = &head, r1 = keep): the chain keeps its first `keep` chunks and the rest go back
// (keep 0: the whole chain, the head cleared). AAPCS.
    LFUNC rt_chain_trim
    push    {r4, lr}
    mov     r2, r0                          // r2 = the link that ends the kept part
    ldr     r3, [r2]                        // r3 = the chunk at that link
1:  cmp     r3, #0
    beq.w   9f
    cmp     r1, #0
    beq.w   2f
    sub     r1, r1, #1
    add     r2, r3, #CH_NEXT
    ldr     r3, [r3, #CH_NEXT]
    b.w     1b
2:  movw    r0, #0
    str     r0, [r2]
    mov     r0, r3
    bl      silica_rt_chunks_free_from
9:  pop     {r4, pc}
    .size   rt_chain_trim, . - rt_chain_trim

// rt_trim_both(r0 = acb, r1 = machine chunks kept, r2 = auxiliary chunks kept): both chains trimmed; the
// current chunks are the first ones again (0 when a chain went back whole). AAPCS.
    LFUNC rt_trim_both
    push    {r4, r5, r6, lr}
    mov     r4, r0
    mov     r6, r2
    add     r0, r4, #ACB_MCHAIN
    bl      rt_chain_trim
    add     r0, r4, #ACB_ACHAIN
    mov     r1, r6
    bl      rt_chain_trim
    ldr     r0, [r4, #ACB_MCHAIN]
    str     r0, [r4, #ACB_MCUR]
    ldr     r0, [r4, #ACB_ACHAIN]
    str     r0, [r4, #ACB_ACUR]
    pop     {r4, r5, r6, pc}
    .size   rt_trim_both, . - rt_trim_both

// silica_rt_actor_release_policy(r0 = acb): the scheduler's step at an actor's dispatch boundary (its
// stacks are empty and its context abandoned), on the scheduler's stack. AAPCS.
    FUNC silica_rt_actor_release_policy
    push    {r4-r8, lr}
    mov     r4, r0
    ldrb    r0, [r4, #ACB_KIND]
    cmp     r0, #KIND_ACTOR
    bne.w   9f
    ldr     r0, [r4, #ACB_POLICY]
    and     r0, r0, #15
    ldr     r7, [r4, #ACB_PEAK]
    uxtb    r5, r7                          // r5 = machine chunks reached
    ubfx    r6, r7, #8, #8                  // r6 = auxiliary chunks reached
    cmp     r0, #ALG_RELEASE_ON_RETURN
    beq.w   1f
    cmp     r0, #ALG_TRACK_RECENT_PEAK
    beq.w   3f
    cmp     r0, #ALG_RELEASE_WHEN_IDLE
    beq.w   4f
    cmp     r0, #ALG_KEEP_HIGH_WATER
    beq.w   8f
    b.w     2f
1:  movw    r5, #0
    movw    r6, #0
    b.w     2f
3:  // the ring takes this dispatch, then the most any entry holds is kept (an actor without a ring
    // block keeps what this dispatch reached, as keep_last_message)
    ldr     r8, [r4, #ACB_RING]
    cmp     r8, #0
    beq.w   2f
    cmp     r5, #15
    it      hi
    movhi   r5, #15
    cmp     r6, #15
    it      hi
    movhi   r6, #15
    orr     r0, r5, r6, lsl #4
    ubfx    r1, r7, #16, #8                 // the ring index
    strb    r0, [r8, r1]
    add     r1, r1, #1
    and     r1, r1, #(RING_SIZE - 1)
    bic     r7, r7, #0xFF0000
    orr     r7, r7, r1, lsl #16
    str     r7, [r4, #ACB_PEAK]
    movw    r5, #0
    movw    r6, #0
    movw    r1, #0
31: ldrb    r0, [r8, r1]
    and     r2, r0, #15
    cmp     r5, r2
    it      lo
    movlo   r5, r2
    lsr     r2, r0, #4
    cmp     r6, r2
    it      lo
    movlo   r6, r2
    add     r1, r1, #1
    cmp     r1, #RING_SIZE
    blo.w   31b
    b.w     2f
4:  bl      silica_rt_now_ms
    str     r0, [r4, #ACB_LAST_MSG]
    b.w     8f
2:  mov     r0, r4
    mov     r1, r5
    mov     r2, r6
    bl      rt_trim_both
8:  ldr     r0, [r4, #ACB_PEAK]             // the next dispatch counts from its first chunks
    bic     r0, r0, #0xFF
    bic     r0, r0, #0xFF00
    str     r0, [r4, #ACB_PEAK]
9:  pop     {r4-r8, pc}
    .size   silica_rt_actor_release_policy, . - silica_rt_actor_release_policy

// silica_rt_actor_idle_scan(): at most once a quarter second (a pass of the scheduler loop, idle or
// between dispatches), every :release_when_idle actor parked at a boundary (ST_IDLE, no context) that has
// had no message for a second gives its chunks back. AAPCS.
    FUNC silica_rt_actor_idle_scan
    push    {r4-r6, lr}
    bl      silica_rt_now_ms
    mov     r6, r0                          // r6 = now (ms, low word)
    MOV32   r1, silica_rt_idle_scan_at
    ldr     r2, [r1]
    sub     r2, r6, r2
    cmp     r2, #IDLE_SCAN_MS
    blo.w   9f
    str     r6, [r1]
    MOV32   r4, silica_rt_acb_all
    ldr     r4, [r4]
1:  cmp     r4, #0
    beq.w   9f
    ldrb    r0, [r4, #ACB_KIND]
    cmp     r0, #KIND_ACTOR
    bne.w   2f
    ldrb    r0, [r4, #ACB_STATUS]
    cmp     r0, #ST_IDLE
    bne.w   2f
    ldr     r0, [r4, #ACB_CTX_A0]
    cmp     r0, #0
    bne.w   2f
    ldr     r0, [r4, #ACB_POLICY]
    and     r0, r0, #15
    cmp     r0, #ALG_RELEASE_WHEN_IDLE
    bne.w   2f
    ldr     r0, [r4, #ACB_MCHAIN]
    ldr     r1, [r4, #ACB_ACHAIN]
    orrs    r0, r0, r1
    beq.w   2f
    ldr     r0, [r4, #ACB_LAST_MSG]
    sub     r0, r6, r0
    movw    r1, #IDLE_RELEASE_MS
    cmp     r0, r1
    blo.w   2f
    mov     r0, r4
    movw    r1, #0
    movw    r2, #0
    bl      rt_trim_both
2:  ldr     r4, [r4, #ACB_ALL_NEXT]
    b.w     1b
9:  pop     {r4-r6, pc}
    .size   silica_rt_actor_idle_scan, . - silica_rt_actor_idle_scan

// ---------------------------------------------------------------------------------------------
// Growable stacks.

// silica_rt_chunk_take(r0 = size, r1 = kind: 0 machine, 1 auxiliary) -> r0 = chunk or 0. A chunk is one
// heap block, from the SRAM2 arena when it has room, else from the SRAM1 heap (rt_heap.S); a chain may
// mix the two regions (no routine assumes an address order between two chunks).
    FUNC silica_rt_chunk_take
    push    {r4, r5, lr}
    mov     r5, r1
    add     r4, r0, #15
    bic     r4, r4, #15
    mov     r0, r4
    bl      silica_rt_alloc_chunk_or_null   // rt_heap.S: the SRAM2 arena first, then SRAM1
    cmp     r0, #0
    beq.w   9f
    str     r4, [r0, #CH_SIZE]
    add     r1, r0, r4
    str     r1, [r0, #CH_TOP]
    add     r1, r0, #64
    str     r1, [r0, #CH_BAND]
    add     r1, r0, #CH_USABLE_OFF
    cmp     r5, #0
    bne.w   1f
    MOV32   r2, _silica_rt_depth_reserve
    add     r1, r1, r2
1:  str     r1, [r0, #CH_LIMIT]
    movw    r1, #1
    str     r1, [r0, #CH_INDEX]
9:  pop     {r4, r5, pc}
    .size   silica_rt_chunk_take, . - silica_rt_chunk_take

// silica_rt_chunks_free_from(r0 = chunk): the chain from this chunk upward goes back.
    FUNC silica_rt_chunks_free_from
    push    {r4, lr}
    mov     r4, r0
1:  cmp     r4, #0
    beq.w   9f
    ldr     r0, [r4, #CH_NEXT]
    push    {r0}
    mov     r0, r4
    bl      silica_rt_free
    pop     {r4}
    b.w     1b
9:  pop     {r4, pc}
    .size   silica_rt_chunks_free_from, . - silica_rt_chunks_free_from

// silica_rt_chunk_next(r0 = acb, r1 = cur, r2 = need, r3 = kind) -> r0 = the chunk above cur that can
// hold `need` bytes above its limit: the retained successor when it serves, else a fresh one (twice
// the current up to the cap, or the need plus headroom when that is larger), linked after cur; 0 when
// the heap is exhausted. (A lowered reservation, stack_policy(n, ...), is not enforced yet.)
    FUNC silica_rt_chunk_next
    push    {r4-r7, lr}
    mov     r4, r1                          // cur
    mov     r5, r2                          // need
    mov     r6, r3                          // kind
    ldr     r0, [r4, #CH_NEXT]
    cmp     r0, #0
    beq.w   2f
    ldr     r1, [r0, #CH_SIZE]
    ldr     r2, [r0, #CH_LIMIT]
    sub     r2, r2, r0                      // the limit's offset in the block
    sub     r1, r1, r2                      // usable above the limit
    cmp     r1, r5
    bhs.w   9f                              // the retained successor serves
    bl      silica_rt_chunks_free_from      // too small: the retained chain above cur goes back
    movw    r0, #0
    str     r0, [r4, #CH_NEXT]
2:  ldr     r0, [r4, #CH_SIZE]
    lsl     r0, r0, #1
    cmp     r6, #0
    bne.w   21f
    movw    r1, #MCHUNK_CAP
    b.w     22f
21: movw    r1, #ACHUNK_CAP
22: cmp     r0, r1
    it      hi
    movhi   r0, r1
    add     r1, r5, #CH_USABLE_OFF
    cmp     r6, #0
    bne.w   3f
    MOV32   r2, _silica_rt_depth_reserve
    add     r1, r1, r2
    add     r1, r1, #MCHUNK_HEADROOM
    b.w     4f
3:  add     r1, r1, #ACHUNK_HEADROOM
4:  cmp     r0, r1
    it      lo
    movlo   r0, r1
    mov     r7, r1                          // r7 = the smallest chunk that serves
    mov     r1, r6
    bl      silica_rt_chunk_take
    cmp     r0, #0
    bne.w   5f
    // no block of the preferred size in either arena: the smallest that holds the need (with its
    // headroom), so the remnants of the two arenas still serve a deep stack
    mov     r0, r7
    mov     r1, r6
    bl      silica_rt_chunk_take
    cmp     r0, #0
    beq.w   9f
5:
    str     r0, [r4, #CH_NEXT]
    str     r4, [r0, #CH_PREV]
    ldr     r1, [r4, #CH_INDEX]
    add     r1, r1, #1
    str     r1, [r0, #CH_INDEX]
9:  pop     {r4-r7, pc}
    .size   silica_rt_chunk_next, . - silica_rt_chunk_next

// silica_rt_stack_grow: called by an emitted prologue (FRAME_ENTER, shared/arm_vr.silica) whose
// would-be sp is below VRG_MLIMIT, on the caller's chunk inside the runtime reserve: r10 = the frame
// bytes, r11 = the frame's real return address, sp = the caller's sp. Answers sp = the frame's base in
// the next chunk (its size under the chunk's top) and r11 = the address of silica_rt_chunk_return, the
// return address the frame keeps; the real one and the caller's sp stay in the chunk header. Every
// other register is kept. Does not return in main (the fatal overflow) or when the heap is exhausted.
    FUNC silica_rt_stack_grow
    ENTRY_SAVE
    add     r4, sp, #44                     // the caller's sp (11 words pushed)
    bl      silica_rt_current
    mov     r5, r0                          // r5 = the running context
    ldrb    r0, [r5, #ACB_KIND]
    cmp     r0, #0
    bne.w   8f
    mov     r0, r5
    ldr     r1, [r9, #VRG_MCHUNK]
    mov     r2, r10
    movw    r3, #0
    bl      silica_rt_chunk_next
    cmp     r0, #0
    beq.w   7f
    str     r11, [r0, #CH_RET]
    str     r4, [r0, #CH_SAVED_SP]
    str     r0, [r9, #VRG_MCHUNK]
    str     r0, [r5, #ACB_MCUR]
    ldr     r1, [r0, #CH_LIMIT]
    str     r1, [r9, #VRG_MLIMIT]
    ldr     r1, [r0, #CH_INDEX]
    ldr     r2, [r5, #ACB_PEAK]
    uxtb    r3, r2
    cmp     r3, r1
    bhs.w   11f
    bic     r2, r2, #0xFF
    orr     r2, r2, r1
    str     r2, [r5, #ACB_PEAK]
11: ldr     r0, [r5, #ACB_MCHAIN]           // the actor's high water (get_actor_memory_usage)
    bl      rt_chain_bytes
    ldr     r1, [r5, #ACB_HW_M]
    cmp     r1, r0
    it      lo
    strlo   r0, [r5, #ACB_HW_M]
    pop     {r0-r8, r12, lr}                // the caller's registers back, on the old chunk
    ldr     r11, [r9, #VRG_MCHUNK]
    ldr     r11, [r11, #CH_TOP]
    sub     r11, r11, r10
    mov     sp, r11
    MOV32   r11, silica_rt_chunk_return
    orr     r11, r11, #1
    bx      lr
7:  bl      silica_rt_region_alloc_failed
8:  mov     r0, r11                         // main: the fatal overflow, at the frame's return address
    bl      silica_rt_fatal_overflow
9:  b.w     9b
    .size   silica_rt_stack_grow, . - silica_rt_stack_grow

// silica_rt_chunk_return: where a frame that entered a machine chunk returns to, with sp at the
// chunk's top and the result in r0:r1 (r2-r8 are the returned callee's and free). Makes the chunk
// below current again, restores the caller's sp and jumps to the real return address.
    FUNC silica_rt_chunk_return
    ldr     r10, [r9, #VRG_MCHUNK]          // the chunk being left
    ldr     r11, [r10, #CH_PREV]
    str     r11, [r9, #VRG_MCHUNK]
    ldr     r12, [r11, #CH_LIMIT]
    str     r12, [r9, #VRG_MLIMIT]
    MOV32   r12, silica_rt_cores
    ldr     r12, [r12, #CORE_CURRENT]
    str     r11, [r12, #ACB_MCUR]
    ldr     r12, [r10, #CH_SAVED_SP]
    mov     sp, r12
    ldr     r11, [r10, #CH_RET]
    bx      r11
    .size   silica_rt_chunk_return, . - silica_rt_chunk_return

// silica_rt_aux_grow(): called by an emitted reservation whose new SP, already stored in VRG_VSP, is
// below VRG_ALIMIT; the reservation's size is in VRG_ARG. On return VRG_VSP is the reservation at the
// top of the next auxiliary chunk. Every register but r10, r11, lr is kept. The live bytes just above
// the old SP (at most AUX_MIRROR_MAX, plus what keeps the new SP's phase mod 16) are mirrored at the
// new chunk's top, so SP-relative reads of operands pushed before the reservation keep working; the
// chunk remembers the SP before the reservation (CH_RET) and the mirror's size (CH_MIRROR).
    FUNC silica_rt_aux_grow
    ENTRY_SAVE
    bl      silica_rt_current
    mov     r5, r0
    ldrb    r0, [r5, #ACB_KIND]
    cmp     r0, #0
    bne.w   8f
    ldr     r6, [r9, #VRG_ACHUNK]           // r6 = the current auxiliary chunk
    ldr     r7, [r9, #VRG_ARG]              // r7 = the reservation
    ldr     r4, [r9, #VRG_VSP]
    add     r4, r4, r7                      // r4 = kept: the SP before the reservation
    ldr     r0, [r6, #CH_TOP]
    sub     r8, r0, r4                      // live bytes above kept in this chunk
    movw    r0, #(AUX_MIRROR_MAX + 15)
    cmp     r8, r0
    bls.w   1f
    rsb     r0, r4, #0
    and     r0, r0, #15
    movw    r8, #AUX_MIRROR_MAX
    add     r8, r8, r0                      // r8 = the mirror's size
1:  mov     r0, r5
    mov     r1, r6
    add     r2, r7, r8                      // the new chunk holds the mirror and the reservation
    movw    r3, #1
    bl      silica_rt_chunk_next
    cmp     r0, #0
    beq.w   7f
    mov     r6, r0                          // r6 = the chunk SP moves to
    str     r4, [r6, #CH_RET]
    str     r8, [r6, #CH_MIRROR]
    str     r6, [r9, #VRG_ACHUNK]
    str     r6, [r5, #ACB_ACUR]
    ldr     r0, [r6, #CH_LIMIT]
    str     r0, [r9, #VRG_ALIMIT]
    ldr     r0, [r6, #CH_TOP]
    sub     r0, r0, r8                      // the mirror's base: a release reaching it pops the chunk
    str     r0, [r9, #VRG_ATOP]
    // copy [kept, kept + mirror) to [base, top)
    mov     r1, r4
    add     r2, r4, r8
    mov     r3, r0
2:  cmp     r1, r2
    bhs.w   3f
    ldr     r12, [r1], #4
    str     r12, [r3], #4
    b.w     2b
3:  sub     r0, r0, r7
    str     r0, [r9, #VRG_VSP]
    ldr     r1, [r6, #CH_INDEX]
    ldr     r2, [r5, #ACB_PEAK]
    ubfx    r3, r2, #8, #8
    cmp     r3, r1
    bhs.w   4f
    bic     r2, r2, #0xFF00
    orr     r2, r2, r1, lsl #8
    str     r2, [r5, #ACB_PEAK]
4:  ldr     r0, [r5, #ACB_ACHAIN]           // the actor's high water (get_actor_memory_usage)
    bl      rt_chain_bytes
    ldr     r1, [r5, #ACB_HW_A]
    cmp     r1, r0
    it      lo
    strlo   r0, [r5, #ACB_HW_A]
    ENTRY_RET
7:  bl      silica_rt_region_alloc_failed
8:  mov     r0, lr                          // main: the fatal overflow, at the reservation
    bl      silica_rt_fatal_overflow
9:  b.w     9b
    .size   silica_rt_aux_grow, . - silica_rt_aux_grow

// silica_rt_aux_release(): called by an emitted release or restore whose new SP, already stored in
// VRG_VSP, is at or above VRG_ATOP or below VRG_ALIMIT: pops auxiliary chunks until the SP is inside
// the current one. A release that lands exactly on a chunk's top continues at the SP kept when the
// chunk was entered; a restore to an older chunk's address keeps its value. Leaf.
    FUNC silica_rt_aux_release
    push    {r4-r7}
    ldr     r4, [r9, #VRG_ACHUNK]           // r4 = chunk
    ldr     r5, [r9, #VRG_VSP]              // r5 = the target
1:  ldr     r6, [r4, #CH_PREV]
    cmp     r6, #0
    beq.w   5f                              // the first chunk: the target is wherever it is
    ldr     r7, [r4, #CH_TOP]
    cmp     r7, r5
    blo.w   3f                              // above the top: an older chunk's address
    ldr     r10, [r4, #CH_MIRROR]
    sub     r10, r7, r10                    // the mirror's base
    cmp     r5, r10
    blo.w   2f
    sub     r5, r5, r10                     // emptied into the mirror: continue at the same offset
    ldr     r7, [r4, #CH_RET]               // above where the entering reservation began
    add     r5, r5, r7
    mov     r4, r6
    b.w     1b
2:  ldr     r7, [r4, #CH_LIMIT]
    cmp     r5, r7
    bhs.w   5f                              // inside this chunk
3:  mov     r4, r6
    b.w     1b
5:  str     r4, [r9, #VRG_ACHUNK]
    str     r5, [r9, #VRG_VSP]
    MOV32   r10, silica_rt_cores
    ldr     r10, [r10, #CORE_CURRENT]
    str     r4, [r10, #ACB_ACUR]
    ldr     r7, [r4, #CH_LIMIT]
    str     r7, [r9, #VRG_ALIMIT]
    ldr     r7, [r4, #CH_TOP]
    ldr     r10, [r4, #CH_MIRROR]
    sub     r7, r7, r10
    ldr     r6, [r4, #CH_PREV]
    cmp     r6, #0
    bne.w   6f
    movw    r7, #0xFFFF
    movt    r7, #0xFFFF
6:  str     r7, [r9, #VRG_ATOP]
    pop     {r4-r7}
    bx      lr
    .size   silica_rt_aux_release, . - silica_rt_aux_release

// silica_rt_actor_stacks_prepare(r0 = acb): the scheduler's step before a dispatch of an actor with no
// context: first chunks for each chain it holds none of (its first dispatch, or its release algorithm
// gave everything back), the stack empty at the top of the first chunk of each, and the landing at the
// top of the first machine chunk. The dispatch's peak (ACB_PEAK bytes 0-1) starts at the first chunks.
    LFUNC silica_rt_actor_stacks_prepare
    push    {r4, r5, lr}
    mov     r4, r0
    ldr     r0, [r4, #ACB_MCHAIN]
    cmp     r0, #0
    bne.w   1f
    movw    r0, #MCHUNK_FIRST
    movw    r1, #0
    bl      silica_rt_chunk_take
    cmp     r0, #0
    beq.w   8f
    str     r0, [r4, #ACB_MCHAIN]
    ldr     r1, [r0, #CH_SIZE]
    ldr     r2, [r4, #ACB_HW_M]
    cmp     r2, r1
    it      lo
    strlo   r1, [r4, #ACB_HW_M]
1:  ldr     r0, [r4, #ACB_MCHAIN]
    str     r0, [r4, #ACB_MCUR]
    ldr     r0, [r4, #ACB_ACHAIN]
    cmp     r0, #0
    bne.w   2f
    movw    r0, #ACHUNK_FIRST
    movw    r1, #1
    bl      silica_rt_chunk_take
    cmp     r0, #0
    beq.w   8f
    str     r0, [r4, #ACB_ACHAIN]
    ldr     r1, [r0, #CH_SIZE]
    ldr     r2, [r4, #ACB_HW_A]
    cmp     r2, r1
    it      lo
    strlo   r1, [r4, #ACB_HW_A]
2:  ldr     r1, [r4, #ACB_PEAK]
    bic     r1, r1, #0xFF
    bic     r1, r1, #0xFF00
    orr     r1, r1, #0x0100
    orr     r1, r1, #0x0001
    str     r1, [r4, #ACB_PEAK]
    ldr     r0, [r4, #ACB_ACHAIN]
    str     r0, [r4, #ACB_ACUR]
    ldr     r1, [r0, #CH_TOP]
    str     r1, [r4, #ACB_CTX_VSP]
    str     r1, [r4, #ACB_CTX_FLOOR]
    mov     r0, r4
    MOV32   r1, silica_rt_actor_landing
    ldr     r2, [r4, #ACB_MCUR]
    ldr     r2, [r2, #CH_TOP]
    bl      silica_rt_ctx_prepare
    pop     {r4, r5, pc}
8:  bl      silica_rt_abort_heap_exhausted
    .size   silica_rt_actor_stacks_prepare, . - silica_rt_actor_stacks_prepare

// ---------------------------------------------------------------------------------------------
// The actor loop: one dispatch per entry (entered afresh by the scheduler at every dispatch).
    FUNC silica_rt_actor_landing
    bl      silica_rt_current
    bl      silica_rt_actor_main
1:  b.w     1b
    .size   silica_rt_actor_landing, . - silica_rt_actor_landing

    FUNC silica_rt_actor_main
    push    {r4-r7, lr}
    sub     sp, sp, #28                     // [sp] the reply slot: the behaviour writes its result tuple
                                            // there (3 words, 24 bytes), [sp+24] pad
    mov     r4, r0                          // r4 = acb
    // First dispatch of a supervisor: its start trampoline runs once (its init on this stack), then
    // whoever waited in spawn for it is woken (the reference spawn returns only after the trampoline ran).
    ldr     r5, [r4, #ACB_SB]
    cmp     r5, #0
    beq.w   1f
    ldr     r6, [r5, #SB_TRAMP]
    cmp     r6, #0
    beq.w   1f
    ldr     r0, [r5, #SB_TRAMP_RAN]
    tst     r0, #TR_RAN
    bne.w   1f
    mov     r0, r4                          // X0 = the ACB
    movw    r1, #0
    movw    r2, #0
    movw    r3, #0
    orr     r6, r6, #1
    blx     r6
    bl      silica_rt_current               // the trampoline (emitted code) clobbered r4-r8
    mov     r4, r0
    ldr     r5, [r4, #ACB_SB]
    ldr     r0, [r5, #SB_TRAMP_RAN]
    orr     r0, r0, #TR_RAN
    str     r0, [r5, #SB_TRAMP_RAN]
    ldr     r0, [r5, #SB_SPAWN_WAITER]
    cmp     r0, #0
    beq.w   1f
    movw    r1, #0
    str     r1, [r5, #SB_SPAWN_WAITER]
    bl      silica_rt_wake
1:  // one message: supervision ingress (a supervisor's block) before the standard mailbox
    ldr     r5, [r4, #ACB_SB]
    cmp     r5, #0
    beq.w   2f
    ldr     r6, [r5, #SB_IN_HEAD]
    cmp     r6, #0
    beq.w   2f
    ldr     r0, [r6, #MSG_NEXT]
    str     r0, [r5, #SB_IN_HEAD]
    cmp     r0, #0
    it      eq
    streq   r0, [r5, #SB_IN_TAIL]
    ldr     r0, [r5, #SB_IN_DEPTH]
    sub     r0, r0, #1
    str     r0, [r5, #SB_IN_DEPTH]
    b.w     3f
2:  ldr     r6, [r4, #ACB_MB_HEAD]
    cmp     r6, #0
    beq.w   6f                              // nothing to serve (a supervisor's first dispatch runs only its trampoline)
    ldr     r0, [r6, #MSG_NEXT]
    str     r0, [r4, #ACB_MB_HEAD]
    cmp     r0, #0
    it      eq
    streq   r0, [r4, #ACB_MB_TAIL]
3:  // r6 = the node. A structured exit notice (an ended child's, rt_failure.S silica_rt_deliver_exit)
    // runs the supervisor's restart logic and its exit report (rt_supervisors.S), never the behaviour;
    // then its payload goes back. A trial hook's notice (MSG_INGRESS_KIND 1) carries an inline value and
    // runs the behaviour.
    ldr     r0, [r6, #MSG_KIND]
    cmp     r0, #2
    bne.w   31f
    ldr     r0, [r6, #MSG_INGRESS_KIND]
    cmp     r0, #0
    bne.w   31f
    ldr     r1, [r6, #MSG_PAYLOAD]
    cmp     r1, #0
    beq.w   5f
    mov     r0, r4
    bl      silica_rt_supervisor_handle_notice
    ldr     r0, [r6, #MSG_PAYLOAD]
    bl      silica_rt_exit_payload_free
    movw    r0, #0
    str     r0, [r6, #MSG_PAYLOAD]
    b.w     5f
31: ldr     r0, [r4, #ACB_BEH]
    cmp     r0, #0
    beq.w   5f                              // a supervisor with no behaviour of its own drops the message
    str     r6, [r4, #ACB_ACTIVE_CALL]
    // the FailureReporter's report (MSG_PAYLOAD_OWNED 2) is recorded as being handled (rt_failure.S)
    ldr     r0, [r6, #MSG_PAYLOAD_OWNED]
    cmp     r0, #2
    bne.w   32f
    ldr     r0, [r6, #MSG_PAYLOAD]
    bl      silica_rt_report_begin
32: mov     r0, r4
    mov     r1, r6
    mov     r2, sp
    bl      silica_rt_run_behaviour
    // handle_report is done with a report: the owner record is cleared (its block, the mailbox buffer,
    // goes back below whatever report_end answers: a report sent on was copied by the copier)
    ldr     r0, [r6, #MSG_PAYLOAD_OWNED]
    cmp     r0, #2
    bne.w   33f
    ldr     r0, [r6, #MSG_PAYLOAD]
    bl      silica_rt_report_end
33:
    // the mailbox buffer (chunk 15 phase 4a) goes back now that the dispatch end has placed the new
    // state's nodes, unless the behaviour's epilogue marked it retained (ACB_SRETAIN: an undescribed word
    // of the state may point into it; it is then kept for the actor's life). As on the ESP32-S3 the
    // dispatch end has cleared the mark already, so the buffer always goes back here.
    movw    r1, #0
    str     r1, [r6, #MSG_PAYLOAD_OWNED]
    ldr     r2, [r4, #ACB_SRETAIN]
    str     r1, [r4, #ACB_SRETAIN]
    ldr     r0, [r6, #MSG_BUF_BLOCK]
    str     r1, [r6, #MSG_BUF_BLOCK]
    str     r1, [r6, #MSG_BUF_BYTES]
    cmp     r2, #0
    bne.w   4f
    cmp     r0, #0
    beq.w   4f
    bl      silica_rt_free
4:  movw    r0, #0
    str     r0, [r4, #ACB_ACTIVE_CALL]
    ldr     r0, [r6, #MSG_KIND]
    cmp     r0, #1
    bne.w   51f
    // a call: the reply is in the node; wake the caller, which frees the node. A caller that ended
    // while it waited (its WAIT_NODE's caller cleared) leaves the node to us.
    movw    r0, #1
    str     r0, [r6, #MSG_REPLY_SET]
    ldr     r0, [r6, #MSG_CALLER]
    cmp     r0, #0
    beq.w   51f
    bl      silica_rt_wake
    b.w     6f
5:  mov     r0, r6                          // dropped undispatched: its message copy goes back too
    bl      rt_node_release_payload
51: mov     r0, r6
    bl      silica_rt_free_node
6:  // dispatch boundary: the stack is empty from here on; the scheduler parks or re-queues the actor
    movw    r0, #ST_BOUNDARY
    strb    r0, [r4, #ACB_STATUS]
    bl      silica_rt_yield_to_sched
9:  b.w     9b
    .size   silica_rt_actor_main, . - silica_rt_actor_main

// silica_rt_run_behaviour(r0 = acb, r1 = node, r2 = reply slot): calls the behaviour with X0 = message,
// X1 = state, X2 = the reply slot, and copies the result out (a call: reply into the node, state into
// the ACB; a cast: state into the ACB). The layout follows the tuple's own tag (the image's :reply /
// :no_reply atoms, emitted as silica_rt_reply_tag / silica_rt_no_reply_tag, -1 when unused), not the
// message kind, as on the ESP32-S3.
    LFUNC silica_rt_run_behaviour
    push    {r4-r7, lr}
    mov     r4, r0
    mov     r5, r1
    mov     r6, r2
    // the convention word's proof bit (bit 2) is the dispatch's proof flag; the result slot is recorded
    ldr     r0, [r4, #ACB_CONV]
    ubfx    r0, r0, #2, #1
    str     r0, [r4, #ACB_SFLAGS]
    movw    r0, #0
    str     r0, [r4, #ACB_SFLAGS + 4]
    str     r6, [r4, #ACB_RSLOT]
    str     r0, [r4, #ACB_RSLOT + 4]
    str     r0, [r4, #ACB_SDESC]
    str     r0, [r4, #ACB_SDESC + 4]
    ldr     r0, [r5, #MSG_PAYLOAD]
    ldr     r1, [r5, #MSG_PAYLOAD + 4]
    ldr     r2, [r4, #ACB_STATE]
    ldr     r3, [r4, #ACB_STATE + 4]
    mov     r4, r6                          // X2 = the reply slot (r4 is reloaded after the call)
    movw    r5, #0
    MOV32   r6, silica_rt_cores
    ldr     r6, [r6, #CORE_CURRENT]
    ldr     r6, [r6, #ACB_BEH]
    orr     r6, r6, #1
    blx     r6                              // X0 back = the result tuple (its address)
    mov     r7, r0                          // r7 = the tuple (the behaviour clobbered r4-r8)
    bl      silica_rt_current
    mov     r4, r0                          // r4 = acb again
    ldr     r5, [r4, #ACB_ACTIVE_CALL]      // r5 = the node again
    // the tuple's tag decides the layout (the two tag words are emitted into every program's
    // __silica_runtime.sams; weak here so a hand-written image without them links: -1, unused)
    ldr     r1, [r7, #0]
    MOV32   r2, silica_rt_reply_tag
    cmp     r2, #0
    beq.w   21f
    ldr     r2, [r2]
    cmp     r1, r2
    beq.w   2f
21: MOV32   r2, silica_rt_no_reply_tag
    cmp     r2, #0
    beq.w   22f
    ldr     r2, [r2]
    cmp     r1, r2
    beq.w   3f
22:
    ldr     r1, [r5, #MSG_KIND]
    cmp     r1, #1
    bne.w   3f
2:  // (:reply, value, state): reply at +8 (a call only), state at +16
    ldr     r1, [r5, #MSG_KIND]
    cmp     r1, #1
    bne.w   4f
    ldr     r1, [r7, #8]
    ldr     r2, [r7, #12]
    str     r1, [r5, #MSG_REPLY]
    str     r2, [r5, #MSG_REPLY + 4]
4:  mov     r0, r4
    ldr     r1, [r7, #16]
    ldr     r2, [r7, #20]
    bl      silica_rt_state_dispatch_end
    str     r0, [r4, #ACB_STATE]
    str     r1, [r4, #ACB_STATE + 4]
    pop     {r4-r7, pc}
3:  // (:no_reply, state): state at +8; a cast-style result to a call answers 0
    ldr     r1, [r5, #MSG_KIND]
    cmp     r1, #1
    bne.w   5f
    movw    r1, #0
    str     r1, [r5, #MSG_REPLY]
    str     r1, [r5, #MSG_REPLY + 4]
5:  mov     r0, r4
    ldr     r1, [r7, #8]
    ldr     r2, [r7, #12]
    bl      silica_rt_state_dispatch_end
    str     r0, [r4, #ACB_STATE]
    str     r1, [r4, #ACB_STATE + 4]
    pop     {r4-r7, pc}
    .size   silica_rt_run_behaviour, . - silica_rt_run_behaviour

// ---------------------------------------------------------------------------------------------
// Spawn.

// silica_rt_spawn_common(r0 = extra block, EXTRA_* fields) -> r0 = the ACB, r2:r3 = its identity (read
// before the spawner lets go of a supervisor that ended in its start: its ACB may be recycled then). A
// supervisor (a trampoline in the block) is scheduled at once and the spawner suspends until its
// trampoline ran, so the children exist when spawn returns (the reference behaviour).
    FUNC silica_rt_spawn_common
    push    {r4-r8, lr}
    mov     r4, r0                          // r4 = extra
    bl      silica_rt_actors_init
    bl      silica_rt_alloc_acb
    mov     r5, r0                          // r5 = acb
    ldr     r0, [r4, #EXTRA_INIT]
    str     r0, [r5, #ACB_STATE]
    ldr     r0, [r4, #EXTRA_INIT + 4]
    str     r0, [r5, #ACB_STATE + 4]
    ldr     r6, [r4, #EXTRA_BEH]
    str     r6, [r5, #ACB_BEH]
    // Spec §16.2.6.4: the calling convention, from the word the emitter writes before the entry of a
    // function declared to return (:reply, ...) (0x5C1AC0F1) or (:no_reply, ...) (0x5C1AC0F2): the low
    // nibble is kept (bit 2 is the state-release proof); anything else is 0 (not checked).
    movw    r0, #0
    bic     r1, r6, #1
    MOV32   r2, 0x20000000
    cmp     r1, r2
    blo.w   1f
    MOV32   r2, 0x20020000
    cmp     r1, r2
    bhs.w   1f
    ldr     r1, [r1, #-4]
    lsr     r2, r1, #4
    MOV32   r3, 0x5C1AC0F
    cmp     r2, r3
    bne.w   1f
    and     r0, r1, #0xF
    and     r2, r1, #0x3
    cmp     r2, #0
    beq.w   11f
    cmp     r2, #3
    bne.w   1f
11: movw    r0, #0
1:  str     r0, [r5, #ACB_CONV]
    ldr     r0, [r4, #EXTRA_POLICY]
    str     r0, [r5, #ACB_POLICY]
    ubfx    r1, r0, #4, #2
    lsl     r1, r1, #4
    str     r1, [r5, #ACB_SPOLICY]
    ldr     r0, [r4, #EXTRA_AGENT]
    strh    r0, [r5, #ACB_AGENT]
    ldr     r0, [r4, #EXTRA_ROW]
    str     r0, [r5, #ACB_ROW]
    ldr     r0, [r4, #EXTRA_SUP]
    str     r0, [r5, #ACB_SUP]
    // a described initial state is copied into the child's state chain (rt_state.S; scalar here)
    mov     r0, r5
    ldr     r1, [r4, #EXTRA_INIT]
    ldr     r2, [r4, #EXTRA_INIT + 4]
    ldr     r3, [r4, #EXTRA_DESC]
    bl      silica_rt_state_install
    // Identity (§15.1.4): numbered by its spawner -- the supervisor for a row child, else the running
    // actor (main when there is none) -- before it can run; the runtime's own actors by the record
    // silica_rt_spawn_rec_override names. A supervisor takes its own position now, in its spawner's
    // order (its record is its row's for a row child, which outlives the child's restarts).
    MOV32   r0, silica_rt_spawn_rec_override
    ldr     r0, [r0]
    cmp     r0, #0
    bne.w   13f
    ldr     r0, [r4, #EXTRA_SUP]
    cmp     r0, #0
    bne.w   12f
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #KIND_ACTOR
    it      ne
    movne   r0, #0
12: bl      silica_rt_spawner_rec
13: mov     r1, r0
    mov     r0, r5
    bl      silica_rt_ident_assign
    cmp     r0, #0
    beq.w   14f
    bl      silica_rt_identity_exhausted    // does not return
14: ldr     r0, [r4, #EXTRA_TRAMP]
    cmp     r0, #0
    beq.w   15f
    mov     r0, r5
    bl      silica_rt_spawner_rec
    bl      silica_rt_spawner_position
15: movw    r0, #1
    strb    r0, [r5, #ACB_ALIVE]
    strb    r0, [r5, #ACB_PRIO]
    movw    r0, #0
    strb    r0, [r5, #ACB_CORE]
    strb    r0, [r5, #ACB_STATUS]           // parked until a message, or scheduled below
    // a child spec passes no policy and inherits its supervisor's
    ldr     r0, [r5, #ACB_POLICY]
    cmp     r0, #0
    bne.w   2f
    ldr     r1, [r5, #ACB_SUP]
    cmp     r1, #0
    beq.w   2f
    ldr     r0, [r1, #ACB_POLICY]
    str     r0, [r5, #ACB_POLICY]
2:  // :track_recent_peak keeps a ring of the last RING_SIZE dispatches: a block of its own (zeroed)
    ldr     r0, [r5, #ACB_POLICY]
    and     r0, r0, #15
    cmp     r0, #ALG_TRACK_RECENT_PEAK
    bne.w   21f
    movw    r0, #RING_SIZE
    bl      silica_rt_alloc
    str     r0, [r5, #ACB_RING]
21: // a supervisor: its block holds the trampoline; schedule it and wait until the trampoline ran
    ldr     r6, [r4, #EXTRA_TRAMP]
    cmp     r6, #0
    beq.w   9f
    mov     r0, r5
    bl      silica_rt_sb_require
    mov     r7, r0
    str     r6, [r7, #SB_TRAMP]
    ldr     r0, [r4, #EXTRA_SUP]
    cmp     r0, #0
    beq.w   3f
    ldr     r0, [r0, #ACB_SB]
    cmp     r0, #0
    beq.w   3f
    ldr     r1, [r0, #SB_SINK]              // a child supervisor inherits its supervisor's report sink
    str     r1, [r7, #SB_SINK]
    ldr     r1, [r0, #SB_SINK + 4]
    str     r1, [r7, #SB_SINK + 4]
3:  bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #KIND_SCHED
    beq.w   4f
    mov     r6, r0                          // r6 = the spawner
    str     r6, [r7, #SB_SPAWN_WAITER]
    movw    r1, #TR_SPAWNER                 // the spawner holds the ACB until it has the reference
    str     r1, [r7, #SB_TRAMP_RAN]
    mov     r0, r5
    bl      silica_rt_make_ready
    // Woken. Only the end of the start (actor_main) or of the actor (rt_failure.S rt_spawn_waiter_wake)
    // clears the wait word; any other wake (an exit notice reaching this spawner's ingress, a cast to it)
    // must not end the wait: suspend again.
5:  movw    r1, #ST_SUSPENDED
    strb    r1, [r6, #ACB_STATUS]
    bl      silica_rt_yield_to_sched
    ldr     r0, [r7, #SB_SPAWN_WAITER]
    cmp     r0, #0
    bne.w   5b
    // A row child's spawner (rt_supervisors.S spawn_child_row) commits it to its row and lets go itself.
    // Any other spawner lets go here; an actor that ended inside its start trampoline is no actor to hand
    // out: the reference returned is silica_rt_dead_acb's, a block that is a dead actor for good (its own
    // ACB goes with its last holder).
    ldr     r0, [r4, #EXTRA_ROW]
    cmp     r0, #0
    bne.w   9f
    ldr     r6, [r7, #SB_TRAMP_RAN]
    ldr     r7, [r5, #ACB_ID]               // r7:r8 = the identity, kept past the let-go
    ldr     r8, [r5, #ACB_ID + 4]
    mov     r0, r5
    movw    r1, #TR_SPAWNER
    bl      silica_rt_tramp_release
    tst     r6, #TR_INIT_DEAD
    beq.w   91f
    MOV32   r5, silica_rt_dead_acb          // its identity, returned with it, is dead
    b.w     91f
4:  mov     r0, r5
    bl      silica_rt_make_ready
9:  ldr     r7, [r5, #ACB_ID]
    ldr     r8, [r5, #ACB_ID + 4]
91: mov     r0, r5
    mov     r2, r7
    mov     r3, r8
    pop     {r4-r8, pc}
    .size   silica_rt_spawn_common, . - silica_rt_spawn_common

// spawn(X0 init, X1 behaviour, W2 core, X3 trampoline, X4 policy, X6 state descriptor) -> X0 reference.
    FUNC silica_rt_actor_spawn
    ENTRY_SAVE
    sub     sp, sp, #EXTRA_SIZE
    ldr     r6, [r9, #0]                    // X3 trampoline
    str     r6, [sp, #EXTRA_TRAMP]
    ldr     r6, [r9, #8]                    // X4 policy
    str     r6, [sp, #EXTRA_POLICY]
    movw    r6, #0
    str     r6, [sp, #EXTRA_AGENT]
    str     r6, [sp, #EXTRA_ROW]
    str     r6, [sp, #EXTRA_SUP]
    ldr     r6, [r9, #24]                   // X6 the initial state's descriptor
    str     r6, [sp, #EXTRA_DESC]
    str     r0, [sp, #EXTRA_INIT]
    str     r1, [sp, #EXTRA_INIT + 4]
    str     r2, [sp, #EXTRA_BEH]
    str     r4, [sp, #EXTRA_CORE]
    mov     r0, sp
    bl      silica_rt_spawn_common
    add     sp, sp, #EXTRA_SIZE
    MOV32   r12, silica_rt_wait_root_acb
    ldr     r1, [r12]
    cmp     r1, #0
    it      eq
    streq   r0, [r12]
    mov     r0, r2                          // X0 = the identity
    mov     r1, r3
    ENTRY_RET_X0
    .size   silica_rt_actor_spawn, . - silica_rt_actor_spawn

// spawn_linked(X0 init, X1 behaviour, X2 agent atom, X3 row, X4 trampoline; X5 the supervisor, X7 the
// state descriptor in the register block) -> X0 reference. Children of a supervisor inherit its policy.
    FUNC silica_rt_actor_spawn_linked
    .thumb_func
    .global silica_rt_actor_spawn_dangerous_linked
silica_rt_actor_spawn_dangerous_linked:
    ENTRY_SAVE
    sub     sp, sp, #EXTRA_SIZE
    ldr     r6, [r9, #8]                    // X4 trampoline
    str     r6, [sp, #EXTRA_TRAMP]
    movw    r6, #0
    str     r6, [sp, #EXTRA_POLICY]
    str     r4, [sp, #EXTRA_AGENT]
    ldr     r6, [r9, #0]                    // X3 row
    str     r6, [sp, #EXTRA_ROW]
    ldr     r6, [r9, #16]                   // X5 the supervisor
    str     r6, [sp, #EXTRA_SUP]
    movw    r6, #0
    str     r6, [r9, #16]                   // consumed
    ldr     r6, [r9, #32]                   // X7 the descriptor
    str     r6, [sp, #EXTRA_DESC]
    movw    r6, #0
    str     r6, [r9, #32]
    str     r0, [sp, #EXTRA_INIT]
    str     r1, [sp, #EXTRA_INIT + 4]
    str     r2, [sp, #EXTRA_BEH]
    str     r6, [sp, #EXTRA_CORE]
    mov     r0, sp
    bl      silica_rt_spawn_common
    add     sp, sp, #EXTRA_SIZE
    mov     r0, r2                          // X0 = the identity
    mov     r1, r3
    ENTRY_RET_X0
    .size   silica_rt_actor_spawn_linked, . - silica_rt_actor_spawn_linked

// ---------------------------------------------------------------------------------------------
// Messages.

// ---------------------------------------------------------------------------------------------
// Actor identity (spec §15.1.4; the ESP32-S3's rt_actors.S "Actor identity").
//
// A reference is its actor's 64-bit identity, position << 32 | child number (X0 = r0:r1: the child
// number in r0, the position in r1), never an ACB address. An ACB holds its identity in ACB_ID from its
// spawn until it is recycled (silica_rt_free_acb writes all ones there, the identity no actor has, and a
// fresh ACB carries all ones until its spawn numbers it). Numbers are never reused, so a stale reference
// never reaches a recycled ACB's next occupant. Resolution (silica_rt_ref_acb) walks the chain of every
// ACB taken from the heap (silica_rt_acb_all, ACB_ALL_NEXT): one core, nothing preempts, at most about a
// thousand actors on this board, so there is no separate table to keep (the ESP32-S3 keeps a hash table
// under its scheduler lock). Spawner records (8 B: position + 1, 0 none yet; the next child number):
// main's and the runtime's (the registry actor, position 0xFFFFFFFE) are static, an actor's is
// ACB_SPOS/ACB_SNEXT, a row child's its row's ROW_SPOS (rt_supervisors.S), which outlives the child's
// restarts (§15.4.12.1).

// silica_rt_ref_acb(r0:r1 = reference) -> r0 = the ACB of the live actor with that identity, else 0 (no
// such actor, or it has ended). Clobbers r0, r1 only.
    FUNC silica_rt_ref_acb
    push    {r2, r3}
    MOV32   r2, silica_rt_acb_all
    ldr     r2, [r2]
1:  cmp     r2, #0
    beq.w   9f
    ldr     r3, [r2, #ACB_ID]
    cmp     r3, r0
    bne.w   2f
    ldr     r3, [r2, #ACB_ID + 4]
    cmp     r3, r1
    beq.w   3f
2:  ldr     r2, [r2, #ACB_ALL_NEXT]
    b.w     1b
3:  ldrb    r3, [r2, #ACB_ALIVE]
    cmp     r3, #0
    beq.w   9f
    mov     r0, r2
    pop     {r2, r3}
    bx      lr
9:  movw    r0, #0
    pop     {r2, r3}
    bx      lr
    .size   silica_rt_ref_acb, . - silica_rt_ref_acb

// silica_rt_acb_ident(r0 = acb or 0) -> r0:r1 = its identity (all ones for 0: the identity no actor has).
// Clobbers r0, r1 only.
    FUNC silica_rt_acb_ident
    cmp     r0, #0
    beq.w   1f
    ldr     r1, [r0, #ACB_ID + 4]
    ldr     r0, [r0, #ACB_ID]
    bx      lr
1:  mvn     r0, #0
    mvn     r1, #0
    bx      lr
    .size   silica_rt_acb_ident, . - silica_rt_acb_ident

// silica_rt_spawner_rec(r0 = acb or 0) -> r0 = the spawner record of that actor (main's for 0). Clobbers
// r0, r1.
    FUNC silica_rt_spawner_rec
    cmp     r0, #0
    beq.w   3f
    ldr     r1, [r0, #ACB_SUP]
    cmp     r1, #0
    beq.w   2f
    ldr     r1, [r0, #ACB_ROW]
    cmp     r1, #0
    beq.w   2f
    add     r0, r1, #ROW_SPOS
    bx      lr
2:  add     r0, r0, #ACB_SPOS
    bx      lr
3:  MOV32   r0, silica_rt_main_spawner
    bx      lr
    .size   silica_rt_spawner_rec, . - silica_rt_spawner_rec

// silica_rt_spawner_position(r0 = rec) -> r0 = position + 1, given now from the global counter when the
// record has none; 0 when positions are exhausted. Clobbers r0-r3.
    FUNC silica_rt_spawner_position
    ldr     r1, [r0]
    cmp     r1, #0
    bne.w   2f
    MOV32   r2, silica_rt_next_position
    ldr     r1, [r2]
    mvn     r3, #1                          // 0xFFFFFFFE: the runtime's position, never handed out
    cmp     r1, r3
    bhs.w   1f
    add     r3, r1, #1
    str     r3, [r2]
    add     r1, r1, #1
    str     r1, [r0]
2:  mov     r0, r1
    bx      lr
1:  movw    r0, #0
    bx      lr
    .size   silica_rt_spawner_position, . - silica_rt_spawner_position

// silica_rt_ident_assign(r0 = acb, r1 = rec) -> r0 = 0 (ACB_ID set), 1 the spawner's numbers are
// exhausted. AAPCS.
    FUNC silica_rt_ident_assign
    push    {r4, r5, r6, lr}
    mov     r4, r0
    mov     r5, r1
    mov     r0, r5
    bl      silica_rt_spawner_position
    cmp     r0, #0
    beq.w   8f
    sub     r6, r0, #1                      // r6 = position
    ldr     r1, [r5, #4]                    // r1 = the child number
    cmn     r1, #1
    beq.w   8f
    add     r2, r1, #1
    str     r2, [r5, #4]
    str     r1, [r4, #ACB_ID]
    str     r6, [r4, #ACB_ID + 4]
    movw    r0, #0
    pop     {r4, r5, r6, pc}
8:  movw    r0, #1
    pop     {r4, r5, r6, pc}
    .size   silica_rt_ident_assign, . - silica_rt_ident_assign

// silica_rt_identity_exhausted(): the spawner ran out of child numbers or positions (§15.1.4). The running
// actor fails with (:explicit, :identity_exhausted); in main the atom's name on the console, status 1.
// Never returns.
    FUNC silica_rt_identity_exhausted
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #KIND_ACTOR
    bne.w   1f
    MOV32   r0, silica_registry_atom_identity_exhausted
    ldr     r0, [r0]
    bl      silica_rt_actor_trap_explicit
1:  MOV32   r0, silica_rt_identity_exhausted_msg
    b.w     silica_rt_main_fail_exit
    .size   silica_rt_identity_exhausted, . - silica_rt_identity_exhausted

    .section .rodata.silica_rt_actors, "a", %progbits
silica_rt_identity_exhausted_msg:
    .asciz  "identity_exhausted\n"
    .section .text.silica_rt_actors, "ax", %progbits

// rt_cast(r0 = acb, r1 = payload lo, r2 = payload hi, r3 = bytes, r12 = block) -> r0 = 1. A cast to a
// call-only actor (its convention bits 1, §16.2.6.4) enqueues nothing: silica_rt_convention_mismatch.
    LFUNC rt_cast
    push    {r4-r7, lr}
    ldr     r4, [r0, #ACB_CONV]
    and     r4, r4, #3
    cmp     r4, #1
    beq.w   8f
    mov     r4, r0
    mov     r5, r1
    mov     r6, r2
    mov     r7, r3
    push    {r12}
    bl      silica_rt_alloc_node
    pop     {r12}
    str     r5, [r0, #MSG_PAYLOAD]
    str     r6, [r0, #MSG_PAYLOAD + 4]
    str     r7, [r0, #MSG_BUF_BYTES]
    str     r12, [r0, #MSG_BUF_BLOCK]
    cmp     r12, #0
    ite     eq
    moveq   r1, #0
    movne   r1, #1
    str     r1, [r0, #MSG_PAYLOAD_OWNED]
    // onto the mailbox; a parked actor becomes ready
    ldr     r1, [r4, #ACB_MB_TAIL]
    cmp     r1, #0
    beq.w   1f
    str     r0, [r1, #MSG_NEXT]
    str     r0, [r4, #ACB_MB_TAIL]
    b.w     2f
1:  str     r0, [r4, #ACB_MB_HEAD]
    str     r0, [r4, #ACB_MB_TAIL]
2:  mov     r0, r4
    bl      silica_rt_make_ready
    mov     r0, r4
    bl      rt_cast_backpressure
    movw    r0, #1
    pop     {r4-r7, pc}
8:  mov     r0, r12                         // nothing was enqueued: the message copy goes back
    bl      silica_rt_free
    bl      silica_rt_convention_mismatch   // does not return
    .size   rt_cast, . - rt_cast

// rt_cast_backpressure(r0 = the target): the ESP32-S3 port's silica_rt_cast_backpressure on one core.
// A sender whose target already has BP_DEPTH messages queued and will run (ready or at its boundary)
// gives the core away (it goes to the back of the ready queue) until the queue is shorter or it has
// waited BP_WAIT_MS, so a burst of casts does not fill the heap with message nodes and buffers before
// the receiver runs. The scheduler never waits; a cast to itself is drained only by its own return; a
// suspended or waiting target may be waiting on the sender. AAPCS.
#define BP_DEPTH         16
#define BP_WAIT_MS       200
    LFUNC rt_cast_backpressure
    push    {r4-r8, lr}
    mov     r4, r0                          // r4 = the target
    bl      silica_rt_current
    mov     r5, r0                          // r5 = the sender
    ldrb    r0, [r5, #ACB_KIND]
    cmp     r0, #KIND_SCHED
    beq.w   9f
    cmp     r4, r5
    beq.w   9f
    movw    r7, #0                          // r7 = 1 once the wait began, at r6 ms
1:  ldrb    r0, [r4, #ACB_ALIVE]
    cmp     r0, #0
    beq.w   9f
    ldrb    r0, [r4, #ACB_STATUS]
    cmp     r0, #ST_READY
    beq.w   2f
    cmp     r0, #ST_BOUNDARY
    bne.w   9f
2:  ldr     r1, [r4, #ACB_MB_HEAD]          // count the queue, up to BP_DEPTH
    movw    r2, #0
3:  cmp     r1, #0
    beq.w   4f
    add     r2, r2, #1
    cmp     r2, #BP_DEPTH
    bhs.w   4f
    ldr     r1, [r1, #MSG_NEXT]
    b.w     3b
4:  cmp     r2, #BP_DEPTH
    blo.w   9f                              // a short queue: carry on
    bl      silica_rt_now_ms
    cmp     r7, #0
    bne.w   5f
    mov     r6, r0
    movw    r7, #1
    b.w     6f
5:  sub     r1, r0, r6
    cmp     r1, #BP_WAIT_MS
    bhs.w   9f                              // waited long enough: carry on
6:  movw    r0, #ST_SUSPENDED               // to the back of the ready queue, then the core goes
    strb    r0, [r5, #ACB_STATUS]
    mov     r0, r5
    bl      silica_rt_make_ready
    bl      silica_rt_yield_to_sched
    b.w     1b
9:  pop     {r4-r8, pc}
    .size   rt_cast_backpressure, . - rt_cast_backpressure

// cast(X0 reference, X1 message, X2 bytes, X3 block) -> 1; send -> 0. An ended or unknown target
// raises actor_not_found (a runtime abort here).
    FUNC silica_rt_actor_cast
    ENTRY_SAVE
    bl      silica_rt_ref_acb
    cmp     r0, #0
    beq.w   8f
    mov     r1, r2
    mov     r2, r3
    mov     r3, r4
    ldr     r12, [r9, #0]
    bl      rt_cast
    movw    r1, #0
    ENTRY_RET_X0
8:  ldr     r0, [r9, #0]                    // no live target: the message copy goes back
    bl      silica_rt_free
    bl      silica_rt_actor_not_found       // does not return
    .size   silica_rt_actor_cast, . - silica_rt_actor_cast

    FUNC silica_rt_actor_send
    ENTRY_SAVE
    bl      silica_rt_ref_acb
    cmp     r0, #0
    beq.w   8f
    mov     r1, r2
    mov     r2, r3
    mov     r3, r4
    ldr     r12, [r9, #0]
    bl      rt_cast
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
8:  ldr     r0, [r9, #0]
    bl      silica_rt_free
    bl      silica_rt_actor_not_found
    .size   silica_rt_actor_send, . - silica_rt_actor_send

// call(X0 reference, X1 message, X2 the mailbox buffer's bytes, X3 its block (TP + 0; 0, 0: an inline
// message)) -> X0 the reply. The caller suspends (a scheduler yield point) until the target's behaviour
// returns its reply. A target that is dead or unknown, or that ends before replying, raises
// actor_not_found (§16.1.1); a call to a cast-only actor (convention bits 2) is a convention mismatch
// (§16.2.6.4). The node records the caller's SP, floor and auxiliary chunk as it parks (design §5.3):
// silica_rt_reply_place (rt_state.S) puts a composite reply under that SP, possibly in a chunk it
// appends, and writes the SP and chunk back; the caller resumes there and its call site adopts the reply.
    FUNC silica_rt_actor_call
    ENTRY_SAVE
    bl      silica_rt_ref_acb
    b.w     rt_call_common
    .size   silica_rt_actor_call, . - silica_rt_actor_call

// call_registered(X0 atom, X1 message, X2 bytes, X3 block) -> X0 the reply: the plain registry's holder.
    FUNC silica_rt_actor_call_registered
    ENTRY_SAVE
    mov     r1, r0
    REG_TABLE r0, silica_pid_registry_ref
    bl      rt_registry_lookup
    b.w     rt_call_common
    .size   silica_rt_actor_call_registered, . - silica_rt_actor_call_registered

// rt_call_common: the body of both, entered after ENTRY_SAVE (X1 at [sp + 8], X2 at [sp + 16]) with
// r0 = the target's ACB or 0. r4 = the block, r5 = the target, r6 = the node, r8 = the caller.
    LFUNC rt_call_common
    ldr     r4, [r9, #0]                    // X3 = the block (read before anything can switch away)
    mov     r5, r0
    cmp     r5, #0
    beq.w   7f
    ldr     r0, [r5, #ACB_CONV]
    and     r0, r0, #3
    cmp     r0, #2
    beq.w   6f
    bl      silica_rt_alloc_node
    mov     r6, r0
    movw    r1, #1
    str     r1, [r6, #MSG_KIND]
    ldr     r1, [sp, #8]
    str     r1, [r6, #MSG_PAYLOAD]
    ldr     r1, [sp, #12]
    str     r1, [r6, #MSG_PAYLOAD + 4]
    str     r4, [r6, #MSG_BUF_BLOCK]
    ldr     r1, [sp, #16]
    str     r1, [r6, #MSG_BUF_BYTES]
    cmp     r4, #0
    ite     eq
    moveq   r1, #0
    movne   r1, #1
    str     r1, [r6, #MSG_PAYLOAD_OWNED]
    bl      silica_rt_current
    mov     r8, r0
    str     r8, [r6, #MSG_CALLER]
    ldr     r1, [r9, #VRG_VSP]              // where the reply is placed from (the pre-call SP p)
    str     r1, [r6, #MSG_PARK_SP]
    ldr     r1, [r9, #VRG_FLOOR]
    str     r1, [r6, #MSG_PARK_FLOOR]
    ldr     r1, [r9, #VRG_ACHUNK]
    str     r1, [r6, #MSG_PARK_CHUNK]
    // onto the target's mailbox; it becomes ready
    ldr     r1, [r5, #ACB_MB_TAIL]
    cmp     r1, #0
    beq.w   1f
    str     r6, [r1, #MSG_NEXT]
    str     r6, [r5, #ACB_MB_TAIL]
    b.w     2f
1:  str     r6, [r5, #ACB_MB_HEAD]
    str     r6, [r5, #ACB_MB_TAIL]
2:  mov     r0, r5
    bl      silica_rt_make_ready
    str     r6, [r8, #ACB_WAIT_NODE]
3:  movw    r0, #ST_SUSPENDED
    strb    r0, [r8, #ACB_STATUS]
    bl      silica_rt_yield_to_sched
    ldr     r7, [r6, #MSG_REPLY_SET]
    cmp     r7, #0
    beq.w   3b                              // woken without a reply: suspend again
    movw    r0, #0
    str     r0, [r8, #ACB_WAIT_NODE]
    // the reply lies at the bottom of this frame's dynamic part: SP, the floor and, when the replier
    // appended one, the auxiliary chunk come from the node (the call site adopts [SP, p))
    ldr     r0, [r6, #MSG_PARK_SP]
    str     r0, [r9, #VRG_VSP]
    ldr     r0, [r6, #MSG_PARK_FLOOR]
    str     r0, [r9, #VRG_FLOOR]
    ldr     r0, [r6, #MSG_PARK_CHUNK]
    ldr     r1, [r9, #VRG_ACHUNK]
    cmp     r0, r1
    beq.w   4f
    str     r0, [r8, #ACB_ACUR]
    bl      silica_rt_aux_publish_chunk
4:  ldr     r0, [r6, #MSG_REPLY]
    ldr     r1, [r6, #MSG_REPLY + 4]
    str     r0, [sp, #0]
    str     r1, [sp, #4]
    mov     r0, r6
    bl      silica_rt_free_node
    cmp     r7, #2
    bne.w   5f
    movw    r4, #0                          // the target ended before replying: its exit path gave the
    b.w     7f                              // message copy back with the node (no second free here)
5:  ENTRY_RET
6:  mov     r0, r4                          // a cast-only target: nothing is enqueued, the copy goes back
    bl      silica_rt_free
    bl      silica_rt_convention_mismatch
7:  cmp     r4, #0                          // no live target (or it ended): actor_not_found
    beq.w   71f
    mov     r0, r4
    movw    r4, #0
    bl      silica_rt_free
71: bl      silica_rt_actor_not_found
    .size   rt_call_common, . - rt_call_common

// recv() -> X0 the next message node of the running actor (supervision ingress first), or 0 (also in
// main and the scheduler).
    FUNC silica_rt_actor_recv
    ENTRY_SAVE
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #KIND_ACTOR
    bne.w   8f
    ldr     r2, [r0, #ACB_SB]
    cmp     r2, #0
    beq.w   1f
    ldr     r3, [r2, #SB_IN_HEAD]
    cmp     r3, #0
    beq.w   1f
    ldr     r1, [r3, #MSG_NEXT]
    str     r1, [r2, #SB_IN_HEAD]
    cmp     r1, #0
    it      eq
    streq   r1, [r2, #SB_IN_TAIL]
    b.w     2f
1:  ldr     r3, [r0, #ACB_MB_HEAD]
    cmp     r3, #0
    beq.w   2f
    ldr     r1, [r3, #MSG_NEXT]
    str     r1, [r0, #ACB_MB_HEAD]
    cmp     r1, #0
    it      eq
    streq   r1, [r0, #ACB_MB_TAIL]
2:  mov     r0, r3
    movw    r1, #0
    ENTRY_RET_X0
8:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_actor_recv, . - silica_rt_actor_recv

// rt_registry_lookup(r0 = table, r1 = atom) -> r0 = the live ACB holding the name, or 0. Clobbers
// r12 only besides r0 (its callers still hold X1 in r2:r3).
    LFUNC rt_registry_lookup
    REG_BOUND r1, r12
    bhs.w   9f
    ldr     r0, [r0, r1, lsl #2]
    cmp     r0, #0
    beq.w   9f
    ldrb    r12, [r0, #ACB_ALIVE]
    cmp     r12, #0
    bne.w   8f
9:  movw    r0, #0
8:  bx      lr
    .size   rt_registry_lookup, . - rt_registry_lookup

.macro CAST_REGISTERED name, table
    FUNC \name
    ENTRY_SAVE
    mov     r1, r0
    REG_TABLE r0, \table
    bl      rt_registry_lookup
    cmp     r0, #0
    beq.w   8f
    mov     r1, r2
    mov     r2, r3
    mov     r3, r4
    ldr     r12, [r9, #0]
    bl      rt_cast
    movw    r1, #0
    ENTRY_RET_X0
8:  ldr     r0, [r9, #0]
    bl      silica_rt_free
    bl      silica_rt_actor_not_found
    .size   \name, . - \name
.endm
    CAST_REGISTERED silica_rt_actor_cast_registered, silica_pid_registry_ref
    CAST_REGISTERED silica_rt_actor_cast_dangerous_registered, silica_dangerous_pid_registry_ref
    CAST_REGISTERED silica_rt_actor_cast_device_registered, silica_device_pid_registry_ref

// register_actor_named(X0 reference, X1 atom) -> 0 stored, 1 the name is held by a live actor and
// nothing was stored (§20.3.1).
.macro REGISTER_NAMED name, table
    FUNC \name
    ENTRY_SAVE
    bl      silica_rt_ref_acb
    cmp     r0, #0
    beq.w   8f
    mov     r4, r0
    REG_TABLE r0, \table
    mov     r1, r2
    bl      rt_registry_lookup
    cmp     r0, #0
    bne.w   8f
    REG_BOUND r2, r1
    bhs.w   8f
    REG_TABLE r0, \table
    str     r4, [r0, r2, lsl #2]
    add     r1, r2, #1
    strh    r1, [r4, #ACB_REG_NAME]
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
8:  movw    r0, #1
    movw    r1, #0
    ENTRY_RET_X0
    .size   \name, . - \name
.endm
    REGISTER_NAMED silica_rt_register_actor_named, silica_pid_registry_ref
    REGISTER_NAMED silica_rt_register_dangerous_actor_named, silica_dangerous_pid_registry_ref
    REGISTER_NAMED silica_rt_register_device_actor_named, silica_device_pid_registry_ref

// registry_require_free(X0 atom): when a live actor holds the name no actor is spawned and the caller
// fails (silica_rt_registry_name_taken, which does not return).
.macro REQUIRE_FREE name, table
    FUNC \name
    ENTRY_SAVE
    mov     r1, r0
    REG_TABLE r0, \table
    bl      rt_registry_lookup
    cmp     r0, #0
    bne.w   8f
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
8:  bl      silica_rt_registry_name_taken
    .size   \name, . - \name
.endm
    REQUIRE_FREE silica_rt_registry_require_free, silica_pid_registry_ref
    REQUIRE_FREE silica_rt_registry_require_free_dangerous, silica_dangerous_pid_registry_ref
    REQUIRE_FREE silica_rt_registry_require_free_device, silica_device_pid_registry_ref

// silica_rt_registry_name_held(r0 = atom) -> r0 = the live holder in the plain registry or 0 (AAPCS).
    FUNC silica_rt_registry_name_held
    mov     r1, r0
    REG_TABLE r0, silica_pid_registry_ref
    b.w     rt_registry_lookup
    .size   silica_rt_registry_name_held, . - silica_rt_registry_name_held

// silica_rt_registry_enter(r0 = atom, r1 = acb): the plain registry takes the name (a supervisor's
// child by its id; AAPCS, rt_supervisors.S).
    FUNC silica_rt_registry_enter
    REG_BOUND r0, r3
    bhs.w   9f
    REG_TABLE r2, silica_pid_registry_ref
    str     r1, [r2, r0, lsl #2]
    add     r0, r0, #1
    strh    r0, [r1, #ACB_REG_NAME]
9:  bx      lr
    .size   silica_rt_registry_enter, . - silica_rt_registry_enter

// register(X0 reference) -> 0 (the unnamed registration of the reference runtime).
    FUNC silica_rt_register_actor
    ENTRY_SAVE
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_register_actor, . - silica_rt_register_actor

    FUNC silica_rt_actor_mark_device
    ENTRY_SAVE
    bl      silica_rt_ref_acb
    cmp     r0, #0
    beq.w   1f
    movw    r1, #1
    strb    r1, [r0, #ACB_DEVICE]
1:  ENTRY_RET
    .size   silica_rt_actor_mark_device, . - silica_rt_actor_mark_device

// The registry actors of the reference are tables here: the init entries only make sure the runtime is up.
    FUNC silica_pid_registry_init
    .thumb_func
    .global silica_dangerous_pid_registry_init
silica_dangerous_pid_registry_init:
    .thumb_func
    .global silica_device_pid_registry_init
silica_device_pid_registry_init:
    ENTRY_SAVE
    bl      silica_rt_actors_init
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_pid_registry_init, . - silica_pid_registry_init

// get_registry_actor() / get_pid_registry() -> X0 the plain registry's actor. The registries are
// tables here (silica_pid_registry_ref ...), so the actor the program talks to is made on the first
// request: a runtime actor whose state is the plain table and whose behaviour is
// silica_rt_pid_registry_beh, the reference's registry protocol over that table. It never ends and is
// not the program's root (spawn_common does not touch silica_rt_wait_root_acb).
    FUNC silica_rt_get_registry_actor
    ENTRY_SAVE
    bl      silica_rt_actors_init
    MOV32   r4, silica_rt_registry_acb
    ldr     r0, [r4]
    cmp     r0, #0
    bne.w   9f
    sub     sp, sp, #EXTRA_SIZE
    mov     r0, sp
    movw    r1, #EXTRA_SIZE
    bl      silica_rt_zero_block
    REG_TABLE r0, silica_pid_registry_ref
    str     r0, [sp, #EXTRA_INIT]
    MOV32   r0, silica_rt_pid_registry_beh  // a Thumb function symbol: bit 0 set by the linker
    str     r0, [sp, #EXTRA_BEH]
    MOV32   r0, silica_rt_runtime_spawner   // numbered by the runtime, not its caller (§15.1.4)
    MOV32   r1, silica_rt_spawn_rec_override
    str     r0, [r1]
    mov     r0, sp
    bl      silica_rt_spawn_common
    add     sp, sp, #EXTRA_SIZE
    MOV32   r1, silica_rt_spawn_rec_override
    movw    r2, #0
    str     r2, [r1]
    str     r0, [r4]                        // the registry never ends: its ACB is kept
9:  bl      silica_rt_acb_ident             // X0 = its identity
    ENTRY_RET_X0
    .size   silica_rt_get_registry_actor, . - silica_rt_get_registry_actor

// The registry behaviour, in the emitted-function ABI: X0 = message record {op, name, pid} (its shape
// word, then three 8-byte slots), X1 = state (the table's address), X2 = the reply tuple buffer; returns
// X0 = that buffer with [+8] = the pair (status atom, actor_ref) and [+16] = the state (no tag word: the
// runtime-internal layout, a call's reply at +8). The pair is built on this machine stack and placed into
// the blocked caller's stack by silica_rt_reply_place through its descriptor, as an emitted behaviour
// epilogue places a user reply; the caller's call site adopts it (a cast that reached the registry keeps
// the pair here, unread). r4 = the acb the pid names (0: none), r5 = name, r6 = table, r7 = status,
// r8 = the reply buffer.
    .section .rodata.silica_rt_actors, "a", %progbits
    .balign 16
silica_rt_pair_word2_desc_root:             // root-word form: one AGG entry (rt_state.S)
    .word   1, 0, -1, -1
    .word   4, 0, silica_rt_pair_word2_desc, 0
silica_rt_pair_word2_desc:                  // the aggregate: two word fields
    .word   2, 0, -1, -1
    .word   0, 0, 0, 0
    .word   0, 0, 0, 0
    .section .text.silica_rt_actors, "ax", %progbits

#define ATOM_INSERT      15
#define ATOM_LOOKUP      16
#define ATOM_DELETE      17
#define ATOM_FOUND       18
#define ATOM_NOT_FOUND   19
#define ATOM_UNKNOWN_OP  20

    FUNC silica_rt_pid_registry_beh
    push    {r4-r8, lr}
    sub     sp, sp, #16                     // [sp] the pair
    mov     r8, r4
    mov     r6, r2
    ldr     r3, [r0, #8]                    // op
    ldr     r5, [r0, #16]                   // name
    ldr     r1, [r0, #28]                   // pid: a reference (§15.1.4), resolved to the ACB the
    ldr     r0, [r0, #24]                   // table holds (0: no live actor)
    bl      silica_rt_ref_acb               // (clobbers r0, r1 only)
    mov     r4, r0
    cmp     r3, #ATOM_INSERT
    beq.w   1f
    cmp     r3, #ATOM_LOOKUP
    beq.w   2f
    cmp     r3, #ATOM_DELETE
    beq.w   3f
    movw    r7, #ATOM_UNKNOWN_OP
    mov     r1, r4
    b.w     8f
    // :insert (§20.3.1): :name_taken when a live actor holds the name (or the index is outside the
    // table); :actor_not_found when the actor has ended; :already_registered when the actor holds another
    // name; :ok when stored, or when the actor already holds this very name.
1:  REG_BOUND r5, r12
    bhs.w   12f
    cmp     r4, #0
    beq.w   13f
    ldr     r12, [r6, r5, lsl #2]
    cmp     r12, #0
    beq.w   14f
    cmp     r12, r4
    beq.w   11f
    ldrb    r0, [r12, #ACB_ALIVE]
    cmp     r0, #0
    bne.w   12f
14: ldrh    r0, [r4, #ACB_REG_NAME]
    cmp     r0, #0
    beq.w   15f
    add     r1, r5, #1
    cmp     r0, r1
    bne.w   16f
15: str     r4, [r6, r5, lsl #2]
    add     r0, r5, #1
    strh    r0, [r4, #ACB_REG_NAME]
11: movw    r7, #ATOM_OK
    mov     r1, r4
    b.w     8f
12: MOV32   r7, silica_registry_atom_name_taken
    ldr     r7, [r7]
    mov     r1, r4
    b.w     8f
13: MOV32   r7, silica_registry_atom_actor_not_found
    ldr     r7, [r7]
    movw    r1, #0
    b.w     8f
16: MOV32   r7, silica_registry_atom_already_registered
    ldr     r7, [r7]
    mov     r1, r4
    b.w     8f
    // :lookup: (:found, the holder) or (:not_found, none)
2:  REG_BOUND r5, r12
    bhs.w   21f
    ldr     r1, [r6, r5, lsl #2]
    cmp     r1, #0
    beq.w   21f
    movw    r7, #ATOM_FOUND
    b.w     8f
21: movw    r7, #ATOM_NOT_FOUND
    movw    r1, #0
    b.w     8f
    // :delete: the slot is emptied (the holder's own name mark with it) -> :ok
3:  REG_BOUND r5, r12
    bhs.w   31f
    ldr     r12, [r6, r5, lsl #2]
    cmp     r12, #0
    beq.w   31f
    ldrh    r0, [r12, #ACB_REG_NAME]
    add     r1, r5, #1
    cmp     r0, r1
    itt     eq
    moveq   r0, #0
    strheq  r0, [r12, #ACB_REG_NAME]
    movw    r0, #0
    str     r0, [r6, r5, lsl #2]
31: movw    r7, #ATOM_OK
    mov     r1, r4
8:  movw    r0, #0
    str     r7, [sp, #0]
    str     r0, [sp, #4]
    mov     r0, r1                          // the actor_ref answered: the ACB's identity (all ones: none)
    bl      silica_rt_acb_ident
    str     r0, [sp, #8]
    str     r1, [sp, #12]
    mov     r0, sp                          // X0 = the pair, X1 = its descriptor
    movw    r1, #0
    MOV32   r2, silica_rt_pair_word2_desc_root
    movw    r3, #0
    bl      silica_rt_reply_place
    movw    r1, #0
    str     r1, [r8, #0]
    str     r1, [r8, #4]
    str     r0, [r8, #8]
    str     r1, [r8, #12]
    str     r6, [r8, #16]
    str     r1, [r8, #20]
    mov     r0, r8
    add     sp, sp, #16
    pop     {r4-r8, pc}
    .size   silica_rt_pid_registry_beh, . - silica_rt_pid_registry_beh

// silica_rt_behaviour_name(r0 = function address) -> r0 = its C string, or "<unknown behavior>" (AAPCS,
// leaf). A record is {.word address, .word name} followed by the name's bytes, the next record 4-aligned
// after the NUL (emitter_core writes them in that order). Addresses compare without the Thumb bit.
    FUNC silica_rt_behaviour_name
    bic     r0, r0, #1
    MOV32   r1, _silica_fnames_start
    MOV32   r2, _silica_fnames_end
1:  cmp     r1, r2
    bhs.w   9f
    ldr     r3, [r1, #0]
    bic     r3, r3, #1
    cmp     r3, r0
    beq.w   2f
    ldr     r3, [r1, #4]                    // the name: skip to its NUL, then align
11: ldrb    r12, [r3], #1
    cmp     r12, #0
    bne.w   11b
    add     r3, r3, #3
    bic     r1, r3, #3
    b.w     1b
2:  ldr     r0, [r1, #4]
    bx      lr
9:  MOV32   r0, silica_rt_behaviour_unknown
    bx      lr
    .size   silica_rt_behaviour_name, . - silica_rt_behaviour_name

// ---------------------------------------------------------------------------------------------
// Ending the program (spec §15.1.2.5).

// wait_for_exit() -> int64: main parks until an exit request is recorded, then returns the recorded
// value. From an actor the call returns 0 at once.
    FUNC silica_rt_wait_for_exit
    ENTRY_SAVE
    bl      silica_rt_actors_init
    bl      silica_rt_current
    mov     r4, r0
    ldrb    r1, [r4, #ACB_KIND]
    cmp     r1, #KIND_MAIN
    bne.w   8f
    MOV32   r5, silica_rt_exit_flag
1:  ldr     r0, [r5]
    cmp     r0, #0
    bne.w   2f
    movw    r0, #ST_WAITQ
    strb    r0, [r4, #ACB_STATUS]
    bl      silica_rt_yield_to_sched        // resumed by silica_rt_exit_request_record
    b.w     1b
2:  MOV32   r0, silica_rt_exit_request
    ldr     r1, [r0, #4]
    ldr     r0, [r0, #0]
    ENTRY_RET_X0
8:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_wait_for_exit, . - silica_rt_wait_for_exit

// silica_rt_exit_request_record(r0:r1 = value) -> r0 = 1 recorded, 0 an earlier one was (AAPCS).
    FUNC silica_rt_exit_request_record
    MOV32   r2, silica_rt_exit_flag
    ldr     r3, [r2]
    cmp     r3, #0
    bne.w   9f
    movw    r3, #1
    str     r3, [r2]
    MOV32   r2, silica_rt_exit_request
    str     r0, [r2, #0]
    str     r1, [r2, #4]
    MOV32   r0, silica_rt_main_acb
    ldrb    r1, [r0, #ACB_STATUS]
    cmp     r1, #ST_WAITQ
    bne.w   1f
    push    {lr}
    bl      silica_rt_make_ready
    pop     {lr}
1:  movw    r0, #1
    bx      lr
9:  movw    r0, #0
    bx      lr
    .size   silica_rt_exit_request_record, . - silica_rt_exit_request_record

// cast_exit(X0 value) -> boolean.
    FUNC silica_rt_cast_exit
    ENTRY_SAVE
    bl      silica_rt_actors_init
    ldr     r0, [sp, #0]
    ldr     r1, [sp, #4]
    bl      silica_rt_exit_request_record
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_cast_exit, . - silica_rt_cast_exit

// ---------------------------------------------------------------------------------------------
// FailureReporter registration (spec §15.4.13.4); the reports and the exit drain are rt_failure.S.
    FUNC silica_rt_failure_reporter_register
    ENTRY_SAVE
    MOV32   r2, silica_rt_root_failure_reporter
    ldr     r3, [r2]
    cmp     r3, #0
    bne.w   1f
    MOV32   r3, silica_rt_root_failure_reporter_id
    str     r0, [r3, #0]
    str     r1, [r3, #4]
    movw    r3, #1
    str     r3, [r2]
1:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_failure_reporter_register, . - silica_rt_failure_reporter_register

    FUNC silica_rt_failure_reporter_set_dump_limit
    ENTRY_SAVE
    MOV32   r2, silica_rt_region_dump_limit
    str     r0, [r2, #0]
    str     r1, [r2, #4]
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_failure_reporter_set_dump_limit, . - silica_rt_failure_reporter_set_dump_limit

// ---------------------------------------------------------------------------------------------
// Ending an actor (remove_actor, stop_self, kill_abnormal, fail_self, traps, CPU faults), the failure
// report and its FailureReporter delivery, the exit drain: rt_failure.S.

// ---------------------------------------------------------------------------------------------
// Clocks (spec §22.14): the SysTick millisecond count (rt_vectors.S).
    FUNC silica_rt_now_ms
    MOV32   r2, silica_rt_ticks_ms
1:  ldr     r1, [r2, #4]
    ldr     r0, [r2, #0]
    ldr     r3, [r2, #4]
    cmp     r1, r3
    bne.w   1b
    bx      lr
    .size   silica_rt_now_ms, . - silica_rt_now_ms

// monotonic_time() -> X0 nanoseconds since the start (spec §22.14.1; the hosts and the ESP32-S3 answer
// nanoseconds too; before 2026-11-10 this answered milliseconds): the SysTick millisecond count x 10^6
// plus the elapsed part of the current millisecond from the SysTick counter (12.5 ns a count at
// 80 MHz). The count and the counter are read with interrupts masked; a wrap the handler has not
// counted yet (PENDSTSET) is counted here, with the counter read again after it.
    FUNC silica_rt_monotonic_time
    ENTRY_SAVE
    mrs     r7, primask
    cpsid   i
    MOV32   r2, silica_rt_ticks_ms
    ldr     r0, [r2, #0]
    ldr     r1, [r2, #4]
    MOV32   r3, SYSTICK_CVR
    ldr     r4, [r3]
    MOV32   r5, 0xE000ED04                  // SCB ICSR
    ldr     r6, [r5]
    tst     r6, #(1 << 26)                  // PENDSTSET: the counter wrapped, the tick is not counted yet
    beq.w   1f
    ldr     r4, [r3]
    adds    r0, r0, #1
    adc     r1, r1, #0
1:  msr     primask, r7
    MOV32   r3, SYSTICK_RVR
    ldr     r3, [r3]
    sub     r4, r3, r4                      // counts elapsed in this millisecond
    movw    r3, #25
    mul     r4, r4, r3
    lsr     r4, r4, #1                      // x 12.5 ns
    MOV32   r3, 1000000
    umull   r2, r5, r0, r3
    mla     r5, r1, r3, r5
    adds    r0, r2, r4
    adc     r1, r5, #0
    ENTRY_RET_X0
    .size   silica_rt_monotonic_time, . - silica_rt_monotonic_time

// current_time() -> X0 epoch milliseconds when the loader wrote the wall clock, else since the start.
    FUNC silica_rt_current_time
    ENTRY_SAVE
    bl      silica_rt_now_ms
    MOV32   r2, silica_rt_wall_clock
    ldr     r3, [r2, #0]
    adds    r0, r0, r3
    ldr     r3, [r2, #4]
    adc     r1, r1, r3
    ENTRY_RET_X0
    .size   silica_rt_current_time, . - silica_rt_current_time

    FUNC silica_rt_wall_clock_start
    bx      lr
    .size   silica_rt_wall_clock_start, . - silica_rt_wall_clock_start

// ---------------------------------------------------------------------------------------------
// Timers (group 4, 2026-11-10; spec §22.14.2; the ESP32-S3's rt_actors.S "Clocks and timers" on one
// core). The pending timers are one list ordered by deadline in SysTick milliseconds (64-bit); the
// scheduler loop fires the due ones before every pop (silica_rt_timers_fire: a dispatch boundary or
// an idle pass, never inside a dispatch), and its wfi wakes at every tick. A deadline is now + delay
// + 1 ms: the current millisecond has partly passed, so this is the first tick boundary at which the
// whole delay certainly has (a timer never fires early by monotonic_time's nanoseconds; it fires at
// most ~1 ms plus the running dispatch late). Numbers are never reused (a 64-bit counter), so a stale
// reference is :not_found and never cancels another timer. A timer that will not deliver (cancelled,
// its target ended, or a call-only target when due) frees its message buffer and its record
// (rt_timer_release). Nothing here runs in an interrupt and nothing preempts, so no lock is needed.
// A timer holds its target's identity (§15.1.4), resolved when it fires: an ended target's due timer
// finds no live actor and is released; an ended actor's pending timers are purged when its ACB is freed
// (silica_rt_free_acb -> silica_rt_timers_purge), so their buffers do not wait for the deadline.

    .section .bss.silica_rt_actors, "aw", %nobits
    .balign 8
silica_rt_timer_next:                       // the next number, low word first (0: 1 not yet handed out)
    .space  8
silica_rt_timer_head:                       // the earliest pending timer, 0 none
    .space  4

    .section .text.silica_rt_actors, "ax", %progbits

// timer_cast: silica_rt_timer_prepare(X0 target, X1 message, X2 the mailbox buffer's bytes, X3 its
// block (TP + 0; 0, 0 for an inline message)) -> X0 = the record. The inner half of send_after.
    FUNC silica_rt_timer_prepare
    ENTRY_SAVE
    movw    r0, #TMR_SIZE
    bl      silica_rt_alloc                 // zeroed (next, number)
    ldr     r1, [sp, #0]
    str     r1, [r0, #TMR_TGT]
    ldr     r1, [sp, #4]
    str     r1, [r0, #TMR_TGT + 4]
    ldr     r1, [sp, #8]
    str     r1, [r0, #TMR_MSG]
    ldr     r1, [sp, #12]
    str     r1, [r0, #TMR_MSG + 4]
    str     r4, [r0, #TMR_THUNK]            // X2 = the buffer's bytes
    ldr     r1, [r9, #0]                    // X3 = its block
    str     r1, [r0, #TMR_OWNED]
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_timer_prepare, . - silica_rt_timer_prepare

// rt_timer_release(r0 = record): a timer that will not deliver frees its message buffer and itself. AAPCS.
    LFUNC rt_timer_release
    push    {r4, lr}
    mov     r4, r0
    ldr     r0, [r4, #TMR_OWNED]
    cmp     r0, #0
    beq.w   1f
    bl      silica_rt_free
1:  mov     r0, r4
    bl      silica_rt_free
    pop     {r4, pc}
    .size   rt_timer_release, . - rt_timer_release

// rt_timer_fire(r0 = record): the cast, as rt_cast enqueues it (a mailbox node that takes the buffer, the
// target made ready), without back-pressure; an ended or call-only target drops the message silently
// (§22.14.2). The record goes back either way. AAPCS.
    LFUNC rt_timer_fire
    push    {r4-r6, lr}
    mov     r4, r0
    ldr     r1, [r4, #TMR_TGT + 4]
    ldr     r0, [r4, #TMR_TGT]
    bl      silica_rt_ref_acb
    movs    r5, r0
    beq.w   8f
    ldr     r1, [r5, #ACB_CONV]
    and     r1, r1, #3
    cmp     r1, #1
    beq.w   8f
    bl      silica_rt_alloc_node            // zeroed (MSG_NEXT, kind 0: a cast)
    ldr     r1, [r4, #TMR_MSG]
    str     r1, [r0, #MSG_PAYLOAD]
    ldr     r1, [r4, #TMR_MSG + 4]
    str     r1, [r0, #MSG_PAYLOAD + 4]
    ldr     r1, [r4, #TMR_THUNK]
    str     r1, [r0, #MSG_BUF_BYTES]
    ldr     r1, [r4, #TMR_OWNED]            // the node takes the buffer
    str     r1, [r0, #MSG_BUF_BLOCK]
    cmp     r1, #0
    ite     eq
    moveq   r2, #0
    movne   r2, #1
    str     r2, [r0, #MSG_PAYLOAD_OWNED]
    ldr     r1, [r5, #ACB_MB_TAIL]
    cmp     r1, #0
    beq.w   1f
    str     r0, [r1, #MSG_NEXT]
    str     r0, [r5, #ACB_MB_TAIL]
    b.w     2f
1:  str     r0, [r5, #ACB_MB_HEAD]
    str     r0, [r5, #ACB_MB_TAIL]
2:  mov     r0, r5
    bl      silica_rt_make_ready
    mov     r0, r4
    bl      silica_rt_free
    pop     {r4-r6, pc}
8:  mov     r0, r4
    bl      rt_timer_release
    pop     {r4-r6, pc}
    .size   rt_timer_fire, . - rt_timer_fire

// silica_rt_send_after(X0 delay_ms (uint64), X1 record) -> X0 = the timer number. A delay of 0 casts at
// once from the caller (§22.14.2), so the message is ordered before anything the caller sends next; its
// number is already fired. A target that has ended means a timer cancelled already: released, never
// found. Otherwise the record is linked in deadline order (after equal deadlines: first armed, first
// delivered). r4:r5 = the number, r6 = the record (ENTRY_SAVE keeps the caller's).
    FUNC silica_rt_send_after
    ENTRY_SAVE
    mov     r6, r2
    MOV32   r3, silica_rt_timer_next
    ldr     r4, [r3, #0]
    ldr     r5, [r3, #4]
    orrs    r12, r4, r5
    it      eq
    moveq   r4, #1
    adds    r12, r4, #1
    str     r12, [r3, #0]
    adc     r12, r5, #0
    str     r12, [r3, #4]
    str     r4, [r6, #TMR_ID]
    str     r5, [r6, #TMR_ID + 4]
    ldr     r0, [sp, #0]
    ldr     r1, [sp, #4]
    orrs    r12, r0, r1
    bne.w   3f
    mov     r0, r6
    bl      rt_timer_fire
    b.w     9f
3:  bl      silica_rt_now_ms
    ldr     r2, [sp, #0]
    ldr     r3, [sp, #4]
    adds    r0, r0, r2
    adcs    r1, r1, r3
    bcs.w   4f
    adds    r0, r0, #1
    adcs    r1, r1, #0
    bcc.w   5f
4:  mvn     r0, #0                          // past the end of time: never due
    mvn     r1, #0
5:  str     r0, [r6, #TMR_DL]
    str     r1, [r6, #TMR_DL + 4]
    mov     r2, r0
    mov     r3, r1
    ldr     r1, [r6, #TMR_TGT + 4]
    ldr     r0, [r6, #TMR_TGT]
    bl      silica_rt_ref_acb
    cmp     r0, #0
    bne.w   6f
    mov     r0, r6
    bl      rt_timer_release
    b.w     9f
6:  ldr     r2, [r6, #TMR_DL]
    ldr     r3, [r6, #TMR_DL + 4]
    MOV32   r7, silica_rt_timer_head        // r7 = the link to rewrite (TMR_NEXT is at 0)
61: ldr     r12, [r7]
    cmp     r12, #0
    beq.w   7f
    ldr     r0, [r12, #TMR_DL]
    ldr     r1, [r12, #TMR_DL + 4]
    subs    r0, r2, r0
    sbcs    r1, r3, r1
    bcc.w   7f                              // the new deadline is earlier: insert before this one
    mov     r7, r12
    b.w     61b
7:  str     r12, [r6, #TMR_NEXT]
    str     r6, [r7]
9:  mov     r0, r4
    mov     r1, r5
    ENTRY_RET_X0
    .size   silica_rt_send_after, . - silica_rt_send_after

// silica_rt_cancel_timer(X0 number) -> X0 = 0 :cancelled (pending: unlinked and released, never
// delivered), 1 :not_found (fired, cancelled, or its target has ended: cancelled automatically).
    FUNC silica_rt_cancel_timer
    ENTRY_SAVE
    MOV32   r7, silica_rt_timer_head
1:  ldr     r4, [r7]
    cmp     r4, #0
    beq.w   8f
    ldr     r2, [r4, #TMR_ID]
    cmp     r2, r0
    bne.w   2f
    ldr     r2, [r4, #TMR_ID + 4]
    cmp     r2, r1
    beq.w   3f
2:  mov     r7, r4
    b.w     1b
3:  ldr     r2, [r4, #TMR_NEXT]
    str     r2, [r7]
    ldr     r1, [r4, #TMR_TGT + 4]
    ldr     r0, [r4, #TMR_TGT]
    bl      silica_rt_ref_acb
    mov     r5, r0
    mov     r0, r4
    bl      rt_timer_release
    cmp     r5, #0
    beq.w   8f
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
8:  movw    r0, #1
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_cancel_timer, . - silica_rt_cancel_timer

// silica_rt_timers_fire(): every timer whose deadline has passed is taken off the list and cast, earliest
// first. Called by the scheduler loop before every pop. AAPCS.
    FUNC silica_rt_timers_fire
    push    {r4-r6, lr}
    MOV32   r4, silica_rt_timer_head
    ldr     r0, [r4]
    cmp     r0, #0
    beq.w   9f
    bl      silica_rt_now_ms
    mov     r5, r0
    mov     r6, r1
1:  ldr     r0, [r4]
    cmp     r0, #0
    beq.w   9f
    ldr     r1, [r0, #TMR_DL]
    ldr     r2, [r0, #TMR_DL + 4]
    subs    r1, r5, r1
    sbcs    r2, r6, r2
    bcc.w   9f                              // now < the earliest deadline: nothing is due
    ldr     r1, [r0, #TMR_NEXT]
    str     r1, [r4]
    bl      rt_timer_fire
    b.w     1b
9:  pop     {r4-r6, pc}
    .size   silica_rt_timers_fire, . - silica_rt_timers_fire

// silica_rt_timers_purge(r0 = acb): every pending timer whose target is this (ended) actor is unlinked
// and released. AAPCS.
    FUNC silica_rt_timers_purge
    push    {r4-r6, lr}
    ldr     r5, [r0, #ACB_ID]               // r5:r6 = its identity (the timers hold references)
    ldr     r6, [r0, #ACB_ID + 4]
    MOV32   r4, silica_rt_timer_head        // r4 = the link to the timer examined
1:  ldr     r0, [r4]
    cmp     r0, #0
    beq.w   9f
    ldr     r1, [r0, #TMR_TGT]
    cmp     r1, r5
    bne.w   11f
    ldr     r1, [r0, #TMR_TGT + 4]
    cmp     r1, r6
    beq.w   2f
11: mov     r4, r0
    b.w     1b
2:  ldr     r1, [r0, #TMR_NEXT]
    str     r1, [r4]
    bl      rt_timer_release
    b.w     1b
9:  pop     {r4-r6, pc}
    .size   silica_rt_timers_purge, . - silica_rt_timers_purge

// ---------------------------------------------------------------------------------------------
// Priorities and the dispatch-order policy (group 5, 2026-11-10; "Ready queues and dispatch-order
// policies" above).

// silica_rt_set_actor_priority(X0 actor, X1 level) -> 0 :ok, 1 :actor_not_found (no actor, or one that
// has ended). Levels 0 low, 1 normal, 2 high choose the ready queue the actor waits in from its next
// push (the emitter maps the program's :low / :normal / :high to them); anything else is normal. The
// level is also the actor's weight class under weighted_fair and lottery.
    FUNC silica_rt_set_actor_priority
    ENTRY_SAVE
    bl      silica_rt_ref_acb
    cmp     r0, #0
    beq.w   8f
    cmp     r3, #0
    it      ne
    movne   r2, #1
    cmp     r2, #3
    it      hs
    movhs   r2, #1
    strb    r2, [r0, #ACB_PRIO]
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
8:  movw    r0, #1
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_set_actor_priority, . - silica_rt_set_actor_priority

// silica_rt_set_scheduler_policy(X0 code) -> 0 :ok, 1 :invalid_policy. Codes are POLICY_* (the emitter
// maps the program's policy atoms to them and the result back, prims_actors.silica
// emit_set_scheduler_policy); an invalid code leaves the policy unchanged. Takes effect at the next push
// or pop.
    FUNC silica_rt_set_scheduler_policy
    ENTRY_SAVE
    cmp     r1, #0
    bne.w   8f
    cmp     r0, #POLICY_COUNT
    bhs.w   8f
    MOV32   r2, silica_rt_sched_policy
    str     r0, [r2]
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
8:  movw    r0, #1
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_set_scheduler_policy, . - silica_rt_set_scheduler_policy

// ---------------------------------------------------------------------------------------------
// Placement, priorities, links: the benign returns of the reference's Phase G surface (one core).
.macro RETURN_ZERO name
    FUNC \name
    ENTRY_SAVE
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   \name, . - \name
.endm
    RETURN_ZERO silica_rt_pin_actor_to_core
    RETURN_ZERO silica_rt_pin_actor_to_performance_core
    RETURN_ZERO silica_rt_pin_actor_to_efficiency_core
    RETURN_ZERO silica_rt_pin_actor_realtime
    RETURN_ZERO silica_rt_pin_actor_to_numa_node
    RETURN_ZERO silica_rt_unpin_actor
    RETURN_ZERO silica_rt_migrate_actor
    RETURN_ZERO silica_rt_get_efficiency_cores     // none: nil
    RETURN_ZERO silica_rt_actor_link
    RETURN_ZERO silica_rt_actor_demonitor

// monitor(X0) -> its argument.
    FUNC silica_rt_actor_monitor
    bx      lr
    .size   silica_rt_actor_monitor, . - silica_rt_actor_monitor

// ---------------------------------------------------------------------------------------------
// Topology queries (spec §22.10) and get_actor_memory_usage (§15.1.2.2). The records and lists are built
// in the running frame's dynamic part (silica_rt_frame_alloc; the call site adopts them), with the
// emitter's layouts: a record is its shape word then one 8-byte slot per field in declaration order; a
// List[T, normal] of 8-byte elements is a 24-byte handle {length, first chunk, cursor} over 32-byte chunks
// {slot 0, slot 1, next, claim} (rt_list.S). One core: core 0, a :performance core (Cortex-M4F at 80 MHz),
// as the ESP32-S3 reports each of its cores. Beyond the ESP32-S3's records (no capabilities, no NUMA node,
// frequency 0) this board names its core's capabilities, gives its frequency and reports one memory
// node over the two SRAM regions; the core has no cache (the image runs from SRAM), so no levels.

// rt_list_from_words(r0 = count, r1 = words: 8-byte slots) -> r0 = the list (0 = nil). AAPCS.
    LFUNC rt_list_from_words
    push    {r4-r8, lr}
    cmp     r0, #0
    beq.w   9f
    mov     r6, r0                          // r6 = elements left
    mov     r7, r1                          // r7 = the next word
    movw    r0, #24
    bl      silica_rt_frame_alloc
    mov     r5, r0                          // r5 = handle
    str     r6, [r5, #0]
    and     r8, r6, #1                      // an odd count: the first chunk holds one element, at slot 1
    lsl     r8, r8, #3                      // r8 = the first chunk's cursor
    str     r8, [r5, #16]
    movw    r4, #0                          // r4 = the previous chunk
1:  cmp     r6, #0
    beq.w   8f
    movw    r0, #32
    bl      silica_rt_frame_alloc
    str     r8, [r0, #24]                   // claim: the lowest data offset handed out
    cmp     r4, #0
    bne.w   2f
    str     r0, [r5, #8]
    b.w     3f
2:  str     r0, [r4, #16]
3:  mov     r4, r0
    add     r1, r0, r8
    movw    r8, #0                          // later chunks fill from slot 0
    add     r2, r0, #16
4:  cmp     r1, r2
    bhs.w   1b
    ldr     r3, [r7], #4
    str     r3, [r1], #4
    ldr     r3, [r7], #4
    str     r3, [r1], #4
    subs    r6, r6, #1
    bne.w   4b
8:  mov     r0, r5
    pop     {r4-r8, pc}
9:  movw    r0, #0
    pop     {r4-r8, pc}
    .size   rt_list_from_words, . - rt_list_from_words

// rt_core_info_record(r0 = id, -1 the sentinel) -> r0 = { id, core_type, capabilities, frequency_mhz }. The
// sentinel names no capabilities and no frequency. AAPCS.
    LFUNC rt_core_info_record
    push    {r4, r5, r6, lr}
    mov     r4, r0
    movw    r0, #40
    bl      silica_rt_frame_alloc
    mov     r5, r0
    MOV32   r1, SHAPE_CORE_INFO
    str     r1, [r5, #0]
    str     r4, [r5, #8]
    asr     r1, r4, #31
    str     r1, [r5, #12]
    movw    r1, #ATOM_PERFORMANCE
    str     r1, [r5, #16]
    cmp     r4, #0
    blt.w   9f
    movw    r0, #3
    MOV32   r1, rt_core_capability_words
    bl      rt_list_from_words
    str     r0, [r5, #24]
    movw    r1, #80
    str     r1, [r5, #32]
9:  mov     r0, r5
    pop     {r4, r5, r6, pc}
    .size   rt_core_info_record, . - rt_core_info_record

// silica_rt_get_core_capabilities(X0 id) -> X0 core_info; an id other than 0 gives the sentinel id -1.
    FUNC silica_rt_get_core_capabilities
    ENTRY_SAVE
    orrs    r2, r0, r1
    beq.w   1f
    mvn     r0, #0
1:  bl      rt_core_info_record
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_get_core_capabilities, . - silica_rt_get_core_capabilities

// silica_rt_get_performance_cores() -> X0 List[int64] = [0] (efficiency cores: none).
    FUNC silica_rt_get_performance_cores
    ENTRY_SAVE
    movw    r0, #1
    MOV32   r1, rt_word_zero
    bl      rt_list_from_words
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_get_performance_cores, . - silica_rt_get_performance_cores

// silica_rt_get_cpu_topology() -> X0 { cores, numa_nodes, cache_hierarchy }: cores [core 0]; numa_nodes
// [{ id 0, cores [0], memory_ranges [SRAM1, SRAM2] }] (latency 0: both are zero-wait SRAM); cache_hierarchy
// { levels: nil }.
    FUNC silica_rt_get_cpu_topology
    ENTRY_SAVE
    sub     sp, sp, #16                     // [sp] two 8-byte words for the lists built below
    movw    r0, #0
    bl      rt_core_info_record
    str     r0, [sp, #0]
    movw    r0, #0
    str     r0, [sp, #4]
    movw    r0, #1
    mov     r1, sp
    bl      rt_list_from_words
    mov     r6, r0                          // r6 = the cores list
    // the memory ranges
    MOV32   r0, 0x20000000
    MOV32   r1, 98304
    bl      rt_memory_range_record
    str     r0, [sp, #0]
    MOV32   r0, 0x10000000
    MOV32   r1, 32768
    bl      rt_memory_range_record
    str     r0, [sp, #8]
    movw    r0, #0
    str     r0, [sp, #4]
    str     r0, [sp, #12]
    movw    r0, #2
    mov     r1, sp
    bl      rt_list_from_words
    mov     r7, r0                          // r7 = the memory ranges
    movw    r0, #1
    MOV32   r1, rt_word_zero
    bl      rt_list_from_words
    mov     r8, r0                          // r8 = the node's cores [0]
    movw    r0, #32
    bl      silica_rt_frame_alloc
    MOV32   r1, SHAPE_NUMA_NODE
    str     r1, [r0, #0]                    // id 0 (zeroed)
    str     r8, [r0, #16]
    str     r7, [r0, #24]
    str     r0, [sp, #0]
    movw    r0, #0
    str     r0, [sp, #4]
    movw    r0, #1
    mov     r1, sp
    bl      rt_list_from_words
    mov     r7, r0                          // r7 = numa_nodes
    movw    r0, #16
    bl      silica_rt_frame_alloc
    MOV32   r1, SHAPE_CACHE_HIERARCHY
    str     r1, [r0, #0]                    // levels: nil (zeroed)
    mov     r8, r0                          // r8 = cache_hierarchy
    movw    r0, #32
    bl      silica_rt_frame_alloc
    MOV32   r1, SHAPE_CPU_TOPOLOGY
    str     r1, [r0, #0]
    str     r6, [r0, #8]
    str     r7, [r0, #16]
    str     r8, [r0, #24]
    add     sp, sp, #16
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_get_cpu_topology, . - silica_rt_get_cpu_topology

// rt_memory_range_record(r0 = start, r1 = size) -> r0 = { start_address, size, latency: 0 }. AAPCS.
    LFUNC rt_memory_range_record
    push    {r4, r5, r6, lr}
    mov     r4, r0
    mov     r5, r1
    movw    r0, #32
    bl      silica_rt_frame_alloc
    MOV32   r1, SHAPE_MEMORY_RANGE
    str     r1, [r0, #0]
    str     r4, [r0, #8]
    str     r5, [r0, #16]
    pop     {r4, r5, r6, pc}
    .size   rt_memory_range_record, . - rt_memory_range_record

// get_actor_memory_usage(X0 actor) -> { reserved, committed, retained, high_water } (40 B: shape word, four
// slots; spec §15.1.2.2), the ESP32-S3's answers. reserved: the lowered reservation, or the whole heap
// (both arenas: an actor's chunks may come from either) for the default; committed: the chunk bytes the
// two chains hold now; retained: the same (release happens at the dispatch boundary, so what is held while
// idle is what the algorithm kept); high_water: the most each chain has held, summed. An actor that has
// ended (or no actor) gives zeros.
    FUNC silica_rt_get_actor_memory_usage
    ENTRY_SAVE
    bl      silica_rt_ref_acb
    mov     r4, r0                          // r4 = the ACB, or 0
    movw    r0, #40
    bl      silica_rt_frame_alloc
    mov     r5, r0
    MOV32   r1, SHAPE_ACTOR_MEMORY
    str     r1, [r5, #0]
    cmp     r4, #0
    beq.w   9f
    ldr     r0, [r4, #ACB_POLICY]
    bic     r0, r0, #63
    cmp     r0, #0
    bne.w   1f
    MOV32   r0, _silica_heap_end
    MOV32   r1, _silica_heap_start
    sub     r0, r0, r1
    MOV32   r1, _silica_sram2_heap_end
    add     r0, r0, r1
    MOV32   r1, _silica_sram2_heap_start
    sub     r0, r0, r1
1:  str     r0, [r5, #8]
    ldr     r0, [r4, #ACB_MCHAIN]
    bl      rt_chain_bytes
    mov     r6, r0
    ldr     r0, [r4, #ACB_ACHAIN]
    bl      rt_chain_bytes
    add     r6, r6, r0
    str     r6, [r5, #16]
    str     r6, [r5, #24]
    ldr     r0, [r4, #ACB_HW_M]
    ldr     r1, [r4, #ACB_HW_A]
    add     r0, r0, r1
    str     r0, [r5, #32]
9:  mov     r0, r5
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_get_actor_memory_usage, . - silica_rt_get_actor_memory_usage

    .section .rodata.silica_rt_topology, "a", %progbits
    .balign 8
rt_word_zero:
    .word   0, 0
rt_core_capability_words:                   // three Silica strings (List[string] slots)
    .word   rt_cap_isa, 0, rt_cap_dsp, 0, rt_cap_fpu, 0
    .balign 8
rt_cap_isa:                                 // string headers: tag -1, data, byte length
    .word   0xFFFFFFFF, 0xFFFFFFFF, rt_cap_isa_s, 0, 8, 0
rt_cap_dsp:
    .word   0xFFFFFFFF, 0xFFFFFFFF, rt_cap_dsp_s, 0, 3, 0
rt_cap_fpu:
    .word   0xFFFFFFFF, 0xFFFFFFFF, rt_cap_fpu_s, 0, 7, 0
rt_cap_isa_s:
    .asciz  "armv7e-m"
rt_cap_dsp_s:
    .asciz  "dsp"
rt_cap_fpu_s:
    .asciz  "fpv4-sp"

    .section .rodata.silica_rt_actors, "a", %progbits
    .global silica_rt_behaviour_unknown
silica_rt_behaviour_unknown:
    .asciz  "<unknown behavior>"

// Weak defaults for the registry's status atoms, for images with no compiler-emitted runtime unit (the
// hand-written smoke images): -1, no such atom. The emitted .rodata.silica_registry definitions are
// strong and override these; --gc-sections then drops this section.
    .section .rodata.silica_registry_default, "a", %progbits
    .balign 4
    .weak   silica_registry_slots
silica_registry_slots:
    .word   0
    .weak   silica_registry_atom_name_taken
silica_registry_atom_name_taken:
    .word   -1
    .weak   silica_registry_atom_already_registered
silica_registry_atom_already_registered:
    .word   -1
    .weak   silica_registry_atom_actor_not_found
silica_registry_atom_actor_not_found:
    .word   -1
    .weak   silica_registry_atom_identity_exhausted
silica_registry_atom_identity_exhausted:
    .word   -1
