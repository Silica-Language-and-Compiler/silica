# Transport links: the hardware a carrier runs on

Status: design accepted for phase A planning; nothing implemented (2026-11-08). It extends
[transport_serialization_design.md](transport_serialization_design.md) (the "transport design" below), §6 (carriers),
§6.0 (the transport pack) and §9.3 (diagnostics), and uses the device and FFI rules of specification §20.4 and
[runtime_failure_reporting.md](runtime_failure_reporting.md). Decisions marked **Decided** are Lee's; the rest of the
text works them out. The companion overview is the "Links" subsection (§6.7) of the transport design; the normative
(planned) text is specification §16.4.9.

## 0. Summary

A carrier today names only a transport kind, `:tcp`, `:udp` or `:serial`, with the properties `mtu`, `boundaries`,
`delivery` and `addressing` (`compiler/stdlib/Carrier.silica`). It says nothing about the hardware under it. This design
adds the **link**: the hardware (or the OS interface) a carrier runs on. A link is a tag plus parameters, such as
`(:uart, 1, 115200)` or `(:interface, :loopback)`.

| Piece | What it is | Where it lives |
| --- | --- | --- |
| carrier | how bytes travel to a peer: kind, framing properties, the actor contract of transport design §6.2 | `Carrier.silica`, `dangerous_*_carrier.silica` (hosted), the port's board tree (boards) |
| **link** | the hardware the carrier runs on: Wi-Fi station, Ethernet, UART n at baud b, USB-CDC, loopback | named in the carrier declaration; provided per target by the transport pack |
| link configuration | SSID, key, IP or DHCP, pins | board pack tables or a per-board config unit, never in protocol code |
| bring-up actor | a dangerous actor under a supervisor that owns the link and brings it up | the port's tree, beside the carrier |

Phases (§9): A hosted link naming, B UART on the ESP32-S3, C UART on the Nucleo, D network links on boards (later).

## 1. Decisions (Lee, 2026-11-08)

1. **A link concept is added under carriers.** A carrier's tag names the transport kind; a link names the hardware the
   carrier runs on (Wi-Fi station, Ethernet RMII, UART n at baud b, USB-CDC, loopback, and so on).
2. **The link is named in the carrier declaration.** Programmers are expected to know their boards. There is no
   separate deployment unit that binds carriers to links.
3. **Each target's transport pack lists the links the target can provide**, like `provides_carrier`. A carrier that
   names a link the target cannot provide is a compile-time error (§5).
4. **Configuration is board or deployment data** and stays out of protocol code (§4).
5. **A bring-up actor owns the link.** It is a dangerous actor under a supervisor. It brings the link up and
   reconnects it. A link failure is a supervised actor failure, restarted under the normal supervisor policy, and is
   not a value the sender checks (§6).
6. **One carrier per link instance.** Two links of the same kind are told apart by instance number.
7. **Scope and order: hosted first** (Mac, Linux: TCP and UDP over the OS socket stack, where the OS does the
   bring-up), then **UART on the boards** (ESP32-S3_raw, STM32-L476RG_raw). Wi-Fi and Ethernet TCP on boards are
   explicitly later and out of scope (§8).
8. **The declaration is the new top-level form** `carried_on name: (:kind) (:link, params...);` (Lee, resolving the
   former open question 1; the head was `carrier ... on` until 2026-11-08, when Lee renamed it to `carried_on`, which
   removes the clash with the built-in module `carrier`). `carried_on` is the declaration head and replaces both the
   `carrier` keyword and the `on` word; the kind and the link follow the name. It needs a parser change, and
   `carried_on` becomes a reserved word when the grammar phase lands. **Planned, not implemented.** The alternative of keeping
   `spawn_dangerous` and passing the link as one more argument is dropped.
9. **The link value is a tagged tuple where the language allows it**, such as `(:uart, 1, 115200)`; otherwise it is
   a record, `{ kind: :uart, n: 1, baud: 115200 }` (Lee, resolving the former open question 2). Which of the two is
   used is decided when the grammar phase starts. What the repo's documents say about expressibility is recorded in
   §3.5. Examples in this document use the tuple spelling.
10. **On hosts, `(:interface, name)` means bind to that interface's address**, which is portable (Lee, resolving the
    former open question 4). Forcing traffic through the interface with per-OS socket options (`IP_BOUND_IF` on
    macOS, `SO_BINDTODEVICE` on Linux) is a possible later option, not part of phase A.

Open questions 1, 2 and 4 are resolved by decisions 8 to 10; the remaining questions keep their numbers (§12).

## 2. Existing vocabulary this builds on

- **Carrier tags and properties.** `Carrier@mtu(:tcp)`, `boundaries`, `delivery`, `addressing`, `provided` are literal
  atom-keyed tables in `compiler/stdlib/Carrier.silica` (a one-atom tagged tuple is not a run-time value, so the
  functions take the atom). `Carrier` is a closed trait (transport design §9.1): programs cannot implement it (E2409).
- **The carrier actor contract** (transport design §6.2): `(:open, owner, address)`, `(:tx, segment, from)`,
  `(:credit, n)`, `(:close)` toward the carrier; `(:link_up, info)`, `(:rx, segment)`, `(:tx_credit, n)`,
  `(:tx_failed, reason)`, `(:link_down, reason)` toward the owner. The three hosted carriers spawn with
  `spawn_dangerous(initial(), carrier, stack_policy(...), state_policy(...))` and open with an address string
  (`"host:port"`, `"listen:port"`, `"path@baud"`).
- **The transport pack** (`emitter/<TARGET>/transport_pack.silica`): `provides_format(tag: string)` and
  `provides_carrier(tag: string)`, flat tables read by the shared compiler; a tag the pack does not list is E2410
  (`NotProvidedOnTarget`) from `sir_target_verify`, wherever it appears. Today the ESP32-S3_raw, STM32-L476RG_raw,
  Linux and Mac packs all answer `false` for every carrier, and the hosted carriers are provided through
  `compiler/stdlib/Carrier.silica` rather than the pack (see the comment in `linux_x86_64/transport_pack.silica`).
- **Board packs.** The ESP32-S3 draft (`ports/board_pack.silica`) is pure indexed functions with no allocation and no
  effects, and already holds `pin_uart0_tx/rx` (43/44), `pin_uart1_tx/rx` (35/36), `uart_txfifo_max` and a
  window-name table (`":esp32s3_uart"`). The Nucleo pack (`emitter/STM32-L476RG_raw/board_pack.silica`) holds
  USART2 on PA2/PA3 as the console (`console_baud` 115200) and window names `:stm32l4_usart1`..`usart3`.
- **Failure reporting.** An actor's fault ends the actor and is delivered through supervision (not a process exit);
  only `main`, the scheduler and trusted runtime code fault the process (70) or abort it (71). Exit reasons of
  §15.4.11 include `(:explicit, <atom>)`.
- **Name hazard.** `link`, `monitor` and `demonitor` are lexer keywords (actor links), and "carrier" also names a
  hosted runtime carrier thread and the built-in module `carrier`. The declaration therefore uses the head
  `carried_on` (Lee, 2026-11-08): the clash with the module `carrier` (`carrier@mtu(...)`) is resolved, because the
  module keeps its name and `carrier` does not become a keyword, and `link` is never a surface word. `carried_on`
  becomes a reserved word when the grammar phase lands. Prose says "link" for the new concept.

## 3. The link: vocabulary, syntax, meaning

### 3.1 Link tags

A link is a tag atom with fixed parameters. The language's vocabulary (the union of every target's pack, as for
carriers):

| Link | Parameters | Carrier kinds it can carry | Meaning |
| --- | --- | --- | --- |
| `(:loopback)` | none | `:tcp`, `:udp` | hosted: bind or connect on the host's loopback interface |
| `(:interface, name: atom or string)` | interface name | `:tcp`, `:udp` | hosted: bind to the named OS interface (`"en0"`, `"eth0"`, `"wlan0"`) |
| `(:ethernet, n: uint32)` | instance | `:tcp`, `:udp` | hosted: the family "any wired interface"; boards (phase D): the RMII/SPI MAC instance n |
| `(:wifi, n: uint32)` | instance | `:tcp`, `:udp` | hosted: the family "any wireless interface"; boards (phase D): the Wi-Fi station n |
| `(:uart, n: uint32, baud: uint32)` | UART instance, baud | `:serial` | board: UART n at baud b, 8N1, no flow control; hosted: not provided (a hosted serial port is `(:serial_port, path, baud)`) |
| `(:serial_port, path: string, baud: uint32)` | OS device path, baud | `:serial` | hosted: a termios port; today's `(:serial)` carrier with its `"path@baud"` address split out |
| `(:usb_cdc, n: uint32)` | instance | `:serial` | board, later (plan item L) |

The pairing of link and carrier kind is a table in the pack module's shared vocabulary (`Link@carries(link, kind)`,
§3.4); a mismatch is E2414.

### 3.2 What the declaration means on a hosted target

The OS owns the hardware and does the bring-up (interface up, DHCP, routes, Wi-Fi association). The link declaration
therefore only says **which interface family the carrier's socket binds to**:

- `(:loopback)`: bind or connect to `127.0.0.1` (and `::1`). The carrier refuses any address that is not loopback.
- `(:interface, "en0")`: bind to the address of that interface (`getifaddrs` lookup at `:open`) so traffic uses it.
  If the interface is absent or has no address at `:open`, the carrier fails (§6.3), exactly as a board link that
  fails to come up.
- `(:ethernet, n)` and `(:wifi, n)`: pick the n-th interface of that family by the OS's own classification (the
  interface list order; the family from `getifaddrs` flags and the system's interface type). Hosted instance numbers
  are only as stable as the OS's enumeration, so portable programs name `(:interface, "...")`; see open question 3.
  `(:interface, name)` is bind to that interface's address (decision 10), not a forced route.
- The bring-up actor on a hosted target is the carrier actor itself (the OS did the work). There is no separate
  bring-up actor, no `device_io` effect, and no configuration table: the interface name in the declaration is the
  whole configuration. TCP and UDP behaviour is as in `dangerous_tcp_carrier` and `dangerous_udp_carrier` today.

### 3.3 Syntax proposal

Today there is no carrier declaration form; carriers are chosen by module at `spawn_dangerous` and by an address string
at `:open`. This design adds a top-level **carrier declaration**, a pure declaration with no effects, in the style of
`impl` and device-description declarations. The form is decided (decision 8; parser change planned, not implemented); the exact production is fixed when the
grammar phase starts.

```
carried_on <name>: (<:kind>) (<:link>, <params>...);
```

A carrier declaration binds `<name>` to the kind and the link. `<name>` is used where the program names the carrier
today (`Carrier@mtu(:tcp)` becomes `Carrier@mtu(<name>)`, and `spawn_dangerous_carrier(<name>, ...)` replaces the module-level
`spawn_dangerous(initial(), carrier, ...)` plus the address string; it is the planned replacement for installing a
carrier through `spawn_dangerous` with an address string, specification §16.4.8). The kind tag continues to give the framing
properties; the link adds the **link properties** of §7 that can only narrow them.

**Example 1: hosted TCP over a named interface.**

```silica
module dangerous_readings_tcp;

carried_on sensor_net: (:tcp) (:interface, "en0");
carried_on test_net: (:tcp) (:loopback);

fn start_readings(sup: supervisor_ref) -> actor_ref proc[concurrency, transport] {
    // spawn_dangerous_carrier starts the carrier actor under sup; the OS has already brought en0 up.
    // address: peer "10.0.0.2:4369"; the link fixes which interface the connect leaves by.
    spawn_dangerous_carrier(sup, sensor_net, :named(:sensor_net))
}
```

The `proc[...]` annotation above is shorthand for the repo rule that effects live only on `sequence` blocks; in real
code `start_readings` wraps the spawn in `sequence proc[concurrency, transport] ... produces pure ... end`, and the
small main rule still holds (main starts the supervisor, calls init, and ends with `wait_for_exit()`).

**Example 2: board UART carrier.** ESP32-S3_raw on the test board, UART1 (TX GPIO35, RX GPIO36 from the board pack):

```silica
module dangerous_uart_demo;

carried_on host_line: (:serial) (:uart, 1, 115200);

// The owner frames with the carrier's properties, as in the hosted examples:
//   wireframe@frame(frame, Carrier@mtu(host_line), Carrier@boundaries(host_line))
// boundaries(host_line) is :stream, so every frame gets a length prefix (transport design §5).
```

The Nucleo version is the same file with `(:uart, 2, 115200)` for the ST-LINK virtual COM port, or another instance
the Nucleo pack lists.

**Example 3: a rejected link.** The Nucleo's transport pack does not list `(:wifi, 0)`; a hosted target does not list
`(:uart, ...)`:

```silica
module dangerous_bad_link;

carried_on lan: (:tcp) (:wifi, 0);

// on STM32-L476RG_raw:
// error E2412 LinkNotProvidedOnTarget at dangerous_bad_link, carried_on lan:
//   link (:wifi, 0) is not provided by target STM32-L476RG_raw; the board pack lists: (:uart, 1..3)
```

### 3.4 Where the link properties are answered

A new built-in `Link.silica` (beside `Carrier.silica`, closed like it) answers the language-wide facts: `carries(link,
kind)` (the pairing table of §3.1) and the shared link vocabulary used for E2413. The target-specific question,
"can this target provide this link?", is the pack's `provides_link` (§5). No user code implements either.

### 3.5 Link values: tagged tuple or record

Decision 9 spells a link `(:uart, 1, 115200)` where the language allows it and `{ kind: :uart, n: 1, baud: 115200 }`
otherwise, to be settled when the grammar phase starts. What the repo's documents show:

- The specification (§3.7, §16.3.2.1) defines tagged tuple **types** `( :tag, T1, …, Tn)`: an atom literal in the first
  position followed by component types of any kind. `(:uart, uint32, uint32)` is therefore expressible as a type, and
  a mixed atom-and-integer tuple literal such as `(:uart, 1, 115200)` is an ordinary tagged-tuple value (the cast
  message `(:open, owner, address)` of §16.4.8 is one). The tag is not interchangeable with `(atom, T1, …)`.
- A **one-atom** tagged tuple, `(:loopback)`, is a type-level tag only (a protocol tag `(:etf)`, a device tag
  `(:esp32s3_uart)`); it is never a run-time value (§16.4.1). It works here because the declaration is compile-time
  and literal-only (E2417), the same position as a protocol tag.
- What the documents do not settle: whether the type checker accepts a tagged-tuple literal with **different
  component types per tag** (a `:loopback` link beside a `:uart` link) as one position's type, since the language
  has no user-named sum for it and a case over `(:uart, n, b) | (:wifi, n)` needs the sum-of-tagged-tuples form of
  §3.4.2. The existing literal-only declarations (limits records, `{ max_bytes: N, ... }`) are records. Because the
  link is read only by the compiler and never at run time, the record spelling is the fallback if the tuple spelling
  cannot be checked per tag.

## 4. Configuration: board and deployment data

**Decided: configuration is board or deployment data, kept out of protocol code.** Because the programmer is expected
to know the board (decision 2), configuration is not a second declaration in the program. Three kinds:

| Kind | Examples | Where it lives |
| --- | --- | --- |
| fixed by the board | UART pins, which UART instances exist, FIFO sizes, interface names the board's PHY provides | the **board pack** (`emitter/<TARGET>/board_pack.silica`): pure indexed tables, no effects, extended with `uart_tx_pin(n)`, `uart_rx_pin(n)`, `uart_window(n)` (UART pins already exist as `pin_uart1_tx` and friends; they become instance-indexed) |
| chosen per deployment, not secret | baud, IP or DHCP, port numbers, interface name | the carrier declaration itself (baud, interface) or the address string given at `:open` (peer address and port, as today) |
| chosen per deployment, secret or site-specific | Wi-Fi SSID and key, static IP, gateway | a **config unit**, `board_config.silica`, a module in the application's tree beside `main` (phase D only; no phase A to C link needs one) |

Rules:

1. **Pins come from the board pack and are not a declaration parameter.** `(:uart, 1, 115200)` means the pins the
   board pack lists for UART 1. A program cannot override them in phase B or C: a pin override is a board-pack
   edit, since "programmers know their boards". An alternative (an optional pin pair parameter, with a pack
   `pin_ok(link, pin)` check) is open question 5.
2. **The config unit is data, not code.** `board_config.silica` is a module of exported pure functions, in the shape of
   the board pack (`wifi_ssid(n: uint32) -> string`, `wifi_key(n: uint32) -> string`, `ip_mode(n: uint32) -> atom`
   with `:dhcp` or `:static`). The bring-up actor reads them. The compiler reads them as data; they never appear
   in `wireframe`, formats or protocol modules. The unit is the application's, so a secret never enters the compiler's
   tree or the trials (`.gitignore`d like `.silica_build_hosts`; a checked-in `board_config.example.silica`).
3. **A missing config function is a compile-time error** at the carrier declaration that needs it: E2416
   (`LinkConfigMissing`), naming the function (phase D).
4. **Nothing is read from the environment or the file system at run time on a board.** On a hosted target the
   interface name is the only configuration and comes from the declaration.

## 5. Pack additions and diagnostics

### 5.1 `provides_link` in the transport pack

Each `emitter/<TARGET>/transport_pack.silica` gains one function, with the same shape and strictness as
`provides_carrier` (flat tables, string-keyed, never overridden by a program):

```silica
export provides_link/2;

// link: the tag name ("uart"); instance: the instance number (0 where the link has none).
fn provides_link(link: string, instance: uint32) -> boolean {
    case link of {
        "uart" -> instance == 1 or instance == 0;   // ESP32-S3_raw phase B: UART1 only; UART0 is the console
        _: string -> false
    }
}
```

The rows by target and phase:

| Target | Phase | `provides_link` rows | Notes |
| --- | --- | --- | --- |
| apple_silicon_mac, linux_aarch64, linux_x86_64 | A | `loopback`, `interface`, `ethernet n`, `wifi n`, `serial_port` | instance rows are answered at run time by the OS; the compile-time check is only that the tag exists |
| ESP32-S3_raw | B | `uart 1` | UART0 is the console (`rt_console.S`) and must not be claimed; UART2 deferred until its pins are in the board pack |
| STM32-L476RG_raw | C | `uart 1`, `uart 3` | USART2 is the console (ST-LINK virtual COM port); which of USART1/3 reach a header is a board-pack question (open question 6) |
| both boards | D, later | `wifi`, `ethernet` | out of scope (§8) |

The existing `provides_carrier(tag)` row for `"serial"` becomes `true` on the targets that provide a link for it, so
E2410 keeps its meaning (the kind is provided) and the new E2412 says the hardware is not.

### 5.2 Diagnostics

Existing numbers in use in the E24xx block: E2401 to E2405, E2408 to E2411 (E2406 and E2407 are provisional in the
transport design's §9.3). A grep of `compiler/src`, `compiler/stdlib` and `compiler/design_documents` finds no
E2412 to E2419. **Decided (Lee, 2026-11-08): E2412 to E2417 are used as the provisional diagnostic numbers** for the
rows below, in the style of the §9.3 table; the diagnostics table at implementation records them:

| Code | Check |
| --- | --- |
| E2412 LinkNotProvidedOnTarget | a carrier declaration names a link the target's transport pack does not list; raised by the target's emitter (as E2410 is), wherever the declaration appears, including one nothing uses. Message: `link (:uart, 2) is not provided by target ESP32-S3_raw; this target provides: (:uart, 1)`. Names the module, the carrier, the link and the target |
| E2413 LinkUnknown | a link tag not in the language's link vocabulary (a misspelling), raised by the shared front end for every target, as E2408 is for carriers |
| E2414 LinkCarrierMismatch | the link cannot carry the carrier's kind (`:tcp` on `(:uart, 1, 115200)`, `:serial` on `(:wifi, 0)`) |
| E2415 LinkInstanceConflict | two carrier declarations in one application name the same link tag and instance (decision 6). Message names both |
| E2416 LinkConfigMissing | the link needs a configuration function (`board_config.silica`, §4) that is not defined; names the function. Phase D |
| E2417 LinkParameterInvalid | a link parameter fails the pack's check: baud out of the UART's range, a non-literal instance or baud (the declaration is pure and literal-only, as limits records are), an interface name that is not a literal |

Placement follows E2410: E2413 and E2414 in the shared front end (they depend only on the language's tables), E2415
in the same pass as E2405 (duplicates), E2412 and E2417 in `sir_target_verify` because they read the pack.

## 6. The bring-up actor and link failure

### 6.1 Roles

- **Carrier actor**: speaks the §6.2 contract with the owner. Unchanged in what it says to the owner.
- **Bring-up actor** (boards only): a **dangerous actor** (specification §15.4.13.5, device and FFI rules of §20.4
  applying to anything that touches the hardware) that owns the link: it brings it up (clock, pins, UART configure;
  later Wi-Fi association and DHCP), watches it, and reconnects. The carrier actor is a child of the same
  supervisor and talks to the bring-up actor by message (cast, not call, per the repo's cast-over-call rule).
- **Supervisor**: the application's supervisor starts both under the normal policy, with the bring-up actor started
  first.

On a hosted target the two roles are one actor (the carrier), because the OS did the bring-up (§3.2).

### 6.2 Effects

Effects stay on sequences, and the existing carriers already show the set: `sequence proc[external_danger,
concurrency, transport]`. For the bring-up actor on a board:

| Operation | Effect |
| --- | --- |
| `cast` to the carrier, `spawn`, message handling | `concurrency` |
| configure the UART (map the window, write registers) | `device_io`, inside a device worker per the device-actor specification; the bring-up actor does not touch registers itself, it casts to the UART device worker that already owns the window |
| read bytes from the link, `byte_at` on frames | `transport` |
| a hosted bring-up (none today) or a Fifi call | `external_danger` |

So the board bring-up actor is `sequence proc[concurrency, transport]` and the register-touching UART worker is
the existing device worker (plan item N: the UART1 worker), which declares `device_io`. The bring-up actor itself needs
**no `device_io`**. This keeps hardware behind device workers (transport design principle 7). If a later network link
needs a Fifi stack (lwIP), that part is `external_danger` and `dangerous_`-prefixed, as the hosted carriers are.

### 6.3 Failure atoms and events

**Decided: a link failure is a supervised actor failure, not a value the sender checks.**

- The bring-up actor ends with an **exit reason** when the link cannot be brought up or is lost. The proposed reasons
  (all `(:explicit, <atom>)` in the §15.4.11 vocabulary, so they are ordinary supervised exits and not process exits):

  | Reason | Meaning |
  | --- | --- |
  | `(:explicit, :link_lost)` | an established link was lost (cable out, association lost, line error burst) |
  | `(:explicit, :link_unavailable)` | the link could not be brought up (interface absent on a hosted target, hardware init failed) |
  | `(:explicit, :link_config)` | the configuration a bring-up needs is unusable at run time (a Wi-Fi key rejected); phase D |
  | `(:explicit, :link_timeout)` | bring-up exceeded its deadline |

- A hardware or OS error that is not a link event keeps its existing reporting: a CPU fault inside the actor is an
  actor failure (fault 70 conventions apply only to `main` and trusted runtime), a runtime abort (71) only when
  `main` runs the failing check.
- **What the supervisor does.** Under the normal supervisor policy (restart count and restart interval of the
  existing supervisors, backoff via the SYSTIMER restart clock on boards), the supervisor restarts the bring-up actor;
  if it exceeds its restart budget, the supervisor itself fails as any supervisor does (the application then
  handles it at the root, or `main` sees the process fault 70 / abort 71 convention). A program wanting different
  behaviour (give up after N, fall back to another link) uses the supervisor policy, not a check in the sender.
- **What the carrier actor does.** The carrier actor is the owner-facing end and is told by messages, not by return
  values:
  - **On `:link_ready`** (from the bring-up actor): the carrier sends `(:link_up, info)` to its owner, grants send credit
    as it does today (8 for TCP), and starts delivering `:rx` against the owner's `:credit`. `info` carries the link
    in text (`"uart1@115200"`, `"en0 10.0.0.5"`).
  - **On `:link_lost`** (from the bring-up actor): the carrier sends `(:tx_failed, :link_down)` for every `:tx` still queued and any later `:tx`
    until the link is up again, sends `(:link_down, :fault)` to its owner (the existing atom set is `:closed`,
    `:reset`, `:timeout`, `:fault`), and **then ends** with exit reason `(:explicit, :link_lost)`. It does not retry
    on its own: retry is the supervisor's restart, which starts a fresh carrier that sends `:link_up` again to
    the (restarted) owner. A clean `(:close)` still ends the carrier with `:closed` and a normal exit, not a failure.
  - Owner contract note: an owner that supervises with the carrier (a linked pair under one supervisor) restarts
    with it. An owner that survives the carrier gets `:link_down` and the restarted carrier's `:link_up`; it must
    send `(:open, ...)` again. This is the existing "a program that needs the link back restarts the carrier under
    its supervisor" sentence of transport design §6.2, made specific.
- **Two levels of names.** The hardware level (bring-up actor, `:link_ready`, `:link_lost`, and the exit reasons
  above) is separate from the owner-facing carrier contract of transport design §6.2 (`(:link_up, info)`,
  `(:link_down, reason)`, `(:tx_failed, ...)`), which is unchanged. Example: Wi-Fi drops; the bring-up actor sends
  `:link_lost` to the carrier and exits `(:explicit, :link_lost)`; the carrier casts `(:link_down, :fault)` to the
  owner and ends. The supervisor's restart then yields a new `:link_ready` and the owner sees `(:link_up, info)`.
- **Console and reporting.** A link failure prints nothing by itself (an actor failure is "none: delivered through
  supervision" in the runtime_failure_reporting table). Programs log with the usual print functions, which need
  `device_io`; the trials assert behaviour through messages.

## 7. Interaction with wireframe framing

`wireframe@frame(frame, mtu, boundaries)` takes two properties of the **carrier**, and the link only narrows them:

| Link | `mtu` | `boundaries` | Effect |
| --- | --- | --- | --- |
| `(:loopback)`, `(:interface, ...)`, `(:ethernet, n)`, `(:wifi, n)` with `:tcp` | 0 (unbounded) | `:stream` | length prefix, no segmentation: the existing TCP rule |
| the same with `:udp` | 65507 (could be narrowed by the interface MTU in phase D; hosted keeps 65507) | `:datagram` | segmented only if the frame exceeds the mtu |
| `(:uart, n, baud)`, `(:serial_port, ...)` | 0 | `:stream` | length prefix; no segmentation |
| `(:usb_cdc, n)` | 0 | `:stream` | as UART |

Properties are therefore looked up as **(kind, link)**: `Carrier@mtu(name)` with a carrier declaration name resolves to
the kind's value unless the link narrows it. In phases A to C the link never changes a property, so `Carrier@mtu` for
a declared carrier equals `Carrier@mtu(kind)`; the link-narrowing hook exists for phase D (path MTU, BLE-like
links) and costs nothing now. The wireframe module and E2407 (`FrameExceedsMtu`) are unchanged.

A UART is `:stream`, so a frame boundary comes from the length prefix, never from the UART's FIFO depth
(`uart_txfifo_max`); the worker fills and drains the FIFO under the carrier's credit. Baud sets throughput only and
changes no property.

## 8. Out of scope: Wi-Fi and Ethernet TCP on boards (phase D, later)

Explicitly not designed in detail now. What it would need, listed so the declaration form does not preclude it:

- **A network stack**: lwIP (or equivalent) ported to the target, in its own `dangerous_` Fifi wrapper under
  specification §20.4 and `dangerous_ffi_security_model.md`; TCP and UDP carriers over it replacing the OS sockets.
- **ESP32-S3**: the Wi-Fi radio driver and firmware blobs (binary, closed), the radio's interrupt and DMA handling
  (plan items K and H), and the TCP/IP task's memory budget (the board heap budget is already tight; see the heap
  budget note). **STM32-L476RG**: no on-chip Ethernet MAC or Wi-Fi radio; it needs an external module
  (ESP-AT over UART, or a SPI Ethernet chip such as the W5500), so the "link" there is the module, a different
  link tag (`(:esp_at, n)`, `(:spi_ethernet, n)`).
- **Bring-up actor logic**: association, DHCP, reconnect with backoff, using §6, and the `board_config.silica` rules of §4
  (E2416).
- **A TLS and trust story** (`tls_quantum_safe_future.md`) before any carrier leaves a lab network.
- **Hosted instance numbers** for `(:wifi, n)` and `(:ethernet, n)` get a stable meaning (open question 3).

None of this is built in phases A to C, and a program naming `(:wifi, n)` on a board gets E2412.

## 9. Phase plan

| Phase | Scope | Work | Closes when |
| --- | --- | --- | --- |
| **A. Hosted link naming** | Mac, Linux AArch64, Linux x86-64 | parse and check `carried_on ... (...)`; `Link.silica`; `provides_link` in the three hosted packs; `(:loopback)`, `(:interface, name)`, `(:ethernet, n)`, `(:wifi, n)`, `(:serial_port, path, baud)`; `spawn_dangerous_carrier` taking a declaration; the TCP, UDP and serial carriers take the interface and the path from the declaration; E2412 to E2415, E2417; docs in transport design §6.3 and a new specification subsection | the existing loopback and serial trials pass with a declaration in place of the module and address strings; the new link trials pass |
| **B. UART on the ESP32-S3** | ESP32-S3_raw | `(:uart, 1, baud)` in the pack; board pack `uart_tx_pin(n)`, `uart_rx_pin(n)`; the UART1 worker (plan item N) with the carrier contract; the bring-up actor (§6) and the failure atoms; `board_values.silica` demo of transport design §10 phase 4 | the ETF-over-UART demo runs; board link trials pass; `make integrate` for the target is green |
| **C. UART on the Nucleo** | STM32-L476RG_raw | `(:uart, 1|3, baud)`; Nucleo board pack indexed pins; the USART worker; the same bring-up actor logic; Mac `(:serial_port, ...)` against the ST-LINK port as the peer | the same trials as phase B pass on the Nucleo |
| **D. Network links on boards** | both boards | §8 | decided later |

Each phase ends with its own trials; the all-trials-every-version constraint holds, so goldens are hand-derived and
linux mirrors follow the usual lock-step.

## 10. Trial plan

Trials follow the repo's conventions: compile-defect trials in their own `compile_defects_<slug>_addition`
directory, one per rejected unit; `ffi_addition/app_transport_*` for hosted carrier programs; board trials run through
the `TRIAL_TARGET` driver; goldens hand-derived.

**Phase A (hosted):**

- `app_transport_tcp_loopback_link` (success): the existing TCP loopback app with the carriers declared on
  `(:loopback)`; the outputs match the current golden.
- `app_transport_udp_loopback_link` (success): the same for UDP.
- `app_transport_tcp_interface_link` (success): `(:interface, <name>)` where the name is the loopback interface name
  of the host (`lo0` on macOS, `lo` on Linux), chosen by the trial per OS, since the loopback interface exists
  everywhere.
- `app_transport_serial_link` (success on the device-bearing host only, outside `make integrate`, as the existing
  serial trial is).
- Error trials: `link_not_provided_hosted` (E2412: `(:uart, 1, 115200)` on a hosted target), `link_unknown` (E2413),
  `link_carrier_mismatch` (E2414: `:tcp` on `(:uart, 1, 115200)`), `link_instance_conflict` (E2415: two carriers on
  `(:uart, 1, ...)`), `link_parameter_invalid` (E2417: non-literal baud).
- `link_interface_absent` (run-time): `(:interface, "nope0")`; asserts the carrier ends with `(:explicit,
  :link_unavailable)` and that a supervisor restart is counted.

**Phase B (ESP32-S3, board trials):**

- `uart1_link_echo`: carrier on `(:uart, 1, 115200)` frames a value and the board's loopback jumper (TX35 to RX36)
  returns it; success output matches.
- `uart1_link_failure_restart`: forces a bring-up failure (a documented fault injection in the UART worker) and asserts
  restart under the supervisor and a second `:link_ready` at the carrier (a second `(:link_up, info)` at the owner); no process exit.
- `uart1_stream_framing`: a frame larger than the FIFO (128) crosses, proving the length-prefix path (§7).
- Error trials: `link_not_provided_wifi_esp32s3` (E2412 for `(:wifi, 0)`), `link_uart0_console_reserved`
  (E2412 for `(:uart, 0, ...)`).
- A `provides_link` table trial for the pack itself (pure function answers).

**Phase C (Nucleo):** the phase B trials with the Nucleo's instances; `link_not_provided_uart2_console` (E2412 for
the console USART); Mac-to-Nucleo frame exchange through the ST-LINK port, recorded in the board README like the other
apps.

**Phase D:** none defined.

## 11. Specification and design document changes

| Document | Change |
| --- | --- |
| specification §16.4.9 (carrier links, planned text added) | the `carried_on` declaration, the link vocabulary, `spawn_dangerous_carrier`, E2412 to E2417 |
| specification §20.4 | one line: a link is hardware reached through device workers (boards) or the OS (hosted); the bring-up actor is a dangerous actor |
| transport design §6.0, §6.1, §6.2 | the pack gains `provides_link`; the trait gains the link-narrowing hook; the "restart the carrier" sentence points here |
| transport design §9.3 | rows for E2412 to E2417 |
| `Carrier.silica`, new `Link.silica` | the tables of §3.1 and §3.4 |
| `docs/learn-silica.md` | after phase B only: one UART example, kept inside the small main rule |

## 12. Open questions

Questions 1, 2 and 4 were resolved on 2026-11-08 (decisions 8 to 10); numbers are kept so references stay stable.
Eight remain (3, 5 to 10 and 12); 11 and 13 are resolved.


1. *(Resolved: decision 8.)*
2. *(Resolved: decision 9.)*
3. **Hosted `(:ethernet, n)` and `(:wifi, n)`.** The OS gives no stable numbering and no portable family
   classification (macOS `en0` is either; Linux names vary). Options: drop them on hosted targets in phase A and keep
   only `(:loopback)` and `(:interface, name)`; or define family by `getifaddrs` flags. Not decided.
4. *(Resolved: decision 10.)*
5. **Pin overrides.** The decision keeps pins in the board pack. Whether a program may pass pins (with a pack
   `pin_ok` check) for boards wired differently is open.
6. **Which UART instances each board provides.** ESP32-S3: UART0 console, UART1 header (35/36); UART2 not in the draft
   board pack. Nucleo: USART2 console; whether USART1 (PA9/PA10) and USART3 reach headers on the NUCLEO-L476RG
   Arduino or Morpho connectors needs the board manual; the Nucleo pack lists the window names but no pins for them.
7. **UART settings beyond baud.** 8N1, no flow control is hard-coded as in the hosted serial carrier. Parity, stop bits and
   RTS/CTS are a link parameter later or never.
8. **Restart budget when the link is physically absent.** A bring-up that fails immediately restarts until the
   supervisor's budget is exhausted and then fails the supervisor. Whether the default supervisor policy suits a
   board with a cable that is simply unplugged, or a link-specific backoff is needed, is not decided by anything in
   the repo.
9. **Effect of the bring-up actor on the number of dangerous-actor threads on hosted targets.** Each dangerous actor is
   an OS thread; one bring-up actor per link on a hosted target is avoided by merging roles (§3.2), but what the
   merged actor does while waiting on an absent interface (poll interval) is open.
10. **Trial hardware.** The UART loopback trial assumes a TX-to-RX jumper on the board under test. Whether the shared
    test boards will have the jumper fitted, or the trials use the Mac `(:serial_port, ...)` peer instead, is
    Lee's call.
11. **Diagnostic numbers.** Resolved 2026-11-08: E2412 to E2417 are used as the provisional numbers (§5.2). The E2406 and
    E2407 numbers of the transport design are still provisional.
12. **Where `provides_link` for the hosted targets lives.** The hosted carriers are provided through `Carrier.silica`
    and the Mac, Linux packs answer `false` for every carrier tag (their comments say the carrier tags are provided "as
    on the Mac"). `provides_link` could follow the same split or the packs could be brought up to date together.
13. *(Resolved 2026-11-08, Lee.)* **Naming of the hardware-level events.** The bring-up actor's events to the carrier are
    `:link_ready` and `:link_lost` and its exit reason is `(:explicit, :link_lost)`, so they do not share names with the
    owner-facing `:link_up` and `:link_down` of the carrier contract (§6.3). Likewise the built-in carriers' `:tcp`,
    `:udp`, `:serial` are carrier kinds, not link tags.
