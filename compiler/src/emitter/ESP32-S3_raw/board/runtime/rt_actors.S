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

// Actor runtime for the bare-metal ESP32-S3: the cooperative per-core scheduler of
// silica-specification.md §15.1.2 / §23.1.1, with the entry points the emitter's
// terms/prims/prims_actors.silica calls (the same `silica_rt_*` names as the Apple Silicon runtime
// in apple_silicon_mac/terms/prims/prims_actors_runtime_asm.silica, which is the reference for
// every observable behaviour here; the design is in design_documents/ports/esp32s3_xtensa_port.md
// §7 and the status in design_documents/ports/esp32s3_port_status.md).
//
// Model. There is no OS. Every context -- `main`, each actor, and one scheduler per core -- is a
// windowed-ABI machine stack plus an auxiliary (emitter `SP`) stack, and switches happen only where
// the specification allows: at a dispatch boundary (the behaviour returned) or where the running
// context suspends to wait (`call` awaiting its reply, `wait_for_exit`, an actor with an empty
// mailbox). Nothing is preempted. A core's scheduler dispatches only the actors pinned to it; an
// actor changes core only through migrate_actor (applied at its next dispatch boundary), so pinning
// is exclusive and hard (§15.1.2, OS-free). Fairness: an actor yields to its core's scheduler after
// every dispatch, so actors on one core take turns; ready queues per priority level
// (set_actor_priority, §22.10) pick the next actor, in the order the program's dispatch-order policy
// says (set_scheduler_policy, "Dispatch-order policies" below). Cross-core state (queues, status words,
// mailboxes) is guarded by one S32C1I spinlock, silica_rt_sched_lock, held only for a few
// instructions and never across a switch or a user call. The free lists (ACBs, message nodes,
// stacks) have their own lock, silica_rt_free_lock, taken inside the six list routines: some
// callers hold the scheduler lock and some do not, and the list routines call nothing that locks.
//
// Two cores. Core 0 (the PRO cpu) boots the program; core 1 (the APP cpu) is started at start-up
// (rt_start.S silica_rt_start_windowed -> silica_rt_actors_start_cores -> silica_rt_start_app_cpu,
// once the actor runtime is initialised) and enters its scheduler from silica_rt_core1_main. The emitted code's caller-saved virtual registers and its auxiliary stack
// pointer live in a per-core block reached through THREADPTR (rt_start.S silica_rt_core_regs), so
// the two cores run emitted code at the same time without sharing a register home. The heap bump
// is a compare-and-swap (rt_heap.S) and the console has a lock (rt_console.S). NCORES_RUN below is
// how many cores the runtime uses: 2, or 1 to diagnose a two-core problem on one core.
//
// Context switch. silica_rt_ctx_switch spills every live register window above its own to the
// stacks they belong to (the SPILL_ALL_WINDOWS trick: touch a high register in each rotation and
// let the overflow exception spill it), then saves a0 (return address + window increment), a1 and
// the emitter SP and loads the other context's. A context is first entered through a fabricated
// pair of frames at the top of its stack that makes RETW land in a trampoline with the ACB in a2.
// Emitted code keeps its caller-saved virtual registers (X3-X8, D0-D7) in this core's register
// block (THREADPTR); a switch happens only inside a runtime call, which the emitter treats as
// clobbering them, so nothing else needs saving.
//
// Stacks (spec §15.1.2.2, actor_memory_budget_plan.md item F). An actor's machine stack and its
// auxiliary (emitter SP) stack are each a chain of heap chunks that starts small, grows on demand
// without limit and is released at the dispatch boundary by the actor's stack_policy algorithm, as
// on the hosted targets; the board has no demand paging, so growth takes chunks from the heap
// ("Growable stacks" below). An actor holds no chunk until its first dispatch, and none while idle
// under :release_on_return. Every chunk ends in a 64-byte guard band watched by one of the two
// Xtensa data breakpoints, re-armed at every switch and every chunk change for the context that is
// about to run (main's two fixed stacks included); the breakpoints watch stores only, so emitted
// code also compares its stack pointers against the running context's limits in this core's
// register block (VRG_MLIMIT at every prologue: the chunk's band top plus _silica_rt_depth_reserve,
// the deepest runtime chain emitted code can call, which tools/main_stack_bound.py measures per
// image; VRG_ALIMIT at every auxiliary reservation) and, below a limit, calls the growth entry
// points. In main, whose stacks are sized per image by the same tool (_silica_main_stack_size,
// _silica_main_aux_size in silica_esp32s3.ld) and never grow, a limit crossed is a store into the
// band on purpose, the same debug exception as a real overflow: a fatal fault. A lowered
// reservation (stack_policy reserve > 0) caps what an actor's chunks may hold together; reaching it
// ends the actor with (:explicit, :stack_exhausted), tag 4, by the same store. get_actor_memory_usage
// reports the chunks held and the most ever held. Freed chunks, ACBs and message nodes go on free
// lists.
//
// Composite state (actor_memory_budget_plan.md item B). The emitted behaviour epilogue moves a
// composite reply and a changed composite state into fresh heap blocks and calls
// silica_rt_state_adopt once the state is installed, so ACB_STATE_OWNED marks a state block the
// actor must give back when it ends (silica_rt_actor_exit, the one exit path every end takes); the
// previous state goes through rt_heap.S silica_rt_state_release. A record or tuple message is a
// heap copy the sender made (MSG_PAYLOAD_OWNED, X2 of send/cast/call); the receiver drops it once
// its behaviour returned, unless that behaviour packed it into the new state.
//
// Layouts (32-bit words unless a width is given; the two 8-byte slots the emitted code reads
// keep a zero high word). The ACB is what every actor costs at rest (actor_memory_budget_plan.md
// item I): 144 bytes (ACB_SIZE), the fields a plain actor needs. Everything supervision needs -- the ingress
// queue, the start trampoline, the strategy and restart accounting, the child table and its
// users/pending words -- lives in a supervision block (SB, 64 B) that only a supervisor gets: one
// is allocated by spawn for an actor started with a trampoline, and on demand by the ingress
// enqueue for an actor that is made a parent some other way (add_child), so a worker never
// carries it. The 32-byte usage ring of :track_recent_peak is a block of its own, allocated by
// spawn for that algorithm only. Both go back with the ACB (silica_rt_free_acb). Small fields are
// bytes (l8ui/s8i; a byte store on the data bus is a single write) and atom-sized ones
// halfwords; the target core is kept as core + 1 so 0 means none.
//   ACB (144 B)   0 state(8)  8 behaviour(8)
//                 16 status(b)  17 core(b)  18 target_core + 1 (b; 0 none)  19 kind (b: 0 actor,
//                    1 main, 2 scheduler)  20 priority(b)  21 alive(b)  22 device flag (b; 1:
//                    started by spawn_device, silica_rt_actor_mark_device)  23 state owned (b; the
//                    state block is the actor's, freed at its end)
//                 24 exit reason tag(b)  25 fault EXCCAUSE+1 (b; 0: no CPU exception captured)
//                 26 exit reason atom(h)  28 agent_type atom(h)  30 registered name+1 (h; 0 none)
//                 32/36 mailbox head/tail  40 ready link (the free-list link once the ACB is freed)
//                 44/48 machine chunk chain: first chunk / current chunk  52/56 the same, auxiliary
//                 60/64/68 saved a0/a1/vsp (a1 0: no context, the next dispatch enters the loop afresh)
//                 72 supervisor  76 child row  80 supervision block (0: a plain actor)
//                 84 active call node  88 policy word ((reserve rounded to 16) | algorithm; the
//                    lowered reservation is its top bits, ACB_RESERVE_LD)  92 wait node
//                 96 usage ring (:track_recent_peak only, else 0): 32 bytes, one per past dispatch,
//                    machine peak (low nibble) and auxiliary peak (high nibble), saturated at 15
//                 100 system-timer stamp of the last dispatch boundary (:release_when_idle)
//                 104 fault EPC1  108 fault EXCVADDR
//                 112 next ACB in the chain of every ACB ever allocated (silica_rt_acb_all; the
//                     exit diagnostic's walk over live actors' stacks)
//                 116 this dispatch's peak chunk indices (machine bits 0-7, auxiliary 8-15) and the
//                     ring index (16-23)  120/124 most machine / auxiliary chunk bytes ever held
//                 128/132 identity (§15.1.4: child number, position; what every reference to the
//                     actor is)  136/140 spawner record (position + 1, next child number)
// (Bytes 128..143 hold the identity and spawner record, added 2026-10-12 when actor references became
// identities; see "Actor identity" below. The ACB was 128 B before that.)
//   SB (64 B)     0/4/8 ingress head/tail/depth  12 spawn waiter  16 sync_failure_reported
//                 20 trampoline  24 trampoline ran  28 strategy  32 allowed restarts
//                 36 time frame  40 restart count  44 window start
//                 48/52 child table head/len
//                 56 child-table users: contexts holding this supervisor's rows outside the
//                    scheduler lock (rt_supervisors.S silica_rt_child_table_enter / _leave)
//                 60 child-table pending: 1 free the rows, 2 recycle the ACB, both done by the
//                    last user to leave (a supervisor that ended while its table was in use)
//   message node (48 B)  0 next  4 kind (0 cast/send, 1 call, 2 exit notice)  8 payload(8)
//                 16 reply set  20 caller ACB  24 reply(8)  32 ingress kind (0 payload ptr, 1 inline)
//                 36 payload owned (a record/tuple copy the sender made; dropped after dispatch)
//   core block (64 B)  0/4/8 ready heads (high, normal, low)  12/16/20 tails  24 current context
//                 28 scheduler pseudo-ACB  32 busy  36 id  40/44/48 queued actors per ready queue
//                 52/56 weighted-fair tier being served and its remaining credit
//   failure payload (32 B, heap)  0 child  8 reason tag  16 reason atom  24 agent type (8-byte slots)
//
// Result and status conventions follow the reference: spawn -> the actor's identity (the
// actor_ref), cast -> 1, send -> 0, call -> the reply (an ended or unknown target raises
// actor_not_found: cast, send and call; so does a call whose target ends before replying), remove_actor / kill_abnormal /
// link / demonitor / register -> 0, monitor -> its argument, migrate_actor -> 0 :ok, 1
// :invalid_target, 2 :actor_not_found, 3 :migration_blocked (the emitter maps the code to the
// program's atom indices). wait_for_exit (spec §15.1.2.5) returns to main the int64 value of the
// first cast_exit request, or 0 when the console's receive side delivers a line reading "exit"
// (rt_console.S); main then continues, and the program ends when main returns (rt_start.S, main's
// result as the status); an idle program waits. cast_exit -> 1 when its request was recorded, 0
// when an earlier one was (the first wins). Atoms the runtime names
// itself are the fixed prefix every executable's atom table starts with (atoms/atom_table.silica
// seed_actor_runtime_atoms): :efficiency 0, :performance 1, :ok 2, :normal 3, :language_error 4,
// :memory_fault 5, :explicit 6, :unknown 7, :insert 15, :lookup 16, :delete 17, :found 18,
// :not_found 19, :unknown_op 20.

#define ACB_STATE        0
#define ACB_BEH          8
#define ACB_CONV         12     // the behaviour's high word (always 0 here) holds its calling convention
                                // (spec §16.2.6.4): 0 not checked, 1 call-only, 2 cast-only
#define ACB_STATUS       16     // byte
#define ACB_CORE         17     // byte
#define ACB_TARGET       18     // byte: target core + 1, 0 none
#define ACB_KIND         19     // byte
#define ACB_PRIO         20     // byte
#define ACB_ALIVE        21     // byte
#define ACB_DEVICE       22     // byte
#define ACB_STATE_OWNED  23     // byte
#define ACB_REASON_TAG   24     // byte
#define ACB_FAULT_CAUSE  25     // byte: EXCCAUSE + 1
#define ACB_REASON_ATOM  26     // halfword
#define ACB_AGENT        28     // halfword
#define ACB_REG_NAME     30     // halfword: atom + 1, 0 none
#define ACB_MB_HEAD      32
#define ACB_MB_TAIL      36
#define ACB_NEXT_READY   40
#define ACB_FREE_NEXT    40
#define ACB_MCHAIN       44
#define ACB_MCUR         48
#define ACB_ACHAIN       52
#define ACB_ACUR         56
#define ACB_CTX_A0       60
#define ACB_CTX_A1       64
#define ACB_CTX_VSP      68
#define ACB_SUP          72
#define ACB_ROW          76
#define ACB_SB           80
#define ACB_ACTIVE_CALL  84
#define ACB_POLICY       88
#define ACB_WAIT_NODE    92
#define ACB_RING         96
#define ACB_LAST_MSG     100
#define ACB_FAULT_EPC    104
#define ACB_FAULT_VADDR  108
#define ACB_ALL_NEXT     112
#define ACB_PEAK         116
#define ACB_HW_M         120
#define ACB_HW_A         124
#define ACB_ID           128    // the actor's identity (spec §15.1.4): child number, then position
#define ACB_SPOS         136    // its spawner record: position + 1 (0 none yet)
#define ACB_SNEXT        140    //   and the next child number it gives (a row child's is in its row)
#define ACB_SIZE         144
#define ROW_SPOS         96     // rt_supervisors.S: a row child's spawner record, kept across restarts

#define SB_IN_HEAD       0
#define SB_IN_TAIL       4
#define SB_IN_DEPTH      8
#define SB_SPAWN_WAITER  12
#define SB_SYNC_REPORTED 16
#define SB_TRAMP         20
#define SB_TRAMP_RAN     24     // the start's state and the ACB's holders (TR_*, below)
#define SB_STRATEGY      28
#define SB_ALLOWED       32
#define SB_TIMEFRAME     36
#define SB_RESTARTS      40
#define SB_WINDOW        44
#define SB_CT_HEAD       48
// SB_TRAMP_RAN bits. A supervisor's ACB is recycled exactly once, by the last of its holders:
// its own end (silica_rt_free_acb, from the scheduler's recycle), its spawner (TR_SPAWNER, from
// spawn until the spawner has the reference in hand -- for a row child, until the row holds it,
// rt_supervisors.S by_flavor) and, for one that ended inside its start trampoline, its exit notice
// (TR_NOTICE, until a supervisor has handled it: maybe_restart matches the row by this reference,
// so no new actor may take the ACB first). TR_OWN_DONE: it ended and was left to its last holder
// (silica_rt_tramp_release).
#define TR_RAN           1      // the start trampoline returned
#define TR_SPAWNER       2
#define TR_NOTICE        4
#define TR_OWN_DONE      8
#define TR_OWN_DONE_BIT  3
#define TR_INIT_DEAD     0x100  // it ended inside its start trampoline (its init failed)
#define TR_INIT_DEAD_BIT 8
#define SB_CT_LEN        52
#define SB_CT_USERS      56
#define SB_CT_PENDING    60
#define SB_SIZE          64
#define RING_SIZE        32

// \rd = the actor's lowered reservation (0 default): the policy word without its algorithm nibble.
.macro ACB_RESERVE_LD rd, acb, rt
    l32i    \rd, \acb, ACB_POLICY
    movi    \rt, -16
    and     \rd, \rd, \rt
.endm

#define ST_IDLE          0
#define ST_READY         1
#define ST_RUNNING       2
#define ST_SUSPENDED     3
#define ST_DEAD          4
#define ST_WAITQ         5
#define ST_FAULTED       6
#define ST_WAIT_INGRESS  7
#define ST_BOUNDARY      8      // the dispatch returned: the scheduler releases, then parks or re-queues

#define KIND_ACTOR       0
#define KIND_MAIN        1
#define KIND_SCHED       2

#define MSG_NEXT         0
#define MSG_KIND         4
#define MSG_PAYLOAD      8
#define MSG_REPLY_SET    16
#define MSG_CALLER       20
#define MSG_REPLY        24
#define MSG_INGRESS_KIND 32
#define MSG_PAYLOAD_OWNED 36
#define MSG_SIZE         48

#define CORE_RQ_HEAD     0
#define CORE_RQ_TAIL     12
#define CORE_CURRENT     24
#define CORE_SCHED       28
#define CORE_BUSY        32
#define CORE_ID          36
#define CORE_RQ_LEN      40
#define CORE_WF_TIER     52
#define CORE_WF_CREDIT   56
#define CORE_SIZE        64
#define NCORES_MAX       2

// Dispatch-order policies (set_scheduler_policy; design_documents/ports/esp32s3_xtensa_port.md §8.10).
// One policy is in force for the whole program and every core applies it to its own ready queues;
// it decides only which READY actor of a core runs next -- never when a running one stops (nothing
// preempts between the yield points of §15.1.2) and never which core an actor is on.
//   PRIORITY_FIFO   the default: the head of the highest-priority non-empty queue.
//   ROUND_ROBIN     one flat queue: every push lands in the normal queue, whatever the actor's
//                   priority, so ready actors run in strict arrival order.
//   WEIGHTED_FAIR   deficit round robin over the three priority tiers with a unit cost per dispatch:
//                   the tier being served runs its head while it has credit and actors, then the
//                   next tier starts with a fresh quantum; an empty tier forfeits its quantum (DRR
//                   zeroes the deficit of an idle queue). Quanta: high 4, normal 2, low 1 -- the
//                   weight classes; the shares are per tier, FIFO within a tier.
//   LOTTERY         Waldspurger-Weihl lottery: a tier holds weight x (actors queued in it) tickets
//                   with the same weights, a xorshift32 draw picks the tier in proportion to its
//                   tickets and the tier's head runs. Choosing the tier and then its head keeps a
//                   pick O(1); FIFO within the tier gives every actor of a tier the same turns, so
//                   an actor's expected share is its ticket share.
// A policy change takes effect at the next push or pop on every core and leaves queued actors where
// they are: a switch to ROUND_ROBIN drains what already waits in the high and low queues in the old
// order first, a switch away from it treats what waits in the flat queue as normal until each
// actor's next push. Only the queue chosen at push and at pop depends on the policy.
#define POLICY_PRIORITY_FIFO 0
#define POLICY_ROUND_ROBIN   1
#define POLICY_WEIGHTED_FAIR 2
#define POLICY_LOTTERY       3
#define POLICY_COUNT         4
#define WEIGHT_HIGH          4
#define WEIGHT_NORMAL        2
#define WEIGHT_LOW           1

// Stack chunks (actor_memory_budget_plan.md item F). Chunk block, 64-byte aligned, from
// silica_rt_alloc_stack: [0, 64) this header, [64, 128) the guard band the data breakpoint
// watches, [128, size) frames or slabs, filled downward from the top.
#define CH_NEXT          0      // the chunk above in the chain (0 at the chain's end)
#define CH_PREV          4      // the chunk below (0 for the first)
#define CH_SIZE          8      // block bytes, header included
#define CH_RET           12     // machine: the entering frame's real a0; auxiliary: SP before the entering reservation
#define CH_LIMIT         16     // what emitted code compares against: band top (+ the runtime reserve, machine)
#define CH_TOP           20     // base + size
#define CH_BAND          24     // base + 64
#define CH_INDEX         28     // position in the chain, 1 for the first
#define CH_MIRROR        32     // auxiliary: bytes at the chunk's top that mirror the chunk below (below)
#define CH_HEADER        64
#define CH_USABLE_OFF    128    // header + band
// Sizes, from the use measured under item E: a replying behaviour needs 300-800 bytes of machine
// stack including the loop's 256 above it, and under 160 of auxiliary, so the first chunks hold
// the common actor without growing (2 KB holds ~1.1 KB of frames once the runtime reserve, header
// and band are taken; 512 holds 384 of slabs). A later chunk doubles its predecessor up to the
// cap, or holds the frame or slab that needs it plus headroom, whichever is larger
// (silica_rt_chunk_size); a wide supervisor init (~6 KB) takes one chunk of its own size.
#define MCHUNK_FIRST       2048
#define ACHUNK_FIRST       512
#define MCHUNK_CAP         16384
#define ACHUNK_CAP         4096
#define MCHUNK_HEADROOM    1024
#define ACHUNK_HEADROOM    256
// An auxiliary chunk entered by growth starts with a copy of the top of the stack it leaves: up to
// AUX_MIRROR_MAX bytes (plus up to 15 to keep the SP's 16-byte phase) from the SP before the
// growing reservation upward. Emitted code addresses earlier slots SP-relative across separate
// reservations (arguments pushed one by one and then read at [SP, #16*i], a parked operand read
// past a tuple), so a reservation that grows must leave those slots at the same offsets above the
// new SP; a release into the mirror continues at the same offset above the kept SP. Emitted code
// writes only the slots of its latest reservation, so the mirror is read-only and is not copied
// back. The largest such offset in emitted code is ~100 bytes (2026-10-11 scan).
#define AUX_MIRROR_MAX     512
#define MCHUNK_LOWERED_MIN 768  // first chunks under a lowered reservation: at least these
#define ACHUNK_LOWERED_MIN 256
#define IDLE_RELEASE_TICKS 16000000   // :release_when_idle: one second of the 16 MHz system timer
#define IDLE_SCAN_TICKS    4000000    // a core scans its idle actors at most every quarter second
#define SCHED_STACK_SIZE      4096
// The registries are sized per image: silica_registry_slots (emitted into __silica_runtime.sams by
// emitter_core.silica) is the build's atom count, one slot per atom (spec §4.1.7: atoms are fixed when
// the program is built, so the tables never overflow). The same word tells an atom from an ACB address
// in the keyed forms: ACBs live at 0x3FC8_8000 and above. REGISTRY_SLOTS loads it into a register.
.macro REGISTRY_SLOTS r
    movi    \r, silica_registry_slots
    l32i    \r, \r, 0
.endm

// Weak defaults for the words above, for images with no compiler-emitted runtime unit (the
// hand-written asm_* board apps): no registry slots, and -1 (no such atom) for every atom word. The
// emitted .rodata.silica_registry definitions are strong and override these; nothing then refers to
// this section and --gc-sections drops it, so a Silica image is unchanged.
    .section .rodata.silica_registry_default, "a"
    .align  4
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
    .weak   silica_registry_atom_duplicate_child_id
silica_registry_atom_duplicate_child_id:
    .word   -1
    .weak   silica_registry_atom_identity_exhausted
silica_registry_atom_identity_exhausted:
    .word   -1
    .weak   silica_registry_atom_shutdown
silica_registry_atom_shutdown:
    .word   -1
    .weak   silica_registry_atom_restart_breach
silica_registry_atom_restart_breach:
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
    .weak   silica_rt_reply_tag
silica_rt_reply_tag:
    .word   -1
    .weak   silica_rt_no_reply_tag
silica_rt_no_reply_tag:
    .word   -1
    // call_supervisor's error reply for a supervisor operation a row child aimed at its own row
    // (rt_supervisors.S silica_rt_sup_op_tag): this build's :error (-1 when the program never
    // spells it) and :language_error (4, fixed in every build: the prefix above).
    .weak   silica_rt_sup_error_tag
silica_rt_sup_error_tag:
    .word   -1
    .weak   silica_rt_sup_self_error_atom
silica_rt_sup_self_error_atom:
    .word   4
    .text
#define INGRESS_LIMIT         1024

#define ATOM_EFFICIENCY  0
#define ATOM_PERFORMANCE 1
#define ATOM_OK          2
#define ATOM_NORMAL      3
#define ATOM_LANGUAGE_ERROR 4
#define ATOM_MEMORY_FAULT 5
#define ATOM_EXPLICIT    6
#define ATOM_UNKNOWN     7
#define ATOM_INSERT      15
#define ATOM_LOOKUP      16
#define ATOM_DELETE      17
#define ATOM_FOUND       18
#define ATOM_NOT_FOUND   19
#define ATOM_UNKNOWN_OP  20

#define DBREAKC_STORE_64 0x80000000

// Cores the runtime runs on (1 or NCORES_MAX). With 1, core 1 is never started and every actor is
// pinned to core 0, as before core 1 ran.
#define NCORES_RUN       2

// The emitted code's per-core register block (rt_start.S silica_rt_core_regs, the same offsets):
// the auxiliary stack pointer (shared/xt_vr.silica vr_vsp_off), the limits emitted code compares
// against, and the running context's current chunks.
#define VRG_VSP          112
#define VRG_MLIMIT       116    // machine-stack limit for emitted prologues
#define VRG_ALIMIT       120    // auxiliary-stack limit for emitted SP reservations
#define VRG_ATOP         124    // auxiliary chunk top: a release reaching it pops the chunk (~0: nothing to pop)
#define VRG_MCHUNK       128    // the running context's current machine chunk
#define VRG_ACHUNK       132    // ... and auxiliary chunk
#define VRG_ARG          136    // an emitted reservation's size, for silica_rt_aux_grow

// ---------------------------------------------------------------------------------------------
// Macros

// Spill every live register window except the current one to the stacks they belong to (Zephyr /
// ESP-IDF xt_asm_utils.h SPILL_ALL_WINDOWS for 64 address registers): writing a high register of a
// rotated window that another frame owns raises the overflow exception that spills it. Sixteen
// rotations bring WINDOWBASE back to where it started; a0-a3 of this window are untouched.
.macro SPILL_ALL_WINDOWS
    and     a12, a12, a12
    rotw    3
    and     a12, a12, a12
    rotw    3
    and     a12, a12, a12
    rotw    3
    and     a12, a12, a12
    rotw    3
    and     a12, a12, a12
    rotw    4
.endm

// The scheduler lock: S32C1I compare-and-swap on one word. \ra and \rb are scratch. The word is 0
// when free, else the owning core's id + 1 (as the console lock), so a fault raised while this
// core holds it can be told apart from the other core holding it (silica_rt_actor_fault_hook).
.macro SCHED_LOCK ra, rb
    movi    \ra, silica_rt_sched_lock
9:  movi    \rb, 0
    wsr     \rb, scompare1
    THIS_CORE \rb
    addi    \rb, \rb, 1
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

// The free-list lock: the same shape. Never taken while the scheduler lock is wanted afterwards
// (the list routines are leaves), so holding the scheduler lock around a list call is fine.
.macro FREE_LOCK ra, rb
    movi    \ra, silica_rt_free_lock
9:  movi    \rb, 0
    wsr     \rb, scompare1
    movi    \rb, 1
    s32c1i  \rb, \ra, 0
    bnez    \rb, 9b
.endm

.macro FREE_UNLOCK ra, rb
    memw
    movi    \ra, silica_rt_free_lock
    movi    \rb, 0
    s32i    \rb, \ra, 0
    memw
.endm

// \r = this core's id (0 or 1) from PRID (0xCDCD on the PRO cpu, 0xABAB on the APP cpu: bit 13).
.macro THIS_CORE r
    rsr     \r, prid
    extui   \r, \r, 13, 1
.endm

// \r = this core's core block. \t scratch.
.macro THIS_CORE_BLOCK r, t
    THIS_CORE \r
    slli    \r, \r, 6
    movi    \t, silica_rt_cores
    add     \r, \r, \t
.endm

// ---------------------------------------------------------------------------------------------
// Data

    .section .bss.silica_rt_actors, "aw", @nobits
    .balign 16
    .global silica_rt_cores
silica_rt_cores:
    .space  CORE_SIZE * NCORES_MAX
    .global silica_rt_main_acb
silica_rt_main_acb:
    .space  ACB_SIZE
silica_rt_sched_acbs:
    .space  ACB_SIZE * NCORES_MAX
    .balign 64
silica_rt_sched_stacks:
    .space  SCHED_STACK_SIZE * NCORES_MAX
    .global silica_rt_sched_lock
silica_rt_sched_lock:
    .space  4
silica_rt_free_lock:
    .space  4
silica_rt_core1_boot_acb:               // core 1's boot context: saved by its first switch, never resumed
    .space  ACB_SIZE
silica_rt_actors_ready:
    .space  4
silica_rt_acb_all:                         // every ACB ever allocated (ACB_ALL_NEXT), never unlinked
    .space  4
silica_rt_actor_hw:                        // most chunk bytes held by ended actors / supervisors:
    .space  16                             //   [0] actor machine [4] actor aux [8] sup machine [12] sup aux
    .global silica_rt_main_mchunk
silica_rt_main_mchunk:                     // main's fixed stacks described as chunks (the switch and the
    .space  CH_HEADER                      // growth entries read limits, bands and tops from them)
    .global silica_rt_main_achunk
silica_rt_main_achunk:
    .space  CH_HEADER
silica_rt_idle_scan_at:                    // per core: system-timer stamp of its last :release_when_idle scan
    .space  4 * NCORES_MAX
silica_rt_cores_started:
    .space  4
    .global silica_rt_ncores
silica_rt_ncores:
    .space  4
    .global silica_rt_sched_policy
silica_rt_sched_policy:                 // POLICY_* in force; zero = PRIORITY_FIFO
    .space  4
silica_rt_lottery_state:                // xorshift32 state, seeded from CCOUNT at the first draw
    .space  4
silica_rt_next_core:
    .space  4
silica_rt_acb_free:
    .space  4
silica_rt_node_free:
    .space  4
silica_rt_stack_free:
    .space  4
silica_rt_dead_acb:                     // what a spawn returns for an actor that ended in its start
    .space  ACB_SIZE                    // (silica_rt_spawn_common): never alive, never recycled
    .global silica_rt_wait_root_acb
silica_rt_wait_root_acb:
    .space  4
    .global silica_rt_exit_request
silica_rt_exit_request:                 // §15.1.2.5: the first cast_exit's int64 value (low word, high word)
    .space  8
    .global silica_rt_exit_flag
silica_rt_exit_flag:                    // 0 no request yet, 1 once one is recorded (any value is legal)
    .space  4
    .global silica_pid_registry_ref
silica_pid_registry_ref:
    .space  8
    .global silica_dangerous_pid_registry_ref
silica_dangerous_pid_registry_ref:
    .space  8
    .global silica_device_pid_registry_ref
silica_device_pid_registry_ref:
    .space  8
    .global silica_rt_root_failure_reporter
silica_rt_root_failure_reporter:
    .space  4
    .global silica_rt_region_dump_limit
silica_rt_region_dump_limit:
    .space  8
    // the report the FailureReporter is handling: +0 the string block (0: none), +4 escaped (the
    // behaviour sent it on, so another actor holds it). One root reporter, so one record serves.
    .global silica_rt_report_owner
silica_rt_report_owner:
    .space  8
    // reports handed to the reporter and not yet taken by its dispatch: a list of 8-byte nodes
    // (+0 next, +4 the report string), oldest first; the scheduler lock guards it
    .global silica_rt_report_list
silica_rt_report_list:
    .space  4
    // deaths between silica_rt_actor_deliver_exit and their queued or written report
    // (silica_rt_actor_exit_body); the scheduler lock guards it
    .global silica_rt_report_inflight
silica_rt_report_inflight:
    .space  4

    .section .rodata.silica_rt_actors, "a"
silica_rt_root_exit_msg:
    .asciz  "[silica] root actor exited (no supervisor)\n"
silica_rt_name_taken_msg:
    .asciz  "language_error\n"
silica_rt_actor_not_found_msg:
    .asciz  "actor_not_found\n"
silica_rt_identity_exhausted_msg:
    .asciz  "identity_exhausted\n"
silica_rt_banner_head:
    .asciz  "\n=== Silica Actor Failure ===\nactor_id:        "
silica_rt_banner_agent:
    .asciz  "\nagent_type_atom: "
silica_rt_banner_reason:
    .asciz  "\nreason_tag:      "
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
silica_rt_exc_n0:  .asciz "IllegalInstruction"
silica_rt_exc_n2:  .asciz "InstructionFetchError"
silica_rt_exc_n3:  .asciz "LoadStoreError"
silica_rt_exc_n6:  .asciz "IntegerDivideByZero"
silica_rt_exc_n9:  .asciz "LoadStoreAlignment"
silica_rt_exc_n20: .asciz "InstrFetchProhibited"
silica_rt_exc_n28: .asciz "LoadProhibited"
silica_rt_exc_n29: .asciz "StoreProhibited"
    .balign 4
silica_rt_exc_names:
    .word 0, silica_rt_exc_n0, 2, silica_rt_exc_n2, 3, silica_rt_exc_n3, 6, silica_rt_exc_n6
    .word 9, silica_rt_exc_n9, 20, silica_rt_exc_n20, 28, silica_rt_exc_n28, 29, silica_rt_exc_n29
    .word -1, 0
silica_rt_banner_sup:
    .asciz  "\nsupervisor_acb:  "
silica_rt_banner_stack:
    .asciz  "\ncall_stack:\n  #0  "
silica_rt_banner_unknown:
    .asciz  "<unknown behavior>"
silica_rt_banner_tail:
    .asciz  "\n  #1  _actor_thread_main\n=== End Silica Actor Failure ===\n"

    .section .text.silica_rt_actors, "ax"
    .literal_position

// ---------------------------------------------------------------------------------------------
// Initialisation. Idempotent; the first actor entry point every program runs is
// silica_pid_registry_init, injected at the top of main, so the runtime sets itself up there.
// main becomes a context: a pseudo-ACB pinned to core 0 whose stacks are the boot stacks, so the
// guard re-arming at a switch back to main restores the two watchpoints _start armed. Core 1 is
// started last, once its core block and scheduler context exist; a spawn pinned to core 1 before
// its scheduler runs simply waits on that core's ready queue.

    .align  4
    .global silica_rt_actors_init
    .type   silica_rt_actors_init, @function
silica_rt_actors_init:
    entry   a1, 32
    movi    a2, silica_rt_actors_ready
    l32i    a3, a2, 0
    bnez    a3, 9f
    movi    a3, 1
    s32i    a3, a2, 0
    movi    a2, silica_rt_ncores
    movi    a3, NCORES_RUN
    s32i    a3, a2, 0
    // core blocks: id and scheduler pseudo-ACB
    movi    a4, silica_rt_cores
    movi    a5, silica_rt_sched_acbs
    movi    a6, 0
1:  s32i    a6, a4, CORE_ID
    s32i    a5, a4, CORE_SCHED
    s32i    a5, a4, CORE_CURRENT    // the scheduler, until something runs (core 0: main, below)
    movi    a7, WEIGHT_HIGH         // weighted fair starts a round at the high tier
    s32i    a7, a4, CORE_WF_CREDIT
    movi    a7, KIND_SCHED
    s8i     a7, a5, ACB_KIND
    s8i     a6, a5, ACB_CORE
    movi    a7, 1
    s8i     a7, a5, ACB_ALIVE
    // the scheduler's stack: no auxiliary stack (it runs no emitted code)
    movi    a7, silica_rt_sched_stacks
    movi    a8, SCHED_STACK_SIZE
    mull    a9, a6, a8
    add     a7, a7, a9
    mov     a10, a5
    movi    a11, silica_rt_sched_landing
    add     a12, a7, a8                 // the scheduler's stack top; no auxiliary stack
    movi    a13, 0
    call8   silica_rt_ctx_prepare
    addi    a4, a4, CORE_SIZE
    movi    a8, ACB_SIZE
    add     a5, a5, a8
    addi    a6, a6, 1
    movi    a7, NCORES_MAX
    blt     a6, a7, 1b
    // main's pseudo-ACB
    movi    a4, silica_rt_main_acb
    movi    a5, KIND_MAIN
    s8i     a5, a4, ACB_KIND
    movi    a5, 1
    s8i     a5, a4, ACB_ALIVE
    movi    a5, ST_RUNNING
    s8i     a5, a4, ACB_STATUS
    movi    a5, 0
    s8i     a5, a4, ACB_CORE
    s8i     a5, a4, ACB_TARGET
    // main's two fixed stacks as chunk headers: the switch publishes their limits and bands
    movi    a6, silica_rt_main_mchunk
    movi    a5, 0
    s32i    a5, a6, CH_NEXT
    s32i    a5, a6, CH_PREV
    s32i    a5, a6, CH_RET
    movi    a5, _silica_main_stack_size
    s32i    a5, a6, CH_SIZE
    movi    a5, _silica_heap_end          // machine stack bottom (the guard _start armed)
    s32i    a5, a6, CH_BAND
    movi    a7, _silica_rt_depth_reserve + 64
    add     a7, a5, a7
    s32i    a7, a6, CH_LIMIT
    movi    a5, _silica_stack_top
    s32i    a5, a6, CH_TOP
    movi    a5, 1
    s32i    a5, a6, CH_INDEX
    s32i    a6, a4, ACB_MCUR
    movi    a6, silica_rt_main_achunk
    movi    a5, 0
    s32i    a5, a6, CH_NEXT
    s32i    a5, a6, CH_PREV
    s32i    a5, a6, CH_RET
    movi    a5, _silica_main_aux_size
    s32i    a5, a6, CH_SIZE
    movi    a5, silica_rt_aux_stack_bottom
    s32i    a5, a6, CH_BAND
    addi    a5, a5, 64
    s32i    a5, a6, CH_LIMIT
    movi    a5, silica_rt_aux_stack_top
    s32i    a5, a6, CH_TOP
    movi    a5, 1
    s32i    a5, a6, CH_INDEX
    s32i    a6, a4, ACB_ACUR
    movi    a5, 1
    s8i     a5, a4, ACB_PRIO
    movi    a5, silica_rt_cores
    s32i    a4, a5, CORE_CURRENT
    movi    a5, silica_rt_exit_flag
    movi    a4, 0
    s32i    a4, a5, 0
    movi    a5, silica_rt_exit_request
    s32i    a4, a5, 0
    s32i    a4, a5, 4
    // identity (§15.1.4): main is position 0, the runtime's own actors position 0xFFFFFFFE, and the
    // first position handed out is 1
    movi    a5, silica_rt_next_position
    movi    a4, 1
    s32i    a4, a5, 0
    movi    a5, silica_rt_main_spawner
    s32i    a4, a5, 0
    movi    a5, silica_rt_runtime_spawner
    movi    a4, -1
    s32i    a4, a5, 0
9:  retw
    .size   silica_rt_actors_init, . - silica_rt_actors_init

// silica_rt_actors_start_cores(): start core 1, once, after silica_rt_actors_init. Called from
// start-up only (rt_start.S silica_rt_start_windowed), never from a spawn: the ROM call it makes
// would otherwise be charged to every actor stack as part of the runtime depth reserve.
    .align  4
    .global silica_rt_actors_start_cores
    .type   silica_rt_actors_start_cores, @function
silica_rt_actors_start_cores:
    entry   a1, 32
#if NCORES_RUN > 1
    movi    a2, silica_rt_cores_started
    l32i    a3, a2, 0
    bnez    a3, 9f
    movi    a3, 1
    s32i    a3, a2, 0
    call8   silica_rt_start_app_cpu     // rt_start.S: core 1 boots into silica_rt_core1_main
#endif
9:  retw
    .size   silica_rt_actors_start_cores, . - silica_rt_actors_start_cores

// silica_rt_core1_main(): core 1's first and only call, on its boot stack (rt_start.S
// silica_rt_start_core1). The boot context is saved into a pseudo-ACB nothing ever loads, and the
// core's scheduler is entered through its prepared frames. Never returns.
    .align  4
    .global silica_rt_core1_main
    .type   silica_rt_core1_main, @function
silica_rt_core1_main:
    entry   a1, 32
    movi    a10, silica_rt_core1_boot_acb
    THIS_CORE_BLOCK a3, a4
    l32i    a11, a3, CORE_SCHED
    call8   silica_rt_ctx_switch
1:  j       1b
    .size   silica_rt_core1_main, . - silica_rt_core1_main

// ---------------------------------------------------------------------------------------------
// Free lists and allocation

// silica_rt_alloc_acb() -> zeroed ACB
    .align  4
silica_rt_alloc_acb:
    entry   a1, 32
    FREE_LOCK a8, a9
    movi    a3, silica_rt_acb_free
    l32i    a2, a3, 0
    beqz    a2, 1f
    l32i    a4, a2, ACB_FREE_NEXT
    s32i    a4, a3, 0
    FREE_UNLOCK a8, a9
    l32i    a5, a2, ACB_ALL_NEXT        // a recycled ACB keeps its place in the all-ACB chain
    mov     a10, a2
    movi    a11, ACB_SIZE
    call8   silica_rt_zero_block
    s32i    a5, a2, ACB_ALL_NEXT
    retw
1:  FREE_UNLOCK a8, a9
    movi    a10, ACB_SIZE
    call8   silica_rt_alloc
    mov     a2, a10
    FREE_LOCK a8, a9                    // a fresh ACB joins the chain
    movi    a3, silica_rt_acb_all
    l32i    a4, a3, 0
    s32i    a4, a2, ACB_ALL_NEXT
    s32i    a2, a3, 0
    FREE_UNLOCK a8, a9
    retw
    .size   silica_rt_alloc_acb, . - silica_rt_alloc_acb

// silica_rt_free_acb(acb)
    .align  4
    .global silica_rt_free_acb
silica_rt_free_acb:
    entry   a1, 32
    SCHED_LOCK a8, a9                   // a supervisor whose rows a restart or a query still holds
    l32i    a5, a2, ACB_SB              // is recycled by the last of them (child_table_leave)
    beqz    a5, 1f
    // a supervisor its spawner or its exit notice still holds is left to the last of them
    // (TR_OWN_DONE; silica_rt_tramp_release recycles it); its stacks are already back
    l32i    a3, a5, SB_TRAMP_RAN
    movi    a4, TR_SPAWNER | TR_NOTICE
    and     a4, a3, a4
    beqz    a4, 4f
    movi    a4, TR_OWN_DONE
    or      a3, a3, a4
    s32i    a3, a5, SB_TRAMP_RAN
    SCHED_UNLOCK a8, a9
    retw
4:
    l32i    a3, a5, SB_CT_USERS
    beqz    a3, 1f
    l32i    a3, a5, SB_CT_PENDING
    movi    a4, 2
    or      a3, a3, a4
    s32i    a3, a5, SB_CT_PENDING
    SCHED_UNLOCK a8, a9
    retw
1:  mov     a10, a2                     // recycled: its identity no longer resolves (§15.1.4)
    call8   silica_rt_idt_remove_locked
    SCHED_UNLOCK a8, a9
    // the side blocks go back with the ACB: the supervision block and the usage ring
    beqz    a5, 2f
    movi    a3, 0
    s32i    a3, a2, ACB_SB
    mov     a10, a5
    call8   silica_rt_free
2:  l32i    a5, a2, ACB_RING
    beqz    a5, 3f
    movi    a3, 0
    s32i    a3, a2, ACB_RING
    mov     a10, a5
    call8   silica_rt_free
3:  FREE_LOCK a8, a9
    movi    a3, silica_rt_acb_free
    l32i    a4, a3, 0
    s32i    a4, a2, ACB_FREE_NEXT
    movi    a4, ST_DEAD
    s8i     a4, a2, ACB_STATUS
    s32i    a2, a3, 0
    FREE_UNLOCK a8, a9
    retw
    .size   silica_rt_free_acb, . - silica_rt_free_acb

// silica_rt_tramp_release(acb, hold): a holder of a supervisor's ACB (TR_SPAWNER or TR_NOTICE) lets
// go. When the actor has ended and was left to its holders (TR_OWN_DONE) and this was the last
// one, the ACB is recycled now (silica_rt_free_acb, which finds no holder left). acb 0 or an
// actor without a supervision block: nothing to do.
    .align  4
    .global silica_rt_tramp_release
    .type   silica_rt_tramp_release, @function
silica_rt_tramp_release:
    entry   a1, 32
    beqz    a2, 8f
    l32i    a4, a2, ACB_SB
    beqz    a4, 8f
    SCHED_LOCK a8, a9
    l32i    a5, a4, SB_TRAMP_RAN
    movi    a6, -1
    xor     a6, a6, a3
    and     a5, a5, a6
    s32i    a5, a4, SB_TRAMP_RAN
    movi    a6, TR_SPAWNER | TR_NOTICE
    and     a6, a5, a6
    SCHED_UNLOCK a8, a9
    bnez    a6, 8f
    bbci    a5, TR_OWN_DONE_BIT, 8f
    mov     a10, a2
    call8   silica_rt_free_acb
8:  retw
    .size   silica_rt_tramp_release, . - silica_rt_tramp_release

// silica_rt_exit_payload_free(payload): an exit notice's payload goes back; one that holds its
// actor (word 32: the actor ended inside its start trampoline) lets go of it.
    .align  4
    .global silica_rt_exit_payload_free
    .type   silica_rt_exit_payload_free, @function
silica_rt_exit_payload_free:
    entry   a1, 32
    beqz    a2, 9f
    l32i    a3, a2, 32
    l32i    a4, a2, 0
    mov     a10, a2
    call8   silica_rt_free
    beqz    a3, 9f
    mov     a10, a4
    movi    a11, TR_NOTICE
    call8   silica_rt_tramp_release
9:  retw
    .size   silica_rt_exit_payload_free, . - silica_rt_exit_payload_free

// silica_rt_alloc_node() -> zeroed message node
    .align  4
silica_rt_alloc_node:
    entry   a1, 32
    FREE_LOCK a8, a9
    movi    a3, silica_rt_node_free
    l32i    a2, a3, 0
    beqz    a2, 1f
    l32i    a4, a2, MSG_NEXT
    s32i    a4, a3, 0
    FREE_UNLOCK a8, a9
    mov     a10, a2
    movi    a11, MSG_SIZE
    call8   silica_rt_zero_block
    retw
1:  FREE_UNLOCK a8, a9
    movi    a10, MSG_SIZE
    call8   silica_rt_alloc
    mov     a2, a10
    retw
    .size   silica_rt_alloc_node, . - silica_rt_alloc_node

// silica_rt_free_node(node)
    .align  4
    .global silica_rt_free_node
silica_rt_free_node:
    entry   a1, 32
    beqz    a2, 1f
    FREE_LOCK a8, a9
    movi    a3, silica_rt_node_free
    l32i    a4, a3, 0
    s32i    a4, a2, MSG_NEXT
    s32i    a2, a3, 0
    FREE_UNLOCK a8, a9
1:  retw
    .size   silica_rt_free_node, . - silica_rt_free_node

// silica_rt_node_release_payload(node): the message copy a cast, send or call carried goes back
// to the heap when the node is dropped without a dispatch (a dead target, an actor's exit drain, a
// supervisor without a behaviour).
    .align  4
silica_rt_node_release_payload:
    entry   a1, 32
    l32i    a3, a2, MSG_PAYLOAD_OWNED
    beqz    a3, 1f
    movi    a4, 2                       // a report the reporter never took stays listed: the exit
    beq     a3, a4, 1f                  // drain prints it (silica_rt_report_drain_at_exit)
    movi    a3, 0
    s32i    a3, a2, MSG_PAYLOAD_OWNED
    l32i    a10, a2, MSG_PAYLOAD
    call8   silica_rt_free
1:  retw
    .size   silica_rt_node_release_payload, . - silica_rt_node_release_payload

// silica_rt_state_adopt(X0 acb) -> X0 acb: the state block now in ACB_STATE is the actor's own
// (the emitted behaviour epilogue just installed a moved copy), so the actor's end frees it.
    .align  4
    .global silica_rt_state_adopt
    .type   silica_rt_state_adopt, @function
silica_rt_state_adopt:
    entry   a1, 32
    beqz    a2, 1f
    movi    a3, 1
    s8i     a3, a2, ACB_STATE_OWNED
1:  movi    a3, 0
    retw
    .size   silica_rt_state_adopt, . - silica_rt_state_adopt

// silica_rt_state_adopt_ref(X0 actor_ref) -> X0 actor_ref: the same for the initial state spawn just
// moved into a new actor. Spawn returns the actor's identity (§15.1.4), never its ACB, so the
// reference is resolved under the scheduler lock; an actor already recycled is not found and its
// identity no longer resolves, so nothing is marked.
    .align  4
    .global silica_rt_state_adopt_ref
    .type   silica_rt_state_adopt_ref, @function
silica_rt_state_adopt_ref:
    entry   a1, 32
    SCHED_LOCK a8, a9
    mov     a10, a2
    mov     a11, a3
    call8   silica_rt_idt_find_locked
    beqz    a11, 1f
    movi    a4, 1
    s8i     a4, a11, ACB_STATE_OWNED
1:  SCHED_UNLOCK a8, a9
    retw
    .size   silica_rt_state_adopt_ref, . - silica_rt_state_adopt_ref

// silica_rt_sb_require(acb) -> the actor's supervision block, allocated now if it had none. Called
// by spawn for an actor with a start trampoline, by the ingress enqueue for any other actor that
// receives an exit notice (an add_child parent), and by the child-table paths for the running
// actor. Allocation is fine under the scheduler lock (rt_heap.S). The block is freed with the ACB.
    .align  4
    .global silica_rt_sb_require
silica_rt_sb_require:
    entry   a1, 32
    l32i    a3, a2, ACB_SB
    bnez    a3, 1f
    movi    a10, SB_SIZE
    call8   silica_rt_alloc
    mov     a3, a10
    s32i    a3, a2, ACB_SB
1:  mov     a2, a3
    movi    a3, 0
    retw
    .size   silica_rt_sb_require, . - silica_rt_sb_require

// silica_rt_zero_block(base, bytes): 4-byte granularity.
    .align  4
silica_rt_zero_block:
    entry   a1, 32
    movi    a6, 0
    add     a3, a2, a3
1:  bgeu    a2, a3, 2f
    s32i    a6, a2, 0
    addi    a2, a2, 4
    j       1b
2:  retw
    .size   silica_rt_zero_block, . - silica_rt_zero_block

// silica_rt_alloc_stack(bytes) -> 64-byte aligned block, or 0 when the heap cannot give it. A fresh
// block comes zeroed from the heap; a reused one is not zeroed (nothing reads a stack before writing
// it). Every block keeps a 16-byte header just below it: [-16] size, [-12] next (while it is on the
// free list), [-8] the heap block it was cut from (silica_rt_stack_to_heap).
    .align  4
silica_rt_alloc_stack:
    entry   a1, 32
    addi    a2, a2, 63
    movi    a3, -64
    and     a2, a2, a3                  // size rounded to 64
    FREE_LOCK a8, a9
    movi    a3, silica_rt_stack_free
    l32i    a4, a3, 0                   // a4 = candidate, a3 = address of the link that points at it
1:  beqz    a4, 5f
    addi    a6, a4, -16                 // a6 = the candidate's header
    l32i    a5, a6, 0
    beq     a5, a2, 2f
    addi    a3, a6, 4
    l32i    a4, a6, 4
    j       1b
2:  l32i    a5, a6, 4                   // unlink
    s32i    a5, a3, 0
    FREE_UNLOCK a8, a9
    mov     a2, a4
    retw
5:  FREE_UNLOCK a8, a9
    addi    a10, a2, 80                 // header + alignment slack
    call8   silica_rt_alloc_or_null
    beqz    a10, 9f
    mov     a7, a10                     // a7 = the heap block
    addi    a10, a10, 16 + 63
    movi    a3, -64
    and     a10, a10, a3
    addi    a6, a10, -16
    s32i    a2, a6, 0
    s32i    a7, a6, 8                   // the heap block, for silica_rt_stack_to_heap
    mov     a2, a10
    retw
9:  movi    a2, 0
    retw
    .size   silica_rt_alloc_stack, . - silica_rt_alloc_stack

// silica_rt_stack_to_heap(block): a chunk of an ended actor goes back to the heap, not to the free
// list. The free list keeps a chunk for the next dispatch of a live actor (no zeroing, no search);
// an ended actor's chunks kept there would hold the peak of chunks ever in use at once for good,
// so heap_used would grow with the timing of the two cores (actors that faulted while handling a
// message on both cores together: stack_budget_board_addition/supervisor_end_frees_child_table).
    .align  4
silica_rt_stack_to_heap:
    entry   a1, 32
    beqz    a2, 1f
    addi    a3, a2, -16
    l32i    a10, a3, 8
    call8   silica_rt_free
1:  retw
    .size   silica_rt_stack_to_heap, . - silica_rt_stack_to_heap

// silica_rt_free_stack(block)
    .align  4
silica_rt_free_stack:
    entry   a1, 32
    beqz    a2, 1f
    FREE_LOCK a8, a9
    movi    a3, silica_rt_stack_free
    l32i    a4, a3, 0
    addi    a5, a2, -16
    s32i    a4, a5, 4
    s32i    a2, a3, 0
    FREE_UNLOCK a8, a9
1:  retw
    .size   silica_rt_free_stack, . - silica_rt_free_stack

// ---------------------------------------------------------------------------------------------
// Ready queues (caller holds the lock)

// silica_rt_rq_push(acb): onto the tail of the queue of acb's core and priority (under
// ROUND_ROBIN, of the one flat queue).
    .align  4
silica_rt_rq_push:
    entry   a1, 32
    l8ui    a3, a2, ACB_CORE
    slli    a3, a3, 6
    movi    a4, silica_rt_cores
    add     a3, a3, a4                  // core block
    movi    a4, silica_rt_sched_policy
    l32i    a4, a4, 0
    movi    a5, POLICY_ROUND_ROBIN
    beq     a4, a5, 2f
    l8ui    a4, a2, ACB_PRIO            // 0 low, 1 normal, 2 high -> queue index 2 - prio
    movi    a5, 2
    sub     a4, a5, a4
    j       3f
2:  movi    a4, 1                       // round robin: arrival order in the normal queue
3:  slli    a4, a4, 2
    add     a3, a3, a4                  // &head; &tail = +12, &len = +40
    l32i    a5, a3, CORE_RQ_LEN
    addi    a5, a5, 1
    s32i    a5, a3, CORE_RQ_LEN
    movi    a5, 0
    s32i    a5, a2, ACB_NEXT_READY
    l32i    a5, a3, CORE_RQ_TAIL
    beqz    a5, 1f
    s32i    a2, a5, ACB_NEXT_READY
    s32i    a2, a3, CORE_RQ_TAIL
    retw
1:  s32i    a2, a3, CORE_RQ_HEAD
    s32i    a2, a3, CORE_RQ_TAIL
    retw
    .size   silica_rt_rq_push, . - silica_rt_rq_push

// silica_rt_rq_take(core block, queue index) -> acb: the head of that queue, which must not be empty.
    .align  4
silica_rt_rq_take:
    entry   a1, 32
    slli    a3, a3, 2
    add     a2, a2, a3
    l32i    a3, a2, CORE_RQ_HEAD
    l32i    a5, a3, ACB_NEXT_READY
    s32i    a5, a2, CORE_RQ_HEAD
    bnez    a5, 1f
    s32i    a5, a2, CORE_RQ_TAIL
1:  l32i    a5, a2, CORE_RQ_LEN
    addi    a5, a5, -1
    s32i    a5, a2, CORE_RQ_LEN
    mov     a2, a3
    retw
    .size   silica_rt_rq_take, . - silica_rt_rq_take

// silica_rt_rq_pop(core block) -> acb or 0: the next actor to run under the policy in force.
    .align  4
silica_rt_rq_pop:
    entry   a1, 48
    movi    a4, silica_rt_sched_policy
    l32i    a4, a4, 0
    movi    a5, POLICY_WEIGHTED_FAIR
    beq     a4, a5, 20f
    movi    a5, POLICY_LOTTERY
    beq     a4, a5, 30f
    // PRIORITY_FIFO (and ROUND_ROBIN, whose pushes all land in the normal queue): the head of the
    // highest-priority non-empty queue
    movi    a3, 0
1:  slli    a5, a3, 2
    add     a5, a5, a2
    l32i    a6, a5, CORE_RQ_HEAD
    bnez    a6, 9f
    addi    a3, a3, 1
    movi    a5, 3
    blt     a3, a5, 1b
    movi    a2, 0
    retw
9:  mov     a10, a2
    mov     a11, a3
    call8   silica_rt_rq_take
    mov     a2, a10
    retw
20: // WEIGHTED_FAIR: serve the current tier while it has credit and actors; otherwise the next tier
    // starts with its quantum (an empty tier forfeits its turn). Some queue is non-empty, so at
    // most three tier changes reach a tier that runs.
    l32i    a6, a2, CORE_RQ_HEAD
    l32i    a7, a2, CORE_RQ_HEAD + 4
    or      a6, a6, a7
    l32i    a7, a2, CORE_RQ_HEAD + 8
    or      a6, a6, a7
    bnez    a6, 21f
    movi    a2, 0
    retw
21: l32i    a3, a2, CORE_WF_TIER
    l32i    a4, a2, CORE_WF_CREDIT
22: slli    a5, a3, 2
    add     a5, a5, a2
    l32i    a6, a5, CORE_RQ_HEAD
    beqz    a6, 23f
    beqz    a4, 23f
    addi    a4, a4, -1
    s32i    a3, a2, CORE_WF_TIER
    s32i    a4, a2, CORE_WF_CREDIT
    j       9b
23: addi    a3, a3, 1
    movi    a5, 3
    bltu    a3, a5, 24f
    movi    a3, 0
24: movi    a4, WEIGHT_HIGH
    beqz    a3, 22b
    movi    a4, WEIGHT_NORMAL
    movi    a5, 1
    beq     a3, a5, 22b
    movi    a4, WEIGHT_LOW
    j       22b
30: // LOTTERY: tickets = weight x actors queued, per tier; draw in [0, total) and find the tier
    l32i    a6, a2, CORE_RQ_LEN
    slli    a6, a6, 2                   // WEIGHT_HIGH x high
    l32i    a7, a2, CORE_RQ_LEN + 4
    slli    a7, a7, 1                   // WEIGHT_NORMAL x normal
    l32i    a8, a2, CORE_RQ_LEN + 8     // WEIGHT_LOW x low
    add     a5, a6, a7
    add     a5, a5, a8                  // total tickets
    bnez    a5, 31f
    movi    a2, 0
    retw
31: // xorshift32 (Marsaglia 2003: 13, 17, 5), not cryptographic; seeded from the cycle counter the
    // first time, kept non-zero by the OR. One state word, written under the scheduler lock the
    // caller holds. Shifts of 16 or more are extui: SRLI takes at most 15.
    movi    a9, silica_rt_lottery_state
    l32i    a3, a9, 0
    bnez    a3, 32f
    rsr     a3, ccount
    movi    a4, 1
    or      a3, a3, a4
32: slli    a4, a3, 13
    xor     a3, a3, a4
    extui   a4, a3, 17, 15
    xor     a3, a3, a4
    slli    a4, a3, 5
    xor     a3, a3, a4
    s32i    a3, a9, 0
    remu    a3, a3, a5                  // the draw
    movi    a4, 0
    bltu    a3, a6, 33f                 // below the high tier's tickets: high
    sub     a3, a3, a6
    movi    a4, 1
    bltu    a3, a7, 33f                 // then the normal tier's
    movi    a4, 2                       // else low (its count is non-zero, or total would be smaller)
33: mov     a3, a4
    j       9b
    .size   silica_rt_rq_pop, . - silica_rt_rq_pop

// silica_rt_make_ready(acb): a parked (idle) actor becomes ready. Lock held.
    .align  4
    .global silica_rt_make_ready
silica_rt_make_ready:
    entry   a1, 32
    l8ui    a3, a2, ACB_STATUS
    bnez    a3, 1f
    movi    a3, ST_READY
    s8i     a3, a2, ACB_STATUS
    mov     a10, a2
    call8   silica_rt_rq_push
1:  retw
    .size   silica_rt_make_ready, . - silica_rt_make_ready

// silica_rt_wake(acb): a suspended context (call, ingress wait) becomes ready. Lock held. main parked
// in wait_for_exit (ST_WAITQ) is not woken here: only silica_rt_exit_request_record resumes it.
    .align  4
    .global silica_rt_wake
silica_rt_wake:
    entry   a1, 32
    l8ui    a3, a2, ACB_STATUS
    movi    a4, ST_SUSPENDED
    beq     a3, a4, 1f
    movi    a4, ST_WAIT_INGRESS
    beq     a3, a4, 1f
    retw
1:  movi    a3, ST_READY
    s8i     a3, a2, ACB_STATUS
    mov     a10, a2
    call8   silica_rt_rq_push
    retw
    .size   silica_rt_wake, . - silica_rt_wake

// ---------------------------------------------------------------------------------------------
// Context switching

// silica_rt_ctx_switch(save acb, load acb). Returns, in the loaded context, from that context's
// own call to this function (or lands in its trampoline the first time). Interrupts are never
// enabled by this runtime, so nothing else touches the window state meanwhile.
    .align  4
    .global silica_rt_ctx_switch
silica_rt_ctx_switch:
    entry   a1, 32
    call8   silica_rt_console_release_if_mine   // a context leaving mid-line gives the console up
    SPILL_ALL_WINDOWS
    s32i    a0, a2, ACB_CTX_A0
    s32i    a1, a2, ACB_CTX_A1
    rur     a4, threadptr               // this core's register block: the emitter's SP lives there
    l32i    a5, a4, VRG_VSP
    s32i    a5, a2, ACB_CTX_VSP
    l32i    a5, a4, VRG_MCHUNK          // and the chunks the leaving context is in
    s32i    a5, a2, ACB_MCUR
    l32i    a5, a4, VRG_ACHUNK
    s32i    a5, a2, ACB_ACUR
    l32i    a5, a3, ACB_CTX_VSP
    s32i    a5, a4, VRG_VSP
    // stack guards and limits for the context about to run, from its current chunks (the
    // scheduler keeps the previous ones, disarmed: it runs no emitted code)
    movi    a6, 0
    wsr     a6, dbreakc0
    wsr     a6, dbreakc1
    l8ui    a5, a3, ACB_KIND
    movi    a6, KIND_SCHED
    beq     a5, a6, 1f
    l32i    a5, a3, ACB_MCUR
    s32i    a5, a4, VRG_MCHUNK
    l32i    a6, a5, CH_LIMIT
    s32i    a6, a4, VRG_MLIMIT
    l32i    a6, a5, CH_BAND
    wsr     a6, dbreaka0
    movi    a6, DBREAKC_STORE_64
    wsr     a6, dbreakc0
    l32i    a5, a3, ACB_ACUR
    s32i    a5, a4, VRG_ACHUNK
    l32i    a6, a5, CH_LIMIT
    s32i    a6, a4, VRG_ALIMIT
    l32i    a6, a5, CH_TOP
    l32i    a7, a5, CH_MIRROR
    sub     a6, a6, a7                  // a release reaching the mirror pops the chunk
    l32i    a7, a5, CH_PREV
    bnez    a7, 2f
    movi    a6, -1                      // the first chunk: a release never pops it
2:  s32i    a6, a4, VRG_ATOP
    l32i    a6, a5, CH_BAND
    wsr     a6, dbreaka1
    movi    a6, DBREAKC_STORE_64
    wsr     a6, dbreakc1
1:  isync
    l32i    a0, a3, ACB_CTX_A0
    l32i    a1, a3, ACB_CTX_A1
    retw
    .size   silica_rt_ctx_switch, . - silica_rt_ctx_switch

// ---------------------------------------------------------------------------------------------
// Growable stacks (actor_memory_budget_plan.md item F, spec §15.1.2.2). An actor's two stacks are
// chains of heap chunks (CH_* above). Emitted code checks its stack pointers against the running
// context's limits in this core's register block (VRG_MLIMIT at every prologue, VRG_ALIMIT at every
// auxiliary reservation) and, below a limit, calls the growth entries here instead of failing:
//
//   machine    control.silica function_prologue: right after ENTRY the frame holds nothing, so the
//              prologue parks it under the limit with MOVSP (legal this early: the caller's window
//              is live), calls silica_rt_stack_grow, which takes a chunk (the retained one above
//              the current chunk when it is big enough, else a fresh one), and moves the frame to
//              that chunk's top with a second MOVSP, which reloads the caller's window through the
//              alloca exception if the parked chain spilled it (the handler reads the call size
//              from a0, so both MOVSPs run with a windowed return address in a0). The frame's a0
//              becomes silica_rt_chunk_return and the real return address goes into the chunk
//              header. The windowed ABI stays exact across the move because every spill and reload
//              of a frame's registers is addressed through the a1 of the frame above it (the base
//              save area under a frame's own a1, the extra save area under its caller's), and the
//              moved frame's a1 is set before any frame above it exists. When the frame returns,
//              RETW lands in silica_rt_chunk_return in the caller's window; it makes the chunk
//              below current again (VRG_MCHUNK, limit, guard) and jumps to the real return address
//              with a0-a7 and the result in a10:a11 intact.
//   auxiliary  shared/xt_vr.silica vsp_adjust / vr_put: a reservation that crosses the limit
//              leaves its size in VRG_ARG and calls silica_rt_aux_grow, which moves SP to the top
//              of the next auxiliary chunk (less the reservation) and keeps the previous SP in the
//              header; the matching release reaches that chunk's top (VRG_ATOP) and calls
//              silica_rt_aux_release, which pops back to the kept SP; a restore of a saved SP (the
//              self-tail-call stub's) pops as many chunks as the target is above. Both keep the
//              caller's a2-a7, where the emitter has X0-X2 across a reservation.
//
// Growth never fails as such: the heap exhausted is a runtime abort (the host's out-of-memory
// outcome, spec §15.1.2.2 "Memory Exhaustion"); a lowered reservation reached ends the actor with
// (:explicit, :stack_exhausted) through a store into the guard band on purpose, so the watchpoint
// raises the debug exception a real overflow would; in main, whose stacks are fixed, a limit
// crossed is the same fatal fault as before. Release, by the five algorithms, is the scheduler's
// (silica_rt_actor_release_policy), at the dispatch boundary and on the idle scan.

// silica_rt_chunk_size(prev chunk, need, cap, headroom) -> bytes for the chunk after prev: the
// larger of twice prev's size (up to the cap) and need + headroom, rounded up to 256.
    .align  4
silica_rt_chunk_size:
    entry   a1, 32
    l32i    a6, a2, CH_SIZE
    slli    a6, a6, 1
    bltu    a6, a4, 1f
    mov     a6, a4
1:  add     a3, a3, a5
    addi    a3, a3, 255
    movi    a7, -256
    and     a3, a3, a7
    bgeu    a6, a3, 2f
    mov     a6, a3
2:  mov     a2, a6
    retw
    .size   silica_rt_chunk_size, . - silica_rt_chunk_size

// silica_rt_chunk_take(size, prev, limit extra) -> a chunk linked after prev (whose chain above
// must be empty), or 0 when the heap cannot give it. CH_SIZE is the block's real size (the free
// list keys on it; silica_rt_alloc_stack rounds up to 64).
    .align  4
silica_rt_chunk_take:
    entry   a1, 48
    s32i    a3, a1, 0
    s32i    a4, a1, 4
    mov     a10, a2
    call8   silica_rt_alloc_stack
    mov     a2, a10
    beqz    a2, 9f
    l32i    a3, a1, 0                   // prev
    l32i    a4, a1, 4                   // extra
    addi    a7, a2, -16
    l32i    a5, a7, 0                   // the block's size
    movi    a6, 0
    s32i    a6, a2, CH_NEXT
    s32i    a3, a2, CH_PREV
    s32i    a5, a2, CH_SIZE
    s32i    a6, a2, CH_RET
    s32i    a6, a2, CH_MIRROR
    addi    a6, a2, CH_USABLE_OFF
    add     a6, a6, a4
    s32i    a6, a2, CH_LIMIT
    add     a6, a2, a5
    s32i    a6, a2, CH_TOP
    addi    a6, a2, CH_HEADER
    s32i    a6, a2, CH_BAND
    movi    a6, 1
    beqz    a3, 1f
    l32i    a6, a3, CH_INDEX
    addi    a6, a6, 1
    s32i    a2, a3, CH_NEXT
1:  s32i    a6, a2, CH_INDEX
9:  retw
    .size   silica_rt_chunk_take, . - silica_rt_chunk_take

// silica_rt_chunks_to_heap_from(chunk): the same for an ended actor's chain: every chunk goes back
// to the heap (silica_rt_stack_to_heap).
    .align  4
silica_rt_chunks_to_heap_from:
    entry   a1, 32
1:  beqz    a2, 9f
    l32i    a3, a2, CH_NEXT
    mov     a10, a2
    call8   silica_rt_stack_to_heap
    mov     a2, a3
    j       1b
9:  retw
    .size   silica_rt_chunks_to_heap_from, . - silica_rt_chunks_to_heap_from

// silica_rt_chunks_free_from(chunk): chunk and every chunk above it go back to the stack free
// list (the link of the chunk below is the caller's to clear).
    .align  4
silica_rt_chunks_free_from:
    entry   a1, 32
1:  beqz    a2, 9f
    l32i    a3, a2, CH_NEXT
    mov     a10, a2
    call8   silica_rt_free_stack
    mov     a2, a3
    j       1b
9:  retw
    .size   silica_rt_chunks_free_from, . - silica_rt_chunks_free_from

// silica_rt_chain_bytes(chunk) -> bytes of chunk and every chunk above it.
    .align  4
silica_rt_chain_bytes:
    entry   a1, 32
    movi    a3, 0
1:  beqz    a2, 9f
    l32i    a4, a2, CH_SIZE
    add     a3, a3, a4
    l32i    a2, a2, CH_NEXT
    j       1b
9:  mov     a2, a3
    retw
    .size   silica_rt_chain_bytes, . - silica_rt_chain_bytes

// silica_rt_chain_trim(&head, keep): the chain keeps its first `keep` chunks and the rest go back
// (keep 0: the whole chain, head cleared).
    .align  4
silica_rt_chain_trim:
    entry   a1, 32
    mov     a4, a2                      // a4 = the link that ends the kept part
    l32i    a5, a2, 0                   // a5 = the chunk at that link
1:  beqz    a5, 9f
    beqz    a3, 2f
    addi    a3, a3, -1
    addi    a4, a5, CH_NEXT
    l32i    a5, a5, CH_NEXT
    j       1b
2:  movi    a6, 0
    s32i    a6, a4, 0
    mov     a10, a5
    call8   silica_rt_chunks_free_from
9:  retw
    .size   silica_rt_chain_trim, . - silica_rt_chain_trim

// silica_rt_chunk_next(acb, cur, need, cap, headroom, limit extra) -> the chunk to run in above
// cur: cur's retained successor when it holds `need` bytes above its limit, else a fresh chunk
// after cur (a successor chain too small for the need goes back first). 0 when the heap is
// exhausted; -1 when the actor's lowered reservation would be passed (a chunk under a lowered
// reservation is cut to what the reservation has left, so the cap is reached exactly).
    .align  4
silica_rt_chunk_next:
    entry   a1, 64
    s32i    a2, a1, 0                   // acb
    s32i    a3, a1, 4                   // cur
    s32i    a4, a1, 8                   // need
    s32i    a5, a1, 12                  // cap
    s32i    a6, a1, 16                  // headroom
    s32i    a7, a1, 20                  // extra
    l32i    a8, a3, CH_NEXT
    beqz    a8, 2f
    l32i    a9, a8, CH_SIZE
    addi    a9, a9, -CH_USABLE_OFF
    sub     a9, a9, a7                  // usable above the limit
    bltu    a9, a4, 1f
    mov     a2, a8                      // the retained successor serves
    retw
1:  mov     a10, a8                     // too small: the retained chain above cur goes back
    call8   silica_rt_chunks_free_from
    l32i    a3, a1, 4
    movi    a8, 0
    s32i    a8, a3, CH_NEXT
2:  l32i    a10, a1, 4
    l32i    a11, a1, 8
    l32i    a12, a1, 20
    add     a11, a11, a12               // the need, plus the limit's offset in the block
    addi    a11, a11, CH_USABLE_OFF
    s32i    a11, a1, 28                 // the least block that serves
    l32i    a12, a1, 12
    l32i    a13, a1, 16
    call8   silica_rt_chunk_size
    s32i    a10, a1, 24                 // size
    // a lowered reservation caps what both chains hold together
    l32i    a2, a1, 0
    ACB_RESERVE_LD a4, a2, a9
    beqz    a4, 3f
    l32i    a10, a2, ACB_MCHAIN
    call8   silica_rt_chain_bytes
    mov     a5, a10
    l32i    a10, a2, ACB_ACHAIN
    call8   silica_rt_chain_bytes
    add     a5, a5, a10                 // a5 = held now
    ACB_RESERVE_LD a4, a2, a9
    bltu    a4, a5, 8f
    sub     a4, a4, a5                  // a4 = what the reservation has left
    l32i    a6, a1, 28
    bltu    a4, a6, 8f                  // not even the least block: the reservation is reached
    l32i    a6, a1, 24
    bgeu    a4, a6, 3f
    movi    a6, -16
    and     a4, a4, a6
    s32i    a4, a1, 24                  // cut to what is left (rounded up to 64 by the allocator)
3:  l32i    a10, a1, 24
    l32i    a11, a1, 4
    l32i    a12, a1, 20
    call8   silica_rt_chunk_take
    mov     a2, a10
    retw
8:  movi    a2, -1
    retw
    .size   silica_rt_chunk_next, . - silica_rt_chunk_next

// silica_rt_stack_grow(frame bytes, real a0) -> (a2 the frame's new a1, a3 its new a0). Called by
// an emitted prologue (control.silica function_prologue) whose frame, still empty, is parked 32
// bytes under the limit -- its caller's a1 is at or above the limit, so the spill areas of the
// parked frame and of this chain never coincide with the caller's. The chain runs inside the
// runtime reserve the limit keeps above the band: its depth plus the 32 bytes
// (silica_rt_stack_grow__stack_extra) is part of _silica_rt_depth_reserve (tools/main_stack_bound.py).
// Does not return in main (the limit crossed is main's fatal overflow) or when a lowered
// reservation is reached (the actor ends with :stack_exhausted); aborts when the heap is exhausted.
    .set    silica_rt_stack_grow__stack_extra, 32
    .align  4
    .global silica_rt_stack_grow
    .type   silica_rt_stack_grow, @function
silica_rt_stack_grow:
    entry   a1, 48
    s32i    a2, a1, 0                   // frame bytes
    s32i    a3, a1, 4                   // real a0
    call8   silica_rt_current
    mov     a6, a10                     // a6 = the running context
    rur     a7, threadptr
    l32i    a5, a7, VRG_MCHUNK          // a5 = its current machine chunk
    l8ui    a4, a6, ACB_KIND
    bnez    a4, 8f                      // main: the fatal overflow
    mov     a10, a6
    mov     a11, a5
    l32i    a12, a1, 0
    movi    a13, MCHUNK_CAP
    movi    a14, MCHUNK_HEADROOM
    movi    a15, _silica_rt_depth_reserve
    call8   silica_rt_chunk_next
    beqz    a10, 7f
    movi    a4, -1
    beq     a10, a4, 8f
    mov     a5, a10                     // a5 = the chunk the frame moves to
    l32i    a4, a1, 4
    s32i    a4, a5, CH_RET
    // publish: this core's current chunk, its limit and its guard
    rur     a7, threadptr
    s32i    a5, a7, VRG_MCHUNK
    l32i    a4, a5, CH_LIMIT
    s32i    a4, a7, VRG_MLIMIT
    l32i    a4, a5, CH_BAND
    wsr     a4, dbreaka0
    isync
    // this dispatch's peak (ACB_PEAK bits 0-7) and the actor's high water
    l32i    a4, a5, CH_INDEX
    movi    a8, 255
    bltu    a4, a8, 1f
    mov     a4, a8
1:  l32i    a7, a6, ACB_PEAK
    extui   a8, a7, 0, 8
    bgeu    a8, a4, 2f
    movi    a8, -256
    and     a7, a7, a8
    or      a7, a7, a4
    s32i    a7, a6, ACB_PEAK
2:  l32i    a10, a6, ACB_MCHAIN
    call8   silica_rt_chain_bytes
    l32i    a4, a6, ACB_HW_M
    bgeu    a4, a10, 3f
    s32i    a10, a6, ACB_HW_M
3:  l32i    a2, a5, CH_TOP
    l32i    a4, a1, 0
    sub     a2, a2, a4                  // the frame's new a1: its ENTRY size under the chunk's top
    l32i    a3, a1, 4                   // its new a0: the real one's window increment (bits 31:30)
    movi    a4, 0xc0000000              // on the return trampoline's address
    and     a3, a3, a4
    movi    a4, silica_rt_chunk_return
    movi    a7, 0x3fffffff
    and     a4, a4, a7
    or      a3, a3, a4
    retw
7:  call8   silica_rt_abort_heap_exhausted
8:  // the fault: a store into the current chunk's guard band (main's chunk header names main's band)
    l32i    a4, a5, CH_BAND
    movi    a3, 0
    s32i    a3, a4, 0
9:  j       9b
    .size   silica_rt_stack_grow, . - silica_rt_stack_grow

// silica_rt_chunk_return: where a frame that entered a machine chunk returns to. Runs in its
// caller's window with the caller's a0 and a1, the result in a10:a11; a8, a9 and a12-a15 are the
// returned callee's and free. Makes the chunk below current again and jumps to the real return
// address kept in the chunk's header (bits 31:30 hold the window increment; the code's own top
// bits replace them, as RETW does).
    .set    silica_rt_chunk_return__stack_bound, 0
    .align  4
    .global silica_rt_chunk_return
    .type   silica_rt_chunk_return, @function
silica_rt_chunk_return:
    rur     a8, threadptr
    l32i    a9, a8, VRG_MCHUNK          // the chunk being left
    l32i    a12, a9, CH_PREV
    s32i    a12, a8, VRG_MCHUNK
    l32i    a13, a12, CH_LIMIT
    s32i    a13, a8, VRG_MLIMIT
    l32i    a13, a12, CH_BAND
    wsr     a13, dbreaka0
    isync
    l32i    a13, a9, CH_RET
    movi    a14, 0x3fffffff
    and     a13, a13, a14
    movi    a14, silica_rt_chunk_return
    movi    a15, 0xc0000000
    and     a14, a14, a15
    or      a13, a13, a14
    jx      a13
    .size   silica_rt_chunk_return, . - silica_rt_chunk_return

// silica_rt_aux_grow(): called (CALL8) by an emitted reservation whose new SP, already stored in
// VRG_VSP, is below VRG_ALIMIT; the reservation's size is in VRG_ARG. On return VRG_VSP is the
// reservation at the top of the next auxiliary chunk. a2-a7 are the caller's X0-X2 and are kept.
    .align  4
    .global silica_rt_aux_grow
    .type   silica_rt_aux_grow, @function
silica_rt_aux_grow:
    entry   a1, 64
    s32i    a2, a1, 0
    s32i    a3, a1, 4
    s32i    a4, a1, 8
    s32i    a5, a1, 12
    s32i    a6, a1, 16
    s32i    a7, a1, 20
    call8   silica_rt_current
    mov     a6, a10                     // a6 = the running context
    rur     a7, threadptr
    l32i    a5, a7, VRG_ACHUNK          // a5 = its current auxiliary chunk
    l32i    a4, a7, VRG_ARG
    s32i    a4, a1, 24                  // the reservation
    l8ui    a4, a6, ACB_KIND
    bnez    a4, 8f                      // main: the fatal overflow
    // the mirror: the live bytes above the SP before the reservation (kept), at most
    // AUX_MIRROR_MAX plus what keeps the new SP's phase mod 16 the same as the old one's
    l32i    a8, a7, VRG_VSP
    l32i    a9, a1, 24
    add     a8, a8, a9                  // kept (VRG_VSP stays as stored until the move below)
    l32i    a9, a5, CH_TOP
    sub     a9, a9, a8                  // live bytes above kept in this chunk
    movi    a10, AUX_MIRROR_MAX + 15
    bgeu    a10, a9, 4f
    neg     a10, a8
    extui   a10, a10, 0, 4
    movi    a9, AUX_MIRROR_MAX
    add     a9, a9, a10
4:  s32i    a9, a1, 28                  // the mirror's size
    mov     a10, a6
    mov     a11, a5
    l32i    a12, a1, 24
    add     a12, a12, a9                // the new chunk holds the mirror and the reservation
    movi    a13, ACHUNK_CAP
    movi    a14, ACHUNK_HEADROOM
    movi    a15, 0
    call8   silica_rt_chunk_next
    beqz    a10, 7f
    movi    a4, -1
    beq     a10, a4, 8f
    mov     a5, a10                     // a5 = the chunk SP moves to
    rur     a7, threadptr
    l32i    a3, a1, 24
    l32i    a4, a7, VRG_VSP
    add     a4, a4, a3                  // SP before the reservation, kept for the release
    s32i    a4, a5, CH_RET
    l32i    a9, a1, 28
    s32i    a9, a5, CH_MIRROR
    s32i    a5, a7, VRG_ACHUNK
    l32i    a4, a5, CH_LIMIT
    s32i    a4, a7, VRG_ALIMIT
    l32i    a4, a5, CH_TOP
    sub     a4, a4, a9                  // the mirror's base: a release reaching it pops the chunk
    s32i    a4, a7, VRG_ATOP
    l32i    a8, a5, CH_RET              // copy [kept, kept + mirror) to [base, top)
    add     a11, a8, a9
    mov     a10, a4
5:  bgeu    a8, a11, 6f
    l32i    a12, a8, 0
    s32i    a12, a10, 0
    addi    a8, a8, 4
    addi    a10, a10, 4
    j       5b
6:  sub     a4, a4, a3
    s32i    a4, a7, VRG_VSP
    l32i    a4, a5, CH_BAND
    wsr     a4, dbreaka1
    isync
    // this dispatch's peak (ACB_PEAK bits 8-15) and the actor's high water
    l32i    a4, a5, CH_INDEX
    movi    a8, 255
    bltu    a4, a8, 1f
    mov     a4, a8
1:  l32i    a7, a6, ACB_PEAK
    extui   a8, a7, 8, 8
    bgeu    a8, a4, 2f
    movi    a8, 0xffff00ff
    and     a7, a7, a8
    slli    a4, a4, 8
    or      a7, a7, a4
    s32i    a7, a6, ACB_PEAK
2:  l32i    a10, a6, ACB_ACHAIN
    call8   silica_rt_chain_bytes
    l32i    a4, a6, ACB_HW_A
    bgeu    a4, a10, 3f
    s32i    a10, a6, ACB_HW_A
3:  l32i    a2, a1, 0
    l32i    a3, a1, 4
    l32i    a4, a1, 8
    l32i    a5, a1, 12
    l32i    a6, a1, 16
    l32i    a7, a1, 20
    retw
7:  call8   silica_rt_abort_heap_exhausted
8:  l32i    a4, a5, CH_BAND
    movi    a3, 0
    s32i    a3, a4, 0
9:  j       9b
    .size   silica_rt_aux_grow, . - silica_rt_aux_grow

// silica_rt_aux_release(): called (CALL8) by an emitted release or restore whose new SP, already
// stored in VRG_VSP, is at or above VRG_ATOP or below VRG_ALIMIT: pops auxiliary chunks until the
// SP is inside the current one. A release that lands exactly on a chunk's top continues at the SP
// kept when the chunk was entered; a restore to an older chunk's address keeps its value. Leaf:
// a2-a7 are the caller's and untouched.
    .align  4
    .global silica_rt_aux_release
    .type   silica_rt_aux_release, @function
silica_rt_aux_release:
    entry   a1, 32
    rur     a15, threadptr
    l32i    a13, a15, VRG_ACHUNK        // a13 = chunk
    l32i    a12, a15, VRG_VSP           // a12 = the target
1:  l32i    a11, a13, CH_PREV
    beqz    a11, 5f                     // the first chunk: the target is wherever it is
    l32i    a10, a13, CH_TOP
    bltu    a10, a12, 3f                // above the top: an older chunk's address
    l32i    a9, a13, CH_MIRROR
    sub     a9, a10, a9                 // the mirror's base
    bltu    a12, a9, 2f
    sub     a12, a12, a9                // emptied into the mirror: continue at the same offset
    l32i    a10, a13, CH_RET            // above where the entering reservation began
    add     a12, a12, a10
    mov     a13, a11
    j       1b
2:  l32i    a10, a13, CH_LIMIT
    bgeu    a12, a10, 5f                // inside this chunk
3:  mov     a13, a11
    j       1b
5:  s32i    a13, a15, VRG_ACHUNK
    s32i    a12, a15, VRG_VSP
    l32i    a10, a13, CH_LIMIT
    s32i    a10, a15, VRG_ALIMIT
    l32i    a10, a13, CH_TOP
    l32i    a9, a13, CH_MIRROR
    sub     a10, a10, a9
    l32i    a11, a13, CH_PREV
    bnez    a11, 6f
    movi    a10, -1
6:  s32i    a10, a15, VRG_ATOP
    l32i    a10, a13, CH_BAND
    wsr     a10, dbreaka1
    isync
    retw
    .size   silica_rt_aux_release, . - silica_rt_aux_release

// silica_rt_actor_stacks_prepare(acb): the scheduler's step before a dispatch of an actor with no
// context: first chunks for each chain it holds none of (its first dispatch, or its algorithm
// released everything) -- under a lowered reservation, first chunks the reservation can hold --
// and the frames the switch lands in at the top of the first machine chunk (silica_rt_ctx_prepare).
    .align  4
silica_rt_actor_stacks_prepare:
    entry   a1, 48
    s32i    a2, a1, 0
    movi    a4, MCHUNK_FIRST
    movi    a5, ACHUNK_FIRST
    ACB_RESERVE_LD a3, a2, a6
    beqz    a3, 1f
    srli    a5, a3, 2                   // a quarter for the auxiliary stack, clamped
    movi    a6, -64
    and     a5, a5, a6
    movi    a6, ACHUNK_LOWERED_MIN
    bgeu    a5, a6, 11f
    mov     a5, a6
11: movi    a6, ACHUNK_FIRST
    bgeu    a6, a5, 12f
    mov     a5, a6
12: sub     a4, a3, a5                  // the rest for the machine stack, clamped
    movi    a6, -64
    and     a4, a4, a6
    movi    a6, MCHUNK_LOWERED_MIN
    bgeu    a4, a6, 13f
    mov     a4, a6
13: movi    a6, MCHUNK_FIRST
    bgeu    a6, a4, 1f
    mov     a4, a6
1:  s32i    a4, a1, 4
    s32i    a5, a1, 8
    l32i    a3, a2, ACB_MCHAIN
    bnez    a3, 2f
    l32i    a10, a1, 4
    movi    a11, 0
    movi    a12, _silica_rt_depth_reserve
    call8   silica_rt_chunk_take
    beqz    a10, 7f
    l32i    a2, a1, 0
    s32i    a10, a2, ACB_MCHAIN
    l32i    a4, a2, ACB_HW_M
    l32i    a5, a10, CH_SIZE
    bgeu    a4, a5, 2f
    s32i    a5, a2, ACB_HW_M
2:  l32i    a2, a1, 0
    l32i    a3, a2, ACB_ACHAIN
    bnez    a3, 3f
    l32i    a10, a1, 8
    movi    a11, 0
    movi    a12, 0
    call8   silica_rt_chunk_take
    beqz    a10, 7f
    l32i    a2, a1, 0
    s32i    a10, a2, ACB_ACHAIN
    l32i    a4, a2, ACB_HW_A
    l32i    a5, a10, CH_SIZE
    bgeu    a4, a5, 3f
    s32i    a5, a2, ACB_HW_A
3:  l32i    a2, a1, 0
    l32i    a3, a2, ACB_MCHAIN
    s32i    a3, a2, ACB_MCUR
    l32i    a4, a2, ACB_ACHAIN
    s32i    a4, a2, ACB_ACUR
    l32i    a5, a2, ACB_PEAK            // this dispatch starts in the first chunk of each chain
    movi    a6, 0xffff0000
    and     a5, a5, a6
    movi    a6, 0x0101
    or      a5, a5, a6
    s32i    a5, a2, ACB_PEAK
    mov     a10, a2
    movi    a11, silica_rt_actor_landing
    l32i    a12, a3, CH_TOP
    l32i    a13, a4, CH_TOP
    call8   silica_rt_ctx_prepare
    retw
7:  call8   silica_rt_abort_heap_exhausted
    retw
    .size   silica_rt_actor_stacks_prepare, . - silica_rt_actor_stacks_prepare

// silica_rt_actor_boundary(acb): the actor's dispatch returned (status ST_BOUNDARY: its stack is
// empty and its context abandoned). Releases what its stack_policy algorithm does not keep, then,
// under the lock, applies a pending migration and ends the actor if asked to, else parks it or
// re-queues it (a pushed actor is the other core's to run as soon as the lock drops, which is why
// the release comes first).
    .align  4
silica_rt_actor_boundary:
    entry   a1, 48
    mov     a10, a2
    call8   silica_rt_actor_release_policy
    movi    a3, 0
    s32i    a3, a2, ACB_CTX_A1          // re-entered afresh at its next dispatch
    SCHED_LOCK a8, a9
    l8ui    a4, a2, ACB_TARGET
    beqz    a4, 1f
    addi    a4, a4, -1
    s8i     a4, a2, ACB_CORE
    movi    a4, 0
    s8i     a4, a2, ACB_TARGET
1:  l8ui    a4, a2, ACB_ALIVE
    beqz    a4, 5f
    l32i    a4, a2, ACB_SB
    beqz    a4, 11f
    l32i    a4, a4, SB_IN_HEAD
    bnez    a4, 2f
11: l32i    a4, a2, ACB_MB_HEAD
    bnez    a4, 2f
    movi    a4, ST_IDLE
    s8i     a4, a2, ACB_STATUS
    SCHED_UNLOCK a8, a9
    retw
2:  movi    a4, ST_READY
    s8i     a4, a2, ACB_STATUS
    mov     a10, a2
    call8   silica_rt_rq_push
    SCHED_UNLOCK a8, a9
    retw
5:  movi    a4, ST_RUNNING
    s8i     a4, a2, ACB_STATUS
    SCHED_UNLOCK a8, a9
    mov     a10, a2
    movi    a11, 1                      // ended by remove_actor / kill_abnormal
    call8   silica_rt_actor_exit
    mov     a10, a2
    call8   silica_rt_actor_recycle
    retw
    .size   silica_rt_actor_boundary, . - silica_rt_actor_boundary

// silica_rt_actor_release_policy(acb): the five release algorithms of spec §15.1.2.2 at the
// dispatch boundary, in chunks (the sizes the stack grew by). ACB_PEAK holds how many chunks of
// each chain this dispatch reached; what the algorithm keeps is a prefix of each chain:
//   1 release_on_return   nothing
//   2 keep_last_message   what this dispatch reached (also an unset algorithm)
//   3 track_recent_peak   the most any of the last 32 dispatches reached (the ring)
//   4 release_when_idle   everything, stamped; silica_rt_actor_idle_scan frees it a second later
//   5 keep_high_water     everything
    .align  4
silica_rt_actor_release_policy:
    entry   a1, 48
    l32i    a3, a2, ACB_POLICY
    extui   a3, a3, 0, 4
    l32i    a4, a2, ACB_PEAK
    extui   a5, a4, 0, 8                // machine chunks reached
    extui   a6, a4, 8, 8                // auxiliary chunks reached
    movi    a7, 1
    beq     a3, a7, 1f
    movi    a7, 3
    beq     a3, a7, 3f
    movi    a7, 4
    beq     a3, a7, 4f
    movi    a7, 5
    beq     a3, a7, 8f
    j       2f
1:  movi    a5, 0
    movi    a6, 0
    j       2f
3:  // the ring takes this dispatch (nibbles, saturated), then the most any entry holds is kept
    // (an actor without a ring block keeps what this dispatch reached, as keep_last_message)
    l32i    a3, a2, ACB_RING
    beqz    a3, 2f
    extui   a7, a4, 16, 8
    movi    a8, 15
    bltu    a5, a8, 31f
    mov     a5, a8
31: bltu    a6, a8, 32f
    mov     a6, a8
32: slli    a9, a6, 4
    or      a9, a9, a5
    add     a8, a3, a7
    s8i     a9, a8, 0
    addi    a7, a7, 1
    movi    a8, 31
    and     a7, a7, a8
    slli    a7, a7, 16
    movi    a8, 0xff00ffff
    and     a4, a4, a8
    or      a4, a4, a7
    s32i    a4, a2, ACB_PEAK
    movi    a5, 0
    movi    a6, 0
    movi    a7, 0
33: add     a8, a3, a7
    l8ui    a9, a8, 0
    extui   a8, a9, 0, 4
    bgeu    a5, a8, 34f
    mov     a5, a8
34: extui   a8, a9, 4, 4
    bgeu    a6, a8, 35f
    mov     a6, a8
35: addi    a7, a7, 1
    movi    a8, 32
    bltu    a7, a8, 33b
    j       2f
4:  call8   silica_rt_now_ticks
    s32i    a10, a2, ACB_LAST_MSG
    j       8f
2:  addi    a10, a2, ACB_MCHAIN
    mov     a11, a5
    call8   silica_rt_chain_trim
    addi    a10, a2, ACB_ACHAIN
    mov     a11, a6
    call8   silica_rt_chain_trim
8:  l32i    a4, a2, ACB_PEAK            // the next dispatch counts from its first chunks
    movi    a8, 0xffff0000
    and     a4, a4, a8
    s32i    a4, a2, ACB_PEAK
    retw
    .size   silica_rt_actor_release_policy, . - silica_rt_actor_release_policy

// silica_rt_actor_idle_scan(core block): at most once a quarter second while this core idles,
// every :release_when_idle actor pinned to it that is parked at a boundary and has had no message
// for a second gives its chunks back (spec §15.1.2.2). Under the scheduler lock, so an actor another
// core is ending (status RUNNING there) or waking (READY) is left alone; its own core is the only
// one that dispatches it.
    .align  4
silica_rt_actor_idle_scan:
    entry   a1, 48
    s32i    a2, a1, 0
    call8   silica_rt_now_ticks
    s32i    a10, a1, 4
    l32i    a2, a1, 0
    l32i    a3, a2, CORE_ID
    slli    a3, a3, 2
    movi    a4, silica_rt_idle_scan_at
    add     a3, a3, a4
    l32i    a4, a3, 0
    sub     a5, a10, a4
    movi    a6, IDLE_SCAN_TICKS
    bltu    a5, a6, 7f
    s32i    a10, a3, 0
    SCHED_LOCK a8, a9
    movi    a7, silica_rt_acb_all
    l32i    a7, a7, 0
1:  beqz    a7, 6f
    l8ui    a3, a7, ACB_KIND
    bnez    a3, 2f
    l8ui    a3, a7, ACB_CORE
    l32i    a4, a2, CORE_ID
    bne     a3, a4, 2f
    l8ui    a3, a7, ACB_STATUS
    bnez    a3, 2f                      // ST_IDLE only
    l32i    a3, a7, ACB_POLICY
    extui   a3, a3, 0, 4
    movi    a4, 4
    bne     a3, a4, 2f
    l32i    a3, a7, ACB_MCHAIN
    beqz    a3, 2f
    l32i    a3, a7, ACB_LAST_MSG
    l32i    a4, a1, 4
    sub     a4, a4, a3
    movi    a5, IDLE_RELEASE_TICKS
    bltu    a4, a5, 2f
    addi    a10, a7, ACB_MCHAIN
    movi    a11, 0
    call8   silica_rt_chain_trim
    addi    a10, a7, ACB_ACHAIN
    movi    a11, 0
    call8   silica_rt_chain_trim
2:  l32i    a7, a7, ACB_ALL_NEXT
    j       1b
6:  SCHED_UNLOCK a8, a9
7:  retw
    .size   silica_rt_actor_idle_scan, . - silica_rt_actor_idle_scan

// silica_rt_ctx_prepare(acb, landing, machine top, auxiliary top): fabricate the frames that make
// the next switch into acb land at `landing` with a2 = acb and a1 = top - 64.
//   [top-144, top-128)  a0-a3 of the landing frame (0, top-64, acb, 0), read by _WindowUnderflow8
//                       from 16 bytes under the fake callee frame at top-128
//   [top-76]            the landing frame's caller SP (top), from which a4-a7 are read at top-32
    .align  4
silica_rt_ctx_prepare:
    entry   a1, 32
    addi    a6, a4, -144                // a6 = top - 144; offsets below are relative to it
    movi    a7, 0
    s32i    a7, a6, 0                   // [top-144] a0
    addi    a7, a4, -64
    s32i    a7, a6, 4                   // [top-140] a1 = top - 64
    s32i    a2, a6, 8                   // [top-136] a2 = acb
    movi    a7, 0
    s32i    a7, a6, 12                  // [top-132] a3
    s32i    a4, a6, 68                  // [top-76]  the landing frame's caller SP = top
    s32i    a7, a6, 112                 // [top-32 .. top-16) its a4-a7
    s32i    a7, a6, 116
    s32i    a7, a6, 120
    s32i    a7, a6, 124
    movi    a7, 0x3fffffff
    and     a3, a3, a7
    movi    a7, 0x80000000              // call8 window increment in the return address
    or      a3, a3, a7
    s32i    a3, a2, ACB_CTX_A0
    addi    a7, a4, -128
    s32i    a7, a2, ACB_CTX_A1
    s32i    a5, a2, ACB_CTX_VSP
    retw
    .size   silica_rt_ctx_prepare, . - silica_rt_ctx_prepare

// Landing points. Entered by RETW with a1 = top - 64 of the context's stack and a2 = its ACB.
    .align  4
silica_rt_actor_landing:
    mov     a10, a2
    call8   silica_rt_actor_main
1:  j       1b

    .align  4
silica_rt_sched_landing:
    mov     a10, a2
    call8   silica_rt_sched_loop
1:  j       1b

// silica_rt_yield_to_sched(): switch from the running context to this core's scheduler. The
// caller has set its own status under the lock and released it. Returns when the scheduler
// dispatches the context again.
    .align  4
    .global silica_rt_yield_to_sched
silica_rt_yield_to_sched:
    entry   a1, 32
    THIS_CORE_BLOCK a3, a4
    l32i    a10, a3, CORE_CURRENT
    l32i    a11, a3, CORE_SCHED
    call8   silica_rt_ctx_switch
    retw
    .size   silica_rt_yield_to_sched, . - silica_rt_yield_to_sched

// silica_rt_current() -> the running context's ACB (main's pseudo-ACB in main).
    .align  4
    .global silica_rt_current
silica_rt_current:
    entry   a1, 32
    THIS_CORE_BLOCK a3, a4
    l32i    a2, a3, CORE_CURRENT
    movi    a3, 0
    retw
    .size   silica_rt_current, . - silica_rt_current

// silica_rt_current_actor() -> the running actor's ACB, or 0 in main / the scheduler.
    .align  4
    .global silica_rt_current_actor
silica_rt_current_actor:
    entry   a1, 32
    THIS_CORE_BLOCK a3, a4
    l32i    a2, a3, CORE_CURRENT
    movi    a3, 0
    beqz    a2, 1f
    l8ui    a4, a2, ACB_KIND
    beqz    a4, 1f
    movi    a2, 0
1:  retw
    .size   silica_rt_current_actor, . - silica_rt_current_actor

// ---------------------------------------------------------------------------------------------
// The scheduler loop, one per core, on its own stack.
//
// Pops the next ready context of this core (highest priority first), records it as current, and
// switches to it; the context switches back when it suspends, reaches its dispatch boundary or
// ends. An actor at a boundary has no context to resume: its loop (silica_rt_actor_main) is
// entered afresh at each dispatch, on first chunks taken here when it holds none
// (silica_rt_actor_stacks_prepare), and after the switch back the scheduler releases what its
// stack_policy algorithm does not keep and parks or re-queues it (silica_rt_actor_boundary); so
// the release never runs on the stack being released. A context that was
// ended while parked (kill_abnormal, remove_actor, a fault) is not resumed: its exit path runs here,
// on the scheduler's stack, and its stacks are recycled. When nothing is ready the core spins
// (cross-core wake-ups arrive through the queues under the lock). An idle core spins on a lock-free
// peek of its queues, so its idling does not slow the other core's spawns, casts and calls with lock
// traffic; whatever the peek sees is confirmed under the lock. A program that has gone quiet is not
// ended: main stays parked in wait_for_exit until a request is recorded (spec §15.1.2.5).
//
// Core 0's loop also reads the console's receive side, the program's standard input on this target:
// every pass, idle or between dispatches, pops what waits in the UART RX FIFO through
// rt_console.S silica_rt_console_poll_exit_line, and a completed "exit" line records an exit request
// with value 0 exactly as cast_exit(0) would. The loop is the right reader because it runs only
// while main has yielded (a call, or wait_for_exit), which is when an exit line can be acted on, and
// a dispatch that never returns stops it, as it stops everything else on this cooperative core: no
// line is read until the scheduler runs again. A line read before main reaches wait_for_exit is
// kept as a recorded request, as a line typed early stays buffered in a host's standard input.

    .align  4
    .global silica_rt_sched_loop
    .type   silica_rt_sched_loop, @function
silica_rt_sched_loop:
    entry   a1, 48
    l8ui    a3, a2, ACB_CORE
    slli    a3, a3, 6
    movi    a4, silica_rt_cores
    add     a3, a3, a4                  // a3 = my core block
1:  // core 0: the console's receive side (an "exit" line ends the program, §15.1.2.5)
    l32i    a5, a3, CORE_ID
    bnez    a5, 12f
    call8   silica_rt_console_poll_exit_line
    beqz    a10, 12f
    movi    a10, 0
    movi    a11, 0
    call8   silica_rt_exit_request_record
12: // :release_when_idle actors of this core, a second after their last message (at most every
    // quarter second: a core busy with one actor's calls still frees another's)
    mov     a10, a3
    call8   silica_rt_actor_idle_scan
    // lock-free peek: anything queued?
    l32i    a5, a3, CORE_RQ_HEAD
    bnez    a5, 10f
    l32i    a5, a3, CORE_RQ_HEAD + 4
    bnez    a5, 10f
    l32i    a5, a3, CORE_RQ_HEAD + 8
    bnez    a5, 10f
    movi    a5, 0
    s32i    a5, a3, CORE_BUSY           // this core's own word (get_actor_memory_usage and diagnostics)
    memw
    j       1b
10: SCHED_LOCK a8, a9
    mov     a10, a3
    call8   silica_rt_rq_pop
    mov     a4, a10                     // a4 = next context
    bnez    a4, 3f
    movi    a5, 0                       // nothing after all
    s32i    a5, a3, CORE_BUSY
    SCHED_UNLOCK a8, a9
    j       1b
3:  l8ui    a5, a4, ACB_STATUS
    movi    a6, ST_DEAD
    beq     a5, a6, 7f                  // ended while queued: only its ACB is left to recycle
    movi    a6, ST_FAULTED
    beq     a5, a6, 6f
    l8ui    a5, a4, ACB_ALIVE
    beqz    a5, 6f                      // ended while parked: exit path here
    movi    a5, ST_RUNNING
    s8i     a5, a4, ACB_STATUS
    movi    a5, 1
    s32i    a5, a3, CORE_BUSY
    s32i    a4, a3, CORE_CURRENT
    SCHED_UNLOCK a8, a9
    // an actor at a dispatch boundary has no context: it gets first chunks unless its algorithm
    // kept them, and is entered afresh at the top of its loop
    l32i    a5, a4, ACB_CTX_A1
    bnez    a5, 31f
    mov     a10, a4
    call8   silica_rt_actor_stacks_prepare
31: mov     a10, a2
    mov     a11, a4
    call8   silica_rt_ctx_switch
    // the context suspended, reached its boundary or ended
    s32i    a2, a3, CORE_CURRENT
    l8ui    a5, a4, ACB_STATUS
    movi    a6, ST_DEAD
    bne     a5, a6, 32f
    mov     a10, a4
    call8   silica_rt_actor_recycle
    j       1b
32: movi    a6, ST_BOUNDARY
    bne     a5, a6, 1b
    mov     a10, a4
    call8   silica_rt_actor_boundary
    j       1b
6:  // exit path on behalf of a context that will never run again: a faulted actor (no root note)
    // or one ended while parked
    l8ui    a11, a4, ACB_STATUS
    movi    a5, ST_FAULTED
    sub     a11, a11, a5
    movi    a5, ST_RUNNING
    s8i     a5, a4, ACB_STATUS
    s32i    a2, a3, CORE_CURRENT
    SCHED_UNLOCK a8, a9
    mov     a10, a4
    call8   silica_rt_actor_exit
    mov     a10, a4
    call8   silica_rt_actor_recycle
    j       1b
7:  SCHED_UNLOCK a8, a9
    mov     a10, a4
    call8   silica_rt_free_acb
    j       1b
    .size   silica_rt_sched_loop, . - silica_rt_sched_loop

// silica_rt_exit_request_record(lo, hi) -> 1 when this is the first exit request: the int64 value
// (a2 low word, a3 high word) is recorded under the flag and main, if it is parked in wait_for_exit
// (ST_WAITQ), is made ready on core 0's queue;
// 0 when a request was already recorded, which then changes nothing (spec §15.1.2.5: the first
// request wins). Takes the scheduler lock; called from any core (cast_exit) and from core 0's
// scheduler loop (the console exit line). main not yet parked finds the word when it reaches
// wait_for_exit, under the same lock, so no request is lost between the two.
    .align  4
silica_rt_exit_request_record:
    entry   a1, 32
    SCHED_LOCK a8, a9
    movi    a4, silica_rt_exit_flag
    l32i    a5, a4, 0
    bnez    a5, 2f
    movi    a5, 1
    s32i    a5, a4, 0
    movi    a4, silica_rt_exit_request
    s32i    a2, a4, 0
    s32i    a3, a4, 4
    movi    a5, silica_rt_main_acb
    l8ui    a6, a5, ACB_STATUS
    movi    a7, ST_WAITQ
    bne     a6, a7, 1f
    movi    a6, ST_READY
    s8i     a6, a5, ACB_STATUS
    mov     a10, a5
    call8   silica_rt_rq_push
1:  SCHED_UNLOCK a8, a9
    movi    a2, 1
    retw
2:  SCHED_UNLOCK a8, a9
    movi    a2, 0
    retw
    .size   silica_rt_exit_request_record, . - silica_rt_exit_request_record

// silica_rt_actor_recycle_stacks(acb): give an ended actor's chunks back, to the heap.
    .align  4
silica_rt_actor_recycle_stacks:
    entry   a1, 32
    l8ui    a3, a2, ACB_KIND
    bnez    a3, 9f
    mov     a10, a2
    call8   silica_rt_actor_note_hw     // the exit diagnostic's deepest-stack figures
    l32i    a10, a2, ACB_MCHAIN
    call8   silica_rt_chunks_to_heap_from
    l32i    a10, a2, ACB_ACHAIN
    call8   silica_rt_chunks_to_heap_from
    movi    a3, 0
    s32i    a3, a2, ACB_MCHAIN
    s32i    a3, a2, ACB_ACHAIN
    s32i    a3, a2, ACB_MCUR
    s32i    a3, a2, ACB_ACUR
9:  retw
    .size   silica_rt_actor_recycle_stacks, . - silica_rt_actor_recycle_stacks

// silica_rt_actor_recycle(acb): the stacks, then the ACB itself.
    .align  4
silica_rt_actor_recycle:
    entry   a1, 32
    l8ui    a3, a2, ACB_KIND
    bnez    a3, 9f
    mov     a10, a2
    call8   silica_rt_actor_recycle_stacks
    mov     a10, a2
    call8   silica_rt_free_acb
9:  retw
    .size   silica_rt_actor_recycle, . - silica_rt_actor_recycle

// ---------------------------------------------------------------------------------------------
// The actor's loop (spec §15.1.2), on the actor's first machine chunk: one dispatch per entry. The
// scheduler enters it afresh for every dispatch (the context is not kept across the boundary, so
// the chunks can be released there) and it ends by parking at the boundary (ST_BOUNDARY) and
// switching to the scheduler, which never resumes it. Frame: [a1, a1+24) the reply tuple buffer
// the behaviour fills through X2 (three 8-byte slots); [a1+24] the node being served.

    .align  4
    .global silica_rt_actor_main
    .type   silica_rt_actor_main, @function
silica_rt_actor_main:
    entry   a1, 80
    // a2 = acb. First dispatch: the supervisor start trampoline runs once (its init on this
    // stack, which grows as the init needs), then whoever waited in spawn for it is woken (the
    // reference spawn returns only after the trampoline ran).
    l32i    a5, a2, ACB_SB
    beqz    a5, 1f
    l32i    a3, a5, SB_TRAMP
    beqz    a3, 1f
    l32i    a4, a5, SB_TRAMP_RAN
    bbsi    a4, 0, 1f                   // TR_RAN: already started
    mov     a10, a2
    movi    a11, 0
    callx8  a3
    SCHED_LOCK a8, a9                   // the spawner's wait word is cleared and read under the lock
    l32i    a4, a5, SB_TRAMP_RAN        // (spawn_common waits until it is 0)
    movi    a6, TR_RAN
    or      a4, a4, a6
    s32i    a4, a5, SB_TRAMP_RAN
    l32i    a4, a5, SB_SPAWN_WAITER
    beqz    a4, 13f
    movi    a6, 0
    s32i    a6, a5, SB_SPAWN_WAITER
    mov     a10, a4
    call8   silica_rt_wake
13: SCHED_UNLOCK a8, a9
1:  // one message: supervision ingress (a supervisor's block) before the standard mailbox
    SCHED_LOCK a8, a9
    l32i    a5, a2, ACB_SB
    beqz    a5, 2f
    l32i    a3, a5, SB_IN_HEAD
    beqz    a3, 2f
    l32i    a4, a3, MSG_NEXT
    s32i    a4, a5, SB_IN_HEAD
    bnez    a4, 11f
    s32i    a4, a5, SB_IN_TAIL
11: l32i    a4, a5, SB_IN_DEPTH
    addi    a4, a4, -1
    s32i    a4, a5, SB_IN_DEPTH
    j       3f
2:  l32i    a3, a2, ACB_MB_HEAD
    beqz    a3, 12f
    l32i    a4, a3, MSG_NEXT
    s32i    a4, a2, ACB_MB_HEAD
    bnez    a4, 3f
    s32i    a4, a2, ACB_MB_TAIL
    j       3f
12: // nothing to serve (a supervisor's first dispatch runs only its trampoline): the boundary
    SCHED_UNLOCK a8, a9
    j       6f
3:  SCHED_UNLOCK a8, a9
    s32i    a3, a1, 24
    l32i    a4, a3, MSG_KIND
    movi    a5, 2
    bne     a4, a5, 4f
    // exit notice: a structured payload runs the supervisor's restart logic, never the behaviour
    l32i    a5, a3, MSG_INGRESS_KIND
    bnez    a5, 4f
    l32i    a5, a3, MSG_PAYLOAD
    beqz    a5, 31f
    l32i    a10, a5, 0
    mov     a11, a2
    l32i    a12, a5, 8
    call8   silica_rt_supervisor_maybe_restart
    l32i    a10, a1, 24
    l32i    a10, a10, MSG_PAYLOAD
    call8   silica_rt_exit_payload_free
31: l32i    a10, a1, 24
    call8   silica_rt_free_node
    j       6f
4:  // the behaviour: X0 = message, X1 = state, X2 = reply buffer; X0 back = tuple pointer
    l32i    a8, a2, ACB_BEH
    beqz    a8, 5f                      // a supervisor with no behaviour of its own drops the message
    // ACB_ACTIVE_CALL names the node being served, a cast's as well as a call's: an actor that ends
    // inside its behaviour (a trap, a fault, a kill while it is suspended) never comes back here, so
    // silica_rt_actor_exit completes the call or gives the cast node back. Set only once the
    // behaviour will run: the drop at 5: frees the node, which must not stay named here.
    s32i    a3, a2, ACB_ACTIVE_CALL
    // the FailureReporter's report (MSG_PAYLOAD_OWNED 2) is recorded, so a cast of it is seen
    l32i    a4, a3, MSG_PAYLOAD_OWNED
    movi    a5, 2
    bne     a4, a5, 44f
    l32i    a10, a3, MSG_PAYLOAD
    call8   silica_rt_report_begin
44: mov     a10, a2
    mov     a11, a3
    mov     a12, a1
    call8   silica_rt_run_behaviour
    l32i    a3, a1, 24
    // the message copy is dropped now that the behaviour has read it, unless the new state packs it
    // or (the report) the behaviour sent it on to another actor
    l32i    a4, a3, MSG_PAYLOAD_OWNED
    beqz    a4, 42f
    movi    a5, 0
    s32i    a5, a3, MSG_PAYLOAD_OWNED
    movi    a5, 2
    bne     a4, a5, 45f
    l32i    a10, a3, MSG_PAYLOAD
    call8   silica_rt_report_end
    l32i    a3, a1, 24
    bnez    a10, 42f
45: l32i    a10, a3, MSG_PAYLOAD
    l32i    a12, a2, ACB_STATE
    movi    a14, 0
    call8   silica_rt_state_release
    l32i    a3, a1, 24
42: l32i    a4, a3, MSG_KIND
    movi    a5, 0
    s32i    a5, a2, ACB_ACTIVE_CALL
    movi    a6, 1
    bne     a4, a6, 5f
    // a call: the reply is in the node; wake the caller
    SCHED_LOCK a8, a9
    movi    a5, 1
    s32i    a5, a3, MSG_REPLY_SET
    l32i    a10, a3, MSG_CALLER
    beqz    a10, 43f
    call8   silica_rt_wake
43: SCHED_UNLOCK a8, a9
    j       6f
5:  l32i    a10, a1, 24
    call8   silica_rt_node_release_payload
    l32i    a10, a1, 24
    call8   silica_rt_free_node
6:  // dispatch boundary: the stack is empty from here on. The scheduler releases what the policy
    // does not keep, applies a pending migration, ends the actor if asked to, else parks or
    // re-queues it for its fair share of the core (§23.1.1): silica_rt_actor_boundary.
    movi    a4, ST_BOUNDARY
    s8i     a4, a2, ACB_STATUS
    memw
    call8   silica_rt_yield_to_sched
9:  j       9b
    .size   silica_rt_actor_main, . - silica_rt_actor_main

// silica_rt_spawn_waiter_wake(acb): the spawner suspended in spawn_common until the supervisor's
// trampoline ran is woken once, by the trampoline's end (actor_main) or by the actor's exit when
// it died before that (a stack overflow in init, for one); otherwise the spawner never returns.
    .align  4
silica_rt_spawn_waiter_wake:
    entry   a1, 32
    l32i    a3, a2, ACB_SB
    beqz    a3, 8f                      // (SCHED_LOCK defines a local 9: of its own)
    SCHED_LOCK a8, a9
    l32i    a4, a3, SB_SPAWN_WAITER
    beqz    a4, 7f
    movi    a5, 0
    s32i    a5, a3, SB_SPAWN_WAITER
    mov     a10, a4
    call8   silica_rt_wake
7:  SCHED_UNLOCK a8, a9
8:  retw
    .size   silica_rt_spawn_waiter_wake, . - silica_rt_spawn_waiter_wake

// silica_rt_run_behaviour(acb, node, reply buffer): calls the behaviour with X0 = message, X1 =
// state, X2 = the buffer, and copies the result out (a call: reply into the node, state into the
// ACB; a cast: state into the ACB). The reply and state slots hold scalars or heap addresses: the
// emitted behaviour epilogue moves a composite reply and a changed composite state into heap blocks
// before returning (actor_memory_budget_plan.md item B, prims_actors.silica), so nothing points into
// the behaviour's frame region once it has returned, and the loop's later frames may reuse it. (Until
// 2026-10-08 this frame was a 1,568-byte pad that kept that region intact, item C.) No call is made
// here after the behaviour returns.
    .align  4
silica_rt_run_behaviour:
    entry   a1, 32
    l32i    a10, a3, MSG_PAYLOAD
    l32i    a11, a3, MSG_PAYLOAD + 4
    l32i    a12, a2, ACB_STATE
    l32i    a13, a2, ACB_STATE + 4
    mov     a14, a4
    movi    a15, 0
    l32i    a8, a2, ACB_BEH
    callx8  a8
    // The layout follows the tuple's own tag (the image's :reply / :no_reply atoms, emitted by the
    // compiler as silica_rt_reply_tag / silica_rt_no_reply_tag, -1 when unused), not the message
    // kind: a cast that reaches a call-style behaviour (an untraced reference, a registry name,
    // FailureReporter delivery) keeps the returned state and drops the reply, and a call to a
    // cast-style behaviour gets 0. The runtime-internal behaviours write neither tag and keep the
    // message-kind rule.
    l32i    a4, a10, 0
    movi    a6, silica_rt_reply_tag
    l32i    a6, a6, 0
    beq     a4, a6, 2f
    movi    a6, silica_rt_no_reply_tag
    l32i    a6, a6, 0
    beq     a4, a6, 3f
    l32i    a4, a3, MSG_KIND
    movi    a6, 1
    bne     a4, a6, 1f
2:  // (:reply, value, state): reply at +8 (a call only), state at +16
    l32i    a12, a10, 16
    l32i    a13, a10, 20
    s32i    a12, a2, ACB_STATE
    s32i    a13, a2, ACB_STATE + 4
    l32i    a4, a3, MSG_KIND
    movi    a6, 1
    bne     a4, a6, 4f
    l32i    a12, a10, 8
    l32i    a13, a10, 12
    s32i    a12, a3, MSG_REPLY
    s32i    a13, a3, MSG_REPLY + 4
4:  retw
3:  // a cast-style result to a call: the reply is 0
    l32i    a4, a3, MSG_KIND
    movi    a6, 1
    bne     a4, a6, 1f
    movi    a12, 0
    s32i    a12, a3, MSG_REPLY
    s32i    a12, a3, MSG_REPLY + 4
1:  // (:no_reply, state): state at +8
    l32i    a12, a10, 8
    l32i    a13, a10, 12
    s32i    a12, a2, ACB_STATE
    s32i    a13, a2, ACB_STATE + 4
    retw
    .size   silica_rt_run_behaviour, . - silica_rt_run_behaviour

// ---------------------------------------------------------------------------------------------
// Ending an actor (spec §15.1.2.3): notify the supervisor, print the failure report the reference
// prints, complete every outstanding call with the death result (the caller raises actor_not_found), drop the rest of the
// mailbox, remove the registered name, and mark the ACB dead. Runs on the dying actor's stack (its
// own loop found alive == 0, or a trap inside a behaviour) or on the scheduler's / the killer's.

    .align  4
    .global silica_rt_actor_exit
    .type   silica_rt_actor_exit, @function
silica_rt_actor_exit:
    entry   a1, 32
    // an ending supervisor shuts its children down first (spec §15.4.8.4, §15.4.12.2): their names
    // are free before its own exit reaches its supervisor, which may restart it at once, and their
    // reports precede its own. It is marked ended first, so its restart logic starts nothing more.
    l32i    a4, a2, ACB_SB
    beqz    a4, 1f
    movi    a4, 0
    s8i     a4, a2, ACB_ALIVE
    mov     a10, a2
    call8   silica_rt_sup_shutdown_children
1:  mov     a10, a2
    mov     a11, a3
    call8   silica_rt_actor_exit_body
    retw
    .size   silica_rt_actor_exit, . - silica_rt_actor_exit

// silica_rt_actor_exit_body(acb, root note): the exit path without the children's shutdown, for a
// child that silica_rt_sup_shutdown_children ends (it has no live child left by then: the shutdown
// ends a subtree deepest first, so no exit path nests inside another).
    .align  4
    .global silica_rt_actor_exit_body
    .type   silica_rt_actor_exit_body, @function
silica_rt_actor_exit_body:
    entry   a1, 48
    s32i    a3, a1, 0                   // [a1+0] the root note may print (below)
    movi    a3, 0
    s8i     a3, a2, ACB_ALIVE
    // a supervisor that ends inside its start trampoline (its init failed) is marked: its spawner,
    // still waiting in spawn, gets no live actor, and its exit notice holds the ACB (TR_NOTICE)
    l32i    a4, a2, ACB_SB
    beqz    a4, 20f
    l32i    a5, a4, SB_TRAMP
    beqz    a5, 20f
    SCHED_LOCK a8, a9
    l32i    a5, a4, SB_TRAMP_RAN
    bbsi    a5, 0, 21f
    movi    a6, TR_INIT_DEAD
    or      a5, a5, a6
    s32i    a5, a4, SB_TRAMP_RAN
21: SCHED_UNLOCK a8, a9
20: movi    a3, 0
    l32i    a4, a2, ACB_WAIT_NODE       // a call this actor was suspended in must not wake it later
    beqz    a4, 0f
    s32i    a3, a4, MSG_CALLER
    s32i    a3, a2, ACB_WAIT_NODE
0:  movi    a7, 0                       // a7 = "no supervisor" from deliver_exit
    l32i    a3, a2, ACB_SB
    beqz    a3, 12f
    l32i    a3, a3, SB_SYNC_REPORTED
    bnez    a3, 1f
12:
    // the death is in flight until its report is queued or written: the supervisor may end on this
    // exit, and main with it, before this actor reports (the exit drain waits for the count)
    SCHED_LOCK a8, a9
    movi    a3, silica_rt_report_inflight
    l32i    a4, a3, 0
    addi    a4, a4, 1
    s32i    a4, a3, 0
    SCHED_UNLOCK a8, a9
    mov     a10, a2
    call8   silica_rt_actor_deliver_exit
    mov     a7, a10
    // a root actor's note goes out before its report reaches a registered FailureReporter, which
    // may end the program (cast_exit) once it has the report; a7 = 0 then (no second note below)
    beqz    a7, 17f
    l32i    a3, a1, 0
    beqz    a3, 17f
    movi    a3, silica_rt_root_failure_reporter
    l32i    a3, a3, 0
    beqz    a3, 17f
    movi    a10, silica_rt_root_exit_msg
    call8   silica_rt_puts
    movi    a7, 0
17: mov     a10, a2
    call8   silica_rt_actor_deliver_unwind_report
    SCHED_LOCK a8, a9
    movi    a3, silica_rt_report_inflight
    l32i    a4, a3, 0
    addi    a4, a4, -1
    s32i    a4, a3, 0
    SCHED_UNLOCK a8, a9
1:  // a spawner waiting for this supervisor's start resumes once the report is queued (the hosts'
    // order: the report reaches the FailureReporter before spawn returns)
    mov     a10, a2
    call8   silica_rt_spawn_waiter_wake
    // outstanding calls: the one being served, then every queued call; other messages are dropped
    SCHED_LOCK a8, a9
    l32i    a3, a2, ACB_ACTIVE_CALL
    beqz    a3, 2f
    movi    a4, 0
    s32i    a4, a2, ACB_ACTIVE_CALL
    l32i    a4, a3, MSG_KIND
    movi    a5, 1
    bne     a4, a5, 13f
    mov     a10, a3
    call8   silica_rt_node_release_payload
    mov     a10, a3
    call8   silica_rt_complete_death_locked
    j       2f
13: // the cast (or ingress) node being served: its dispatch never returns, so it goes back here,
    // once. A record copy goes back with it; the report a FailureReporter was handling goes back
    // unless it was sent on (silica_rt_report_end), as at a normal return.
    l32i    a4, a3, MSG_PAYLOAD_OWNED
    movi    a5, 2
    bne     a4, a5, 14f
    movi    a5, 0
    s32i    a5, a3, MSG_PAYLOAD_OWNED
    l32i    a10, a3, MSG_PAYLOAD
    call8   silica_rt_report_end
    bnez    a10, 15f
    l32i    a10, a3, MSG_PAYLOAD
    call8   silica_rt_free
    j       15f
14: mov     a10, a3
    call8   silica_rt_node_release_payload
15: mov     a10, a3
    call8   silica_rt_free_node
2:  l32i    a3, a2, ACB_MB_HEAD
    beqz    a3, 4f
    l32i    a4, a3, MSG_NEXT
    s32i    a4, a2, ACB_MB_HEAD
    mov     a10, a3
    call8   silica_rt_node_release_payload
    l32i    a4, a3, MSG_KIND
    movi    a5, 1
    bne     a4, a5, 3f
    mov     a10, a3
    call8   silica_rt_complete_death_locked
    j       2b
3:  mov     a10, a3
    call8   silica_rt_free_node
    j       2b
4:  movi    a4, 0
    s32i    a4, a2, ACB_MB_TAIL
    movi    a5, 0                       // a5 = the ingress, detached under the lock
    l32i    a6, a2, ACB_SB              // a6 = the supervision block, if any
    beqz    a6, 51f
    l32i    a5, a6, SB_IN_HEAD
    s32i    a4, a6, SB_IN_HEAD
    s32i    a4, a6, SB_IN_TAIL
    s32i    a4, a6, SB_IN_DEPTH
51: SCHED_UNLOCK a8, a9
    // notices never served go back, their payloads too (a payload holding an actor lets go of it,
    // which may recycle that ACB: outside the lock)
52: beqz    a5, 54f
    l32i    a3, a5, MSG_NEXT
    l32i    a4, a5, MSG_INGRESS_KIND
    bnez    a4, 53f
    l32i    a10, a5, MSG_PAYLOAD
    beqz    a10, 53f
    call8   silica_rt_exit_payload_free
53: mov     a10, a5
    call8   silica_rt_free_node
    mov     a5, a3
    j       52b
54: beqz    a7, 6f
    // the hosts print this note only for a root actor ended by remove_actor / kill_abnormal (its
    // loop finds it ended), never for one that failed (a trap, a fault, actor_not_found)
    l32i    a3, a1, 0
    beqz    a3, 6f
    movi    a10, silica_rt_root_exit_msg
    call8   silica_rt_puts
6:  // registered name (§20.3.1)
    l16ui    a3, a2, ACB_REG_NAME
    beqz    a3, 7f
    addi    a3, a3, -1
    mov     a10, a2
    mov     a11, a3
    call8   silica_rt_registry_forget
7:  // the state block the actor owns (silica_rt_state_adopt) goes back; a state that is still a
    // spawner's or a row's is not the actor's to free
    l8ui    a3, a2, ACB_STATE_OWNED
    beqz    a3, 71f
    movi    a3, 0
    s8i     a3, a2, ACB_STATE_OWNED
    l32i    a10, a2, ACB_STATE
    call8   silica_rt_free
    movi    a3, 0
    s32i    a3, a2, ACB_STATE
71: mov     a10, a2
    call8   silica_rt_child_table_free
    SCHED_LOCK a8, a9                   // the row is read and stamped under the lock: a supervisor
    l32i    a3, a2, ACB_ROW             // that ends clears its live children's row words under it
    beqz    a3, 72f                     // before it frees the rows (silica_rt_child_table_free)
    movi    a4, 1
    s32i    a4, a3, 56                  // row.exit_done for the supervisor's cascade
72: SCHED_UNLOCK a8, a9
8:  movi    a3, ST_DEAD
    s8i     a3, a2, ACB_STATUS
    retw
    .size   silica_rt_actor_exit_body, . - silica_rt_actor_exit_body

// silica_rt_complete_death_locked(node): the call completes with reply set 2 (the target ended
// before replying; the caller raises actor_not_found, spec §16.1.1) and its caller is woken.
    .align  4
silica_rt_complete_death_locked:
    entry   a1, 32
    l32i    a3, a2, MSG_REPLY_SET
    bnez    a3, 1f
    movi    a3, 0
    s32i    a3, a2, MSG_REPLY
    s32i    a3, a2, MSG_REPLY + 4
    movi    a3, 2
    s32i    a3, a2, MSG_REPLY_SET
    l32i    a10, a2, MSG_CALLER
    beqz    a10, 1f
    call8   silica_rt_wake
1:  retw
    .size   silica_rt_complete_death_locked, . - silica_rt_complete_death_locked

// silica_rt_actor_trap(reason tag): a language-level failure (badarith, case_clause) inside the
// running actor. Ends the actor where it stands (spec §15.1.2: ending is the exception to the
// no-preemption rule): the exit path runs on this stack, then the core's scheduler continues.
// Never returns. Called by rt_console.S when the trap happens in an actor.
    .align  4
    .global silica_rt_actor_trap
    .type   silica_rt_actor_trap, @function
silica_rt_actor_trap:
    entry   a1, 32
    mov     a3, a2
    call8   silica_rt_current_actor
    mov     a2, a10
    beqz    a2, 9f
    s8i     a3, a2, ACB_REASON_TAG
    movi    a4, 0
    s8i     a4, a2, ACB_ALIVE
    mov     a10, a2
    movi    a11, 0                      // a failure: no root note
    call8   silica_rt_actor_exit
    call8   silica_rt_yield_to_sched
9:  j       9b
    .size   silica_rt_actor_trap, . - silica_rt_actor_trap

// silica_rt_actor_trap_explicit(atom): the running actor fails with failure_reason (:explicit, atom),
// tag 4 and the atom in ACB_REASON_ATOM, ended where it stands as silica_rt_actor_trap ends it for a
// language-level failure (§20.3.1 :duplicate_child_id from rt_supervisors.S). Never returns.
    .align  4
    .global silica_rt_actor_trap_explicit
    .type   silica_rt_actor_trap_explicit, @function
silica_rt_actor_trap_explicit:
    entry   a1, 32
    mov     a3, a2
    call8   silica_rt_current_actor
    mov     a2, a10
    beqz    a2, 9f
    s16i    a3, a2, ACB_REASON_ATOM
    movi    a3, 4
    s8i     a3, a2, ACB_REASON_TAG
    movi    a4, 0
    s8i     a4, a2, ACB_ALIVE
    mov     a10, a2
    movi    a11, 0                      // a failure: no root note
    call8   silica_rt_actor_exit
    call8   silica_rt_yield_to_sched
9:  j       9b
    .size   silica_rt_actor_trap_explicit, . - silica_rt_actor_trap_explicit

// silica_rt_actor_fault_hook(cause, epc1, excvaddr): called by the fatal trampoline (rt_vectors.S), on the fault
// stack with a single live window, when a CPU exception was raised while an actor was running on
// this core. Returns 0 when the fault is the process's (main, the scheduler, no actor); otherwise
// the actor is ended -- reason (:explicit, :stack_exhausted) tag 4 for a stack-guard hit (cause
// 1006), :memory_fault tag 3 for anything else -- and this function does not return: the exit path
// is left to the core's scheduler (status FAULTED), whose context is resumed directly.
    .align  4
    .global silica_rt_actor_fault_hook
    .type   silica_rt_actor_fault_hook, @function
// The hook's own exit label is 8, not 9: SCHED_LOCK below defines a local 9 of its own, and every
// `9f` early-out here (no actor on this core: main's fault, the scheduler's) used to land on it, so
// the hook spun S32C1I on a garbage address and faulted itself. The nested path then reported the
// hook's pc, which is what hid the first fault's cause and EPC (design_documents/
// runtime_failure_reporting.md §3.2; actor_memory_budget_plan.md §13).
silica_rt_actor_fault_hook:
    entry   a1, 32
    mov     a12, a3                     // EPC1 and EXCVADDR (arguments 1 and 2), kept for the ACB
    mov     a13, a4
    mov     a5, a2
    movi    a2, 0
    movi    a3, 0
    movi    a4, silica_rt_actors_ready
    l32i    a4, a4, 0
    beqz    a4, 8f
    THIS_CORE_BLOCK a4, a6
    l32i    a6, a4, CORE_CURRENT
    beqz    a6, 8f
    l8ui    a7, a6, ACB_KIND
    bnez    a7, 8f
    // A fault raised while this core holds the scheduler lock (inside a runtime routine working
    // on the run queues, a child table or a mailbox) is the process's: the structures under the
    // lock are half-updated, and the exit path below needs the lock this core already holds, so
    // ending the actor would spin forever on it. Before this the hook took the lock anyway and
    // the program ended through the nested path with the hook's own pc, hiding the cause and the
    // EPC. The lock is released (the other core, if it waits on it, carries on until the process
    // ends; on core 0 the report stalls it first) and 0 is returned: the trampoline reports the
    // ORIGINAL fault (cause, EPC1, EXCVADDR) as a fatal fault, status 70
    // (design_documents/runtime_failure_reporting.md §3.2).
    movi    a7, silica_rt_sched_lock
    l32i    a8, a7, 0
    THIS_CORE a9
    addi    a9, a9, 1
    bne     a8, a9, 3f
    SCHED_UNLOCK a8, a9
    j       8f
3:  movi    a7, 1006
    movi    a8, 3
    bne     a5, a7, 1f
    movi    a8, 4
1:  s8i     a8, a6, ACB_REASON_TAG
    // the exception registers go into the ACB for the device-actor report (EXCCAUSE+1 in a byte, so
    // 0 means none: cause 0 is IllegalInstruction); cause codes from 1001 up are the runtime's own
    movi    a7, 64
    bgeu    a5, a7, 2f
    addi    a7, a5, 1
    s8i     a7, a6, ACB_FAULT_CAUSE
    s32i    a12, a6, ACB_FAULT_EPC
    s32i    a13, a6, ACB_FAULT_VADDR
2:  movi    a7, 0
    s8i     a7, a6, ACB_ALIVE
    movi    a7, ST_FAULTED
    s8i     a7, a6, ACB_STATUS
    // the report counter was bumped by the trampoline; this fault is handled, not fatal
    movi    a7, silica_rt_fatal_depth   // this core's count (rt_vectors.S FATAL_DEPTH_SLOT)
    THIS_CORE a8
    addx4   a7, a8, a7
    l32i    a8, a7, 0
    addi    a8, a8, -1
    s32i    a8, a7, 0
    // queue the actor so the scheduler runs its exit path, then resume the scheduler context
    SCHED_LOCK a8, a9
    mov     a10, a6
    call8   silica_rt_rq_push
    SCHED_UNLOCK a8, a9
    l32i    a3, a4, CORE_SCHED
    s32i    a3, a4, CORE_CURRENT
    rur     a4, threadptr
    l32i    a5, a3, ACB_CTX_VSP
    s32i    a5, a4, VRG_VSP
    movi    a5, 0
    wsr     a5, dbreakc0
    wsr     a5, dbreakc1
    // the abandoned context may have held the console lock (a fault inside a print)
    call8   silica_rt_console_release_if_mine
    // only this window is live (the trampoline reset WINDOWSTART, then the shim called us), so
    // the RETW below reloads the scheduler's frame from its stack, as a switch does
    rsr     a5, windowbase
    movi    a6, 1
    ssl     a5
    sll     a6, a6
    wsr     a6, windowstart
    rsync
    l32i    a0, a3, ACB_CTX_A0
    l32i    a1, a3, ACB_CTX_A1
    retw
8:  retw
    .size   silica_rt_actor_fault_hook, . - silica_rt_actor_fault_hook

// ---------------------------------------------------------------------------------------------
// spawn

// silica_rt_actor_spawn(X0 init, X1 behaviour, X2 core id, X3 supervisor trampoline, X4 policy)
// -> X0 actor_ref. X3 and X4 arrive in this core's register block (THREADPTR; offsets 0 and 8).
    .align  4
    .global silica_rt_actor_spawn
    .type   silica_rt_actor_spawn, @function
silica_rt_actor_spawn:
    entry   a1, 48
    rur     a8, threadptr
    l32i    a9, a8, 0                   // X3 trampoline
    s32i    a9, a1, 0
    l32i    a9, a8, 8                   // X4 policy
    s32i    a9, a1, 4
    movi    a9, 0
    s32i    a9, a1, 8                   // agent type
    s32i    a9, a1, 12                  // row
    s32i    a9, a1, 16                  // no supervisor to inherit a reserve from
    mov     a10, a2
    mov     a11, a3
    mov     a12, a4
    mov     a13, a5
    mov     a14, a6
    mov     a15, a1
    call8   silica_rt_spawn_common
    mov     a6, a10
    mov     a2, a12                     // the reference: the identity (§15.1.4; spawn_common's a4:a5)
    mov     a3, a13
    // the first top-level spawn is the root actor wait_for_exit watched in the reference
    beqz    a6, 9f
    movi    a4, silica_rt_wait_root_acb
    l32i    a5, a4, 0
    bnez    a5, 9f
    s32i    a6, a4, 0
9:  retw
    .size   silica_rt_actor_spawn, . - silica_rt_actor_spawn

// silica_rt_actor_spawn_linked(X0 init, X1 behaviour, X2 agent atom, X3 row pointer,
// X4 trampoline) -> X0 actor_ref (the identity). Children of a supervisor inherit the spawner's
// stack policy. silica_rt_actor_spawn_linked_acb is the runtime's own form (rt_supervisors.S):
// X0 = the ACB, a4:a5 (the caller's a12:a13) = the identity.
    .align  4
    .global silica_rt_actor_spawn_linked
    .global silica_rt_actor_spawn_dangerous_linked
    .type   silica_rt_actor_spawn_linked, @function
silica_rt_actor_spawn_linked:
silica_rt_actor_spawn_dangerous_linked:
    entry   a1, 32
    mov     a10, a2
    mov     a11, a3
    mov     a12, a4
    mov     a13, a5
    mov     a14, a6
    mov     a15, a7
    call8   silica_rt_actor_spawn_linked_acb
    mov     a2, a12                     // its a4:a5: the identity
    mov     a3, a13
    retw
    .size   silica_rt_actor_spawn_linked, . - silica_rt_actor_spawn_linked

    .align  4
    .global silica_rt_actor_spawn_linked_acb
    .type   silica_rt_actor_spawn_linked_acb, @function
silica_rt_actor_spawn_linked_acb:
    entry   a1, 48
    rur     a8, threadptr
    l32i    a9, a8, 8                   // X4 trampoline
    s32i    a9, a1, 0
    movi    a9, 0
    s32i    a9, a1, 4                   // policy: inherit (default)
    s32i    a6, a1, 8                   // agent type (X2)
    l32i    a9, a8, 0                   // X3 row
    s32i    a9, a1, 12
    l32i    a9, a8, 16                  // X5 the supervisor (rt_supervisors.S), whose reserve the child inherits
    s32i    a9, a1, 16
    movi    a9, 0
    s32i    a9, a8, 16                  // consumed: a later plain spawn must not inherit from it
    mov     a10, a2
    mov     a11, a3
    mov     a12, a4
    mov     a13, a5
    movi    a14, 0                      // core: runtime-assigned
    mov     a15, a1
    call8   silica_rt_spawn_common
    mov     a2, a10
    movi    a3, 0
    mov     a4, a12                     // spawn_common's a4:a5: the identity
    mov     a5, a13
    retw
    .size   silica_rt_actor_spawn_linked_acb, . - silica_rt_actor_spawn_linked_acb

// silica_rt_spawn_common(init lo, init hi, beh lo, beh hi, core, extra*) -> acb
//   extra: [0] trampoline, [4] policy word, [8] agent atom, [12] row, [16] supervisor (reserve source)
    .align  4
silica_rt_spawn_common:
    entry   a1, 64
    s32i    a2, a1, 0
    s32i    a3, a1, 4
    s32i    a4, a1, 8
    s32i    a5, a1, 12
    s32i    a6, a1, 16
    s32i    a7, a1, 20
    call8   silica_rt_actors_init
    call8   silica_rt_alloc_acb
    mov     a2, a10                     // a2 = acb
    l32i    a3, a1, 0
    s32i    a3, a2, ACB_STATE
    l32i    a3, a1, 4
    s32i    a3, a2, ACB_STATE + 4
    l32i    a3, a1, 8
    s32i    a3, a2, ACB_BEH
    // Spec §16.2.6.4: the calling convention, from the word the emitter writes before the entry of a
    // function declared to return (:reply, ...) (0x5C1AC0F1) or (:no_reply, ...) (0x5C1AC0F2), read
    // through the data-bus alias of the instruction-bus address; anything else is 0 (not checked).
    l32i    a3, a1, 8
    movi    a4, 0
    movi    a8, 0x40378000
    bltu    a3, a8, 63f
    movi    a8, _silica_iram_dram_offset
    sub     a5, a3, a8
    addi    a5, a5, -4
    l32i    a5, a5, 0
    srli    a6, a5, 4
    movi    a8, 0x5C1AC0F
    bne     a6, a8, 63f
    extui   a4, a5, 0, 4
    bltui   a4, 3, 63f
    movi    a4, 0
63: s32i    a4, a2, ACB_CONV
    l32i    a7, a1, 20                  // extra
    l32i    a3, a7, 4
    s32i    a3, a2, ACB_POLICY
    l32i    a3, a7, 8
    s16i    a3, a2, ACB_AGENT
    l32i    a3, a7, 12
    s32i    a3, a2, ACB_ROW
    // the supervisor (spawn_linked's X5; 0 from a plain spawn) is recorded before the actor can
    // run: a child supervisor whose init fails in its start trampoline must find it on its exit
    // path, or its exit notice is dropped as a root's (never restarted, the root-exit note
    // printed). The host records it the same way (prims_actors_runtime_asm, ACB #192).
    l32i    a3, a7, 16
    s32i    a3, a2, ACB_SUP
    // Identity (§15.1.4): numbered by its spawner -- the supervisor for a row child, else the running
    // actor (main when there is none) -- and entered in the identity table before it can run. A
    // supervisor takes its own position now, in its spawner's order. [a1+24] keeps the identity for
    // the return (the ACB of one that ends in its start may be recycled before the spawn returns).
    l32i    a10, a7, 16
    bnez    a10, 61f
    call8   silica_rt_current_actor
61: call8   silica_rt_spawner_rec
    mov     a11, a10
    mov     a10, a2
    call8   silica_rt_ident_assign
    beqz    a10, 62f
    call8   silica_rt_identity_exhausted
62: l32i    a3, a2, ACB_ID
    s32i    a3, a1, 24
    l32i    a3, a2, ACB_ID + 4
    s32i    a3, a1, 28
    l32i    a3, a7, 0
    beqz    a3, 63f
    mov     a10, a2
    call8   silica_rt_spawner_rec
    call8   silica_rt_spawner_position
63: movi    a3, 1
    s8i     a3, a2, ACB_ALIVE
    s8i     a3, a2, ACB_PRIO
    // core: the argument when it names a running core (0 is also "default"), else round robin
    l32i    a3, a1, 16
    movi    a4, silica_rt_ncores
    l32i    a4, a4, 0
    beqz    a3, 1f
    bgeu    a3, a4, 1f
    j       2f
1:  movi    a5, silica_rt_next_core
    l32i    a3, a5, 0
    addi    a6, a3, 1
    bltu    a6, a4, 11f
    movi    a6, 0
11: s32i    a6, a5, 0
2:  s8i     a3, a2, ACB_CORE
    // the stack policy: (reserve rounded to 16) | algorithm. A child spec passes none and inherits
    // its supervisor's. A lowered reserve (the word's top bits, ACB_RESERVE_LD) caps what the
    // chunks of both stacks may hold together; nothing is taken here: the first chunks come at the
    // first dispatch (item F), so a spawn cannot fail for want of stack
    l32i    a3, a2, ACB_POLICY
    bnez    a3, 3f
    l32i    a4, a7, 16
    beqz    a4, 3f
    l32i    a3, a4, ACB_POLICY
    s32i    a3, a2, ACB_POLICY
3:  // :track_recent_peak keeps a ring of the last 32 dispatches: a block of its own
    extui   a3, a3, 0, 4
    movi    a4, 3
    bne     a3, a4, 4f
    movi    a10, RING_SIZE
    call8   silica_rt_alloc
    s32i    a10, a2, ACB_RING
4:  // a supervisor: its supervision block holds the trampoline, and the trampoline must have
    // run before spawn returns: schedule the actor now and suspend the spawner until the actor's
    // first schedule wakes it. The spawner holds the ACB (TR_SPAWNER) until it lets go.
    l32i    a3, a7, 0
    beqz    a3, 7f
    mov     a10, a2
    call8   silica_rt_sb_require
    mov     a6, a10                     // a6 = the supervision block
    s32i    a3, a6, SB_TRAMP
    movi    a5, TR_SPAWNER
    s32i    a5, a6, SB_TRAMP_RAN
    call8   silica_rt_current
    mov     a4, a10                     // a4 = the spawner
    s32i    a4, a6, SB_SPAWN_WAITER
    SCHED_LOCK a8, a9
    movi    a5, ST_READY
    s8i     a5, a2, ACB_STATUS
    mov     a10, a2
    call8   silica_rt_rq_push
    movi    a5, ST_SUSPENDED
    s8i     a5, a4, ACB_STATUS
    SCHED_UNLOCK a8, a9
    call8   silica_rt_yield_to_sched
    // Woken. Only the end of the start (actor_main) or of the actor (silica_rt_spawn_waiter_wake)
    // clears the wait word; any other wake of a suspended context -- an exit notice reaching this
    // spawner's ingress, from a child it started earlier -- must not end the wait: suspend again.
5:  SCHED_LOCK a8, a9
    l32i    a5, a6, SB_SPAWN_WAITER
    beqz    a5, 6f
    movi    a5, ST_SUSPENDED
    s8i     a5, a4, ACB_STATUS
    SCHED_UNLOCK a8, a9
    call8   silica_rt_yield_to_sched
    j       5b
6:  SCHED_UNLOCK a8, a9
    // A row child's spawner (rt_supervisors.S by_flavor) commits it to its row and lets go itself.
    // Any other spawner lets go here; an actor that ended inside its start trampoline is no actor
    // to hand out: the ACB returned is silica_rt_dead_acb, a block that is a dead actor for good
    // (its own ACB goes with its last holder), and its identity, returned with it, is dead.
    l32i    a5, a7, 12
    bnez    a5, 7f
    l32i    a5, a6, SB_TRAMP_RAN
    mov     a10, a2
    movi    a11, TR_SPAWNER
    call8   silica_rt_tramp_release
    bbci    a5, TR_INIT_DEAD_BIT, 7f
    movi    a2, silica_rt_dead_acb
7:  l32i    a4, a1, 24                  // a4:a5 (the caller's a12:a13) = the identity
    l32i    a5, a1, 28
    retw
    .size   silica_rt_spawn_common, . - silica_rt_spawn_common

// ---------------------------------------------------------------------------------------------
// Actor identity (spec §15.1.4)
//
// A reference is its actor's 64-bit identity, position << 32 | child number (X0 = a10:a11: the
// child number in the low word, the position in the high word); never an ACB address. The
// identity table maps an identity to its ACB for every ACB that has not been recycled: open
// addressing, linear probing, a power-of-two capacity grown x2 above half load, backward-shift
// deletion. A slot holds the ACB (0 empty); its key is the ACB's ACB_ID. The table is guarded by
// the scheduler lock. An actor is entered by its spawn before it can run and removed when its ACB
// is recycled (silica_rt_free_acb), so a slot never names a free ACB; an ended actor's ACB, until
// then, is found with ACB_ALIVE 0. ACBs are type-stable (they go to a free list, never back to the
// heap), so an entry point that resolved a reference and then acts on the ACB re-checks ACB_ID
// under the lock where a recycle in between would matter (silica_rt_enqueue_by_id, call).
// Spawner records (8 B: position + 1, 0 none yet; next child number): main's and the runtime's
// (the registries, position 0xFFFFFFFE) are static, an actor's is ACB_SPOS/ACB_SNEXT, a row
// child's its row's ROW_SPOS (rt_supervisors.S), which outlives the child's restarts (§15.4.12.1).

// \rd = home slot of the identity (\lo, \hi) under \mask. \t scratch.
.macro IDT_HASH rd, lo, hi, mask, t
    movi    \t, 0x85EBCA6B
    mull    \rd, \hi, \t
    xor     \rd, \rd, \lo
    movi    \t, 0x9E3779B1
    mull    \rd, \rd, \t
    srli    \rd, \rd, 16
    and     \rd, \rd, \mask
.endm

    .section .bss.silica_rt_actors, "aw", @nobits
    .balign 8
    .global silica_rt_idt
silica_rt_idt:                          // [0] slots  [4] mask (capacity - 1)  [8] count
    .space  12
    .global silica_rt_next_position
silica_rt_next_position:                // set to 1 by silica_rt_actors_init (main is position 0)
    .space  4
    .global silica_rt_main_spawner
silica_rt_main_spawner:                 // position + 1 = 1, set by silica_rt_actors_init
    .space  8
    .global silica_rt_runtime_spawner
silica_rt_runtime_spawner:              // position 0xFFFFFFFE, set by silica_rt_actors_init
    .space  8
    .global silica_rt_spawn_rec_override
silica_rt_spawn_rec_override:
    .space  4
    .global silica_rt_root_failure_reporter_id
silica_rt_root_failure_reporter_id:
    .space  8
    .text

// silica_rt_idt_find_locked(lo, hi) -> a2 = the slot holding it or the empty slot where it would
// go (0: no table yet), a3 = its ACB or 0. Scheduler lock held. Leaf.
    .align  4
    .global silica_rt_idt_find_locked
silica_rt_idt_find_locked:
    entry   a1, 32
    movi    a8, silica_rt_idt
    l32i    a9, a8, 0
    l32i    a10, a8, 4
    beqz    a9, 68f
    IDT_HASH a11, a2, a3, a10, a12
61: addx4   a12, a11, a9
    l32i    a13, a12, 0
    beqz    a13, 65f
    l32i    a14, a13, ACB_ID
    bne     a14, a2, 62f
    l32i    a14, a13, ACB_ID + 4
    beq     a14, a3, 65f
62: addi    a11, a11, 1
    and     a11, a11, a10
    j       61b
65: mov     a2, a12
    mov     a3, a13
    retw
68: movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_idt_find_locked, . - silica_rt_idt_find_locked

// silica_rt_idt_grow_locked(): twice the capacity (64 the first time). Scheduler lock held; the
// heap has its own leaf lock.
    .align  4
silica_rt_idt_grow_locked:
    entry   a1, 32
    movi    a2, silica_rt_idt
    l32i    a3, a2, 0                   // a3 = old slots
    l32i    a4, a2, 4                   // a4 = old mask
    movi    a5, 64
    beqz    a3, 61f
    addi    a5, a4, 1
    slli    a5, a5, 1                   // a5 = new capacity
61: slli    a10, a5, 2
    call8   silica_rt_alloc
    mov     a6, a10
    slli    a11, a5, 2
    call8   silica_rt_zero_block
    movi    a2, silica_rt_idt
    s32i    a6, a2, 0
    addi    a7, a5, -1
    s32i    a7, a2, 4
    beqz    a3, 69f
    movi    a7, 0                       // a7 = old index
62: addx4   a6, a7, a3
    l32i    a6, a6, 0
    beqz    a6, 63f
    l32i    a10, a6, ACB_ID
    l32i    a11, a6, ACB_ID + 4
    call8   silica_rt_idt_find_locked
    s32i    a6, a10, 0
63: addi    a7, a7, 1
    bgeu    a4, a7, 62b
    mov     a10, a3
    call8   silica_rt_free
69: retw
    .size   silica_rt_idt_grow_locked, . - silica_rt_idt_grow_locked

// silica_rt_idt_insert_locked(acb): its ACB_ID resolves from now on. Scheduler lock held.
    .align  4
silica_rt_idt_insert_locked:
    entry   a1, 32
    movi    a8, silica_rt_idt
    l32i    a9, a8, 0
    beqz    a9, 61f
    l32i    a10, a8, 8
    addi    a10, a10, 1
    slli    a10, a10, 1
    l32i    a11, a8, 4
    addi    a11, a11, 1
    bgeu    a11, a10, 62f
61: call8   silica_rt_idt_grow_locked
62: l32i    a10, a2, ACB_ID
    l32i    a11, a2, ACB_ID + 4
    call8   silica_rt_idt_find_locked
    s32i    a2, a10, 0
    movi    a8, silica_rt_idt
    l32i    a9, a8, 8
    addi    a9, a9, 1
    s32i    a9, a8, 8
    retw
    .size   silica_rt_idt_insert_locked, . - silica_rt_idt_insert_locked

// silica_rt_idt_remove_locked(acb): its identity no longer resolves (the ACB is being recycled).
// Entries after it in the probe run shift back into the hole unless that moves them before their
// home slot. Scheduler lock held.
    .align  4
    .global silica_rt_idt_remove_locked
silica_rt_idt_remove_locked:
    entry   a1, 32
    mov     a7, a2
    l32i    a10, a2, ACB_ID
    l32i    a11, a2, ACB_ID + 4
    call8   silica_rt_idt_find_locked
    bne     a11, a7, 69f
    movi    a8, silica_rt_idt
    l32i    a3, a8, 0                   // a3 = slots
    l32i    a4, a8, 4                   // a4 = mask
    sub     a5, a10, a3
    srli    a5, a5, 2                   // a5 = the hole
    mov     a6, a5                      // a6 = the entry looked at
61: addi    a6, a6, 1
    and     a6, a6, a4
    addx4   a8, a6, a3
    l32i    a2, a8, 0
    beqz    a2, 65f
    l32i    a9, a2, ACB_ID
    l32i    a10, a2, ACB_ID + 4
    IDT_HASH a11, a9, a10, a4, a12
    sub     a12, a6, a11
    and     a12, a12, a4                // its distance from home
    sub     a13, a6, a5
    and     a13, a13, a4                // the hole's distance behind it
    bltu    a12, a13, 61b
    addx4   a9, a5, a3
    s32i    a2, a9, 0
    mov     a5, a6
    j       61b
65: addx4   a9, a5, a3
    movi    a10, 0
    s32i    a10, a9, 0
    movi    a8, silica_rt_idt
    l32i    a9, a8, 8
    addi    a9, a9, -1
    s32i    a9, a8, 8
69: retw
    .size   silica_rt_idt_remove_locked, . - silica_rt_idt_remove_locked

// silica_rt_ref_acb(lo, hi) -> the ACB with this identity (alive or ended, not yet recycled), or 0.
    .align  4
    .global silica_rt_ref_acb
    .type   silica_rt_ref_acb, @function
silica_rt_ref_acb:
    entry   a1, 32
    SCHED_LOCK a8, a9
    mov     a10, a2
    mov     a11, a3
    call8   silica_rt_idt_find_locked
    mov     a2, a11
    SCHED_UNLOCK a8, a9
    movi    a3, 0
    retw
    .size   silica_rt_ref_acb, . - silica_rt_ref_acb

// silica_rt_ref_alive(lo, hi) -> 1 when the identity names an actor that is alive, else 0.
    .align  4
    .global silica_rt_ref_alive
    .type   silica_rt_ref_alive, @function
silica_rt_ref_alive:
    entry   a1, 32
    SCHED_LOCK a8, a9
    mov     a10, a2
    mov     a11, a3
    call8   silica_rt_idt_find_locked
    movi    a2, 0
    beqz    a11, 61f
    l8ui    a2, a11, ACB_ALIVE
61: SCHED_UNLOCK a8, a9
    movi    a3, 0
    retw
    .size   silica_rt_ref_alive, . - silica_rt_ref_alive

// silica_rt_acb_ident(acb) -> X0 = its identity (all ones for 0: the identity no actor has).
    .align  4
    .global silica_rt_acb_ident
    .type   silica_rt_acb_ident, @function
silica_rt_acb_ident:
    entry   a1, 32
    beqz    a2, 61f
    l32i    a3, a2, ACB_ID + 4
    l32i    a2, a2, ACB_ID
    retw
61: movi    a2, -1
    movi    a3, -1
    retw
    .size   silica_rt_acb_ident, . - silica_rt_acb_ident

// silica_rt_spawner_rec(acb or 0) -> the spawner record of that actor (main's, or the runtime's
// while silica_rt_spawn_rec_override names it, for 0).
    .align  4
    .global silica_rt_spawner_rec
silica_rt_spawner_rec:
    entry   a1, 32
    beqz    a2, 63f
    l32i    a3, a2, ACB_SUP
    beqz    a3, 62f
    l32i    a3, a2, ACB_ROW
    beqz    a3, 62f
    addi    a2, a3, ROW_SPOS
    retw
62: addi    a2, a2, ACB_SPOS
    retw
63: movi    a2, silica_rt_spawn_rec_override
    l32i    a2, a2, 0
    bnez    a2, 64f
    movi    a2, silica_rt_main_spawner
64: retw
    .size   silica_rt_spawner_rec, . - silica_rt_spawner_rec

// silica_rt_spawner_position_locked(rec) -> position + 1, given now from the global counter when the
// record has none; 0 when positions are exhausted. Scheduler lock held.
    .align  4
silica_rt_spawner_position_locked:
    entry   a1, 32
    l32i    a4, a2, 0
    bnez    a4, 62f
    movi    a5, silica_rt_next_position
    l32i    a4, a5, 0
    movi    a6, 0xFFFFFFFE
    bgeu    a4, a6, 61f
    addi    a6, a4, 1
    s32i    a6, a5, 0
    addi    a4, a4, 1
    s32i    a4, a2, 0
62: mov     a2, a4
    retw
61: movi    a2, 0
    retw
    .size   silica_rt_spawner_position_locked, . - silica_rt_spawner_position_locked

// silica_rt_spawner_position(rec): the record takes its position now (a supervisor, when spawned).
    .align  4
    .global silica_rt_spawner_position
silica_rt_spawner_position:
    entry   a1, 32
    SCHED_LOCK a8, a9
    mov     a10, a2
    call8   silica_rt_spawner_position_locked
    SCHED_UNLOCK a8, a9
    retw
    .size   silica_rt_spawner_position, . - silica_rt_spawner_position

// silica_rt_ident_assign(acb, rec) -> 0 (ACB_ID set, in the table), 1 the spawner's numbers are
// exhausted.
    .align  4
    .global silica_rt_ident_assign
silica_rt_ident_assign:
    entry   a1, 32
    SCHED_LOCK a8, a9
    mov     a10, a3
    call8   silica_rt_spawner_position_locked
    beqz    a10, 67f
    addi    a4, a10, -1                 // a4 = position
    l32i    a5, a3, 4                   // a5 = child number
    movi    a6, -1
    beq     a5, a6, 67f
    addi    a6, a5, 1
    s32i    a6, a3, 4
    s32i    a5, a2, ACB_ID
    s32i    a4, a2, ACB_ID + 4
    mov     a10, a2
    call8   silica_rt_idt_insert_locked
    SCHED_UNLOCK a8, a9
    movi    a2, 0
    retw
67: SCHED_UNLOCK a8, a9
    movi    a2, 1
    retw
    .size   silica_rt_ident_assign, . - silica_rt_ident_assign

// silica_rt_identity_exhausted(): the spawner ran out of child numbers or positions (§15.1.4). The
// running actor fails with (:explicit, :identity_exhausted); in main the atom's name on the console,
// exit status 1. Never returns.
    .align  4
    .global silica_rt_identity_exhausted
silica_rt_identity_exhausted:
    entry   a1, 32
    call8   silica_rt_current_actor
    beqz    a10, 61f
    movi    a10, silica_registry_atom_identity_exhausted
    l32i    a10, a10, 0
    call8   silica_rt_actor_trap_explicit
61: movi    a10, silica_rt_identity_exhausted_msg
    call8   silica_rt_main_fail_exit
    j       61b
    .size   silica_rt_identity_exhausted, . - silica_rt_identity_exhausted

// silica_rt_enqueue_by_id(lo, hi, node) -> 0 enqueued on the live actor with that identity, 1 there
// is none (no such actor, or it has ended): resolution and enqueue are one critical section, so a
// recycle in between cannot deliver to another actor.
    .align  4
silica_rt_enqueue_by_id:
    entry   a1, 32
    SCHED_LOCK a8, a9
    mov     a10, a2
    mov     a11, a3
    call8   silica_rt_idt_find_locked
    beqz    a11, 68f
    mov     a2, a11
    l8ui    a5, a2, ACB_ALIVE
    beqz    a5, 68f
    l32i    a5, a2, ACB_CONV            // a cast to a call-only actor (§16.2.6.4): nothing enqueued
    beqi    a5, 1, 67f
    movi    a5, 0
    s32i    a5, a4, MSG_NEXT
    l32i    a5, a2, ACB_MB_TAIL
    beqz    a5, 61f
    s32i    a4, a5, MSG_NEXT
    s32i    a4, a2, ACB_MB_TAIL
    j       62f
61: s32i    a4, a2, ACB_MB_HEAD
    s32i    a4, a2, ACB_MB_TAIL
62: mov     a10, a2
    call8   silica_rt_make_ready
    SCHED_UNLOCK a8, a9
    movi    a2, 0
    retw
67: SCHED_UNLOCK a8, a9
    movi    a2, 2
    retw
68: SCHED_UNLOCK a8, a9
    movi    a2, 1
    retw
    .size   silica_rt_enqueue_by_id, . - silica_rt_enqueue_by_id

// silica_rt_cast_try(X0 reference, X1 message, X2 payload owned) -> 1 enqueued, 0 no live actor, 2 the
// target is call-only (§16.2.6.4) (either way the message is dropped: a record copy it owned goes
// back; a report (2) stays listed for the exit drain).
    .align  4
    .global silica_rt_cast_try
    .type   silica_rt_cast_try, @function
silica_rt_cast_try:
    entry   a1, 32
    mov     a10, a4
    call8   silica_rt_report_escape_check
    mov     a7, a6
    call8   silica_rt_alloc_node
    mov     a6, a10                     // a6 = node
    s32i    a4, a6, MSG_PAYLOAD
    s32i    a5, a6, MSG_PAYLOAD + 4
    s32i    a7, a6, MSG_PAYLOAD_OWNED
    mov     a10, a2
    mov     a11, a3
    mov     a12, a6
    call8   silica_rt_enqueue_by_id
    bnez    a10, 61f
    movi    a2, 1
    movi    a3, 0
    retw
61: mov     a2, a10                     // 1 dead, 2 convention mismatch
    mov     a10, a6
    call8   silica_rt_free_node
    movi    a5, 1
    bne     a7, a5, 62f
    mov     a10, a4
    call8   silica_rt_free
62: addi    a2, a2, -1                  // -> 0 / 2
    slli    a2, a2, 1
    movi    a3, 0
    retw
    .size   silica_rt_cast_try, . - silica_rt_cast_try

// ---------------------------------------------------------------------------------------------
// Messages

// silica_rt_enqueue_message(acb, node): onto the standard mailbox; a parked actor becomes ready.
    .align  4
silica_rt_enqueue_message:
    entry   a1, 32
    SCHED_LOCK a8, a9
    movi    a4, 0
    s32i    a4, a3, MSG_NEXT
    l32i    a4, a2, ACB_MB_TAIL
    beqz    a4, 1f
    s32i    a3, a4, MSG_NEXT
    s32i    a3, a2, ACB_MB_TAIL
    j       2f
1:  s32i    a3, a2, ACB_MB_HEAD
    s32i    a3, a2, ACB_MB_TAIL
2:  mov     a10, a2
    call8   silica_rt_make_ready
    SCHED_UNLOCK a8, a9
    retw
    .size   silica_rt_enqueue_message, . - silica_rt_enqueue_message

// silica_rt_enqueue_ingress(acb, node) -> 0 ok, 1 dead target. Bounded; overflow is a runtime abort.
    .align  4
silica_rt_enqueue_ingress:
    entry   a1, 32
    SCHED_LOCK a8, a9
    l8ui    a4, a2, ACB_ALIVE
    beqz    a4, 8f
    mov     a10, a2                     // the target's supervision block (made now for an actor
    call8   silica_rt_sb_require        // that became a parent through add_child)
    mov     a6, a10
    l32i    a4, a6, SB_IN_DEPTH
    movi    a5, INGRESS_LIMIT
    bgeu    a4, a5, 9f
    addi    a4, a4, 1
    s32i    a4, a6, SB_IN_DEPTH
    movi    a4, 0
    s32i    a4, a3, MSG_NEXT
    l32i    a4, a6, SB_IN_TAIL
    beqz    a4, 1f
    s32i    a3, a4, MSG_NEXT
    s32i    a3, a6, SB_IN_TAIL
    j       2f
1:  s32i    a3, a6, SB_IN_HEAD
    s32i    a3, a6, SB_IN_TAIL
2:  mov     a10, a2
    call8   silica_rt_make_ready
    mov     a10, a2
    call8   silica_rt_wake                  // a supervision_wait_and_drain_one waiter
    SCHED_UNLOCK a8, a9
    movi    a2, 0
    retw
8:  SCHED_UNLOCK a8, a9
    movi    a2, 1
    retw
9:  SCHED_UNLOCK a8, a9
    call8   silica_rt_abort_ingress_full
    retw
    .size   silica_rt_enqueue_ingress, . - silica_rt_enqueue_ingress

// silica_rt_actor_send(X0 reference, X1 message, X2 payload owned) -> 0. X2 is 1 when the emitter
// copied a record or tuple message into a heap block of its own (MSG_PAYLOAD_OWNED). It is a cast: an
// ended (or unknown) actor raises actor_not_found (§16.1.4).
    .align  4
    .global silica_rt_actor_send
    .type   silica_rt_actor_send, @function
silica_rt_actor_send:
    entry   a1, 32
    mov     a10, a2
    mov     a11, a3
    mov     a12, a4
    mov     a13, a5
    mov     a14, a6
    call8   silica_rt_cast_try
    beqz    a10, 61f
    beqi    a10, 2, 62f
    movi    a2, 0
    movi    a3, 0
    retw
61: call8   silica_rt_actor_not_found   // never returns
    j       61b
62: call8   silica_rt_convention_mismatch   // a call-only target (§16.2.6.4); never returns
    j       62b
    .size   silica_rt_actor_send, . - silica_rt_actor_send

// silica_rt_actor_cast(X0 reference, X1 message, X2 payload owned) -> 1 enqueued. An ended (or
// unknown) actor raises actor_not_found; the message is dropped (§16.1.2, §16.1.4).
    .align  4
    .global silica_rt_actor_cast
    .type   silica_rt_actor_cast, @function
silica_rt_actor_cast:
    entry   a1, 32
    mov     a10, a2
    mov     a11, a3
    mov     a12, a4
    mov     a13, a5
    mov     a14, a6
    call8   silica_rt_cast_try
    beqz    a10, 61f
    beqi    a10, 2, 62f
    movi    a2, 1
    movi    a3, 0
    retw
61: call8   silica_rt_actor_not_found   // never returns
    j       61b
62: call8   silica_rt_convention_mismatch   // a call-only target (§16.2.6.4); never returns
    j       62b
    .size   silica_rt_actor_cast, . - silica_rt_actor_cast

// silica_rt_actor_call(X0 actor, X1 message, X2 payload owned) -> X0 reply. A target that is dead,
// or that ends before replying, raises actor_not_found (§16.1.1).
// The caller suspends (a scheduler yield point) until the target's behaviour returns its reply.
    .align  4
    .global silica_rt_actor_call
    .type   silica_rt_actor_call, @function
silica_rt_actor_call:
    entry   a1, 48
    s32i    a2, a1, 4                   // [a1+4]/[a1+8] the reference (§15.1.4), resolved under the
    s32i    a3, a1, 8                   // lock that enqueues, so a recycle in between cannot misdeliver
    mov     a10, a4
    call8   silica_rt_report_escape_check
    s32i    a6, a1, 0
    call8   silica_rt_alloc_node
    mov     a6, a10                     // a6 = node
    movi    a7, 1
    s32i    a7, a6, MSG_KIND
    s32i    a4, a6, MSG_PAYLOAD
    s32i    a5, a6, MSG_PAYLOAD + 4
    l32i    a7, a1, 0
    s32i    a7, a6, MSG_PAYLOAD_OWNED
    call8   silica_rt_current
    mov     a7, a10                     // a7 = me
    s32i    a7, a6, MSG_CALLER
    SCHED_LOCK a8, a9
    l32i    a10, a1, 4
    l32i    a11, a1, 8
    call8   silica_rt_idt_find_locked
    mov     a2, a11
    beqz    a2, 8f
    l8ui    a4, a2, ACB_ALIVE
    beqz    a4, 8f
    l32i    a4, a2, ACB_CONV            // a call to a cast-only actor (§16.2.6.4): nothing enqueued
    beqi    a4, 2, 7f
    movi    a4, 0
    s32i    a4, a6, MSG_NEXT
    l32i    a4, a2, ACB_MB_TAIL
    beqz    a4, 1f
    s32i    a6, a4, MSG_NEXT
    s32i    a6, a2, ACB_MB_TAIL
    j       2f
1:  s32i    a6, a2, ACB_MB_HEAD
    s32i    a6, a2, ACB_MB_TAIL
2:  mov     a10, a2
    call8   silica_rt_make_ready
    movi    a4, ST_SUSPENDED
    s8i     a4, a7, ACB_STATUS
    s32i    a6, a7, ACB_WAIT_NODE
    SCHED_UNLOCK a8, a9
3:  call8   silica_rt_yield_to_sched
    l32i    a4, a6, MSG_REPLY_SET
    beqz    a4, 4f
    movi    a5, 0
    s32i    a5, a7, ACB_WAIT_NODE
    l32i    a2, a6, MSG_REPLY
    l32i    a3, a6, MSG_REPLY + 4
    mov     a10, a6
    call8   silica_rt_free_node
    movi    a5, 2
    beq     a4, a5, 9f
    retw
9:  // the target ended before replying: actor_not_found (§16.1.1)
    call8   silica_rt_actor_not_found   // never returns
    movi    a2, 0
    movi    a3, 0
    retw
4:  // woken without a reply (spurious): suspend again
    SCHED_LOCK a8, a9
    movi    a4, ST_SUSPENDED
    s8i     a4, a7, ACB_STATUS
    SCHED_UNLOCK a8, a9
    j       3b
8:  SCHED_UNLOCK a8, a9
    mov     a10, a6
    call8   silica_rt_node_release_payload
    mov     a10, a6
    call8   silica_rt_free_node
    // an ended (or unknown) actor raises actor_not_found (§16.1.1)
    call8   silica_rt_actor_not_found   // never returns
    movi    a2, 0
    movi    a3, 0
    retw
7:  SCHED_UNLOCK a8, a9
    mov     a10, a6
    call8   silica_rt_node_release_payload
    mov     a10, a6
    call8   silica_rt_free_node
    call8   silica_rt_convention_mismatch   // never returns
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_actor_call, . - silica_rt_actor_call

// Registry-keyed forms: X0 = atom (registry slot), X1 = message, X2 = payload owned.
    .align  4
    .global silica_rt_actor_call_registered
    .type   silica_rt_actor_call_registered, @function
silica_rt_actor_call_registered:
    entry   a1, 32
    movi    a10, silica_pid_registry_ref
    mov     a11, a2
    call8   silica_rt_registry_lookup
    beqz    a10, 9f
    call8   silica_rt_acb_ident         // the holder's identity (§15.1.4)
    mov     a12, a4
    mov     a13, a5
    mov     a14, a6
    call8   silica_rt_actor_call
    mov     a2, a10
    mov     a3, a11
    retw
9:  call8   silica_rt_actor_not_found   // never returns
    j       9b
    .size   silica_rt_actor_call_registered, . - silica_rt_actor_call_registered

    .align  4
    .global silica_rt_actor_cast_registered
    .type   silica_rt_actor_cast_registered, @function
silica_rt_actor_cast_registered:
    entry   a1, 32
    movi    a10, silica_pid_registry_ref
    mov     a11, a2
    call8   silica_rt_registry_lookup
    beqz    a10, 9f
    call8   silica_rt_acb_ident         // the holder's identity (§15.1.4)
    mov     a12, a4
    mov     a13, a5
    mov     a14, a6
    call8   silica_rt_actor_cast
    mov     a2, a10
    mov     a3, a11
    retw
9:  call8   silica_rt_actor_not_found   // never returns
    j       9b
    .size   silica_rt_actor_cast_registered, . - silica_rt_actor_cast_registered

    .align  4
    .global silica_rt_actor_cast_dangerous_registered
    .type   silica_rt_actor_cast_dangerous_registered, @function
silica_rt_actor_cast_dangerous_registered:
    entry   a1, 32
    movi    a10, silica_dangerous_pid_registry_ref
    mov     a11, a2
    call8   silica_rt_registry_lookup
    beqz    a10, 9f
    call8   silica_rt_acb_ident         // the holder's identity (§15.1.4)
    mov     a12, a4
    mov     a13, a5
    mov     a14, a6
    call8   silica_rt_actor_cast
    mov     a2, a10
    mov     a3, a11
    retw
9:  call8   silica_rt_actor_not_found   // never returns
    j       9b
    .size   silica_rt_actor_cast_dangerous_registered, . - silica_rt_actor_cast_dangerous_registered

// cast_device_registered resolves only the device table (device spec §1 "Split registries"): a
// name bound in the ordinary or dangerous table is not found here, and cast_registered never
// finds a device worker.
    .align  4
    .global silica_rt_actor_cast_device_registered
    .type   silica_rt_actor_cast_device_registered, @function
silica_rt_actor_cast_device_registered:
    entry   a1, 32
    movi    a10, silica_device_pid_registry_ref
    mov     a11, a2
    call8   silica_rt_registry_lookup
    beqz    a10, 9f
    call8   silica_rt_acb_ident         // the holder's identity (§15.1.4)
    mov     a12, a4
    mov     a13, a5
    mov     a14, a6
    call8   silica_rt_actor_cast
    mov     a2, a10
    mov     a3, a11
    retw
9:  call8   silica_rt_actor_not_found   // never returns
    j       9b
    .size   silica_rt_actor_cast_device_registered, . - silica_rt_actor_cast_device_registered

// silica_rt_actor_self() -> X0 the running actor's identity (all ones in main)
    .align  4
    .global silica_rt_actor_self
    .type   silica_rt_actor_self, @function
silica_rt_actor_self:
    entry   a1, 32
    call8   silica_rt_current_actor
    call8   silica_rt_acb_ident         // the identity; main (no actor): all ones, no actor's
    mov     a2, a10
    mov     a3, a11
    retw
    .size   silica_rt_actor_self, . - silica_rt_actor_self

// silica_rt_actor_recv() -> X0 the next message node of the running actor (ingress first), or 0
    .align  4
    .global silica_rt_actor_recv
    .type   silica_rt_actor_recv, @function
silica_rt_actor_recv:
    entry   a1, 32
    call8   silica_rt_current_actor
    mov     a2, a10
    movi    a3, 0
    beqz    a2, 29f
    SCHED_LOCK a8, a9
    l32i    a6, a2, ACB_SB
    beqz    a6, 1f
    l32i    a4, a6, SB_IN_HEAD
    beqz    a4, 1f
    l32i    a5, a4, MSG_NEXT
    s32i    a5, a6, SB_IN_HEAD
    bnez    a5, 2f
    s32i    a5, a6, SB_IN_TAIL
    j       2f
1:  l32i    a4, a2, ACB_MB_HEAD
    beqz    a4, 2f
    l32i    a5, a4, MSG_NEXT
    s32i    a5, a2, ACB_MB_HEAD
    bnez    a5, 2f
    s32i    a5, a2, ACB_MB_TAIL
2:  SCHED_UNLOCK a8, a9
    mov     a2, a4
29:  retw
    .size   silica_rt_actor_recv, . - silica_rt_actor_recv

// ---------------------------------------------------------------------------------------------
// Ending other actors

// silica_rt_remove_actor(X0 actor) -> 0. Ends the actor normally at its next dispatch boundary;
// a parked actor ends now. The calling actor itself is a :language_error (below).
    .align  4
    .global silica_rt_remove_actor
    .type   silica_rt_remove_actor, @function
silica_rt_remove_actor:
    entry   a1, 32
    mov     a10, a2                     // X0 = reference (§15.1.4)
    mov     a11, a3
    call8   silica_rt_ref_acb
    mov     a2, a10
    beqz    a2, 9f
    // Spec §15.1.2.3: remove_actor must not name the calling actor; the caller fails with
    // :language_error and nothing is changed on it (as kill_abnormal).
    call8   silica_rt_current_actor
    beq     a10, a2, 8f
    mov     a10, a2
    movi    a11, 0
    call8   silica_rt_end_actor
9:  movi    a2, 0
    movi    a3, 0
    retw
8:  call8   silica_rt_language_error_current   // never returns
    j       8b
    .size   silica_rt_remove_actor, . - silica_rt_remove_actor

// silica_rt_actor_kill_abnormal(X0 reference) -> 0, and silica_rt_actor_kill_abnormal_named(X0
// registry atom) -> 0. Reason tag 1. An identity can be numerically small, so the atom form has its
// own entry (the emitter chooses it by the argument's type).
    .align  4
    .global silica_rt_actor_kill_abnormal_named
    .type   silica_rt_actor_kill_abnormal_named, @function
silica_rt_actor_kill_abnormal_named:
    entry   a1, 32
    movi    a10, silica_pid_registry_ref
    mov     a11, a2
    call8   silica_rt_registry_lookup
    mov     a2, a10
    j       61f
    .size   silica_rt_actor_kill_abnormal_named, . - silica_rt_actor_kill_abnormal_named

    .align  4
    .global silica_rt_actor_kill_abnormal
    .type   silica_rt_actor_kill_abnormal, @function
silica_rt_actor_kill_abnormal:
    entry   a1, 32
    mov     a10, a2
    mov     a11, a3
    call8   silica_rt_ref_acb
    mov     a2, a10
61: beqz    a2, 9f
    // Spec §15.1.2.3: kill_abnormal must not name the calling actor; the caller fails with
    // :language_error and nothing is changed on it (a call it is serving gets no reply).
    call8   silica_rt_current_actor
    beq     a10, a2, 8f
1:  l8ui    a4, a2, ACB_ALIVE
    beqz    a4, 9f
    l32i    a6, a2, ACB_SUP
    mov     a10, a2
    movi    a11, 1
    call8   silica_rt_end_actor
    // a supervised victim: its supervisor's pending exit notices are handled before returning
    mov     a4, a6
    beqz    a4, 9f
    mov     a10, a4
    call8   silica_rt_supervisor_drain_ingress
9:  movi    a2, 0
    movi    a3, 0
    retw
8:  call8   silica_rt_language_error_current   // never returns
    j       8b
    .size   silica_rt_actor_kill_abnormal, . - silica_rt_actor_kill_abnormal

// silica_rt_end_actor(acb, reason tag): request the end. The running actor (a self-kill) ends after
// its behaviour returns, as the reference does. An actor that is not running -- parked, suspended
// in a call, or queued but not yet dispatched -- is not in the middle of anything, so its exit
// path runs here, in the caller's context, and its stacks are recycled; a queued one keeps its
// ACB until the scheduler pops it (status DEAD). An actor running on another core ends at its
// next dispatch boundary.
    .align  4
    .global silica_rt_end_actor
silica_rt_end_actor:
    entry   a1, 32
    l8ui    a4, a2, ACB_KIND
    bnez    a4, 29f
    SCHED_LOCK a8, a9
    l8ui    a4, a2, ACB_ALIVE
    beqz    a4, 8f
    l8ui    a4, a2, ACB_REASON_TAG
    bnez    a4, 1f
    s8i     a3, a2, ACB_REASON_TAG
1:  movi    a4, 0
    s8i     a4, a2, ACB_ALIVE
    l8ui    a4, a2, ACB_STATUS
    movi    a5, ST_IDLE
    beq     a4, a5, 2f
    movi    a5, ST_SUSPENDED
    beq     a4, a5, 2f
    movi    a5, ST_WAIT_INGRESS
    beq     a4, a5, 2f
    movi    a5, ST_READY
    beq     a4, a5, 3f
    SCHED_UNLOCK a8, a9
    retw
2:  movi    a5, ST_RUNNING
    s8i     a5, a2, ACB_STATUS
    SCHED_UNLOCK a8, a9
    mov     a10, a2
    movi    a11, 1                      // ended by remove_actor / kill_abnormal
    call8   silica_rt_actor_exit
    mov     a10, a2
    call8   silica_rt_actor_recycle
    retw
3:  movi    a5, ST_RUNNING
    s8i     a5, a2, ACB_STATUS
    SCHED_UNLOCK a8, a9
    mov     a10, a2
    movi    a11, 1                      // ended by remove_actor / kill_abnormal
    call8   silica_rt_actor_exit
    mov     a10, a2
    call8   silica_rt_actor_recycle_stacks
    retw
8:  SCHED_UNLOCK a8, a9
29:  retw
    .size   silica_rt_end_actor, . - silica_rt_end_actor

// silica_rt_end_actor_leaf(acb, reason tag): silica_rt_end_actor for silica_rt_sup_shutdown_children,
// through the exit path without the shutdown (silica_rt_actor_exit_body), so that no exit path calls
// itself (main_stack_bound.py bounds main's stack only without recursion).
    .align  4
    .global silica_rt_end_actor_leaf
silica_rt_end_actor_leaf:
    entry   a1, 32
    l8ui    a4, a2, ACB_KIND
    bnez    a4, 29f
    SCHED_LOCK a8, a9
    l8ui    a4, a2, ACB_ALIVE
    beqz    a4, 8f
    l8ui    a4, a2, ACB_REASON_TAG
    bnez    a4, 1f
    s8i     a3, a2, ACB_REASON_TAG
1:  movi    a4, 0
    s8i     a4, a2, ACB_ALIVE
    l8ui    a4, a2, ACB_STATUS
    movi    a5, ST_IDLE
    beq     a4, a5, 2f
    movi    a5, ST_SUSPENDED
    beq     a4, a5, 2f
    movi    a5, ST_WAIT_INGRESS
    beq     a4, a5, 2f
    movi    a5, ST_READY
    beq     a4, a5, 3f
    SCHED_UNLOCK a8, a9
    retw
2:  movi    a5, ST_RUNNING
    s8i     a5, a2, ACB_STATUS
    SCHED_UNLOCK a8, a9
    mov     a10, a2
    movi    a11, 1                      // ended by remove_actor / kill_abnormal
    call8   silica_rt_actor_exit_body
    mov     a10, a2
    call8   silica_rt_actor_recycle
    retw
3:  movi    a5, ST_RUNNING
    s8i     a5, a2, ACB_STATUS
    SCHED_UNLOCK a8, a9
    mov     a10, a2
    movi    a11, 1                      // ended by remove_actor / kill_abnormal
    call8   silica_rt_actor_exit_body
    mov     a10, a2
    call8   silica_rt_actor_recycle_stacks
    retw
8:  SCHED_UNLOCK a8, a9
29:  retw
    .size   silica_rt_end_actor_leaf, . - silica_rt_end_actor_leaf

// ---------------------------------------------------------------------------------------------
// Registries. Three of them -- ordinary, dangerous (FFI) and device workers -- so a keyed cast can
// never reach a worker of another kind. Each registry is an actor whose state is a table of
// silica_registry_slots actor_refs indexed by atom (0 = unregistered; one slot per atom of the image);
// register_actor_named writes the table directly and the keyed call /
// cast forms read it, as in the reference; the actor itself answers {op, name, pid} messages with
// a (status, pid) pair.

// silica_rt_registry_lookup(&registry ref word, atom) -> acb or 0
    .align  4
silica_rt_registry_lookup:
    entry   a1, 32
    l32i    a2, a2, 0
    beqz    a2, 9f
    l32i    a2, a2, ACB_STATE           // the table
    beqz    a2, 9f
    REGISTRY_SLOTS a4
    bgeu    a3, a4, 9f
    slli    a3, a3, 2
    add     a2, a2, a3
    l32i    a2, a2, 0
    beqz    a2, 9f
    l8ui    a4, a2, ACB_ALIVE
    bnez    a4, 8f
9:  movi    a2, 0
8:  movi    a3, 0
    retw
    .size   silica_rt_registry_lookup, . - silica_rt_registry_lookup

// silica_rt_registry_store(&registry ref word, atom, acb) -> 0 stored (or the acb already holds this
// name), 1 the name is held by a live actor or supervisor and nothing was stored (spec §20.3.1). A slot
// whose holder has ended is free: the exit path forgets names, so such a slot is at most in flight.
    .align  4
silica_rt_registry_store:
    entry   a1, 32
    l32i    a2, a2, 0
    beqz    a2, 9f
    l32i    a2, a2, ACB_STATE
    beqz    a2, 9f
    REGISTRY_SLOTS a5
    bgeu    a3, a5, 8f
    slli    a5, a3, 2
    add     a5, a2, a5
    l32i    a6, a5, 0
    beqz    a6, 1f
    beq     a6, a4, 9f
    l8ui    a7, a6, ACB_ALIVE
    bnez    a7, 8f
1:  s32i    a4, a5, 0
    beqz    a4, 9f
    addi    a3, a3, 1
    s16i    a3, a4, ACB_REG_NAME
9:  movi    a2, 0
    movi    a3, 0
    retw
8:  movi    a2, 1
    movi    a3, 0
    retw
    .size   silica_rt_registry_store, . - silica_rt_registry_store

// silica_rt_registry_slot(&registry ref word, atom) -> address of the slot, or 0
    .align  4
silica_rt_registry_slot:
    entry   a1, 32
    l32i    a2, a2, 0
    beqz    a2, 9f
    l32i    a2, a2, ACB_STATE
    beqz    a2, 9f
    REGISTRY_SLOTS a4
    bgeu    a3, a4, 9f
    slli    a3, a3, 2
    add     a2, a2, a3
    movi    a3, 0
    retw
9:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_registry_slot, . - silica_rt_registry_slot

// silica_rt_registry_forget(acb, atom): clear the slot in whichever registry holds this actor.
    .align  4
silica_rt_registry_forget:
    entry   a1, 32
    movi    a4, 0
    s16i    a4, a2, ACB_REG_NAME
    movi    a10, silica_pid_registry_ref
    mov     a11, a3
    call8   silica_rt_registry_slot
    beqz    a10, 1f
    l32i    a5, a10, 0
    bne     a5, a2, 1f
    s32i    a4, a10, 0
1:  movi    a10, silica_dangerous_pid_registry_ref
    mov     a11, a3
    call8   silica_rt_registry_slot
    beqz    a10, 2f
    l32i    a5, a10, 0
    bne     a5, a2, 2f
    s32i    a4, a10, 0
2:  retw
    .size   silica_rt_registry_forget, . - silica_rt_registry_forget

// silica_rt_register_actor_named(X0 actor, X1 atom) -> 0 stored, 1 the name is held by a live actor
// or supervisor and nothing was stored (§20.3.1); the dangerous and device forms the same.
    .align  4
    .global silica_rt_register_actor_named
    .type   silica_rt_register_actor_named, @function
silica_rt_register_actor_named:
    entry   a1, 32
    mov     a10, a2                     // X0 = reference (§15.1.4): the slots hold its ACB
    mov     a11, a3
    call8   silica_rt_ref_acb
    movi    a2, 0
    movi    a3, 0
    beqz    a10, 61f                    // an ended actor is never named (§20.3.1)
    l8ui    a5, a10, ACB_ALIVE
    beqz    a5, 61f
    mov     a12, a10
    movi    a10, silica_pid_registry_ref
    mov     a11, a4
    call8   silica_rt_registry_store
    mov     a2, a10
    movi    a3, 0
61: retw
    .size   silica_rt_register_actor_named, . - silica_rt_register_actor_named

    .align  4
    .global silica_rt_register_dangerous_actor_named
    .type   silica_rt_register_dangerous_actor_named, @function
silica_rt_register_dangerous_actor_named:
    entry   a1, 32
    mov     a10, a2                     // X0 = reference (§15.1.4): the slots hold its ACB
    mov     a11, a3
    call8   silica_rt_ref_acb
    movi    a2, 0
    movi    a3, 0
    beqz    a10, 61f                    // an ended actor is never named (§20.3.1)
    l8ui    a5, a10, ACB_ALIVE
    beqz    a5, 61f
    mov     a12, a10
    movi    a10, silica_dangerous_pid_registry_ref
    mov     a11, a4
    call8   silica_rt_registry_store
    mov     a2, a10
    movi    a3, 0
61: retw
    .size   silica_rt_register_dangerous_actor_named, . - silica_rt_register_dangerous_actor_named

// silica_rt_actor_mark_device(X0 actor_ref) -> X0 actor_ref: marks an actor started by spawn_device so
// its failure report carries the hardware fault details. Emitted right after the spawn, before the
// first message is sent. Window: an actor on the other core could fault in its init before this
// store lands; sending to it only after the mark closes that.
    .align  4
    .global silica_rt_actor_mark_device
    .type   silica_rt_actor_mark_device, @function
silica_rt_actor_mark_device:
    entry   a1, 32
    mov     a10, a2                     // X0 = reference (§15.1.4); returned as it came
    mov     a11, a3
    call8   silica_rt_ref_acb
    beqz    a10, 9f
    movi    a4, 1
    s8i     a4, a10, ACB_DEVICE
9:  retw
    .size   silica_rt_actor_mark_device, . - silica_rt_actor_mark_device

    .align  4
    .global silica_rt_register_device_actor_named
    .type   silica_rt_register_device_actor_named, @function
silica_rt_register_device_actor_named:
    entry   a1, 32
    mov     a10, a2                     // X0 = reference (§15.1.4): the slots hold its ACB
    mov     a11, a3
    call8   silica_rt_ref_acb
    movi    a2, 0
    movi    a3, 0
    beqz    a10, 61f
    movi    a5, 1
    s8i     a5, a10, ACB_DEVICE
    l8ui    a5, a10, ACB_ALIVE
    beqz    a5, 61f                     // an ended actor is never named (§20.3.1)
    mov     a12, a10
    movi    a10, silica_device_pid_registry_ref
    mov     a11, a4
    call8   silica_rt_registry_store
    mov     a2, a10
    movi    a3, 0
61: retw
    .size   silica_rt_register_device_actor_named, . - silica_rt_register_device_actor_named

// Legacy unary register_actor(actor_ref) -> 0: the global slot belongs to the registry actor.
    .align  4
    .global silica_rt_register_actor
    .type   silica_rt_register_actor, @function
silica_rt_register_actor:
    entry   a1, 32
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_register_actor, . - silica_rt_register_actor

// silica_rt_registry_name_held(X0 atom) -> X0 = the live actor or supervisor holding the name in the
// ordinary registry, or 0. The supervisor child paths probe a child id with it before spawning.
    .align  4
    .global silica_rt_registry_name_held
    .type   silica_rt_registry_name_held, @function
silica_rt_registry_name_held:
    entry   a1, 32
    movi    a10, silica_pid_registry_ref
    mov     a11, a2
    call8   silica_rt_registry_lookup
    mov     a2, a10
    movi    a3, 0
    retw
    .size   silica_rt_registry_name_held, . - silica_rt_registry_name_held

// silica_rt_registry_require_free{,_dangerous,_device}(X0 atom): the pre-spawn check of
// spawn_registered, spawn_dangerous_registered, spawn_device_registered and
// spawn_registered_supervisor (§20.3.1): when a live actor holds the name no actor is spawned and the
// caller fails with :language_error (silica_rt_registry_name_taken, which does not return).
    .align  4
    .global silica_rt_registry_require_free
    .type   silica_rt_registry_require_free, @function
silica_rt_registry_require_free:
    entry   a1, 32
    movi    a10, silica_pid_registry_ref
    mov     a11, a2
    call8   silica_rt_registry_lookup
    bnez    a10, 1f
    movi    a2, 0
    movi    a3, 0
    retw
1:  call8   silica_rt_registry_name_taken
    j       1b
    .size   silica_rt_registry_require_free, . - silica_rt_registry_require_free

    .align  4
    .global silica_rt_registry_require_free_dangerous
    .type   silica_rt_registry_require_free_dangerous, @function
silica_rt_registry_require_free_dangerous:
    entry   a1, 32
    movi    a10, silica_dangerous_pid_registry_ref
    mov     a11, a2
    call8   silica_rt_registry_lookup
    bnez    a10, 1f
    movi    a2, 0
    movi    a3, 0
    retw
1:  call8   silica_rt_registry_name_taken
    j       1b
    .size   silica_rt_registry_require_free_dangerous, . - silica_rt_registry_require_free_dangerous

    .align  4
    .global silica_rt_registry_require_free_device
    .type   silica_rt_registry_require_free_device, @function
silica_rt_registry_require_free_device:
    entry   a1, 32
    movi    a10, silica_device_pid_registry_ref
    mov     a11, a2
    call8   silica_rt_registry_lookup
    bnez    a10, 1f
    movi    a2, 0
    movi    a3, 0
    retw
1:  call8   silica_rt_registry_name_taken
    j       1b
    .size   silica_rt_registry_require_free_device, . - silica_rt_registry_require_free_device

// silica_rt_registry_name_taken(): a registered name was already held by a live actor or supervisor
// (§20.3.1: spawn_registered, spawn_registered_supervisor, a supervised child id). In an actor it is a
// language-level failure, reason tag 2 (:language_error), ended where it stands like a case_clause; in
// main it is the language-level failure of §15.4.5.5: the failure atom's name, exit status 1. Never returns.
    .align  4
// silica_rt_convention_mismatch / silica_rt_language_error_current: the same failure for a call()/cast()
// whose target was spawned with the other calling convention (§16.2.6.4; nothing was enqueued) and for
// kill_abnormal naming the calling actor (§15.1.2.3).
    .global silica_rt_registry_name_taken
    .type   silica_rt_registry_name_taken, @function
    .global silica_rt_convention_mismatch
    .type   silica_rt_convention_mismatch, @function
    .global silica_rt_language_error_current
    .type   silica_rt_language_error_current, @function
silica_rt_convention_mismatch:
silica_rt_language_error_current:
silica_rt_registry_name_taken:
    entry   a1, 32
    call8   silica_rt_current_actor
    beqz    a10, 1f
    movi    a10, 2
    call8   silica_rt_actor_trap
1:  movi    a10, silica_rt_name_taken_msg
    call8   silica_rt_main_fail_exit
    j       1b
    .size   silica_rt_registry_name_taken, . - silica_rt_registry_name_taken

// silica_rt_actor_not_found(): cast_registered / call_registered / cast_dangerous_registered /
// cast_device_registered named a name no live actor holds in its registry
// (§20.3.1: they raise actor_not_found, as cast() and call() do for an ended actor). In an actor it
// is failure_reason (:explicit, :actor_not_found), tag 4, ended where it stands; in main it is the
// language-level failure of §15.4.5.5: the atom's name on the console, exit status 1. Never returns.
    .align  4
    .global silica_rt_actor_not_found
    .type   silica_rt_actor_not_found, @function
silica_rt_actor_not_found:
    entry   a1, 32
    call8   silica_rt_current_actor
    beqz    a10, 1f
    movi    a10, silica_registry_atom_actor_not_found
    l32i    a10, a10, 0
    call8   silica_rt_actor_trap_explicit
1:  movi    a10, silica_rt_actor_not_found_msg
    call8   silica_rt_main_fail_exit
    j       1b
    .size   silica_rt_actor_not_found, . - silica_rt_actor_not_found

// silica_rt_get_registry_actor() -> the registry actor_ref
    .align  4
    .global silica_rt_get_registry_actor
    .type   silica_rt_get_registry_actor, @function
silica_rt_get_registry_actor:
    entry   a1, 32
    movi    a10, silica_pid_registry_ref
    l32i    a10, a10, 0
    call8   silica_rt_acb_ident         // its identity (§15.1.4)
    mov     a2, a10
    mov     a3, a11
    retw
    .size   silica_rt_get_registry_actor, . - silica_rt_get_registry_actor

// The registry behaviour, in the emitted-function ABI: X0 = message record {op, name, pid} (its
// shape word, then three 8-byte slots), X1 = state (the table), X2 = the reply tuple buffer;
// returns X0 = that buffer with [+8] = a heap pair (status atom, actor_ref) and [+16] = the state.
    .align  4
    .global silica_rt_pid_registry_beh
    .type   silica_rt_pid_registry_beh, @function
silica_rt_pid_registry_beh:
    entry   a1, 32
    mov     a7, a6                      // a7 = reply buffer
    movi    a10, 16
    call8   silica_rt_alloc
    mov     a6, a10                     // a6 = pair
    l32i    a3, a2, 8                   // op
    l32i    a5, a2, 16                  // name
    l32i    a10, a2, 24                 // pid: a reference (§15.1.4), resolved to the ACB the
    l32i    a11, a2, 28                 // table holds (0: no actor)
    call8   silica_rt_ref_acb
    mov     a2, a10
    movi    a8, ATOM_INSERT
    beq     a3, a8, 1f
    movi    a8, ATOM_LOOKUP
    beq     a3, a8, 2f
    movi    a8, ATOM_DELETE
    beq     a3, a8, 3f
    movi    a8, ATOM_UNKNOWN_OP
    mov     a9, a2
    j       8f
    // :insert (§20.3.1): :name_taken when a live actor or supervisor holds the name (or the index is
    // outside the table, which no atom is); :actor_not_found when the actor has ended; :already_registered
    // when the actor holds another name; :ok when stored, or when the actor already holds this very name.
1:  REGISTRY_SLOTS a9
    bgeu    a5, a9, 12f
    beqz    a2, 13f
    l8ui    a8, a2, ACB_ALIVE
    beqz    a8, 13f
    slli    a9, a5, 2
    add     a9, a4, a9
    l32i    a8, a9, 0
    beqz    a8, 14f
    beq     a8, a2, 11f
    l8ui    a10, a8, ACB_ALIVE
    bnez    a10, 12f
14: l16ui    a8, a2, ACB_REG_NAME
    beqz    a8, 15f
    addi    a10, a5, 1
    bne     a8, a10, 16f
15: s32i    a2, a9, 0
    addi    a9, a5, 1
    s16i    a9, a2, ACB_REG_NAME
11: movi    a8, ATOM_OK
    mov     a9, a2
    j       8f
12: movi    a8, silica_registry_atom_name_taken
    l32i    a8, a8, 0
    mov     a9, a2
    j       8f
13: movi    a8, silica_registry_atom_actor_not_found
    l32i    a8, a8, 0
    movi    a9, 0
    j       8f
16: movi    a8, silica_registry_atom_already_registered
    l32i    a8, a8, 0
    mov     a9, a2
    j       8f
2:  REGISTRY_SLOTS a9
    bgeu    a5, a9, 21f
    slli    a9, a5, 2
    add     a9, a4, a9
    l32i    a9, a9, 0
    beqz    a9, 21f
    movi    a8, ATOM_FOUND
    j       8f
21: movi    a8, ATOM_NOT_FOUND
    movi    a9, 0
    j       8f
3:  REGISTRY_SLOTS a9
    bgeu    a5, a9, 31f
    slli    a9, a5, 2
    add     a9, a4, a9
    movi    a8, 0
    s32i    a8, a9, 0
31: movi    a8, ATOM_OK
    mov     a9, a2
8:  s32i    a8, a6, 0
    movi    a8, 0
    s32i    a8, a6, 4
    mov     a10, a9                     // the pid answered: the identity of the ACB (all ones: none)
    call8   silica_rt_acb_ident
    s32i    a10, a6, 8
    s32i    a11, a6, 12
    movi    a8, 0
    s32i    a8, a7, 0
    s32i    a8, a7, 4
    s32i    a6, a7, 8
    s32i    a8, a7, 12
    s32i    a4, a7, 16
    s32i    a8, a7, 20
    mov     a2, a7
    movi    a3, 0
    retw
    .size   silica_rt_pid_registry_beh, . - silica_rt_pid_registry_beh

// silica_rt_registry_spawn(&ref word): the registry actor, with small stacks.
    .align  4
silica_rt_registry_spawn:
    entry   a1, 48
    mov     a6, a2
    l32i    a3, a2, 0
    bnez    a3, 9f
    REGISTRY_SLOTS a10
    slli    a10, a10, 2
    call8   silica_rt_alloc
    mov     a7, a10
    rur     a8, threadptr
    movi    a9, 0
    s32i    a9, a8, 0                   // X3: no trampoline
    movi    a9, 2
    s32i    a9, a8, 8                   // X4: default reservation, :keep_last_message
    mov     a10, a7
    movi    a11, 0
    movi    a12, silica_rt_pid_registry_beh
    movi    a13, 0
    movi    a14, 0
    movi    a8, silica_rt_runtime_spawner   // numbered by the runtime, not main (§15.1.4)
    movi    a9, silica_rt_spawn_rec_override
    s32i    a8, a9, 0
    call8   silica_rt_actor_spawn
    movi    a9, silica_rt_spawn_rec_override
    movi    a8, 0
    s32i    a8, a9, 0
    call8   silica_rt_ref_acb               // the registry never ends: its ACB is kept
    s32i    a10, a6, 0
    // the registries are runtime actors, not the program's root
    movi    a8, silica_rt_wait_root_acb
    l32i    a9, a8, 0
    bne     a9, a10, 9f
    movi    a9, 0
    s32i    a9, a8, 0
9:  retw
    .size   silica_rt_registry_spawn, . - silica_rt_registry_spawn

// Injected at the top of every program's main by the emitter.
    .align  4
    .global silica_pid_registry_init
    .type   silica_pid_registry_init, @function
silica_pid_registry_init:
    entry   a1, 32
    call8   silica_rt_actors_init
    movi    a10, silica_pid_registry_ref
    call8   silica_rt_registry_spawn
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_pid_registry_init, . - silica_pid_registry_init

    .align  4
    .global silica_dangerous_pid_registry_init
    .type   silica_dangerous_pid_registry_init, @function
silica_dangerous_pid_registry_init:
    entry   a1, 32
    call8   silica_rt_actors_init
    movi    a10, silica_dangerous_pid_registry_ref
    call8   silica_rt_registry_spawn
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_dangerous_pid_registry_init, . - silica_dangerous_pid_registry_init

// The third registry, for device workers (device spec §1): one more registry actor
// and a REGISTRY_SLOTS table on a board where SRAM is scarce (actor_memory_budget_plan.md).
    .align  4
    .global silica_device_pid_registry_init
    .type   silica_device_pid_registry_init, @function
silica_device_pid_registry_init:
    entry   a1, 32
    call8   silica_rt_actors_init
    movi    a10, silica_device_pid_registry_ref
    call8   silica_rt_registry_spawn
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_device_pid_registry_init, . - silica_device_pid_registry_init

// ---------------------------------------------------------------------------------------------
// Placement (spec §15.1.2 Actor Pinning Policy, §22.10)

// silica_rt_migrate_actor(X0 actor, X1 target core) -> 0 :ok, 1 :invalid_target,
// 2 :actor_not_found, 3 :migration_blocked. The move is applied at the actor's next dispatch
// boundary; a parked actor has none pending, so it moves at once. The mailbox moves with the
// actor (it is the actor's own), so message order is preserved (§15.1.2.4.1).
    .align  4
    .global silica_rt_migrate_actor
    .type   silica_rt_migrate_actor, @function
silica_rt_migrate_actor:
    entry   a1, 32
    mov     a10, a2                     // X0 = reference (§15.1.4): its ACB, or 0
    mov     a11, a3
    call8   silica_rt_ref_acb
    mov     a2, a10
    movi    a3, 0
    beqz    a2, 8f
    l8ui    a6, a2, ACB_KIND
    bnez    a6, 8f
    l8ui    a6, a2, ACB_ALIVE
    beqz    a6, 8f
    bnez    a5, 7f
    movi    a6, silica_rt_ncores
    l32i    a6, a6, 0
    bgeu    a4, a6, 7f
    SCHED_LOCK a8, a9
    l8ui    a6, a2, ACB_STATUS
    beqz    a6, 1f                      // idle: pin now
    movi    a7, ST_SUSPENDED
    beq     a6, a7, 1f                  // suspended in a call: resumes on the new core
    addi    a7, a4, 1
    s8i     a7, a2, ACB_TARGET          // running or queued: at the next dispatch boundary
    j       2f
1:  s8i     a4, a2, ACB_CORE
2:  SCHED_UNLOCK a8, a9
    movi    a2, 0
    movi    a3, 0
    retw
7:  movi    a2, 1
    movi    a3, 0
    retw
8:  movi    a2, 2
    movi    a3, 0
    retw
    .size   silica_rt_migrate_actor, . - silica_rt_migrate_actor

// pin_actor_to_core(X0, X1 core) -> 0 : a move (§22.10)
    .align  4
    .global silica_rt_pin_actor_to_core
    .type   silica_rt_pin_actor_to_core, @function
silica_rt_pin_actor_to_core:
    entry   a1, 32
    mov     a10, a2
    mov     a11, a3
    mov     a12, a4
    mov     a13, a5
    call8   silica_rt_migrate_actor
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_pin_actor_to_core, . - silica_rt_pin_actor_to_core

// The ESP32-S3's two LX7 cores are alike; both are reported as :performance cores, so a move to a
// performance core goes to core 0 and there is no efficiency core to move to.
    .align  4
    .global silica_rt_pin_actor_to_performance_core
    .type   silica_rt_pin_actor_to_performance_core, @function
silica_rt_pin_actor_to_performance_core:
    entry   a1, 32
    mov     a10, a2
    mov     a11, a3
    movi    a12, 0
    movi    a13, 0
    call8   silica_rt_migrate_actor
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_pin_actor_to_performance_core, . - silica_rt_pin_actor_to_performance_core

    .align  4
    .global silica_rt_pin_actor_to_efficiency_core
    .global silica_rt_pin_actor_realtime
    .global silica_rt_pin_actor_to_numa_node
    .global silica_rt_unpin_actor
    .type   silica_rt_pin_actor_to_efficiency_core, @function
silica_rt_pin_actor_to_efficiency_core:
silica_rt_pin_actor_realtime:
silica_rt_pin_actor_to_numa_node:
silica_rt_unpin_actor:
    entry   a1, 32
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_pin_actor_to_efficiency_core, . - silica_rt_pin_actor_to_efficiency_core

// silica_rt_set_actor_priority(X0 actor, X1 level) -> 0 :ok, 1 :actor_not_found (no actor, or one
// that has ended). Levels 0 low, 1 normal, 2 high choose the ready queue the actor waits in (§23.1.1
// priority hints; the emitter maps the program's :low / :normal / :high to them); anything else is
// normal. The level is also the actor's weight class under the weighted_fair and lottery policies.
    .align  4
    .global silica_rt_set_actor_priority
    .type   silica_rt_set_actor_priority, @function
silica_rt_set_actor_priority:
    entry   a1, 32
    mov     a10, a2                     // X0 = reference (§15.1.4): its ACB, or 0
    mov     a11, a3
    call8   silica_rt_ref_acb
    mov     a2, a10
    movi    a3, 0
    beqz    a2, 8f
    l8ui    a6, a2, ACB_ALIVE
    beqz    a6, 8f
    movi    a6, 3
    bltu    a4, a6, 1f
    movi    a4, 1
1:  s8i     a4, a2, ACB_PRIO
    movi    a2, 0
    movi    a3, 0
    retw
8:  movi    a2, 1
    movi    a3, 0
    retw
    .size   silica_rt_set_actor_priority, . - silica_rt_set_actor_priority

// silica_rt_set_scheduler_policy(X0 code) -> 0 :ok, 1 :invalid_policy. Codes are POLICY_* (the
// emitter maps the program's policy atoms to them and the result back, prims_actors.silica
// emit_set_scheduler_policy). Takes effect at the next push or pop on every core; see
// "Dispatch-order policies" above for what happens to actors already queued.
    .align  4
    .global silica_rt_set_scheduler_policy
    .type   silica_rt_set_scheduler_policy, @function
silica_rt_set_scheduler_policy:
    entry   a1, 32
    bnez    a3, 7f
    movi    a4, POLICY_COUNT
    bgeu    a2, a4, 7f
    SCHED_LOCK a8, a9
    movi    a4, silica_rt_sched_policy
    s32i    a2, a4, 0
    SCHED_UNLOCK a8, a9
    movi    a2, 0
    movi    a3, 0
    retw
7:  movi    a2, 1
    movi    a3, 0
    retw
    .size   silica_rt_set_scheduler_policy, . - silica_rt_set_scheduler_policy

// ---------------------------------------------------------------------------------------------
// Topology (spec §22.10). Records and lists are built in the emitter's layouts: a record is its
// shape word then one 8-byte slot per field; a List[T, normal] is a 24-byte handle {length, first chunk, cursor} over
// 24-byte chunks {slot 0, slot 1, next} (two 8-byte slots per chunk, rt_list.S).

// silica_rt_list_from_words(count, words*) -> list handle (0 = nil); words are 8-byte slots.
    .align  4
silica_rt_list_from_words:
    entry   a1, 48
    beqz    a2, 9f
    mov     a6, a2                      // a6 = n
    mov     a7, a3                      // a7 = words
    movi    a10, 24
    call8   silica_rt_alloc
    mov     a5, a10                     // a5 = handle
    s32i    a6, a5, 0
    // first chunk holds n mod 2 == 1 ? one element at slot 1 : two elements
    movi    a4, 0                       // a4 = previous chunk (0: first)
    mov     a2, a6
    extui   a3, a6, 0, 1                // odd -> cursor 8
    slli    a3, a3, 3
    s32i    a3, a5, 16
1:  beqz    a2, 8f
    movi    a10, 24
    call8   silica_rt_alloc
    bnez    a4, 2f
    s32i    a10, a5, 8
    j       3f
2:  s32i    a10, a4, 16
3:  mov     a4, a10
    // fill from `cursor` (first chunk) or 0 upward
    add     a8, a10, a3
    movi    a3, 0
    addi    a9, a10, 16
4:  bgeu    a8, a9, 1b
    l32i    a11, a7, 0
    s32i    a11, a8, 0
    l32i    a11, a7, 4
    s32i    a11, a8, 4
    addi    a7, a7, 8
    addi    a8, a8, 8
    addi    a2, a2, -1
    bnez    a2, 4b
8:  mov     a2, a5
    movi    a3, 0
    retw
9:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_list_from_words, . - silica_rt_list_from_words

// Reserved shape numbers of the records this runtime builds (emitter record_shape.silica,
// atom_table.silica seed_actor_runtime_atoms): the word every record starts with.
#define SHAPE_CORE_INFO        65537
#define SHAPE_CPU_TOPOLOGY     65538
#define SHAPE_CACHE_HIERARCHY  65541
#define SHAPE_ACTOR_MEMORY     65543

// silica_rt_core_info_record(id) -> { id, core_type, capabilities, frequency_mhz } (40 B: shape word, four slots)
    .align  4
silica_rt_core_info_record:
    entry   a1, 32
    mov     a6, a2
    movi    a10, 40
    call8   silica_rt_alloc
    movi    a8, SHAPE_CORE_INFO
    s32i    a8, a10, 0
    s32i    a6, a10, 8
    srai    a6, a6, 31
    s32i    a6, a10, 12
    movi    a8, ATOM_PERFORMANCE
    s32i    a8, a10, 16
    mov     a2, a10
    movi    a3, 0
    retw
    .size   silica_rt_core_info_record, . - silica_rt_core_info_record

// silica_rt_get_core_capabilities(X0 id) -> X0 core_info; an unknown id gives the sentinel id -1
    .align  4
    .global silica_rt_get_core_capabilities
    .type   silica_rt_get_core_capabilities, @function
silica_rt_get_core_capabilities:
    entry   a1, 32
    movi    a4, silica_rt_ncores
    l32i    a4, a4, 0
    bnez    a3, 1f
    bgeu    a2, a4, 1f
    j       2f
1:  movi    a2, -1
2:  mov     a10, a2
    call8   silica_rt_core_info_record
    mov     a2, a10
    movi    a3, 0
    retw
    .size   silica_rt_get_core_capabilities, . - silica_rt_get_core_capabilities

// silica_rt_get_cpu_topology() -> X0 { cores, numa_nodes, cache_hierarchy }
    .align  4
    .global silica_rt_get_cpu_topology
    .type   silica_rt_get_cpu_topology, @function
silica_rt_get_cpu_topology:
    entry   a1, 64
    movi    a4, silica_rt_ncores
    l32i    a4, a4, 0
    movi    a5, 0
1:  bge     a5, a4, 2f
    mov     a10, a5
    call8   silica_rt_core_info_record
    slli    a6, a5, 3
    add     a6, a1, a6
    s32i    a10, a6, 0
    movi    a7, 0
    s32i    a7, a6, 4
    addi    a5, a5, 1
    j       1b
2:  mov     a10, a4
    mov     a11, a1
    call8   silica_rt_list_from_words
    mov     a6, a10                     // cores list
    movi    a10, 16
    call8   silica_rt_alloc
    movi    a8, SHAPE_CACHE_HIERARCHY
    s32i    a8, a10, 0
    mov     a7, a10                     // cache_hierarchy { levels: nil }
    movi    a10, 32
    call8   silica_rt_alloc
    movi    a8, SHAPE_CPU_TOPOLOGY
    s32i    a8, a10, 0
    s32i    a6, a10, 8
    s32i    a7, a10, 24
    mov     a2, a10
    movi    a3, 0
    retw
    .size   silica_rt_get_cpu_topology, . - silica_rt_get_cpu_topology

// silica_rt_get_performance_cores() -> List[int64] of every running core; efficiency cores: none
    .align  4
    .global silica_rt_get_performance_cores
    .type   silica_rt_get_performance_cores, @function
silica_rt_get_performance_cores:
    entry   a1, 48
    movi    a4, silica_rt_ncores
    l32i    a4, a4, 0
    movi    a5, 0
    movi    a7, 0
1:  bge     a5, a4, 2f
    slli    a6, a5, 3
    add     a6, a1, a6
    s32i    a5, a6, 0
    s32i    a7, a6, 4
    addi    a5, a5, 1
    j       1b
2:  mov     a10, a4
    mov     a11, a1
    call8   silica_rt_list_from_words
    mov     a2, a10
    movi    a3, 0
    retw
    .size   silica_rt_get_performance_cores, . - silica_rt_get_performance_cores

    .align  4
    .global silica_rt_get_efficiency_cores
    .type   silica_rt_get_efficiency_cores, @function
silica_rt_get_efficiency_cores:
    entry   a1, 32
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_get_efficiency_cores, . - silica_rt_get_efficiency_cores

// ---------------------------------------------------------------------------------------------
// Ending the program (spec §15.1.2.5).
//
// wait_for_exit() -> int64: main parks (ST_WAITQ) until an exit request is recorded, then returns
// the recorded value to main (a2 low word, a3 high word): the first cast_exit's value, or 0 for a
// line reading "exit" on the console's receive side (read by core 0's scheduler loop). main then
// continues, and the program ends when main returns, through the image's ordinary end of main
// (rt_start.S -> rt_console.S silica_rt_exit: the exit marker with main's result, then halt, core 0
// stalling the APP cpu first); the actors are abandoned. A program that has gone quiet waits. The
// flag is checked under the lock before parking, so a request recorded while main was still
// running returns at once; a resume without a recorded request (none is expected) parks again.
// From an actor the call returns 0 at once, as before.
    .align  4
    .global silica_rt_wait_for_exit
    .type   silica_rt_wait_for_exit, @function
silica_rt_wait_for_exit:
    entry   a1, 32
    call8   silica_rt_actors_init
    call8   silica_rt_current
    mov     a2, a10
    l8ui    a4, a2, ACB_KIND
    movi    a5, KIND_MAIN
    bne     a4, a5, 8f
    movi    a6, silica_rt_exit_flag
1:  SCHED_LOCK a8, a9
    l32i    a7, a6, 0
    bnez    a7, 2f                      // a request is recorded: return without parking
    movi    a4, ST_WAITQ
    s8i     a4, a2, ACB_STATUS
    SCHED_UNLOCK a8, a9
    call8   silica_rt_yield_to_sched    // resumed by silica_rt_exit_request_record
    j       1b
2:  SCHED_UNLOCK a8, a9
    movi    a6, silica_rt_exit_request
    l32i    a2, a6, 0                   // the recorded int64 value, to main
    l32i    a3, a6, 4
    retw
8:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_wait_for_exit, . - silica_rt_wait_for_exit

// cast_exit(value: int64) -> boolean. a2:a3 = the value (low word, high word). Records the request
// and returns at once: 1 when it was recorded (main's wait returns this value), 0 when an earlier
// request already was. Any actor on either core; nothing here allocates. Nothing that follows the
// call in the same dispatch is guaranteed to run: main may end the program as soon as its core
// schedules it.
    .align  4
    .global silica_rt_cast_exit
    .type   silica_rt_cast_exit, @function
silica_rt_cast_exit:
    entry   a1, 32
    mov     a6, a2
    mov     a7, a3
    call8   silica_rt_actors_init
    mov     a10, a6
    mov     a11, a7
    call8   silica_rt_exit_request_record
    mov     a2, a10
    movi    a3, 0
    retw
    .size   silica_rt_cast_exit, . - silica_rt_cast_exit

// ---------------------------------------------------------------------------------------------
// Links and monitors (spec §15.4.8.5-8.6): the reference runtime's Phase G surface returns benign
// values; the same here.
    .align  4
    .global silica_rt_actor_link
    .global silica_rt_actor_demonitor
    .type   silica_rt_actor_link, @function
silica_rt_actor_link:
silica_rt_actor_demonitor:
    entry   a1, 32
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_actor_link, . - silica_rt_actor_link

    .align  4
    .global silica_rt_actor_monitor
    .type   silica_rt_actor_monitor, @function
silica_rt_actor_monitor:
    entry   a1, 32
    retw
    .size   silica_rt_actor_monitor, . - silica_rt_actor_monitor

// silica_rt_actor_add_child(X0 supervisor, X1 child) -> 0: the explicit parent/child relation.
    .align  4
    .global silica_rt_actor_add_child
    .type   silica_rt_actor_add_child, @function
silica_rt_actor_add_child:
    entry   a1, 32
    mov     a10, a4                     // X0 / X1 = references (§15.1.4)
    mov     a11, a5
    call8   silica_rt_ref_acb
    mov     a4, a10
    mov     a10, a2
    mov     a11, a3
    call8   silica_rt_ref_acb
    mov     a2, a10
    beqz    a2, 9f
    beqz    a4, 9f
    s32i    a2, a4, ACB_SUP             // the parent's supervision block comes with the first
9:  movi    a2, 0                       // exit notice it receives (silica_rt_enqueue_ingress)
    movi    a3, 0
    retw
    .size   silica_rt_actor_add_child, . - silica_rt_actor_add_child

// ---------------------------------------------------------------------------------------------
// Exit notification (spec §15.4.10) and its behaviour-only accessors

// silica_rt_actor_deliver_exit(X0 dying actor) -> 0 delivered to its supervisor's ingress, or
// dropped because that supervisor is dead (spec §15.4.10.4: silently; the unwind report still
// reaches the FailureReporter); 1 no supervisor: a root actor, the caller prints the root-exit note.
// (Until 2026-10-12 a dead supervisor gave 1 as well, so a child that outlived its supervisor
// printed the note a second time; supervisors_board_defects_addition/child_outlives_supervisor_board.)
    .align  4
    .global silica_rt_actor_deliver_exit
    .type   silica_rt_actor_deliver_exit, @function
silica_rt_actor_deliver_exit:
    entry   a1, 32
    l32i    a6, a2, ACB_SUP
    beqz    a6, 19f                     // (SCHED_LOCK below defines a local 9: of its own)
    movi    a10, 40
    call8   silica_rt_alloc
    mov     a7, a10
    s32i    a2, a7, 0
    l8ui    a8, a2, ACB_REASON_TAG
    s32i    a8, a7, 8
    l16ui    a8, a2, ACB_REASON_ATOM
    s32i    a8, a7, 16
    l16ui    a8, a2, ACB_AGENT
    s32i    a8, a7, 24
    // an actor that ended inside its start trampoline: the notice holds its ACB until a supervisor
    // has handled it (word 32; silica_rt_exit_payload_free), since the row is matched by it
    movi    a8, 0
    s32i    a8, a7, 32
    l32i    a4, a2, ACB_SB
    beqz    a4, 1f
    SCHED_LOCK a8, a9
    l32i    a3, a4, SB_TRAMP_RAN
    bbci    a3, TR_INIT_DEAD_BIT, 2f
    movi    a5, TR_NOTICE
    or      a3, a3, a5
    s32i    a3, a4, SB_TRAMP_RAN
    movi    a5, 1
    s32i    a5, a7, 32
2:  SCHED_UNLOCK a8, a9
1:  call8   silica_rt_alloc_node
    mov     a5, a10                     // a5 = the node
    movi    a8, 2
    s32i    a8, a5, MSG_KIND
    s32i    a7, a5, MSG_PAYLOAD
    mov     a11, a5
    mov     a10, a6
    call8   silica_rt_enqueue_ingress
    beqz    a10, 8f
    mov     a10, a7                     // a dead supervisor: the notice goes back (payload, node)
    call8   silica_rt_exit_payload_free
    mov     a10, a5
    call8   silica_rt_free_node
8:  movi    a2, 0
    movi    a3, 0
    retw
19: movi    a2, 1
    movi    a3, 0
    retw
    .size   silica_rt_actor_deliver_exit, . - silica_rt_actor_deliver_exit

// silica_rt_actor_supervision_ingress_enqueue(X0 actor, X1 inline int64) -> :ok (trial hook: the
// payload is not a structured notice, so the target's behaviour runs on it)
    .align  4
    .global silica_rt_actor_supervision_ingress_enqueue
    .type   silica_rt_actor_supervision_ingress_enqueue, @function
silica_rt_actor_supervision_ingress_enqueue:
    entry   a1, 32
    mov     a10, a2                     // X0 = reference (§15.1.4): its ACB, or 0
    mov     a11, a3
    call8   silica_rt_ref_acb
    mov     a2, a10
    movi    a3, 0
    beqz    a2, 9f
    call8   silica_rt_alloc_node
    movi    a8, 2
    s32i    a8, a10, MSG_KIND
    movi    a8, 1
    s32i    a8, a10, MSG_INGRESS_KIND
    s32i    a4, a10, MSG_PAYLOAD
    s32i    a5, a10, MSG_PAYLOAD + 4
    mov     a11, a10
    mov     a10, a2
    call8   silica_rt_enqueue_ingress
9:  movi    a2, ATOM_OK
    movi    a3, 0
    retw
    .size   silica_rt_actor_supervision_ingress_enqueue, . - silica_rt_actor_supervision_ingress_enqueue

// silica_rt_actor_supervision_wait_and_drain_one() -> X0 failure payload: blocks the running actor
// until an exit notice is in its ingress, runs the restart logic, returns the payload.
    .align  4
    .global silica_rt_actor_supervision_wait_and_drain_one
    .type   silica_rt_actor_supervision_wait_and_drain_one, @function
silica_rt_actor_supervision_wait_and_drain_one:
    entry   a1, 32
    call8   silica_rt_current_actor
    mov     a2, a10
    beqz    a2, 29f
1:  SCHED_LOCK a8, a9
    l32i    a7, a2, ACB_SB              // a7 = the supervision block (the enqueue makes it)
    beqz    a7, 11f
    l32i    a4, a7, SB_IN_HEAD
    bnez    a4, 2f
11: movi    a4, ST_WAIT_INGRESS
    s8i     a4, a2, ACB_STATUS
    SCHED_UNLOCK a8, a9
    call8   silica_rt_yield_to_sched
    j       1b
2:  l32i    a5, a4, MSG_NEXT
    s32i    a5, a7, SB_IN_HEAD
    bnez    a5, 3f
    s32i    a5, a7, SB_IN_TAIL
3:  l32i    a5, a7, SB_IN_DEPTH
    addi    a5, a5, -1
    s32i    a5, a7, SB_IN_DEPTH
    SCHED_UNLOCK a8, a9
    l32i    a6, a4, MSG_PAYLOAD          // a6 = payload
    l32i    a5, a4, MSG_INGRESS_KIND
    bnez    a5, 4f
    beqz    a6, 4f
    l32i    a10, a6, 0
    beqz    a10, 4f
    mov     a11, a2
    l32i    a12, a6, 8
    call8   silica_rt_supervisor_maybe_restart
    l32i    a5, a6, 32                  // the program gets the payload; its hold on the actor ends
    beqz    a5, 4f
    movi    a5, 0
    s32i    a5, a6, 32
    l32i    a10, a6, 0
    movi    a11, TR_NOTICE
    call8   silica_rt_tramp_release
4:  mov     a10, a4
    call8   silica_rt_free_node
    mov     a2, a6
    movi    a3, 0
    retw
29:  movi    a3, 0
    retw
    .size   silica_rt_actor_supervision_wait_and_drain_one, . - silica_rt_actor_supervision_wait_and_drain_one

    .align  4
    .global silica_rt_actor_failure_reason_tag
    .type   silica_rt_actor_failure_reason_tag, @function
silica_rt_actor_failure_reason_tag:
    entry   a1, 32
    beqz    a2, 1f
    l32i    a2, a2, 8
1:  movi    a3, 0
    retw
    .size   silica_rt_actor_failure_reason_tag, . - silica_rt_actor_failure_reason_tag

// reason tag -> failure_reason atom: 0 :normal, 2 :language_error, 3 :memory_fault, 4 :explicit,
// else :unknown (the reference maps 5 to :foreign_fault, which the fixed atom prefix lacks).
    .align  4
    .global silica_rt_actor_failure_reason_atom
    .type   silica_rt_actor_failure_reason_atom, @function
silica_rt_actor_failure_reason_atom:
    entry   a1, 32
    movi    a3, 0
    beqz    a2, 7f
    l32i    a4, a2, 8
    movi    a2, ATOM_NORMAL
    beqz    a4, 9f
    movi    a2, ATOM_LANGUAGE_ERROR
    movi    a5, 2
    beq     a4, a5, 9f
    movi    a2, ATOM_MEMORY_FAULT
    movi    a5, 3
    beq     a4, a5, 9f
    movi    a2, ATOM_EXPLICIT
    movi    a5, 4
    beq     a4, a5, 9f
7:  movi    a2, ATOM_UNKNOWN
9:  retw
    .size   silica_rt_actor_failure_reason_atom, . - silica_rt_actor_failure_reason_atom

    .align  4
    .global silica_rt_actor_failure_agent_type
    .type   silica_rt_actor_failure_agent_type, @function
silica_rt_actor_failure_agent_type:
    entry   a1, 32
    beqz    a2, 1f
    l32i    a2, a2, 24
1:  movi    a3, 0
    retw
    .size   silica_rt_actor_failure_agent_type, . - silica_rt_actor_failure_agent_type

    .align  4
    .global silica_rt_actor_failure_release
    .type   silica_rt_actor_failure_release, @function
silica_rt_actor_failure_release:
    entry   a1, 32
    mov     a10, a2
    call8   silica_rt_free
    movi    a2, ATOM_OK
    movi    a3, 0
    retw
    .size   silica_rt_actor_failure_release, . - silica_rt_actor_failure_release

// ---------------------------------------------------------------------------------------------
// The failure report (the reference's deliver_unwind_report). Delivered to the registered root
// FailureReporter as a Silica string when one is alive, else printed on the console:
//   \n=== Silica Actor Failure ===\nactor_id:        N\nagent_type_atom: N\nreason_tag:      N
//   \nsupervisor_acb:  0x..\ncall_stack:\n  #0  <behaviour symbol>\n  #1  _actor_thread_main
//   \n=== End Silica Actor Failure ===\n
// The behaviour's symbol comes from the function-name records the emitter writes
// (.rodata.silica_fnames: {address, name} pairs between _silica_fnames_start and _end).

    .align  4
    .global silica_rt_failure_reporter_register
    .type   silica_rt_failure_reporter_register, @function
silica_rt_failure_reporter_register:
    entry   a1, 32
    movi    a4, silica_rt_root_failure_reporter
    l32i    a5, a4, 0
    bnez    a5, 1f
    // X0 = the reporter's reference: the identity is kept, the word below only says one is
    // registered (delivery resolves the identity, §15.1.4)
    movi    a5, silica_rt_root_failure_reporter_id
    s32i    a2, a5, 0
    s32i    a3, a5, 4
    movi    a5, 1
    s32i    a5, a4, 0
1:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_failure_reporter_register, . - silica_rt_failure_reporter_register

    .align  4
    .global silica_rt_failure_reporter_set_dump_limit
    .type   silica_rt_failure_reporter_set_dump_limit, @function
silica_rt_failure_reporter_set_dump_limit:
    entry   a1, 32
    movi    a4, silica_rt_region_dump_limit
    s32i    a2, a4, 0
    s32i    a3, a4, 4
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_failure_reporter_set_dump_limit, . - silica_rt_failure_reporter_set_dump_limit

// silica_rt_behaviour_name(fn address) -> C string, or the "<unknown behavior>" text.
// A record is {.word address, .word name} followed by the name's bytes, the next record 4-aligned
// after the NUL (emitter_core writes them in that order).
    .align  4
silica_rt_behaviour_name:
    entry   a1, 32
    movi    a3, _silica_fnames_start
    movi    a4, _silica_fnames_end
1:  bgeu    a3, a4, 9f
    l32i    a5, a3, 0
    beq     a5, a2, 2f
    l32i    a5, a3, 4                   // the name: skip to its NUL, then align
11: l8ui    a6, a5, 0
    addi    a5, a5, 1
    bnez    a6, 11b
    addi    a5, a5, 3
    movi    a6, -4
    and     a3, a5, a6
    j       1b
2:  l32i    a2, a3, 4
    movi    a3, 0
    retw
9:  movi    a2, silica_rt_banner_unknown
    movi    a3, 0
    retw
    .size   silica_rt_behaviour_name, . - silica_rt_behaviour_name

// The report is composed into a buffer (silica_rt_report_buf, 512 B) by the emit helpers below,
// then printed or cast.
    .section .bss.silica_rt_report, "aw", @nobits
    .balign 8
silica_rt_report_buf:
    .space  512
silica_rt_report_len:
    .space  4
    .section .text.silica_rt_actors, "ax"
    .literal_position

// append a C string
    .align  4
silica_rt_report_puts:
    entry   a1, 32
    movi    a3, silica_rt_report_len
    l32i    a4, a3, 0
    movi    a5, silica_rt_report_buf
    add     a5, a5, a4
    movi    a7, 500
1:  l8ui    a6, a2, 0
    beqz    a6, 2f
    bgeu    a4, a7, 2f
    s8i     a6, a5, 0
    addi    a5, a5, 1
    addi    a2, a2, 1
    addi    a4, a4, 1
    j       1b
2:  s32i    a4, a3, 0
    retw
    .size   silica_rt_report_puts, . - silica_rt_report_puts

// append "0x" + 8 hex digits
    .align  4
silica_rt_report_hex:
    entry   a1, 32
    mov     a6, a2
    movi    a3, silica_rt_report_len
    l32i    a4, a3, 0
    movi    a5, silica_rt_report_buf
    add     a5, a5, a4
    movi    a7, 48
    s8i     a7, a5, 0
    movi    a7, 120
    s8i     a7, a5, 1
    addi    a5, a5, 2
    movi    a7, 28
1:  ssr     a7
    srl     a8, a6
    extui   a8, a8, 0, 4
    movi    a9, 10
    bltu    a8, a9, 2f
    addi    a8, a8, 39
2:  addi    a8, a8, 48
    s8i     a8, a5, 0
    addi    a5, a5, 1
    addi    a7, a7, -4
    bgez    a7, 1b
    addi    a4, a4, 10
    s32i    a4, a3, 0
    retw
    .size   silica_rt_report_hex, . - silica_rt_report_hex

// append an unsigned 64-bit decimal: a2 = low word, a3 = high word. Each step divides by 10 in
// 16-bit pieces (high word, then the two halves of the low word), so only 32-bit QUOU/REMU are needed.
    .align  4
silica_rt_report_udec64:
    entry   a1, 64
    addi    a6, a1, 40                  // digits backwards into [a1 + 16, a1 + 40)
    mov     a7, a6
    movi    a8, 10
1:  remu    a9, a3, a8
    quou    a3, a3, a8
    extui   a10, a2, 16, 16
    slli    a9, a9, 16
    or      a10, a10, a9
    remu    a9, a10, a8
    quou    a10, a10, a8
    extui   a11, a2, 0, 16
    slli    a9, a9, 16
    or      a11, a11, a9
    remu    a9, a11, a8
    quou    a11, a11, a8
    slli    a10, a10, 16
    or      a2, a10, a11
    addi    a9, a9, 48
    addi    a7, a7, -1
    s8i     a9, a7, 0
    or      a12, a2, a3
    bnez    a12, 1b
    movi    a3, silica_rt_report_len
    l32i    a4, a3, 0
    movi    a5, silica_rt_report_buf
    add     a5, a5, a4
2:  bgeu    a7, a6, 3f
    l8ui    a9, a7, 0
    s8i     a9, a5, 0
    addi    a5, a5, 1
    addi    a7, a7, 1
    addi    a4, a4, 1
    j       2b
3:  s32i    a4, a3, 0
    retw
    .size   silica_rt_report_udec64, . - silica_rt_report_udec64

// append a signed decimal (32-bit)
    .align  4
silica_rt_report_dec:
    entry   a1, 48
    movi    a3, silica_rt_report_len
    l32i    a4, a3, 0
    movi    a5, silica_rt_report_buf
    add     a5, a5, a4
    bgez    a2, 1f
    movi    a6, 45
    s8i     a6, a5, 0
    addi    a5, a5, 1
    addi    a4, a4, 1
    neg     a2, a2
1:  addi    a6, a1, 12                  // digits backwards into [a1, a1+12)
    mov     a7, a6
    movi    a8, 10
2:  remu    a9, a2, a8
    quou    a2, a2, a8
    addi    a9, a9, 48
    addi    a7, a7, -1
    s8i     a9, a7, 0
    bnez    a2, 2b
3:  bgeu    a7, a6, 4f
    l8ui    a9, a7, 0
    s8i     a9, a5, 0
    addi    a5, a5, 1
    addi    a7, a7, 1
    addi    a4, a4, 1
    j       3b
4:  s32i    a4, a3, 0
    retw
    .size   silica_rt_report_dec, . - silica_rt_report_dec

// append the device-actor fault lines (after reason_tag) when this actor is a device actor and a
// CPU exception was captured: exccause N (Name), epc 0x.., excvaddr 0x..
    .align  4
silica_rt_report_device_fault:
    entry   a1, 32
    l8ui    a4, a2, ACB_DEVICE
    beqz    a4, 9f
    l8ui    a5, a2, ACB_FAULT_CAUSE
    beqz    a5, 9f
    addi    a5, a5, -1
    movi    a10, silica_rt_banner_exc
    call8   silica_rt_report_puts
    mov     a10, a5
    call8   silica_rt_report_dec
    movi    a4, silica_rt_exc_names
1:  l32i    a6, a4, 0
    bltz    a6, 3f
    beq     a6, a5, 2f
    addi    a4, a4, 8
    j       1b
2:  movi    a10, silica_rt_banner_lp
    call8   silica_rt_report_puts
    l32i    a10, a4, 4
    call8   silica_rt_report_puts
    movi    a10, silica_rt_banner_rp
    call8   silica_rt_report_puts
3:  movi    a10, silica_rt_banner_epc
    call8   silica_rt_report_puts
    l32i    a10, a2, ACB_FAULT_EPC
    call8   silica_rt_report_hex
    movi    a10, silica_rt_banner_vaddr
    call8   silica_rt_report_puts
    l32i    a10, a2, ACB_FAULT_VADDR
    call8   silica_rt_report_hex
9:  retw
    .size   silica_rt_report_device_fault, . - silica_rt_report_device_fault

// The FailureReporter's report is a heap string the message owns (MSG_PAYLOAD_OWNED 2): the
// reporter's dispatch frees it once handle_report has returned, as it frees a record message copy
// (silica_rt_state_release: kept when the new state still reaches it), and also keeps it when
// handle_report sent it on to another actor -- a send, cast or call with it while it is being
// handled marks it escaped.
// silica_rt_report_begin(X0 report): handle_report is about to run on it.
    .align  4
    .global silica_rt_report_begin
    .type   silica_rt_report_begin, @function
silica_rt_report_begin:
    entry   a1, 32
    movi    a3, silica_rt_report_owner
    s32i    a2, a3, 0
    movi    a4, 0
    s32i    a4, a3, 4
    mov     a10, a2                     // then off the pending list (in that order: the exit
    call8   silica_rt_report_list_take  // drain never sees it in neither place)
    retw
    .size   silica_rt_report_begin, . - silica_rt_report_begin

// silica_rt_report_list_add(X0 report) -> X0 1 listed, 0 no memory.
    .align  4
    .global silica_rt_report_list_add
    .type   silica_rt_report_list_add, @function
silica_rt_report_list_add:
    entry   a1, 32
    movi    a10, 8
    call8   silica_rt_alloc_or_null
    beqz    a10, 3f
    movi    a4, 0
    s32i    a4, a10, 0
    s32i    a2, a10, 4
    SCHED_LOCK a8, a9
    movi    a5, silica_rt_report_list
1:  l32i    a6, a5, 0
    beqz    a6, 2f
    mov     a5, a6
    j       1b
2:  s32i    a10, a5, 0
    SCHED_UNLOCK a8, a9
    movi    a2, 1
    movi    a3, 0
    retw
3:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_report_list_add, . - silica_rt_report_list_add

// silica_rt_report_list_take(X0 report) -> X0 1 when it was listed (it is not any more), 0 when it
// was not (the exit drain printed it).
    .align  4
    .global silica_rt_report_list_take
    .type   silica_rt_report_list_take, @function
silica_rt_report_list_take:
    entry   a1, 32
    movi    a7, 0
    SCHED_LOCK a8, a9
    movi    a5, silica_rt_report_list
1:  l32i    a6, a5, 0
    beqz    a6, 3f
    l32i    a4, a6, 4
    beq     a4, a2, 2f
    mov     a5, a6
    j       1b
2:  l32i    a4, a6, 0
    s32i    a4, a5, 0
    mov     a7, a6
3:  SCHED_UNLOCK a8, a9
    movi    a2, 0
    beqz    a7, 4f
    mov     a10, a7
    call8   silica_rt_free
    movi    a2, 1
4:  movi    a3, 0
    retw
    .size   silica_rt_report_list_take, . - silica_rt_report_list_take

// silica_rt_root_report_and_note(a2 = a root supervisor's ACB): its failure report and the root
// note. With a registered FailureReporter the note goes first: the reporter prints the report on
// its own actor and may end the program (cast_exit) once it has it. Without one the report is
// written here, synchronously, and the note follows it.
    .align  4
    .global silica_rt_root_report_and_note
    .type   silica_rt_root_report_and_note, @function
silica_rt_root_report_and_note:
    entry   a1, 32
    movi    a3, silica_rt_root_failure_reporter
    l32i    a3, a3, 0
    beqz    a3, 1f
    movi    a10, silica_rt_root_exit_msg
    call8   silica_rt_puts
    mov     a10, a2
    call8   silica_rt_actor_deliver_unwind_report
    retw
1:  mov     a10, a2
    call8   silica_rt_actor_deliver_unwind_report
    movi    a10, silica_rt_root_exit_msg
    call8   silica_rt_puts
    retw
    .size   silica_rt_root_report_and_note, . - silica_rt_root_report_and_note

// silica_rt_report_drain_at_exit(): main has returned (rt_start.S, before silica_rt_exit) or
// failed (silica_rt_main_fail_exit). Each report handed to the reporter is printed once
// (§15.4.13.4): while a death's report is still being made (silica_rt_report_inflight), or one is
// pending or being handled and the reporter is alive, main yields to this core's scheduler and
// waits half a millisecond, 2000 times at most; what is still pending then goes to the console,
// oldest first. A report the reporter is handling when the wait ends is the reporter's to print.
    .align  4
    .global silica_rt_report_drain_at_exit
    .type   silica_rt_report_drain_at_exit, @function
silica_rt_report_drain_at_exit:
    entry   a1, 32
    movi    a7, 2000
1:  movi    a3, silica_rt_report_inflight
    memw
    l32i    a4, a3, 0
    bnez    a4, 5f
    movi    a3, silica_rt_report_list
    l32i    a4, a3, 0
    movi    a3, silica_rt_report_owner
    l32i    a5, a3, 0
    or      a4, a4, a5
    beqz    a4, 6f
    movi    a3, silica_rt_root_failure_reporter
    l32i    a4, a3, 0
    beqz    a4, 6f
    movi    a3, silica_rt_root_failure_reporter_id
    l32i    a10, a3, 0
    l32i    a11, a3, 4
    call8   silica_rt_ref_alive
    beqz    a10, 6f
5:  beqz    a7, 6f
    addi    a7, a7, -1
    SCHED_LOCK a8, a9
    movi    a5, silica_rt_main_acb
    movi    a6, ST_READY
    s8i     a6, a5, ACB_STATUS
    mov     a10, a5
    call8   silica_rt_rq_push
    SCHED_UNLOCK a8, a9
    call8   silica_rt_yield_to_sched
    movi    a10, 500
    call8   silica_rt_delay_us
    j       1b
6:  SCHED_LOCK a8, a9
    movi    a3, silica_rt_report_list
    l32i    a7, a3, 0
    movi    a4, 0
    s32i    a4, a3, 0
    SCHED_UNLOCK a8, a9
    call8   silica_rt_console_acquire
7:  beqz    a7, 8f
    l32i    a6, a7, 4
    l32i    a10, a6, 8
    movi    a11, 0
    l32i    a12, a6, 16
    movi    a13, 0
    call8   silica_rt_write
    l32i    a7, a7, 0
    j       7b
8:  call8   silica_rt_console_release
    retw
    .size   silica_rt_report_drain_at_exit, . - silica_rt_report_drain_at_exit

// silica_rt_main_fail_exit(a2 = the failure atom's name, a line): main's language-level failure
// (§15.4.5.5): the name on the console, then the reports still pending or being made, as the hosts'
// exit drain prints them after it, then exit status 1. Runs on main's stack where it failed (the
// drain yields main to the scheduler as at a normal return). Never returns.
    .align  4
    .global silica_rt_main_fail_exit
    .type   silica_rt_main_fail_exit, @function
silica_rt_main_fail_exit:
    entry   a1, 32
    mov     a10, a2
    call8   silica_rt_puts
    call8   silica_rt_report_drain_at_exit
    movi    a10, 1
    call8   silica_rt_exit
1:  j       1b
    .size   silica_rt_main_fail_exit, . - silica_rt_main_fail_exit

// silica_rt_report_escape_check(X0 message): a send, cast or call is about to carry X0.
    .align  4
    .global silica_rt_report_escape_check
    .type   silica_rt_report_escape_check, @function
silica_rt_report_escape_check:
    entry   a1, 32
    movi    a3, silica_rt_report_owner
    l32i    a4, a3, 0
    beqz    a4, 1f
    bne     a4, a2, 1f
    movi    a4, 1
    s32i    a4, a3, 4
1:  retw
    .size   silica_rt_report_escape_check, . - silica_rt_report_escape_check

// silica_rt_report_end(X0 report) -> X0 1 to keep it (sent on, or not the report recorded), 0 to
// release it through silica_rt_state_release.
    .align  4
    .global silica_rt_report_end
    .type   silica_rt_report_end, @function
silica_rt_report_end:
    entry   a1, 32
    movi    a3, silica_rt_report_owner
    l32i    a4, a3, 0
    movi    a5, 1
    bne     a4, a2, 1f
    movi    a4, 0
    s32i    a4, a3, 0
    l32i    a5, a3, 4
1:  mov     a2, a5
    movi    a3, 0
    retw
    .size   silica_rt_report_end, . - silica_rt_report_end

// silica_rt_actor_deliver_unwind_report(X0 dying actor) -> 0
    .align  4
    .global silica_rt_actor_deliver_unwind_report
    .type   silica_rt_actor_deliver_unwind_report, @function
silica_rt_actor_deliver_unwind_report:
    entry   a1, 32
    // the buffer is shared by both cores: composed and written (or cast) under the console lock,
    // which is re-entrant on this core for the write and never held across a switch (a cast is an
    // enqueue, not a yield)
    call8   silica_rt_console_acquire
    movi    a3, silica_rt_report_len
    movi    a4, 0
    s32i    a4, a3, 0
    movi    a10, silica_rt_banner_head
    call8   silica_rt_report_puts
    l32i    a10, a2, ACB_ID             // the actor's identity (§15.1.4, §15.4.6.4), as an integer
    l32i    a11, a2, ACB_ID + 4
    call8   silica_rt_report_udec64
    movi    a10, silica_rt_banner_agent
    call8   silica_rt_report_puts
    l16ui    a10, a2, ACB_AGENT
    call8   silica_rt_report_dec
    movi    a10, silica_rt_banner_reason
    call8   silica_rt_report_puts
    l8ui    a10, a2, ACB_REASON_TAG
    call8   silica_rt_report_dec
    mov     a10, a2
    call8   silica_rt_report_device_fault
    movi    a10, silica_rt_banner_sup
    call8   silica_rt_report_puts
    l32i    a10, a2, ACB_SUP
    call8   silica_rt_report_hex
    movi    a10, silica_rt_banner_stack
    call8   silica_rt_report_puts
    l32i    a10, a2, ACB_BEH
    call8   silica_rt_behaviour_name
    call8   silica_rt_report_puts
    movi    a10, silica_rt_banner_tail
    call8   silica_rt_report_puts
    movi    a3, silica_rt_report_len
    l32i    a4, a3, 0
    movi    a5, silica_rt_report_buf
    add     a6, a5, a4
    movi    a7, 0
    s8i     a7, a6, 0                   // NUL after the text (the buffer keeps spare bytes)
    // a registered, alive root FailureReporter (other than the dying actor) receives the text
    movi    a6, silica_rt_root_failure_reporter
    l32i    a6, a6, 0
    beqz    a6, 5f
    movi    a6, silica_rt_root_failure_reporter_id   // the dying actor is the reporter: no reporter
    l32i    a7, a6, 0
    l32i    a8, a2, ACB_ID
    bne     a7, a8, 61f
    l32i    a7, a6, 4
    l32i    a8, a2, ACB_ID + 4
    beq     a7, a8, 4f
61:
    // silica_rt_string_from_bytes(X0 bytes, X1 count) and silica_rt_actor_cast(X0 actor, X1
    // message, X2 owned) take 64-bit arguments, a register pair each, so X1 is a12:a13 in both
    // calls. With the count and then the string in a11 (X0's high word), the string was built
    // from a stale length and the reporter received a null message: no reporter could read a
    // report (actors_addition/failure_reporter_root_only hung on the board).
    mov     a10, a5
    movi    a11, 0
    mov     a12, a4
    movi    a13, 0
    call8   silica_rt_string_from_bytes
    mov     a7, a10                     // a7 = the report string
    call8   silica_rt_report_list_add   // listed until handle_report takes it (a10 = the string)
    mov     a12, a7                     // X1 = the report string
    movi    a13, 0
    movi    a14, 2                      // X2 = 2: the message owns the report (freed after
    movi    a15, 0                      // handle_report returns, see silica_rt_report_end)
    l32i    a10, a6, 0                  // X0 = the reporter's identity; cast_try: an ended reporter
    l32i    a11, a6, 4                  // is no failure of the dying actor's, the text is written
    call8   silica_rt_cast_try
    beqi    a10, 1, 9f                  // 0 ended, 2 a call-only reporter (§16.2.6.4): no enqueue,
    mov     a10, a7                     // not cast: it is written below instead (§15.4.13.4)
    call8   silica_rt_report_list_take
    mov     a10, a7
    call8   silica_rt_free
    j       5f
4:  movi    a6, silica_rt_root_failure_reporter
    movi    a7, 0
    s32i    a7, a6, 0
5:  mov     a10, a5
    mov     a12, a4
    call8   silica_rt_write
9:  call8   silica_rt_console_release
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_actor_deliver_unwind_report, . - silica_rt_actor_deliver_unwind_report

// ---------------------------------------------------------------------------------------------
// Stack high-water marks (actor_memory_budget_plan.md items E and F): the most chunk bytes an
// actor's two chains have held (ACB_HW_M, ACB_HW_A, kept by the growth entries), folded per role.

// silica_rt_actor_note_hw(acb): fold the actor's two marks into the role's maxima
// (silica_rt_actor_hw; a supervisor is an ACB with a start trampoline). The registry actors are
// left out: their behaviour is runtime code.
    .align  4
silica_rt_actor_note_hw:
    entry   a1, 32
    l32i    a3, a2, ACB_BEH
    movi    a4, silica_rt_pid_registry_beh
    beq     a3, a4, 9f
    movi    a6, silica_rt_actor_hw
    l32i    a3, a2, ACB_SB
    beqz    a3, 1f
    l32i    a3, a3, SB_TRAMP
    beqz    a3, 1f
    addi    a6, a6, 8
1:  l32i    a4, a2, ACB_HW_M
    l32i    a3, a6, 0
    bgeu    a3, a4, 2f
    s32i    a4, a6, 0
2:  l32i    a4, a2, ACB_HW_A
    l32i    a3, a6, 4
    bgeu    a3, a4, 9f
    s32i    a4, a6, 4
9:  retw
    .size   silica_rt_actor_note_hw, . - silica_rt_actor_note_hw

// silica_rt_actor_stacks_report(): at the program's end (rt_console.S silica_rt_exit), fold in every
// actor still holding chunks and print " actors <n> actor-max machine M aux A sup-max machine M aux A"
// (the most chunk bytes any actor / supervisor held, per stack; n counts the ACBs ever allocated,
// registries included).
    .align  4
    .global silica_rt_actor_stacks_report
silica_rt_actor_stacks_report:
    entry   a1, 32
    movi    a6, 0
    movi    a7, silica_rt_acb_all
    l32i    a7, a7, 0
1:  beqz    a7, 2f
    addi    a6, a6, 1
    mov     a10, a7
    call8   silica_rt_actor_note_hw
    l32i    a7, a7, ACB_ALL_NEXT
    j       1b
2:  movi    a10, silica_rt_hw_actors
    call8   silica_rt_puts
    mov     a10, a6
    call8   silica_rt_print_u32
    movi    a10, silica_rt_hw_actor_max
    call8   silica_rt_puts
    movi    a7, silica_rt_actor_hw
    l32i    a10, a7, 0
    call8   silica_rt_print_u32
    movi    a10, silica_rt_hw_aux
    call8   silica_rt_puts
    l32i    a10, a7, 4
    call8   silica_rt_print_u32
    movi    a10, silica_rt_hw_sup_max
    call8   silica_rt_puts
    l32i    a10, a7, 8
    call8   silica_rt_print_u32
    movi    a10, silica_rt_hw_aux
    call8   silica_rt_puts
    l32i    a10, a7, 12
    call8   silica_rt_print_u32
    retw
    .size   silica_rt_actor_stacks_report, . - silica_rt_actor_stacks_report



    .section .rodata.silica_rt_actor_hw, "a"
silica_rt_hw_actors:
    .asciz  " actors "
silica_rt_hw_actor_max:
    .asciz  " actor-max machine "
silica_rt_hw_sup_max:
    .asciz  " sup-max machine "
silica_rt_hw_aux:
    .asciz  " aux "
    .section .text.silica_rt_actors, "ax"

// ---------------------------------------------------------------------------------------------
// get_actor_memory_usage(X0 actor) -> { reserved, committed, retained, high_water } (40 B: shape word,
// four slots; spec §15.1.2.2). reserved: the lowered reservation, or the whole heap for the default
// (what an actor may grow into, as the machine's memory is on a host); committed: the chunk bytes
// the two chains hold now; retained: the same (release happens at the dispatch boundary, so what
// is held while idle is what the algorithm kept); high_water: the most each chain has held, summed.
    .align  4
    .global silica_rt_get_actor_memory_usage
    .type   silica_rt_get_actor_memory_usage, @function
silica_rt_get_actor_memory_usage:
    entry   a1, 32
    mov     a10, a2                     // X0 = reference (§15.1.4): its ACB, or 0
    mov     a11, a3
    call8   silica_rt_ref_acb
    mov     a2, a10
    movi    a3, 0
    mov     a6, a2
    movi    a10, 40
    call8   silica_rt_alloc
    mov     a2, a10
    movi    a3, 0
    movi    a4, SHAPE_ACTOR_MEMORY
    s32i    a4, a2, 0
    beqz    a6, 9f
    ACB_RESERVE_LD a4, a6, a5
    bnez    a4, 1f
    movi    a4, _silica_heap_end
    movi    a5, _silica_heap_start
    sub     a4, a4, a5
1:  s32i    a4, a2, 8
    l32i    a10, a6, ACB_MCHAIN
    call8   silica_rt_chain_bytes
    mov     a5, a10
    l32i    a10, a6, ACB_ACHAIN
    call8   silica_rt_chain_bytes
    add     a5, a5, a10
    s32i    a5, a2, 16
    s32i    a5, a2, 24
    l32i    a4, a6, ACB_HW_M
    l32i    a5, a6, ACB_HW_A
    add     a4, a4, a5
    s32i    a4, a2, 32
9:  retw
    .size   silica_rt_get_actor_memory_usage, . - silica_rt_get_actor_memory_usage

// ---------------------------------------------------------------------------------------------
// Supervisors: the child table runtime lives in rt_supervisors.S. Until it does, the entry points
// the emitter and this file reach are defined there or here as the reference's benign values.
