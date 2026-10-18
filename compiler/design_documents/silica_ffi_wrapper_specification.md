# Silica External Library Call Wrapper Specification

**Last updated**: May 23, 2026 (implementation status added 2026-10-16)

**Implementation status (2026-10-16).**

- *Implemented:* the `dangerous_*` module rules, `foreign c_wrapper` declarations, sidecar loading and the `silica.link` manifest (`src/ffi/`), the placement, ABI and taint checkers, `spawn_dangerous` / `spawn_dangerous_registered` / `cast_dangerous_registered`, the split dangerous registry, cast-only FFI workers, and the guarded FFI runtime (fault handlers, per-actor FFI arena, `_silica_rt_ffi_guarded_enter` / `_exit`; sources `ffi_guarded_runtime_asm.silica` and `ffi_fault_runtime_asm.silica` in the Apple Silicon, linux_aarch64 and linux_x86_64 emitters). Codes: E2103, E2110 to E2114, E4020 to E4026, E4030 to E4034, E4040 to E4049 ([error_codes.md](../error_codes.md)). Trials: `trials/ffi_addition` (app trials including guarded-fault and supervised-dangerous-fault trials), `trials/error_enforcement_addition/ffi_addition`.
- *Not implemented:* **re-creation (§7.7)**. No `Recreatable` trait, `recreate` or related diagnostics exist in the compiler, standard library or trials. Wherever this specification, `dangerous_ffi_security_model.md`, `crypto-proposal-introduction.md` and `tls_quantum_safe_future.md` rely on re-creation to clear taint, that is design, not behaviour; today FFI results leave a worker only by the designated result cast and external-danger-touched data stays tainted. Package declarations (§14.3) and building C wrapper sources are also future.
- *Differences from the text below:* the process-global registries are three, not two (the third serves device workers, [silica_device_actor_specification.md](silica_device_actor_specification.md)); each is a table sized by the build's atom count with no overflow list (see [atom_actor_registry_direct_index_design.md](atom_actor_registry_direct_index_design.md)); `get_dangerous_pid_registry()` (§4.9.2) is not a builtin; `ffi_wrapper_implementation_plan.md` is not in the tree.

## Related Documents

| Document                                      | Purpose                                                                  |
| --------------------------------------------- | ------------------------------------------------------------------------ |
| `silica-specification.md`                     | Core language syntax, effects, actors, regions, and compiler diagnostics |
| `silica-specification-additional.md`          | Additional compile-time failure rules                                    |
| `ffi_wrapper_implementation_plan.md`          | Compiler implementation phases (no longer in the tree)                   |
| `atom_actor_registry_direct_index_design.md`  | Atom-keyed direct-index registry representation (shared by both tables)   |
| `pid_registry_process_global_actor_gate.md`   | Process-global PID registry actor and actor-gated table access           |

---

## 1. Introduction

### 1.1 Overview

This specification defines the rules for outbound calls from Silica to external libraries through C-compatible wrapper functions.

This specification applies only to calls from Silica to C libraries and to other language libraries that expose a C-compatible interface. Underlying external libraries may be provided as dynamically linked shared libraries or as statically linked archive/object libraries. Calls from C or other languages into Silica are not part of the language and are not planned; there is no inbound-interop specification.

Silica does not call arbitrary external APIs directly. Every external operation callable from Silica must be exposed through a Silica-compatible C wrapper function. The wrapper function adapts the original external API into a stable, explicit ABI boundary that the Silica compiler can type-check and effect-check. In the initial implementation, the toolchain validates wrapper **archive presence** when emitting the link manifest at compile time and validates wrapper **symbol presence** at link time only; it does not parse C headers.

### 1.2 Design Principles

- **Wrapper-First External Calls**: External libraries are adapted through wrapper functions before Silica calls them.
- **Explicit Danger Boundary**: Every module that declares or exposes foreign functions, or that imports or otherwise uses any module whose name begins with `dangerous_`, must itself use the `dangerous_` module-name prefix. That naming requirement propagates along the module dependency graph to the root application module, so the compiled application name carries `dangerous_` whenever the program depends—directly or transitively—on any `dangerous_*` module. A module that never depends on a `dangerous_*` module is not required to use the prefix.
- **Cast-Mediated Foreign Calls**: Application actors never call `dangerous_*` module functions directly. Every outbound foreign operation is requested by `cast` to a dedicated **FFI worker actor**; the worker executes the C wrapper call and delivers the outcome by `cast` to a designated receiver actor.
- **Cast-Only Client Behaviors**: An actor whose behavior initiates foreign work must be a **cast-only behavior** (it handles incoming messages through `cast`, not `call`).
- **Worker-Scoped `external_danger`**: Calls to `dangerous_*` modules are required to appear only in the sequence portion of `sequence proc[external_danger] ... produces pure ... end` inside an FFI worker actor behavior. The `external_danger` effect authorizes **execution** of foreign calls inside that worker behavior; it does **not** authorize the caller to execute foreign calls.
- **Install vs Execute Separation**: FFI worker actors are installed with `spawn_dangerous(...)` and referenced by `dangerous_actor_ref`. The spawn site requires only `concurrency` (and any other non-danger effects such as `device_io`); it must **not** declare `external_danger`. Ordinary `spawn(...)` must not start a behavior that contains `external_danger` sequences or `dangerous_*` calls.
- **Typed Danger Boundary**: `dangerous_actor_ref` is distinct from `actor_ref`. A `dangerous_actor_ref` may be obtained only from `spawn_dangerous(...)` or `spawn_dangerous_registered(...)`; it cannot be coerced from `actor_ref` or obtained from `spawn_registered(...)`.
- **Split Actor Registries**: Process-global actor registration uses **two** atom-keyed slot tables—one for ordinary `actor_ref` values and one for `dangerous_actor_ref` values. Registration stores the same opaque runtime handle in either table; retrieval is typed by **which table and which lookup primitive** are used (§4.9).
- **No Retained Dangerous Data in `produces pure`**: A completed `external_danger` sequence produces only structurally pure Silica values. Foreign results leave the worker through designated FFI result casts, not through a tainted `produces pure` value.
- **Strict Structural Taint**: Values returned from `dangerous_*` modules remain external-danger-touched at every depth. User code cannot clear taint. The only way to clear it is **re-creation**: a compiler-derived `Recreatable` trait that validates a tainted value and builds a new, pure one (§7.7).
- **Strong Typing at the Boundary**: Silica foreign declarations, explicit `wrapper_meta` references, and sidecar metadata define the Silica-facing ABI; compile time verifies that named prebuilt archives exist; link time verifies that required wrapper symbols are defined in those archives.
- **Two-Layer String Declarations**: Raw foreign bindings use pointer-plus-length arguments; exported adapter wrappers accept Silica `string` and perform the copy before calling the raw binding.
- **No Raw Pointer Exposure**: Raw pointers, `void *`, and opaque C structs must not be exposed directly to Silica source types.
- **Non-Recursive Data Only**: Recursive C struct shapes must not be sent to Silica.
- **Outbound Only**: This specification does not define callbacks, trampolines, exported Silica functions, or external calls into Silica.
- **Prebuilt Wrapper Libraries (initial toolchain)**: C wrapper object code is supplied as prebuilt static libraries. After compile, `silica-compiler` writes a **`silica.link`** manifest naming required archives and foreign symbols; project Makefiles pass those archives to the external linker. The compiler does not compile C wrapper sources or invoke the linker in the initial implementation.

### 1.3 Scope

This specification defines:

1. C wrapper function requirements.
2. Silica `dangerous_*` module requirements, including naming rules that cascade along module dependencies to the root application module and compiled application name.
3. Cast-mediated foreign calls, cast-only client behaviors, and the `external_danger` effect.
4. Split ordinary and dangerous actor registries for atom-keyed registration and retrieval (§4.9).
5. Rules for strings, buffers, pointers, arrays, and de-opaqueified C structs.
6. Restrictions on dangerous data crossing actor and effect boundaries.
7. Sidecar wrapper metadata, the **`silica.link`** link manifest, compile-time archive validation, and link-time symbol validation.
8. Compile-time, parser, type-check, and link-time failures.

This specification does not define:

1. C calling into Silica.
2. Callbacks from C into Silica.
3. Function-pointer trampolines.
4. Exported Silica functions callable by external libraries.
5. Inbound runtime initialization from external languages.

---

## 2. Terminology

### 2.1 External operation

An **external operation** is any operation implemented outside Silica and callable from Silica.

### 2.2 C wrapper function

A **C wrapper function** is a C ABI function written specifically to be called by Silica. It may call one or more functions from an underlying C library or from another language library that exposes a C-compatible interface.

The C wrapper function is the Silica-facing ABI adapter. It is not required to match the original library function signature.

### 2.3 Raw foreign binding

A **raw foreign binding** is a Silica declaration that names a C wrapper symbol and gives it a Silica type.

A raw foreign binding has no Silica body.

### 2.4 Dangerous module

A **dangerous module** is a Silica module whose name begins with `dangerous_`.

Any module that declares, exposes, or calls a raw foreign binding must be a `dangerous_*` module.

Any module that imports or otherwise uses any `dangerous_*` module—whether it calls adapter wrappers, re-exports symbols, or depends on types defined there—must also be a `dangerous_*` module. That rule applies transitively: if module `B` is `dangerous_*` and module `A` uses `B`, then `A` must be `dangerous_*`; any module that uses `A` must likewise be `dangerous_*`, up to and including the root application module. The root application module therefore uses the `dangerous_` prefix in its declared module name whenever its dependency closure contains any `dangerous_*` module, and the toolchain derived compiled name for the application reflects that prefix.

No module, including the root application module, is required to include `dangerous_` in its name when no module it depends on—directly or transitively—is a `dangerous_*` module.

### 2.5 External-danger-touched data

A value is **external-danger-touched** when it is returned from a `dangerous_*` module or structurally contains a value returned from a `dangerous_*` module.

The property is structural. Records, tuples, lists, sums, buffers, and nested values containing external-danger-touched data are themselves external-danger-touched.

### 2.6 De-opaqueification

**De-opaqueification** is the process by which wrapper code translates an opaque C struct or opaque external object into explicit Silica-compatible contents.

Silica does not receive the opaque object itself. Silica receives concrete data derived from the object.

### 2.7 FFI worker actor

An **FFI worker actor** is an actor whose behavior executes outbound foreign calls. It is spawned with `spawn_dangerous(...)`, referenced by `dangerous_actor_ref`, receives foreign-call request messages by `cast`, invokes `dangerous_*` module functions inside `sequence proc[external_danger] ... produces pure ... end`, and delivers outcomes by `cast` to a designated receiver actor named in the request.

### 2.8 Cast-only behavior

A **cast-only behavior** is an actor behavior function that handles incoming actor messages exclusively through `cast`. It must not be written as a `call`-reply behavior. Application actors that initiate foreign work, and FFI worker actors that execute foreign calls, must use cast-only behaviors.

### 2.9 `dangerous_actor_ref`

A **`dangerous_actor_ref`** is a primitive reference type for FFI worker actors. It is returned only by `spawn_dangerous(...)` and `spawn_dangerous_registered(...)`. It is not interchangeable with `actor_ref`. Client and result-sink actors continue to use `actor_ref`. At runtime a `dangerous_actor_ref` is the same opaque actor handle as an `actor_ref`; the distinction exists only in Silica typing and registry routing (§4.9).

### 2.10 Sidecar metadata file

A **sidecar metadata file** is a macro-free metadata file stored under `dangerous_exposure_source/`. It declares link libraries and per-symbol wrapper facts that cannot be derived from Silica foreign declarations alone.

Sidecar files are **not** discovered automatically from header names or directory layout. A `dangerous_*` module references sidecar files explicitly through `wrapper_meta` declarations in Silica source (§3.2).

### 2.11 Link manifest (`silica.link`)

The **link manifest** is a macro-free text file, **`silica.link`**, written by `silica-compiler` in the build directory after all units in `silica.config` compile successfully. When the program uses foreign bindings, the manifest lists deduped `link_library` / `archive` pairs and required `foreign c_wrapper` symbol names for the whole program closure. Project build scripts read `archive:` lines from this file during the link stage (§14.2).

---

## 3. Program Structure and Module Rules

### 3.1 Dangerous module naming rule

**Rule (foreign declarations)**: A Silica module that declares or exposes one or more foreign functions must have a name beginning with `dangerous_`.

**Rule (dangerous dependency)**: A Silica module that imports or otherwise uses any module whose name begins with `dangerous_` must itself have a name beginning with `dangerous_`. This applies regardless of whether the importing module declares foreign functions of its own. The requirement cascades along dependencies: the root application module must use the `dangerous_` prefix whenever any module in its dependency closure is `dangerous_*`, so the compiled artifact name for the application reflects that dangerous indicator.

**Rule (optional prefix)**: No module is required to use the `dangerous_` prefix when its transitive module dependencies include no `dangerous_*` module.

Valid:

```silica
module dangerous_net;
```

Invalid:

```silica
module net;
```

Invalid:

```silica
module app;

use dangerous_net;
```

**Compiler failure**:

```text
DangerousModuleNameError:
Modules that declare or expose foreign functions must use the dangerous_ prefix.
```

**Compiler failure**:

```text
DangerousDependencyNamingError:
A module that imports or uses a dangerous_* module must use the dangerous_ prefix in its own module name.
```

### 3.2 Foreign declaration syntax

This specification adds the following declaration forms.

**Sidecar reference (module level)** — required in any module that declares one or more raw foreign bindings:

```silica
wrapper_meta "dangerous_exposure_source/db/silica_db_wrapper.meta";
```

A module may declare multiple `wrapper_meta` paths when its foreign bindings draw metadata from more than one sidecar file.

**Raw foreign binding**:

```silica
foreign c_wrapper "symbol_name"
fn local_name(arg1: Type1, arg2: Type2) -> ReturnType;
```

**Optional per-binding sidecar override** — when one foreign binding uses a different sidecar file from the module defaults:

```silica
foreign c_wrapper "symbol_name"
    meta "dangerous_exposure_source/other/extra.meta"
fn local_name(arg1: Type1, arg2: Type2) -> ReturnType;
```

Example:

```silica
module dangerous_legacy_math;

wrapper_meta "dangerous_exposure_source/legacy/silica_legacy_math_wrapper.meta";

foreign c_wrapper "silica_legacy_math_add_int64"
fn add_raw(left: int64, right: int64) -> int64;
```

**Sidecar reference rules**:

- Every module containing a `foreign c_wrapper` declaration must declare at least one `wrapper_meta` path, unless every such declaration carries its own `meta` clause.
- Each `wrapper_meta` and `meta` path must be a string literal.
- Each path must be rooted under the project `dangerous_exposure_source/` directory.
- The compiler loads **only** sidecar files referenced by `wrapper_meta` or `meta` declarations in the module being compiled. It does not infer paths from header basenames, directory walks, or symbol naming conventions.
- Each `foreign c_wrapper "symbol"` declaration must have exactly one matching `wrapper symbol { ... }` entry in a sidecar file referenced by that module.

**Compiler warning**:

When the compiler accepts a module that contains one or more `foreign c_wrapper` declarations, it emits warning `W4001` once for each raw foreign binding encountered. This warning is emitted because the module actually declares a callable FFI wrapper boundary; merely running the FFI checker or compiling modules with no `foreign c_wrapper` declarations must not emit `W4001`.

The warning is advisory only. It must never be promoted into an error, must not block compilation, and must not introduce any additional enforcement trial. Existing hard-error rules in this specification remain the only compile-time enforcement for FFI usage.

Required warning text begins:

```text
FFI_Warning at
W4001

DANGER DANGER DANGER: this module uses FFI wrapper '<local_name>' for foreign symbol '<symbol_name>'.
```

The warning message must clearly state that FFI breaks the Silica security model for the app and exposes the entire application to memory insecurity, ABI unsafety, undefined behavior, privilege-boundary collapse, and other security issues from the foreign code and wrapper boundary.

**Compiler failures**:

```text
MissingWrapperMetaError:
A module that declares foreign c_wrapper bindings must declare wrapper_meta paths or a meta path on each foreign binding.
```

```text
WrapperMetaPathError:
wrapper_meta and meta paths must be located under dangerous_exposure_source at the root of the Silica project.
```

A foreign declaration binds a C wrapper symbol to a Silica function name in the current module.

### 3.3 Export rule

**Rule**: Every exported function from a `dangerous_*` module must be a Silica adapter wrapper.

Raw foreign bindings must not be exported directly to application code.

**Adapter detection rule**: An exported function from a `dangerous_*` module is a valid Silica adapter wrapper if and only if it is an ordinary Silica function declaration with a body. A `foreign c_wrapper` declaration is never a valid export.

A Silica adapter wrapper is a Silica function with a body that calls one or more raw foreign bindings and returns a Silica-facing value that conforms to this specification. Exported adapter wrappers are callable only from FFI worker actors inside `external_danger` sequences (§4). Application actors must not call them directly; they request foreign work by `cast` to an FFI worker actor (§4.2).

Example:

```silica
module dangerous_legacy_math;

export add/2;

wrapper_meta "dangerous_exposure_source/legacy/silica_legacy_math_wrapper.meta";

foreign c_wrapper "silica_legacy_math_add_int64"
fn add_raw(left: int64, right: int64) -> int64;

fn add(left: int64, right: int64) -> int64 {
    add_raw(left, right)
}
```

The exported name `add/2` is not callable from application actor behaviors. An FFI worker actor calls it inside the sequence portion of a valid `sequence proc[external_danger] ... produces pure ... end` block.

The raw foreign binding `add_raw/2` is not exported.

---

## 4. Cast-Mediated Foreign Calls and the `external_danger` Effect

### 4.1 Effect declaration

This specification adds the following effect:

```silica
external_danger
```

### 4.2 Cast-mediated call model

**Rule**: Every outbound foreign operation uses a cast-mediated handshake. Application actors must not call `dangerous_*` module functions directly.

Required flow:

1. A **client actor** with a cast-only behavior receives work by `cast`.
2. The client actor sends a foreign-call request by `cast` to an **FFI worker actor**.
3. The FFI worker actor executes the requested operation inside `sequence proc[external_danger] ... produces pure ... end`, calling one or more `dangerous_*` module functions as needed.
4. If the operation has a result, the FFI worker actor delivers it by `cast` to the receiver actor named in the request (typically the client actor).

This cast-mediated model applies to all outbound foreign calls. From the perspective of Silica actor scheduling, every foreign call is **non-blocking**: the client actor sends a request cast and resumes; the FFI worker actor performs the call and delivers the outcome by a separate result cast (§12).

### 4.3 Cast-only client behavior rule

**Rule**: An actor whose behavior initiates foreign work must be spawned with a cast-only behavior.

Such a behavior:

- handles incoming messages exclusively through `cast`;
- must not use the `call`-reply behavior shape;
- requests foreign operations only by casting to an FFI worker actor;
- receives foreign outcomes only by handling FFI result casts.

**Parser failure**:

```text
ExternalDangerClientBehaviorError:
Actors that initiate foreign work must use cast-only behaviors.
```

### 4.4 FFI worker actor rule

**Rule**: Outbound C wrapper execution occurs only inside an FFI worker actor behavior installed by `spawn_dangerous`.

An FFI worker actor:

- is spawned with `spawn_dangerous(initial_state, behavior_fn [, core_id]) -> dangerous_actor_ref`;
- uses a cast-only behavior whose body contains one or more `sequence proc[external_danger] ... produces pure ... end` blocks;
- receives foreign-call request casts;
- executes `dangerous_*` module calls only inside those `external_danger` sequence blocks;
- delivers foreign outcomes by `cast` to the receiver named in the request;
- must not deliver external-danger-touched data through the `produces pure` clause (§7.4).

A program may use one shared FFI worker actor or multiple specialized worker actors. The worker behavior must be the function passed directly to `spawn_dangerous`.

**Install rule**: `spawn_dangerous(...)` may appear in `main`, supervisors, or any ordinary actor behavior sequence that declares `concurrency` (and other permitted non-danger effects). The spawn site must **not** declare `external_danger`. Installing a worker does not execute foreign calls; it only starts an actor whose behavior will execute them when it receives casts.

**Parser failure**:

```text
ExternalDangerInSpawnSiteError:
sequence blocks that call spawn_dangerous must not declare external_danger. The external_danger effect is valid only inside the FFI worker behavior passed to spawn_dangerous.
```

### 4.5 Required effect rule

**Rule**: A call to any function in any `dangerous_*` module must appear in the sequence portion of an enclosing `sequence proc[external_danger] ... produces pure ... end` block inside an FFI worker actor behavior.

This rule applies to:

- raw foreign bindings called by adapter wrappers inside `dangerous_*` modules;
- Silica adapter functions declared in `dangerous_*` modules;
- helper functions defined in `dangerous_*` modules;
- functions that return only pure Silica values but reside in a `dangerous_*` module.

Calls to `dangerous_*` module functions from application actor behaviors, ordinary top-level functions, or non-worker actor behaviors are invalid.

Valid (inside FFI worker behavior):

```silica
sequence proc[external_danger]
    sum: int64 <- dangerous_legacy_math@add(req.left, req.right);
    cast(req.reply_to, { tag: :foreign_ok, value: sum });
produces
    pure state
end
```

Invalid (direct call from application behavior):

```silica
sum: int64 <- dangerous_legacy_math@add(left, right);
```

**Parser failure**:

```text
DangerousModuleCallError:
Calls to dangerous_* module functions must appear in the sequence portion of sequence proc[external_danger] ... produces pure ... end inside an FFI worker actor behavior.
```

### 4.6 Worker placement rule

**Rule**: A `sequence proc[external_danger] ... produces pure ... end` block is valid only when it appears directly inside the cast-only behavior function passed to `spawn_dangerous` for an FFI worker actor.

The worker behavior may be written as a function literal at the `spawn_dangerous` call site or as a named top-level function passed directly to `spawn_dangerous`. In both cases, the function containing the `external_danger` sequence must be the FFI worker behavior function supplied to `spawn_dangerous`.

**Parser failure**:

```text
ExternalDangerPlacementError:
external_danger sequence blocks are only valid directly inside the cast-only behavior function installed by spawn_dangerous for an FFI worker actor.
```

### 4.7 Disallowed placements

The parser must reject an `external_danger` sequence block in any of the following positions:

- inside `main` or any application actor behavior;
- inside the sequence block that calls `spawn_dangerous` (the install site);
- inside an ordinary top-level function body;
- inside a helper function that is not the FFI worker behavior passed directly to `spawn_dangerous`;
- inside an application actor behavior;
- inside a function literal that is not passed directly to `spawn_dangerous` as an FFI worker behavior;
- inside a named function that is not passed directly to `spawn_dangerous` as an FFI worker behavior;
- inside a nested expression that is not the direct body of the installed FFI worker behavior function;
- inside any non-actor context.

The parser must reject a direct call to any `dangerous_*` module function outside an FFI worker actor `external_danger` sequence.

The parser must reject `spawn(initial_state, behavior_fn)` when `behavior_fn` contains an `external_danger` sequence or calls any `dangerous_*` module function.

The parser must reject `spawn_dangerous(initial_state, behavior_fn)` when `behavior_fn` does not contain a valid FFI worker `external_danger` sequence.

The parser must reject binding the result of `spawn_dangerous(...)` as `actor_ref`, or binding the result of `spawn(...)` as `dangerous_actor_ref`.

### 4.8 Interaction with other effects

An FFI worker behavior is permitted to contain a sequence block tagged only with `external_danger` when the block performs only dangerous module calls, pure computation, concurrency casts required for FFI result delivery, and no other effects.

If the worker behavior performs other effects, the sequence block is permitted to include additional effects only when those effects are valid in actor behavior functions and are not restricted by this specification.

The following effects are restricted for external-danger-touched data:

```silica
device_io
network_io
hot_swap
register_rwr
```

See §7.3.

### 4.9 Split actor registries

Silica programs that register actors by atom name use **separate process-global registries** (two for ordinary and FFI actors, and a third for device workers, which the device specification defines):

1. **Ordinary registry** — stores handles for ordinary actors (`actor_ref`), including those created by `spawn_registered(...)`.
2. **Dangerous registry** — stores handles for FFI worker actors (`dangerous_actor_ref`), including those created by `spawn_dangerous_registered(...)`.

Both registries use the same direct-index table representation described in `atom_actor_registry_direct_index_design.md` (atom id → actor identity; in the runtimes the table has one slot per atom of the build and no overflow list). Each registry has its own process-global root (for example `_silica_pid_registry_ref` for the ordinary table and `_silica_dangerous_pid_registry_ref` for the dangerous table), its own registry actor bootstrap, and its own fast-path lookup stubs. See `pid_registry_process_global_actor_gate.md` for the actor-gated access model; the dangerous registry follows the same shape.

#### 4.9.1 Compile-time facade, shared runtime word

`dangerous_actor_ref` and `actor_ref` are **distinct Silica types with no subtyping or coercion**, but at execution time both denote the same kind of opaque actor handle (typically a pointer to an actor control block). Registration inserts that word into a slot table; it does **not** attach a runtime “dangerous” tag to the handle itself.

The **typed danger boundary for registered actors is enforced at retrieval**, not by tagging handles:

- Ordinary lookup primitives resolve names only in the ordinary registry and treat results as `actor_ref`.
- Dangerous lookup primitives resolve names only in the dangerous registry and treat results as `dangerous_actor_ref`.

Using two tables ensures that `cast_registered(...)` cannot accidentally reach an FFI worker registered under the same atom spelling, even if compile-time checks are bypassed.

#### 4.9.2 Surface API

**Ordinary registry** (existing Silica actor registration; see `silica-specification.md` §15–§16):

| Operation | Arity | Returns / effect |
| --------- | ----- | ---------------- |
| `spawn_registered(initial_state, behavior_fn, name: atom [, core_id])` | 3 (+ optional 4th) | `actor_ref` |
| `cast_registered(name: atom, message)` | 2 | `boolean` |
| `call_registered(name: atom, message)` | 2 | site-specific reply |
| `get_pid_registry()` | 0 | `actor_ref` (registry actor) |

**Dangerous registry** (FFI worker registration; this specification):

| Operation | Arity | Returns / effect |
| --------- | ----- | ---------------- |
| `spawn_dangerous_registered(initial_state, behavior_fn, name: atom [, core_id])` | 3 (+ optional 4th) | `dangerous_actor_ref` |
| `cast_dangerous_registered(name: atom, message)` | 2 | `boolean` |
| `get_dangerous_pid_registry()` | 0 | `actor_ref` (dangerous registry actor; table holds `dangerous_actor_ref` targets). **Not implemented:** this builtin does not exist; the runtime reaches the table through `_silica_dangerous_pid_registry_ref` |

Rules for `spawn_dangerous_registered`:

- Same install-site rules as `spawn_dangerous` (§4.4): `concurrency` at the call site only; no `external_danger` at the install site.
- `behavior_fn` must be the FFI worker behavior passed directly to spawn (valid `external_danger` sequence inside).
- After spawn, the runtime registers the worker handle in the **dangerous** table under `name` (same insertion helper as ordinary registration, different table root).

`spawn_dangerous(...)` without a name remains valid and does not register the worker. Holding a `dangerous_actor_ref` in a variable or actor state is unchanged.

There is no `call_dangerous_registered` in this specification version: FFI workers are cast-only behaviors (§4.3).

#### 4.9.3 Atom namespace policy

Registry keys remain **`atom`** literals in a single process-wide intern table (§2 of `atom_actor_registry_direct_index_design.md`). The two slot tables are **parallel namespaces keyed by the same atom ids**:

- An atom may be registered in **at most one** of the two tables at a time. Inserting into one table must remove or reject a conflicting entry in the other.
- Keys used with the dangerous registry **must** begin with the `dangerous_` spelling prefix (for example `:dangerous_text_worker`). This is required even when the key is unique across tables, so that source code visibly marks dangerous registry use and the compiler can reject `cast_registered` / `spawn_registered` on those keys.

Ordinary registry keys must **not** use the `dangerous_` prefix.

#### 4.9.4 Prohibited registration paths

The following are hard errors (see §15.1):

- `spawn_registered(...)` when `behavior_fn` is or contains an FFI worker behavior (behavior with `external_danger` or `dangerous_*` calls); use `spawn_dangerous_registered` instead.
- `spawn_registered(...)` with a registry `name` whose spelling begins with `dangerous_`.
- `spawn_dangerous_registered(...)` with a registry `name` whose spelling does **not** begin with `dangerous_`.
- `cast_registered(...)` when `name` is registered in the dangerous table or its spelling begins with `dangerous_`.
- `cast_dangerous_registered(...)` when `name` is registered in the ordinary table or its spelling does not begin with `dangerous_`.
- Binding the result of `spawn_dangerous_registered(...)` as `actor_ref`, or the result of `spawn_registered(...)` as `dangerous_actor_ref`.

Lookup helpers such as `actor_ref_of_word` / registry `:lookup` replies that return `actor_ref` must not be used to recover a `dangerous_actor_ref` from the dangerous table; use `cast_dangerous_registered` or a future `dangerous_actor_ref_of_word` that is explicitly tied to the dangerous registry.

#### 4.9.5 Relationship to other FFI rules

Split registries do **not** replace the core FFI boundary:

- Foreign execution still occurs only inside FFI worker behaviors installed by `spawn_dangerous` / `spawn_dangerous_registered`.
- Application actors still never call `dangerous_*` module functions directly.
- `external_danger` remains valid only inside the worker behavior, not at the spawn or register site.

Registries only solve **name → ref typing** for long-lived or cross-module worker lookup. They do not grant `external_danger` to callers that cast by name.

**Parser / type-check failure (dangerous registry key)**:

```text
DangerousRegistryKeyError:
spawn_dangerous_registered: registry name must be an atom whose spelling begins with 'dangerous_'.
```

**Parser / type-check failure (ordinary registry misuse)**:

```text
DangerousRegistryMisuseError:
spawn_registered: actors whose behavior uses dangerous code must be registered with spawn_dangerous_registered and an atom whose spelling begins with 'dangerous_'.
```

---

## 5. C Wrapper Header Requirements

### 5.1 Header structure

A C wrapper header intended for Silica must be macro-free.

The header must not use Silica-specific C preprocessor macros, annotation macros, ABI-version macros, or generated binding macros.

Example macro-free header shape:

```c
#include <stdint.h>
#include <stddef.h>

int64_t silica_legacy_math_add_int64(int64_t left, int64_t right);
```

If a project uses ordinary C include guards or `#pragma once`, those mechanisms must not encode Silica ABI metadata and must not be required by the Silica binding generator. All Silica-specific metadata must be supplied outside the C preprocessor macro system as described in §13.

### 5.2 Symbol naming

Wrapper function symbols must use the following naming convention:

```text
silica_<module>_<function>
```

Examples:

```c
int64_t silica_legacy_math_add_int64(int64_t left, int64_t right);
silica_i64_result silica_net_parse_port(const uint8_t *text_ptr, uint64_t text_len);
```

The Silica compiler or binding generator is permitted to use this convention to infer default module and function names. Explicit binding declarations are permitted to override the local Silica name.

### 5.3 C linkage

Wrapper functions must use C linkage.

When compiled as C++, declarations must be enclosed in:

```c
#ifdef __cplusplus
extern "C" {
#endif

/* declarations */

#ifdef __cplusplus
}
#endif
```

### 5.4 Supported scalar ABI types

Silica-facing wrapper declarations must use fixed-width integer types from `<stdint.h>`.

Allowed integer types:

```c
int8_t
int16_t
int32_t
int64_t
uint8_t
uint16_t
uint32_t
uint64_t
```

Allowed floating-point types:

```c
float
double
```

`float` maps to `float32`.

`double` maps to `float64`.

### 5.5 Disallowed C ABI types

The following C types must not appear in Silica-facing wrapper declarations:

```c
char
short
int
long
long long
size_t
ptrdiff_t
_Bool
bool
void *
```

These types are permitted inside the wrapper implementation when calling the underlying external library.

Because Silica is strongly typed, wrapper code must translate any `void *` value from the underlying C-compatible library into one of the concrete Silica-facing representations allowed by this specification before the value reaches a Silica foreign binding.

### 5.6 Boolean representation

Silica `boolean` values must be represented at the wrapper ABI boundary as `uint8_t`.

Required encoding:

```text
0 = false
1 = true
```

A wrapper receiving a boolean argument is required to reject values other than `0` or `1` when the function is reachable from unchecked or external code.

---

## 6. Boundary Data Rules

### 6.1 Strings sent from Silica to a wrapper

Silica strings passed to C wrapper functions are never passed as references to the original Silica string storage.

This specification uses a **two-layer declaration model**:

1. **Raw foreign binding**: declares the C ABI shape using pointer-plus-length arguments.
2. **Exported adapter wrapper**: accepts a Silica `string`, copies it to actor-stack scratch memory, and calls the raw foreign binding.

Raw foreign binding example (the enclosing module must also declare `wrapper_meta`; see §3.2):

```silica
wrapper_meta "dangerous_exposure_source/net/silica_net_wrapper.meta";

foreign c_wrapper "silica_net_parse_port"
fn parse_port_raw(text_ptr: uint8, text_len: uint64) -> { tag: int64, value: int64, error_code: int64 };
```

Adapter wrapper example:

```silica
export parse_port/1;

fn parse_port(text: string) -> { tag: int64, value: int64, error_code: int64 } {
    parse_port_raw(text)
}
```

The compiler lowers a Silica `string` argument at a raw foreign binding call site into an actor-stack copy exposed to C as:

```c
const uint8_t *text_ptr,
uint64_t text_len
```

When the call site is an adapter wrapper with a `string` parameter, the adapter body calls the raw binding; the compiler performs the same copy lowering for that call.

**The `_ptr` / `_len` declaration form.** In a raw foreign binding, a parameter pair written `name_ptr: uint8,
name_len: uint64` is a pointer-plus-length declaration form, not two scalars.
- The compiler lowers the pair to `const uint8_t *name_ptr, uint64_t name_len`.
- At the call site, the pair is supplied by one Silica argument: a `string`, or a byte buffer `buf(L, Space, uint8, N)` (§6.2).
- A plain `uint8` value is never accepted there. The pointer is therefore never exposed as an ordinary scalar (§6.3).

The copied memory resides in the expandable stack of the encompassing Silica actor (the FFI worker actor executing the foreign call). It is not allocated in the general heap.

The original Silica string is not modifiable from C. The C wrapper must treat `text_ptr` as read-only memory.

The wrapper must not assume the input is NUL-terminated.

The wrapper must not retain `text_ptr` after returning. The copied string memory is recovered when the foreign function call ends.

If the external library needs to retain the string data after the wrapper returns, the wrapper must copy the data into library-owned or wrapper-owned memory before returning.

### 6.2 Buffers

Mutable buffers must be represented explicitly as pointer-plus-length pairs.

Silica buffers use the canonical form `buf(L, Space, T, N)`: region lifetime `L`, memory space `Space`, element
type `T`, and length `N`. A buffer crosses the boundary as a typed pointer plus a `uint64_t` element count.
**`buf(L, Space, uint8, N)` is the byte-payload form**: raw bytes cross as `uint8_t *` plus a `uint64_t` byte
length. This is the form for binary data such as network payloads, digests and encoded records, and binary data
does not have to be carried as `string`.

A wrapper that writes into a buffer must document:

- whether the pointer may be null;
- the maximum number of bytes written;
- whether the output is initialized on failure;
- whether the buffer is retained after return.

### 6.3 C pointer arguments

C pointer arguments in wrapper declarations must be concrete and typed.

A C pointer argument must not be exposed to Silica as:

- an untyped pointer;
- an integer address;
- a `void *`;
- an ordinary scalar value.

The wrapper signature and Silica foreign declaration must agree on the concrete data shape being passed.

The pointer-plus-length declaration form in §6.1 and the buffer form in §6.2 are the permitted ways to pass a
pointer. Neither exposes the pointer to Silica as a value.

### 6.4 C pointer return values

For C function return values, C arrays and non-array C pointers have different Silica mappings.

A C return value that represents an array must be mapped to a Silica buffer. The wrapper must provide enough information for Silica to know the buffer element type and length.

Canonical array return mapping:

```text
T * returned as array data -> buf(L, Space, T, N), where N is the returned length
```

If the C API returns a pointer to array data without a length, the wrapper must obtain the length from the library contract, an out-parameter, a companion function, a sentinel convention, or wrapper-maintained metadata. If the wrapper cannot determine the length, it must return an explicit error result instead of exposing the array to Silica.

Any other C pointer return value must be changed from the pointer itself into the data it points to, using the pointee type.

Canonical non-array pointer return mapping:

```text
T * returned as single object -> T
const T * returned as single object -> T
```

The wrapper is responsible for reading, copying, and decoding the pointed-to value into the corresponding Silica-compatible type before returning it to Silica.

If the pointer is null, the wrapper must translate null into an explicit error result or into a documented concrete sum value such as `None`.

The pointer value itself must not be returned to Silica for non-array return values.

### 6.5 `void *` translation

`void *` must not appear in a Silica-facing wrapper declaration.

Permitted translations for `void *` are:

- a de-opaqueified Silica-compatible record, sum, buffer, string, scalar, or explicit error;
- a concrete buffer when the value is known to be byte data and has a known length;
- an explicit error result when the wrapper cannot determine or validate the pointed-to type.

The wrapper must not guess the pointee type of a `void *`. The translation must be based on the underlying library contract, an accompanying tag or type code, or wrapper-controlled metadata.

### 6.6 De-opaqueified C structs

Opaque C structs must be de-opaqueified by wrapper code before their contents reach Silica.

For this specification, an opaque C struct is any C struct whose fields are hidden from the public C header, incomplete at the wrapper boundary, version-dependent, or otherwise not directly visible to Silica source.

Silica does not accept opaque C structs as opaque handles, raw pointers, integer handles, or untyped scalar values. The wrapper must translate the opaque C struct into its actual content using Silica-compatible explicit types.

Required wrapper behavior:

- inspect or access the underlying C object through the library's documented accessor functions, public ABI contract, or wrapper-owned knowledge of the object layout;
- copy the object's meaningful contents into Silica-compatible records, sums, buffers, strings, integers, floats, booleans, atoms, or other values allowed by this specification;
- return an explicit error result when the object contents cannot be accessed, validated, or represented as Silica-compatible values;
- avoid exposing the object's pointer identity as the Silica value.

The shape word that begins every Silica record value is not part of the C layout; the wrapper strips it from records passed to C and adds it to records returned from C at the boundary.

A C object that was originally opaque to ordinary C callers may be represented in Silica only after de-opaqueification into explicit content.

Example C library:

```c
typedef struct db_result db_result_t;

int db_result_status(db_result_t *result);
int64_t db_result_count(db_result_t *result);
const char *db_result_message(db_result_t *result);
```

Example Silica-facing result after de-opaqueification:

```silica
{ status: int64, count: int64, message: string }
```

If the C object represents a resource whose meaningful contents cannot be de-opaqueified, the wrapper must expose operations that return de-opaqueified snapshots or explicit error results. It must not expose the object itself as an opaque Silica value.

### 6.7 Recursive C struct prohibition

Recursive struct definitions are not allowed to be sent to Silica.

A struct is recursive if it contains, directly or indirectly, a field whose type refers back to the same struct shape. This includes recursion through pointers, arrays, records, tuples, lists, sum variants, or any chain of nested struct fields.

Invalid C shapes:

```c
struct node {
    int64_t value;
    struct node *next;
};

struct tree {
    int64_t value;
    struct tree *left;
    struct tree *right;
};
```

Such structures must be transformed by the wrapper into non-recursive Silica-compatible values, such as bounded buffers, flat records, summary values, or explicit error results.

**Compiler or wrapper-validation failure**:

```text
RecursiveExternalStructError:
Recursive C struct definitions cannot be exposed to Silica. The wrapper must return a non-recursive Silica-compatible value or an explicit error result.
```

### 6.8 Structs by value

C structs are permitted to be passed or returned by value only when the struct is explicitly declared as a Silica-compatible ABI record.

Such structs must:

- contain only wrapper-allowed scalar fields or other Silica-compatible ABI records;
- avoid bitfields;
- avoid flexible array members;
- avoid compiler-specific packing unless explicitly declared and checked;
- have layout declared consistently in Silica foreign declarations and sidecar metadata;
- be non-recursive.

### 6.9 Variadic functions

Silica-facing wrapper functions must not be variadic.

A C variadic API such as `printf` must be adapted through a fixed-signature wrapper function.

Example:

```c
int64_t silica_log_i64(const uint8_t *message_ptr, uint64_t message_len, int64_t value);
```

### 6.10 No inbound calls to Silica

This specification does not define callbacks, function pointers, trampolines, exported Silica functions, or any mechanism for external code to call into Silica.

Calls from C or from another language into Silica are not part of the language and are not planned.

---

## 7. External-Danger-Touched Data Rules

### 7.1 General taint rule

Any value returned from a `dangerous_*` module is external-danger-touched data.

This applies to all Silica values, not only strings, byte buffers, or memory-region references.

The taint is structural. Records, tuples, lists, and sum values containing external-danger-touched data are themselves external-danger-touched.

### 7.2 Executable content and command text

A string or byte buffer returned from a `dangerous_*` module is external-danger-touched data.

The compiler is not required to prove whether such data is executable binary content or system command text.

Instead, Silica treats such values as tainted external data. They must not be passed to APIs that execute commands, load dynamic code, write executable files, spawn processes, evaluate scripts, or cross ordinary actor `call` or `cast` message boundaries. There are two exceptions: the **FFI result cast** path defined in §4.2 and §7.6, and a value **re-created** under §7.7, which crosses those boundaries but still never reaches the APIs listed above.

Command execution APIs must not accept raw string commands. They must accept structured command values, such as an allowlisted program identifier plus an argument list.

### 7.3 Restricted effects

Any use of external-danger-touched data inside a `sequence ... produces pure ... end` block that declares any of the following existing Silica effects causes a type-check failure during compilation:

```silica
device_io
network_io
hot_swap
register_rwr
```

This rule applies to all external-danger-touched data, not only strings, byte buffers, or memory-region references.

The prohibition is structural. A value is not permitted to be used in one of these effect-tagged sequence blocks if it contains external-danger-touched data at any depth.

Invalid examples include:

- writing external-danger-touched data through `device_io`;
- sending external-danger-touched data through `network_io`;
- using external-danger-touched data in a `hot_swap` operation;
- using external-danger-touched data in a `register_rwr` operation;
- placing external-danger-touched data inside a record, tuple, list, or sum value and then using that containing value in any of the restricted effect blocks.

**Type-check failure**:

```text
ExternalDangerRestrictedEffectError:
external_danger-touched data cannot be used inside sequence blocks that declare device_io, network_io, hot_swap, or register_rwr.
```

### 7.4 Sequence completion rule

Silica retains no external-danger-touched data in the `produces pure` value of a `sequence proc[external_danger] ... produces pure ... end` block.

The value produced by the `produces pure` clause must contain only structurally pure Silica values. It must not contain external-danger-touched data at any depth.

**Strict structural taint**: In this specification version, external-danger-touched data is not cleared by destructuring, tag matching, field projection, copying into fresh records, or user-defined helper functions. A value returned from a `dangerous_*` module remains external-danger-touched at every depth until it is consumed entirely inside the `external_danger` sequence block without appearing in `produces pure`, or until it is re-created (§7.7), the one compiler-written validator.

Foreign outcomes leave an FFI worker actor through the designated **FFI result cast** to the receiver named in the request (§4.2). The cast payload may contain external-danger-touched data. The worker's `produces pure` value must contain only structurally pure actor state.

Before the sequence block completes, every external-danger-touched value inside the sequence must be one of the following:

- consumed entirely within the block without appearing in `produces pure`;
- delivered to the designated receiver by an FFI result cast executed inside the block;
- rejected through explicit control flow that does not place tainted data in `produces pure`;
- re-created into a structurally pure value by a compiler-derived `recreate` call (§7.7). The re-created value, not
  the tainted original, may then appear in `produces pure`.

Re-creation (§7.7) is the one permitted way to turn external-danger-touched data into a pure value. Destructuring,
copying and user-defined helpers remain ineffective, as stated above.

The sequence boundary is a taint boundary for `produces pure`. External-danger-touched data may exist inside the dynamic and lexical extent of the `external_danger` sequence block, and may appear only in FFI result casts executed from that block, except for region values explicitly converted into actor-state-owned region references under §7.5.

The result of the `produces pure` expression must be checked structurally. If any field, tuple element, list element, sum payload, or nested value contains external-danger-touched data, compilation fails.

**Type-check failure**:

```text
ExternalDangerSequenceResultError:
sequence proc[external_danger] must produce only pure Silica values; external_danger-touched data cannot appear in the produced value.
```

### 7.5 Actor-local memory-region containment

Any memory region modified, created, or used within a sequence block tagged with `external_danger` is actor-local to the FFI worker behavior function in which that sequence block appears.

Such a memory region must never be moved out of the FFI worker behavior, except that it may be explicitly converted into an actor-state-owned region reference and stored in the actor state returned by that behavior invocation, or delivered through an FFI result cast under §7.6.

This rule applies to:

- memory-region references passed into a `dangerous_*` module function;
- memory-region references returned from a `dangerous_*` module function;
- memory regions allocated, initialized, mutated, borrowed, or consumed within an `external_danger` sequence block;
- records, tuples, lists, or sum values containing any such memory-region reference.

Actor state is the only permitted long-lived destination for such memory regions. These regions must not cross actor message boundaries.

The parser must reject any program that attempts to move an external-danger-touched memory region out of the FFI worker behavior, except when the region is explicitly converted into an actor-state-owned region reference and placed into the actor state returned by that same behavior invocation, or delivered through an FFI result cast under §7.6.

**Parser failure**:

```text
ExternalDangerRegionEscapeError:
Memory regions created, modified, or used inside sequence proc[external_danger] cannot move out of the FFI worker behavior function, except when explicitly converted into actor-state-owned region references returned as actor state, or delivered through an FFI result cast under §7.6.
```

### 7.6 Actor call and cast boundary rule

An external-danger-touched memory region must not be included at any depth in:

- a return value produced for an ordinary actor `call`;
- an ordinary actor `cast` payload.

This prohibition is structural. Wrapping the region inside records, tuples, lists, or sum variants does not make it valid.

**FFI result cast exception**: An FFI worker actor may include external-danger-touched data, including memory-region references, in a cast payload sent to the receiver named in a foreign-call request, provided the cast is executed inside the requesting worker's `external_danger` sequence block. No other cast or call path may carry external-danger-touched memory regions.

A client actor that receives an FFI result cast must consume, discard, or re-create any external-danger-touched payload within that cast handler. It must not place external-danger-touched data, memory regions included, into actor state, ordinary outbound casts, or `call` replies. The only way for a result to leave the handler is re-creation (§7.7): the pure value that `recreate` returns may go into actor state, ordinary casts and `call` replies.

**Type-check failure**:

```text
ExternalDangerMessageBoundaryError:
Memory regions created, modified, or used inside sequence proc[external_danger] cannot appear at any depth in an ordinary call reply or cast payload. Only FFI result casts from an FFI worker actor to the designated receiver are permitted.
```

### 7.7 Validator rule: re-creation

External-danger-touched data stays tainted until it is consumed inside a permitted `external_danger` sequence block,
delivered through an FFI result cast (§4.2, §7.6), or **re-created**. Re-creation is the only validator this
specification defines, and it is written by the compiler, never by the program. User-defined helpers still never
clear taint (§7.4).

**Declaring a re-creatable type.** A program establishes the `Recreatable` marker trait on an inline type. The
body carries only limits, never code:

```silica
// A 64-byte digest.
impl Recreatable for buf(L, normal, uint8, 64) { max_bytes: 64 };

// A decoded record from a foreign parser.
impl Recreatable for { tag: :ok | :error, value: int64, name: string } { max_bytes: 4096, max_depth: 4 };
```

Limits are optional keyword fields: `max_bytes` (total size of the value), `max_depth` (nesting depth), and
`max_length` (maximum element count of any list or buffer). A type without a limit field uses the type's own fixed
bounds, and a variable-sized type with no applicable limit is rejected at compile time.

**The derived function.** For each such type `T`, the compiler derives:

```silica
recreate(x: T) -> (:ok, T) | (:rejected, atom)
```

The derived code does the following, in this order:

1. **It checks the declared limits** (total size, depth, lengths) before it reads the contents.
2. **It walks the value and builds a new one** in a fresh region owned by the caller. No part of the result refers
   to worker, wrapper or C-owned memory.
3. **It rebuilds every enumerated value** (atoms in an atom union, sum tags) from the type's own literals. An input
   value that is not one of the declared literals is rejected.
4. **It range-checks** every integer and float against its type and any declared bounds, and every buffer length
   against its type and limits. For `string` fields it may also check UTF-8 validity, when the declaration asks
   for it (`utf8: true`).
5. **It returns `(:ok, T)` with the new value, or `(:rejected, reason)`.** It never returns partial data. The
   `reason` atom names the first check that failed (for example `:too_large`, `:too_deep`, `:bad_tag`,
   `:out_of_range`, `:bad_utf8`).

**Where it may be called.** Only where external-danger-touched data may legally be: inside the `external_danger`
sequence block of an FFI worker, or inside the handler that receives an FFI result cast (§7.6).

**What the result may do.** The re-created value is structurally pure.
- It may go into actor state, ordinary casts and `call` replies.
- It may be used in sequence blocks that declare `device_io` or `network_io`.
- It **remains barred** from `hot_swap`, command execution, and code loading (§7.2). Re-created bytes are still
  foreign content.

**Auditability.** Every `impl Recreatable` is a visible de-taint point. The compiler reports each one as an advisory
warning, alongside the W4001 warning emitted for every foreign binding.

**Type-check failures**:

```text
RecreateCallSiteError:
recreate may be called only inside an external_danger sequence block or an FFI result-cast handler.

RecreatableLimitError:
Recreatable on a variable-sized type requires max_bytes, max_length, or another applicable limit.
```

---

## 8. Type Mapping

Type mapping is directional. Values sent from Silica to a C wrapper follow different rules from values returned from a C wrapper to Silica.

### 8.1 Values sent from Silica to a C wrapper

When Silica calls a C wrapper function, Silica values are lowered into the wrapper ABI as follows:

| Silica source type | C wrapper receives                                                   |
| ------------------ | -------------------------------------------------------------------- |
| `int8`             | `int8_t`                                                             |
| `int16`            | `int16_t`                                                            |
| `int32`            | `int32_t`                                                            |
| `int64`            | `int64_t`                                                            |
| `uint8`            | `uint8_t`                                                            |
| `uint16`           | `uint16_t`                                                           |
| `uint32`           | `uint32_t`                                                           |
| `uint64`           | `uint64_t`                                                           |
| `float32`          | `float`                                                              |
| `float64`          | `double`                                                             |
| `boolean`          | `uint8_t`, where `0 = false` and `1 = true`                          |
| `string` (adapter) | adapter parameter only; lowered at raw call to actor-stack copy as `const uint8_t *` plus `uint64_t` length |
| `string` (raw foreign binding) | not permitted; raw bindings use pointer-plus-length arguments |
| `buf(L, Space, T, N)` | typed pointer plus `uint64_t` element count; `buf(L, Space, uint8, N)` is the byte-payload form (§6.2) |
| inline record      | C struct with matching field order and verified layout               |
| inline sum         | C struct with explicit `tag` and payload fields                      |

Rules for values sent from Silica:

- Raw foreign bindings declare pointer-plus-length arguments for string data; exported adapter wrappers accept Silica `string`.
- Silica strings are copied into the FFI worker actor's expandable stack before the raw foreign binding call reaches C.
- The original Silica string storage is never exposed to C.
- The wrapper must treat string pointers as read-only.
- Silica buffers must be passed with their length.
- Silica must not send recursive record shapes to C.

### 8.2 Values returned from a C wrapper to Silica

When a C wrapper returns values to Silica, C ABI values are raised into Silica values as follows:

| C wrapper return value           | Silica receives                                                       |
| -------------------------------- | --------------------------------------------------------------------- |
| `int8_t`                         | `int8`                                                                |
| `int16_t`                        | `int16`                                                               |
| `int32_t`                        | `int32`                                                               |
| `int64_t`                        | `int64`                                                               |
| `uint8_t`                        | `uint8`                                                               |
| `uint16_t`                       | `uint16`                                                              |
| `uint32_t`                       | `uint32`                                                              |
| `uint64_t`                       | `uint64`                                                              |
| `float`                          | `float32`                                                             |
| `double`                         | `float64`                                                             |
| `uint8_t` used as boolean        | `boolean`, only when value is `0` or `1`                              |
| C struct result                  | inline Silica record or sum with verified non-recursive shape         |
| C array return                   | Silica buffer, `buf(L, Space, T, N)`, with known element type and length |
| non-array typed C pointer return | copied or decoded pointee value of type `T`                           |
| `void *` from underlying library | de-opaqueified record, sum, buffer, string, scalar, or explicit error |
| opaque C struct                  | de-opaqueified Silica-compatible contents or explicit error           |
| null pointer                     | explicit error result or documented concrete sum value such as `None` |

Rules for values returned to Silica:

- C array returns must become Silica buffers with known element type and length.
- Non-array C pointer returns must not expose pointer identity to Silica. The wrapper must copy or decode the pointed-to value into the corresponding Silica-compatible type.
- Opaque C structs must be de-opaqueified into actual Silica-compatible contents.
- Recursive C struct definitions must not be returned to Silica.
- `void *` must never be returned to Silica as an untyped pointer.
- Returned values from `dangerous_*` modules are external-danger-touched until consumed inside an FFI worker `external_danger` sequence or delivered through an FFI result cast.
- A wrapper must return an explicit error when it cannot determine a returned pointer's element type, pointee type, length, layout, or de-opaqueified contents.

---

## 9. Result Conventions

### 9.1 Tag convention

Result structs are required to use an integer tag field.

Required encoding:

```text
0 = Ok
1 = Error
```

Additional tags are permitted only when documented by the specific wrapper family.

### 9.2 Integer result

```c
typedef struct silica_i64_result {
    int64_t tag;
    int64_t value;
    int64_t error_code;
} silica_i64_result;
```

Meaning:

```text
tag = 0 => Ok(value)
tag = 1 => Error(error_code)
```

### 9.3 De-opaqueified object result

Opaque C object results must be returned to Silica as de-opaqueified content.

Example Silica-facing result shape:

```silica
Ok({ status: int64, count: int64, message: string }) | Error(int64)
```

The wrapper must copy or decode the object's contents into Silica-compatible fields before returning.

If the wrapper cannot access or validate the object's actual content, it must return an explicit error result.

The pointer identity, address, private handle, or incomplete object representation must not be returned to Silica.

### 9.4 Combined result

A wrapper is permitted to use a combined result when an operation returns multiple values.

```c
typedef struct silica_counter_result {
    int64_t tag;
    int64_t value;
    int64_t error_code;
} silica_counter_result;
```

Unused fields must be initialized to deterministic values.

Required default:

```text
Unused integer field = 0
Unused object field = implementation-defined invalid value
```

### 9.5 Error codes

Wrapper error codes are required to be stable integers local to the wrapper module.

A wrapper is permitted to translate C `errno` values, library-specific error codes, or null-pointer failures into wrapper-specific error codes.

The wrapper must read `errno` immediately after the failing call when `errno` is relevant.

---

## 10. Examples

### 10.1 Numeric wrapper

Original external C API:

```c
int legacy_add(int a, int b);
```

Silica-facing C wrapper header:

```c
#include <stdint.h>

int64_t silica_legacy_math_add_int64(int64_t left, int64_t right);
```

C wrapper implementation:

```c
#include <stdint.h>
#include "legacy_math.h"

int64_t silica_legacy_math_add_int64(int64_t left, int64_t right) {
    return (int64_t)legacy_add((int)left, (int)right);
}
```

Silica dangerous module:

```silica
module dangerous_legacy_math;

export add/2;

wrapper_meta "dangerous_exposure_source/legacy/silica_legacy_math_wrapper.meta";

foreign c_wrapper "silica_legacy_math_add_int64"
fn add_raw(left: int64, right: int64) -> int64;

fn add(left: int64, right: int64) -> int64 {
    add_raw(left, right)
}
```

Valid actor behavior and spawn site:

```silica
module dangerous_math_app;

use dangerous_legacy_math;

fn ffi_worker_behavior(
    msg: {
        op: :foreign_call,
        reply_to: actor_ref,
        left: int64,
        right: int64
    },
    state: { pending: int64 }
) -> { pending: int64 } {
    sequence proc[external_danger, concurrency]
        sum: int64 <- dangerous_legacy_math@add(msg.left, msg.right);
        cast(msg.reply_to, { tag: :foreign_ok, value: sum });
    produces
        pure state
    end
}

fn client_behavior(
    msg: {
        op: :compute,
        left: int64,
        right: int64
    } | {
        tag: :foreign_ok,
        value: int64
    },
    state: { value: int64, worker: actor_ref, self_ref: actor_ref }
) -> { value: int64, worker: actor_ref, self_ref: actor_ref } {
    case msg of {
        { op: :compute, left: left, right: right } -> {
            cast(state.worker, {
                op: :foreign_call,
                reply_to: state.self_ref,
                left: left,
                right: right
            });
            state
        };
        { tag: :foreign_ok, value: value } -> {
            { value: value, worker: state.worker, self_ref: state.self_ref }
        };
    }
}

fn main() -> int64 {
    sequence proc[concurrency]
        worker_ref: dangerous_actor_ref <- spawn_dangerous({ pending: 0 }, ffi_worker_behavior);
        client_ref: actor_ref <- spawn(
            { value: 0, worker: worker_ref, self_ref: client_ref },
            client_behavior
        );
    produces
        pure 0
    end
}
```

This example is valid because:

- the importing compilation unit is a `dangerous_*` module (`dangerous_math_app`), satisfying the dangerous dependency naming rule in §3.1;
- the external call is exposed only through a `dangerous_*` module;
- the call appears inside the sequence portion of `sequence proc[external_danger] ... produces pure ... end` in an FFI worker cast-only behavior;
- the client actor requests foreign work by `cast` and receives the outcome by FFI result cast;
- the worker's `produces pure` value contains only structurally pure actor state; the foreign result leaves through an FFI result cast;
- `main` installs the FFI worker with `spawn_dangerous` using only `concurrency` and does not contain an `external_danger` sequence or call any `dangerous_*` module function directly.

### 10.2 Fallible parser wrapper returning pure data

C wrapper header:

```c
#include <stdint.h>

typedef struct silica_i64_result {
    int64_t tag;
    int64_t value;
    int64_t error_code;
} silica_i64_result;

silica_i64_result silica_net_parse_port(
    const uint8_t *text_ptr,
    uint64_t text_len
);
```

C wrapper implementation outline:

```c
#include <stdint.h>
#include <stdlib.h>

silica_i64_result silica_net_parse_port(
    const uint8_t *text_ptr,
    uint64_t text_len
) {
    silica_i64_result result;

    if (text_ptr == 0 || text_len == 0) {
        result.tag = 1;
        result.value = 0;
        result.error_code = 1;
        return result;
    }

    /* Parse copied actor-stack string bytes without retaining text_ptr. */
    result.tag = 0;
    result.value = 8080;
    result.error_code = 0;
    return result;
}
```

Silica dangerous module:

```silica
module dangerous_net;

export parse_port/1;

wrapper_meta "dangerous_exposure_source/net/silica_net_wrapper.meta";

foreign c_wrapper "silica_net_parse_port"
fn parse_port_raw(text_ptr: uint8, text_len: uint64) -> { tag: int64, value: int64, error_code: int64 };

fn parse_port(text: string) -> { tag: int64, value: int64, error_code: int64 } {
    parse_port_raw(text)
}
```

Sidecar metadata referenced by `wrapper_meta` (`dangerous_exposure_source/net/silica_net_wrapper.meta`):

```text
link_library: "silica_net"

wrapper silica_net_parse_port {
    symbol: "silica_net_parse_port"
    result: "tagged_result"
    error_domain: "dangerous_net"
}
```

Valid actor behavior and spawn site:

```silica
module dangerous_parser_app;

use dangerous_net;

fn ffi_worker_behavior(
    msg: {
        op: :foreign_call,
        reply_to: actor_ref,
        text: string
    },
    state: { pending: int64 }
) -> { pending: int64 } {
    sequence proc[external_danger, concurrency]
        raw: { tag: int64, value: int64, error_code: int64 } <- dangerous_net@parse_port(msg.text);
        cast(msg.reply_to, { tag: :foreign_ok, raw: raw });
    produces
        pure state
    end
}

fn client_behavior(
    msg: { op: :parse, text: string } | { tag: :foreign_ok, raw: { tag: int64, value: int64, error_code: int64 } },
    state: { last_port: int64, worker: actor_ref, self_ref: actor_ref }
) -> { last_port: int64, worker: actor_ref, self_ref: actor_ref } {
    case msg of {
        { op: :parse, text: text } -> {
            cast(state.worker, { op: :foreign_call, reply_to: state.self_ref, text: text });
            state
        };
        { tag: :foreign_ok, raw: raw } -> {
            case raw.tag of {
                0: int64 -> { last_port: raw.value, worker: state.worker, self_ref: state.self_ref };
                _: int64 -> state;
            }
        };
    }
}

fn main() -> int64 {
    sequence proc[concurrency]
        worker_ref: dangerous_actor_ref <- spawn_dangerous({ pending: 0 }, ffi_worker_behavior);
        parser_ref: actor_ref <- spawn(
            { last_port: 0, worker: worker_ref, self_ref: parser_ref },
            client_behavior
        );
    produces
        pure 0
    end
}
```

This example is valid because the importing compilation unit is a `dangerous_*` module (`dangerous_parser_app`), the client actor uses a cast-only behavior, the `external_danger` sequence is in the FFI worker behavior rather than in `main`, the raw foreign binding uses pointer-plus-length while the adapter accepts `string`, and the worker delivers the foreign result through an FFI result cast rather than through `produces pure`.

### 10.3 Array return mapped to a Silica buffer

Examples §10.3–§10.5 show `dangerous_*` module and C wrapper shapes only. Application integration uses the cast-mediated FFI worker model from §4 and §10.1–§10.2.

Original external C API:

```c
const int64_t *library_values(uint64_t *out_len);
```

Silica-facing C wrapper header:

```c
#include <stdint.h>

typedef struct silica_i64_buffer_result {
    int64_t tag;
    const int64_t *items_ptr;
    uint64_t items_len;
    int64_t error_code;
} silica_i64_buffer_result;

silica_i64_buffer_result silica_values_get_all(void);
```

Required wrapper behavior:

- `items_ptr` and `items_len` describe array data.
- The Silica binding maps the pair to `buf(L, normal, int64, N)`, with `N` taken from `items_len`.
- If the wrapper cannot determine `items_len`, it must return an error result.

Silica dangerous module:

```silica
module dangerous_values;

export get_all/0;

wrapper_meta "dangerous_exposure_source/values/silica_values_wrapper.meta";

foreign c_wrapper "silica_values_get_all"
fn get_all_raw() -> { tag: int64, items: buf(L, normal, int64, N), error_code: int64 };

fn get_all() -> { tag: int64, items: buf(L, normal, int64, N), error_code: int64 } {
    get_all_raw()
}
```

Valid actor behavior and spawn site:

```silica
module dangerous_values_app;

use dangerous_values;

fn values_actor_behavior(
    msg: atom,
    state: { count: int64 }
) -> { count: int64 } {
    sequence proc[external_danger]
        raw: { tag: int64, items: buf(L, normal, int64, N), error_code: int64 } <- dangerous_values@get_all();
        count_value: int64 <- buffer_length(raw.items);
    produces
        pure case raw.tag of {
            0: int64 -> { count: count_value };
            _: int64 -> state;
        }
    end
}

fn main() -> int64 {
    sequence proc[concurrency]
        values_ref: actor_ref <- spawn(
            { count: 0 },
            values_actor_behavior
        );
    produces
        pure 0
    end
}
```

This example is valid only if the importing compilation unit is a `dangerous_*` module (here `dangerous_values_app`), `values_actor_behavior` is the function passed to `spawn_dangerous`, `count_value` is a pure Silica value, and the returned buffer itself does not escape the `external_danger` sequence.

### 10.4 Non-array pointer return decoded to pointee data

Original external C API:

```c
typedef struct point {
    int64_t x;
    int64_t y;
} point_t;

const point_t *library_current_point(void);
```

Silica-facing C wrapper header:

```c
#include <stdint.h>

typedef struct silica_point {
    int64_t x;
    int64_t y;
} silica_point;

typedef struct silica_point_result {
    int64_t tag;
    silica_point value;
    int64_t error_code;
} silica_point_result;

silica_point_result silica_point_current(void);
```

Required wrapper behavior:

- the original `const point_t *` is not returned to Silica;
- the wrapper copies the pointee data into `silica_point`;
- null is translated into an error result.

Silica dangerous module:

```silica
module dangerous_point;

export current/0;

wrapper_meta "dangerous_exposure_source/point/silica_point_wrapper.meta";

foreign c_wrapper "silica_point_current"
fn current_raw() -> { tag: int64, value: { x: int64, y: int64 }, error_code: int64 };

fn current() -> { tag: int64, value: { x: int64, y: int64 }, error_code: int64 } {
    current_raw()
}
```

### 10.5 De-opaqueified C struct

Original external C API:

```c
typedef struct db_result db_result_t;

int db_result_status(db_result_t *result);
int64_t db_result_count(db_result_t *result);
const char *db_result_message(db_result_t *result);
```

Silica-facing C wrapper header:

```c
#include <stdint.h>

typedef struct silica_db_result_snapshot {
    int64_t status;
    int64_t count;
    const uint8_t *message_ptr;
    uint64_t message_len;
} silica_db_result_snapshot;

typedef struct silica_db_result_snapshot_result {
    int64_t tag;
    silica_db_result_snapshot value;
    int64_t error_code;
} silica_db_result_snapshot_result;

silica_db_result_snapshot_result silica_db_result_snapshot_current(void);
```

Required wrapper behavior:

- the opaque `db_result_t *` is not exposed to Silica;
- accessor functions are used to de-opaqueify the object;
- the returned Silica-facing value is a non-recursive snapshot;
- recursive links, private identity, handles, and raw pointers do not reach Silica.

Silica dangerous module:

```silica
module dangerous_db_result;

export current_snapshot/0;

wrapper_meta "dangerous_exposure_source/db/silica_db_result_wrapper.meta";

foreign c_wrapper "silica_db_result_snapshot_current"
fn current_snapshot_raw() -> {
    tag: int64,
    value: { status: int64, count: int64, message: string },
    error_code: int64
};

fn current_snapshot() -> {
    tag: int64,
    value: { status: int64, count: int64, message: string },
    error_code: int64
} {
    current_snapshot_raw()
}
```

---

## 11. Ownership and Lifetime Rules

### 11.1 Copied Silica string memory

A Silica `string` passed to a C wrapper function is copied before the wrapper receives it.

The copy is stored in the expandable stack of the encompassing Silica actor, not in the general heap.

The C wrapper receives only the copied memory. It never receives a modifiable reference to the original Silica string.

The copied string memory is valid only for the duration of the foreign function call. When the function call ends, the copied memory is recovered.

The wrapper must not retain a pointer to the copied string memory after returning.

### 11.2 Retained data

If a C library needs to retain data passed from Silica, the wrapper must copy the data into wrapper-owned or library-owned memory.

For Silica strings, this means copying from the actor-stack string copy into memory whose lifetime is controlled by the wrapper or underlying library.

### 11.3 Allocator identity

Memory allocated by a C library must be freed by the appropriate C library or wrapper function.

Silica code must not directly free C-allocated memory unless the allocation contract explicitly permits it.

### 11.4 De-opaqueified external objects

Opaque external C objects must not be retained by Silica as opaque values.

When a C library returns an opaque object, the wrapper must either:

- decode the object's meaningful contents into Silica-compatible values;
- expose a wrapper operation that performs a complete operation and returns only Silica-compatible values;
- return an explicit error result.

The implementation may use private C pointers or wrapper-owned handle tables internally during the execution of a wrapper function, but ordinary Silica code must never observe those pointers or handles.

### 11.5 Double close

Wrapper implementations are required to detect invalid or already-closed resources when detection is possible and return an error code rather than causing undefined behavior.

---

## 12. Non-Blocking Foreign Calls

All outbound foreign calls use the cast-mediated model in §4.2. Client actors and FFI worker actors both use cast-only behaviors. A client never waits synchronously inside an `external_danger` sequence for a C library call to finish.

**Architectural rule**: Every foreign call is non-blocking at the Silica actor level. The client sends a foreign-call request cast and continues until it handles the FFI result cast. Any synchronous wait inside the underlying C wrapper executes on the FFI worker actor's thread only and does not block other actors' scheduling.

Sidecar metadata does **not** declare `blocking`. That field is redundant because the cast-only FFI worker model already isolates potentially blocking C library calls to the worker actor thread.

Wrapper authors remain responsible for not performing unbounded blocking work that would stall an FFI worker actor, but that is an operational constraint on worker design—not a separate metadata dimension tracked by the compiler.

---

## 13. Wrapper Metadata

The wrapper must be macro-free.

C wrapper headers and C wrapper implementation files must not define or require Silica-specific C preprocessor macros for ownership, lifetime, blocking behavior, result semantics, ABI versioning, or binding generation.

Wrapper metadata that cannot be derived from Silica foreign declarations must be supplied in **sidecar metadata files** stored under `dangerous_exposure_source/`.

### 13.1 Sidecar reference and discovery

Sidecar metadata files live under `dangerous_exposure_source/` but are located **only** through explicit Silica source references:

```silica
wrapper_meta "dangerous_exposure_source/db/silica_db_wrapper.meta";
```

or, for a single binding override:

```silica
foreign c_wrapper "silica_db_get_i64"
    meta "dangerous_exposure_source/db/silica_db_wrapper.meta"
fn get_i64_raw(key_ptr: uint8, key_len: uint64) -> { tag: int64, value: int64, error_code: int64 };
```

Example layout:

```text
dangerous_exposure_source/db/silica_db_wrapper.h      # C header (authoring reference; not parsed by toolchain)
dangerous_exposure_source/db/silica_db_wrapper.meta    # sidecar metadata
dangerous_exposure_source/lib/libsilica_db.a           # prebuilt archive
silica.link                                            # link manifest (emitted in build dir after compile)
```

```silica
module dangerous_db;

wrapper_meta "dangerous_exposure_source/db/silica_db_wrapper.meta";

foreign c_wrapper "silica_db_get_i64"
fn get_i64_raw(key_ptr: uint8, key_len: uint64) -> { tag: int64, value: int64, error_code: int64 };
```

Rules:

- The compiler loads a sidecar file if and only if a `wrapper_meta` or `meta` declaration in the compiling module names that path.
- The compiler does **not** infer sidecar paths from header basenames, directory walks, `silica_<module>_<function>` symbol names, or build-system defaults.
- A module with foreign bindings must declare at least one reachable sidecar path before compilation succeeds.
- Each `foreign c_wrapper "symbol"` declaration must have exactly one matching `wrapper symbol { ... }` entry in a referenced sidecar file.
- A sidecar file may declare one `link_library` name used at link time for all wrappers listed in that file.

The Silica compiler reads explicitly referenced sidecar metadata during compilation. After all units in `silica.config` compile successfully, the compiler aggregates required `link_library` names and `foreign c_wrapper` symbols for the whole program closure, verifies that each resolved prebuilt archive exists under `dangerous_exposure_source/lib/`, and writes **`silica.link`** in the build directory. Project build scripts (Makefiles in the reference trial harness) read `archive:` lines from `silica.link` during the link stage and pass those static archive paths to the external linker (`rust-lld` or `clang`). The compiler does **not** invoke the linker. The linker verifies that each referenced wrapper symbol is defined in the linked prebuilt libraries.

### 13.2 Required sidecar fields (initial implementation)

Each `wrapper` entry must include at minimum:

```text
wrapper silica_db_get_i64 {
    symbol: "silica_db_get_i64"
    result: "tagged_result"
    error_domain: "dangerous_db"
}
```

Optional argument metadata may describe properties not visible in Silica foreign declarations:

```text
    arguments: [
        { name: "key_ptr", lifetime: "borrowed", retain: false },
        { name: "key_len", role: "length", length_of: "key_ptr" }
    ]
```

Required documented properties include, when applicable:

- borrowed inputs;
- retained external data;
- out-parameters;
- result tag conventions;
- array element type and length source;
- de-opaqueification contract;
- non-recursive struct declarations;
- error-code domain.

`blocking` is not a sidecar field. The cast-only FFI worker architecture makes blocking metadata redundant (§12).

### 13.3 What the toolchain does not validate initially

The initial Silica toolchain does **not** parse C headers or C source. It does not mechanically verify C struct layout, C type spelling, variadic signatures, or wrapper implementation behavior.

Silica-side foreign declarations and sidecar metadata are the source of truth for the Silica-facing ABI. Compile time verifies that each named prebuilt archive exists before `silica.link` is written. Link time verifies symbol presence in the archives named by that manifest only.

---

## 14. Build-System Requirements

### 14.1 Dangerous exposure source directory

All C wrapper header files are required to be located under the `dangerous_exposure_source` directory at the root of the Silica source code for the project.

Subdirectories inside `dangerous_exposure_source` are permitted.

Valid header locations:

```text
dangerous_exposure_source/silica_net_wrapper.h
dangerous_exposure_source/db/silica_db_wrapper.h
dangerous_exposure_source/vendor/sqlite/silica_sqlite_wrapper.h
```

Invalid header locations:

```text
include/silica_net_wrapper.h
src/ffi/silica_db_wrapper.h
wrappers/silica_sqlite_wrapper.h
```

The Silica compiler rejects any `wrapper_meta` or `meta` path, or any sidecar metadata file referenced by those declarations, located outside `dangerous_exposure_source`.

Required failure:

```text
WrapperMetaPathError:
wrapper_meta and meta paths must be located under dangerous_exposure_source at the root of the Silica project,
or at the root of the library that declares them.
```

**Libraries.** A library, meaning a set of Silica sources consumed by other projects, may root its own
`dangerous_exposure_source` directory at the library's root.
- `wrapper_meta` and `meta` paths in the library's modules are resolved relative to the library that declares them.
- The same applies to sidecar files and `lib<name>.a` archives (§14.2) named by those sidecars.
- The consuming project does not need to copy them into its own tree.
- The project-root rule above remains the default for application modules.
- Every path, whether library-rooted or project-rooted, must still lie under a `dangerous_exposure_source` directory.
- The `dangerous_*` naming cascade (§2.4, §3.1) is unchanged. A project that uses a library's `dangerous_*` modules still has a `dangerous_*` root module.

### 14.2 Prebuilt wrapper libraries and link manifest (initial implementation)

In the initial implementation, C wrapper object code is supplied as **prebuilt static libraries**. Project Makefiles link these libraries during Stage 3 of the build; `silica-compiler` does not compile C wrapper sources and does not invoke the assembler or linker.

**Three-stage build (reference harness)**

1. **`silica-compiler`** — compile units listed in `silica.config` to `.sams` (and `__silica_runtime.sams` when needed); emit **`silica.link`** when the program uses foreign bindings.
2. **`clang`** — assemble `.sams` → `.o`.
3. **`rust-lld` or `clang`** — link `.o` and manifest-named static archives → executable.

Conventions:

- A sidecar file names the library to link: `link_library: "silica_db"`.
- Prebuilt archives live under `dangerous_exposure_source/lib/`, for example `dangerous_exposure_source/lib/libsilica_db.a`.
- The resolved archive path for a `link_library` name `<name>` is `dangerous_exposure_source/lib/lib<name>.a`, relative to the root (project or library, §14.1) that holds the sidecar naming it.
- The linker must resolve every `foreign c_wrapper "symbol"` used by the program against the archives named in `silica.link`.

**Link manifest (`silica.link`)**

After a successful compile of **all** units in `silica.config`, and only when the program closure references foreign bindings, the compiler writes one link manifest file, **`silica.link`**, in the build directory. The file lists:

- deduped `link_library: "<name>"` lines;
- resolved `archive: "dangerous_exposure_source/lib/lib<name>.a"` lines (one per `link_library`);
- deduped `symbol: "<c_wrapper_symbol>"` lines for every `foreign c_wrapper` binding in the closure.

Example:

```text
link_library: "silica_legacy_math"
archive: "dangerous_exposure_source/lib/libsilica_legacy_math.a"
link_library: "silica_text"
archive: "dangerous_exposure_source/lib/libsilica_text.a"
symbol: "silica_legacy_math_add_int64"
symbol: "silica_text_echo"
```

The manifest is macro-free and Makefile-friendly. Build scripts may pass `archive:` paths directly to the linker or derive `-L dangerous_exposure_source/lib -l<name>` from `link_library:` lines; direct archive paths are preferred for deterministic builds.

Before writing `silica.link`, the compiler verifies that each resolved archive path exists on disk. If a referenced archive is missing, compilation fails and **`silica.link` is not written**.

**Compile-time failure (missing archive)**:

```text
MissingArchiveError:
Referenced prebuilt library archive is missing from the project layout.
```

Compiler diagnostic: **`E4034`** (spec §15.2).

**Link-time failure (missing symbol)**:

```text
MissingForeignSymbolError:
Required C wrapper symbol is not defined in the linked prebuilt libraries.
```

This failure is reported by the external linker when a declared `foreign c_wrapper` symbol is not defined in the archives passed at Stage 3 (for example undefined symbol `_silica_legacy_math_symbol_not_in_archive` on macOS AArch64).

### 14.3 Package declarations (future)

Library-rooted `dangerous_exposure_source` directories (§14.1) are available without a package format. A future
Silica package format may additionally declare:

- wrapper header files located under `dangerous_exposure_source`;
- wrapper implementation files;
- include paths;
- library search paths;
- libraries to link;
- link mode for each external library, where relevant: dynamically linked shared library or statically linked archive/object library;
- optional `pkg-config` package names;
- target-specific conditions.

Example future package metadata shape:

```text
foreign package db {
    headers: ["dangerous_exposure_source/db/silica_db_wrapper.h"]
    sidecars: ["dangerous_exposure_source/db/silica_db_wrapper.meta"]
    libraries: ["dangerous_exposure_source/lib/libsilica_db.a"]
    link_mode: "static"
}
```

Compilation of C wrapper sources and dynamic linking support are out of scope for the initial implementation described by this specification version.

---

## 15. Compile-Time and Parser Checks

The compile-time and parser checks are divided into two categories:

1. Silica-side checks; and
2. link-time and metadata checks.

### 15.1 Silica-side checks

Silica-side checks are enforced by the Silica parser, type checker, effect checker, and module checker.

Required Silica-side hard errors:

- foreign declaration in a module whose name does not begin with `dangerous_`;
- import or other use of a `dangerous_*` module from a module whose own name does not begin with `dangerous_`;
- raw foreign binding exported directly to application code;
- exported function from a `dangerous_*` module that is not a Silica adapter wrapper with a body;
- module containing `foreign c_wrapper` declarations with no `wrapper_meta` declaration and no per-binding `meta` clause;
- `wrapper_meta` or `meta` path not located under `dangerous_exposure_source`;
- sidecar file referenced by `wrapper_meta` or `meta` that does not exist on disk;
- direct call to any function in a `dangerous_*` module from an application actor behavior or outside an FFI worker actor;
- call to any function in a `dangerous_*` module outside the sequence portion of a `sequence proc[external_danger] ... produces pure ... end` block;
- `dangerous_*` module call outside the sequence portion of a sequence block that declares `external_danger`;
- `dangerous_*` module call inside a sequence block that does not declare `external_danger`;
- actor that initiates foreign work spawned with a behavior that is not cast-only;
- `spawn(...)` starting a behavior that contains an `external_danger` sequence or calls any `dangerous_*` module function;
- `spawn_dangerous(...)` starting a behavior that does not contain a valid FFI worker `external_danger` sequence;
- `spawn_dangerous(...)` result bound as `actor_ref`, or `spawn(...)` result bound as `dangerous_actor_ref`;
- `spawn_dangerous_registered(...)` result bound as `actor_ref`, or `spawn_registered(...)` result bound as `dangerous_actor_ref`;
- `spawn_registered(...)` when the behavior is an FFI worker behavior or uses `external_danger` / `dangerous_*` calls; use `spawn_dangerous_registered` instead;
- `spawn_registered(...)` with a registry `name` whose atom spelling begins with `dangerous_`;
- `spawn_dangerous_registered(...)` with a registry `name` whose atom spelling does not begin with `dangerous_`;
- `cast_registered(...)` when the name is registered in the dangerous registry or its spelling begins with `dangerous_`;
- `cast_dangerous_registered(...)` when the name is registered in the ordinary registry or its spelling does not begin with `dangerous_`;
- `external_danger` declared on a sequence block that installs an FFI worker with `spawn_dangerous`;
- `external_danger` sequence block outside the cast-only behavior function passed directly to `spawn_dangerous` for an FFI worker actor;
- `external_danger` sequence block inside an ordinary top-level function body;
- `external_danger` sequence block inside a helper function that is not the FFI worker behavior passed directly to `spawn_dangerous`;
- `external_danger` sequence block inside an application actor behavior or inside `main`;
- `external_danger` sequence block inside a function literal that is not passed directly as an FFI worker behavior to `spawn_dangerous`;
- `external_danger` sequence block in a nested expression position that is not the direct body of the installed FFI worker behavior function;
- raw foreign binding declaration using Silica `string` instead of pointer-plus-length arguments;
- more than eight Silica-level arguments after lowering;
- raw pointers in Silica-facing declarations;
- missing or mismatched sidecar metadata entry for a used `foreign c_wrapper` symbol;
- memory region created, modified, or used within `sequence proc[external_danger] ... produces pure ... end` moved out of the FFI worker behavior except through explicit conversion into an actor-state-owned region reference returned as actor state;
- `sequence proc[external_danger] ... produces pure ... end` block producing a value containing external-danger-touched data at any depth;
- memory region created, modified, or used within `sequence proc[external_danger] ... produces pure ... end` included at any depth in an ordinary `call` reply or cast payload;
- external-danger-touched data used inside a sequence block that declares `device_io`, `network_io`, `hot_swap`, or `register_rwr`;
- recursive Silica record shape sent to a C wrapper;
- foreign declaration whose Silica type disagrees with the declared sidecar metadata contract.

Required Silica-side warning:

- `W4001` for each accepted `foreign c_wrapper` declaration encountered in a module.

`W4001` is a warning, not a hard error. It is emitted only for actual FFI wrapper declarations and does not change the compiler exit status. The purpose is to make every FFI boundary visibly dangerous even when the program otherwise satisfies all required FFI rules.

Required compiler warning:

```text
FFI_Warning at
W4001

DANGER DANGER DANGER: this module uses FFI wrapper '<local_name>' for foreign symbol '<symbol_name>'. FFI breaks the Silica security model for this app and exposes the entire application to memory insecurity, ABI unsafety, undefined behavior, privilege-boundary collapse, and other security issues from the foreign code and wrapper boundary.
```

Required parser failure:

```text
MissingWrapperMetaError:
A module that declares foreign c_wrapper bindings must declare wrapper_meta paths or a meta path on each foreign binding.
```

Required parser failure:

```text
WrapperMetaPathError:
wrapper_meta and meta paths must be located under dangerous_exposure_source at the root of the Silica project.
```

Required parser failure:

```text
ExternalDangerClientBehaviorError:
Actors that initiate foreign work must use cast-only behaviors.
```

Required parser failure:

```text
ExternalDangerPlacementError:
external_danger sequence blocks are only valid directly inside the cast-only behavior function installed by spawn_dangerous for an FFI worker actor.
```

Required parser failure:

```text
DangerousSpawnMismatchError:
spawn cannot start a behavior that uses external_danger or dangerous_* code; use spawn_dangerous and bind the result as dangerous_actor_ref.
```

Required parser failure:

```text
SpawnDangerousBehaviorError:
spawn_dangerous requires a behavior whose body uses sequence proc[external_danger] or dangerous_* code.
```

Required parser failure:

```text
ExternalDangerInSpawnSiteError:
sequence blocks that call spawn_dangerous must not declare external_danger. The external_danger effect is valid only inside the FFI worker behavior passed to spawn_dangerous.
```

Required parser failure:

```text
DangerousDependencyNamingError:
A module that imports or uses a dangerous_* module must use the dangerous_ prefix in its own module name.
```

Required parser failure:

```text
DangerousModuleCallError:
Calls to dangerous_* module functions must appear in the sequence portion of sequence proc[external_danger] ... produces pure ... end inside an FFI worker actor behavior.
```

Required parser failure:

```text
ExternalDangerRegionEscapeError:
Memory regions created, modified, or used inside sequence proc[external_danger] cannot move out of the FFI worker behavior function, except when explicitly converted into actor-state-owned region references returned as actor state, or delivered through an FFI result cast under §7.6.
```

Required type-check failure:

```text
ExternalDangerSequenceResultError:
sequence proc[external_danger] must produce only pure Silica values; external-danger-touched data cannot appear in the produced value.
```

Required type-check failure:

```text
ExternalDangerMessageBoundaryError:
Memory regions created, modified, or used inside sequence proc[external_danger] cannot appear at any depth in an ordinary call reply or cast payload. Only FFI result casts from an FFI worker actor to the designated receiver are permitted.
```

Required type-check failure:

```text
ExternalDangerRestrictedEffectError:
external-danger-touched data cannot be used inside sequence blocks that declare device_io, network_io, hot_swap, or register_rwr.
```

### 15.2 Link-time and metadata checks

Link-time and metadata checks are enforced by the Silica compiler when loading sidecar metadata and when writing the link manifest, and by the external linker when producing the final binary.

Required hard errors in the initial implementation:

- sidecar file path referenced by `wrapper_meta` or `meta` located outside `dangerous_exposure_source`;
- module with `foreign c_wrapper` declarations and no reachable sidecar reference;
- `foreign c_wrapper "symbol"` declaration with no matching sidecar `wrapper` entry in a referenced sidecar file;
- sidecar entry with no `link_library` declaration for its file;
- required sidecar field missing for a used wrapper (`result` or `error_domain` when applicable);
- referenced prebuilt library archive missing from the project layout (checked when emitting `silica.link`; compilation fails before the manifest is written);
- wrapper symbol referenced by Silica not defined in the linked prebuilt libraries (checked by the external linker at Stage 3 using archives named in `silica.link`).

Required compile-time failure (missing archive, link-manifest validation):

```text
MissingArchiveError:
Referenced prebuilt library archive is missing from the project layout.
```

Compiler diagnostic: **`E4034`**.

Required link-time failure (missing symbol):

```text
MissingForeignSymbolError:
Required C wrapper symbol is not defined in the linked prebuilt libraries.
```

Required metadata failure:

```text
MissingWrapperMetaError:
A module that declares foreign c_wrapper bindings must declare wrapper_meta paths or a meta path on each foreign binding.
```

```text
WrapperMetaPathError:
wrapper_meta and meta paths must be located under dangerous_exposure_source at the root of the Silica project.
```

The following wrapper-side checks from earlier specification drafts are **not mechanically enforced** by the Silica toolchain. They remain **authoring guidelines** for wrapper implementers. The Silica compiler does not parse C headers or wrapper source; there is no plan to add a C tokenizer or parser for these checks.

- unsupported C type in wrapper signature;
- variadic wrapper function;
- unsupported C struct layout;
- recursive C struct definition exposed to Silica instead of being flattened, summarized, bounded, or rejected;
- C array return value not mapped to a Silica buffer with known element type and length;
- non-array C pointer return value exposed as a pointer instead of being copied or decoded into its pointee type;
- `void *` value exposed directly to Silica instead of being translated by wrapper code into an approved concrete Silica-facing representation;
- opaque C object exposed to Silica as `uint64`, raw pointer, untyped scalar, handle, or opaque external type instead of being de-opaqueified into Silica-compatible contents;
- wrapper result struct missing a deterministic tag convention;
- wrapper result struct containing uninitialized fields visible to Silica;
- wrapper exposing a C string as NUL-terminated only instead of pointer-plus-length or Silica-compatible string data;
- wrapper retaining actor-stack string or buffer copies after the foreign call ends;
- wrapper failing to provide an explicit error result when it cannot determine a returned pointer's element type, pointee type, length, layout, or de-opaqueified contents;
- Silica-specific C preprocessor macro present in a wrapper header or wrapper implementation.

The deferred checks remain design requirements for wrapper authors even when not mechanically enforced in the initial toolchain. Mechanical enforcement of this list is **out of scope** for the Silica compiler.

---

## 16. Open Design Questions

The following questions remain open:

1. Exact sidecar `.meta` field syntax details beyond the initial required fields in §13.2.
2. Standard foreign-call request and FFI result cast message shapes.
3. How many FFI worker actors a program should spawn by convention (shared vs per-domain workers).
4. When the build tool should compile C wrapper sources and support dynamic linking (§14.3).

**Resolved and moved to §16.1:** how client actors derive pure actor state from FFI result casts, and how region
values returned through FFI result casts become actor-owned. Both are answered by re-creation (§7.7).

**Removed from open questions:** mechanical wrapper-side checks in §15.2 — out of scope; Silica validates Silica declarations, sidecar metadata, and link manifest only; wrapper authors follow the §15.2 authoring guidelines without compiler C parsing.

### 16.1 Resolved design decisions

The following decisions are fixed by this specification version:

| Topic | Decision |
| ----- | -------- |
| Dangerous-module call scope | Every call to any function in any `dangerous_*` module must appear inside an FFI worker `external_danger` sequence. |
| Install vs execute | `spawn_dangerous` installs an FFI worker and requires only `concurrency` at the spawn site. `external_danger` authorizes foreign-call execution inside the worker behavior only. |
| FFI worker spawn | FFI worker actors are installed with `spawn_dangerous(...)` or `spawn_dangerous_registered(...)` and referenced by `dangerous_actor_ref`. Ordinary `spawn(...)` and `spawn_registered(...)` must not start dangerous behaviors. |
| Actor registries | Two process-global atom-keyed slot tables: ordinary (`actor_ref`, `cast_registered`) and dangerous (`dangerous_actor_ref`, `cast_dangerous_registered`). Same opaque handle at runtime; retrieval typed by table and lookup primitive (§4.9). Dangerous registry keys must use the `dangerous_` atom spelling prefix. |
| Foreign call transport | All outbound foreign calls use cast to an FFI worker actor; results return by FFI result cast. |
| Client actor shape | Actors that initiate foreign work use cast-only behaviors. |
| Adapter-wrapper detection | Exported `dangerous_*` functions must have a Silica body; raw `foreign c_wrapper` declarations are never exported. |
| String declarations | Raw foreign bindings use pointer-plus-length; adapter wrappers accept Silica `string`. |
| Metadata | Sidecar `.meta` files under `dangerous_exposure_source/`, referenced explicitly by `wrapper_meta` or per-binding `meta` in Silica source. |
| Toolchain validation | No C parsing; Silica declarations + sidecar metadata + compile-time archive existence (`E4034`) + link-time symbol resolution. §15.2 wrapper-side C checks are authoring guidelines only. |
| Build integration | Prebuilt static wrapper libraries under `dangerous_exposure_source/lib/`; compiler emits `silica.link`; project Makefiles pass manifest `archive:` paths to the external linker. |
| De-taint | Strict structural taint. The only way to clear it is re-creation: a compiler-derived `recreate` for a type that declares `Recreatable` (§7.7). User-defined helpers never clear taint. |
| Pure actor state from FFI result casts | A client re-creates the payload inside the result-cast handler (§7.7). Only the re-created value may enter actor state, ordinary casts or `call` replies. |
| Region values from FFI result casts | Re-creation builds the value in a fresh region owned by the caller (§7.7). That region, not the worker's, becomes actor state. |
| Foreign call scheduling | Architecturally non-blocking via cast-only client and FFI worker actors; no `blocking` sidecar field. |

External languages calling into Silica is not a planned capability, so no inbound-interop specification exists or is expected.

---

## 17. Summary

Silica FFI is wrapper-first and cast-mediated.

External libraries are required to be adapted into a small, explicit, predictable C-compatible ABI subset before Silica calls them. Wrapper functions are required to use fixed-width types, pointer-plus-length strings, explicit result structs, de-opaqueified C object contents, and clear ownership rules. Wrapper object code is supplied initially as prebuilt static libraries under `dangerous_exposure_source/lib/`. Sidecar `.meta` files under `dangerous_exposure_source/` declare link libraries and wrapper facts and are loaded only when named by `wrapper_meta` or `meta` declarations in Silica source. After compile, `silica-compiler` writes **`silica.link`** naming required archives and foreign symbols for the `silica.config` closure; project build scripts link using those archive paths.

Application actors never call `dangerous_*` module functions directly. They use cast-only behaviors to send foreign-call requests to FFI worker actors. FFI worker actors are installed with `spawn_dangerous(...)` or `spawn_dangerous_registered(...)`, referenced by `dangerous_actor_ref`, and execute `sequence proc[external_danger] ... produces pure ... end` blocks inside their behavior functions. Install sites (`main`, supervisors, and ordinary client actors) call `spawn_dangerous` / `spawn_dangerous_registered` with `concurrency` only and must not declare `external_danger`. Atom-keyed worker lookup uses the **dangerous registry** and `cast_dangerous_registered`; the ordinary registry and `cast_registered` must not resolve FFI workers (§4.9). Every compilation unit that imports or uses a `dangerous_*` module must itself be a `dangerous_*` module; that constraint propagates to the root application module and to the compiled application name whenever the program depends on FFI.

Raw foreign bindings declare pointer-plus-length arguments for string data; exported adapter wrappers accept Silica `string`. The initial toolchain validates Silica declarations, explicit sidecar references, sidecar metadata contents, prebuilt archive presence when emitting `silica.link`, and link-time symbol presence in manifest-named archives. It does not parse C headers.

Any C array return maps to a Silica buffer. Any non-array C pointer must be converted to type before being sent to Silica. Any `void *` from the underlying library must be translated by wrapper code into an approved concrete Silica-facing representation before Silica sees it. Opaque C structs must be de-opaqueified into Silica-compatible contents, not exposed as handles, raw pointers, or opaque external types.

External-danger-touched data must not appear in the `produces pure` value of an `external_danger` sequence. It may appear only in FFI result casts executed from that sequence. Strict structural taint applies. External-danger-touched data must not cross ordinary actor `call` or `cast` boundaries and must not be used in sequence blocks declaring `device_io`, `network_io`, `hot_swap`, or `register_rwr`. The single exception is re-creation (§7.7): a compiler-derived `recreate` validates the data and builds a new, pure value, which may then go anywhere except `hot_swap`, command execution and code loading.
