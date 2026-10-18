# Runtime failure reporting: one report, every target

Status: implemented 2026-09-19 in all four emitter trees (`apple_silicon_mac`, `linux_aarch64`,
`linux_x86_64`, `ESP32-S3_raw`) and the ESP32-S3 board runtime. Verified on the Mac; the Linux and x86-64
runtime text is assembled but not yet run on its hosts; the board runtime is assembled and linked into
images but not yet run on the board. The follow-up decisions of the same day (handlers installed by the
startup code, a last-resort path for a fault inside the handler, `_exit` on every process-fatal path, and
the two paths that used to exit 1) were implemented in defect batch 2 (§6).

**Implementation status (2026-10-16).** The runtime text has since been run on every target: the Linux
AArch64 and x86-64 runtimes through their fixed points and trial suites, the board runtime through the board
trial suites and apps (the stack-guard app, the device-actor fault details of §3.2). The board has an actor
runtime and two cores since 2026-09 (an actor's fault ends the actor; only `main`, the scheduler and the
runtime's own code take the process-fatal path), so the earlier statements below that the board has no actor
runtime describe the 2026-09-19 state and are corrected in place. The non-fatal path, the report an actor's
death delivers to the `FailureReporter`, is described in §7.

The contract is normative in the specification, **§15.4.5.5 Process-Fatal Reports and Exit Status**
([silica-specification.md](silica-specification.md)). This document is non-normative: it describes how each
target meets that contract, so that a program that ends abnormally reports it the same way whether it
runs on macOS, Linux (AArch64 or x86-64) or bare metal on the ESP32-S3.

## 1. The contract

| Class | Report (one line) | Exit status |
| --- | --- | --- |
| Fatal fault: a synchronous CPU exception the program cannot survive (§15.4.4 gate fails, a fault outside any actor, including exhausting `main`'s stack, a fault in trusted runtime code) | `[silica] fault at 0x<pc>` + ` in <symbol>+0x<offset>` where available + `  addr=0x<fault address>` + `  actor=0x..  sbase=0x..  ssize=0x..` on targets with actors | **70** |
| Runtime abort: a runtime check the program cannot continue from, a resource the runtime cannot obtain (memory to commit for a growing actor stack, §15.4.10.2), a containment failure not raised by hardware | `[silica] abort: <reason> at 0x<pc>` + ` in <symbol>+0x<offset>` where available | **71** |
| Language-level failure in `main` (`case_clause`, `badarith`) | the atom name | 1 |
| Actor failure (a fault or stack exhaustion inside an actor that the runtime recovers, every exit reason of §15.4.11) | none: delivered through supervision (§15.4.4, §15.4.10) | not a process exit |

What the rules mean in practice:

- **Nothing ends a Silica process through C `abort()` (SIGABRT, status 134) or a default signal action
  (status 139).** Every call to `abort()` the runtime and the emitted code used to make is now a runtime
  abort (§4). Where the specification says the process "aborts" when containment fails, the process ends
  with a fatal fault report (status 70) when the hardware raised the failure, and with a runtime abort
  (status 71) when the runtime did (the host refusing to commit memory for a growing stack).
- **Hosted targets write the report on standard error. The OS-free target writes it on the console as
  program output**, just before the console's exit marker, which carries the status. The trial harness
  captures a hosted program's stdout and stderr in one `.sout`, so the two forms compare equal.
- **Fields a target cannot supply are left out, not made up.** See §2.
- **Every `0x` value is opaque.** Tools that compare reports fold them (§5).

## 2. What each target prints

| | `apple_silicon_mac` | `linux_aarch64` | `linux_x86_64` | `ESP32-S3_raw` (board) |
| --- | --- | --- | --- | --- |
| Where | stderr | stderr | stderr | UART0 as program output, then `\x02SILICA:EXIT:<status>\x03` |
| `0x<pc>` width | 16 digits | 16 | 16 | 8 |
| ` in <symbol>+0x<offset>` | yes: `dladdr` names the nearest preceding exported symbol | only when the address is exactly a symbol's start: the ELF symbols the emitters write have no `.size`, and glibc's `dladdr` matches a size-0 symbol only at its address | as `linux_aarch64` | never: no symbol table on the board |
| `  addr=0x..` (fault) | `si_addr` | `si_addr` | `si_addr` | `EXCVADDR`, only for the exception causes that set it (2, 3, 9, 12-18, 20, 24-26, 28, 29); a stack-guard hit (a data breakpoint, cause 1006) has none |
| `  actor=  sbase=  ssize=` (fault) | yes (zero outside an actor) | yes | yes | never: the board's fatal report carries no actor fields (an actor's own fault is an actor failure, §7) |
| After the report | exit | exit | exit | exit marker; for a fault, the board-only details after it: ` fault: exccause=<n> epc=0x.. excvaddr=0x..` and ` (stack guard: ...)` for cause 1006, which `run_on_board.py` sends to stderr |

Examples. A stack overflow in `main` (trial `actor_stacks_addition/stack_overflow_in_main`):

```
[silica] fault at 0x0000000102d41690 in m_down+0x0000000000000024  addr=0x000000014d0c3ff0  actor=0x0000000000000000  sbase=0x0000000000000000  ssize=0x0000000000000000
70
```

on the Mac, and on the board (app `silica_08_stack_guard`):

```
[silica] fault at 0x4037a1b4
\x02SILICA:EXIT:70\x03 fault: exccause=1006 epc=0x4037a1b4 excvaddr=0x00000000 (stack guard: machine or auxiliary stack overflow)
```

A list index past the end (trial `list_addition/list_at_out_of_range_aborts`, app `silica_15_list_index_abort`):

```
[silica] abort: list index out of range at 0x0000000104b2dc80 in main+0x0000000000000548
71
```

The symbol is the nearest exported one: `L_list_at_helper` is a local label emitted after `main`, so an
address inside it reads `main+0x548`. The pc of an abort is the address of the call into the abort
routine, never its return address, so a call that is the last instruction of a function is not
attributed to the function after it.

## 3. How the sameness is achieved

### 3.1 Hosted targets (macOS, Linux AArch64, Linux x86-64)

**Signals.** `silica_rt_install_sync_fault_handlers` (`emitter/<target>/terms/ffi_fault_runtime_asm.silica`)
installs `silica_rt_sync_fault_handler` with `sigaction` for SIGSEGV, SIGBUS, SIGILL and SIGFPE
(`SA_SIGINFO | SA_ONSTACK | SA_NODEFER`) and gives the installing thread a 64 KB `sigaltstack`. Each actor
thread gets its own 64 KB alternate stack (ACB +352). **The startup code installs the handlers before
`main` runs**: the same module puts the install routine in the program's constructor list
(`__DATA,__mod_init_func` on Darwin, `.init_array` on Linux), which dyld or the C runtime runs before
`main`, so a fault in `main`'s prologue, or in anything else that runs before `main`'s body (a foreign
library's constructor), is reported like any other. The calls from `silica_rt_actor_spawn` and from
`main`'s prologue (the emitter injects `_silica_pid_registry_init`) remain and return at once (the
installed flag). A stack overflow in `main` faults on the guard page below the main thread's stack and the
handler runs on the alternate stack.

`SA_NODEFER` keeps a signal deliverable while its own handler runs. Without it the signal is blocked there,
and a synchronous fault on a blocked signal is not delivered: the kernel ends the process with the default
action (status 139).

**The decision** (spec §15.4.5.3), in `silica_rt_sync_fault_handler`:

0. **a fault raised while a handler runs on this thread takes the last-resort path**
   (`silica_rt_fault_in_handler`, `silica_rt_fault_last_resort`; spec §15.4.5.5). The test is whether the
   interrupted stack pointer, read from the `ucontext`, lies on this thread's alternate signal stack
   (`sigaltstack(NULL, &ss)`): only the handler, and the runtime code it calls or leaves the thread in
   (`silica_rt_actor_fail_current`, the guarded-FFI teardown), runs there. The comparison is strict at
   both ends. An actor's execution stack is often mapped directly below that thread's alternate stack,
   so the top of the reservation *is* the alternate stack's base, and the growth fault of a behavior's
   first push interrupts code whose stack pointer is exactly that base; with an inclusive bound every
   actor's first message was reported as a fault inside the handler
   (`actor_stacks_addition/stack_many_idle_actors_hold_nothing` caught it). The last resort writes
   `[silica] fault at 0x<pc>  addr=0x<fault address>` with `write(2)` and ends with `_exit(70)`: no `dladdr`
   (it takes the loader's lock, which the faulting handler may hold, and it may be what faulted), no TLS,
   no actor fields. The line may follow part of the first handler's line; the report tools fold everything
   after the first `[silica] fault at ` on a line (§5), so it compares the same.

   Why this test and not the alternatives: a per-thread "in handler" flag needs TLS the handler can
   reach without allocating, and it stays set when the handler leaves by `siglongjmp` (guarded-FFI
   recovery, an actor failing on `:stack_exhausted`) unless every such exit clears it; the stack pointer
   test keeps no state, so nothing can go stale. `SA_RESETHAND` resets the action for the whole process,
   which would take stack growth away from every other actor thread while one thread reports. A second
   handler would still need this test to know it was nested.
1. a fault inside the current actor's reservation is stack growth (`silica_rt_stack_grow_to`): grown,
   return; the end of a reservation the program lowered, the actor fails with
   `(:explicit, :stack_exhausted)` (supervision, not a process report); **the host refused to commit
   memory: runtime abort** `cannot commit memory for a growing actor stack`, status 71, reported at the
   faulting pc read from the `ucontext` (§15.4.10.2);
2. only now are the report fields recorded: the pc (`ucontext`), the fault address (`si_addr`), the current
   actor and its stack reservation (zero outside an actor). They are process-wide, and until 2026-09-19
   they were recorded on entry, so an actor taking growth faults on another thread could overwrite them
   while `main` was reporting its own fault (seen as a stack overflow in `main` reported with an actor's
   pc, address and stack);
3. a fault inside a guarded FFI call is recovered (`siglongjmp`) and becomes an actor failure;
4. anything else is a **fatal fault**: `silica_rt_print_fault_site` writes the report line from the
   recorded fields (`dladdr` for the symbol), and the process ends with C `_exit(70)` (Darwin assembly
   `bl __exit`; `bl _exit` there is C `exit()`, which would run atexit handlers and flush stdio from inside
   the signal handler).

A guarded foreign fault recovered when **no actor is current** has no supervisor to deliver it to:
`silica_rt_ffi_guarded_fault_finish` (`L_gff_process`) writes the fault report line from the fields the
handler recorded before its `siglongjmp` and ends with `_exit(70)`. It used to print `foreign_fault` and exit 1.
Silica source cannot make a guarded call outside an actor (the call must be the root body of a
`spawn_dangerous` behavior), so only foreign code driving the runtime entries reaches it; trial
`ffi_addition/app_process_fatal_paths/foreign_fault_without_actor` does.

**Runtime aborts.** One routine per target, in the same module as the fault report so that it shares the
output helpers (`silica_rt_fault_puts`, `silica_rt_fault_puthex`, the `dladdr` buffer):

- `silica_rt_abort_with(reason)` (Darwin `_silica_rt_abort_with`): the reason is a NUL-terminated string;
  the reported pc is the call instruction (AArch64 `X30 - 4`, x86-64 the return address `- 5`).
- `silica_rt_abort_with_pc(reason, pc)`: the same with an explicit address (used by the fault handler for
  the stack-commit abort).
- One entry per site, `silica_rt_abort_<site>`, which loads its reason and branches to
  `silica_rt_abort_with` with the return address untouched. Emitted code and hand-written runtime call
  these, so an abort site is one call instruction and the reasons live in one table per target.

`silica_rt_abort_with` is safe wherever the old `abort()` calls were: it allocates nothing and does not
run on the caller's stack. The first caller claims a word (`LDAXR`/`STLXR`, `xchg`) and moves onto a
static 32 KB stack, because the caller may be an actor at the very end of its reservation or the fault
handler on its alternate stack; a second caller on any thread parks (`yield` / `pause` loop) until the
process has gone. It writes `[silica] abort: <reason> at 0x<pc>`, then ` in <symbol>+0x<offset>` when
`dladdr` names the address, then a newline, with `write(2, ...)`, and ends with C `_exit(71)`
(Darwin `__exit`): async-signal-safe, no atexit handlers and no stdio flush, as the `abort()` it replaces.
Silica's own output never sits in a stdio buffer (the print helpers make the `write` system call), so no
Silica output is lost by skipping the flush. Every process-fatal path now ends this way (the fault report,
the last resort, the foreign fault with no actor). A normal exit (`main` returning, `wait_for_exit`) and
a language-level failure in `main` (`badarith`, `case_clause`, status 1) keep C `exit()`: they are not in a
signal handler, and flushing a foreign library's stdio buffers there is what a normal exit does.

A spawn whose stack reservation fails while `main` is the spawner (`silica_rt_spawn_reserve_failed`,
`prims_actors_stack_asm`) is a runtime abort, `stack reservation failed`, status 71 (spec §15.1.2.2),
reported at the spawn routine's call to `silica_rt_spawn_reserve_failed`. It used to print
`stack_reserve_failed` and exit 1.

### 3.2 The ESP32-S3 board (OS-free)

There are no signals. The runtime (`emitter/ESP32-S3_raw/board/runtime/`) installs its own vectors
(`rt_vectors.S`, VECBASE set by `rt_start.S`) and, for the two fixed stacks, data breakpoints over the
64-byte guard at the bottom of each (`DBREAKA0/1`, armed in `_start`): the 128 KB machine stack and the
64 KB auxiliary stack the emitter uses as `SP`. This is the "exception vectors + stack-guard data
breakpoints" form spec §15.4.5.1 names for OS-free targets.

**Fatal fault.** Every vector except the window overflow/underflow and alloca handlers goes to
`silica_rt_fatal_trampoline` with a cause code (EXCCAUSE for user exceptions, 1001-1008 for the kernel,
level-2..5, debug, NMI and double-exception vectors; the debug vector copies EPC6 to EPC1, so a stack-guard
hit reports the store that reached the guard). The trampoline abandons the faulting context (interrupts
off, only the current register window live, PS reset, the 2 KB fault stack) and calls
`silica_rt_fatal_report` (`rt_console.S`), which prints `[silica] fault at 0x<epc>`, adds
`  addr=0x<excvaddr>` for the causes that set EXCVADDR, ends the line, writes the exit marker with status
70, then the board-only details, and halts.

**Device-actor fault details (board only).** An actor started with `spawn_device` or
`spawn_device_registered` is flagged in its ACB (`ACB_DEVICE`, offset 192; set by
`silica_rt_actor_mark_device`, which the emitter calls right after the spawn, and by
`silica_rt_register_device_actor_named`). When such an actor ends on a CPU exception, the fault hook
(`silica_rt_actor_fault_hook`) has saved EXCCAUSE+1, EPC1 and EXCVADDR into the ACB (offsets 196/200/204; causes
from 1001 up, the runtime's own, are not saved), and the standard `=== Silica Actor Failure ===` block gains three
lines directly after `reason_tag`:

    exccause:        29 (StoreProhibited)
    epc:             0x40388019
    excvaddr:        0x00000018

The name is printed for the common causes (0 IllegalInstruction, 2 InstructionFetchError, 3 LoadStoreError,
6 IntegerDivideByZero, 9 LoadStoreAlignment, 20 InstrFetchProhibited, 28 LoadProhibited, 29 StoreProhibited)
and omitted for the rest. Non-device actors, and device actors that end for any other reason, print the block
unchanged, byte for byte. Hosts never have device actors (device actor specification, E2220), so the host
report has no such lines. A restarted device child that a supervisor spawns from a child row is not flagged
(rows carry no device flavor yet).

**Both cores (2026-10-16).** A fatal fault or runtime abort on either core stops the other. Each core has its own fault stack (2 KB) and its own fault counter (`silica_rt_fatal_depth`); the first core to claim the fatal-owner word stalls the other core through the RTC stall bits (RunStall) and then reports. The other core is stopped, so there is one report. The second fault stack costs 2 KB of heap.

**Runtime abort.** The entries `silica_rt_abort_with(reason)` and `silica_rt_abort_<site>()` (`rt_console.S`)
are windowed functions reached with CALL8. Each names its reason in `a2` and jumps to
`silica_rt_abort_body`, which turns the return address in `a0` into the address of the CALL8 (bits 31:30
of `a0` hold the window increment, so the real top bits are taken from a code address, then 3 is
subtracted) and calls `silica_rt_abort_trampoline` (`rt_vectors.S`). That resets the context exactly as
the fatal trampoline does and calls `silica_rt_abort_report` on the fault stack, which prints
`[silica] abort: <reason> at 0x<pc>` and ends with `silica_rt_exit(71)`. Nothing is allocated, so the
heap-exhausted abort is safe. `silica_rt_abort()` without a reason remains, as `runtime check failed`,
for code compiled before the per-site entries existed.

**A fault while a report is being written.** `silica_rt_fatal_depth` (a word in `.data`, so it reads 0
even before `rt_start` zeroes `.bss`) counts the entries into `silica_rt_fatal_trampoline` and
`silica_rt_abort_trampoline`. The first entry reports as above. A second one (a fault raised while a fatal
or abort report runs) goes to `silica_rt_fatal_nested`, which writes only `[silica] fault at 0x<epc>`
(`silica_rt_fatal_last_resort`, `rt_console.S`) and the exit marker with status 70 from a fresh fault stack;
a third one, a fault in that last resort, halts. Before this a report that faulted re-entered the trampoline,
which started the report again from the top, forever.

**Console protocol.** `rt_start.S` prints `\x02SILICA:START\x03` before `main`; `silica_rt_exit` prints
`\x02SILICA:EXIT:<status>\x03` and halts. `board/tools/run_on_board.py` prints the program's bytes followed
by the status on its own line, which is exactly the `.sout` form, and sends anything after the exit marker
to stderr. The report line is before the marker, so it is part of the `.sout`, as the host's stderr line
is.

## 4. The sites

Emitted code (host emitters `terms/prims/prims_memory.silica`, `terms/prims/prims_list.silica`; the ESP32
emitter's `prims_memory.silica`):

| Site | Entry | Reason |
| --- | --- | --- |
| `L_region_overflow` (the region allocator returned nothing) | `silica_rt_abort_region_overflow` | `region allocation failed` |
| `L_buf_invalid` (`alloc_buf` count negative, or its byte size overflows) | `silica_rt_abort_buf_invalid` | `invalid buffer size` |
| `L_buf_bounds` (buffer store or load index at or past the length) | `silica_rt_abort_buf_bounds` | `buffer index out of bounds` |
| `L_lat_oob` in `L_list_at_helper` (host) | `silica_rt_abort_list_index` | `list index out of range` |

Hosted runtime (`emitter/<target>/terms/`):

| Site | Entry | Reason |
| --- | --- | --- |
| `canonical_arena_runtime_asm`: key 0 / 512-entry table full / `malloc` failed | `silica_rt_abort_arena_key` / `_arena_full` / `_arena_nomem` | `canonical arena key is zero` / `canonical arena table is full` / `canonical arena allocation failed` |
| `ffi_guarded_runtime_asm`: `L_gffi_enter_abort` (per-thread guarded state not allocated) | `silica_rt_abort_guarded_ffi_state` | `guarded FFI state could not be allocated` |
| `prims_actors_runtime_asm` (x86-64: `_b`): `Lsie_abort`, supervision ingress at its 1024 bound | `silica_rt_abort_ingress_full` | `supervision ingress queue is full` |
| `prims_actors_runtime_asm` (x86-64: `_c`): `Lde_abort`, exit delivery into a supervisor's ingress at its bound | `silica_rt_abort_exit_queue_full` | `supervisor ingress queue is full (exit delivery)` |
| `ffi_fault_runtime_asm`: `L_sfh_unrecoverable` (host refused to commit a growing stack) | `silica_rt_abort_with_pc` at the faulting pc | `cannot commit memory for a growing actor stack` |
| `prims_actors_stack_asm`: `silica_rt_spawn_reserve_failed` with `main` as the spawner | `silica_rt_abort_stack_reserve` | `stack reservation failed` |

Board runtime (`board/runtime/`):

| Site | Entry | Reason |
| --- | --- | --- |
| `rt_list.S` `silica_rt_list_at`, index out of range | `silica_rt_abort_list_index` | `list index out of range` |
| `rt_ordering.S` `silica_rt_canonical_arena_lookup`, key 0 / table full | `silica_rt_abort_arena_key` / `_arena_full` | as on the host |
| `rt_string.S` `silica_rt_string_bad`, `rt_console.S` `silica_rt_print_string`: the tag word is not -1 | `silica_rt_abort_not_a_string` | `not a Silica string` |
| `rt_heap.S` `silica_rt_alloc`, heap exhausted (was: status 134 and a message after the marker) | `silica_rt_abort_heap_exhausted` | `heap exhausted` |
| emitted `L_region_overflow` / `L_buf_invalid` / `L_buf_bounds` | `silica_rt_abort_region_overflow` / `_buf_invalid` / `_buf_bounds` | as on the host |

The ESP32-S3 emitter tree still carries the AArch64 runtime chunks it was copied from
(`terms/ffi_fault_runtime_asm.silica`, `canonical_arena_runtime_asm`, `ffi_guarded_runtime_asm`,
`prims_actors_runtime_asm`). They are not emitted for this target (`emit_actor_runtime_module` writes a
marker only) and are edited in step with the Mac tree.

Reachable from Silica source today, and covered by a trial: the list index, the invalid buffer size, the
buffer index past the length (`memory_region_addition/buf_write_out_of_bounds_aborts`, `buf_read_out_of_bounds_aborts`),
the zero canonical-arena key, the fatal fault of a stack overflow in `main`, and `main`'s failed stack
reservation (`actor_stacks_addition/stack_reserve_failed_in_main`). Covered by a trial through a C probe
linked after the runtime (`ffi_addition/app_process_fatal_paths`): a fault before `main`, a fault inside
the fault handler, a guarded foreign fault with no current actor. Not reachable in practice: the
allocator failures (region, arena, guarded FFI state), a full supervision ingress (1024 pending entries),
and the stack-commit refusal. **The buffer bounds check is emitted** (since 2026-09-19): `alloc_buf` stores the
element count in the word below element 0 (`prims_memory@emit_alloc_buf`) and every store and load compares the
index against it (`emit_buf_bounds_check`) and branches to `L_buf_bounds`. Before that the store only checked
when its SIR node carried a `|bounds:` marker, which no program produced.

## 5. Comparing reports

Because the addresses change from run to run, and the fields after the pc change from target to target,
every tool that compares a report folds it first with `trials/normalize_fatal_reports.awk`:

```
[silica] fault at 0x<pc>...           ->  [silica] fault at <PTR>
[silica] abort: <reason> at 0x<pc>... ->  [silica] abort: <reason> at <PTR>
```

A fault line keeps only its class, an abort line its class and reason; every other line is compared as
before (`diff -Bw`). The match is not anchored, so a report that follows program output without a newline
is folded too. Goldens are written by hand in the folded form, which the rule leaves unchanged.

Where it is applied:

- **Trial suites** that contain such trials use the per-suite hook `compare_scout_normalized.sh` (the
  convention `supervisors_addition` and `ffi_addition` already had): `actor_stacks_addition`,
  `list_addition`, `memory_region_addition`. Their Makefiles compare every trial's `.sout` with its
  `.scout` through it. `ffi_addition`'s own script (pointer fields of actor-failure banners) folds the
  report lines too since defect batch 2, for `app_process_fatal_paths`.
- **Board trial runs** (`trials/targets/board_suite.sh`) use the suite's `compare_scout_normalized.sh` when
  it has one, so the same `.scout` holds on the host and on the board.
- **Board apps**: `board/tools/host_reference.sh` writes `expected.scout` in the folded form, and
  `board/tools/compare_sout.sh <run.sout> <app>/expected.scout` compares a board run with it.
- **The x86-64 ladder** (`emitter/linux_x86_64/ladder/README.md`) folds both sides before its `diff`.

## 6. Limits

- **Implemented in defect batch 2 (2026-09-19)** (spec §15.4.5.5 as updated): the fault handlers are installed by
  the startup code before `main` runs (§3.1), and a fault raised inside the handler takes the last-resort path
  (line + 70; §3.1 step 0, §3.2). Every process-fatal path ends with the async-signal-safe `_exit` (in Darwin
  assembly `bl __exit`; `bl _exit` there is C's `exit()`; Linux spells them `_exit` and `exit`). Trials:
  `ffi_addition/app_process_fatal_paths` (`fault_before_main`, `fault_inside_handler`,
  `foreign_fault_without_actor`). The Linux AArch64 and x86-64 text is assembled, not yet run on those hosts;
  the board text is assembled and linked into images, not yet run on the board.
- The last-resort test needs the thread to have an alternate signal stack. Every thread the runtime creates has
  one; a thread created by foreign code does not, and a fault inside the handler on such a thread still ends
  with status 139. So does a fault that exhausts the 64 KB alternate stack itself: the kernel cannot deliver
  the signal at all.
- Two reports at once (two threads failing together) can interleave their lines; only the first abort
  reports, but a fault on another thread does not take the abort's claim word.
- On Linux the symbol is missing from most reports until the emitters write `.size` for their functions.
- On the board a CPU exception in an actor ends only that actor (`silica_rt_actor_fault_hook`; a stack-guard hit in an actor ends it with
  `(:explicit, :stack_exhausted)`); a fault in `main`, in the scheduler or in the
  runtime's own code is fatal. The fatal report still has no actor fields.
- **Implemented in defect batch 2 (2026-09-19):** a spawn whose stack reservation fails while `main` is the
  spawner is a runtime abort (`stack reservation failed`, 71; spec §15.1.2.2; trial
  `actor_stacks_addition/stack_reserve_failed_in_main`), and a guarded FFI fault with no current actor is a
  fatal fault (70; trial `ffi_addition/app_process_fatal_paths/foreign_fault_without_actor`). They used to
  print `stack_reserve_failed` or `foreign_fault` and exit 1.
- Process-fatal paths write only the report line; unwind reports belong to actor failures (spec §15.4.5.5).
- **Supervisor shutdown (2026-10-15, spec §15.4.12.2).** When a supervisor ends, it first shuts down its live children, one at
  a time, last child-table row first. Each shut-down child produces a failure report like any other death: a child with
  `shutdown: 0` ends with reason tag 1 (as `kill_abnormal`), a child with `shutdown > 0` ends with
  `(:explicit, :shutdown)` (reason tag 4). A child whose supervisor is already dead does not print the root-actor note.
  The `shutdown` time limit is not enforced on any target, because nothing preempts a running message.
- `remove_actor(self())` and `kill_abnormal(self())` fail the caller with `:language_error` at run time (spec §15.1.2.3);
  the compile-time rejection is not implemented.
- A `call` or `cast` whose target's calling convention does not match (a cast to a call-only actor, a call to a
  cast-only one) is rejected at compile time wherever the compiler can follow the reference (E2237, E2238; spec
  §16.2.6.4). Where it cannot, the runtime records the convention in the control block at spawn (hosted ACB
  +432) and the sender fails with `:language_error`, the same exit reason as any other language-level failure
  in an actor.

## 7. Actor failure reports (the non-fatal path)

Non-normative; the contract is spec §15.4.6.4 (the report), §15.4.11 (the notification to the supervisor) and
§15.4.13.4 (the `FailureReporter` trait). This is the path an actor's death takes, as opposed to the
process-fatal reports of §1 to §5. Checked against the hosted and board runtimes 2026-10-16.

- **One report per death, delivered asynchronously.** When an actor ends abnormally or is shut down, the
  runtime formats the report on the dying actor's teardown path and hands it to the registered root
  `FailureReporter` by a cast, so `handle_report` runs on the reporter's own thread (hosted) or dispatch
  (board), never on the dying actor's stack. The structured notification to the supervisor's ingress is a
  separate channel. Where no reporter is registered the report is written to standard error (the board: the
  console) at once.
- **The banner.** Hosted (`L_phase_f_unwind_fmt`) and board (`rt_actors.S`) print the same shape:
  `=== Silica Actor Failure ===`, `actor_id:` (the actor's 64-bit identity of spec §15.1.4, position in the
  high word and child number in the low word, printed as one unsigned integer; before 2026-10-12 it was the
  control-block pointer), `agent_type_atom:`, `reason_tag:`, `supervisor_acb:` (a pointer; null prints `0x0`
  on Darwin, `(nil)` on glibc, `0x00000000` on the board), `call_stack:` with `#0` the behaviour's symbol
  (`<unknown behavior>` when the slot is empty) and `#1  _actor_thread_main`, and
  `=== End Silica Actor Failure ===`. A region dump section follows only when the reporter's
  `region_dump_limit()` is above zero. The fields differ from the specification's example (`agent_type:`,
  `behavior:`, `supervisor:` lines); the table of §15.4.6.4 describes the intended report. The comparison
  tools fold `actor_id`, `supervisor_acb`, `epc` and `agent_type_atom` (§5).
- **Handler before any start (E2236).** `main` must register the reporter before it starts any actor or
  supervisor, so a death during start-up, the root supervisor's own included, always has a destination. The
  reporter must be cast-only: `register_failure_reporter` of a reply-form (call-only) behaviour is rejected
  (E2237).
- **The root supervisor's report ends the program.** A reporter recognises it (null `supervisor_acb`, frame
  `#0  <unknown behavior>`) and calls `cast_exit`; the compiler's reporter uses status 76 or 1
  (`main.silica`), the trial-support reporters 70. The runtime separately writes
  `[silica] root actor exited (no supervisor)` synchronously for a root actor's death; the note is not part
  of the report, which is why ordered `.scout` comparison cannot see their relative order (§5).
- **Drained at exit (hosted).** Reports already handed to the reporter are not lost when the process ends:
  an `atexit` handler (`_silica_rt_report_drain_at_exit`) waits up to two seconds, in one-millisecond steps,
  while a report is pending or being handled and the reporter is alive, then writes every report still pending
  to standard error, oldest first. A report the reporter is handling when the wait ends is the reporter's to
  print. A process-fatal path ends with `_exit` (§3.1), which runs no `atexit` handlers, so it does not drain.
- **Report blocks are freed.** The runtime owns the report string until the reporter's behaviour returns, and
  frees it then unless the behaviour passed it on in a message (`_silica_rt_report_escape_check`); the
  structured payload sent to a supervisor is freed by `silica_rt_actor_failure_release`. A report still queued when the reporter ends goes to
  standard error and is freed (`_silica_rt_report_unhandled`).
- **Supervisor shutdown and restarts.** A supervisor ending shuts down its live children first; each produces
  a report like any other death (§6, spec §15.4.12.2).
- **Restart-intensity breach (2026-10-16, spec §15.4.13.2).** A supervisor that exceeds its restart intensity ends,
  after shutting down its children, with `(:explicit, :restart_intensity_breach)` (reason tag 4) on every target. It used to end with
  reason tag 0, so a `:transient` parent never restarted it. The atom is a dedicated runtime atom, distinct from the `:shutdown` of orderly shutdown.

## 8. Where the code is

| Target | Fault report | Runtime abort |
| --- | --- | --- |
| `apple_silicon_mac`, `linux_aarch64`, `linux_x86_64` | `emitter/<target>/terms/ffi_fault_runtime_asm.silica`: `silica_rt_install_sync_fault_handlers` (and its constructor entry), `silica_rt_sync_fault_handler`, `silica_rt_print_fault_site`, `silica_rt_fault_in_handler`, `silica_rt_fault_last_resort` | same file, `emit_abort_runtime_asm`: `silica_rt_abort_with`, `silica_rt_abort_with_pc`, `silica_rt_abort_<site>`; the claim word and the 32 KB report stack in its `.bss` |
| `ESP32-S3_raw` | `board/runtime/rt_vectors.S` (vectors, `silica_rt_fatal_trampoline`, `silica_rt_fatal_nested`, `silica_rt_fatal_depth`), `rt_console.S` (`silica_rt_fatal_report`, `silica_rt_fatal_last_resort`), `rt_start.S` (VECBASE, stack-guard breakpoints) | `rt_console.S` (`silica_rt_abort_with`, `silica_rt_abort_<site>`, `silica_rt_abort_body`, `silica_rt_abort_report`), `rt_vectors.S` (`silica_rt_abort_trampoline`) |

Related: [porting_for_os_free_targets.md](porting_for_os_free_targets.md),
[porting_to_linux_x86_64_hosted.md](porting_to_linux_x86_64_hosted.md), the board pack's
[README](../src/emitter/ESP32-S3_raw/board/README.md) (console protocol),
[ports/esp32s3_port_status.md](ports/esp32s3_port_status.md), and
[macos_crash_handling_for_silica.md](macos_crash_handling_for_silica.md) (the guarded-FFI recovery that
comes before a fatal fault).
