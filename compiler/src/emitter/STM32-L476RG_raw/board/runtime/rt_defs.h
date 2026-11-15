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

/* Layouts and conventions shared by every file of the bare-metal STM32L476RG runtime. The ACB,
   chunk, message and register-block layouts are the ESP32-S3 runtime's (rt_actors.S there), kept
   byte for byte so that the emitter's expectations (shared/arm_vr.silica, terms/prims/prims_actors
   .silica) hold on both boards.

   Register conventions (shared/arm_vr.silica): X0 = r0:r1, X1 = r2:r3, X2 = r4:r5, X9 = r6:r7,
   r9 = TP (the register block base, never written after boot), r8/r10/r11/r12 the emitter's
   scratch. An entry the emitted code calls (bl silica_rt_*) keeps every register except r10, r11,
   lr, and r0:r1 when it answers in X0: ENTRY_SAVE / ENTRY_RET below. Internal routines follow the
   AAPCS (arguments r0-r3, result r0/r1, r0-r3 and r12 clobbered, r4-r11 kept). */

#define VRG_BLOCK_SIZE   192
#define VRG_VSP          112
#define VRG_MLIMIT       116
#define VRG_ALIMIT       120
#define VRG_ATOP         124
#define VRG_MCHUNK       128
#define VRG_ACHUNK       132
#define VRG_ARG          136
#define VRG_FLOOR        140
#define VRG_CCB          144
#define VRG_FFI          148    /* 1 while a foreign call runs (rt_ffi.S): a fault in an actor is :foreign_fault */

/* Actor control block (rt_actors.S of the ESP32-S3 port, "Layouts"). */
#define ACB_STATE        0
#define ACB_BEH          8
#define ACB_CONV         12
#define ACB_STATUS       16     /* byte */
#define ACB_CORE         17     /* byte */
#define ACB_TARGET       18     /* byte */
#define ACB_KIND         19     /* byte: 0 actor, 1 main, 2 scheduler */
#define ACB_PRIO         20     /* byte */
#define ACB_ALIVE        21     /* byte */
#define ACB_DEVICE       22     /* byte */
#define ACB_STATE_OWNED  23     /* byte */
#define ACB_REASON_TAG   24     /* byte */
#define ACB_FAULT_CAUSE  25     /* byte */
#define ACB_REASON_ATOM  26     /* halfword */
#define ACB_AGENT        28     /* halfword */
#define ACB_REG_NAME     30     /* halfword: atom + 1, 0 none */
#define ACB_MB_HEAD      32
#define ACB_MB_TAIL      36
#define ACB_NEXT_READY   40
#define ACB_FREE_NEXT    40
#define ACB_MCHAIN       44
#define ACB_MCUR         48
#define ACB_ACHAIN       52
#define ACB_ACUR         56
#define ACB_CTX_A0       60     /* the resume address (Thumb bit set); 0: no context yet */
#define ACB_CTX_A1       64     /* the saved machine sp */
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
#define ACB_ID           128
#define ACB_SPOS         136
#define ACB_SNEXT        140
#define ACB_SDESC        144
#define ACB_SFLAGS       152
#define ACB_SRETAIN      160
#define ACB_RSLOT        168
#define ACB_SLOGN        176
#define ACB_SCHAIN       184
#define ACB_SCUR         188
#define ACB_SLOG         192
#define ACB_SBYTES       196
#define ACB_SPOLICY      200
#define ACB_CTX_FLOOR    204
#define ACB_SIZE         208

#define KIND_ACTOR       0
#define KIND_MAIN        1
#define KIND_SCHED       2

#define ST_IDLE          0
#define ST_READY         1
#define ST_RUNNING       2
#define ST_SUSPENDED     3
#define ST_DEAD          4
#define ST_WAITQ         5
#define ST_FAULTED       6
#define ST_WAIT_INGRESS  7
#define ST_BOUNDARY      8

/* Supervision block. */
#define SB_IN_HEAD       0
#define SB_IN_TAIL       4
#define SB_IN_DEPTH      8
#define SB_SPAWN_WAITER  12
#define SB_SYNC_REPORTED 16
#define SB_TRAMP         20
#define SB_TRAMP_RAN     24
#define SB_STRATEGY      28
#define SB_ALLOWED       32
#define SB_TIMEFRAME     36
#define SB_RESTARTS      40
#define SB_WINDOW        44
#define SB_CT_HEAD       48
#define SB_CT_LEN        52
#define SB_CT_USERS      56
#define SB_CT_PENDING    60
#define SB_SINK          64
#define SB_SIZE          72
#define TR_RAN           1
#define TR_SPAWNER       2
#define TR_NOTICE        4
#define TR_OWN_DONE      8
#define TR_INIT_DEAD     0x100

/* Message node (64 B). */
#define MSG_NEXT         0
#define MSG_KIND         4      /* 0 cast/send, 1 call, 2 exit notice */
#define MSG_PAYLOAD      8
#define MSG_REPLY_SET    16
#define MSG_CALLER       20
#define MSG_REPLY        24
#define MSG_INGRESS_KIND 32
#define MSG_PAYLOAD_OWNED 36
#define MSG_BUF_BLOCK    40
#define MSG_BUF_BYTES    44
#define MSG_PARK_SP      48
#define MSG_PARK_FLOOR   52
#define MSG_PARK_CHUNK   56
#define MSG_SIZE         64

/* Core block (one core): the ESP32-S3's layout. Three ready queues, index 0 high, 1 normal, 2 low
   (queue index = 2 - ACB_PRIO): heads at +0/+4/+8, tails at +12/+16/+20, lengths at +40/+44/+48;
   the weighted-fair tier being served and its remaining credit at +52/+56 (rt_actors.S, "Ready
   queues and dispatch-order policies"). */
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

/* Stack chunk header (64 B) + 64-byte band; the usable area starts at CH_USABLE_OFF. */
#define CH_NEXT          0
#define CH_PREV          4
#define CH_SIZE          8
#define CH_RET           12     /* machine: the entering frame's real return address; aux: the SP before the entering reservation */
#define CH_LIMIT         16
#define CH_TOP           20
#define CH_BAND          24
#define CH_INDEX         28
#define CH_MIRROR        32     /* aux: bytes at the top mirroring the chunk below */
#define CH_SAVED_SP      36     /* machine: the caller's sp when the frame moved here (silica_rt_chunk_return restores it) */
#define CH_HEADER        64
#define CH_USABLE_OFF    128

#define MCHUNK_FIRST     2048
#define ACHUNK_FIRST     512
#define MCHUNK_CAP       8192
#define ACHUNK_CAP       2048
#define MCHUNK_HEADROOM  1024
#define ACHUNK_HEADROOM  256
#define AUX_MIRROR_MAX   512

/* Child table row and child spec (rt_supervisors.S). */
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
#define ROW_DESC         88
#define ROW_STOPPING     92
#define ROW_SPOS         96
#define ROW_SNEXT        100
#define ROW_CID          104
#define ROW_SIZE         112

#define SPEC_SHAPE       0
#define SPEC_ID          8
#define SPEC_AGENT       16
#define SPEC_INIT        24
#define SPEC_BEH         32
#define SPEC_RESTART     40
#define SPEC_SHUTDOWN    48
#define SPEC_FLAVOR      56
#define SPEC_STATE_POLICY 64
#define SPEC_TRAMP       72
#define SPEC_DESC        80
#define SPEC_LIST_CHUNK  88

/* The fixed prefix of every program's atom table (atoms/atom_table.silica). */
#define ATOM_OK          2
#define ATOM_NORMAL      3
#define ATOM_LANGUAGE_ERROR 4
#define ATOM_MEMORY_FAULT 5
#define ATOM_EXPLICIT    6
#define ATOM_UNKNOWN     7
#define ATOM_DANGEROUS   22

/* Registry tables (rt_actors.S): one word (atom -> ACB) per atom of the image, sized at
   silica_rt_actors_init from silica_registry_slots (the build's atom count, emitted into
   __silica_runtime.sams; at least REG_SLOTS_MIN), as on the ESP32-S3. silica_pid_registry_ref,
   silica_dangerous_pid_registry_ref and silica_device_pid_registry_ref each hold the address of their
   heap table; silica_rt_reg_slots holds the slot count. */
#define REG_SLOTS_MIN    64

/* Peripherals (RM0351). */
#define RCC_BASE         0x40021000
#define RCC_CR           0x00
#define RCC_CFGR         0x08
#define RCC_AHB2ENR      0x4C
#define RCC_APB1ENR1     0x58
#define GPIOA_BASE       0x48000000
#define GPIO_MODER       0x00
#define GPIO_OTYPER      0x04
#define GPIO_OSPEEDR     0x08
#define GPIO_PUPDR       0x0C
#define GPIO_IDR         0x10
#define GPIO_ODR         0x14
#define GPIO_BSRR        0x18
#define GPIO_AFRL        0x20
#define USART2_BASE      0x40004400
#define USART_CR1        0x00
#define USART_BRR        0x0C
#define USART_ISR        0x1C
#define USART_ICR        0x20
#define USART_RDR        0x24
#define USART_TDR        0x28
#define SYSTICK_CSR      0xE000E010
#define SYSTICK_RVR      0xE000E014
#define SYSTICK_CVR      0xE000E018
#define SCB_VTOR         0xE000ED08
#define SCB_CCR          0xE000ED14
#define SCB_SHCSR        0xE000ED24
#define SCB_CFSR         0xE000ED28
#define SCB_HFSR         0xE000ED2C
#define SCB_MMFAR        0xE000ED34
#define SCB_BFAR         0xE000ED38
#define SCB_CPACR        0xE000ED88
#define FPU_FPCCR        0xE000EF34

/* Entry wrappers for the routines emitted code calls. */
.macro ENTRY_SAVE
    push    {r0-r8, r12, lr}
.endm
.macro ENTRY_RET
    pop     {r0-r8, r12, pc}
.endm
.macro ENTRY_RET_X0
    str     r0, [sp, #0]
    str     r1, [sp, #4]
    pop     {r0-r8, r12, pc}
.endm
/* A 32-bit constant or symbol address into a register. */
.macro MOV32 r, v
    movw    \r, #:lower16:\v
    movt    \r, #:upper16:\v
.endm
/* The base of a registry table (its heap block) into \r. */
.macro REG_TABLE r, sym
    movw    \r, #:lower16:\sym
    movt    \r, #:upper16:\sym
    ldr     \r, [\r]
.endm
/* Compare an atom with the registry slot count (\scratch is clobbered): bhs = outside the tables. */
.macro REG_BOUND atom, scratch
    movw    \scratch, #:lower16:silica_rt_reg_slots
    movt    \scratch, #:upper16:silica_rt_reg_slots
    ldr     \scratch, [\scratch]
    cmp     \atom, \scratch
.endm
/* A Thumb function. */
.macro FUNC name
    .align  2
    .global \name
    .thumb_func
    .type   \name, %function
\name:
.endm
.macro LFUNC name
    .align  2
    .thumb_func
    .type   \name, %function
\name:
.endm
