# macOS Crash Handling for Compiled Language Runtimes

On macOS, a compiled language/runtime is allowed to **observe and intercept quite a lot**, but it is only safely allowed to **do very little directly inside the crash path**.

The useful distinction is:

```text
Can macOS deliver the fault to my runtime?        Often yes.
Can my runtime safely recover and continue?      Only in tightly controlled cases.
Can I safely run arbitrary cleanup code there?   No.
```

## Implementation status (2026-10-16)

This note is the design reasoning; the Apple Silicon runtime follows its signal-based half. What exists: `silica_rt_install_sync_fault_handlers` (`emitter/apple_silicon_mac/terms/ffi_fault_runtime_asm.silica`) installs the handler with `sigaction` (`SA_SIGINFO | SA_ONSTACK | SA_NODEFER`) for SIGSEGV, SIGBUS, SIGILL and SIGFPE, from the program's constructor list so it is in place before `main`, and gives every thread a `sigaltstack`; a guarded foreign call keeps a per-thread 512-byte state block with a `sigsetjmp` buffer, and a fault recognised inside the guarded call returns through `siglongjmp` to the call site, after which ordinary runtime code ends the actor and the supervisor sees an ordinary failure; a fault outside a guarded call, or a runtime abort, is the process report of spec §15.4.5.5 (`[silica] fault at 0x...` status 70, `[silica] abort: <reason> at 0x...` status 71) written without allocating, from a static stack; a guarded fault with no actor to deliver to ends the process with status 70 ([runtime_failure_reporting.md](runtime_failure_reporting.md) §3.1). Mach exception ports are not used. The Linux AArch64 and Linux x86-64 runtimes carry the same bridge in their own `ffi_fault_runtime_asm.silica`. The `extern unsafe` / `guarded` / `isolated` declarations in "Best Design for Silica on macOS" are illustrative syntax, not Silica source: the language surface is Fifi (`dangerous_*` modules, wrapper archives, `spawn_dangerous`; [silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md)), and no `ForeignFault` result type or isolated helper-process mode exists.

## What macOS Lets You React To

For native compiled code, macOS can report faults as Unix signals and/or Mach exceptions. Common ones include:

| Fault | Usually seen as | Meaning |
|---|---:|---|
| Invalid memory access | `SIGSEGV` / `EXC_BAD_ACCESS` | Bad pointer, protected page, unmapped memory |
| Bus error | `SIGBUS` | Bad memory access type/alignment/mapped-file issue |
| Illegal instruction | `SIGILL` | Invalid CPU instruction |
| Floating-point/arithmetic fault | `SIGFPE` | Some arithmetic traps, when hardware/runtime actually delivers a signal |
| Abort | `SIGABRT` | `abort()`, failed assertion, some runtime aborts |
| Trace/breakpoint | `SIGTRAP` | Debug trap, breakpoint, intentional trap |

At the C/runtime level you can install handlers with `sigaction`:

```c
sigaction(SIGSEGV, ...);
sigaction(SIGBUS, ...);
sigaction(SIGILL, ...);
sigaction(SIGFPE, ...);
sigaction(SIGABRT, ...);
```

You can also use `sigaltstack(...)` plus `SA_ONSTACK` in the `sigaction` flags so that a signal handler runs on an alternate stack. This improves the odds that your handler can run even when the normal thread stack is damaged or exhausted. The alternate stack is not isolation: it has a fixed size, does not grow like a normal stack, and can itself overflow if the handler does too much.

## What You Can Safely Do in a Signal Handler

Very little.

A signal handler is not a normal callback. You generally cannot safely:

```text
allocate memory
take locks
call Objective-C or Swift runtime machinery
format complex strings
walk dynamic loader state
throw normal language exceptions
run arbitrary cleanup code
```

A signal handler should be closer to this:

```c
static void handler(int sig, siginfo_t *info, void *ctx) {
    record_minimal_fault_info_without_calling_unsafe_apis();
    siglongjmp_to_prearranged_boundary_or_abort();
}
```

not this:

```c
static void handler(...) {
    printf("nice error");
    malloc(...);
    lock_mutex(...);
    throw_exception(...);
    call_silica_runtime();
}
```

For Silica, this implies:

```text
preallocate crash/fault records
avoid locks
avoid heap allocation
avoid runtime calls inside the handler
avoid TLS/runtime access that might allocate or lock
treat the handler as a tiny bridge back to a known recovery point
```

## Mach Exceptions

macOS is built on Mach, so low-level faults are also represented as Mach exceptions such as:

```text
EXC_BAD_ACCESS
EXC_BAD_INSTRUCTION
EXC_ARITHMETIC
EXC_BREAKPOINT
```

A runtime can use Mach exception handling through exception ports. Sophisticated runtimes, debuggers, profilers, crash reporters, and sandbox/JIT systems sometimes do this.

However, Mach exceptions are not a magic “safe catch C crash” facility. They are lower-level, thread-state-oriented, and can interfere with debuggers or crash reporters if exceptions are not forwarded correctly. Modern macOS also has hardened-runtime and Mach IPC restrictions that can affect who may set exception ports and what exception behaviors are permitted.

For Silica, `sigaction` is probably the better starting point unless you specifically need precise control over thread state.

## Can You Resume Execution?

Sometimes, but only when the fault is part of a design you control.

For example, runtimes often intentionally protect pages and then recover from the fault:

```text
access guard page
→ SIGSEGV / EXC_BAD_ACCESS
→ runtime recognizes the address
→ grow stack, commit page, or report bounds trap
→ resume or jump to runtime trap handler
```

That is legitimate because the runtime knows:

```text
which page faulted
why it faulted
what invariant still holds
how to resume or abort the current computation
```

For arbitrary C FFI, you usually do **not** know that. The C code may already have corrupted valid memory before the fault occurred.

In this document, “FFI arena” means a runtime-managed scratch containment area for guarded FFI: copied inputs, output buffers, temporary C-facing memory, and metadata that can be discarded or reset if the guarded call faults. It may be backed by a Silica memory region, but it is not automatically the same thing as a user-visible Silica memory region unless the runtime explicitly specifies that relationship.

A realistic recovery model is:

```text
safe-ish:
  fault inside guarded FFI region
  handler verifies fault address / state
  abandon current Silica fiber/task
  reset FFI arena
  return to scheduler only if the runtime can prove the surrounding process state is still trustworthy
  report actor failure through the normal supervision path

not safe:
  fault anywhere
  throw normal Silica exception
  continue as if nothing happened
  terminate or restart an actor directly inside the signal handler
```

If the guarded FFI call occurs while running a Silica actor, the intended model is:

```text
fault in guarded FFI call
→ tiny signal/Mach bridge records preallocated fault data
→ bridge exits to a prepared runtime boundary
→ normal runtime code marks the actor as failed
→ supervisor receives the ordinary failure/exit signal
→ supervisor policy may restart the actor
```

The signal handler must not do actor lifecycle work itself. It must not acquire scheduler locks, allocate failure messages, send supervisor notifications, run Silica cleanup code, or restart the actor. Those actions belong in ordinary runtime code after control has returned to a known recovery boundary.

## What macOS Will Not Let You Reliably Catch

You cannot reliably catch or recover from everything.

Examples:

```text
SIGKILL
```

Cannot be caught or handled.

```text
memory corruption that does not fault
```

If C writes to the wrong but still-valid address, macOS has nothing to report.

```text
deadlocks
```

No signal is generated.

```text
infinite loops
```

You need a watchdog, timeout, separate thread, separate process, or cooperative checks.

```text
corrupted malloc/runtime/global state
```

The eventual crash may happen later, far away from the original FFI call.

```text
Objective-C / Swift exceptions
```

These are not the same thing as Unix signals or Mach exceptions. They are language/runtime mechanisms and should not be treated as a containment boundary for unsafe C memory faults.

## Practical macOS Techniques

| Technique | macOS allows? | Good for | Safe recovery? |
|---|---:|---|---:|
| `sigaction` handlers | Yes | Detecting `SIGSEGV`, `SIGBUS`, `SIGILL`, etc. | Only carefully |
| `sigaltstack` + `SA_ONSTACK` | Yes | Handling faults when normal stack is bad | Helps, not isolation |
| `sigsetjmp` / `siglongjmp` | Technically possible | Escaping a guarded region | Dangerous unless tightly controlled |
| Mach exception ports | Yes, advanced and permission-sensitive | Debugger/runtime-level fault handling | Possible, complex |
| Page protection with `mprotect`/`mmap` | Yes | Guard pages, protected arenas, JIT tricks | Good for designed traps |
| Recovering arbitrary C corruption | No reliable guarantee | N/A | No |
| Catching `SIGKILL` | No | N/A | No |
| Doing rich runtime work in signal handler | Effectively no | N/A | No |

## Best Design for Silica on macOS

A good design for Silica would be a “guarded FFI” mode with an explicit contract:

```text
Silica can make a best-effort attempt to detect certain native faults that occur
during a guarded FFI call. If the fault is recognized as occurring inside a
constrained FFI region, and the runtime can still trust its scheduler state,
Silica may terminate the current Silica task/fiber and return a ForeignFault.
Silica does not guarantee recovery from arbitrary memory corruption caused by C.
```

For actor code, this means guarded FFI may be converted into actor death, not into ordinary in-place continuation:

```text
guarded FFI inside actor = sometimes convertible to actor failure
supervisor restart       = allowed only after normal runtime recovery code runs
signal handler           = records and escapes; it does not supervise
```

Implementation shape:

```text
1. Install signal handlers early with `sigaction`.
2. Use `sigaltstack` and `SA_ONSTACK`.
3. Keep preinitialized per-thread FFI state reachable without calling unsafe runtime APIs:
   - currently_inside_ffi
   - recovery jump buffer or scheduler continuation
   - active FFI arena bounds
   - active FFI function metadata
4. Use a restricted ABI:
   - no raw VM object pointers
   - copied buffers or handles
   - dedicated FFI arena, possibly backed by a Silica memory region but not identical to user-visible region ownership unless explicitly specified
   - no callbacks into arbitrary Silica runtime code
   - no C-created threads touching Silica runtime state
5. Optionally protect VM heap/guard pages with mprotect.
6. On fault:
   - handler checks thread-local state
   - records minimal fault info
   - jumps to a prearranged recovery point or aborts
7. Recovery path kills the current Silica task or actor, resets the FFI arena, and resumes the scheduler only when runtime invariants still hold; otherwise the process aborts.
8. Actor supervisors observe this as ordinary actor failure/exit and may restart according to their normal policy.
```

The guarantee should be “task death,” not “ordinary exception from arbitrary C.”
For actor-hosted FFI, the guarantee should be “actor failure if the runtime can still trust itself,” not “the actor is always restartable.”

This requires the runtime to enter guarded FFI without holding scheduler or actor-system locks that the recovery path would need. It also requires actor state touched by C to be disposable or confined to the FFI arena. If that arena is backed by a Silica memory region, ordinary region ownership rules still apply at the Silica boundary; the arena's crash-containment role is an implementation discipline, not a license for C to hold arbitrary region aliases. If C corrupts shared runtime state, heap allocator state, another actor's memory, or scheduler structures before the fault is detected, the process should abort instead of pretending supervision can repair it.

A plausible language-level distinction:

```silica
extern unsafe c fn fast_hash(ptr: Ptr<u8>, len: usize) -> u64
extern guarded c fn decode_image(input: Bytes) -> Result<Image, ForeignFault>
extern isolated c fn run_plugin(input: Bytes) -> Result<Bytes, ForeignCrash>
```

On macOS:

```text
unsafe   = direct native call
guarded  = same process, best-effort signal/Mach fault detection at prepared FFI boundaries, restricted ABI
isolated = helper process
```

## Bottom Line

macOS allows a compiled runtime to react to **many synchronous native faults**:

```text
bad memory accesses
illegal instructions
arithmetic traps
aborts
breakpoints
```

It also gives you both Unix signal handling and lower-level Mach exception mechanisms.

But macOS does **not** make arbitrary C FFI safely recoverable. The safe design is to react only at carefully prepared FFI boundaries, do almost nothing inside the handler, and convert recognized faults into **Silica task failure**, not a normal resumable exception.
