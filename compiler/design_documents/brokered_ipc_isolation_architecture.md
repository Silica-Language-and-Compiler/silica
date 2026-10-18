# Brokered IPC Isolation Architecture for Safe Use of Unsafe Libraries

> **Implementation status (2026-10-16).** Design only. Silica has no broker, no helper-process runtime and no `NetOpen`-style intrinsics; none of the compiler, the runtimes or the trials implement this architecture. The in-process mechanism is Fifi ([silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md)): networking is not part of the language and a program reaches the host's network through Fifi wrappers in dangerous actors (specification §20.4). This document is the stronger-isolation alternative that [dangerous_ffi_security_model.md](dangerous_ffi_security_model.md) §16 names for untrusted or adversarial libraries. The `NetOpen` example below is an illustration of a broker protocol, not a Silica API.

## Purpose

This document describes a system architecture intended to maximize safety when a memory-safe application must use functionality provided by an unsafe library, such as a C networking library. The primary goal is to isolate unsafe behavior from the safe application while still allowing the safe application to access the required functionality.

## Design Goals

The architecture is designed to satisfy the following requirements:

- The main application is written in a memory-safe language.
- The main application does not load C libraries or any other unsafe-language libraries.
- The unsafe library is hosted outside the main application.
- There is no direct shared memory between the safe application and the unsafe worker.
- There are no TCP/IP calls between the system components.
- All communication between the safe application and the unsafe worker passes through a broker process.
- The broker uses two separate IPC channels and copies validated data between them.
- The design should be as safe as practical, prioritizing isolation, narrow interfaces, bounded behavior, and recoverability.

## High-Level Architecture

```text
+----------------+      IPC Channel A      +----------------+      IPC Channel B      +------------------+
| Safe App       | <---------------------> | Broker Process | <---------------------> | Unsafe Worker    |
| memory-safe    |                         | validates/copy |                         | hosts C library  |
+----------------+                         +----------------+                         +------------------+
```

The system has three processes:

1. **Safe Application** A memory-safe application that contains business logic and never links to unsafe libraries.

2. **Broker Process** A narrow mediation layer that owns both IPC channels, validates all requests and responses, copies data through private broker memory, and enforces policy.

3. **Unsafe Worker** A small, tightly constrained process whose only purpose is to host the unsafe library and execute a narrow set of operations.

## Core Safety Principle

The unsafe library must never be reachable through an in-process FFI boundary from the safe application.

Instead, the architecture places the unsafe library behind a broker process with two separate IPC channels:

- **Channel A:** Safe Application ↔ Broker
- **Channel B:** Broker ↔ Unsafe Worker

The broker must never forward raw memory, raw pointers, or unvalidated protocol structures from one side to the other.

## Primary Security Properties

This architecture is intended to provide:

- **Memory isolation** between the safe application and the unsafe library
- **Fault containment** for crashes and corruption in the unsafe worker
- **Reduced attack surface** in the safe application
- **Centralized policy enforcement** in the broker
- **Recoverability** through worker restart and handle invalidation
- **Protocol mediation** so the unsafe worker is treated as untrusted input

## Security Boundaries

### Safe Application Boundary

The safe application is trusted to follow its own language and runtime safety rules, but it must not trust the worker directly. It communicates only with the broker.

### Broker Boundary

The broker is the critical trust boundary in the design. It must be kept small, memory-safe if possible, and limited to mediation and policy enforcement.

The broker is responsible for:

- receiving requests
- copying them into private broker memory
- validating them completely
- translating them to the worker protocol
- receiving worker responses
- validating them as untrusted input
- translating them back to the safe-side protocol

### Unsafe Worker Boundary

The unsafe worker must be treated as crashable and potentially hostile. It should be assumed capable of:

- crashing
- hanging
- returning malformed responses
- corrupting its own state
- writing invalid data into its shared channel with the broker

It must not be trusted with pointers into broker memory or safe application memory.

## Strong Architectural Rules

1. The safe application and the unsafe worker never share any memory object.
2. The broker owns all IPC endpoints and all cross-boundary translation.
3. The broker copies all data through broker-private memory.
4. No pointers cross any boundary.
5. No library-defined native structs cross any boundary.
6. All cross-boundary state is represented using opaque broker-issued handles.
7. Every request and response is validated at the receiving boundary.
8. All operations are bounded by explicit size limits and time limits.
9. The unsafe worker is disposable and restartable.
10. The broker invalidates handles after worker restart or protocol desynchronization.

## IPC Model

### Separate Channels

The broker must use two distinct IPC channels, not one shared region visible to all three processes.

Preferred interpretation:

- one shared memory object or queue pair for Safe App ↔ Broker
- one separate shared memory object or queue pair for Broker ↔ Unsafe Worker

Unsafe interpretation to avoid:

- one common shared memory region mapped by all three components

A common region weakens isolation because the safe and unsafe sides may still influence or observe the same bytes indirectly.

### Recommended Transport Shape

A practical non-TCP design is:

- shared memory for payload transfer
- eventfd, futex, semaphore, or pipe for notification

A Linux-friendly implementation would use:

- `memfd` or POSIX shared memory for message buffers
- `eventfd` for signaling

### Mailbox vs Ring Buffer

For maximum safety and implementation clarity, prefer **mailboxes** or fixed request/response slots before moving to more complex lock-free ring buffers.

Mailboxes are easier to reason about, easier to audit, and less likely to introduce synchronization bugs.

## Data Ownership Model

Cross-boundary communication should follow a strict ownership model.

For each channel:

- one side owns request production
- the other side owns request consumption
- one side owns response production
- the other side owns response consumption

Neither side should mutate data after handoff. The broker must copy inbound messages into broker-private memory before validation and translation.

## Protocol Design Requirements

The protocol should be explicitly specified and versioned.

### Message Format Requirements

Each message should have:

- protocol version
- operation code
- request ID
- payload length
- status or result code
- reserved fields for future compatibility

Example header:

```c
struct MsgHeader {
    uint32_t version;
    uint32_t opcode;
    uint32_t request_id;
    uint32_t payload_len;
    uint32_t status;
    uint32_t reserved;
};
```

### Protocol Constraints

- use fixed-width integer types only
- define byte order explicitly
- include explicit lengths for all variable-sized data
- apply a hard maximum message size
- apply hard maximum field counts
- use explicit framing for every message
- forbid raw pointers
- forbid native object references
- forbid function pointers
- forbid nested unbounded structures
- forbid direct transmission of C structs from the unsafe library

### Versioning

Every message must include a protocol version. The broker must reject unsupported versions.

## Broker Validation Requirements

The broker must validate all requests from the safe side and all responses from the worker side.

At minimum, validation should include:

- protocol version is supported
- opcode is allowed
- payload length is within bounds
- field offsets and lengths do not overflow
- enum values are valid
- required fields are present
- text fields are valid according to policy, such as UTF-8 if required
- handles exist, belong to the calling client, and are in the correct state
- operation is legal in the current state machine
- all returned lengths match actual payload sizes

The broker must reject any malformed or unexpected message.

## Copy, Validate, Re-Encode

The broker must implement this discipline for every message:

1. Receive message on one channel.
2. Copy message into broker-private memory.
3. Validate the message.
4. Convert it into an internal representation.
5. Re-encode it into the protocol for the other channel.
6. Copy it out to the destination channel.

The broker must never translate by aliasing, forwarding references, or reusing untrusted memory buffers directly.

## Handle-Based State

All cross-boundary state should be represented as opaque broker-issued handles.

Examples:

- `connection_handle`
- `request_handle`
- `buffer_handle`

The safe application must never see worker-native identifiers or pointers.

### Handle Safety Requirements

Handles should include or map to:

- object ID
- generation counter
- client or session ownership
- object type

Generation counters are critical so that after a worker crash or restart, old handles automatically become invalid.

## Unsafe Worker Design Rules

The unsafe worker should be as small as possible.

It should do only the following:

- receive a narrow command
- decode and validate enough to act safely within its own process
- call the unsafe library
- capture the result
- return a structured response

It should not contain:

- application business logic
- broad parsing logic if avoidable
- policy logic that belongs in the broker
- direct access to the safe-side protocol

The worker should be considered replaceable and disposable.

## Sandbox and Privilege Reduction

Because the worker hosts unsafe code, it should run with the least privileges practical.

Recommended measures:

- separate OS user or service account
- minimal filesystem access
- no unnecessary device access
- limited syscall surface
- seccomp, namespaces, pledge/unveil, or equivalent sandboxing
- resource limits for memory, CPU, files, and process creation
- restricted environment variables
- no additional IPC channels beyond the broker-owned interface

If the worker must perform networking because the library’s purpose is networking, that privilege should exist only in the worker, not in the safe application or broker unless strictly needed.

## Failure Handling Model

The system must be designed to fail safely.

### Worker Crash

If the worker crashes:

- the broker detects channel failure or timeout
- the broker restarts or replaces the worker
- the broker invalidates all worker-derived handles
- the broker returns a structured error to the safe application

### Worker Hang

If the worker hangs:

- the broker times out the operation
- the broker terminates and restarts the worker
- the broker invalidates affected handles
- the broker returns a timeout or worker-failed result

### Malformed Worker Response

If the worker returns malformed data:

- the broker rejects the response
- the broker logs a protocol violation
- the broker may terminate and replace the worker

### Out-of-Order or Unexpected Response

The broker matches responses by request ID and expected state. Unexpected responses are rejected.

### Oversized or Invalid Requests

The broker rejects oversized or malformed requests before large allocation, forwarding, or state mutation.

## Logging and Auditability

The broker should maintain security-relevant logs for:

- protocol violations
- malformed inputs
- invalid handles
- worker crashes
- worker restarts
- timeouts
- rejected operations

Logs must avoid leaking sensitive payload data unless explicitly needed for debugging and safe to retain.

## Recommended Implementation Languages

To maximize safety:

- **Safe Application:** memory-safe language such as Rust, Erlang, Go, or similar
- **Broker:** memory-safe language, preferably Rust for tight systems-level control
- **Unsafe Worker:** minimal wrapper around the unsafe library, in C or another suitable systems language

The broker should be implemented in a memory-safe language whenever possible.

## Example: Using an Unsafe C TCP/IP Library

A representative use case is isolating a C networking library.

### Safe-Side API

The safe application should see a narrow API such as:

- `NetOpen(host, port)`
- `NetSend(handle, data)`
- `NetRecv(handle, max_bytes)`
- `NetClose(handle)`

### Broker Role

The broker validates:

- host length and encoding
- port range
- payload sizes
- legal state transitions
- timeout policies
- maximum receive sizes

The broker then translates the request into a worker operation.

### Worker Role

The worker performs:

- socket open using the C library
- send operation through the C library
- receive operation through the C library
- close operation through the C library

The broker stores the mapping between a safe handle and the worker’s internal object state. The safe application never sees raw worker references.

## Minimal Flow Example

### Open Connection

1. Safe application sends `OPEN(host, port)`.
2. Broker copies request into private memory.
3. Broker validates host and port.
4. Broker sends worker request.
5. Worker opens connection through the unsafe library.
6. Worker returns success with internal object reference.
7. Broker maps internal object to a broker-issued opaque handle.
8. Broker returns the opaque handle to the safe application.

### Send Data

1. Safe application sends `SEND(handle, payload)`.
2. Broker validates handle, state, and payload size.
3. Broker forwards re-encoded request to worker.
4. Worker sends through the unsafe library.
5. Worker returns result.
6. Broker validates and translates response.
7. Broker returns structured status to safe application.

### Receive Data

1. Safe application sends `RECV(handle, max_bytes)`.
2. Broker clamps or validates the maximum size against policy.
3. Broker forwards request.
4. Worker receives through the unsafe library.
5. Worker returns a bounded payload.
6. Broker validates returned length and state.
7. Broker copies safe response back to the application.

### Close Connection

1. Safe application sends `CLOSE(handle)`.
2. Broker validates handle and state.
3. Broker forwards close request.
4. Worker closes the underlying object.
5. Broker invalidates handle mapping.
6. Broker returns completion status.

## Recommended Safety Posture

If the system must be as safe as possible, the following priorities should dominate the design:

### Highest-Priority Decisions

1. Keep the broker small and memory-safe.
2. Keep the worker tiny and disposable.
3. Use two separate IPC channels with no direct safe↔unsafe communication.
4. Copy and validate every message at both boundaries.
5. Never pass pointers, native structs, or raw object references.
6. Use strict protocol framing, length checks, and versioning.
7. Enforce timeouts, resource limits, and restart behavior.
8. Sandbox the worker aggressively.
9. Use opaque handles with generation counters.
10. Prefer simplicity and auditability over zero-copy optimization.

## Non-Goals and Limits

This architecture greatly improves safety, but it does not make unsafe code harmless.

It does not automatically protect against:

- kernel vulnerabilities
- side-channel leakage
- a fully malicious worker attacking the operating system
- broker bugs caused by weak validation logic
- misuse of privileges granted to the worker

The architecture is strongest against:

- accidental memory corruption
- crashes in the unsafe library
- unsafe behavior that would otherwise compromise an in-process caller

## Broker Authenticity Using OS-Level Identity

When cryptography is supplied by the unsafe worker, it must not be used as a trust anchor for authentication. In this case, broker authenticity must be established using operating system identity mechanisms and controlled process creation.

### Design Principle

The broker is trusted because:

- it is launched by a trusted parent or supervisor
- its executable identity is enforced by the operating system
- its IPC endpoints are protected by OS-level permissions
- its peer identity can be verified by the safe application

No trust decision depends on cryptographic output produced by the unsafe worker.

### General Requirements

- The broker must run under a controlled and expected user identity.
- IPC endpoints must be created in protected namespaces.
- The safe application must verify peer identity after connecting.
- The broker executable must be protected against replacement or tampering.
- Prefer launching the broker via a trusted supervisor or service manager.

---

## Platform-Specific Guidance

### Linux

Use the following mechanisms:

- **Unix domain sockets or shared memory in protected directories** (e.g., under `/run`, `/var/run`, or a private directory with strict permissions)
- **File permissions and ownership** to prevent unauthorized creation or connection
- **SO\_PEERCRED (getsockopt)** to obtain peer PID, UID, and GID
- **/proc inspection** (optional) to verify executable path of the peer process
- **Namespaces and seccomp** to further restrict the broker and worker

Recommended flow:

1. Broker creates IPC endpoint in a directory owned by a trusted user.
2. Permissions restrict access to the intended safe application.
3. Safe application connects to the endpoint.
4. Safe application retrieves peer credentials via `SO_PEERCRED`.
5. Safe application verifies UID/GID and optionally executable path.

### macOS

Use the following mechanisms:

- **Unix domain sockets** in protected directories (avoid world-writable paths like `/tmp` unless secured carefully)
- **Filesystem permissions and sandboxing**
- ``\*\* / \*\*`` to obtain peer UID and GID
- **Code signing and notarization** to ensure broker binary integrity
- **App Sandbox / entitlements** if applicable

Recommended flow:

1. Broker creates a Unix domain socket in a protected location.
2. Safe application connects to the socket.
3. Safe application retrieves peer credentials using `getpeereid` or equivalent.
4. Safe application verifies expected UID/GID.
5. Optionally verify broker code signature or bundle identity.

### Windows

Use the following mechanisms:

- **Named pipes with ACLs** restricting which users or SIDs can connect
- **Security descriptors** applied at creation time
- **Impersonation APIs** (e.g., `ImpersonateNamedPipeClient`) to inspect client identity
- ``\*\* / \*\*``
- **Access tokens** to verify SID and privileges
- **Code signing and Windows Defender Application Control (WDAC)** for binary integrity

Recommended flow:

1. Broker creates a named pipe with a restrictive security descriptor.
2. Safe application connects to the pipe.
3. Broker or safe application retrieves peer identity via access token inspection.
4. Safe application verifies expected SID and privileges.
5. Optionally verify broker binary signature.

---

## Limitations of OS-Level Identity

OS-level identity provides strong protection against:

- unrelated local processes
- endpoint spoofing in shared namespaces
- unauthorized users connecting to IPC endpoints

However, it does not protect against:

- processes running under the same user identity
- compromised user accounts
- malicious replacement of binaries if filesystem protections are weak
- kernel-level compromise

For higher assurance, combine OS identity with:

- strict filesystem protections
- code signing enforcement
- trusted launch mechanisms

---

## Summary

The safest practical form of this design is a **brokered isolation architecture** in which:

- the safe application never loads unsafe libraries
- the unsafe library runs only inside a separate worker process
- the broker owns two separate IPC channels
- the broker copies validated data through private memory
- the safe and unsafe components never share memory directly
- all cross-boundary state is represented using opaque handles
- the worker is tightly sandboxed, bounded, and restartable

A concise description of the design is:

> Unsafe functionality is placed behind a broker process, never behind an FFI boundary. The broker owns two separate IPC channels, validates all requests and responses, copies data through private memory, and enforces a narrow handle-based protocol between a memory-safe application and a disposable unsafe worker.

