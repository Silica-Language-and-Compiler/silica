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
// Not here yet (each ends the program with "runtime entry not yet ported", status 71, see rt_stubs.S):
// call / call_registered and replies, actor failure handling and reports (a fault is process-fatal
// on this port for now), links and monitors beyond the benign returns, supervision restarts, timers,
// priorities and dispatch-order policies (one FIFO ready queue), stack release policies (an actor keeps
// its chunks until it ends), the identity table (an actor's identity is its ACB address: an actor_ref
// is `acb, 0`), get_actor_memory_usage and the topology queries.
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
// it dispatches it (2 KB machine, 512 B auxiliary). Growth is where emitted code checks its limits:
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
silica_rt_root_failure_reporter_id:
    .space  8
    .global silica_rt_region_dump_limit
silica_rt_region_dump_limit:
    .space  8
silica_rt_acb_free:
    .space  4
silica_rt_node_free:
    .space  4
    .balign 8
    .global silica_rt_ticks_ms
silica_rt_ticks_ms:
    .space  8
    .global silica_pid_registry_ref
silica_pid_registry_ref:
    .space  REG_SLOTS * 4
    .global silica_dangerous_pid_registry_ref
silica_dangerous_pid_registry_ref:
    .space  REG_SLOTS * 4
    .global silica_device_pid_registry_ref
silica_device_pid_registry_ref:
    .space  REG_SLOTS * 4

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

// self() -> X0 = the running actor's reference (its ACB address; 0 in main).
    FUNC silica_rt_actor_self
    b.w     silica_rt_current_actor
    .size   silica_rt_actor_self, . - silica_rt_actor_self

// ---------------------------------------------------------------------------------------------
// Blocks: ACBs and message nodes from the heap, recycled through free lists.
    FUNC silica_rt_alloc_acb
    push    {r4, lr}
    MOV32   r4, silica_rt_acb_free
    ldr     r0, [r4]
    cmp     r0, #0
    beq.w   1f
    ldr     r1, [r0, #ACB_FREE_NEXT]
    str     r1, [r4]
    movw    r1, #ACB_SIZE
    bl      silica_rt_zero_block
    pop     {r4, pc}
1:  movw    r0, #ACB_SIZE
    bl      silica_rt_alloc
    pop     {r4, pc}
    .size   silica_rt_alloc_acb, . - silica_rt_alloc_acb

    FUNC silica_rt_free_acb
    MOV32   r1, silica_rt_acb_free
    ldr     r2, [r1]
    str     r2, [r0, #ACB_FREE_NEXT]
    str     r0, [r1]
    bx      lr
    .size   silica_rt_free_acb, . - silica_rt_free_acb

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
// The ready queue (one FIFO) and contexts.

// silica_rt_make_ready(r0 = acb): a parked, suspended or waiting context becomes ready. A context
// that is ready or running already is left alone (a running actor re-queues itself at its boundary
// when its mailbox is not empty).
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
    movw    r1, #ST_READY
    strb    r1, [r0, #ACB_STATUS]
    movw    r1, #0
    str     r1, [r0, #ACB_NEXT_READY]
    MOV32   r2, silica_rt_cores
    ldr     r1, [r2, #CORE_RQ_TAIL]
    cmp     r1, #0
    beq.w   1f
    str     r0, [r1, #ACB_NEXT_READY]
    str     r0, [r2, #CORE_RQ_TAIL]
    b.w     2f
1:  str     r0, [r2, #CORE_RQ_HEAD]
    str     r0, [r2, #CORE_RQ_TAIL]
2:  ldr     r1, [r2, #CORE_RQ_LEN]
    add     r1, r1, #1
    str     r1, [r2, #CORE_RQ_LEN]
9:  bx      lr
    .size   silica_rt_make_ready, . - silica_rt_make_ready

// silica_rt_rq_pop() -> r0 = the next ready context or 0.
    LFUNC silica_rt_rq_pop
    MOV32   r2, silica_rt_cores
    ldr     r0, [r2, #CORE_RQ_HEAD]
    cmp     r0, #0
    beq.w   9f
    ldr     r1, [r0, #ACB_NEXT_READY]
    str     r1, [r2, #CORE_RQ_HEAD]
    cmp     r1, #0
    it      eq
    streq   r1, [r2, #CORE_RQ_TAIL]
    ldr     r1, [r2, #CORE_RQ_LEN]
    sub     r1, r1, #1
    str     r1, [r2, #CORE_RQ_LEN]
9:  bx      lr
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
    LFUNC rt_publish_context
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
    .size   rt_publish_context, . - rt_publish_context

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
2:  bl      silica_rt_rq_pop
    mov     r5, r0
    cmp     r5, #0
    bne.w   3f
    movw    r0, #0
    str     r0, [r4, #CORE_BUSY]
    wfi                                     // nothing ready: sleep until the next tick (the UART is polled)
    b.w     1b
3:  ldrb    r0, [r5, #ACB_STATUS]
    cmp     r0, #ST_DEAD
    beq.w   7f
    ldrb    r0, [r5, #ACB_ALIVE]
    cmp     r0, #0
    beq.w   7f
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
    cmp     r0, #ST_BOUNDARY
    bne.w   1b
    // the boundary: the loop is entered afresh next time; a waiting message re-queues the actor
    movw    r0, #0
    str     r0, [r5, #ACB_CTX_A0]
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
7:  // ended: its chunks and ACB go back
    mov     r0, r5
    bl      silica_rt_actor_recycle
    b.w     1b
    .size   silica_rt_sched_loop, . - silica_rt_sched_loop

// silica_rt_actor_recycle(r0 = acb): the chains and the ACB go back to the heap.
    LFUNC silica_rt_actor_recycle
    push    {r4, lr}
    mov     r4, r0
    ldr     r0, [r4, #ACB_MCHAIN]
    bl      silica_rt_chunks_free_from
    ldr     r0, [r4, #ACB_ACHAIN]
    bl      silica_rt_chunks_free_from
    ldr     r0, [r4, #ACB_SB]
    bl      silica_rt_free
    movw    r0, #ST_DEAD
    strb    r0, [r4, #ACB_STATUS]
    mov     r0, r4
    bl      silica_rt_free_acb
    pop     {r4, pc}
    .size   silica_rt_actor_recycle, . - silica_rt_actor_recycle

// ---------------------------------------------------------------------------------------------
// Growable stacks.

// silica_rt_chunk_take(r0 = size, r1 = kind: 0 machine, 1 auxiliary) -> r0 = chunk or 0.
    FUNC silica_rt_chunk_take
    push    {r4, r5, lr}
    mov     r5, r1
    add     r4, r0, #15
    bic     r4, r4, #15
    mov     r0, r4
    bl      silica_rt_alloc_or_null
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
    mov     r1, r6
    bl      silica_rt_chunk_take
    cmp     r0, #0
    beq.w   9f
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
    bhs.w   1f
    bic     r2, r2, #0xFF
    orr     r2, r2, r1
    str     r2, [r5, #ACB_PEAK]
1:  pop     {r0-r8, r12, lr}                // the caller's registers back, on the old chunk
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
4:  ENTRY_RET
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
// context: first chunks for each chain it holds none of, the stack empty at the top of the first
// chunk of each, and the landing at the top of the first machine chunk.
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
2:  ldr     r0, [r4, #ACB_ACHAIN]
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
    sub     sp, sp, #12                     // [sp] the reply slot (8), [sp+8] pad
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
3:  // r6 = the node. An exit notice runs the supervisor's restart logic (not ported: dropped).
    ldr     r0, [r6, #MSG_KIND]
    cmp     r0, #2
    beq.w   5f
    ldr     r0, [r4, #ACB_BEH]
    cmp     r0, #0
    beq.w   5f                              // a supervisor with no behaviour of its own drops the message
    str     r6, [r4, #ACB_ACTIVE_CALL]
    mov     r0, r4
    mov     r1, r6
    mov     r2, sp
    bl      silica_rt_run_behaviour
    // the mailbox buffer goes back now that the dispatch end has placed the state
    ldr     r0, [r6, #MSG_BUF_BLOCK]
    cmp     r0, #0
    beq.w   4f
    movw    r1, #0
    str     r1, [r6, #MSG_BUF_BLOCK]
    str     r1, [r6, #MSG_BUF_BYTES]
    bl      silica_rt_free
4:  movw    r0, #0
    str     r0, [r4, #ACB_ACTIVE_CALL]
    ldr     r0, [r6, #MSG_KIND]
    cmp     r0, #1
    bne.w   5f
    // a call: the reply is in the node; wake the caller (calls are not ported yet: no caller waits)
    movw    r0, #1
    str     r0, [r6, #MSG_REPLY_SET]
    ldr     r0, [r6, #MSG_CALLER]
    cmp     r0, #0
    beq.w   6f
    bl      silica_rt_wake
    b.w     6f
5:  mov     r0, r6
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

// silica_rt_spawn_common(r0 = extra block, EXTRA_* fields) -> r0 = the ACB. A supervisor (a trampoline
// in the block) is scheduled at once and the spawner suspends until its trampoline ran, so the children
// exist when spawn returns (the reference behaviour).
    FUNC silica_rt_spawn_common
    push    {r4-r7, lr}
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
    // identity: the ACB address (the identity table is not ported)
    str     r5, [r5, #ACB_ID]
    movw    r0, #0
    str     r0, [r5, #ACB_ID + 4]
    movw    r0, #1
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
2:  // a supervisor: its block holds the trampoline; schedule it and wait until the trampoline ran
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
    str     r0, [r7, #SB_SPAWN_WAITER]
    movw    r1, #ST_SUSPENDED
    strb    r1, [r0, #ACB_STATUS]
    mov     r0, r5
    bl      silica_rt_make_ready
    bl      silica_rt_yield_to_sched        // woken by the trampoline's end (actor_main)
    b.w     9f
4:  mov     r0, r5
    bl      silica_rt_make_ready
9:  mov     r0, r5
    pop     {r4-r7, pc}
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
    MOV32   r1, silica_rt_wait_root_acb
    ldr     r2, [r1]
    cmp     r2, #0
    it      eq
    streq   r0, [r1]
    movw    r1, #0
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
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_actor_spawn_linked, . - silica_rt_actor_spawn_linked

// ---------------------------------------------------------------------------------------------
// Messages.

// rt_ref_acb(r0 = reference low word) -> r0 = its ACB when it names a live actor, else 0.
    LFUNC rt_ref_acb
    cmp     r0, #0
    beq.w   9f
    MOV32   r1, _silica_heap_start
    cmp     r0, r1
    blo.w   9f
    MOV32   r1, _silica_heap_end
    cmp     r0, r1
    bhs.w   9f
    ldrb    r1, [r0, #ACB_ALIVE]
    cmp     r1, #0
    bne.w   8f
9:  movw    r0, #0
8:  bx      lr
    .size   rt_ref_acb, . - rt_ref_acb

// rt_cast(r0 = acb, r1 = payload lo, r2 = payload hi, r3 = bytes, r12 = block) -> r0 = 1.
    LFUNC rt_cast
    push    {r4-r7, lr}
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
    movw    r0, #1
    pop     {r4-r7, pc}
    .size   rt_cast, . - rt_cast

// cast(X0 reference, X1 message, X2 bytes, X3 block) -> 1; send -> 0. An ended or unknown target
// raises actor_not_found (a runtime abort here).
    FUNC silica_rt_actor_cast
    ENTRY_SAVE
    bl      rt_ref_acb
    cmp     r0, #0
    beq.w   8f
    mov     r1, r2
    mov     r2, r3
    mov     r3, r4
    ldr     r12, [r9, #0]
    bl      rt_cast
    movw    r1, #0
    ENTRY_RET_X0
8:  bl      silica_rt_actor_not_found
    .size   silica_rt_actor_cast, . - silica_rt_actor_cast

    FUNC silica_rt_actor_send
    ENTRY_SAVE
    bl      rt_ref_acb
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
8:  bl      silica_rt_actor_not_found
    .size   silica_rt_actor_send, . - silica_rt_actor_send

// rt_registry_lookup(r0 = table, r1 = atom) -> r0 = the live ACB holding the name, or 0. Clobbers
// r12 only besides r0 (its callers still hold X1 in r2:r3).
    LFUNC rt_registry_lookup
    cmp     r1, #REG_SLOTS
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
    MOV32   r0, \table
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
8:  bl      silica_rt_actor_not_found
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
    bl      rt_ref_acb
    cmp     r0, #0
    beq.w   8f
    mov     r4, r0
    MOV32   r0, \table
    mov     r1, r2
    bl      rt_registry_lookup
    cmp     r0, #0
    bne.w   8f
    cmp     r2, #REG_SLOTS
    bhs.w   8f
    MOV32   r0, \table
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
    MOV32   r0, \table
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
    MOV32   r0, silica_pid_registry_ref
    b.w     rt_registry_lookup
    .size   silica_rt_registry_name_held, . - silica_rt_registry_name_held

// silica_rt_registry_enter(r0 = atom, r1 = acb): the plain registry takes the name (a supervisor's
// child by its id; AAPCS, rt_supervisors.S).
    FUNC silica_rt_registry_enter
    cmp     r0, #REG_SLOTS
    bhs.w   9f
    MOV32   r2, silica_pid_registry_ref
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
    bl      rt_ref_acb
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

// Failures the messaging raises (status 71 aborts here; the reference ends the calling actor with
// :language_error, which is stage 2 of this port).
    FUNC silica_rt_actor_not_found
    MOV32   r0, silica_rt_reason_actor_not_found
    b.w     silica_rt_abort_body
    .size   silica_rt_actor_not_found, . - silica_rt_actor_not_found

    FUNC silica_rt_registry_name_taken
    MOV32   r0, silica_rt_reason_name_taken
    b.w     silica_rt_abort_body
    .size   silica_rt_registry_name_taken, . - silica_rt_registry_name_taken

    FUNC silica_rt_convention_mismatch
    MOV32   r0, silica_rt_reason_convention
    b.w     silica_rt_abort_body
    .size   silica_rt_convention_mismatch, . - silica_rt_convention_mismatch

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
// FailureReporter registration (spec §15.4.13.4) and the report drain at exit.
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

    FUNC silica_rt_report_drain_at_exit
    bx      lr
    .size   silica_rt_report_drain_at_exit, . - silica_rt_report_drain_at_exit

// ---------------------------------------------------------------------------------------------
// Ending an actor: the minimal forms (a normal stop of the running actor, remove_actor of a parked
// one). The name is dropped and the ACB marked; the scheduler recycles the chunks.
    LFUNC rt_end_acb
    push    {r4, lr}
    mov     r4, r0
    movw    r0, #0
    strb    r0, [r4, #ACB_ALIVE]
    ldrh    r1, [r4, #ACB_REG_NAME]
    cmp     r1, #0
    beq.w   1f
    sub     r1, r1, #1
    MOV32   r2, silica_pid_registry_ref
    str     r0, [r2, r1, lsl #2]
    strh    r0, [r4, #ACB_REG_NAME]
1:  pop     {r4, pc}
    .size   rt_end_acb, . - rt_end_acb

// remove_actor(X0 reference) -> 0.
    FUNC silica_rt_remove_actor
    ENTRY_SAVE
    bl      rt_ref_acb
    cmp     r0, #0
    beq.w   9f
    mov     r4, r0
    bl      rt_end_acb
    bl      silica_rt_current
    cmp     r0, r4
    bne.w   1f
    movw    r0, #ST_DEAD                    // the running actor ends: the scheduler recycles it
    strb    r0, [r4, #ACB_STATUS]
    bl      silica_rt_yield_to_sched
1:  ldrb    r0, [r4, #ACB_STATUS]
    cmp     r0, #ST_IDLE
    bne.w   9f
    mov     r0, r4                          // parked, no context: its chunks and ACB go back now
    bl      silica_rt_actor_recycle
9:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_remove_actor, . - silica_rt_remove_actor

// stop_self_normal(): the running actor ends with :normal.
    FUNC silica_rt_stop_self_normal
    ENTRY_SAVE
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #0
    bne.w   9f
    mov     r4, r0
    bl      rt_end_acb
    movw    r0, #ST_DEAD
    strb    r0, [r4, #ACB_STATUS]
    bl      silica_rt_yield_to_sched
9:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_stop_self_normal, . - silica_rt_stop_self_normal

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

// monotonic_time() -> X0 milliseconds since the start.
    FUNC silica_rt_monotonic_time
    ENTRY_SAVE
    bl      silica_rt_now_ms
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
    RETURN_ZERO silica_rt_set_actor_priority
    RETURN_ZERO silica_rt_set_scheduler_policy
    RETURN_ZERO silica_rt_migrate_actor
    RETURN_ZERO silica_rt_get_performance_cores
    RETURN_ZERO silica_rt_get_efficiency_cores
    RETURN_ZERO silica_rt_actor_link
    RETURN_ZERO silica_rt_actor_demonitor
    RETURN_ZERO silica_rt_actor_add_child

// monitor(X0) -> its argument.
    FUNC silica_rt_actor_monitor
    bx      lr
    .size   silica_rt_actor_monitor, . - silica_rt_actor_monitor

    .section .rodata.silica_rt_actors, "a", %progbits
silica_rt_reason_actor_not_found:
    .asciz  "actor_not_found"
silica_rt_reason_name_taken:
    .asciz  "registered name already held"
silica_rt_reason_convention:
    .asciz  "actor calling convention mismatch"
