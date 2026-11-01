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

// Supervisor runtime for the bare-metal ESP32-S3 (spec §15.4.8-§15.4.12): the child table and its
// operations, which the emitter's prims_actors.silica reaches as silica_rt_supervisor_* and
// silica_rt_child_table_*, and which the per-supervisor start trampoline (module_linkage.silica)
// reaches as silica_rt_supervisor_materialize_init_children. The reference for every behaviour is
// apple_silicon_mac/terms/prims/prims_actors_child_table_asm.silica; the ACB fields it uses are the
// ones rt_actors.S defines (supervisor, agent type, row on the actor; the child table head/len,
// strategy, restart caps, sync_failure_reported and the ingress queue in the supervision block,
// ACB_SB, which only a supervisor carries -- actor_memory_budget_plan.md item I. A query on an
// actor without one sees an empty table; the paths that make a supervisor, materialize and
// start_child, call silica_rt_sb_require).
//
// Child table: a singly linked list of 112-byte rows anchored at SB+48 (head) with the high-water
// row count at SB+52; a row whose child is 0 is a tombstone (:temporary / :transient children
// that were not restarted, terminated children). The rows go back to the heap when the supervisor
// ends (silica_rt_child_table_free); a context that walks them outside the scheduler lock brackets
// the walk with silica_rt_child_table_enter / _leave, and an end that comes while such a walk is
// in progress leaves the free to the last walker. Row layout, 8-byte slots as the reference's:
//   +0 child_ref  +8 id atom  +16 agent_type atom  +24 initial state  +32 behaviour  +40 restart atom
//   +48 shutdown  +56 exit_done  +64 flavor atom  +72 supervisor start trampoline  +80 next row
//   +88 initial state bytes (the shell size of a composite initial state; 0 for a scalar)
//   +92 stopping: a stop_child of this row is in progress, so the child's exit notice must not
//       restart or tombstone the row (the stop's caller settles the row; see maybe_restart)
//   +96/+100 the child's spawner record, +104 the child's identity (spec §15.1.4; a reference is an
//       identity, so every child reference this file answers with is +104, never the ACB at +0)
// A child spec record (as the emitter lays it out in a child-spec list cell or a start_child
// argument): shape word@0, id@8, agent_type@16, initial_state@24, behavior@32, restart@40,
// shutdown@48, flavor@56, hidden start trampoline@64 with the initial state's shell size in its
// high word@68 (terms/term_child_spec.silica; 72 bytes; the child-spec list keeps one such cell per
// 72-byte chunk, prims_list.silica chunk_elem_slot_bytes).
//
// A composite initial state is copied into a fresh heap block for every spawn of the row
// (silica_rt_supervisor_spawn_child_row_by_flavor), owned by that child (rt_actors.S
// ACB_STATE_OWNED) and freed at its end, so a restarted child starts from the spec's init again
// and never shares a state block with a dead predecessor.
//
// Cooperative model: the reference kills a sibling by marking it and spinning on the row's exit_done
// flag while the child's own thread unwinds; here a parked child is ended synchronously in the
// caller's context (rt_actors.S silica_rt_end_actor runs the exit path and stamps exit_done), so
// the flag is set when end_actor returns. A child running on another core ends at its next
// dispatch boundary; the wait loops below cover that case.
//
// Restart frequency windows are measured in seconds from the 16 MHz system timer (SYSTIMER unit
// 0), started here on first use.

#define ACB_STATE        0
#define ACB_BEH          8
#define ACB_STATUS       16     // byte
#define ACB_KIND         19     // byte
#define ACB_ALIVE        21     // byte
#define ACB_STATE_OWNED  23     // byte
#define ACB_REASON_TAG   24     // byte
#define ACB_REASON_ATOM  26     // halfword
#define ACB_AGENT        28     // halfword
#define ACB_CONV         12     // rt_actors.S: the behaviour's calling convention (1 call-only, 2 cast-only)
#define ACB_SUP          72
#define ACB_ROW          76
#define ACB_SB           80     // the supervision block (rt_actors.S), 0 for a plain actor
#define SB_IN_HEAD       0
#define SB_IN_TAIL       4
#define SB_IN_DEPTH      8
#define SB_SYNC_REPORTED 16
#define SB_TRAMP         20
#define SB_TRAMP_RAN     24     // the start's state and the ACB's holders (rt_actors.S TR_*)
#define SB_STRATEGY      28
#define SB_ALLOWED       32
#define SB_TIMEFRAME     36
#define SB_RESTARTS      40
#define SB_WINDOW        44
#define SB_CT_HEAD       48
#define SB_CT_LEN        52
#define SB_CT_USERS      56
#define SB_CT_PENDING    60
#define SB_SINK          64     // the report sink's identity (8 B; spec §15.4.10.5), 0 none

#define ST_DEAD          4

#define TR_SPAWNER       2      // rt_actors.S: the spawner holds the ACB
#define TR_INIT_DEAD_BIT 8      // rt_actors.S: the actor ended inside its start trampoline

#define MSG_NEXT         0
#define MSG_KIND         4
#define MSG_PAYLOAD      8
#define MSG_INGRESS_KIND 32

#define ROW_CHILD        0
#define ROW_ID           8
#define ROW_AGENT        16
#define ROW_INIT         24
#define ROW_BEH          32
#define ROW_RESTART      40
#define ROW_SHUTDOWN     48
#define ROW_EXIT_DONE    56
#define ROW_FLAVOR       64
#define ROW_TRAMP        72
#define ROW_NEXT         80
#define ROW_INIT_BYTES   88
#define ROW_STOPPING     92
#define ROW_SPOS         96     // the child's spawner record (position + 1, next child number): kept
#define ROW_SNEXT        100    //   across the child's restarts (spec §15.1.4, §15.4.12.1)
#define ROW_CID          104    // the current child's identity (8 B): what call_supervisor answers
#define ROW_SIZE         112
#define ACB_ID           128    // rt_actors.S: the actor's identity

#define SPEC_SHAPE       0
#define SPEC_ID          8
#define SPEC_AGENT       16
#define SPEC_INIT        24
#define SPEC_BEH         32
#define SPEC_RESTART     40
#define SPEC_SHUTDOWN    48
#define SPEC_FLAVOR      56
#define SPEC_TRAMP       64
#define SPEC_INIT_BYTES  68
#define SPEC_LIST_CHUNK  72

// Reserved shape numbers of the records this runtime builds (emitter record_shape.silica,
// atom_table.silica seed_actor_runtime_atoms): the word every record starts with.
#define SHAPE_CHILD_INFO 65536

#define ATOM_NORMAL      3
#define ATOM_LANGUAGE_ERROR 4
#define ATOM_MEMORY_FAULT 5
#define ATOM_EXPLICIT    6
#define ATOM_UNKNOWN     7
#define ATOM_PERMANENT   9
#define ATOM_TRANSIENT   10
#define ATOM_ONE_FOR_ALL 13
#define ATOM_REST_FOR_ONE 14
#define ATOM_DANGEROUS   22

#define SYSTIMER_CONF_REG          0x60023000
#define SYSTIMER_UNIT0_OP_REG      0x60023004
#define SYSTIMER_UNIT0_VALUE_HI_REG 0x60023040
#define SYSTIMER_UNIT0_VALUE_LO_REG 0x60023044
#define SYSTIMER_CLK_EN            0x80000000
#define SYSTIMER_UNIT0_WORK_EN     0x40000000
#define SYSTIMER_UNIT0_UPDATE      0x40000000
#define SYSTIMER_UNIT0_VALUE_VALID 0x20000000
#define SYSTIMER_TICKS_PER_SECOND  16000000

.macro SCHED_LOCK ra, rb
    movi    \ra, silica_rt_sched_lock
9:  movi    \rb, 0
    wsr     \rb, scompare1
    movi    \rb, 1
    s32c1i  \rb, \ra, 0
    bnez    \rb, 9b
.endm

.macro SCHED_UNLOCK ra, rb
    memw
    movi    \ra, silica_rt_sched_lock
    movi    \rb, 0
    s32i    \rb, \ra, 0
    memw
.endm

    .section .rodata.silica_rt_supervisors, "a"
silica_rt_duplicate_child_id_msg:
    .asciz  "duplicate_child_id\n"

    .section .text.silica_rt_supervisors, "ax"
    .literal_position

// ---------------------------------------------------------------------------------------------
// Time: seconds since the system timer was started (first call).

    .align  4
    .global silica_rt_now_seconds
    .type   silica_rt_now_seconds, @function
silica_rt_now_seconds:
    entry   a1, 32
    movi    a3, SYSTIMER_CONF_REG
    l32i    a4, a3, 0
    movi    a5, SYSTIMER_CLK_EN | SYSTIMER_UNIT0_WORK_EN
    or      a4, a4, a5
    s32i    a4, a3, 0
    movi    a3, SYSTIMER_UNIT0_OP_REG
    movi    a4, SYSTIMER_UNIT0_UPDATE
    s32i    a4, a3, 0
    movi    a5, SYSTIMER_UNIT0_VALUE_VALID
1:  l32i    a4, a3, 0
    and     a4, a4, a5
    beqz    a4, 1b
    movi    a3, SYSTIMER_UNIT0_VALUE_LO_REG
    l32i    a10, a3, 0
    movi    a3, SYSTIMER_UNIT0_VALUE_HI_REG
    l32i    a11, a3, 0
    movi    a12, SYSTIMER_TICKS_PER_SECOND
    movi    a13, 0
    call8   __udivdi3
    mov     a2, a10
    movi    a3, 0
    retw
    .size   silica_rt_now_seconds, . - silica_rt_now_seconds

// silica_rt_now_ticks() -> the system timer's low word (16 MHz; wraps every 268 s, so differences
// are taken modulo 2^32), started on first use as above. rt_actors.S :release_when_idle.
    .align  4
    .global silica_rt_now_ticks
    .type   silica_rt_now_ticks, @function
silica_rt_now_ticks:
    entry   a1, 32
    movi    a3, SYSTIMER_CONF_REG
    l32i    a4, a3, 0
    movi    a5, SYSTIMER_CLK_EN | SYSTIMER_UNIT0_WORK_EN
    or      a4, a4, a5
    s32i    a4, a3, 0
    movi    a3, SYSTIMER_UNIT0_OP_REG
    movi    a4, SYSTIMER_UNIT0_UPDATE
    s32i    a4, a3, 0
    movi    a5, SYSTIMER_UNIT0_VALUE_VALID
1:  l32i    a4, a3, 0
    and     a4, a4, a5
    beqz    a4, 1b
    movi    a3, SYSTIMER_UNIT0_VALUE_LO_REG
    l32i    a2, a3, 0
    movi    a3, 0
    retw
    .size   silica_rt_now_ticks, . - silica_rt_now_ticks

// ---------------------------------------------------------------------------------------------
// Rows

// silica_rt_child_table_enter(sup) / silica_rt_child_table_leave(sup): bracket every walk of a
// supervisor's rows that runs outside the scheduler lock and may not be in the supervisor's own
// context, or may park while it holds row pointers (the call_supervisor prims, the restart logic a
// drain runs on a caller's behalf, a start trampoline parked while a child supervisor's init runs).
// ACB_CT_USERS counts them. A supervisor that ends while the count is not 0 leaves its rows and its
// ACB to the last of them (ACB_CT_PENDING: 1 the rows, 2 the ACB), so a restart in progress never
// writes into freed rows and a recycled ACB is never reused under a walker. sup 0 is a no-op.
    .align  4
    .global silica_rt_child_table_enter
    .type   silica_rt_child_table_enter, @function
silica_rt_child_table_enter:
    entry   a1, 32
    beqz    a2, 7f                      // (SCHED_LOCK defines a local 9: of its own)
    l32i    a4, a2, ACB_SB
    beqz    a4, 7f                      // no supervision block: no rows to hold
    SCHED_LOCK a8, a9
    l32i    a3, a4, SB_CT_USERS
    addi    a3, a3, 1
    s32i    a3, a4, SB_CT_USERS
    SCHED_UNLOCK a8, a9
7:  retw
    .size   silica_rt_child_table_enter, . - silica_rt_child_table_enter

    .align  4
    .global silica_rt_child_table_leave
    .type   silica_rt_child_table_leave, @function
silica_rt_child_table_leave:
    entry   a1, 32
    beqz    a2, 7f                      // (SCHED_LOCK defines a local 9: of its own)
    l32i    a5, a2, ACB_SB
    beqz    a5, 7f
    SCHED_LOCK a8, a9
    l32i    a3, a5, SB_CT_USERS
    beqz    a3, 8f                      // never entered (a stale reference): nothing to leave
    addi    a3, a3, -1
    s32i    a3, a5, SB_CT_USERS
    bnez    a3, 8f
    l32i    a4, a5, SB_CT_PENDING
    beqz    a4, 8f
    movi    a3, 0
    s32i    a3, a5, SB_CT_PENDING
    SCHED_UNLOCK a8, a9
    bbci    a4, 0, 1f
    mov     a10, a2
    call8   silica_rt_child_table_free  // no user is left: this time it frees
1:  bbci    a4, 1, 9f
    mov     a10, a2
    call8   silica_rt_free_acb
    j       9f
8:  SCHED_UNLOCK a8, a9
9:  retw
7:  retw
    .size   silica_rt_child_table_leave, . - silica_rt_child_table_leave

// silica_rt_child_table_free(acb): run when the supervisor ends (rt_actors.S silica_rt_actor_exit).
// Under the scheduler lock the chain is detached, the anchors are cleared and every live child
// still pointing at its row (ACB_ROW, where its own end stamps exit_done) is cut loose; then each
// row goes back to the heap, as silica_rt_region_destroy returns a region's chain. While a walker
// holds the rows (ACB_CT_USERS) the free is left to the last one to leave. sync_failure_reported
// outlives the table.
    .align  4
    .global silica_rt_child_table_free
    .type   silica_rt_child_table_free, @function
silica_rt_child_table_free:
    entry   a1, 32
    l32i    a2, a2, ACB_SB              // a plain actor has no table (7f: a 9f here would land
    beqz    a2, 7f                      // in SCHED_LOCK's own local 9:)
    SCHED_LOCK a8, a9
    l32i    a3, a2, SB_CT_USERS
    beqz    a3, 1f
    l32i    a3, a2, SB_CT_PENDING
    movi    a4, 1
    or      a3, a3, a4
    s32i    a3, a2, SB_CT_PENDING
    SCHED_UNLOCK a8, a9
    j       9f
1:  l32i    a5, a2, SB_CT_HEAD          // a5 = the detached chain
    movi    a3, 0
    s32i    a3, a2, SB_CT_HEAD
    s32i    a3, a2, SB_CT_LEN
    mov     a4, a5
2:  beqz    a4, 3f
    l32i    a6, a4, ROW_CHILD
    beqz    a6, 21f
    l32i    a7, a6, ACB_ROW
    bne     a7, a4, 21f
    s32i    a3, a6, ACB_ROW             // an orphaned child no longer stamps this row at its end
21: l32i    a4, a4, ROW_NEXT
    j       2b
3:  SCHED_UNLOCK a8, a9
4:  beqz    a5, 9f
    l32i    a4, a5, ROW_NEXT
    mov     a10, a5
    call8   silica_rt_free
    mov     a5, a4
    j       4b
7:
9:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_child_table_free, . - silica_rt_child_table_free

// silica_rt_row_release_child(row): the row's child slot is given up (a tombstone, or a respawn
// about to take the row). Under the scheduler lock the old child's ACB_ROW is cleared if it still
// names this row, so an exit of that child still in progress on another core (its banner printing,
// say) no longer stamps exit_done into a row that may be reused or freed by then; the slot is 0.
    .align  4
silica_rt_row_release_child:
    entry   a1, 32
    SCHED_LOCK a8, a9
    l32i    a3, a2, ROW_CHILD
    beqz    a3, 1f
    l32i    a4, a3, ACB_ROW
    bne     a4, a2, 1f
    movi    a4, 0
    s32i    a4, a3, ACB_ROW
1:  movi    a4, 0
    s32i    a4, a2, ROW_CHILD
    s32i    a4, a2, ROW_CHILD + 4
    s32i    a4, a2, ROW_STOPPING
    SCHED_UNLOCK a8, a9
    retw
    .size   silica_rt_row_release_child, . - silica_rt_row_release_child

// silica_rt_child_table_append_row(acb) -> the new (zeroed) row at the tail; len is not changed.
    .align  4
silica_rt_child_table_append_row:
    entry   a1, 32
    movi    a10, ROW_SIZE
    call8   silica_rt_alloc
    l32i    a5, a2, ACB_SB              // the caller made the block (silica_rt_sb_require)
    l32i    a3, a5, SB_CT_HEAD
    bnez    a3, 1f
    s32i    a10, a5, SB_CT_HEAD
    mov     a2, a10
    movi    a3, 0
    retw
1:  l32i    a4, a3, ROW_NEXT
    beqz    a4, 2f
    mov     a3, a4
    j       1b
2:  s32i    a10, a3, ROW_NEXT
    mov     a2, a10
    movi    a3, 0
    retw
    .size   silica_rt_child_table_append_row, . - silica_rt_child_table_append_row

// silica_rt_child_table_row_at(acb, index) -> row or 0
    .align  4
silica_rt_child_table_row_at:
    entry   a1, 32
    l32i    a4, a2, ACB_SB
    beqz    a4, 9f
    l32i    a4, a4, SB_CT_HEAD
1:  beqz    a4, 9f
    beqz    a3, 8f
    l32i    a4, a4, ROW_NEXT
    addi    a3, a3, -1
    j       1b
8:  mov     a2, a4
    movi    a3, 0
    retw
9:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_child_table_row_at, . - silica_rt_child_table_row_at

// silica_rt_supervisor_spawn_child_row(row, sup) -> child. spawn_linked(initial state, behaviour,
// agent type, row, trampoline); a :dangerous child is registered in the dangerous registry as well.
// Frame: [a1] the initial state handed to the child, [a1+4] 1 when it is the child's own copy.
    .align  4
    .global silica_rt_supervisor_spawn_child_row_by_flavor
    .type   silica_rt_supervisor_spawn_child_row_by_flavor, @function
silica_rt_supervisor_spawn_child_row_by_flavor:
    entry   a1, 48
    mov     a6, a2                      // a6 = row
    mov     a7, a3                      // a7 = supervisor
    mov     a10, a6
    call8   silica_rt_row_release_child // the row's previous child, if any, lets go of the row
    movi    a4, 0                       // exit_done is cleared before the child can run: one that
    s32i    a4, a6, ROW_EXIT_DONE       // ends in its start stamps it, and that stamp must stay
    l32i    a5, a6, ROW_INIT
    s32i    a5, a1, 0
    movi    a4, 0
    s32i    a4, a1, 4
    l32i    a4, a6, ROW_INIT_BYTES
    beqz    a4, 2f
    movi    a9, 65536
    bltu    a5, a9, 2f                  // an atom alternative of a sum-typed init is a value
    mov     a10, a4
    call8   silica_rt_alloc
    mov     a8, a5                      // copy the shell word by word
    mov     a9, a10
    add     a4, a5, a4
1:  bgeu    a8, a4, 11f
    l32i    a3, a8, 0
    s32i    a3, a9, 0
    addi    a8, a8, 4
    addi    a9, a9, 4
    j       1b
11: s32i    a10, a1, 0
    movi    a3, 1
    s32i    a3, a1, 4
2:  rur     a8, threadptr               // this core's register block (X3.. at 0)
    s32i    a6, a8, 0                   // X3 = row
    movi    a9, 0
    s32i    a9, a8, 4
    l32i    a9, a6, ROW_TRAMP
    s32i    a9, a8, 8                   // X4 = trampoline
    movi    a9, 0
    s32i    a9, a8, 12
    s32i    a7, a8, 16                  // X5 = the supervisor whose stack reserve the child inherits
    s32i    a9, a8, 20
    l32i    a10, a1, 0
    movi    a11, 0
    l32i    a12, a6, ROW_BEH
    l32i    a13, a6, ROW_BEH + 4
    l32i    a14, a6, ROW_AGENT
    movi    a15, 0
    call8   silica_rt_actor_spawn_linked_acb
    s32i    a12, a6, ROW_CID            // the child's identity (§15.1.4; the callee's a4:a5)
    s32i    a13, a6, ROW_CID + 4
    mov     a5, a10                     // a5 = child, held for this spawner (TR_SPAWNER) when it
    beqz    a5, 9f                      // is a supervisor
    // a child that ended inside its start trampoline (its init failed): the row takes the
    // reference, since its exit notice is matched to the row by it, but nothing is written into
    // the ended actor, its id is not registered, and the init copy it never adopted goes back
    l32i    a4, a5, ACB_SB
    beqz    a4, 3f
    l32i    a4, a4, SB_TRAMP_RAN
    bbci    a4, TR_INIT_DEAD_BIT, 3f
    s32i    a5, a6, ROW_CHILD
    movi    a9, 0
    s32i    a9, a6, ROW_CHILD + 4
    l32i    a9, a1, 4
    beqz    a9, 8f
    l32i    a10, a1, 0
    call8   silica_rt_free
    j       8f
3:  s32i    a7, a5, ACB_SUP
    l32i    a9, a1, 4
    s8i     a9, a5, ACB_STATE_OWNED
    s32i    a5, a6, ROW_CHILD
    movi    a9, 0
    s32i    a9, a6, ROW_CHILD + 4
    l32i    a4, a6, ROW_FLAVOR
    movi    a9, ATOM_DANGEROUS
    bne     a4, a9, 1f
    l32i    a10, a6, ROW_CID            // X0 = the child's reference
    l32i    a11, a6, ROW_CID + 4
    l32i    a12, a6, ROW_ID
    movi    a13, 0
    call8   silica_rt_register_dangerous_actor_named
1:  l32i    a10, a6, ROW_CID
    l32i    a11, a6, ROW_CID + 4
    l32i    a12, a6, ROW_ID
    movi    a13, 0
    call8   silica_rt_register_actor_named
8:  mov     a10, a5                     // the row holds the child now: the spawner lets go
    movi    a11, TR_SPAWNER
    call8   silica_rt_tramp_release
9:  mov     a2, a5
    movi    a3, 0
    retw
    .size   silica_rt_supervisor_spawn_child_row_by_flavor, . - silica_rt_supervisor_spawn_child_row_by_flavor

// silica_rt_row_child_ref(row or 0) -> X0 = the reference to the row's child: its identity, or all
// ones (no actor's) for no row, a tombstone, or a row whose child is gone.
    .align  4
silica_rt_row_child_ref:
    entry   a1, 32
    beqz    a2, 61f
    l32i    a4, a2, ROW_CHILD
    beqz    a4, 61f
    l32i    a3, a2, ROW_CID + 4
    l32i    a2, a2, ROW_CID
    retw
61: movi    a2, -1
    movi    a3, -1
    retw
    .size   silica_rt_row_child_ref, . - silica_rt_row_child_ref

// silica_rt_sup_acb(X0 the supervisor's reference) -> its ACB. A supervisor that has ended (or never
// existed) raises actor_not_found (§16.1.1.1: call_supervisor is a call). Never returns 0.
    .align  4
silica_rt_sup_acb:
    entry   a1, 32
    mov     a10, a2
    mov     a11, a3
    call8   silica_rt_ref_acb
    beqz    a10, 61f
    l8ui    a4, a10, ACB_ALIVE
    beqz    a4, 61f
    mov     a2, a10
    movi    a3, 0
    retw
61: call8   silica_rt_actor_not_found   // never returns
    j       61b
    .size   silica_rt_sup_acb, . - silica_rt_sup_acb

// silica_rt_fill_row_from_spec(row, spec): copy the visible fields and the hidden trampoline.
    .align  4
silica_rt_fill_row_from_spec:
    entry   a1, 32
    movi    a4, 0
    s32i    a4, a2, ROW_CHILD
    s32i    a4, a2, ROW_CHILD + 4
    l32i    a4, a3, SPEC_ID
    s32i    a4, a2, ROW_ID
    l32i    a4, a3, SPEC_AGENT
    s32i    a4, a2, ROW_AGENT
    l32i    a4, a3, SPEC_INIT
    s32i    a4, a2, ROW_INIT
    l32i    a4, a3, SPEC_INIT + 4
    s32i    a4, a2, ROW_INIT + 4
    l32i    a4, a3, SPEC_BEH
    s32i    a4, a2, ROW_BEH
    l32i    a4, a3, SPEC_BEH + 4
    s32i    a4, a2, ROW_BEH + 4
    l32i    a4, a3, SPEC_RESTART
    s32i    a4, a2, ROW_RESTART
    l32i    a4, a3, SPEC_SHUTDOWN
    s32i    a4, a2, ROW_SHUTDOWN
    l32i    a4, a3, SPEC_SHUTDOWN + 4
    s32i    a4, a2, ROW_SHUTDOWN + 4
    movi    a4, 0
    s32i    a4, a2, ROW_EXIT_DONE
    l32i    a4, a3, SPEC_FLAVOR
    s32i    a4, a2, ROW_FLAVOR
    l32i    a4, a3, SPEC_TRAMP
    s32i    a4, a2, ROW_TRAMP
    l32i    a4, a3, SPEC_INIT_BYTES
    s32i    a4, a2, ROW_INIT_BYTES
    movi    a4, 0
    s32i    a4, a2, ROW_STOPPING
    s32i    a4, a2, ROW_SPOS            // a new child for this row: a fresh spawner record
    s32i    a4, a2, ROW_SNEXT
    retw
    .size   silica_rt_fill_row_from_spec, . - silica_rt_fill_row_from_spec

// ---------------------------------------------------------------------------------------------
// silica_rt_supervisor_materialize_init_children(X0 supervisor ACB, X1 init result tuple): called by
// the per-supervisor start trampoline on the supervisor's first schedule. The tuple holds the
// supervisor_flags record (a pointer in slot 0, or the three fields flat in slots 0-2 for older
// shapes) and the child-spec list handle (slot 1, or slot 3 in the flat shape).
    .align  4
    .global silica_rt_supervisor_materialize_init_children
    .type   silica_rt_supervisor_materialize_init_children, @function
silica_rt_supervisor_materialize_init_children:
    entry   a1, 64
    mov     a6, a2                      // a6 = supervisor
    movi    a8, 0
    s32i    a8, a1, 4                   // [4] the flags record, [8] the list handle: released at 9
    s32i    a8, a1, 8
    mov     a10, a6
    call8   silica_rt_sb_require
    s32i    a10, a1, 12                 // [12] the supervision block
    mov     a10, a6
    call8   silica_rt_child_table_enter
    beqz    a4, 9f
    l32i    a9, a1, 12
    l32i    a5, a4, 0
    movi    a8, 4096
    bltu    a5, a8, 1f
    // slot 0 is the flags record (shape word at 0, fields from 8)
    s32i    a5, a1, 4
    l32i    a8, a5, 8
    s32i    a8, a9, SB_STRATEGY
    l32i    a8, a5, 16
    s32i    a8, a9, SB_ALLOWED
    l32i    a8, a5, 24
    s32i    a8, a9, SB_TIMEFRAME
    l32i    a7, a4, 8                   // a7 = list handle
    j       2f
1:  s32i    a5, a9, SB_STRATEGY
    l32i    a8, a4, 8
    s32i    a8, a9, SB_ALLOWED
    l32i    a8, a4, 16
    s32i    a8, a9, SB_TIMEFRAME
    l32i    a7, a4, 24
2:  s32i    a7, a1, 8
    beqz    a7, 9f
    l32i    a2, a7, 0                   // a2 = remaining count
    l32i    a3, a7, 8                   // a3 = chunk
    l32i    a4, a7, 16                  // a4 = cursor (first chunk only)
3:  beqz    a2, 9f
    beqz    a3, 9f
    add     a5, a3, a4                  // a5 = the spec in this cell
    s32i    a5, a1, 0
    mov     a10, a6
    call8   silica_rt_child_table_append_row
    mov     a7, a10                     // a7 = row
    mov     a10, a7
    l32i    a11, a1, 0
    call8   silica_rt_fill_row_from_spec
    // §20.3.1: a child whose id a live actor or supervisor already holds is not started, and init
    // fails with :language_error (the supervisor is the running actor while its trampoline runs).
    l32i    a10, a7, ROW_ID
    call8   silica_rt_registry_name_held
    beqz    a10, 4f
    mov     a10, a6
    call8   silica_rt_child_table_leave
    call8   silica_rt_registry_name_taken
4:  mov     a10, a7
    mov     a11, a6
    call8   silica_rt_supervisor_spawn_child_row_by_flavor
    l32i    a9, a1, 12
    l32i    a8, a9, SB_CT_LEN
    addi    a8, a8, 1
    s32i    a8, a9, SB_CT_LEN
    l32i    a3, a3, SPEC_LIST_CHUNK      // next chunk (one cell per chunk)
    movi    a4, 0
    addi    a2, a2, -1
    j       3b
9:  mov     a10, a6
    l32i    a11, a1, 4
    l32i    a12, a1, 8
    call8   silica_rt_init_result_release
    movi    a2, 0
    movi    a3, 0
    mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
    .size   silica_rt_supervisor_materialize_init_children, . - silica_rt_supervisor_materialize_init_children

// silica_rt_init_result_release(sup, flags record, child-spec list handle): the init result has been
// copied into the supervisor's ACB and rows, so the blocks that carried it go back to the heap: the
// list's chunks (one spec cell each, the next chunk at SPEC_LIST_CHUNK), its handle and the flags
// record. The spec's composite initial state is NOT among them: it is a separate block (every spec
// field is one word, composites boxed) that the row keeps for restarts (ROW_INIT), and
// silica_rt_state_release guards it the same way. A value `init` returned belongs to its caller
// (spec §12.1.2), the start trampoline, whose scope ends with this call; what the runtime cannot see
// is a list that shares memory with something that outlives the call -- a handle, or a chunk through
// a copy-on-write prepend, that `init` also reached from the supervisor's own initial state or from a
// child's composite initial state. So the release follows silica_rt_state_release's ownership rule:
// nothing is freed when any of those owner blocks reaches the handle or one of the chunks (four
// levels down, as there). Each spec list `init` builds was leaked before this, about a kilobyte for
// ten specs on every supervisor start and restart (actor_memory_budget_plan.md item A, §13).
    .align  4
    .global silica_rt_init_result_release
    .type   silica_rt_init_result_release, @function
silica_rt_init_result_release:
    entry   a1, 48
    mov     a6, a2                      // a6 = supervisor
    mov     a7, a3                      // a7 = flags record (0: flat shape, none)
    mov     a5, a4                      // a5 = list handle (0: none)
    beqz    a7, 1f
    mov     a10, a6
    mov     a11, a7
    call8   silica_rt_init_owners_reach
    bnez    a10, 9f
1:  beqz    a5, 4f
    mov     a10, a6
    mov     a11, a5
    call8   silica_rt_init_owners_reach
    bnez    a10, 9f
    l32i    a8, a5, 8                   // the chunks, in list order
2:  beqz    a8, 3f
    s32i    a8, a1, 0
    mov     a10, a6
    mov     a11, a8
    call8   silica_rt_init_owners_reach
    bnez    a10, 9f
    l32i    a8, a1, 0
    l32i    a8, a8, SPEC_LIST_CHUNK
    j       2b
3:  l32i    a8, a5, 8                   // nothing outside reaches the list: free chunks, then the handle
5:  beqz    a8, 6f
    l32i    a9, a8, SPEC_LIST_CHUNK
    s32i    a9, a1, 0
    mov     a10, a8
    call8   silica_rt_free
    l32i    a8, a1, 0
    j       5b
6:  mov     a10, a5
    call8   silica_rt_free
4:  beqz    a7, 9f
    mov     a10, a7
    call8   silica_rt_free
9:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_init_result_release, . - silica_rt_init_result_release

// silica_rt_init_owners_reach(sup, block) -> 1 when the supervisor's own initial state (ACB_STATE,
// when it is a heap block) or a row's composite initial state (ROW_INIT with ROW_INIT_BYTES set)
// reaches `block` within four levels (rt_heap.S silica_rt_heap_reaches). Walks the rows inside the
// caller's child_table_enter bracket.
    .align  4
    .global silica_rt_init_owners_reach
    .type   silica_rt_init_owners_reach, @function
silica_rt_init_owners_reach:
    entry   a1, 48
    mov     a6, a2                      // a6 = supervisor
    mov     a7, a3                      // a7 = block
    l32i    a4, a6, ACB_STATE
    mov     a10, a7
    mov     a11, a4
    movi    a12, 0
    movi    a13, 4
    call8   silica_rt_heap_reaches
    bnez    a10, 8f
    l32i    a5, a6, ACB_SB
    beqz    a5, 9f
    l32i    a5, a5, SB_CT_HEAD
1:  beqz    a5, 9f
    l32i    a4, a5, ROW_INIT_BYTES
    beqz    a4, 2f
    s32i    a5, a1, 0
    mov     a10, a7
    l32i    a11, a5, ROW_INIT
    mov     a12, a4
    movi    a13, 4
    call8   silica_rt_heap_reaches
    l32i    a5, a1, 0
    bnez    a10, 8f
2:  l32i    a5, a5, ROW_NEXT
    j       1b
8:  movi    a2, 1
    movi    a3, 0
    retw
9:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_init_owners_reach, . - silica_rt_init_owners_reach

// silica_rt_supervisor_start_child_in(sup, spec) -> child: reuse the first tombstone row or append.
    .align  4
silica_rt_supervisor_start_child_in:
    entry   a1, 48
    mov     a6, a2                      // a6 = sup
    mov     a7, a3                      // a7 = spec
    mov     a10, a6
    call8   silica_rt_sb_require        // the running actor becomes a supervisor if it was not one
    s32i    a10, a1, 0                  // [0] the supervision block
    mov     a10, a6
    call8   silica_rt_child_table_enter
    l32i    a4, a1, 0
    l32i    a4, a4, SB_CT_HEAD
    movi    a5, 0                       // a5 = appended flag
1:  beqz    a4, 2f
    l32i    a8, a4, ROW_CHILD
    beqz    a8, 3f
    l32i    a4, a4, ROW_NEXT
    j       1b
2:  mov     a10, a6
    call8   silica_rt_child_table_append_row
    mov     a4, a10
    movi    a5, 1
3:  mov     a10, a4
    mov     a11, a7
    call8   silica_rt_fill_row_from_spec
    // §20.3.1: an id a live actor or supervisor already holds is not started (child 0; the row is a
    // tombstone the next start reuses).
    l32i    a10, a4, ROW_ID
    call8   silica_rt_registry_name_held
    beqz    a10, 4f
    movi    a10, 0
    j       5f
4:  mov     a10, a4
    mov     a11, a6
    call8   silica_rt_supervisor_spawn_child_row_by_flavor
    beqz    a10, 5f
    mov     a10, a4                     // the answer is the child's identity (§15.1.4)
5:  call8   silica_rt_row_child_ref
    mov     a2, a10
    s32i    a11, a1, 4
    beqz    a5, 9f
    l32i    a9, a1, 0
    l32i    a8, a9, SB_CT_LEN
    addi    a8, a8, 1
    s32i    a8, a9, SB_CT_LEN
9:  l32i    a3, a1, 4
    mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
    .size   silica_rt_supervisor_start_child_in, . - silica_rt_supervisor_start_child_in

// silica_rt_supervisor_start_child(X0 spec) -> child, in the running supervisor
    .align  4
    .global silica_rt_supervisor_start_child
    .type   silica_rt_supervisor_start_child, @function
silica_rt_supervisor_start_child:
    entry   a1, 32
    mov     a6, a2
    call8   silica_rt_current_actor
    beqz    a10, 9f
    mov     a11, a6
    call8   silica_rt_supervisor_start_child_in
    mov     a2, a10
    mov     a3, a11
    retw
9:  movi    a2, -1
    movi    a3, -1
    retw
    .size   silica_rt_supervisor_start_child, . - silica_rt_supervisor_start_child

// silica_rt_supervisor_add_child(X0 sup, X1 spec) -> child (call_supervisor :add_child)
    .align  4
    .global silica_rt_supervisor_add_child
    .type   silica_rt_supervisor_add_child, @function
silica_rt_supervisor_add_child:
    entry   a1, 32
    mov     a10, a2                     // X0 = the supervisor's reference (§15.1.4)
    mov     a11, a3
    call8   silica_rt_sup_acb
    mov     a2, a10
    movi    a3, 0
    mov     a6, a2
    mov     a7, a4
    mov     a10, a6
    call8   silica_rt_supervisor_drain_ingress
    // §20.3.1: an id a live actor or supervisor already holds starts no child; the actor that
    // asked for the add fails with (:explicit, :duplicate_child_id) (silica_rt_duplicate_child_id)
    l32i    a10, a7, SPEC_ID
    call8   silica_rt_registry_name_held
    beqz    a10, 1f
    call8   silica_rt_duplicate_child_id
1:  mov     a10, a6
    mov     a11, a7
    call8   silica_rt_supervisor_start_child_in
    mov     a2, a10
    mov     a3, a11
    retw
    .size   silica_rt_supervisor_add_child, . - silica_rt_supervisor_add_child

// silica_rt_duplicate_child_id(): call_supervisor :add_child named a child id a live actor or
// supervisor already holds (§20.3.1). No child is started; the running actor fails with
// failure_reason (:explicit, :duplicate_child_id); in main it is the language-level failure of
// §15.4.5.5: the atom's name on the console, exit status 1. Never returns.
    .align  4
silica_rt_duplicate_child_id:
    entry   a1, 32
    call8   silica_rt_current_actor
    beqz    a10, 1f
    movi    a10, silica_registry_atom_duplicate_child_id
    l32i    a10, a10, 0
    call8   silica_rt_actor_trap_explicit
1:  movi    a10, silica_rt_duplicate_child_id_msg
    call8   silica_rt_main_fail_exit    // rt_actors.S: the name, the pending reports, status 1
    j       1b
    .size   silica_rt_duplicate_child_id, . - silica_rt_duplicate_child_id

// silica_rt_supervisor_fail_duplicate_child_id(sup): a restart found the child's name held by
// another live actor or supervisor (§20.3.1). The supervisor fails with failure_reason
// (:explicit, :duplicate_child_id), tag 4, the way a restart-intensity breach ends it
// (maybe_restart 7:): a root supervisor reports its own failure here, claiming the supervision
// block's sync_failure_reported so its exit path does not report again, and the root note follows;
// then silica_rt_end_actor ends it (a parked supervisor ends at once, in this context; a
// supervised one delivers the exit, carrying this reason, to its parent).
    .align  4
silica_rt_supervisor_fail_duplicate_child_id:
    entry   a1, 32
    mov     a6, a2
    movi    a8, silica_registry_atom_duplicate_child_id
    l32i    a8, a8, 0
    s16i    a8, a6, ACB_REASON_ATOM
    movi    a8, 4
    s8i     a8, a6, ACB_REASON_TAG
    call8   silica_rt_current_actor     // decided in a caller's context: it ends in its own
    beq     a10, a6, 2f                 // (maybe_restart 7:)
    mov     a10, a6
    call8   silica_rt_sup_end_elsewhere
    j       3f
2:  l32i    a8, a6, ACB_SUP
    bnez    a8, 1f
    l32i    a9, a6, ACB_SB
    beqz    a9, 1f
    l32i    a8, a9, SB_SYNC_REPORTED
    bnez    a8, 1f
    movi    a8, 1
    s32i    a8, a9, SB_SYNC_REPORTED
    mov     a10, a6                     // its children first, so their reports precede its own
    call8   silica_rt_sup_shutdown_children
    mov     a10, a6
    call8   silica_rt_root_report_and_note
1:  mov     a10, a6
    movi    a11, 4
    call8   silica_rt_end_actor
3:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_supervisor_fail_duplicate_child_id, . - silica_rt_supervisor_fail_duplicate_child_id

// silica_rt_sup_end_elsewhere(sup): a supervisor whose end is decided outside its own context (its
// restart logic run by a drain on a caller's behalf) ends in its own: it is marked ended and, when
// parked, queued, so its core's scheduler runs its exit path (rt_actors.S silica_rt_sched_loop),
// which shuts its children down (silica_rt_sup_shutdown_children) and reports. Ending it in the
// caller's context instead would shut the children down there, and the caller, a child itself in
// the middle of a dispatch, could only be skipped: it would outlive its supervisor. A supervisor
// running on the other core ends at its next dispatch boundary.
    .align  4
silica_rt_sup_end_elsewhere:
    entry   a1, 32
    SCHED_LOCK a8, a9
    movi    a4, 0
    s8i     a4, a2, ACB_ALIVE
    mov     a10, a2
    call8   silica_rt_make_ready
    mov     a10, a2
    call8   silica_rt_wake
    SCHED_UNLOCK a8, a9
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_sup_end_elsewhere, . - silica_rt_sup_end_elsewhere

// silica_rt_supervisor_respawn_row(row, sup) -> 0 when the row's child was started, 1 when the
// row's id is held by a live actor or supervisor: no child is started under a name it does not
// hold, the row is released (a tombstone) and the supervisor has failed (above). Every restart
// path respawns through this; the first start of a child keeps its own rule (materialize,
// start_child_in). Internal convention: a2 row, a3 supervisor.
    .align  4
silica_rt_supervisor_respawn_row:
    entry   a1, 32
    mov     a6, a2
    mov     a7, a3
    l32i    a10, a6, ROW_ID
    call8   silica_rt_registry_name_held
    beqz    a10, 1f
    mov     a10, a6
    call8   silica_rt_row_release_child
    mov     a10, a7
    call8   silica_rt_supervisor_fail_duplicate_child_id
    movi    a2, 1
    movi    a3, 0
    retw
1:  mov     a10, a6
    mov     a11, a7
    call8   silica_rt_supervisor_spawn_child_row_by_flavor
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_supervisor_respawn_row, . - silica_rt_supervisor_respawn_row

// ---------------------------------------------------------------------------------------------
// Exit notices

// silica_rt_supervisor_drain_ingress(sup): every structured exit notice waiting in the supervisor's
// ingress runs the restart logic now, in the caller's context.
    .align  4
    .global silica_rt_supervisor_drain_ingress
    .type   silica_rt_supervisor_drain_ingress, @function
silica_rt_supervisor_drain_ingress:
    entry   a1, 32
    mov     a6, a2
    bnez    a6, 0f
    movi    a2, 0                       // no supervisor: nothing to drain (a 9f here would land
    movi    a3, 0                       // in SCHED_LOCK's own local 9:)
    retw
0:  mov     a10, a6
    call8   silica_rt_child_table_enter
    l32i    a5, a6, ACB_SB
    beqz    a5, 7f                      // no supervision block: nothing was ever delivered
1:  SCHED_LOCK a8, a9
    l32i    a5, a6, ACB_SB              // a5 = the block (a7 and a5 are reused below)
    l32i    a7, a5, SB_IN_HEAD
    beqz    a7, 8f
    l32i    a4, a7, MSG_NEXT
    s32i    a4, a5, SB_IN_HEAD
    bnez    a4, 2f
    s32i    a4, a5, SB_IN_TAIL
2:  l32i    a4, a5, SB_IN_DEPTH
    beqz    a4, 3f
    addi    a4, a4, -1
    s32i    a4, a5, SB_IN_DEPTH
3:  SCHED_UNLOCK a8, a9
    l32i    a4, a7, MSG_INGRESS_KIND
    bnez    a4, 4f
    l32i    a5, a7, MSG_PAYLOAD
    beqz    a5, 4f
    l32i    a10, a5, 0
    mov     a11, a6
    l32i    a12, a5, 8
    call8   silica_rt_supervisor_maybe_restart
    mov     a12, a10                    // the row the notice was matched to (0: none)
    mov     a13, a11                    // 1 when its child was restarted
    mov     a10, a6
    mov     a11, a5
    call8   silica_rt_sup_exit_report   // to the sink, if one is named (spec §15.4.10.5)
    mov     a10, a5
    call8   silica_rt_exit_payload_free
4:  mov     a10, a7
    call8   silica_rt_free_node
    j       1b
8:  SCHED_UNLOCK a8, a9
7:
9:  movi    a2, 0
    movi    a3, 0
    mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
    .size   silica_rt_supervisor_drain_ingress, . - silica_rt_supervisor_drain_ingress

// silica_rt_supervisor_drop_pending_exit(sup, child): remove the exit notice a deliberately stopped
// child left in the supervisor's ingress, so no restart follows.
    .align  4
silica_rt_supervisor_drop_pending_exit:
    entry   a1, 32
    SCHED_LOCK a8, a9
    l32i    a2, a2, ACB_SB              // a2 = the supervision block
    beqz    a2, 8f
    addi    a4, a2, SB_IN_HEAD          // a4 = &link to the current node
    l32i    a5, a4, 0
1:  beqz    a5, 8f
    l32i    a6, a5, MSG_INGRESS_KIND
    bnez    a6, 2f
    l32i    a6, a5, MSG_PAYLOAD
    beqz    a6, 2f
    l32i    a7, a6, 0
    beq     a7, a3, 3f
2:  addi    a4, a5, MSG_NEXT
    l32i    a5, a5, MSG_NEXT
    j       1b
3:  l32i    a7, a5, MSG_NEXT
    s32i    a7, a4, 0
    bnez    a7, 4f
    // the removed node was the tail: the tail is the node whose link we rewrote (or none)
    addi    a7, a2, SB_IN_HEAD
    beq     a4, a7, 31f
    addi    a7, a4, -MSG_NEXT
    s32i    a7, a2, SB_IN_TAIL
    j       4f
31: movi    a7, 0
    s32i    a7, a2, SB_IN_TAIL
4:  l32i    a7, a2, SB_IN_DEPTH
    beqz    a7, 5f
    addi    a7, a7, -1
    s32i    a7, a2, SB_IN_DEPTH
5:  SCHED_UNLOCK a8, a9
    mov     a10, a6
    call8   silica_rt_exit_payload_free
    mov     a10, a5
    call8   silica_rt_free_node
    retw
8:  SCHED_UNLOCK a8, a9
    retw
    .size   silica_rt_supervisor_drop_pending_exit, . - silica_rt_supervisor_drop_pending_exit

// silica_rt_sup_shutdown_children(sup): the coordinated shutdown of an ending supervisor's live
// children (spec §15.4.8.4, §15.4.12.2), called by its exit path (rt_actors.S silica_rt_actor_exit)
// and, for a root supervisor that fails by itself, before its report. The subtree is ended deepest
// first, one child at a time: each round finds, under the scheduler lock, the last live row of the
// deepest supervisor below sup that still has one (a child supervisor with live children of its own
// is descended into, not ended), marks that row stopping (its supervisor's restart logic leaves it
// alone), ends its child and waits for the child's exit_done stamp, then settles the row (a
// tombstone). A child with shutdown 0 is killed (reason tag 1, as kill_abnormal); one with
// shutdown > 0 ends with (:explicit, :shutdown). A parked child ends at once in this context; one
// running on the other core ends at its next dispatch boundary (the shutdown time is not enforced:
// nothing is preempted). The child is ended through silica_rt_end_actor_leaf, whose exit path does
// not shut down children again (it has none left), so no exit path nests in another and
// main_stack_bound.py still bounds main's stack. By the time this returns every child's name is
// free (§20.3.1), so a restarted supervisor registers its children again. The running actor itself
// is never chosen. A row is used outside the lock only while its table is entered (SB_CT_USERS,
// silica_rt_child_table_leave), as the other walkers do. Frame: [a1+0] the running actor.
    .align  4
    .global silica_rt_sup_shutdown_children
    .type   silica_rt_sup_shutdown_children, @function
silica_rt_sup_shutdown_children:
    entry   a1, 48
    l32i    a3, a2, ACB_SB
    beqz    a3, 7f
    call8   silica_rt_current_actor
    s32i    a10, a1, 0
10: SCHED_LOCK a8, a9
    mov     a4, a2                      // a4 = the supervisor whose table is searched
11: l32i    a3, a4, ACB_SB
    beqz    a3, 15f
    l32i    a3, a3, SB_CT_HEAD
    movi    a5, 0                       // a5 = its last live row
12: beqz    a3, 13f
    l32i    a7, a3, ROW_CHILD
    beqz    a7, 121f
    l32i    a8, a1, 0
    beq     a7, a8, 121f
    l32i    a8, a3, ROW_EXIT_DONE       // ended, not yet settled: nothing to wait for
    bnez    a8, 121f
    mov     a5, a3
121: l32i   a3, a3, ROW_NEXT
    j       12b
13: beqz    a5, 15f
    mov     a6, a5                      // a6 = the row
    l32i    a3, a5, ROW_CHILD           // a3 = its child
    l8ui    a8, a3, ACB_ALIVE
    beqz    a8, 14f
    l32i    a8, a3, ACB_SB
    beqz    a8, 14f
    l32i    a8, a8, SB_CT_HEAD          // a child supervisor with a live row: descend
    l32i    a9, a1, 0                   // (a9 is free while the lock is held)
131: beqz   a8, 14f
    l32i    a7, a8, ROW_CHILD
    beqz    a7, 132f
    beq     a7, a9, 132f
    l32i    a7, a8, ROW_EXIT_DONE
    beqz    a7, 133f
132: l32i   a8, a8, ROW_NEXT
    j       131b
133: mov    a4, a3
    j       11b
14: l32i    a3, a4, ACB_SB              // the row's table is entered while it is used unlocked
    l32i    a8, a3, SB_CT_USERS
    addi    a8, a8, 1
    s32i    a8, a3, SB_CT_USERS
    movi    a8, 1
    s32i    a8, a6, ROW_STOPPING
    SCHED_UNLOCK a8, a9
    j       20f
15: beq     a4, a2, 16f                 // the supervisor itself has no live row: done
    SCHED_UNLOCK a8, a9                 // a child's last row went meanwhile: search again
    j       10b
16: SCHED_UNLOCK a8, a9
    j       7f
20: l32i    a10, a6, ROW_CID
    l32i    a11, a6, ROW_CID + 4
    call8   silica_rt_ref_acb
    mov     a5, a10                     // a5 = the child, if it is not yet recycled
    beqz    a5, 22f
    l8ui    a8, a5, ACB_KIND
    bnez    a8, 23f
    movi    a7, 4                       // shutdown 0 (or negative): killed, (:explicit, :killed)
    l32i    a8, a6, ROW_SHUTDOWN + 4
    bltz    a8, 213f
    bnez    a8, 211f
    l32i    a8, a6, ROW_SHUTDOWN
    beqz    a8, 213f
211: SCHED_LOCK a8, a9                  // shutdown > 0: (:explicit, :shutdown) unless it has a reason
    l8ui    a3, a5, ACB_ALIVE
    beqz    a3, 212f
    l8ui    a3, a5, ACB_REASON_TAG
    bnez    a3, 212f
    movi    a3, silica_registry_atom_shutdown
    l32i    a3, a3, 0
    s16i    a3, a5, ACB_REASON_ATOM
212: SCHED_UNLOCK a8, a9
    movi    a7, 4
    j       21f
213: SCHED_LOCK a8, a9                  // shutdown 0: (:explicit, :killed) unless it has a reason
    l8ui    a3, a5, ACB_ALIVE
    beqz    a3, 214f
    l8ui    a3, a5, ACB_REASON_TAG
    bnez    a3, 214f
    movi    a3, silica_registry_atom_killed
    l32i    a3, a3, 0
    s16i    a3, a5, ACB_REASON_ATOM
214: SCHED_UNLOCK a8, a9
21: mov     a10, a5
    mov     a11, a7
    call8   silica_rt_end_actor_leaf
22: l32i    a8, a6, ROW_EXIT_DONE       // its exit path's last stamp (or the row was settled by
    bnez    a8, 23f                     // another shutdown of the same subtree)
    l32i    a8, a6, ROW_CHILD
    beqz    a8, 23f
    memw
    j       22b
23: mov     a10, a6
    call8   silica_rt_row_release_child
    mov     a10, a4
    call8   silica_rt_child_table_leave
    j       10b
7:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_sup_shutdown_children, . - silica_rt_sup_shutdown_children

// silica_rt_supervisor_stop_child(sup, row): end the child in a row and wait until it is gone
// (spec §15.4.12.2 sequential stop); its exit notice is dropped and the flag cleared. The row is
// marked stopping first: the child's exit notice reaches the supervisor's ingress, and when this
// runs in a caller's context (the call_supervisor prims do) the supervisor's own loop may serve
// that notice on the other core before the caller settles the row; the mark makes maybe_restart
// leave the row alone, so the row is restarted or tombstoned once, by the caller, and never
// respawned under a child still exiting. The mark stays until the row is settled
// (silica_rt_row_release_child), so a notice served late changes nothing either.
    .align  4
silica_rt_supervisor_stop_child:
    entry   a1, 32
    l32i    a4, a3, ROW_CHILD
    beqz    a4, 9f
    movi    a5, 1
    s32i    a5, a3, ROW_STOPPING
    memw
    mov     a10, a4
    movi    a11, 0
    call8   silica_rt_end_actor
1:  l32i    a5, a3, ROW_EXIT_DONE
    bnez    a5, 2f
    memw
    j       1b
2:  mov     a10, a2
    mov     a11, a4
    call8   silica_rt_supervisor_drop_pending_exit
    movi    a5, 0
    s32i    a5, a3, ROW_EXIT_DONE
9:  retw
    .size   silica_rt_supervisor_stop_child, . - silica_rt_supervisor_stop_child

// ---------------------------------------------------------------------------------------------
// silica_rt_supervisor_maybe_restart(dead child, supervisor, reason tag): the restart
// decision (§15.4.12). Restart policy: :permanent always, :transient only after an abnormal exit,
// anything else tombstones the row. Frequency cap: allowed_restart_count within
// restarts_time_frame seconds (both 0 = unlimited; allowed 0 with a frame = no restarts); a breach
// ends the supervisor (a root supervisor reports first). Strategy: :one_for_one respawns the row,
// :one_for_all stops the other live children then respawns every row, :rest_for_one stops the
// children after the dead one then respawns from it on.
// Returns X0 = the row the notice was matched to (0: no row, or the supervisor has ended) and X1 = 1
// when that row's child was restarted: what the exit report of §15.4.10.5 is built from
// (silica_rt_sup_exit_report, called by every handler of a notice right after this).
    .align  4
    .global silica_rt_supervisor_maybe_restart
    .type   silica_rt_supervisor_maybe_restart, @function
silica_rt_supervisor_maybe_restart:
    entry   a1, 64
    // internal convention: a2 child, a3 supervisor, a4 reason tag (callers pass a10-a12)
    s32i    a4, a1, 0                   // reason tag
    mov     a6, a3                      // a6 = supervisor
    l32i    a7, a6, ACB_SB              // [4] its supervision block (none: not a supervisor)
    beqz    a7, 9f
    l8ui    a8, a6, ACB_ALIVE           // an ended supervisor restarts and tombstones nothing: its
    beqz    a8, 9f                      // children are being shut down (silica_rt_sup_shutdown_children)
    s32i    a7, a1, 4
    l32i    a7, a7, SB_CT_HEAD          // a7 = row
    movi    a5, 0                       // a5 = row index
1:  beqz    a7, 9f
    l32i    a4, a7, ROW_CHILD
    beq     a4, a2, 2f
    l32i    a7, a7, ROW_NEXT
    addi    a5, a5, 1
    j       1b
2:  // a row being stopped by a caller is that caller's to settle (stop_child above)
    l32i    a4, a7, ROW_STOPPING
    bnez    a4, 9f
    // policy
    l32i    a4, a7, ROW_RESTART
    movi    a8, ATOM_PERMANENT
    beq     a4, a8, 3f
    movi    a8, ATOM_TRANSIENT
    bne     a4, a8, 8f
    l32i    a4, a1, 0
    beqz    a4, 8f
3:  // frequency cap (a9 = the supervision block, reloaded after every call)
    l32i    a9, a1, 4
    l32i    a3, a9, SB_ALLOWED
    l32i    a4, a9, SB_TIMEFRAME
    or      a8, a3, a4
    beqz    a8, 4f
    beqz    a3, 7f
    call8   silica_rt_now_seconds
    addi    a2, a10, 1                  // a2 = now + 1 (0 marks "no window yet")
    l32i    a9, a1, 4
    l32i    a8, a9, SB_WINDOW
    beqz    a8, 31f
    sub     a8, a2, a8
    bltu    a4, a8, 31f                 // outside the window: start a new one
    l32i    a8, a9, SB_RESTARTS
    addi    a8, a8, 1
    bltu    a3, a8, 7f                  // count > allowed
    s32i    a8, a9, SB_RESTARTS
    j       4f
31: s32i    a2, a9, SB_WINDOW
    movi    a8, 1
    s32i    a8, a9, SB_RESTARTS
    bltu    a3, a8, 7f
4:  // strategy
    l32i    a9, a1, 4
    l32i    a4, a9, SB_STRATEGY
    movi    a8, ATOM_ONE_FOR_ALL
    beq     a4, a8, 5f
    movi    a8, ATOM_REST_FOR_ONE
    beq     a4, a8, 6f
    // every restart respawns through silica_rt_supervisor_respawn_row (§20.3.1: a name another
    // actor took since the child ended fails the supervisor instead; 1 ends the restart)
    mov     a10, a7
    mov     a11, a6
    call8   silica_rt_supervisor_respawn_row
    bnez    a10, 90f
    j       91f
5:  // one_for_all: stop every other live child, then respawn every row that has a child
    l32i    a3, a1, 4
    l32i    a3, a3, SB_CT_HEAD
51: beqz    a3, 52f
    beq     a3, a7, 511f
    l32i    a4, a3, ROW_CHILD
    beqz    a4, 511f
    mov     a10, a6
    mov     a11, a3
    call8   silica_rt_supervisor_stop_child
511: l32i   a3, a3, ROW_NEXT
    j       51b
52: l32i    a3, a1, 4
    l32i    a3, a3, SB_CT_HEAD
53: beqz    a3, 91f
    l32i    a4, a3, ROW_CHILD
    beqz    a4, 531f
    mov     a10, a3
    mov     a11, a6
    call8   silica_rt_supervisor_respawn_row
    bnez    a10, 90f
531: l32i   a3, a3, ROW_NEXT
    j       53b
6:  // rest_for_one: stop and tombstone the rows after the dead one, then respawn from it on
    l32i    a3, a7, ROW_NEXT
61: beqz    a3, 62f
    l32i    a4, a3, ROW_CHILD
    beqz    a4, 611f
    mov     a10, a6
    mov     a11, a3
    call8   silica_rt_supervisor_stop_child
    mov     a10, a3
    call8   silica_rt_row_release_child
611: l32i   a3, a3, ROW_NEXT
    j       61b
62: mov     a3, a7
63: beqz    a3, 91f
    mov     a10, a3
    mov     a11, a6
    call8   silica_rt_supervisor_respawn_row
    bnez    a10, 90f
    l32i    a3, a3, ROW_NEXT
    j       63b
7:  // cap breached: the supervisor ends abnormally (§15.4.13.2: it terminates, propagating the
    // failure), with failure_reason (:explicit, silica_registry_atom_restart_breach), tag 4, as
    // silica_rt_supervisor_fail_duplicate_child_id; its parent applies its own restart rules to it.
    // Decided in a caller's context (a drain on behalf of kill_abnormal or call_supervisor), it ends
    // in its own (silica_rt_sup_end_elsewhere): its exit there shuts every child down, the caller
    // included once its dispatch is done. A root supervisor reports its own failure first, after
    // its children are shut down.
    movi    a8, silica_registry_atom_restart_breach
    l32i    a8, a8, 0
    s16i    a8, a6, ACB_REASON_ATOM
    movi    a8, 4
    s8i     a8, a6, ACB_REASON_TAG
    call8   silica_rt_current_actor
    beq     a10, a6, 70f
    mov     a10, a6
    call8   silica_rt_sup_end_elsewhere
    j       90f
70: l32i    a8, a6, ACB_SUP
    bnez    a8, 71f
    l32i    a9, a1, 4
    l32i    a8, a9, SB_SYNC_REPORTED
    bnez    a8, 71f
    movi    a8, 1
    s32i    a8, a9, SB_SYNC_REPORTED
    movi    a8, 0
    s8i     a8, a6, ACB_ALIVE
    // its children are shut down before its report goes out, so their reports precede it (the
    // FailureReporter may end the program on the root's)
    mov     a10, a6
    call8   silica_rt_sup_shutdown_children
    mov     a10, a6
    call8   silica_rt_root_report_and_note
    // ACB_ALIVE is already 0 (cleared above so the shutdown restarts nothing): the running supervisor
    // takes its exit path at its dispatch boundary (rt_actors.S silica_rt_sched_loop); calling
    // silica_rt_end_actor here would only return at its "already ended" test.
    j       90f
71: mov     a10, a6
    movi    a11, 4
    call8   silica_rt_end_actor
    j       90f
8:  // no restart: tombstone
    mov     a10, a7
    call8   silica_rt_row_release_child
    j       90f
9:  movi    a2, 0                       // no row (not found, a row being stopped by a caller, an ended supervisor)
    movi    a3, 0
    retw
90: mov     a2, a7                      // the row: its child was not restarted (tombstoned, a breach, a failed respawn)
    movi    a3, 0
    retw
91: mov     a2, a7                      // the row: its child was restarted
    movi    a3, 1
    retw
    .size   silica_rt_supervisor_maybe_restart, . - silica_rt_supervisor_maybe_restart

// silica_rt_sup_exit_report(sup, payload, row, restarted): the exit report of spec §15.4.10.5, cast
// to the supervisor's report sink (SB_SINK: named by :set_report_sink, or inherited from the
// supervisor's own supervisor when it was spawned, rt_actors.S silica_rt_spawn_common) after every
// exit notice the restart logic has handled; nothing when the notice was matched to no row or no
// sink is named. The record is laid out as the emitter lays out
// { child: actor_ref, child_id: atom, failure_reason: ..., restarted: boolean, new_child: actor_ref }:
// a shape word (silica_registry_shape_exit_report, the image's number for that record; 0 when no unit
// spells it) and one 8-byte slot per field. failure_reason is the one-word sum of §15.4.11.2: the
// fixed atom for tags 0, 2 and 3, a pointer to the pair (:explicit, atom) for tag 4 (the pair sits
// in the record's own 64-byte block, at +48), and :unknown otherwise (since 2026-10-23 no exit carries
// tag 1: a division by zero is 2, a kill is 4 with :killed). child is the identity the notice
// carries (payload+40); new_child is the row's current child (ROW_CID) when restarted, else child.
// The cast owns the block (silica_rt_cast_try's X2 = 1): the receiver's dispatch frees it, as it
// frees any record copy a cast made, and a sink that has ended or is call-only gets nothing (the
// block goes back there). The supervisor never waits.
    .align  4
    .global silica_rt_sup_exit_report
    .type   silica_rt_sup_exit_report, @function
silica_rt_sup_exit_report:
    entry   a1, 48
    beqz    a4, 9f                      // no row: the notice was not handled as a child exit
    l32i    a6, a2, ACB_SB
    beqz    a6, 9f
    l32i    a7, a6, SB_SINK             // the sink's identity (0: none)
    l32i    a6, a6, SB_SINK + 4
    or      a8, a7, a6
    beqz    a8, 9f
    s32i    a7, a1, 0                   // [0]/[4] the sink
    s32i    a6, a1, 4
    s32i    a3, a1, 8                   // [8] the payload
    s32i    a4, a1, 12                  // [12] the row
    s32i    a5, a1, 16                  // [16] restarted
    movi    a10, 64                     // one block: the record (48 B) and, at +48, the pair
    call8   silica_rt_alloc             // (:explicit, atom) when the reason is one; zeroed
    mov     a6, a10                     // a6 = the record
    // the failure_reason word (§15.4.11.2)
    l32i    a3, a1, 8
    l32i    a8, a3, 8                   // the reason tag
    movi    a7, ATOM_NORMAL
    beqz    a8, 2f
    movi    a7, ATOM_LANGUAGE_ERROR
    beqi    a8, 2, 2f
    movi    a7, ATOM_MEMORY_FAULT
    beqi    a8, 3, 2f
    movi    a7, ATOM_UNKNOWN
    bnei    a8, 4, 2f
    movi    a8, ATOM_EXPLICIT           // (:explicit, atom): the pair at +48, one 8-byte slot each
    s32i    a8, a6, 48
    l32i    a8, a3, 16                  // the notice's atom
    s32i    a8, a6, 56
    addi    a7, a6, 48
2:  movi    a8, silica_registry_shape_exit_report
    l32i    a8, a8, 0
    s32i    a8, a6, 0                   // shape
    l32i    a8, a3, 40                  // child: the ended child's identity
    s32i    a8, a6, 8
    l32i    a8, a3, 44
    s32i    a8, a6, 12
    l32i    a4, a1, 12
    l32i    a8, a4, ROW_ID              // child_id
    s32i    a8, a6, 16
    s32i    a7, a6, 24                  // failure_reason
    l32i    a5, a1, 16                  // restarted
    s32i    a5, a6, 32
    l32i    a8, a3, 40                  // new_child: the ended child, or the row's current child
    l32i    a9, a3, 44
    beqz    a5, 3f
    l32i    a8, a4, ROW_CID
    l32i    a9, a4, ROW_CID + 4
3:  s32i    a8, a6, 40
    s32i    a9, a6, 44
    l32i    a10, a1, 0                  // cast to the sink, owned: the receiver's dispatch frees the
    l32i    a11, a1, 4                  // block (1 enqueued; else it went back in silica_rt_cast_try)
    mov     a12, a6
    movi    a13, 0
    movi    a14, 1
    call8   silica_rt_cast_try
9:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_sup_exit_report, . - silica_rt_sup_exit_report

// silica_rt_supervisor_set_report_sink(X0 the supervisor's reference, X1 the sink's reference) -> 0,
// or -2 (the error reply of the lowering, as for :terminate_child aimed at the caller's own row) when
// the sink names no live actor or a call-only one (spec §15.4.10.5: the sink is a cast-only actor;
// reports are casts). Exits already in the ingress are handled first (§15.4.9.4), before the sink is
// named, so they are not reported.
    .align  4
    .global silica_rt_supervisor_set_report_sink
    .type   silica_rt_supervisor_set_report_sink, @function
silica_rt_supervisor_set_report_sink:
    entry   a1, 48
    s32i    a4, a1, 0                   // [0]/[4] the sink's reference (§15.1.4)
    s32i    a5, a1, 4
    mov     a10, a2                     // X0 = the supervisor's reference (§15.1.4)
    mov     a11, a3
    call8   silica_rt_sup_acb
    mov     a6, a10                     // a6 = the supervisor
    mov     a10, a6
    call8   silica_rt_child_table_enter
    mov     a10, a6
    call8   silica_rt_supervisor_drain_ingress
    l32i    a10, a1, 0
    l32i    a11, a1, 4
    call8   silica_rt_ref_acb
    beqz    a10, 8f                     // no such actor
    l8ui    a4, a10, ACB_ALIVE
    beqz    a4, 8f                      // ended
    l32i    a4, a10, ACB_CONV
    beqi    a4, 1, 8f                   // call-only (§16.2.6.4)
    mov     a10, a6
    call8   silica_rt_sb_require
    l32i    a4, a1, 0
    s32i    a4, a10, SB_SINK
    l32i    a4, a1, 4
    s32i    a4, a10, SB_SINK + 4
    movi    a2, 0
    movi    a3, 0
    j       9f
8:  movi    a2, -2
    movi    a3, -1
9:  mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
    .size   silica_rt_supervisor_set_report_sink, . - silica_rt_supervisor_set_report_sink

// ---------------------------------------------------------------------------------------------
// Behaviour-only accessors (trials)

// silica_rt_child_table_first_ref() -> the running supervisor's first live child, or 0
    .align  4
    .global silica_rt_child_table_first_ref
    .type   silica_rt_child_table_first_ref, @function
silica_rt_child_table_first_ref:
    entry   a1, 32
    call8   silica_rt_current_actor
    movi    a4, 0
    beqz    a10, 9f
    l32i    a4, a10, ACB_SB
    beqz    a4, 9f
    l32i    a4, a4, SB_CT_HEAD
1:  beqz    a4, 9f
    l32i    a2, a4, ROW_CHILD
    bnez    a2, 9f
    l32i    a4, a4, ROW_NEXT
    j       1b
9:  mov     a10, a4                     // the row's child reference (§15.1.4), all ones for none
    call8   silica_rt_row_child_ref
    mov     a2, a10
    mov     a3, a11
    retw
    .size   silica_rt_child_table_first_ref, . - silica_rt_child_table_first_ref

// silica_rt_child_table_row_ref(X0 index) -> the child of that row (0 for a tombstone / no row)
    .align  4
    .global silica_rt_child_table_row_ref
    .type   silica_rt_child_table_row_ref, @function
silica_rt_child_table_row_ref:
    entry   a1, 32
    mov     a6, a2
    call8   silica_rt_current_actor
    movi    a2, 0
    movi    a3, 0
    beqz    a10, 9f
    bltz    a6, 9f
    l32i    a4, a10, ACB_SB
    beqz    a4, 9f
    l32i    a4, a4, SB_CT_LEN
    bgeu    a6, a4, 9f
    mov     a11, a6
    call8   silica_rt_child_table_row_at
    call8   silica_rt_row_child_ref     // the row's child reference (§15.1.4), all ones for none
    mov     a2, a10
    mov     a3, a11
    retw
9:  movi    a2, -1
    movi    a3, -1
    retw
    .size   silica_rt_child_table_row_ref, . - silica_rt_child_table_row_ref

// ---------------------------------------------------------------------------------------------
// call_supervisor helpers (the SIR generator lowers call_supervisor to these prims)

// silica_rt_supervisor_count_children(X0 sup) -> live rows
    .align  4
    .global silica_rt_supervisor_count_children
    .type   silica_rt_supervisor_count_children, @function
silica_rt_supervisor_count_children:
    entry   a1, 32
    mov     a10, a2                     // X0 = the supervisor's reference (§15.1.4)
    mov     a11, a3
    call8   silica_rt_sup_acb
    mov     a2, a10
    movi    a3, 0
    mov     a6, a2
    mov     a10, a6
    call8   silica_rt_child_table_enter
    mov     a10, a6
    call8   silica_rt_supervisor_drain_ingress
    movi    a2, 0
    movi    a3, 0
    l32i    a4, a6, ACB_SB
    beqz    a4, 9f
    l32i    a4, a4, SB_CT_HEAD
1:  beqz    a4, 9f
    l32i    a5, a4, ROW_CHILD
    beqz    a5, 2f
    addi    a2, a2, 1
2:  l32i    a4, a4, ROW_NEXT
    j       1b
9:  mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
    .size   silica_rt_supervisor_count_children, . - silica_rt_supervisor_count_children

// silica_rt_live_row_by_id(sup, id) -> row or 0
    .align  4
silica_rt_live_row_by_id:
    entry   a1, 32
    l32i    a4, a2, ACB_SB
    beqz    a4, 9f
    l32i    a4, a4, SB_CT_HEAD
1:  beqz    a4, 9f
    l32i    a5, a4, ROW_CHILD
    beqz    a5, 2f
    l32i    a5, a4, ROW_ID
    beq     a5, a3, 8f
2:  l32i    a4, a4, ROW_NEXT
    j       1b
8:  mov     a2, a4
    movi    a3, 0
    retw
9:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_live_row_by_id, . - silica_rt_live_row_by_id

// silica_rt_supervisor_get_child(X0 sup, X1 id) -> the live child the row with that id holds, or 0
// (spec §15.4.8.3: :get_child names the child by id; before 2026-10-12 the first live child was
// returned whatever the id, as the hosts did)
    .align  4
    .global silica_rt_supervisor_get_child
    .type   silica_rt_supervisor_get_child, @function
silica_rt_supervisor_get_child:
    entry   a1, 32
    mov     a10, a2                     // X0 = the supervisor's reference (§15.1.4)
    mov     a11, a3
    call8   silica_rt_sup_acb
    mov     a2, a10
    movi    a3, 0
    mov     a6, a2
    mov     a7, a4                      // requested id
    mov     a10, a6
    call8   silica_rt_child_table_enter
    mov     a10, a6
    call8   silica_rt_supervisor_drain_ingress
    mov     a10, a6
    mov     a11, a7
    call8   silica_rt_live_row_by_id
    call8   silica_rt_row_child_ref     // its identity (§15.1.4), all ones for none
    mov     a2, a10
    mov     a3, a11
    mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
    .size   silica_rt_supervisor_get_child, . - silica_rt_supervisor_get_child

// silica_rt_supervisor_get_child_info(X0 sup, X1 id) -> { id, agent_type, child, restart } (40 B: shape word, four slots)
    .align  4
    .global silica_rt_supervisor_get_child_info
    .type   silica_rt_supervisor_get_child_info, @function
silica_rt_supervisor_get_child_info:
    entry   a1, 32
    mov     a10, a2                     // X0 = the supervisor's reference (§15.1.4)
    mov     a11, a3
    call8   silica_rt_sup_acb
    mov     a2, a10
    movi    a3, 0
    mov     a6, a2
    mov     a7, a4                      // requested id
    mov     a10, a6
    call8   silica_rt_child_table_enter
    mov     a10, a6
    call8   silica_rt_supervisor_drain_ingress
    mov     a10, a6
    mov     a11, a7
    call8   silica_rt_live_row_by_id      // no live row with the id: an empty record
    mov     a5, a10
    movi    a10, 40
    call8   silica_rt_alloc
    mov     a2, a10
    movi    a3, 0
    movi    a4, SHAPE_CHILD_INFO
    s32i    a4, a2, 0
    movi    a4, -1                      // no child: the identity no actor has
    s32i    a4, a2, 24
    s32i    a4, a2, 28
    beqz    a5, 9f
    s32i    a7, a2, 8
    l32i    a4, a5, ROW_AGENT
    movi    a8, ATOM_UNKNOWN
    bne     a4, a8, 1f
    l32i    a4, a5, ROW_ID
1:  s32i    a4, a2, 16
    mov     a10, a5
    call8   silica_rt_row_child_ref     // the child's identity (§15.1.4)
    s32i    a10, a2, 24
    s32i    a11, a2, 28
    l32i    a4, a5, ROW_RESTART
    bnez    a4, 2f
    movi    a4, ATOM_PERMANENT
2:  s32i    a4, a2, 32
9:  mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
    .size   silica_rt_supervisor_get_child_info, . - silica_rt_supervisor_get_child_info

// silica_rt_supervisor_get_child_id / _agent_type / _restart (X0 sup, X1 id) -> the row's field, or 0
    .align  4
    .global silica_rt_supervisor_get_child_id
    .type   silica_rt_supervisor_get_child_id, @function
silica_rt_supervisor_get_child_id:
    entry   a1, 32
    mov     a10, a2                     // X0 = the supervisor's reference (§15.1.4)
    mov     a11, a3
    call8   silica_rt_sup_acb
    mov     a2, a10
    movi    a3, 0
    movi    a6, ROW_ID
    j       silica_rt_supervisor_row_field
    .size   silica_rt_supervisor_get_child_id, . - silica_rt_supervisor_get_child_id

    .align  4
    .global silica_rt_supervisor_get_child_agent_type
    .type   silica_rt_supervisor_get_child_agent_type, @function
silica_rt_supervisor_get_child_agent_type:
    entry   a1, 32
    mov     a10, a2                     // X0 = the supervisor's reference (§15.1.4)
    mov     a11, a3
    call8   silica_rt_sup_acb
    mov     a2, a10
    movi    a3, 0
    movi    a6, ROW_AGENT
    j       silica_rt_supervisor_row_field
    .size   silica_rt_supervisor_get_child_agent_type, . - silica_rt_supervisor_get_child_agent_type

    .align  4
    .global silica_rt_supervisor_get_child_restart
    .type   silica_rt_supervisor_get_child_restart, @function
silica_rt_supervisor_get_child_restart:
    entry   a1, 32
    mov     a10, a2                     // X0 = the supervisor's reference (§15.1.4)
    mov     a11, a3
    call8   silica_rt_sup_acb
    mov     a2, a10
    movi    a3, 0
    movi    a6, ROW_RESTART
    j       silica_rt_supervisor_row_field
    .size   silica_rt_supervisor_get_child_restart, . - silica_rt_supervisor_get_child_restart

// shared tail: a2 = sup, a4 = id, a6 = field offset (entered in the caller's window)
    .align  4
silica_rt_supervisor_row_field:
    mov     a7, a2
    mov     a10, a7
    call8   silica_rt_child_table_enter
    mov     a10, a7
    call8   silica_rt_supervisor_drain_ingress
    mov     a10, a7
    mov     a11, a4
    call8   silica_rt_live_row_by_id
    movi    a2, 0
    movi    a3, 0
    beqz    a10, 9f
    add     a10, a10, a6
    l32i    a2, a10, 0
9:  mov     a10, a7
    call8   silica_rt_child_table_leave
    retw
    .size   silica_rt_supervisor_row_field, . - silica_rt_supervisor_row_field

// silica_rt_supervisor_which_children(X0 sup) -> List[{ id, agent_type, child, restart }]: built the
// way the reference builds it, one 40-byte record (shape word, four slots) per 56-byte chunk
// (next chunk at 48), newest first.
    .align  4
    .global silica_rt_supervisor_which_children
    .type   silica_rt_supervisor_which_children, @function
silica_rt_supervisor_which_children:
    entry   a1, 32
    mov     a10, a2                     // X0 = the supervisor's reference (§15.1.4)
    mov     a11, a3
    call8   silica_rt_sup_acb
    mov     a2, a10
    movi    a3, 0
    mov     a6, a2
    mov     a10, a6
    call8   silica_rt_child_table_enter
    mov     a10, a6
    call8   silica_rt_supervisor_drain_ingress
    movi    a7, 0                       // a7 = list handle so far
    l32i    a5, a6, ACB_SB
    beqz    a5, 9f
    l32i    a5, a5, SB_CT_HEAD
1:  beqz    a5, 9f
    l32i    a4, a5, ROW_CHILD
    beqz    a4, 8f
    movi    a10, 56
    call8   silica_rt_alloc
    mov     a2, a10                     // a2 = chunk
    movi    a4, SHAPE_CHILD_INFO
    s32i    a4, a2, 0
    l32i    a4, a5, ROW_ID
    s32i    a4, a2, 8
    l32i    a4, a5, ROW_AGENT
    s32i    a4, a2, 16
    l32i    a4, a5, ROW_CID             // the child's identity (§15.1.4)
    s32i    a4, a2, 24
    l32i    a4, a5, ROW_CID + 4
    s32i    a4, a2, 28
    l32i    a4, a5, ROW_RESTART
    s32i    a4, a2, 32
    beqz    a7, 2f
    l32i    a4, a7, 8
    s32i    a4, a2, 48
2:  movi    a10, 24
    call8   silica_rt_alloc
    movi    a4, 1
    beqz    a7, 3f
    l32i    a4, a7, 0
    addi    a4, a4, 1
3:  s32i    a4, a10, 0
    s32i    a2, a10, 8
    mov     a7, a10
8:  l32i    a5, a5, ROW_NEXT
    j       1b
9:  mov     a2, a7
    movi    a3, 0
    mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
    .size   silica_rt_supervisor_which_children, . - silica_rt_supervisor_which_children

// silica_rt_supervisor_terminate_child / remove_child (X0 sup, X1 id) -> 0, or -2 when the running
// actor is a row child of this supervisor naming its own row: it would end itself and then wait,
// in silica_rt_supervisor_stop_child, for an exit only it can complete (the running actor ends
// after its behaviour returns, silica_rt_end_actor). The lowering turns -2 into the error reply
// (tag :error, error :language_error; silica_rt_sup_op_tag and its siblings below) and nothing
// is stopped. Main (no running actor), a sibling, an unrelated actor and the supervisor itself go
// on as before.
    .align  4
    .global silica_rt_supervisor_terminate_child
    .global silica_rt_supervisor_remove_child
    .type   silica_rt_supervisor_terminate_child, @function
silica_rt_supervisor_terminate_child:
silica_rt_supervisor_remove_child:
    entry   a1, 32
    mov     a10, a2                     // X0 = the supervisor's reference (§15.1.4)
    mov     a11, a3
    call8   silica_rt_sup_acb
    mov     a2, a10
    movi    a3, 0
    mov     a6, a2
    mov     a7, a4
    mov     a10, a6
    call8   silica_rt_child_table_enter
    mov     a10, a6
    mov     a11, a7
    call8   silica_rt_live_row_by_id
    beqz    a10, 1f
    mov     a5, a10
    call8   silica_rt_current_actor
    l32i    a4, a5, ROW_CHILD
    bne     a4, a10, 1f
    movi    a2, -2
    movi    a3, -1
    mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
1:  mov     a10, a6
    call8   silica_rt_supervisor_drain_ingress
    mov     a10, a6
    mov     a11, a7
    call8   silica_rt_live_row_by_id
    beqz    a10, 9f
    mov     a5, a10
    mov     a10, a6
    mov     a11, a5
    call8   silica_rt_supervisor_stop_child
    mov     a10, a5
    call8   silica_rt_row_release_child
9:  movi    a2, 0
    movi    a3, 0
    mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
    .size   silica_rt_supervisor_terminate_child, . - silica_rt_supervisor_terminate_child

// The reply fields of call_supervisor's :terminate_child / :remove_child / :restart_child
// (terms_actor_lowering build_call_supervisor_op_reply): the operation answers -2 when the asking
// actor is a row child of the supervisor naming its own row (above and below), and the reply is
// then the error shape (tag :error, status :error, error :language_error, child 0) instead of
// the operation's own. The atoms are the image's words (silica_rt_sup_error_tag, this build's
// :error or -1; silica_rt_sup_self_error_atom, :language_error), emitted with the registry words
// (emitter_core.silica xt_runtime_registry_words), so no program's atom table gains an atom.
// silica_rt_sup_op_tag(X0 = the operation's answer, X1 = the tag or status of the operation's
// own reply) -> X1, or this build's :error for the -2 answer.
    .align  4
    .global silica_rt_sup_op_tag
    .type   silica_rt_sup_op_tag, @function
silica_rt_sup_op_tag:
    entry   a1, 32
    movi    a6, -2
    bne     a2, a6, 1f
    movi    a6, -1
    bne     a3, a6, 1f
    movi    a6, silica_rt_sup_error_tag
    l32i    a4, a6, 0
    srai    a5, a4, 31
1:  mov     a2, a4
    mov     a3, a5
    retw
    .size   silica_rt_sup_op_tag, . - silica_rt_sup_op_tag

// silica_rt_sup_op_error(X0 = the answer, X1 = the error atom of the operation's own reply, :ok)
// -> X1, or :language_error for the -2 answer.
    .align  4
    .global silica_rt_sup_op_error
    .type   silica_rt_sup_op_error, @function
silica_rt_sup_op_error:
    entry   a1, 32
    movi    a6, -2
    bne     a2, a6, 1f
    movi    a6, -1
    bne     a3, a6, 1f
    movi    a6, silica_rt_sup_self_error_atom
    l32i    a4, a6, 0
    srai    a5, a4, 31
1:  mov     a2, a4
    mov     a3, a5
    retw
    .size   silica_rt_sup_op_error, . - silica_rt_sup_op_error

// silica_rt_sup_op_child(X0 = :restart_child's answer: the started child's identity, all ones for
// no child) -> the answer, or 0 (the error reply's child) for the -2 answer.
    .align  4
    .global silica_rt_sup_op_child
    .type   silica_rt_sup_op_child, @function
silica_rt_sup_op_child:
    entry   a1, 32
    movi    a6, -2
    bne     a2, a6, 1f
    movi    a6, -1
    bne     a3, a6, 1f
    movi    a2, 0
    movi    a3, 0
1:  retw
    .size   silica_rt_sup_op_child, . - silica_rt_sup_op_child

// silica_rt_supervisor_restart_child(X0 sup, X1 id) -> the restarted child (all ones when the id is
// unknown), or -2 when the running actor is a row child of this supervisor whose restart would stop
// its own row: its own id named or, under :one_for_all, any id a row bears (the group it is in is
// stopped and respawned). It would wait in silica_rt_supervisor_stop_child for an exit only it can
// complete (as terminate_child above); the lowering turns -2 into the error reply and nothing is
// stopped.
    .align  4
    .global silica_rt_supervisor_restart_child
    .type   silica_rt_supervisor_restart_child, @function
silica_rt_supervisor_restart_child:
    entry   a1, 48
    mov     a10, a2                     // X0 = the supervisor's reference (§15.1.4)
    mov     a11, a3
    call8   silica_rt_sup_acb
    mov     a2, a10
    movi    a3, 0
    mov     a6, a2
    mov     a7, a4
    mov     a10, a6
    call8   silica_rt_child_table_enter
    // the self check: the row of this supervisor whose child is the running actor, if any
    call8   silica_rt_current_actor
    beqz    a10, 4f
    mov     a4, a10
    l32i    a5, a6, ACB_SB
    beqz    a5, 4f
    l32i    a5, a5, SB_CT_HEAD
41: beqz    a5, 4f
    l32i    a8, a5, ROW_CHILD
    beq     a8, a4, 42f
    l32i    a5, a5, ROW_NEXT
    j       41b
42: l32i    a8, a5, ROW_ID               // its own id, or under :one_for_all any id a row bears
    beq     a8, a7, 7f
    l32i    a8, a6, ACB_SB
    l32i    a8, a8, SB_STRATEGY
    movi    a9, ATOM_ONE_FOR_ALL
    bne     a8, a9, 4f
    l32i    a5, a6, ACB_SB
    l32i    a5, a5, SB_CT_HEAD
43: beqz    a5, 4f
    l32i    a8, a5, ROW_ID
    beq     a8, a7, 7f
    l32i    a5, a5, ROW_NEXT
    j       43b
7:  movi    a2, -2
    movi    a3, -1
    mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
4:  mov     a10, a6
    call8   silica_rt_supervisor_drain_ingress
    // the row with this id, live or tombstoned
    l32i    a5, a6, ACB_SB
    beqz    a5, 9f
    l32i    a5, a5, SB_CT_HEAD
1:  beqz    a5, 9f
    l32i    a4, a5, ROW_ID
    beq     a4, a7, 2f
    l32i    a5, a5, ROW_NEXT
    j       1b
2:  l32i    a4, a6, ACB_SB
    l32i    a4, a4, SB_STRATEGY
    movi    a8, ATOM_ONE_FOR_ALL
    beq     a4, a8, 5f
    l32i    a4, a5, ROW_CHILD
    beqz    a4, 3f
    mov     a10, a6
    mov     a11, a5
    call8   silica_rt_supervisor_stop_child
3:  mov     a10, a5
    mov     a11, a6
    call8   silica_rt_supervisor_respawn_row  // §20.3.1: a taken name fails the supervisor, no child
    mov     a10, a5
    call8   silica_rt_row_child_ref     // the restarted child's identity (§15.1.4)
    mov     a2, a10
    mov     a3, a11
    mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
5:  // one_for_all: stop every live child, then respawn every row
    movi    a2, 0
    s32i    a2, a1, 0                   // [a1] the row with the id once respawned
    l32i    a3, a6, ACB_SB
    l32i    a3, a3, SB_CT_HEAD
51: beqz    a3, 52f
    l32i    a4, a3, ROW_CHILD
    beqz    a4, 511f
    mov     a10, a6
    mov     a11, a3
    call8   silica_rt_supervisor_stop_child
511: l32i   a3, a3, ROW_NEXT
    j       51b
52: l32i    a3, a6, ACB_SB
    l32i    a3, a3, SB_CT_HEAD
53: beqz    a3, 8f
    mov     a10, a3
    mov     a11, a6
    call8   silica_rt_supervisor_respawn_row
    bnez    a10, 8f
    l32i    a4, a3, ROW_ID
    bne     a4, a7, 531f
    s32i    a3, a1, 0
531: l32i   a3, a3, ROW_NEXT
    j       53b
8:  l32i    a10, a1, 0
    call8   silica_rt_row_child_ref     // the child's identity (§15.1.4), all ones for none
    mov     a2, a10
    mov     a3, a11
    mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
9:  movi    a2, -1
    movi    a3, -1
    mov     a10, a6
    call8   silica_rt_child_table_leave
    retw
    .size   silica_rt_supervisor_restart_child, . - silica_rt_supervisor_restart_child
