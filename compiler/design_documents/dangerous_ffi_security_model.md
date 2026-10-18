# Silica `dangerous_*` FFI Security Model

**Audience**: security engineers, language/runtime reviewers, C ABI reviewers, and maintainers evaluating Silica programs that cross into external native code.

**Status**: design summary based on the current FFI design documents. The normative rules live in [silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md). Implementation sequencing lived in `ffi_wrapper_implementation_plan.md`, which is no longer in the tree (current status: [silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md), top). macOS crash-handling caveats live in [macos_crash_handling_for_silica.md](macos_crash_handling_for_silica.md).

## 1. Executive Summary

Silica's `dangerous_*` FFI system is a typed, actor-mediated, wrapper-first boundary for outbound calls into C-compatible libraries. It is designed to make foreign code dependency, execution authority, data taint, ABI metadata, and actor routing visible to the compiler and to reviewers.

It is not a sandbox. A `dangerous_*` module name does not stop malicious or memory-unsafe C from corrupting process state. The system's primary controls are:

- mandatory transitive naming of modules and root artifacts that depend on FFI;
- prohibition on direct application calls into `dangerous_*` modules;
- execution of wrapper calls only inside dedicated, spawned, cast-only FFI worker actor behaviors installed through `spawn_dangerous`;
- a separate `dangerous_actor_ref` type and separate dangerous actor registry;
- explicit `external_danger` effect placement only inside FFI worker behavior;
- C-facing scratch storage for wrapper arguments and results belongs to the dangerous actor's execution context, initially including actor-stack scratch space and, for guarded FFI, a per-actor FFI arena;
- sidecar metadata and link manifests for wrapper symbol and archive accountability;
- strict structural taint for data returned from dangerous calls;
- wrapper-side ABI restrictions that avoid exposing raw pointers or opaque C objects to Silica source;
- guarded runtime support, where available, for trapping recognized native faults at prepared FFI boundaries and terminating the dangerous actor through normal actor failure paths.

The design gives security professionals clear places to audit: the `dangerous_*` module closure, sidecar metadata, wrapper source and archives under `dangerous_exposure_source/`, FFI worker actor behavior, and the cast result paths receiving external-danger-touched data.

## 2. Threat Model

### In Scope

The FFI design addresses accidental complexity and review failure around native interop:

- hidden transitive dependencies on unsafe external code;
- direct calls from ordinary application logic into foreign wrappers;
- unclear distinction between installing a worker and executing foreign code;
- raw pointer and opaque object exposure to Silica source;
- wrapper ABI drift between Silica declarations, metadata, archives, and linked symbols;
- dangerous data silently flowing through ordinary pure values or actor messages;
- accidental registration or lookup of FFI workers as ordinary actors.

### Out of Scope

The FFI design does not claim to contain a malicious or arbitrarily memory-corrupting library running in the same process. In particular, it does not reliably prevent:

- C writes to valid but wrong memory;
- allocator, global-state, scheduler, or runtime metadata corruption;
- non-faulting data corruption before a later crash;
- deadlocks, infinite loops, or unbounded blocking in foreign code;
- malicious wrapper metadata or a malicious prebuilt archive;
- callbacks from C into Silica;
- C-created threads touching Silica runtime state;
- language runtime exceptions from Objective-C, Swift, C++, or other non-Silica runtimes.

For untrusted native code, the stronger isolation choice is a helper process or brokered IPC architecture, not same-process FFI.

## 3. Meaning of `dangerous_*`

`dangerous_*` is a mandatory static classification marker for outbound native interop. It is deliberately visible in source, module dependencies, and the root compiled artifact name.

A module must use the `dangerous_` prefix if it:

- declares a raw `foreign c_wrapper` binding;
- exposes or calls a raw foreign binding;
- imports or otherwise uses any module whose name starts with `dangerous_`.

The rule is transitive. If a root application depends directly or indirectly on any `dangerous_*` module, the root module must also be named `dangerous_*`, and the compiled application name reflects that prefix.

Security consequence: reviewers can identify mixed Silica/native programs without reverse-engineering link maps or manually walking every import. This is a visibility and enforcement mechanism, not memory isolation.

## 4. Wrapper-First Boundary

Silica does not call arbitrary C APIs directly. External libraries must be adapted behind Silica-compatible C wrapper functions.

The wrapper function is the Silica-facing ABI. It may call any underlying C library function, but the exposed wrapper contract is expected to use a narrow ABI subset:

- fixed-width scalar types;
- pointer-plus-length string or byte-buffer conventions at the raw boundary;
- explicit result records for multi-field or fallible operations;
- concrete, de-opaqueified data instead of opaque C structs;
- no raw pointer, `void *`, or function pointer exposure to Silica source;
- no recursive C struct shapes sent into Silica;
- clear ownership, lifetime, allocation, and release rules.

Silica validates the Silica declaration and sidecar metadata. It does not parse C headers, verify C source, prove memory safety of wrapper code, or prove that sidecar metadata truthfully describes the archive. Wrapper review remains a human and tooling responsibility.

## 5. Sidecar Metadata and Link Accountability

FFI metadata is explicit. Sidecar `.meta` files live under `dangerous_exposure_source/` and are referenced by `wrapper_meta` declarations or per-binding `meta` clauses in Silica source. They are not discovered implicitly from headers, directories, or symbol names.

The design uses these artifacts:

- `dangerous_*` Silica modules with raw `foreign c_wrapper` declarations and adapter wrappers;
- sidecar metadata describing wrapper facts and link libraries;
- prebuilt wrapper static libraries under `dangerous_exposure_source/lib/`;
- a generated `silica.link` manifest listing required archives and symbols for the program closure;
- external linker checks that referenced wrapper symbols exist.

Security consequence: the foreign dependency surface becomes explicit and build-visible. The system can catch missing metadata, missing archives, and missing symbols. It cannot catch a malicious archive that implements the right symbol with unsafe behavior.

## 6. Install Authority vs Execute Authority

Silica separates installing an FFI worker from executing foreign code.

`spawn_dangerous(...)` installs an FFI worker actor and returns `dangerous_actor_ref`. The spawn site requires `concurrency`, but it must not declare `external_danger`. Installing the worker is not the dangerous operation.

`external_danger` authorizes execution of foreign calls only inside the behavior function of the FFI worker actor passed directly to `spawn_dangerous(...)` or `spawn_dangerous_registered(...)`.

Application actors do not call `dangerous_*` functions directly. They send request messages by `cast` to an FFI worker. The worker performs the foreign call inside an `external_danger` sequence and sends results back by designated FFI result casts.

The placement rule is intentionally strict: every outbound call to a Silica-visible C wrapper must occur inside a cast-only FFI worker behavior that was spawned as dangerous. A wrapper call is not valid in `main`, in an ordinary helper function, in an ordinary actor behavior, in a `call`-reply actor behavior, or in a sequence block that merely happens to declare `external_danger`. The function containing the `external_danger` sequence must be the behavior function supplied directly to `spawn_dangerous` or `spawn_dangerous_registered`.

This split supports audit questions such as:

- Who is allowed to create the worker?
- Which actor behavior executes native code?
- Which messages can ask the worker to execute native code?
- Which actor receives foreign results?
- Is the `external_danger` effect confined to the worker behavior?

## 7. Typed Actor Boundary

`dangerous_actor_ref` is distinct from ordinary `actor_ref`. The distinction exists in Silica typing and registry routing even if runtime handles are opaque values underneath.

The actor registry is split:

- ordinary actor table: `actor_ref`, ordinary registration and lookup;
- dangerous actor table: `dangerous_actor_ref`, dangerous registration and lookup.

An ordinary `spawn(...)` must not start behavior containing `external_danger` or direct dangerous calls. Ordinary registered lookup must not retrieve FFI workers. Dangerous registered lookup uses the dangerous registry and requires dangerous atom naming.

Security consequence: FFI workers are not accidentally passed, stored, looked up, or invoked as ordinary actors. The type system and registry APIs maintain a visible routing boundary around actors that may execute native code.

## 8. Cast-Mediated Call Flow

The intended outbound call path is:

```text
application actor
  cast request
    -> dangerous_actor_ref / dangerous registry
      FFI worker actor
        sequence proc[external_danger]
          call dangerous_* adapter
          adapter calls raw foreign c_wrapper binding
          wrapper calls external library
          result becomes external-danger-touched
          cast result to designated receiver
        produces pure
```

The `produces pure` value of the `external_danger` sequence must not contain external-danger-touched data. Foreign results leave through designated FFI result casts instead.

This model is asynchronous and actor-shaped. It is not a synchronous ordinary function call from application logic into C.

Both sides of the request path are cast-shaped. The client actor that initiates foreign work is cast-only, and the FFI worker actor that executes wrapper calls is also cast-only. Foreign results are delivered by cast to the designated receiver actor instead of by returning through an ordinary synchronous `call`.

## 9. Data Taint and Purity

Data returned from `dangerous_*` modules is external-danger-touched. Taint is structural: any record, tuple, list, sum, buffer, or nested value containing dangerous data is also dangerous.

Current design uses strict structural taint (implemented). The one validator-based de-taint path is **re-creation** (designed, not yet implemented; see §13): a compiler-derived `recreate` for types that declare `Recreatable` limits ([silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md) §7.7). User-written validators still never clear taint.

Key restrictions:

- tainted data must not appear in the `produces pure` result of an `external_danger` sequence;
- tainted regions or values must not cross ordinary actor `call` or `cast` boundaries;
- tainted data may leave the FFI worker only through designated FFI result casts;
- external-danger-touched data must not be used as if it were ordinary pure Silica data merely because it has a Silica type.

Security consequence: the compiler tracks that data came from a dangerous boundary even after it is placed inside ordinary-looking structures. This limits accidental laundering of foreign results into pure control or state paths. It does not mean the bytes are semantically trustworthy.

## 10. Strings, Buffers, and Pointer Exposure

The FFI design uses a two-layer string model:

- raw foreign bindings use pointer-plus-length arguments or result records;
- exported Silica adapter wrappers accept and return Silica `string` values.

The adapter layer performs copying and conversion so ordinary Silica source does not manipulate raw C pointers. For returned strings, wrappers must expose enough metadata for pointer-plus-length result handling and release behavior.

Raw pointers, `void *`, opaque C structs, and arbitrary C handles are not valid Silica-facing types. External objects must be de-opaqueified into concrete data before crossing into Silica.

Security consequence: ordinary Silica code does not receive ambient C pointer authority. Pointer lifetimes and ownership remain wrapper responsibilities at the boundary.

## 11. FFI Arena and Silica Memory Regions

Wrapper calls execute in the dangerous actor's execution context. Current FFI marshaling gives the foreign call C-facing scratch space associated with the FFI worker actor, such as actor-stack scratch for copied string input before passing pointer-plus-length arguments. This matters for security review because the application actor does not hand its own stack storage directly to the wrapper call path; the C-facing bytes are staged in the dangerous worker's call context.

The macOS crash-handling design also uses an FFI arena as runtime-managed scratch containment memory for guarded FFI calls: copied inputs, output buffers, temporary C-facing memory, and metadata that can be discarded or reset after a guarded fault.

An FFI arena may be backed by a Silica memory region, but it is not automatically the same thing as a user-visible Silica memory region. If an implementation chooses to back an arena with a Silica region, ordinary Silica region ownership rules still apply at the Silica boundary.

The security purpose of actor-local scratch space and the FFI arena is to reduce the amount of ordinary actor or runtime memory directly exposed to C. It does not make C memory-safe. If C corrupts shared runtime state, another actor's memory, allocator metadata, or scheduler structures, the process must abort rather than pretend the arena boundary repaired the damage.

## 12. Guarded FFI and macOS Fault Handling

The macOS guarded-FFI design uses `sigaction`, `sigaltstack`, thread-local guarded-call state, and optionally Mach exception or page-protection mechanisms to detect some synchronous native faults during prepared FFI calls. The standard signals in scope include `SIGSEGV`, `SIGBUS`, `SIGILL`, and other configured synchronous native faults where the runtime can identify that the thread was inside a guarded FFI boundary.

The intended actor-hosted failure path is:

```text
recognized fault during guarded FFI call
  -> tiny signal/Mach bridge records preallocated fault data
  -> bridge exits to a prepared runtime boundary
  -> ordinary runtime code terminates the dangerous actor as failed
  -> supervisor observes ordinary actor failure
  -> if the actor was launched under a supervisor, supervisor policy may restart it
```

Important caveats:

- the signal handler must not allocate, acquire runtime locks, send actor messages, run Silica cleanup code, or restart actors;
- same-process recovery is best effort and only valid when runtime invariants are still trustworthy;
- faults outside the active guarded FFI boundary should abort or follow normal process failure behavior;
- non-faulting corruption is not detectable by this mechanism;
- process isolation remains the stronger design for untrusted libraries.

The guarded path is a fault-conversion mechanism, not a general C containment boundary. Where this guarded path is available and enabled, the desired failure unit is the dangerous actor: the runtime traps the recognized native fault, terminates that actor after returning to safe runtime code, discards the actor's FFI scratch/arena state, and lets the ordinary supervision system apply its configured restart, shutdown, or escalation rules. If the actor was not launched under a supervisor, no supervisor restart occurs.

## 13. Current Implementation Reading

Status as of 2026-10-16, from the code and trials (the phase plan this section was written from is no longer in the tree):

- Implemented: the wrapper-first FFI path (modules, `foreign c_wrapper`, sidecar metadata, `silica.link`, marshaling), `spawn_dangerous` / `spawn_dangerous_registered` / `cast_dangerous_registered`, the dangerous registry (one of three process-global registries; the third serves device workers), and the placement, ABI and structural-taint checks. Trials: `trials/ffi_addition`, `trials/error_enforcement_addition/ffi_addition`.
- Implemented: the guarded runtime boundary (`_silica_rt_ffi_guarded_enter` / `_exit`, per-actor FFI arena, fault bridge) on Apple Silicon macOS, and the corresponding fault runtimes in the linux_aarch64 and linux_x86_64 emitters (`ffi_guarded_runtime_asm.silica`, `ffi_fault_runtime_asm.silica`). Fault and supervision behaviour is covered by `app_guarded_fault_trials` and `app_supervisor_dangerous_guarded_fault_trials`; `app_process_fatal_paths` covers faults before `main`, inside the fault handler, and with no current actor (all report `[silica] fault at` and exit 70, [runtime_failure_reporting.md](runtime_failure_reporting.md)).
- Not implemented: **re-creation** (`Recreatable` / `recreate`, FFI wrapper specification §7.7). §9 and invariant 9 describe the design; today tainted data leaves a worker only by the designated FFI result cast, and a program cannot move it into actor state.
- Open design items: exact ptr+len transfer field syntax and standard request/result cast message shapes (FFI specification §16).

Reviewers should treat completed phases as implementation status, not as a formal security certification. The stronger claim is the explicit design boundary: what the compiler is expected to reject, what the linker can prove, and what remains wrapper/runtime responsibility.

## 14. Security Invariants

The design is trying to preserve these invariants:

1. A program that depends on outbound native FFI is visibly marked by `dangerous_*` at every module layer up to the root artifact.
2. Ordinary application code cannot directly call `dangerous_*` functions.
3. Foreign execution authority is confined to cast-only FFI worker behavior installed by `spawn_dangerous`.
4. Every wrapper call executes inside the dangerous actor's `external_danger` sequence, not in ordinary application control flow.
5. Creating an FFI worker does not itself grant `external_danger` to the creator.
6. FFI worker references are typed as `dangerous_actor_ref` and use separate registry routes.
7. Raw foreign bindings are not exported as ordinary Silica APIs.
8. C-facing pointer authority is confined to wrapper/adaptor/runtime machinery and dangerous-actor scratch or arena storage, not exposed to ordinary Silica source.
9. Foreign results remain structurally tainted unless they are re-created ([silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md) §7.7). Re-created values are still barred from code loading and command execution.
10. Same-process guarded FFI may fail closed by terminating the current dangerous actor/task or process; it must not resume silently after untrusted corruption.
11. A supervised dangerous actor that dies from a recognized guarded FFI fault is restarted, stopped, or escalated according to its supervisor's normal policy.

## 15. Audit Checklist

For a `dangerous_*` dependency, review:

- the full transitive `dangerous_*` module closure;
- every `foreign c_wrapper` declaration and its Silica type;
- every `wrapper_meta` and per-binding `meta` reference;
- sidecar metadata under `dangerous_exposure_source/`;
- generated `silica.link` archives and symbols;
- wrapper source and build provenance for each prebuilt archive;
- ownership and release behavior for pointer-plus-length returns;
- bounds checks and integer overflow checks in wrapper code;
- treatment of embedded NULs, invalid UTF-8, and length mismatches;
- whether C retains pointers after wrapper return;
- whether C uses global state, callbacks, signals, threads, or thread-local state;
- FFI worker actor behavior and allowed request message shapes;
- result receiver behavior and all places where external-danger-touched data flows;
- whether the library is trusted enough for same-process FFI or should run behind brokered IPC.

Red flags:

- wrapper metadata that cannot be traced to reviewed wrapper source;
- generic `void *`-style handles represented as integers or records;
- C callbacks into Silica;
- C-created threads touching Silica runtime values;
- retained borrowed pointers into Silica memory or an FFI arena;
- result structs with ambiguous ownership or lifetime;
- ordinary actors storing foreign results as pure long-lived state without a specified taint-handling rule;
- FFI workers registered in a way that obscures who may send execution requests;
- use of same-process FFI for adversarial plugins, file parsers, codecs, or scripting engines.

## 16. Residual Risk

The design reduces accidental exposure and makes native interop reviewable. It does not eliminate native-code risk.

Residual risk remains in:

- wrapper correctness;
- sidecar truthfulness;
- prebuilt archive provenance;
- ABI mismatches not detectable from Silica declarations;
- native library memory safety;
- native library semantic correctness;
- denial of service through blocking, loops, resource exhaustion, or deadlocks;
- platform-specific signal and exception behavior;
- the gap between guarded same-process fault detection and full process isolation.

The practical security posture is therefore:

```text
trusted library, reviewed wrapper, ordinary fault tolerance needed
  -> same-process dangerous FFI may be acceptable

memory-unsafe but non-adversarial library, crash recovery desirable
  -> guarded FFI may help, with documented caveats

untrusted, adversarial, parser-heavy, plugin-style, or high-risk library
  -> use brokered IPC or a helper process, not same-process dangerous FFI
```

## 17. Related Documents

- [silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md): normative FFI rules.
- [macos_crash_handling_for_silica.md](macos_crash_handling_for_silica.md): macOS guarded FFI fault handling and caveats.
- [brokered_ipc_isolation_architecture.md](brokered_ipc_isolation_architecture.md): stronger process-isolated alternative for unsafe code.
- [silica-specification.md](silica-specification.md): core language, effects, actors, regions, and diagnostics.
