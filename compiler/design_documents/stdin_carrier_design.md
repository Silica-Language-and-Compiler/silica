# Standard input: the `(:stdin)` link of the `(:serial)` carrier

**Decision (2026-11-18): standard input is DANGEROUS.** It is untrusted input from outside the program, like a socket,
so it follows "hosted carriers are all Fifi" (transport design §6.3): the carrier is `dangerous_console_stdin_carrier`,
a dangerous actor over a small C wrapper (`compiler/stdlib/net/silica_console.c`, bound by `dangerous_console.silica`);
its `(:rx, chunk)` bytes are external-danger-touched; an owner is a `dangerous_` module (E4021) and de-taints each chunk
with `recreate(chunk, { max_bytes: 65536 })`, which this work adds for `string` (FFI wrapper specification §7.7). This
replaces the first design, below in strike-through form where it differs, in which the runtime read fd 0 under
`device_io` through a `console_read` builtin and the bytes were pure: that made stdin the one hosted carrier whose input
was trusted. `console_read`, its per-emitter helpers and E2419 are removed. The `wait_for_exit` hand-off (§6), the link,
`wireframe` `:lines` and the carrier's message contract are unchanged.

**Status (2026-11-19), dangerous design: built on `main` (`274b925f71`), at a fixed point and installed locally.** The
compiler with this work reached its fixed point (gen3 byte-identical to gen2, 374 units) and is installed in this
checkout as `binaries/silica-999905-macos-applesilicon` (`binaries/silica-compiler`); nothing is released.
- Apple Silicon: `trials/stdin_addition` passes 12/12 (one trial `INTEGRATE_PENDING`, §11 item 4). The whole trial tree
  ran 35,419 pass, 53 fail: 47 were `.ascomp` diffs from this work (the atoms `:lines` and `:lines_skip`, the larger
  `wireframe`, the nested-call fix of §11 item 2), refreshed and re-run clean. The rest predate this work (the TCP
  `link_rules` print races, the macOS 27.2 linker warning, `bees_sd7`'s and `dangerous_tcp_carrier_end_memory`'s RSS
  ceilings, the latter's missing Mac `.ascomp`, and a leftover `compile_defects_effect_propagation_addition` directory).
  `silica-examples/glass-mine` builds and its `ci.sh` passes (checked on the earlier base).
- Linux AArch64 (phase 2): verified with programs cross-built on the Mac (`make TARGET=linux_aarch64`) and run in a local
  arm64 container: five stdin trial programs match their `.scout`, and `glass-mine` plays to its endings. The Linux trial
  suites themselves need a native Linux compiler and were not run; Linux x86-64 has the same code, unrun.
- Boards: no `(:stdin)` link (§10 question 1). The nested-call fix of §11 item 2 was verified on a real ESP32-S3.
- Not yet done: the Linux trial suites on a Linux host; §10's open questions; §11 items 1, 4 and 5.

Status (2026-11-18, first design): **phase 1 (Apple Silicon) built on gen1 and its trials pass; not yet at a fixed
point or published.** The link, the pack rows, `console_read` (E2419 outside the carrier), the `wait_for_exit` hand-off,
`console_stdin_carrier` and the `wireframe` `:lines` mode (with `skip_line` recovery) exist. `trials/stdin_addition`
(9 trials, one application each, input fed from `<trial>.stdin`) passes 9/9 and the four new error trials in
`error_enforcement_addition` (E2414, E2415, E2417, E2419) pass, run with `SILICA_COMPILER=binaries/silica-gen1`; a
terminal (`stdin:tty`) and idle CPU (under 1%) were checked by hand. The new trials have no `.ascomp` golden yet (the
suite skips the comparison when none exists). Not yet done: gen2 and the fixed point, then the golden refresh of the
existing suites (the runtime change alters every per-directory `__silica_runtime.ascomp`; `wireframe`'s new atoms
renumber the transport goldens; about ten error messages list `(:stdin)`); the Linux and board phases; and the
pre-existing compiler defects of §11. Decisions marked
**Open (Lee)** in §10 are the language owner's; the rest of the text works out a proposal. It extends
[transport_serialization_design.md](transport_serialization_design.md) (the "transport design") §6 (carriers) and §5
(framing), and [transport_links_design.md](transport_links_design.md) (the "links design") §3.1 (link tags). The
normative texts it changes are specification §5.1, §9.1.1, §15.1.2.5, §16.4.9 and §20.2.4 (§9).

## 0. Summary

A program reads its standard input through a carrier, as it reads a socket, a serial port or a store:

```silica
carried_on input: (:serial) (:stdin);
```

`spawn_dangerous_carrier(input, <policies>...)` starts the carrier, a dangerous actor (`dangerous_actor_ref`), from a
`dangerous_` module; the owner sends `(:open, owner, "")` and `(:credit, n)`, and the carrier answers with the §6.2
contract: `(:link_up, "stdin:tty" | "stdin:pipe")`, one `(:rx, chunk)` per credit, and `(:link_down, :closed)` at end
of input. The chunk is external-danger-touched: the owner's `(:rx)` handler is the FFI result-cast handler and
de-taints it with `recreate(chunk, { max_bytes: 65536 })` before using it. A new `:lines` mode of `wireframe` turns the
pure chunks into lines. A program that declares the link takes standard input from `wait_for_exit`, which then watches
only `cast_exit`.

| Piece | What it is | Where it lives |
| --- | --- | --- |
| `(:stdin)` link | a link tag, 0 parameters, carries `:serial` | `compiler/stdlib/Link.silica`, `type_checker/type_checker_links.silica` |
| pack rows | `provides_link "stdin"`, `carrier_module`, `carrier_spawn` | `emitter/<TARGET>/transport_pack.silica` |
| the carrier | a dangerous actor speaking §6.2, read-only | `compiler/stdlib/dangerous_console_stdin_carrier.silica` |
| the wrapper | `select` (zero timeout) + `read` on fd 0, `isatty(0)`; Fifi binding | `compiler/stdlib/net/silica_console.c`, `compiler/stdlib/dangerous_console.silica` |
| `recreate` for `string` | `recreate(s, { max_bytes: N [, utf8: true] }) -> (:ok, string) \| (:rejected, atom)` | type checker, SIR generator, the hosted emitters |
| ~~`console_read`~~ | ~~a runtime primitive under `device_io`~~ (removed by the decision above) | |
| the hand-off | `_silica_rt_stdin_owned`, read by `wait_for_exit` | `emitter/<TARGET>/terms/prims/prims_actors_runtime_asm.silica` |
| line framing | `wireframe@fresh(:lines)`, `unframe`, `finish` | `compiler/stdlib/wireframe.silica` |

---

## 1. What exists (2026-11-18)

1. **No user program can read input.** `read_line()` is listed in specification §20.2.4 but is E2007 (unknown
   function). `read_lines(path)` type-checks but does not link in a user program: `_silica_read_file_path` is defined
   only in the compiler's bootstrap shim (`src/silica_rt_shim.s`), which says of itself that it is scaffolding.
2. **The language reads data through carriers.** "Silica has no files, paths or directories" (transport design §6.8,
   the `read-log-file` example). Every hosted and board link is a carrier actor.
3. **`wait_for_exit` already reads standard input** (specification §15.1.2.5): `_silica_rt_wait_for_exit` selects on
   fd 0 and the exit pipe, collects lines of at most 255 bytes and records `cast_exit(0)` for a line `exit`. Its
   register `x19` is 1 while standard input is read and 0 after its end, when only the pipe is watched. Its comment
   records that `poll(2)` on macOS often never signals `POLLIN` for a tty, and that `select(2)` is reliable.
4. **A Fifi carrier cannot deliver usable text.** Bytes a foreign call reads are external-danger-touched (FFI wrapper
   specification §7.4); such data may not be used in a sequence that declares `device_io` (§7.4 there), so a line read
   through `dangerous_sockets@recv_bytes` could not be printed. The one de-taint for raw text would be
   `recreate(s, { max_bytes: N, utf8: true })`, and composite `recreate` is not built (§7.7 there: scalars only). The
   wrapper `silica_sockets_recv` also waits with `poll`, the call item 3 found unreliable on a macOS tty.

## 2. Principles

1. **Standard input is a link, not a builtin.** A blocking `read_line()` would hold a scheduler core for as long as
   the user does not type (specification §23.1.1: no preemption inside a dispatch), has no value for the end of input,
   and races `wait_for_exit` for bytes. A carrier has none of these problems and needs no new concept.
2. **The kind is `:serial`.** Standard input is a byte stream with no address, reliable and ordered: the `:serial`
   row of `Carrier.silica` (`mtu` 0, `:stream`, `:reliable_ordered`, `:none`) already says so. The link names the
   hardware, here the process's fd 0 (links design §1, decision 1).
3. **Standard input is untrusted, so it is dangerous** (decision above). It comes from outside the program like a
   socket's bytes; every received byte is untrusted input (transport design §2, principle 4), and a hosted carrier is
   a Fifi actor (§6.3). The bytes stay external-danger-touched until the owner re-creates them. (The first design
   read them in the trusted runtime under `device_io`, citing specification §9.1.1, and treated them as pure like a
   device worker's; that is withdrawn. §9.1.1's "read from console" now means printing's counterpart through this
   carrier, under `external_danger` in the carrier.)
4. **One reader of fd 0.** A program that declares `(:stdin)` takes standard input from `wait_for_exit`; one that does
   not keeps today's behaviour exactly.
5. **Lines are framing.** The carrier moves chunks of bytes; the owner frames them, as it frames every stream.

## 3. The program's view

```silica
module dangerous_main;

use dangerous_console_stdin_carrier;

carried_on input: (:serial) (:stdin);

fn main() -> int64 {
    sequence proc[concurrency, device_io]
        rep: actor_ref <- spawn(0, reporter, stack_policy(0, :keep_last_message), state_policy(:keep_state_area));
        _: atom <- register_failure_reporter(rep);
        car: dangerous_actor_ref <- spawn_dangerous_carrier(input, stack_policy(0, :keep_last_message), state_policy(:keep_state_area));
        own: actor_ref <- spawn({ car: car, rx: wireframe@fresh(:lines), lines: 0 }, owner, stack_policy(0, :keep_last_message), state_policy(:keep_state_area));
        _: boolean <- cast(car, (:open, own, "") impl ActorMessage {});
        code: int64 <- wait_for_exit()
    produces
        pure code
    end
}
```

The spawn binds `dangerous_actor_ref` and the module is a `dangerous_` module, as for the `(:backing)` store
(`read-log-file`). The owner's `(:rx, chunk)` handler de-taints first:

```silica
fn on_rx(chunk: string, st: ...) -> ... {
    sequence proc[transport]
        r: (:ok, string) | (:rejected, atom) <- recreate(chunk, { max_bytes: 65536 })
    produces
        pure case r of { (:ok, bytes: string) -> framed(bytes, st); (:rejected, why: atom) -> refused(why, st) }
    end
}
```

`utf8: true` belongs on complete lines, not chunks: a chunk can end in the middle of a UTF-8 sequence.

The owner receives:

| Message | Meaning |
| --- | --- |
| `(:link_up, "stdin:tty")` or `(:link_up, "stdin:pipe")` | open; the info says whether fd 0 is a terminal (`isatty`), so a program can decide to print a prompt. No `(:tx_credit, n)` follows: the link is read-only |
| `(:rx, chunk)` | up to 65536 bytes, as one `read(2)` returned them; consumes one credit |
| `(:tx_failed, :no_credit)` | the answer to any `:tx`: the carrier never grants send credit |
| `(:link_down, :closed)` | end of input (Ctrl-D on a tty, the writer closed the pipe), or the owner's `:close`. The last message |
| `(:link_down, :in_use)` | an `:open` while another owner holds the link (the store carriers' atom, transport design §6.8.2) |
| `(:link_down, :fault)` | `read(2)` failed; the carrier ends `(:explicit, :link_lost)` |

## 4. The carrier: `dangerous_console_stdin_carrier`

A dangerous actor modelled on `dangerous_serial_carrier`: its foreign calls (`dangerous_console@probe`, `read`, `take`)
sit in the root `external_danger` block of its behaviour, it re-creates only the scalar tags it relies on, and the bytes
it reads leave it one way only, as the FFI result cast `(:rx, bytes)` to the owner; they never enter its own state. Its
state is `{ owner: actor_ref, up: boolean, rx_credit: int64, polling: boolean, ending: atom }`; its messages are
`(:open, actor_ref, string) | (:tx, string, actor_ref) | (:credit, int64) | :close | :poll`. In the table below,
`console_read(0)` and `console_read(65536)` read as the wrapper's `probe` and `read` (tag 0 data, 2 nothing ready,
3 end of input, 1 error).

| On | Does |
| --- | --- |
| `(:open, o, _)`, not up | `console_read(0)` once to learn tty or pipe; `(:link_up, info)` to `o`; up. Starts polling only when credit arrives |
| `(:open, o, _)`, up | `(:link_down, :in_use)` to `o`; the current owner is unchanged |
| `(:credit, n)` | adds `n`; starts the `:poll` loop if it is not running |
| `:poll`, credit > 0 | `console_read(65536)`: `(:data, s)` → `(:rx, s)`, credit − 1, `:poll` again at once; `:none` → `send_after(20, self(), :poll)`; `:end` → `(:link_down, :closed)`, `stop_self(:normal)`; `(:fault, errno)` → `(:link_down, :fault)`, `stop_self((:explicit, :link_lost))` |
| `:poll`, credit 0 | the loop stops (`polling: false`); nothing is read, so the writer of a pipe blocks when the OS buffer fills: backpressure reaches the producing process |
| `(:tx, _, from)` | `(:tx_failed, :no_credit)` to `from` |
| `:close` | `(:link_down, :closed)`, `stop_self(:normal)`. fd 0 is never closed |

The 20 ms idle poll is the `(:serial)` carrier's (`dangerous_serial_carrier`). A restart under a supervisor after the
end of input reads the end again at once and ends again: the end of standard input is final.

## 5. ~~The primitive: `console_read`~~ (withdrawn; see the decision at the top)

The wrapper keeps the same behaviour in C: `select(2)` with a zero timeout on fd 0 (never `poll`, §1 item 3), `read(2)`
of at most 65536 bytes into a per-thread buffer fetched by `take`, `isatty(0)` for the probe, `EINTR`/`EAGAIN` as
"nothing ready", and fd 0 never closed. The first design's text follows for the record.

```
console_read(max: int64) -> (:data, string) | :none | :end | (:fault, int64)    proc[device_io]
```

- **Never blocks.** It checks fd 0 with a zero timeout, then reads at most `max` bytes. `:none`: nothing waiting.
  `:end`: `read` answered 0. `(:fault, errno)`: `read` failed (an `EAGAIN` or `EINTR` is `:none`).
- **`max` 0** reads nothing and answers `(:data, "tty")` or `(:data, "pipe")` from `isatty(0)`: the carrier's one
  probe at `:open`. (A separate `console_is_tty()` is the alternative; §10, question 6.)
- **Where it may be called:** only in `compiler/stdlib/console_stdin_carrier.silica`, as `peek` and `poke` are only in
  `device_*` modules. Elsewhere it is a new error, **E24xx ConsoleReadOutsideCarrier** (number from the diagnostics
  table), naming the module and function. It is a builtin, so §19.3.3 applies: an unqualified call is always the prim.
- **Per target:**
  - Apple Silicon: `select(2)` with a zero `timeval` (not `poll`, §1 item 3), then `read` (syscall 3); `isatty` via
    `ioctl(0, TIOCGETA)` (syscall 54). The emitter writes a helper `L_console_read_helper` once per program, beside
    `L_ps_helper`.
  - Linux AArch64: `ppoll` (73) with a zero timespec, `read` (63), `ioctl(0, TCGETS)` (29). Linux x86-64: `poll` (7),
    `read` (0), `ioctl` (16). Linux's `poll` on a tty is reliable.
  - The result string is allocated as `L_tr_byte_slice` allocates its result (`L_dyn_alloc`, then `L_str_forget`;
    `emitter/apple_silicon_mac/terms/prims/prims_transport.silica`): read into a scratch area on the actor stack, then
    copy exactly the bytes read, so no allocation is ever `max` bytes long.
  - Board targets: phase 3 (§8).

## 6. The hand-off from `wait_for_exit`

- The compiler knows at build time whether the application declares a `(:stdin)` link (`carried_on` declarations are
  tag-11 declarations, checked across every module of a compile). When it does, the emitter of the module that holds
  the declaration writes one data word: `.globl _silica_rt_stdin_owned` / `_silica_rt_stdin_owned: .quad 1`.
- The runtime declares `.comm _silica_rt_stdin_owned,8,3`: a common symbol, 0 unless a definition is linked in.
- `_silica_rt_wait_for_exit` sets `x19` from it at entry: `x19 = 1 - stdin_owned`. With `x19` 0 the existing loop
  never sets fd 0 in the `fd_set` and never reads it: the path it takes today after the end of input. No other change.
- When standard input is owned, a line `exit` is data like any other; the program decides whether it ends the program
  (with `cast_exit`). Ending from outside (a signal, the host) is unchanged. §10, question 3.
- `wait_for_exit` keeps `device_io` in its effect row: whether it reads standard input is decided at link time, and
  the signature should not depend on another module's declarations.

## 7. Line framing: `wireframe` `:lines` mode

```
wireframe@fresh(:lines) -> { mode: atom, expected: int64, pending: string }
wireframe@unframe(state, chunk, max_line)
    -> (:more, state) | (:frame, line, state) | (:rejected, :too_large)
wireframe@finish(state) -> (:frame, line) | :empty
```

- One line per call, without its `\n` or `\r\n`. As in `:stream` mode, call again with `""` to drain the next line of
  the same chunk.
- `expected` is the count of pending bytes already known to hold no newline, so a long line arriving over many chunks
  is scanned once.
- `(:rejected, :too_large)` when a line (or the unterminated tail) exceeds `max_line`. The owner recovers with
  `wireframe@unframe(wireframe@skip_line(old_state, chunk), "", max_line)`, where `old_state` and `chunk` are what
  it passed to the rejected call (unframe is pure, so it still holds them): `skip_line` drops the long line through
  its newline and keeps what follows, or enters a `:lines_skip` state that discards until the next newline.
  Starting again with `fresh(:lines)` is wrong: it throws away the start of the next line (found 2026-11-18: a
  300 KB line followed by `short` lost `short`).
- `finish` answers the last line when the input ended without a newline; the owner calls it on `:link_down`.
- It is content framing, chosen by the program, so it serves line protocols over `(:tcp)` as well. This differs from
  "one framing, chosen by the carrier's properties" (transport design §5): §10, question 2.

**Prototype.** The mode, an owner and a stand-in carrier that splits its input as a pipe may (`"hel"`, `"lo\nwor"`,
`"ld\r\nthird line\nno newline at end"`, then `(:link_down, :closed)`) were written as one module and run on Apple
Silicon (2026-11-18). Output: `hello`, `world`, `third line`, `no newline at end`, `lines read: 4`, status 0. The owner's
drain loop:

```silica
fn drain(r: (:more, { mode: atom, expected: int64, pending: string }) | (:frame, string, { mode: atom, expected: int64, pending: string }) | (:rejected, atom), st: { car: actor_ref, rx: { mode: atom, expected: int64, pending: string }, lines: int64 }) -> { car: actor_ref, rx: { mode: atom, expected: int64, pending: string }, lines: int64 } {
    case r of {
        (:more, rx1: { mode: atom, expected: int64, pending: string }) -> { car: st.car, rx: rx1, lines: st.lines };
        (:frame, line: string, rx2: { mode: atom, expected: int64, pending: string }) -> {
            st2: { car: actor_ref, rx: { mode: atom, expected: int64, pending: string }, lines: int64 } <- on_line(line, { car: st.car, rx: rx2, lines: st.lines });
            drain(unframe_lines(st2.rx, "", 4096), st2)
        };
        (:rejected, why: atom) -> {
            _: atom <- say_atom("line rejected: ", why);
            { car: st.car, rx: fresh_lines(), lines: st.lines }
        }
    }
}
```

## 8. Phases

| Phase | Target | Work | Closes when |
| --- | --- | --- | --- |
| **1** | Apple Silicon | `Link.silica` and `type_checker_links.silica` rows; the Mac pack rows; `console_stdin_carrier.silica`; `console_read` through type checker, effect checker, SIR and emitter, with E24xx; the hand-off; `wireframe` `:lines` | the trials of §8.1 pass on the Mac; `make integrate` is green |
| **2** | Linux AArch64, Linux x86-64 | their pack rows, `console_io_inline.silica`, the hand-off in their runtime | the same trials pass on both |
| **3** | ESP32-S3_raw, STM32-L476RG_raw | `(:stdin)` as the console's receive side, if question 1 is decided yes | the board console trials pass |

### 8.1 Trials (phase 1)

Under `trials/stdin_addition/` (apps take input from a file the harness pipes in):

- `stdin_lines_piped`: three lines in, three lines echoed, then `(:link_down, :closed)` and status 0.
- `stdin_no_final_newline`: the last line arrives through `finish`.
- `stdin_crlf`: `\r\n` lines come out without the `\r`.
- `stdin_empty`: `:link_up`, then `:closed` at once.
- `stdin_line_too_long`: a 1 MiB line with `max_line` 4096 is `(:rejected, :too_large)`, and the next line is read.
- `stdin_exit_line_is_data`: input `exit` is echoed; the program ends by its own `cast_exit`.
- `stdin_tx_refused`: a `:tx` is answered `(:tx_failed, :no_credit)`.
- `stdin_second_open_in_use`: a second `:open` is `(:link_down, :in_use)`.
- `wait_for_exit_unchanged`: a program without the link still ends on an `exit` line (regression).

Under `trials/error_enforcement_addition/`: `stdin_link_declared_twice` (E2415), `stdin_link_wrong_kind` (E2414 for
`(:tcp) (:stdin)`), `stdin_link_with_parameter` (E2417), `console_read_outside_carrier` (E24xx).

A tty run (prompt, typed lines, Ctrl-D) is checked by hand and recorded in the status line; the harness has no tty.

## 9. Specification changes

- §5.1, §9.1.1: "read from console" is through the `(:stdin)` link (§16.4.9); no builtin reads the console.
- §15.1.2.5: a program that declares a `(:stdin)` link does not have standard input watched by `wait_for_exit`; the
  `exit` line then has no meaning to the runtime.
- §16.4.9 and links design §3.1: the `(:stdin)` row (0 parameters, carries `:serial`, hosted; boards per question 1).
- §20.2.4: `read_line` removed (question 4).
- New diagnostic E24xx ConsoleReadOutsideCarrier.

## 10. Open questions

1. **Open (Lee): boards and decision 17** ("the console is never a link"). Proposed: `(:stdin)` takes only the
   console's receive side, which `wait_for_exit` already reads on a raw target; the runtime keeps transmit for
   printing and failure reports, so no UART instance is shared in the sense of E2415. Until decided, the board packs do
   not list `(:stdin)` and a declaration is E2412.
2. **Open (Lee): `:lines` in `wireframe`.** Proposed: a mode of `wireframe`, chosen by the program. Alternative: a
   separate built-in module `lineframe`, keeping `wireframe` to framings the carrier's properties choose.
3. **Open (Lee): the `exit` line when standard input is owned.** Proposed: no meaning; the program owns its input.
   Alternative: the carrier recognises `exit` and records `cast_exit(0)` before delivering anything else.
4. **Open (Lee): `read_line` in §20.2.4.** Proposed: removed. It was never built.
5. **The CLI and the implicit `use`.** `silica build` bundles a stdlib module only when a source file names it in
   a `use` line, so a program with a `(:stdin)` link must write `use dangerous_console_stdin_carrier;` (as `read-log-file`
   writes `use dangerous_store_backing_carrier;`); without it the build fails with E1009. Proposed: the CLI learns
   that `carried_on` implies the carrier module. Until then, the documentation says the `use` line is required.
6. **Spelling of the spawn.** Proposed: `spawn_dangerous_carrier`, as for `(:memory)`. A neutral `spawn_carrier`
   alias would read better for carriers that are not dangerous, but it is a second spelling of one thing.
7. ~~**The tty probe.**~~ Settled by the decision: the wrapper's `probe` (`isatty(0)`).

## 11. Defects found while building this (pre-existing)

All of these reproduce on the released compiler `silica-999908-macos-applesilicon`, so they predate this work. Items 2
and 3 are fixed (2026-11-18); items 1 and 4 are open. The carrier works around 1 and, until 2 is released, 2.

1. **A tuple-pattern tag that is not yet interned resolves to atom index 0.** The atom table grows in compile order,
   so a module compiled before the one that first spells an atom matches `(:open, ...)` against index 0 and no arm
   ever matches (`:language_error`, no case arm matched). Bare-atom patterns are not affected. Repro: a two-module
   program whose `(:alpha, n)` pattern is in a module compiled before `main`, which builds `(:alpha, 7)`
   (`picker.sams` compares the tag with `#0`; `:alpha` is not in `silica.atoms`). The carriers sidestep it with a
   `msg_kind` function whose arms return the tags as values, which interns them; this is why
   `dangerous_serial_carrier` and `store_memory_carrier` are written that way.
2. **A call nested in a tuple or record literal argument clobbers the arguments evaluated before it.** For
   `f(x, (:tag, g(y)))` the code evaluates `x` into X0, calls `g`, then branches to `f` without reloading X0, so `f`
   receives `g`'s result as `x`. Repro: `show(n, (:tag, concat("a", "b")))` prints a pointer (`6089009568`) instead of
   `42`; binding the `concat` first prints `42`. In the carrier this made the `:link_up` cast go to a non-actor and
   answer `false`. Workaround: bind the inner call first.
   **Fixed (2026-11-18) in the three hosted emitters and the two board emitters** (`term_user_call_helpers`,
   `term_emit_kind_call`, `term_emit_kind_call_tail`). Root cause: the argument-staging path that protects staged
   registers refuses tuple-typed arguments, and the sequential path's guards (`guard_prev`, the two-argument reorder)
   recognised only user calls, so a helper-calling prim (`concat`, `substring`, string compares, the transport prims,
   ...) at any depth clobbered X0..X7; the reorder also left X1 unprotected. A new predicate,
   `term_subterm_may_clobber_arg_regs`, treats every prim not on a short register-safe list as a clobber. Trial suite
   `trials/compile_defects_nested_call_in_tuple_arg_addition` (4 programs, all pass on gen1). Not yet verified on the
   ESP32-S3 board; STM32 unverified.
3. **A call's last tuple-typed argument is laid out flat.** In rest-chain call lowering
   (`terms_user_call_lowering.silica`) the remaining formals were passed through `tuple_rest_element_type`, which
   returns a single remaining formal bare, so `(atom, (atom, string))` was read as two formals; the literal
   `(:outer, (:pair, s))` was then laid out with its flattened inferred type `(atom, atom, string)`, and the callee,
   which reads a pair whose second word points to the inner pair, faulted (`addr=0x21`). Any call of three or more
   arguments whose last parameter is a tuple or sum was affected. **Fixed (2026-11-18)** in shared SIR code
   (`tuple_rest_formals`; a tuple literal takes the formal when its top-level arity differs from the inferred one).
   Related and **open**: a record literal argument with a non-scalar field still takes its inferred field types, so an
   unsuffixed float in it is `float32` against a `float64` formal; widening that changes code for many existing
   record-literal arguments, including in the compiler, and needs a decision.
4. **Receiver-side taint is not enforced** (FFI wrapper specification §7.6). The compiler tracks external-danger
   taint only inside the worker that makes the foreign call. A payload a behaviour *receives* from a dangerous actor
   (an FFI result cast, such as a carrier's `(:rx, chunk)`) is not treated as tainted, so an owner may print, store or
   forward raw foreign bytes; `decode` and `recreate` in carrier owners are a convention, not an enforced step. This
   holds for every dangerous carrier (`(:tcp)`, `(:udp)`, `(:serial)`, `(:backing)` and `(:stdin)`). Enforcing it needs a
   static rule for which received payloads are tainted, because a carrier learns its owner only at run time (from
   `:open`); for example, "in a `dangerous_` module, the payloads of the carrier-contract variants a behaviour
   receives are external-danger-touched until `recreate`/`decode`". **Open (Lee).** The trial
   `trials/stdin_addition/fail_stdin_tainted_chunk_printed` (expects E2103) is marked `INTEGRATE_PENDING` until then.
5. **`bytes` is a keyword**, and binding a variable named `bytes` reports E2001 "string literal required, got numeric
   literal" at its use, which does not point at the cause. A clearer diagnostic ("`bytes` is a reserved word") would
   help.
