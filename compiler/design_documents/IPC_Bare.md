# Embedded Actor Runtime (Bare Metal)

> **Implementation status (2026-10-16).** Partly realised by the ESP32-S3_raw runtime (`compiler/src/emitter/ESP32-S3_raw/board/runtime/rt_actors.S`, [ports/esp32s3_xtensa_port.md](ports/esp32s3_xtensa_port.md) §8). It matches the design in: no operating system; actors with private state and one mailbox each; a runtime scheduler dispatching one message at a time (cooperative, per core; both LX7 cores run actors); supervision with restart; registration of logical names (atom-keyed registries, [atom_actor_registry_direct_index_design.md](atom_actor_registry_direct_index_design.md)). It differs in: mailboxes are queues of allocated message nodes (48 B each, [actor_memory_budget_plan.md](actor_memory_budget_plan.md)), not fixed-slot circular rings with a compile-time payload ceiling, and the runtime allocates (memory budgets are set by [actor_memory_budget_plan.md](actor_memory_budget_plan.md)); interrupts are never enabled by the runtime (INTENABLE is 0), so the "Interrupt Handling" section has no implementation; there is no mailbox-full policy, no cross-application shared-SRAM transport and no datagram header. "Multi-core support" under Future Extensions exists (two cores). Priority mailboxes, timers and delayed messages: actor priorities and scheduler policies exist (`set_actor_priority`, `set_scheduler_policy`), see [ports/esp32s3_port_status.md](ports/esp32s3_port_status.md). The datagram sections below remain design.

## Purpose

This document describes an Erlang-inspired actor runtime for embedded systems running without an operating system.

It also defines how **independent applications on the same piece of hardware** exchange messages—including **non-ASCII text**—without an operating system or network stack. Communication stays on-device; payloads are opaque bytes with **UTF-8** as the standard encoding whenever applications send Silica `string` values or other human-readable text.

Examples include

- STM32
- RP2040
- AVR
- PIC
- MSP430
- Bare-metal ESP32

The runtime provides asynchronous message passing between actors while performing all scheduling internally. Applications on the same device never share mutable memory; they communicate only through bounded datagram-style messages.

---

# Design Goals

- No operating system
- No shared mutable state
- Message-oriented communication
- Same-device application isolation with local-only delivery
- UTF-8 text interchange (full Unicode scalar values, including non-ASCII)
- Deterministic execution
- Automatic supervision
- Automatic restart
- Interrupt-safe
- Zero dynamic allocation
- Portable across microcontrollers
- Small memory footprint

---

# System Model

Each actor is a runtime-managed execution unit.

Each actor owns

- private state
- mailbox
- supervisor

```
Runtime
│
├── Scheduler
├── Supervisor
├── Actor A
├── Actor B
├── Actor C
└── Actor D
```

Actors communicate only through messages.

Actors never directly invoke one another.

---

# Same-Device Applications

Multiple applications may run on one piece of hardware without a general-purpose operating system—for example separate firmware images, core-local runtimes, or MPU-isolated regions on a multi-core MCU.

```
Device
│
├── Application: UI
│   └── actors …
│
├── Application: Control
│   └── actors …
│
└── Application: Logger
    └── actors …
```

Each application owns private memory. The runtime (or a thin shared transport layer) delivers **datagram messages** between application mailboxes. Messages never leave the device and never traverse TCP/IP or other off-board links as part of this design.

Applications agree on logical names and message types at compile time or through a shared registry; they do not pass raw pointers across the boundary.

---

# Datagram Model

On bare metal there is no kernel socket buffer. A **datagram** is one complete, boundary-preserving message: a fixed header plus `length` payload bytes, enqueued and dequeued as a single unit.

Unlike a byte stream, the transport never splices bytes across messages. Unlike `IPC_OS.md` (Unix domain `SOCK_DGRAM`), the circular mailbox *is* the datagram queue.

Properties:

- Message boundaries are preserved end to end.
- Delivery is local to the device only.
- Payloads are opaque bytes; the transport does not interpret them.
- Capacity is bounded at compile time (see Payload Capacity).

---

# Mailboxes

Each actor owns one circular mailbox.

```
Mailbox (circular ring of fixed slots)

+--------+--------+--------+-----+
| Slot 0 | Slot 1 | Slot 2 | …   |
+--------+--------+--------+-----+
     ^                    ^
   head                 tail
 (dequeue)            (enqueue)
```

Only the owning actor removes messages.

Many actors may enqueue messages.

Each slot stores one full message record (header plus payload capacity). Head and tail indices (or equivalent) advance modulo the slot count. All mailbox storage is allocated statically with the actor.

Concurrency:

- Brief interrupt masking, or lock-free head/tail updates, protect enqueue against ISR and peer actors.
- Dequeue runs only on the owning actor under the scheduler.
- ISR producers should use a short critical section: build the record, enqueue, return.

---

# Message Format

```
+---------+---------+----------+----------+
| Type    | Sender  | Length   | Payload  |
+---------+---------+----------+----------+
```

Suggested wire record (an inline record type, bound to a variable)

```silica
// L_ipc: static lifetime for mailbox storage (bare-metal runtime region)
// MAX_PAYLOAD: compile-time byte capacity (e.g. 256)

msg: {
    type: uint16,
    sender: uint16,
    length: uint16,
    payload: buf(L_ipc, normal, uint8, MAX_PAYLOAD)
} <- {
    type: msg_type,
    sender: sender_id,
    length: byte_len,
    payload: payload_buf
}
```

Field roles:

- `type` — application or runtime message kind
- `sender` — logical sender identity (not a memory address)
- `length` — number of valid payload bytes (`0 … MAX_PAYLOAD`)
- `payload` — storage of `MAX_PAYLOAD` bytes; only the first `length` bytes are meaningful

Application-level text uses Silica `string` at the API boundary; the runtime encodes it into `payload` as UTF-8 bytes before send and decodes after receive:

```silica
log_line: Line { text: string } <- Line { text: greeting }
```

The `length` field is the **byte length** of the UTF-8 (or other opaque) bytes copied into `payload`, not a Unicode character count.

Suggested layout practice: align each slot to 4 or 8 bytes; keep the header packed (6 bytes) ahead of the payload buffer.

---

# Payload Capacity

Mailbox slots use a **fixed compile-time capacity** (`MAX_PAYLOAD`). Message sizes vary within that ceiling.

| Aspect | Rule |
| --- | --- |
| Minimum payload | `length = 0` |
| Maximum payload | `length = MAX_PAYLOAD` |
| Variable size | Any `length` in `0 … MAX_PAYLOAD` is valid |
| Oversized send | Rejected by the runtime (or split only if applications define multi-part framing) |
| Slot footprint | Every occupied slot consumes the full slot size, regardless of `length` |

Typical MCU defaults are `MAX_PAYLOAD` of 64–256 bytes, chosen for the largest common message rather than the largest conceivable one.

This is intentional for bare metal: zero heap use, deterministic RAM cost, and interrupt-safe enqueue via a single slot copy. The tradeoff is internal fragmentation (a 4-byte message still occupies one full slot).

Larger logical transfers require an **application-defined multi-part protocol** (sequence numbers, end marker, reassembly in private state), or a future extension such as DMA / shared large-buffer transport. The base runtime delivers only single-datagram messages.

---

# Text and Unicode

Silica `string` values are UTF-8 encoded (see `silica-specification.md` §4). When applications exchange human-readable text—including accented letters, CJK, emoji, and other non-ASCII characters—the **payload bytes MUST be valid UTF-8**.

Rules:

- The transport is **encoding-neutral**: it copies and delivers opaque byte sequences and preserves message boundaries. It does not inspect or normalize text.
- Each complete UTF-8 string intended for the receiver MUST fit in a single message payload, unless the applications define an explicit multi-part reassembly protocol.
- Do not rely on NUL (`0x00`) termination; use `length` (and application message types) instead.
- If a receiver decodes a text payload and finds invalid UTF-8, that is an **application-level error**; the transport has already delivered the datagram successfully.
- Binary and text payloads may coexist: distinguish them with the `type` field or application-defined message variants.

Example: sending the greeting `"café 🔥"` from one application to another copies eleven UTF-8 bytes (including multi-byte `é` and four-byte emoji) as one bounded payload; the receiver reconstructs a Silica `string` from those bytes.

---

# Sending

```
send(destination, message)
```

Runtime steps

1. Locate destination mailbox (logical name → actor → mailbox).
2. Reject if encoded payload length exceeds `MAX_PAYLOAD`.
3. If the mailbox has a free slot, copy the header and `length` payload bytes into the next slot; advance the enqueue index.
4. Mark the destination actor ready.
5. Return immediately (success, full, or oversized—never block waiting for the receiver).

The sender never waits for the receiver to process the message.

---

# Receiving

```
receive()
```

Runtime steps

1. If the mailbox is empty, return control to the scheduler (actors never block).
2. Remove the oldest message (advance the dequeue index).
3. Process the message using only the first `length` payload bytes.
4. Return to the scheduler.

If no message exists, the scheduler selects another ready actor.

---

# Mailbox Full Policy

When every slot is occupied, `send` must not grow storage. The runtime uses a compile-time policy, for example:

- **Reject** — return a full/busy result to the sender (preferred for actor-to-actor sends).
- **Drop-newest** — discard the message being sent.
- **Drop-oldest** — overwrite the oldest queued message (use only where loss is acceptable).

ISR producers should prefer **reject** or **drop-newest** so interrupt handlers stay bounded and never wait. Supervised restart clears the mailbox, so a full ring does not permanently stall an actor after recovery.

---

# Cross-Application Transport

Within one runtime image, `send` copies directly into the destination actor’s mailbox.

When independent applications on the same MCU do not share ordinary mutable heap—MPU-isolated regions, dual-core runtimes, or separately linked images—the same datagram record crosses a thin shared transport:

| Mechanism | Role |
| --- | --- |
| Shared SRAM ring | Fixed slots in a dedicated region; producer copies a datagram, consumer dequeues into a local mailbox |
| Hardware mailbox / FIFO | Small control words or slot indices (e.g. RP2040 FIFO, STM32 IPCC); payload body in the shared ring if needed |
| Doorbell IRQ | After posting a slot, raise an interrupt or event so the peer scheduler marks the receiving actor ready |

Rules for the shared path:

- Copy bytes; never pass pointers into another application’s private memory.
- Preserve the same header and `length` semantics as in-process mailboxes.
- Use generation or sequence metadata so a restarted peer does not consume stale slots.
- Keep the shared region minimal: rings and registry entries only, not application heaps.

```
Application A                    Shared transport                 Application B
─────────────                    ────────────────                 ─────────────
encode datagram  →  copy into slot / ring  →  IRQ / event  →  enqueue local mailbox
                                                              →  schedule actor
```

---

# Scheduling

Scheduling is performed by the runtime.

```
while (true)
{
    actor = next_ready_actor();

    dispatch_one_message(actor);
}
```

Each scheduling step processes one message.

Actors voluntarily return control after completing the message.

---

# Supervision

Every actor belongs to exactly one supervisor.

```
Root Supervisor
│
├── Communications
│   ├── UART
│   ├── SPI
│   └── CAN
│
├── Sensors
│   ├── GPS
│   ├── IMU
│   └── Temperature
│
└── Application
    ├── Navigation
    └── Control
```

Supervisors

- create actors
- monitor actors
- restart actors
- apply restart policies

Actors never supervise one another.

---

# Restart

Restarting an actor consists of

1. Clearing mailbox.
2. Reinitializing actor state.
3. Incrementing generation.
4. Returning actor to the scheduler.

Other actors continue executing normally.

---

# Registration

Actors communicate using logical identities.

```
navigation

control

gps

logger
```

The runtime maps

```
Logical Name
        ↓
Mailbox
        ↓
Actor Descriptor
```

Applications never use memory addresses directly.

---

# Interrupt Handling

Interrupt handlers never execute application logic.

```
Interrupt

↓

Create Message  (header + payload ≤ MAX_PAYLOAD)

↓

Queue Message   (enqueue one mailbox slot; apply full policy if needed)

↓

Return
```

The scheduler later delivers the message to the appropriate actor. The ISR path must remain bounded: one slot copy, no heap, no wait for the consumer.

---

# Memory

Each actor owns

- mailbox (fixed slot count × fixed slot size)
- private state

All memory is statically allocated.

No heap allocation is required.

Cross-application rings, if present, are also sized at compile time and live in a dedicated shared region—not in either application’s private heap.

Approximate mailbox cost per actor:

```
mailbox_bytes ≈ SLOT_COUNT × (HEADER_BYTES + MAX_PAYLOAD + ALIGNMENT_PADDING)
```

---

# Advantages

- No operating system required
- Deterministic execution
- Very small footprint
- No shared mutable state
- Local-only messaging on one device
- Variable payload sizes within a fixed compile-time ceiling
- Full Unicode text without an OS locale or socket stack
- Automatic supervision
- Automatic restart
- Excellent modularity
- Highly portable

---

# Future Extensions

- Priority mailboxes
- Timers
- Delayed messages
- Publish/Subscribe
- DMA message producers
- Multi-core support
- Optional large-payload path (shared buffer or DMA) alongside fixed slots
- Compact payload arenas to reduce internal fragmentation

---

# Summary

Each actor owns private state and one circular mailbox of fixed-size slots.

Independent applications on the same hardware communicate through bounded local datagrams—never through shared mutable heaps or off-device networking. Payload length may vary from zero up to `MAX_PAYLOAD` bytes per message; larger transfers need an explicit multi-part or future large-buffer path.

Text payloads use UTF-8 so applications can exchange non-ASCII and full Unicode strings consistently with Silica `string`.

The runtime scheduler dispatches one message at a time to ready actors.

Every actor belongs to a supervisor.

The result is an Erlang-inspired runtime that provides messaging, supervision, and fault recovery while requiring no operating system.