# Silica Actor Capabilities and Message Ordering Specification

**Status:** Draft extension. Adds mode- and protocol-typed actor references, dangerous actor capabilities, capability splitting, and formal message-order guarantees.

**Implementation status (2026-10-16).** Not implemented, and still a draft. There is no `actor_ref call with P end` type form, no protocol expressions, no capability splitting and no capability consumption tracking in the lexer, parser, type checker or effect checker, and the E3500 to E3506 diagnostics of §13 are not allocated in [error_codes.md](../error_codes.md). What exists instead is a simpler mode check on plain references: the compiler follows an `actor_ref` through variables, parameters and results, tuple and record fields, list elements, actor state and message fields, and rejects a `cast` that reaches a call-only actor (**E2237**) or a `call` that reaches a cast-only actor (**E2238**); where the mode is unknown at compile time the runtime compares the convention it recorded at spawn with the operation and fails the caller with `:language_error` (silica-specification.md §16.2.6.4). The dangerous and device families keep their own typed references (`dangerous_actor_ref`, `device_actor_ref`) with no protocol parameter. Behavior hot-swapping (§9.5) has been removed from the roadmap, so that subsection has no planned implementation.

**Related Documents**

| Document | Purpose |
|----------|---------|
| [silica-specification.md](silica-specification.md) | Core language specification |
| [silica-formal-verification-specification.md](silica-formal-verification-specification.md) | Formal verification framework |
| [silica-specification-additional.md](silica-specification-additional.md) | Compiler failure rules |
| [silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md) | FFI worker actors, `dangerous_actor_ref`, and dangerous registry rules |

**Research Basis**

This extension is informed in part by Colin S. Gordon's work on actor capabilities and message ordering, especially:

- Gordon, Colin S. *Actor Capabilities for Message Ordering*.

---

## 1. Introduction

### 1.1 Overview
This document extends Silica's actor model with **actor capabilities**: mode- and protocol-typed actor references that restrict which operation may be used (`call` or `cast`), which message shapes may be sent, and the **order** in which messages may be sent through a particular reference.

The goal is to statically prevent a class of actor bugs where messages arrive at a valid actor in an invalid lifecycle phase. Examples include sending `commit` before `begin`, `close` before `open`, or sending a one-shot control message twice.

### 1.2 Design Goals
- Preserve Silica's existing actor model while making protocol typing universal
- Reuse Silica's explicit effect system rather than introducing a wholly separate checking framework
- Support local reasoning: correctness should be checkable from the actor behavior and the capability type carried by the actor reference
- Integrate with existing FIFO mailbox semantics without changing runtime message ordering
- Lift Silica's existing call-only/cast-only behavior split into the actor reference type itself
- Apply the same capability discipline to ordinary `actor_ref` values and FFI worker `dangerous_actor_ref` values
- Fit Silica's no-generics, explicit-type, LLM-friendly design philosophy
- Keep opting out of ordering restrictions explicit rather than implicit

### 1.3 Non-Goals
This document does not:
- Introduce full multiparty session types
- Require changes to Silica's region-based memory model
- Change the runtime mailbox ordering semantics already defined by Silica
- Replace Silica's existing call/cast distinction with a new runtime messaging model
- Make FFI execution less dangerous or relax the FFI wrapper security model

---

## 2. Summary of the Extension

### 2.1 New Surface Concept
Silica actor references are uniformly capability-typed:

```silica
actor_ref call with Protocol end
actor_ref cast with Protocol end
dangerous_actor_ref cast with Protocol end
```

where `call` or `cast` is the communication mode authorized by the reference, and `Protocol` is a compile-time protocol expression describing the allowed sequence of messages sent through that reference.

Examples:

```silica
actor_ref call with :dynamic end
actor_ref cast with :open then :write repeat then :close end
actor_ref call with :begin then :commit end
actor_ref cast with :heartbeat repeat end
actor_ref cast with :request then :reply_port_handoff end
dangerous_actor_ref cast with :ffi_request repeat end
```

### 2.2 Mandatory Protocol Typing
This extension adopts a **uniform mandatory protocol model**:
- every actor reference has an explicit mode and protocol capability
- every spawned actor declares a protocol
- opting out of ordering restrictions is still explicit

The distinguished built-in protocol:

```silica
actor_ref call with :dynamic end
actor_ref cast with :dynamic end
dangerous_actor_ref cast with :dynamic end
```

means:

```text
no static ordering restriction beyond ordinary actor message typing and actor-reference mode checks
```

### 2.3 Key Semantic Idea
A value of type `actor_ref call with P end`, `actor_ref cast with P end`, or `dangerous_actor_ref cast with P end` is both:
1. a handle to an actor, and
2. a static capability that permits only the selected communication mode and message sequences described by `P`

Sending a message through such a reference **consumes** part of the protocol, except for the unrestricted built-in protocol `:dynamic`. Therefore, protocol actor references are **flow-sensitive**.

For `call()`-compatible protocol actors, the intended guarantee is actor-global: protocol conformance is checked against the order of messages actually received by the actor across all outstanding capabilities together, not merely against each individual capability in isolation.

For `cast()`-compatible protocol actors, the guarantee is weaker: the protocol constrains what may be sent through each capability, but the runtime does not defer, reorder, or phase-buffer incoming cast messages to force a global received-order protocol.

### 2.4 Separation of Unrestricted and Exhausted Protocols
This specification distinguishes two different built-in meanings:

- `:dynamic` — unrestricted protocol; ordering is not statically constrained
- `epsilon` — exhausted protocol; no further messages may be sent

These meanings must never be conflated.

---

## 3. Protocol Language

### 3.1 Protocol Expressions
The surface language introduces protocol expressions:

```ebnf
protocol_expression ::= protocol_atom
                      | protocol_expression "then" protocol_expression
                      | protocol_expression "or" protocol_expression
                      | protocol_expression "interleave" protocol_expression
                      | protocol_expression "repeat"
                      | protocol_expression "optional"
                      | "(" protocol_expression ")"

protocol_atom ::= ":" identifier
                | "message" "(" record_type ")"
                | "epsilon"
```

### 3.2 Intended Reading
- `P then Q` — first a sequence in `P`, then a sequence in `Q`
- `P or Q` — either branch is allowed
- `P repeat` — zero or more repetitions of `P`
- `P optional` — zero or one occurrence of `P`
- `P interleave Q` — all shuffles of sequences from `P` and `Q`
- `epsilon` — the empty protocol

### 3.3 Required Surface Support
The implementation must support the full user-visible protocol surface defined in this document.

`interleave` is part of the required user-visible syntax and semantics, not merely an internal typing construct.

### 3.4 Protocol Labels
A protocol step denotes a **message class**. The compiler maps each sent message to a protocol label using the **atom-commanded record message** mechanism:

```silica
{ command: :open, path: string }
{ command: :write, bytes: buf(R, normal, uint8, N) }
{ command: :close }
```

Protocol labels are always drawn from the `command: atom` field of actor messages.

### 3.5 Canonical Message Label Rule
Every protocol-governed message must map its `command: atom` field to a protocol label. A conforming implementation must use atom-commanded record messages as the sole mechanism for protocol labeling.

Exact record-shape matching through `message({ ... })` is not used for protocol label determination.

---

## 4. New Types and Type Forms

### 4.1 Actor Reference Types
Silica uses explicit capability-carrying actor reference forms:

```silica
actor_ref call with Protocol end
actor_ref cast with Protocol end
dangerous_actor_ref cast with Protocol end
```

There is no unparameterized `actor_ref` or `dangerous_actor_ref` in this extension.

The mode component is part of the type:
- `actor_ref call with P end` authorizes `call()` only.
- `actor_ref cast with P end` authorizes `cast()` only.
- `dangerous_actor_ref cast with P end` authorizes `cast()` only to an FFI worker actor installed by `spawn_dangerous(...)` or `spawn_dangerous_registered(...)`.

There is intentionally no `dangerous_actor_ref call with P end` form. FFI worker actors remain cast-only under the FFI wrapper security model.

### 4.1.1 Legacy Dynamic Reference Compatibility
During migration, existing unparameterized references may be treated as explicit dynamic capabilities:

```silica
actor_ref             == actor_ref call with :dynamic end | actor_ref cast with :dynamic end
dangerous_actor_ref   == dangerous_actor_ref cast with :dynamic end
```

The union-like legacy reading of `actor_ref` is a compatibility rule only. New code should use explicit `call` or `cast` capability types when this extension is enabled.

### 4.2 Built-In Protocol Constants
The language defines the following distinguished protocol constants:

```text
:dynamic   unrestricted protocol
epsilon    exhausted protocol
```

`actor_ref call with :dynamic end`, `actor_ref cast with :dynamic end`, and `dangerous_actor_ref cast with :dynamic end` may be used wherever the programmer wishes to opt out of static ordering restrictions while still preserving communication-mode and danger-boundary checks.

Any actor capability ending in `with epsilon end` denotes a capability that cannot be used with `call()` or `cast()`.

### 4.3 Behavior Capability Types
This document introduces an internal behavior type form used by the compiler and formal specification:

```text
behavior[RecvProtocol, Mode, State, Reply]
```

where:
- `RecvProtocol` is the protocol the actor is prepared to handle across future messages
- `Mode` is `call_only` or `cast_only`
- `State` is the actor state type
- `Reply` is the reply type for `call_only` actors, or `unit` for `cast_only`

This internal form need not appear in user syntax.

### 4.4 Self Capability Type
Inside a protocol actor, `self()` has a protocol type:

```silica
self() -> actor_ref call with SelfProtocol end
self() -> actor_ref cast with SelfProtocol end
```

The exact mode and `SelfProtocol` are derived from the current actor behavior and tracked flow-sensitively by the compiler. `self()` inside an FFI worker behavior is not a path for fabricating ordinary authority over that worker; FFI workers expose dangerous cast capabilities through `spawn_dangerous(...)` or `spawn_dangerous_registered(...)`.

## 5. Actor Declaration and Spawn

### 5.1 Protocol-Governed Spawn
The surface language uses mode- and protocol-delimited spawn forms:

```silica
spawn call with Protocol end (initial_state, behavior_fn) -> actor_ref call with Protocol end
spawn cast with Protocol end (initial_state, behavior_fn) -> actor_ref cast with Protocol end
spawn_dangerous cast with Protocol end (initial_state, behavior_fn) -> dangerous_actor_ref cast with Protocol end
spawn_dangerous_registered cast with Protocol end (initial_state, behavior_fn, name: atom) -> dangerous_actor_ref cast with Protocol end
```

Example:

```silica
file_actor: actor_ref cast with :open then (:write repeat) then :close end <-
    spawn cast with :open then (:write repeat) then :close end (initial_state, file_behavior)
```

### 5.2 Mandatory Spawn Annotation
Every spawned actor must declare a protocol explicitly:

```silica
spawn call with :dynamic end (initial_state, behavior_fn) -> actor_ref call with :dynamic end
spawn cast with :dynamic end (initial_state, behavior_fn) -> actor_ref cast with :dynamic end
spawn cast with :open then (:write repeat) then :close end (initial_state, behavior_fn)
    -> actor_ref cast with :open then (:write repeat) then :close end
spawn_dangerous cast with :ffi_request repeat end (initial_state, ffi_worker_behavior)
    -> dangerous_actor_ref cast with :ffi_request repeat end
```

### 5.3 Spawn Typing Rule
If the result type is `actor_ref M with P end` or `dangerous_actor_ref cast with P end`, then the compiler must verify that:
- the actor's behavior return convention matches the reference mode (`:reply` for `call`, `:no_reply` for `cast`)
- the actor's behavior is protocol-compatible with `P`
- the actor's mailbox handling remains safe for every sequence allowed by `P`
- the actor's future behavior transitions do not invalidate already-issued capabilities

For `dangerous_actor_ref cast with P end`, the compiler must also enforce the FFI wrapper placement rules: the behavior must be a cast-only FFI worker behavior passed directly to `spawn_dangerous(...)` or `spawn_dangerous_registered(...)`, and any `external_danger` sequence must occur directly inside that behavior.

### 5.4 Required Implementation Rule
All protocol features described in this document are part of the required implementation surface.

No staged rollout, reduced subset, or partial protocol checker is assumed by this specification.

## 6. Sending Through Protocol References

### 6.1 Actor Operations
Silica actor operations are interpreted over protocol-typed actor references:

```silica
call(actor: actor_ref call with P end, message: ActorMessage) -> Reply proc[concurrency]
cast(actor: actor_ref cast with P end, message: ActorMessage) -> unit proc[concurrency]
cast(actor: dangerous_actor_ref cast with P end, message: ActorMessage) -> unit proc[concurrency]
```

provided the sent message matches the next allowed protocol step.

`call()` is never valid for `actor_ref cast with P end` or `dangerous_actor_ref cast with P end`. `cast()` is never valid for `actor_ref call with P end`.

### 6.2 Flow-Sensitive Consumption Rule
After sending a message with protocol label `L` through `actor_ref M with P end` or `dangerous_actor_ref cast with P end`, the reference is updated to:

```text
actor_ref M with derive(P, L) end
dangerous_actor_ref cast with derive(P, L) end
```

where `derive(P, L)` is the protocol derivative: the remaining protocol after consuming one `L` step.

### 6.3 Example

```silica
sequence proc[concurrency]
    f: actor_ref cast with :open then (:write repeat) then :close end <- open_file_actor
    cast(f, { command: :open, path: "/tmp/x" } impl ActorMessage {})
    // f is now actor_ref cast with (:write repeat) then :close end

    cast(f, { command: :write, bytes: chunk } impl ActorMessage {})
    // f is still actor_ref cast with (:write repeat) then :close end

    cast(f, { command: :close } impl ActorMessage {})
    // f is now actor_ref cast with epsilon end
produces
    pure ()
end
```

### 6.4 Terminal Capability Rule
Any actor capability whose protocol is `epsilon` is a valid value but cannot be used with `call()` or `cast()`.

Any attempt to send through an actor capability whose protocol is `epsilon` is a compile-time error.

### 6.5 Unrestricted Capability Rule
For the built-in unrestricted protocol:

```text
derive(:dynamic, label) = :dynamic
```

A value whose protocol is `:dynamic` therefore keeps the same mode and danger boundary after any well-typed `call()` or `cast()`.

### 6.6 Protocols Govern Outgoing Messages Only
Protocols do not govern replies from actors. The protocol `P` in an actor capability constrains only the sequence of outgoing messages that may be sent through the reference. When a `call()` receives a reply, the reply type is determined by the actor's declared reply type, not by protocol rules.

Reply protocols are not modeled explicitly in the surface language.

## 7. Capability Splitting and Copying

### 7.1 Motivation
In Silica, some values are copyable while others are move-only (e.g., region handles cannot be copied). Protocol actor references, like region handles, can present similar constraints: unrestricted copying could duplicate permission to send one-shot messages.

### 7.2 Splitting Judgment
The compiler introduces an internal judgment:

```text
split(P) => (P1, P2)
```

which is valid only when:

```text
interleave(P1, P2) is contained in P
```

### 7.3 User-Level Rule
A value of type `actor_ref call with P end`, `actor_ref cast with P end`, or `dangerous_actor_ref cast with P end` may be:
- moved freely
- copied freely

Each copy of a reference maintains its own independent protocol state.

### 7.4 Independent Protocol State Tracking
When a reference is copied, each copy tracks its own protocol state independently. The implementation details of how independent states are reconciled at the actor's mailbox are deferred to runtime and compiler design, but the requirement is:

**Each outstanding copy of a capability-typed actor reference maintains its own flow-sensitive protocol position, independently of other copies of the same underlying actor reference.**

### 7.5 Capability Splitting
Splitting, as defined in section 7.2, remains a valid operation for cases where a protocol should be deliberately partitioned across multiple references with complementary protocol obligations.

## 8. Interaction with Existing Call-Only and Cast-Only Actors

### 8.1 Existing Distinction
Silica already distinguishes actors whose behaviors are call-only or cast-only.

### 8.2 Protocol Consistency Rule
A protocol actor must also be mode-consistent:
- `call()` may only be used with `actor_ref call with P end`
- `cast()` may only be used with `actor_ref cast with P end` or `dangerous_actor_ref cast with P end`

Mode also affects the interpretation of protocol ordering:
- for `call()` actors, protocol conformance is checked against the order of messages actually received by the actor across all outstanding capabilities together
- for `cast()` actors, protocol conformance constrains capability use statically, but does not add runtime mailbox deferral, reordering, or phase-blocking behavior

### 8.3 Internal Typing Separation
The compiler must track both:
- **mode safety**: call-only vs cast-only
- **protocol safety**: message ordering and capability consumption

These are orthogonal checks.

### 8.4 Required Design Constraint
A protocol actor declaration must choose exactly one convention:

```text
protocol call actor
protocol cast actor
```

Mixed-mode protocol actors are not permitted by this specification.

### 8.5 Dangerous Actor Capabilities and FFI Workers
FFI worker actors use the same protocol machinery, but with a narrower reference family:

```silica
dangerous_actor_ref cast with P end
```

This capability means:
- the handle refers to an FFI worker actor in the dangerous actor family
- only `cast()` may be used through the reference
- outgoing messages must follow protocol `P`
- the reference does not authorize direct foreign calls by the holder

The actual authority to execute foreign code remains confined to the FFI worker behavior installed by `spawn_dangerous(...)` or `spawn_dangerous_registered(...)`. Capability typing controls message authority to that worker; it does not move `external_danger` authority to the sender.

The ordinary/dangerous boundary remains explicit:
- `actor_ref cast with P end` is not coercible to `dangerous_actor_ref cast with P end`
- `dangerous_actor_ref cast with P end` is not coercible to `actor_ref cast with P end`
- ordinary actor registries return ordinary actor capabilities
- dangerous actor registries return dangerous cast capabilities
- dangerous registry names retain the spelling and lookup restrictions from the FFI wrapper specification

There is no `dangerous_actor_ref call with P end` because FFI workers are cast-only. Request/reply FFI workflows should be modeled by sending a cast message that contains an ordinary reply actor capability, for example:

```silica
{
    command: :add,
    lhs: int64,
    rhs: int64,
    reply_to: actor_ref cast with :ffi_result end
}
```

In that pattern, the client holds a dangerous cast capability to the FFI worker, and the FFI worker holds an ordinary cast capability back to the result sink. The result sink may then print, forward, or call another ordinary actor according to its own capability type.

---

## 9. Behavior Semantics for Protocol Actors

### 9.1 Behavior Transition Model
A protocol actor's behavior is modeled as a state machine over message commands.

Each handled message produces:
- the next actor state
- optionally a reply
- the next behavior phase

### 9.2 Surface-Level Programming Model
Silica does not need new runtime actor machinery. Protocol actors are a **static typing discipline** over the existing mailbox and behavior semantics.

Protocols constrain message sending statically through actor capabilities. They do not introduce runtime mailbox deferral, reordering, or phase-blocking semantics. Any message ordering guarantees arise from compile-time rejection of invalid sends and from proof obligations that the actor remains prepared for all sequences permitted by its outstanding capabilities.

For `call()` actors, the protocol discipline is interpreted globally over the actor's received message order across all outstanding capabilities.

For `cast()` actors, the discipline remains per-capability and static: casts are not buffered or delayed by the runtime to force a protocol phase order.

State-machine actors (core specification §15.5) can **postpone** an event. That is not protocol-driven deferral: the behavior asks for it, for one event at a time, and the runtime never postpones on its own. Protocol typing does not rely on postponement, and a postponed message has still been received for the purposes of this specification.

### 9.3 Recommended Source-Level Style
Protocol actors should be written using explicit state records whose `phase` field mirrors the protocol phase.

Example:

```silica
{ phase: :closed, handle: OptionHandle }
{ phase: :opened, handle: FileHandle }
```

The compiler should verify that message handling branches are consistent with the declared protocol.

### 9.4 Phase Consistency Rule
If a behavior issues a restricted self-capability or returns a future behavior phase, the actor must remain prepared to handle every message sequence permitted by all outstanding capabilities previously given to other actors.

### 9.5 Hot-Swapped Behavior Protocol Preservation
When an actor's behavior is hot-swapped (replaced with a new behavior function during execution), the new behavior must preserve the protocol declared at spawn time. The new behavior may not refine, widen, or otherwise alter the protocol that was promised to all outstanding capabilities.

The protocol remains invariant across behavior transitions.

---

## 10. Effects and Protocol Obligations

### 10.1 Reuse of the Existing Effect System
Silica already uses explicit effect declarations on sequence blocks. This extension reuses that design by introducing internal **protocol obligations** tracked alongside ordinary effects.

### 10.2 Internal Judgment Shape
The formal verification layer should extend typing judgments from:

```text
Γ; L; ScopDep ⊢ e : T; L'; ScopDep'
```

to:

```text
Γ; L; ScopDep; Ω ⊢ e : T; L'; ScopDep'; Ω'
```

where `Ω` is a protocol obligation environment.

### 10.3 Meaning of Ω
`Ω` records obligations induced by:
- issued self-capabilities
- protocol splits
- future messages the actor must remain prepared to receive

### 10.4 Local Soundness Goal
The system must guarantee:

> If a program type-checks, then every message sent through a well-typed actor capability is accepted by the target actor in a mailbox state consistent with the remaining protocol of that capability.

For `call()` actors, this guarantee is strengthened to the actor-global level: the actor's actual received message order across all outstanding capabilities must remain consistent with the protocol obligations justified by the type system.

For `cast()` actors, this guarantee remains static and capability-directed: the type system constrains which casts may be sent, but the runtime mailbox is not required to defer or reorder casts to satisfy protocol phases.

### 10.5 Required Obligation Tracking Strategy
Protocol obligations are a required part of the type system and formal model described by this specification.

A conforming implementation must track protocol obligations with enough precision to justify the soundness claims in this document.

## 11. Formal Verification Extension

### 11.1 New Verification Layer
The formal verification document should gain a new layer for actor protocols, above the current value calculus and region-lifetime framework.

Suggested layering:

1. Layer 1 — value calculus
2. Layer 2 — regions and lifetimes
3. Layer 3 — actor protocol capabilities

### 11.2 New Type Forms
The formal system adds:

```text
T ::= ... | ActorRef(M, P) | DangerousActorRef(P) | Beh(P, M, S, R)
```

where:
- `P` is a protocol language
- `M` is actor mode (`call_only` or `cast_only`)
- `S` is state type
- `R` is reply type

### 11.3 Protocol Language Domain
Define a protocol denotation:

```text
⟦P⟧ ⊆ Label*
```

where `Label` is the finite set of message commands used by the program.

### 11.4 Derivative Operator
Add a derivative operator:

```text
derive(P, l)
```

with the property:

```text
⟦derive(P, l)⟧ = { w | l · w ∈ ⟦P⟧ }
```

### 11.5 Capability-Send Rule
Add a send rule of the form:

```text
Γ ⊢ e_msg : MsgType(label = l)
Γ(x) = ActorRef(M, P) or Γ(x) = DangerousActorRef(P)
derive(P, l) ≠ ∅
────────────────────────────────
Γ ⊢ send(x, e_msg) : unit ⊣ Γ[x ↦ update_protocol(Γ(x), derive(P, l))]
```

### 11.6 Capability Split Rule
Add a split rule of the form:

```text
shuffle(P1, P2) ⊆ P
────────────────────────────────
Γ, x : ActorRef(M, P) ⊢ split x as x1, x2
      ⊣ Γ, x1 : ActorRef(M, P1), x2 : ActorRef(M, P2)

Γ, x : DangerousActorRef(P) ⊢ split x as x1, x2
      ⊣ Γ, x1 : DangerousActorRef(P1), x2 : DangerousActorRef(P2)
```

### 11.7 Behavior Soundness Rule
For any actor with behavior type `Beh(P, M, S, R)`, any message sequence admitted by outstanding capabilities to that actor must be accepted by the actor's future behavior evolution.

This is the central proof obligation of the extension.

---

## 12. Syntax Additions

### 12.1 Type Grammar Additions
Extend the type grammar with:

```ebnf
actor_mode ::= "call" | "cast"
type ::= ... | "actor_ref" actor_mode "with" protocol_expression "end"
             | "dangerous_actor_ref" "cast" "with" protocol_expression "end"
```

### 12.2 Spawn Grammar Additions
```ebnf
spawn_expression ::= "spawn" actor_mode "with" protocol_expression "end"
                     "(" expression "," expression ["," expression] ")"
                   | "spawn_dangerous" "cast" "with" protocol_expression "end"
                     "(" expression "," expression ["," expression] ")"
                   | "spawn_dangerous_registered" "cast" "with" protocol_expression "end"
                     "(" expression "," expression "," atom_expression ["," expression] ")"
```

### 12.3 No Change to Existing Message Syntax
The actual runtime message syntax remains record-based and still uses `ActorMessage`.

---

## 13. Static Errors

### 13.1 New Error Category
Add **Protocol Capability Errors** with code range `E35xx`.

### 13.2 Required Errors

#### E3500 — ProtocolViolation
A message label is not permitted by the current protocol state of the actor reference.

Example:
```text
cannot send message commanded :close through actor_ref cast with :open then (:write repeat) then :close end before sending :open
```

#### E3501 — ProtocolExhausted
A send or call attempts to use an actor capability whose protocol is `epsilon`.

#### E3502 — IllegalCapabilityCopy
The program duplicates a non-copyable protocol actor reference.

#### E3503 — IncompatibleProtocolSpawn
A spawned behavior is not compatible with the declared protocol.

#### E3504 — IncompatibleProtocolMode
A protocol actor is declared or used inconsistently with `call()` vs `cast()` mode.

#### E3505 — ProtocolMatchIndeterminate
The compiler cannot determine a unique protocol label for the sent message.

#### E3506 — DangerousCapabilityMode
The program attempts to declare, construct, or use `dangerous_actor_ref call with P end`. Dangerous actor capabilities are cast-only.

---

## 14. Implementation Requirements

A conforming implementation must implement this specification as a complete feature set.

Required components include:
- parsing `actor_ref call with P end`, `actor_ref cast with P end`, and `dangerous_actor_ref cast with P end`
- parsing `spawn call with P end (...)`, `spawn cast with P end (...)`, and dangerous cast spawn forms
- parsing and typing the full protocol language
- support for both atom-tag labels and `message({ ... })` protocol atoms
- protocol derivatives
- user-visible `interleave`
- flow-sensitive updates through `call()` and `cast()`
- copyability and capability splitting checks
- behavior/protocol compatibility checking
- mode consistency checking
- protocol obligation tracking in the formal and compiler-internal model

This specification does not define staged milestones, reduced compliance profiles, or phased subsets.

## 15. Design Constraints for Silica

### 15.1 No Generics
Because Silica avoids generics, protocol typing must remain explicit and concrete. This document therefore uses explicit `actor_ref call with P end`, `actor_ref cast with P end`, and `dangerous_actor_ref cast with P end` syntax rather than generic actor API abstractions.

### 15.2 Explicit Types
No inference is required for user-visible protocols.

Mandatory protocol annotations are consistent with Silica's broader design preference for explicit programmer intent.

This specification assumes full explicit support for all protocol constructs at implementation time.

### 15.3 LLM-Friendly Syntax
The protocol surface syntax is intentionally verbose and keyword-based:
- `with`
- `then`
- `or`
- `repeat`
- `optional`
- `interleave`
- `end`

This is preferred over symbolic regex-like notation for readability and machine parsing.

### 15.4 Explicit Opt-Out
Opting out of ordering restrictions remains explicit through `:dynamic` as a surface protocol literal.

This preserves uniformity in the type system while still allowing programmers to choose unrestricted actor references when protocol checking is unnecessary. `:dynamic` is not replaced with a keyword or alternate syntax; the atom literal `:dynamic` is the explicit surface expression for unrestricted protocol behavior.

## 16. Required Feature Scope

A conforming Silica implementation must support all of the following:

1. **Explicit unrestricted actors**
   - `actor_ref call with :dynamic end`
   - `actor_ref cast with :dynamic end`
   - `dangerous_actor_ref cast with :dynamic end`
   - `spawn call with :dynamic end (...)`
   - `spawn cast with :dynamic end (...)`
   - `spawn_dangerous cast with :dynamic end (...)`

2. **One-shot capabilities**
   - `:grant_once`
   - `:shutdown`

3. **Linear request protocols**
   - `:begin then :commit`
   - `:open then :close`

4. **Repeatable message windows**
   - `:open then (:write repeat) then :close`

5. **Reply-port handoff protocols**
   - a client receives a restricted actor reference permitting exactly one follow-up message

6. **User-visible interleaving protocols**
   - protocol expressions using `interleave`

7. **Exact message-shape protocols**
   - protocol atoms of the form `message({ ... })`

8. **Mode-consistent protocol actors**
   - `call()` and `cast()` compatibility enforced together with protocol checking

9. **Dangerous actor capabilities**
   - `dangerous_actor_ref cast with P end`
   - no dangerous call capability
   - no coercion between ordinary and dangerous actor capabilities

## 17. Conformance

An implementation conforms to this specification if it:
- uses explicit mode- and protocol-typed actor reference forms
- requires explicit protocol annotation at actor creation points
- correctly parses and type-checks ordinary and dangerous capability type forms and their spawn forms
- treats `:dynamic` as the unrestricted built-in protocol (as a surface literal)
- treats `epsilon` as the exhausted protocol
- enforces atom-commanded message labels as the sole protocol labeling mechanism
- rejects protocol-invalid sends
- allows references to be freely copied, with each copy tracking independent protocol state
- enforces mode consistency with existing `call()`/`cast()` rules
- rejects `dangerous_actor_ref call with P end` and rejects all ordinary/dangerous actor-reference coercions
- interprets protocol ordering for `call()` actors against actual received message order across all outstanding capabilities together
- interprets protocol ordering for `cast()` actors as a static capability discipline without runtime mailbox deferral or reordering
- ensures hot-swapped behaviors preserve the protocol declared at spawn time
- does not model or govern reply messages through the protocol system
- integrates protocol obligations into the formal verification framework

## 18. Design Decisions

The following design questions were resolved during specification development:

### 18.1 Protocol Labels
**Decision:** Protocol labels are always atom commands drawn from the `command: atom` field of actor messages. Exact record-shape matching is not used for protocol determination.

**Rationale:** Atom commands provide clear, unambiguous protocol labeling while maintaining consistency with Silica's explicit-type philosophy.

### 18.2 Reference Copyability
**Decision:** Capability-typed actor references are freely copyable. Each copy maintains its own independent protocol state.

**Rationale:** Copyability provides flexibility in reference management while allowing independent tracking of protocol consumption across multiple handles to the same actor.

### 18.3 Reply Protocols
**Decision:** Reply protocols are not modeled explicitly in the surface language. Protocols govern only outgoing messages; reply types are determined by the actor's declared reply type.

**Rationale:** Simplicity and orthogonality with existing call/cast typing. Protocol discipline applies to the sender's side only.

### 18.4 Behavior Hot-Swapping
**Decision:** Hot-swapped behaviors must preserve the protocol declared at spawn time. Behaviors may not refine, widen, or otherwise alter the protocol promised to outstanding capabilities.

**Rationale:** Protocol invariance ensures safety guarantees remain valid across behavior transitions.

### 18.5 Unrestricted Protocol Literal
**Decision:** `:dynamic` remains a surface protocol literal. No alternate keyword spelling is introduced.

**Rationale:** Consistency with Silica's explicit, literal-based design philosophy. Unrestricted protocol behavior is an explicit choice, not implicit or hidden.

### 18.6 Mode in Reference Types
**Decision:** The actor reference type includes communication mode directly: `actor_ref call ...`, `actor_ref cast ...`, and `dangerous_actor_ref cast ...`.

**Rationale:** Silica already requires every behavior to be call-only or cast-only. Placing that distinction on the reference turns the existing behavior-side rule into an explicit capability held by callers.

### 18.7 Dangerous Actor Capabilities
**Decision:** Dangerous actor references participate in protocol typing only as `dangerous_actor_ref cast with P end`.

**Rationale:** FFI worker actors are intentionally cast-mediated. A dangerous call capability would blur the FFI security model and encourage request/reply FFI flows that bypass explicit reply actors.

## 19. References

1. Gordon, Colin S. *Actor Capabilities for Message Ordering*.

## 20. Proposed Companion Changes

After this document stabilizes, the following companion updates should be drafted:

1. An amendment to **silica-specification.md** referencing this extension in the actor and concurrency sections
2. An amendment to **silica-formal-verification-specification.md** adding Layer 3 protocol rules
3. A compiler-internal design note defining the protocol AST, derivative algorithm, and copy-checking rules
