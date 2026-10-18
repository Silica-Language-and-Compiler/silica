# Embedded Actor Runtime (RTOS)

> **Implementation status (2026-10-16).** Design only. No Silica target runs on an RTOS: the targets are three OS-hosted ports (Apple Silicon macOS, Linux AArch64, Linux x86-64) and the OS-free ESP32-S3_raw port, whose runtime (`rt_actors.S`) is a cooperative per-core scheduler with its own mailboxes, not RTOS tasks. There is no actor-per-RTOS-task mapping, no RTOS mailbox primitive use and no `L_ipc` static mailbox region in the compiler or runtimes. The wire record below is illustrative.

## Purpose

This document describes an Erlang-inspired actor runtime for embedded systems running a Real-Time Operating System (RTOS).

Examples include

- FreeRTOS
- Zephyr
- ThreadX
- Azure RTOS
- CMSIS-RTOS
- RTEMS

The architecture provides asynchronous message passing between independent actors while using the RTOS for scheduling and execution.

---

# Design Goals

- No shared mutable state
- Message-oriented communication
- Deterministic execution
- Automatic supervision
- Automatic restart
- Interrupt-safe
- Static memory allocation
- Portable across RTOS implementations
- Simple implementation
- Predictable timing

---

# System Model

Each actor executes as an independent RTOS task.

Each actor owns

- private state
- mailbox
- task
- supervisor

```
Root Supervisor
│
├── Actor A
├── Actor B
├── Actor C
└── Actor D
```

Actors communicate only through messages.

Actors never directly modify another actor's state.

---

# Mailboxes

Each actor owns one mailbox.

The mailbox may be implemented using

- RTOS queues
- a custom lock-free queue
- a circular buffer

Only the owning actor removes messages.

Many actors may send messages.

---

# Message Format

```
+---------+---------+----------+----------+
| Type    | Sender  | Length   | Payload  |
+---------+---------+----------+----------+
```

Suggested wire record (an inline record type, bound to a variable)

```silica
// L_ipc: static lifetime for mailbox storage (RTOS actor region)
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

---

# Sending

```
send(destination, message)
```

Runtime steps

1. Locate destination mailbox.
2. Copy message into mailbox.
3. Wake destination task if necessary.
4. Return immediately.

The sender never waits for the receiver.

---

# Receiving

```
receive()
```

Runtime steps

1. Wait for mailbox.
2. Remove oldest message.
3. Process message.
4. Wait again.

---

# Scheduling

Scheduling is performed entirely by the RTOS.

Actors never invoke one another directly.

The runtime does not contain its own scheduler.

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

1. Terminating the task.
2. Creating a new task.
3. Initializing actor state.
4. Reattaching the mailbox.
5. Returning the actor to service.

The actor's logical identity remains unchanged.

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
Task Handle
```

Applications never use RTOS task handles directly.

---

# Interrupt Handling

Interrupt handlers perform minimal work.

```
Interrupt

↓

Create Message

↓

Send to Mailbox

↓

Return
```

Application logic always executes inside actors.

---

# Memory

Actors own

- task stack
- mailbox
- actor state

Memory should preferably be statically allocated.

Dynamic allocation is optional.

---

# Advantages

- Deterministic scheduling
- Simple actor model
- Automatic supervision
- Automatic restart
- No shared mutable state
- Excellent modularity
- Portable across RTOS implementations

---

# Future Extensions

- Priority mailboxes
- Delayed messages
- Publish/Subscribe
- Timers
- Multi-core scheduling
- Distributed messaging

---

# Summary

Each actor executes as an RTOS task.

Actors communicate only through asynchronous messages.

Every actor belongs to a supervisor.

The RTOS performs scheduling while the runtime provides Erlang-inspired messaging and supervision.