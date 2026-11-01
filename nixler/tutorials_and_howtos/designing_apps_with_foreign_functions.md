# Designing Silica Apps That Use Foreign Functions

This tutorial is for software engineers who are new to Silica and need to build an app that calls C or another library with a C-compatible ABI.

The goal is not to make foreign code look safe. The goal is to design the app so the dangerous part is easy to find, small enough to review, and isolated behind actors, casts, wrappers, metadata, and supervision.

For the lower-level build recipe, see [ffi_wrappers_and_makefiles.md](./ffi_wrappers_and_makefiles.md). For the formal rules, see [silica_ffi_wrapper_specification.md](../design_documents/silica_ffi_wrapper_specification.md). For the security-review model, see [dangerous_ffi_security_model.md](../design_documents/dangerous_ffi_security_model.md).

---

## The Short Version

When a Silica app must use foreign functions:

1. Keep ordinary app logic in ordinary modules as much as possible.
2. Put each foreign library behind a small C wrapper library.
3. Put Silica foreign declarations in a small number of `dangerous_*` modules.
4. Do not call `dangerous_*` functions from ordinary app logic.
5. Start one or a few dedicated FFI worker actors with `spawn_dangerous`.
6. Make those workers cast-only.
7. Send requests to the workers by `cast`.
8. Execute wrapper calls only inside the worker's `sequence proc[external_danger] ... produces pure ... end`.
9. Send results back by cast.
10. Launch dangerous workers under supervisors so recognized actor failure can follow ordinary restart or escalation policy.

The design pressure should always be toward fewer dangerous locations, not toward sprinkling foreign calls throughout the app.

---

## First Concepts

### What is a foreign function?

A foreign function is code outside Silica that Silica calls through a C-compatible ABI. It may be written in C, or in another language that exposes C ABI symbols.

Silica does not call the original library API directly. You write or provide a small C wrapper that adapts the library into the ABI shape Silica expects.

### What does `dangerous_*` mean?

`dangerous_*` is Silica's visible marker for modules that declare, expose, import, or use outbound foreign code.

If any module depends on a `dangerous_*` module, it must also be named `dangerous_*`. This naming rule propagates up to the root app module.

That does not mean every file should contain foreign calls. It means the app is honestly marked as depending on foreign code. You should still keep the actual foreign declarations, wrapper calls, and FFI worker behaviors in a small number of places.

### What is an actor?

An actor is a concurrent unit with its own state and mailbox. Other actors communicate with it by sending messages.

For FFI, this matters because foreign calls are not ordinary direct function calls from app code. They are routed through dedicated FFI worker actors.

### What is `cast`?

`cast` sends a message without waiting for a reply. FFI workers use cast-shaped message flow:

```text
app actor
  cast request
    -> FFI worker actor
      foreign call
      cast result
        -> result receiver actor
```

This keeps the foreign work behind an actor boundary instead of making it feel like a normal local function call.

### What is `external_danger`?

`external_danger` is the effect used for actually executing a foreign wrapper call. It is valid only inside the FFI worker actor behavior passed directly to `spawn_dangerous`.

Installing a dangerous actor does not require `external_danger`. Executing the wrapper call does.

---

## The App Shape You Want

A good FFI app usually has this shape:

```text
safe-ish app logic
  domain modules
  validation modules
  ordinary actors
  UI/API/device/network edge

foreign boundary
  dangerous_* adapter module
  sidecar metadata
  prebuilt wrapper archive
  dangerous FFI worker actor
  supervisor for the worker

external world
  C wrapper code
  underlying C-compatible library
```

Even though the root app may need a `dangerous_*` name because of transitive dependency rules, your code organization should still make the real boundary obvious.

Good containment:

```text
dangerous_image_app.silica
image_pipeline.silica
image_validation.silica
dangerous_image_worker.silica
dangerous_image_codec.silica
dangerous_exposure_source/
```

Poor containment:

```text
dangerous_image_app.silica
dangerous_image_routes.silica       # directly calls C wrapper
dangerous_user_profiles.silica      # directly calls C wrapper
dangerous_thumbnail_jobs.silica     # directly calls C wrapper
dangerous_report_export.silica      # directly calls C wrapper
dangerous_email_templates.silica    # directly calls C wrapper
dangerous_exposure_source/
```

The first shape gives reviewers one or two places to inspect. The second shape turns the whole app into an FFI search problem.

---

## Recommended Design Pattern

Use four layers.

### 1. C wrapper layer

This is C code, not Silica code. It adapts the real library into a small, boring ABI.

Prefer:

- fixed-width integer types like `int64_t` and `uint64_t`;
- pointer-plus-length for strings and byte buffers;
- explicit result records for errors;
- clear ownership and release rules.

Avoid:

- `void *` handles exposed to Silica;
- raw library structs exposed directly;
- callbacks into Silica;
- C-created threads that touch Silica runtime state;
- retained borrowed pointers into Silica actor memory.

### 2. `dangerous_*` adapter module

This Silica module declares raw `foreign c_wrapper` bindings and exports small adapter functions.

Keep this module boring. It should not contain business logic.

```silica
module dangerous_image_codec;

export decode_png/1;

wrapper_meta "dangerous_exposure_source/image/silica_image_codec.meta";

foreign c_wrapper "silica_image_decode_png"
fn decode_png_raw(bytes_ptr: uint8_ptr, bytes_len: uint64) -> ImageDecodeResult;

fn decode_png(input: string) -> ImageDecodeResult {
    decode_png_raw(input)
}
```

The exact string and buffer syntax will follow the current compiler rules. The important design point is that raw foreign declarations stay here, not across the app.

### 3. Dangerous FFI worker actor

This actor is the only Silica code that executes the adapter call.

It must be spawned with `spawn_dangerous`, must use a cast-only behavior, and must call the adapter only inside `external_danger`.

```silica
module dangerous_image_worker;

use dangerous_image_codec;

fn image_worker_behavior(msg: DecodeRequest, state: ImageWorkerState) -> (:no_reply, ImageWorkerState) {
    sequence proc[external_danger, concurrency]
        result: ImageDecodeResult <- dangerous_image_codec@decode_png(msg.bytes);
        cast(msg.reply_to, {
            request_id: msg.request_id,
            result: result
        });
    produces
        pure (:no_reply, state)
    end
}
```

The key rule: every wrapper call goes through this worker shape. Do not make little convenience calls to the dangerous adapter from random modules.

### 4. Ordinary application actors

Ordinary application actors send requests to the FFI worker by cast. They do not call the dangerous adapter directly.

```silica
fn upload_handler_behavior(msg: UploadMessage, state: UploadState) -> (:no_reply, UploadState) {
    sequence proc[concurrency]
        cast(state.image_worker, {
            request_id: msg.request_id,
            bytes: msg.upload_bytes,
            reply_to: self()
        });
    produces
        pure (:no_reply, state)
    end
}
```

This keeps the rest of the app actor-shaped. The upload handler asks for foreign work; it does not become foreign work.

---

## Supervise Dangerous Workers

Production Silica actors should be designed with supervision in mind, and dangerous FFI workers especially should be launched under a supervisor.

When available on the platform, Silica's guarded FFI implementation can trap recognized native faults such as `SIGSEGV`, `SIGBUS`, `SIGILL`, and other configured synchronous native faults that occur inside a prepared guarded FFI boundary. The signal handler does not restart actors. It records minimal fault information and exits to a safe runtime boundary.

After control returns to ordinary runtime code, the dangerous actor is terminated as failed. If it was launched under a supervisor, the supervisor follows its configured rules: restart, stop, restart related children, or escalate.

That gives you this design:

```text
supervisor
  starts dangerous FFI worker

dangerous FFI worker
  receives casts
  executes wrapper calls
  terminates on recognized guarded FFI fault

supervisor policy
  restarts or escalates
```

Do not design the app so business actors depend on a dangerous worker always surviving. Design request/retry/error paths as if the worker can die between messages.

Important caveat: this is not a guarantee that arbitrary C corruption can be repaired. If foreign code corrupts shared runtime state, another actor's memory, allocator state, or scheduler state, the process should abort. For untrusted native code, use brokered IPC or a helper process instead of same-process FFI.

---

## Actor Stack and Foreign Call Storage

Wrapper calls execute in the dangerous actor's execution context.

Current FFI marshaling gives C-facing arguments and temporary data scratch storage associated with the FFI worker actor, such as actor-stack scratch for copied string input before passing pointer-plus-length arguments. Guarded FFI also uses a per-actor FFI arena where available for copied inputs, output buffers, temporary C-facing memory, and metadata that can be discarded or reset after a guarded fault.

This is part of the containment story:

- the application actor does not hand its own stack directly to C;
- C-facing bytes are staged in the dangerous worker's call context;
- guarded FFI can discard the worker's scratch or arena state when the actor fails;
- ordinary Silica region ownership rules still apply at the Silica boundary.

This does not make C safe. It narrows what you intentionally expose.

---

## How to Decide How Many FFI Workers You Need

Start with one worker per foreign subsystem.

Use one worker when:

- the library is small;
- calls are fast;
- calls share one configuration;
- ordering matters;
- all calls have similar failure behavior.

Use multiple workers when:

- one library call can block for a long time;
- different calls need different restart policies;
- different calls use different external libraries;
- failures should be isolated from each other;
- you need separate throughput lanes.

Examples:

```text
Good:
  dangerous_image_codec_worker
  dangerous_audio_codec_worker
  dangerous_database_worker

Maybe too broad:
  dangerous_everything_worker

Usually too scattered:
  one dangerous worker per app feature when all call the same library in the same way
```

The goal is not "one worker forever." The goal is a small number of meaningful dangerous boundaries.

---

## What Not To Do

Do not do this:

```silica
fn render_profile_page(user: User) -> Html {
    thumbnail <- dangerous_image_codec@decode_png(user.avatar);
    ...
}
```

That makes an ordinary business function execute foreign code directly.

Do this instead:

```text
profile page actor
  cast decode request
    -> dangerous image worker
      dangerous_image_codec@decode_png(...)
      cast decode result
        -> profile page actor
```

Do not hide dangerous calls behind innocent names:

```silica
fn normalize_image(bytes: string) -> Image {
    dangerous_image_codec@decode_png(bytes)
}
```

That spreads danger under a friendly API. Prefer a boundary name that tells the truth:

```silica
fn request_decode_from_image_worker(worker: dangerous_actor_ref, request: DecodeRequest) {
    cast(worker, request)
}
```

---

## Review Checklist for Non-Security Specialists

Before adding a foreign library, ask:

- Can this be done in Silica instead?
- Can this be done with brokered IPC instead of same-process FFI?
- What is the smallest wrapper API the app needs?
- Which single module declares the foreign bindings?
- Which actor executes those bindings?
- Which supervisor owns that actor?
- What should happen if the dangerous actor dies?
- Can callers retry safely?
- Are request and result messages explicit records instead of vague blobs?
- Does foreign data become trusted too early?
- Are raw pointers, handles, callbacks, or C-owned lifetimes leaking into Silica?
- Can reviewers find all foreign calls with one or two searches?

A good test: a new engineer should be able to answer "Where does this app touch C?" in under a minute.

---

## Suggested Project Layout

```text
my_app/
  dangerous_my_app.silica                 # root module, dangerous because dependency propagates
  app_routes.silica                       # ordinary app logic if it has no direct dangerous imports
  image_pipeline.silica                   # ordinary processing logic
  dangerous_image_codec.silica            # raw foreign binding + small adapter
  dangerous_image_worker.silica           # only place that executes image foreign calls
  dangerous_image_supervisor.silica       # starts/restarts the worker
  dangerous_exposure_source/
    image/
      silica_image_codec.meta
      silica_image_codec_wrapper.h
    src/
      silica_image_codec_wrapper.c
    lib/
      libsilica_image_codec.a
```

Depending on exact module dependencies, more modules may need the `dangerous_` prefix. That is fine. The app should still keep actual foreign declarations and wrapper calls in the adapter and worker modules.

---

## A Practical Build Order

1. Design the smallest foreign API the app needs.
2. Write the C wrapper header and implementation.
3. Write sidecar metadata under `dangerous_exposure_source/`.
4. Build the wrapper static archive.
5. Write one `dangerous_*` adapter module with raw `foreign c_wrapper` declarations.
6. Write a dangerous FFI worker actor that calls the adapter inside `external_danger`.
7. Add a supervisor that starts the worker.
8. Change ordinary app actors to send cast requests to the worker.
9. Add tests for successful calls, failed library results, worker death, and restart behavior.
10. Review whether any dangerous calls escaped the worker boundary.

The companion build tutorial, [ffi_wrappers_and_makefiles.md](./ffi_wrappers_and_makefiles.md), shows the wrapper archive, sidecar, and Makefile details.

---

## Final Rule of Thumb

Foreign functions should feel like crossing a border.

You should know:

- where the border is;
- who is allowed to cross it;
- what data crosses it;
- who watches that border actor;
- what happens when it fails.

In Silica, that border is the combination of `dangerous_*` modules, C wrappers, sidecar metadata, `spawn_dangerous`, cast-only FFI worker actors, `external_danger`, actor-local FFI scratch storage, and supervisors.
