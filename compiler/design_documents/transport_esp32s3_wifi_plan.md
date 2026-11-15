# ESP32-S3 Wi-Fi TCP transport to a Mac and a BEAM node: Phase D plan and development plan

Status: **target changed by Lee, 2026-11-09: serial over USB-C is the transport between the Mac and the board; the Wi-Fi
stages (3 to 9) are deferred (§8).** Route R2 was chosen for Wi-Fi (§3) and stays the Wi-Fi route when it resumes. Stage 1
is closed (§7); stages S-A, S-B and S-C are done (§7, 2026-11-09), and S-D, end to end over USB-C with both peers,
on 2026-11-10 (§7; synthetic readings: the I2C0 accelerometer worker is not built). Stage results are recorded in §7. It refines Phase D of
[transport_links_design.md](transport_links_design.md) §8–§9 ("decided later") and uses the item letters of
[esp32s3_board_peripherals_plan.md](esp32s3_board_peripherals_plan.md) §5. Facts below were read from those two
documents, `emitter/ESP32-S3_raw/transport_pack.silica` and `compiler/stdlib`; anything not checked is marked
*(unverified)*.

## 1. Goal

An ESP32-S3 board (BYU-Idaho v4.0) and an Apple Silicon Mac exchange Silica values over Wi-Fi TCP:

- **Codec:** BEAM External Term Format, `(:etf)`, as in the hosted demo (`transport_beam_demo`): `encode` / `decode`
  with the 4-byte length prefix of `wireframe`, which is what Erlang's `gen_tcp {packet, 4}` speaks.
- **Peer on the Mac:** either a Silica program (`dangerous_tcp_carrier`, now multi-peer) or an Erlang node.
  Both are the same bytes on the same TCP connection; "BEAM" is a codec and a peer, not a second transport.
- **Network:** the developer's phone as an access point (decided 2026-11-09; `BYUI_Visitor`, an open network, is not
  used). Application-level encryption is out of scope for now. The hotspot itself is normally WPA2 or WPA3 protected
  *(unverified for the phone in use)*, so the radio must do WPA2 and the board needs the key (stage 5).
- **Link in the program:** `(:wifi, 0)` on the board, declared as in transport_links_design.md §3.

## 2. What is not built, and what is

Not built (checked 2026-11-09): every phase of transport_links_design.md. There is no `Link.silica`, no
`carried_on` in `compiler/src`, no ESP32-S3 carrier (the pack answers false for every carrier tag, so a carrier tag is
E2410), no UART1 worker (item N), no interrupt runtime (item K: "the runtime runs with interrupts off and polls"), no
DMA (item H), no network stack (items O, P), no radio (item M: "a decision, not scheduled work").

Built: ETF encode/decode on the board (the pack provides `"etf"`, lowered onto `rt_transport.S`); `wire_etf`,
`wireframe` and `Carrier`; the hosted `(:tcp)`, `(:udp)` and `(:serial)` carriers; the Mac BEAM demo; FFI on the board
in the actor's stack chain.

## 3. The radio route (decided: R2, 2026-11-09)

The Wi-Fi MAC, PHY and calibration exist only as closed Espressif libraries that assume FreeRTOS-style tasks, queues
and timers (peripherals plan §4.4). The port is ESP-IDF-free and polls with interrupts off. Three routes:

| Route | What it is | Cost | Risk |
| --- | --- | --- | --- |
| **R1. Espressif blobs behind a `dangerous_` wrapper, own OS adaptation layer** | link the radio libraries; write the OS shim (tasks, queues, timers, interrupts, DMA) in Silica/assembly on this runtime | largest; needs K and H first | the blobs' expectations of a scheduler and interrupts are only partly documented; the actor runtime has to host them |
| **R2. ESP-IDF's Wi-Fi component (and lwIP) as foreign code** | build the IDF pieces, run them as a foreign component, reach them through Fifi | smaller code, but IDF brings its own FreeRTOS and interrupt handling, which collides with the polling runtime | two schedulers on one core pair; the heap budget; "ESP-IDF-free" ends |
| **R3. Radio off the board: a second ESP32 running Espressif's AT firmware on UART1** | the board speaks bytes to a Wi-Fi modem over UART1; the modem owns the radio and TCP | small; reuses item N | not the S3's own radio; needs a second board; the carrier is `(:uart1)` toward the modem, with TCP done by AT commands |

**Decision (Lee, 2026-11-09): R2.** The UART1 carrier is built first (stage 1: every route needs it). Stage 3 is then
the R2 integration, treated as a time-boxed spike first, because whether IDF code can coexist with the polling runtime
is the open technical question. If the spike shows it cannot, R3 is the fallback for the demo and R1 stays the long-term
path; that outcome is recorded in §7 and reported to Lee before any other route is started.

Network stack above the link: **lwIP** (through the wrapper) for R1/R2 first, because the Silica stack of items O and P
(supervised IPv4, ARP, DHCP, TCP actors) is moderate to large work and is not on the critical path to a demo. The
Silica stack stays the long-term, OS-free path and sits on the radio's link layer unchanged.

## 4. Development plan

Each stage ends with its own trials and leaves the tree green on Apple Silicon (`make integrate` for the touched suites;
goldens regenerated from the compiler's own output; the compiler's fixed point re-checked after any compiler-source
change). Stages 0 to 2 need no radio.

### Stage 0. Feasibility and test network (no code)

- Use the phone's hotspot (it avoids the captive portal and client isolation common on campus guest networks such as
  `BYUI_Visitor`, which a board cannot get past). Put the Mac on the hotspot and check that the Mac can reach another
  device on it with TCP. *(unverified.)*
- ESP32-S3 Wi-Fi is **2.4 GHz only**: enable the hotspot's 2.4 GHz band (on an iPhone, "Maximize Compatibility").
- Note the Mac's address on the hotspot subnet (it is assigned by the phone and may change; pick a port, and have the
  board take the Mac's address from `board_config.silica` for now) and keep the phone awake with the hotspot screen on
  if it drops idle clients.
- Expect the Mac to lose its other network while joined, unless the phone provides internet.
- Confirm the board's Wi-Fi hardware (antenna, RF routing) in `PORT_TEST_BOARD_byu_idaho_v4.0_feb26.md`.

### Stage 1. UART1 carrier on the board (design phase B; item N)

- UART1 device worker (GPIO35 TX, GPIO36 RX) with the §6.2 carrier contract; board pack `uart_tx_pin`, `uart_rx_pin`.
- ESP32 transport pack: first carrier rows (`:uart1`), `provides_carrier`.
- Bring-up actor and failure atoms (links design §6).
- Mac side: the existing `(:serial)` carrier and the BEAM demo as the peer.
- **Closes when:** a board program sends an ETF frame over UART1 and the Mac Silica program and the Erlang peer decode
  it. Proves the board end of the carrier contract with no radio.

### Stage 2. Link naming (design phase A)

- Parse and check `carried_on` declarations; `Link.silica`; pack `provides_link` rows for the three hosted targets and the
  board; `spawn_dangerous_carrier` taking a declaration; E2412 to E2417; the hosted `(:wifi, n)`, `(:loopback)` and
  `(:serial_port, ...)` rows; hosted `getpeername` (so `:accepted` and `:link_up` carry the peer address, not
  `"peer:accepted"`).
- **Closes when:** the links design's phase A trials pass, and the existing loopback and serial trials pass with a
  declaration in place of the module and address strings.

### Stage 3. Radio spike (decision gate)

- Time-box: attempt R2 (IDF Wi-Fi plus lwIP as foreign code) on the bring-up board; record whether it associates to an
  open network and gets a DHCP lease while the Silica runtime is running.
- Outcome decides R1, R2 or R3. Write the result into this document.
- Check the licensing of the Wi-Fi libraries before committing any of them to the tree. *(unverified.)*

### Stage 4. Interrupts and DMA (items K, H), if the route needs them

- The interrupt runtime per spec §9 (handler acks and enqueues to the owning worker) and DMA per spec §5.3.
- Required for R1; likely unavoidable for R2. Skipped for R3.

### Stage 5. Wi-Fi link: station, DHCP, reconnect

- Join the phone's hotspot (SSID and passphrase from `board_config.silica`; the file is secret, so it stays out of git;
  E2416 must still accept an empty key so an open network works later). WPA2 is done by the radio libraries, which is one
  more reason R1 and R2 use them and a Silica-native radio is not an option.
- Bring-up actor: association, DHCP, reconnect under the default supervisor restart policy; `(:link_down, :fault)` to the
  owner when the link drops, as the links design specifies.
- **Closes when:** the board reports an address and survives an access-point drop and rejoin.

### Stage 6. TCP on the board

- lwIP behind a `dangerous_` wrapper (route R1/R2) with a board socket wrapper mirroring `dangerous_sockets`; or, for
  R3, AT-command TCP behind the UART1 carrier.
- Memory: budget the stack's heap and the connection count against the board heap before enabling it.

### Stage 7. Board `(:tcp)` carrier and `(:wifi, 0)`

- Board TCP carrier speaking §6.2, with listener behaviour as on the Mac.
- ESP32 pack rows: `(:tcp)` carrier, `(:wifi, 0)` link; remove the E2412 rejection of `(:wifi, n)` on this target only.
- **Closes when:** a board program compiles with `carried_on lan: (:tcp) (:wifi, 0)` and the pack and verifier accept it.

### Stage 8. BEAM end to end

- Board connects to a `gen_tcp` listener on the Mac (`{packet, 4}`) and sends an ETF reading; the Mac replies with an LED
  command; and the same with a Mac Silica `(:tcp)` listener as the peer.
- Run through a script outside `make integrate`, as the BEAM demo is (the Apple suite skips board trials).
- **Closes when:** both peers work against the same board program, with only the Mac side changed.

### Stage 9. Hardening and docs

- Reconnect, failure atoms, memory limits, a long-run soak.
- Update the transport design (§6.4 rows), the links design (§8, §9), the board plan (items M, N, O, P), the
  specification subsection, and the README of the demo. Open question carried forward: TLS before any use beyond a lab
  network.

## 5. Trials

- **Compile-time (Apple Silicon, `make integrate`):** ESP32 pack rows accept `(:tcp)` and `(:wifi, 0)`; hosted packs
  reject `(:uart, 1)`; `link_not_provided_wifi_esp32s3` flips from E2412 to accepted at stage 7; the carrier failure
  trials already committed keep passing.
- **Assembly:** `.esp32_s3.ascomp` goldens for the new board units.
- **Board:** a scripted run per stage 1, 5 and 8 against the connected board and the Mac peer.

## 6. Risks, ranked

1. **Radio route (stage 3):** a polling runtime with interrupts off against code that expects a scheduler and interrupts.
2. **Network:** hotspot behaviour (2.4 GHz band, address changes, idle drops, WPA2 on the radio side); stage 0 answers it cheaply.
3. **Heap budget** on the board for a TCP/IP stack.
4. **Scope:** stages 4 to 6 are most of the work; stages 1, 2, 7 and 8 are compiler and library work of known shape.

## 7. Stage log

Each stage's result is recorded here when it closes: date, what was built, trials, and anything that changed the plan.

- **Stage 1, 2026-11-09: the UART1 carrier exists and sends on the board; the Mac decodes the same bytes; the
  wire itself was not observed (nothing is wired to the UART1 header).** Built:
  - `emitter/ESP32-S3_raw/board/apps/device_lib/device_esp32s3_uart1.silica`: the `(:uart1)` carrier as a device
    worker speaking the §6.2 contract (`:open` / `:tx` / `:credit` / `:close` toward it; `:link_up` with
    `"uart1@115200"`, `:tx_credit` 8 then 1 per `:tx`, `:rx` against credit, `:tx_failed`, `:link_down`). It owns
    the UART1, GPIO, IO_MUX and SYSTEM windows; bring-up at `:open` (clock gate and reset in SYSTEM, core reset,
    crystal as the UART clock with CLKDIV 347 + 3/16 for 115200, 8N1, FIFO resets, GPIO-matrix routing of signal 15
    to GPIO35/36, pull-up on RX). Failure atoms of the links design §6.3: `(:explicit, :link_unavailable)` when
    CLKDIV does not read back, `(:explicit, :link_timeout)` when the TX FIFO is not empty after reset,
    `(:explicit, :link_lost)` on RX overflow, frame error or a TX byte finding no FIFO room; each after
    `(:link_down, :fault)` to the owner, ended with `stop_self` by the behaviour. A `:close` answers
    `(:link_down, :closed)` and returns the worker to `:idle` (a device worker at the root has no supervisor; ending
    it printed a root-exit report on the console). The bring-up actor and the carrier are one worker for a UART:
    only the device worker may touch registers and a UART has no association step; the three-actor split of §6.1
    is left to the Wi-Fi link (stage 5). The receive poll (`send_after` to `self()` while credit remains) compiles
    and is untested on hardware: no peer was wired.
  - Pack: `board_pack.silica` window 12 `:esp32s3_uart1` at 0x60010000 (`rt_device.S` twin; TRM-unconfirmed like
    SPI2, confirmed on the board by the CLKDIV read-back); `pack_descriptions.silica` row (E2239 for a program that
    describes the tag, checked by hand with the rebuilt compiler); `gen_board_pack.py` entry `uart1` with
    `values_of="uart0"` (description module only, the field constants are UART0's) and the generated
    `board/pack/device_esp32s3_uart1_registers.silica`; `transport_pack.silica` `provides_carrier "uart1"` (recorded,
    read by nothing yet: the carrier check E2412 / `provides_link` is stage 2). `Carrier.silica` is unchanged: the
    `(:uart1)` row of §6.4 is the defaults (mtu 0, `:stream`, `:reliable_ordered`); `addressing(:uart1)` still answers
    `:endpoint` (should be `:none`) and `provides(:uart1)` false, deferred to stage 2 because `Carrier.silica` has
    Linux assembly goldens that cannot be regenerated on the Mac.
  - Demo: `board/apps/silica_32_transport_uart1_etf` (encode + `wireframe@frame` with `Carrier@mtu((:uart1))` /
    `Carrier@boundaries((:uart1))`, one 52-byte `:tx`); `programmer_tools/transport_uart1_demo` (the Mac peer on the
    hosted `(:serial)` carrier, `serial_to_tcp_bridge.py` toward the Erlang peer of `transport_beam_demo`,
    `fake_board.py` playing the board on a pty, `run_peer.sh`).
  - Trials: `trials/transport_board_addition/device_uart1_carrier_tx` (board only, `INTEGRATE_PENDING` on hosts): a
    204-byte frame, larger than the 128-byte FIFO, through the carrier; `.ESP32-S3_raw.scout` hand-derived,
    `.esp32_s3.ascomp` written by `gen_board_ascomp.sh` from the rebuilt compiler's output.
  - Runs: the ESP32-S3 cross compiler rebuilt from the tree (the window table is compiled in; 77 min, scratch
    `BUILD_ROOT`); `run_app.sh silica_32_transport_uart1_etf` on the board (RAM load, `/dev/cu.usbserial-8310`,
    `silica-compiler-ESP32-S3_raw` would refuse the window): MATCH, twice; `make integrate
    TRIAL_TARGET=ESP32-S3_raw TRIAL_SUITES=transport_board_addition`: 2/2 (assembly and output);
    `run_peer.sh --fake-board` on the Mac: `frame 48 bytes`, `accel x=1 y=-2 z=512 at_ms=1000`, exit 0; Erlang's
    `term_to_binary` of the same term is 48 bytes. No Apple compiler source changed (the ESP32 emitter tree is pruned
    from the Apple build), so no Apple fixed-point re-check was needed; no Apple trial suite was touched.
  - **Not closed by the definition of §4:** "the Mac Silica program and the Erlang peer decode it" was shown on the
    Mac with the design's bytes on a pty, not with bytes from the board. The board is connected by its USB-UART jack
    only (UART0, the console); nothing is on the UART1 header. To close it: a 3.3 V USB-serial adapter with its RX
    on GPIO35 (board TX) and GND to board GND (adapter TX to GPIO36 only for a later receiving program; no TX-to-RX
    jumper), then `run_peer.sh --port <adapter>` (or `--erlang`) in one terminal and `run_app.sh
    silica_32_transport_uart1_etf` in another.
  - Found on the way (not fixed, pre-existing): adding the carrier chain to `trials/device_actor_addition` made its
    board compile fail with E2213 (`register :out_w1tc is not in the description of (:esp32s3_gpio)`; locally the
    same set failed at `device_esp32s3_rmt` on `(:esp32s3_system)`). The compiler exits after every unit and
    parse-skips a `use`d module whose `.iface` is fresh, but an `.iface` carries no description rows, so a driver
    compiled in a later process sees an empty description whenever the description module's `.iface` happened to be
    usable; which driver fails depends on the order. The original suite compiles because its ifaces are re-parsed.
    The UART1 trial therefore has its own suite. The fix (never parse-skip a module that exports a `registers/1`
    description, or carry the rows in the `.iface`) is a shared-front-end change with a fixed-point rebuild.
  - Board-side gaps for later stages: a device worker cannot be a supervisor child (`flavor` has no `:device`), so
    the carrier is spawned by its owner and restarted by the program, not by a supervisor; `Carrier.silica`'s
    `:uart1` row; the `(:uart1)` receive path on hardware; UART2 (decision 17) has no window yet.

- **Stage S-A (and S-B in part), 2026-11-09: the `(:usb_serial_jtag)` carrier exists, both directions, and
  ETF frames crossed the native USB-C jack between the board and the Mac, with the Silica peer and with the
  Erlang peer; the bytes were observed on the Mac.** First task, the item F gate: `silica_31_device_usb_console`
  (and nothing else it needs) moved to the chunk-15 spawn forms (`spawn` / `spawn_device` /
  `spawn_registered_supervisor` with the `state_policy` argument, the `state_policy` field in `init`'s child
  record; it had stopped compiling with E2005), `expected.scout` unchanged; `usb_console_check.py` under the
  IDF 6.1 Python exited 0 (UART0 matched; USB console `hello from usb serial jtag` / `A` read 0.1 s after the
  open; the node vanished and reappeared once at the RAM load, as item F recorded; no ROM banner was left in
  the IN FIFO). The W2300 at `device_esp32s3_usb_serial_jtag.silica` line 221 is the chunk-15 state-release
  advisory ("state release not proven ... copies its whole state at dispatch end"; `uart1_carrier` gets the
  same at its line 663): the state is two words, so it is a cost note, not a defect, and was left. The
  compile takes about 2 s per app now (item F recorded 8 min 50 s). Built:
  - `device_lib/device_esp32s3_usb_serial_jtag.silica`: a second exported behaviour, `usb_serial_jtag_carrier/2`,
    beside the item F console worker, over the same register helpers (one window, board_pack window 7). The
    §6.2 contract both ways: `:open` enables the USB pads (CONF0, the reset default), clears INT_CLR,
    discards bytes left in the OUT FIFO and checks the link by the SOF frame index advancing over about
    100 ms (the host sends SOFs whether or not the port is open; the controller is enumerated by the ROM and
    hardware, so there is no association step), then `(:link_up, "usb_serial_jtag")` (no baud: the controller
    ignores the host's line speed; "@<address>" is appended when the address is not "") and `(:tx_credit, 8)`;
    `:tx` writes byte by byte waiting for SERIAL_IN_EP_DATA_FREE, WR_DONE after every 64 bytes and at the
    end, then `(:tx_credit, 1)`; `:credit` starts the `send_after` poll; `:poll` drains the OUT FIFO (up to
    256 bytes) into one `(:rx, bytes)` per credit, re-armed after 1 ms with data and 20 ms without; `:close`
    answers `(:link_down, :closed)` and returns to `:idle`. Failure atoms of the links design §6.3: `(:explicit,
    :link_unavailable)` when no SOF arrives at `:open`; `(:explicit, :link_lost)` when a TX byte finds no FIFO
    room within about 10 s (the host stopped reading; the bound is long so a host that opens its port late
    still gets the frame) or INT_RAW shows a PID / CRC5 / CRC16 / bit-stuff error since `:open`; each after
    `(:tx_failed, :link_down)` for the `:tx` in hand and `(:link_down, :fault)`, ended by `stop_self`. A frame
    of at most 64 bytes needs no reader: it waits in the IN FIFO until the host opens the port, which is what
    lets the board send first.
  - Pack: `transport_pack.silica` `provides_carrier "usb_serial_jtag"` (read by nothing yet, like `"uart1"`;
    the ESP32-S3 cross compiler was not rebuilt for it: no window table or description row changed, window 7
    and the `:esp32s3_usb_serial_jtag` description row are item F's). `Carrier.silica` unchanged (the
    `(:usb_serial_jtag)` row is the defaults: mtu 0, `:stream`, `:reliable_ordered`; `addressing` still
    answers `:endpoint`, deferred with the `:uart1` row).
  - Demo: `board/apps/silica_33_transport_usb_serial_jtag_etf` (grants 4 receive credits, encodes and sends the
    §13.4 accelerometer frame as one 52-byte `:tx`, decodes the reply `(:led, { which, on })` from the `:rx`
    segments with `wireframe@unframe` and `decode((:etf), ...)` on the board, prints `led red on` on UART0,
    closes); `programmer_tools/transport_usb_serial_jtag_demo` (the Mac peer on the hosted `(:serial)`
    carrier, which receives, decodes, answers `(:led, { which: :red, on: true })` and closes a second later;
    `find_usb_serial_jtag_port.py` resolves the port by 303A:1001; `run_peer.sh --erlang` runs the Erlang peer
    of `transport_beam_demo` behind `transport_uart1_demo/serial_to_tcp_bridge.py`, which gained `--hex` and
    now opens the port without pyserial's flush-at-open).
  - Trials: `trials/transport_board_addition/device_usb_serial_jtag_carrier_tx` (board only; a 60-byte frame,
    under the 64-byte FIFO, so it needs no reader; `.ESP32-S3_raw.scout` hand-derived, `.esp32_s3.ascomp` from
    `gen_board_ascomp.sh`). Adding the USB modules to the suite's compile set renumbered the atoms in
    `device_uart1_carrier_tx`'s assembly (`movi` immediates only), so its `.esp32_s3.ascomp` was regenerated
    too (the stale one deleted first; the script never overwrites).
  - Runs (board on `/dev/cu.usbserial-8310` for the RAM load and UART0, native USB-C on
    `/dev/cu.usbmodem83201`; IDF 6.1 Python and esptool; compiler `compiler/build/ESP32-S3_raw/silica-compiler`
    from stage 1): `run_app.sh --timeout 120 silica_33_transport_usb_serial_jtag_etf` MATCH three times (twice
    against the Silica peer, once against the Erlang peer), the peer started 8 s after `running ... on the
    board`. Silica peer: `serial open /dev/cu.usbmodem83201@115200`, `frame 48 bytes`, `accel x=1 y=-2 z=512
    at_ms=1000`, `sent 39 bytes`, `link down :closed`, exit 0. Erlang peer: `peer: got {accel,#{y => -2,z =>
    512,x => 1,at_ms => 1000}} (48 bytes)`, `peer: x=1 y=-2 z=512 at_ms=1000`; the bridge (`--hex`) showed
    `serial -> tcp 52 bytes:
    000000308368027705616363656c7400000004770561745f6d7362000003e8770178610177017962fffffffe77017a6200000200`
    (the design's §13.4 bytes behind the length prefix) and `tcp -> serial 39 bytes:
    0000002383680277036c6564740000000277026f6e770474727565770577686963687703726564`; the Silica peer's reply
    is the same 39 bytes (checked on a pty with `fake_board.py`). `make integrate TRIAL_TARGET=ESP32-S3_raw
    TRIAL_SUITES=transport_board_addition`: 4 / 4 (two assembly, two output; 22 s). The Mac closing the port
    (HUPCL drops DTR) did not reset the chip in any run. No Apple compiler source changed, no Apple suite was
    touched; no fixed-point re-check was needed.
  - Found on the way: the Erlang run first timed out with 0 bytes while the Silica peer read the same frame.
    pyserial 3.5's `open()` ends with `tcflush(TCIFLUSH)`, and on this port the board's frame is already in the
    macOS driver's buffer at open, so the flush threw it away; the bridge now opens in two steps with the
    flush disabled. Any host tool that reads a frame the board sent before the port was opened must not
    flush at open.
  - What S-A does not cover: a frame longer than 64 bytes toward a host that has not opened the port fails
    after the 10 s bound (by design); the receive side has no board-only trial (it needs a peer: the demo is
    the evidence); DTR state and USB suspend are not visible in this register set, so a host closing its port
    is not a `:link_down`; the carrier is spawned by its owner, not a supervisor (`flavor` has no `:device`,
    as in stage 1). S-B is done in the part that needs the board (both peers, both directions); the `(:uart0)`
    path of the §8 table was not built (the console shares it).

- **Stage S-C, 2026-11-09: the `carried_on` link declaration exists on the Apple Silicon Mac and the ESP32-S3 board;
  the loopback apps and the board carriers run through declarations.** Built (shared front end, packs, stdlib; the
  normative text is specification §16.4.9, the status is in transport_links_design.md):
  - Parser: `carried_on` is a keyword (lexer); `parser/carried_on_expand.silica` reads every declaration at the token
    level before the constraint parser (a malformed line is E1081, never skipped), turns a declaration's name in an
    expression into the kind's atom (`Carrier@mtu(usb)` is the `(:serial)` row) and expands
    `spawn_dangerous_carrier(<name>, <policies>...)` into the spawn the target's pack spells (`carrier_spawn`): on the
    Mac `spawn_dangerous(<initial literal>, dangerous_<kind>_carrier@carrier, ...)`, the serial carrier's literal
    holding the declared path and baud; on the board `spawn_device(:idle, device_esp32s3_<uart1 | usb_serial_jtag>@...,
    ...)`. The module the spawn names is an implicit `use` (as `wire_etf` is). The declaration is a tag-11 declaration
    (`constraint_extract_decls`), its tokens as parameters.
  - Checks: `type_checker/type_checker_links.silica` (shared: E2408 unknown kind, E2413 unknown link, E2414 kind and
    link do not pair, E2415 the same UART instance / serial path / USB-Serial-JTAG controller claimed twice in a module
    or across the compile's modules, E2417 parameter shape, a baud of 0); `sir_generator/sir_target_verify.silica`
    (pack: E2410 kind not provided, E2412 link not provided with the console note of decision 17 and the pack's
    `provided_links`, E2417 a baud the pack's `link_baud_ok` rejects), for every declaration, used or not; the parser
    gives E2410 / E2412 at a `spawn_dangerous_carrier` the pack cannot serve.
  - Packs (all five export `provides_link/2`, `provided_links/0`, `link_console_note/2`, `link_baud_ok/2`,
    `carrier_spawn/4`, `carrier_module/2`): the Mac provides `tcp`, `udp`, `serial` as carrier kinds (decision 16) and
    the links `loopback`, `interface`, `ethernet n`, `wifi n`, `serial_port` (baud in the termios set of the wrapper);
    the ESP32-S3 provides `serial` and the links `uart 1` (115200 only: the worker's fixed CLKDIV) and
    `usb_serial_jtag`, UART0 rejected as the console, UART2 not until it has a window; Linux and the Nucleo answer
    false / "" (their rows are not written: E2412 there).
  - Stdlib: `Link.silica` (closed like `Carrier`: `known`, `arity`, `instance_indexed`, `carries`; the vocabulary gained
    `(:usb_serial_jtag)`), `Carrier.silica` rows `:uart1` and `:usb_serial_jtag` (`provides` true, `addressing`
    `:none`; the deferred stage 1 / S-A item), `dangerous_serial_carrier` state `path` and `baud` (the declared port;
    `:open` with `""`; `:link_up` carries `"path@baud"`). The demo peers (`transport_uart1_demo`,
    `transport_usb_serial_jtag_demo`) declare their port and spawn with `spawn_dangerous_carrier`; `run_peer.sh`
    patches the declaration's path literal.
  - Trials: `error_enforcement_addition/link_*` (E1081 x2, E2408, E2412 x2, E2413, E2414, E2415, E2417 x3);
    `transport_addition/transport_link_tags` (the `Link` facts, the board carrier rows, declared carriers read through
    their names) and the sub-trial `app_transport_tcp_loopback_link` (the TCP and UDP loopback apps on
    `carried_on ... (:loopback)`, the loopback goldens; the original `ffi_addition/app_transport_tcp_loopback` is
    unchanged so its Linux goldens stay valid); `transport_board_addition/device_uart1_link_tx`,
    `device_usb_serial_jtag_link_tx` (the stage 1 / S-A programs through declarations, same `.scout`) and the
    compile-failure trial `link_uart0_console_reserved` (E2412 with the console note). Runs: Apple compiler rebuilt
    incrementally from `binaries/silica-compiler` (the baseline had to be rebuilt in full first, 25 min; then 2 min and 9 s);
    `transport_addition` 39 / 39 (the Apple `.ascomp` goldens of `transport_carrier_tags`, the listener sub-trial and the
    new sub-trial were regenerated: two new atoms in `Carrier.silica` renumber every atom index of a suite that links it);
    `ffi_addition/app_transport_tcp_loopback` green after the same regeneration of its eight Apple goldens;
    `error_enforcement_addition` 11099 / 11099 with the eleven `link_*` trials (goldens from the compiler's output);
    `programmer_tools/transport_uart1_demo/run_peer.sh --fake-board` exit 0 through the declared port (its fake board now
    waits 12 s instead of 3: the peer is compiled first, and a frame written before the pty slave is opened was echoed
    back in cooked mode); the ESP32-S3 cross compiler rebuilt from the tree (67 min 47 s, scratch `BUILD_ROOT`, copied
    over `compiler/build/ESP32-S3_raw/silica-compiler`); `make integrate TRIAL_TARGET=ESP32-S3_raw
    TRIAL_SUITES=transport_board_addition` 9 / 9 on the board (four programs' output and assembly, the UART0 console
    rejection; the four `.esp32_s3.ascomp` goldens regenerated by `gen_board_ascomp.sh` after the matching run, the two
    old ones having been renumbered); `run_app.sh --timeout 120 silica_33_transport_usb_serial_jtag_etf` (the demo now
    declares `carried_on usb: (:serial) (:usb_serial_jtag);`) MATCH against the Mac peer that declares its port
    (`frame 48 bytes`, `accel x=1 y=-2 z=512 at_ms=1000`, `sent 39 bytes`, exit 0). Fixed point on Apple Silicon: gen2 (the tree built by the new
    compiler, scratch `BUILD_ROOT`) and gen3 (the tree built by gen2) compared unit by unit with the o<N> counters
    normalised, 374 units, 0 differ, and the two binaries are byte-identical.
    The full Apple tree (`make -C trials integrate JOBS=6` with the new compiler): 35152 / 35152, no failures (the
    two pre-existing failures of 2026-11-05 did not reappear).
  - Found on the way: the board image tooling (`board_suite.sh link_closure`, `build_image.sh`) links a program with the
    modules its source names in `use` lines, so a board program keeps an explicit `use device_esp32s3_...;` beside the
    implicit one the expansion adds (the hosted app makefiles list their link objects, so the implicit `use` alone is
    enough there).
  - **Linux goldens stale, to be regenerated on a Linux host in lock-step** (the Linux ports were not touched and the Mac cannot
    regenerate them): all 16 in `trials/ffi_addition/app_transport_tcp_loopback`, that is `{Carrier, dangerous_sockets,
    dangerous_tcp_carrier, dangerous_tcp_loopback, dangerous_udp_carrier, dangerous_udp_loopback, wire_etf, wireframe}` with
    `.linux_aarch64.ascomp` and `.linux_x86_64.ascomp`. Two causes: this stage's two new `Carrier.silica` atoms renumber atom
    indices in every unit of the suite, and the earlier, already pushed carrier work (the `provides` rename and comments in
    `Carrier.silica`, whose byte offsets name the `L_case_o<offset>` labels; the multi-peer rewrite of
    `dangerous_tcp_carrier.silica`; the loopback sources) had already staled some of them. The Linux
    `transport_err_not_on_target.linux_*.golden_fail` are unaffected (the message did not change). The Apple goldens were
    regenerated from the compiler built from this tree (`compiler/build/apple_silicon_mac/silica-compiler`); the published
    `binaries/silica-compiler` predates `carried_on` and cannot compile the link trials until it is republished.
  - Not done: the hosted interface links bind nothing yet (`(:interface, name)`, `(:ethernet, n)`, `(:wifi, n)` are
    accepted and spawn the plain carriers; no `getifaddrs`, no `(:explicit, :link_unavailable)` at open, so the
    `link_interface_absent` / `link_family_absent` trials of the links design §10 wait); E2416 (phase D); the Linux
    and Nucleo pack rows; UART2; the supervised board bring-up (no `:device` flavor). Decisions for Lee: the parser
    (a shared stage) reads the pack's `carrier_spawn` text, as `sir_target_verify` reads `provides_format`, which is
    the pack-as-data pattern of the transport design §6.0 and not a target hook in the front end; the one-atom
    `(:usb_serial_jtag)` joined the link vocabulary (the design listed `(:usb_cdc, n)` only); on the board
    `spawn_dangerous_carrier` answers a `device_actor_ref` because the carrier is a device worker; E2415 is limited to
    exclusive hardware (two carriers on `(:loopback)` are allowed, as the loopback app needs).

- **Stage S-D, 2026-11-10: end to end over the native USB-C jack, on the board, with the Silica peer and with the
  Erlang peer; the board drives the LED each reply names. The readings are synthetic. The pairs now live in
  `examples/transport_pairs/`.** The board's MMA8452Q is on I2C0, and the I2C0 worker is not built
  (esp32s3_board_peripherals_plan.md item 2). The board therefore sends four readings from a fixed table in the
  program, as `(x, y, z, at_ms)`: `(1, -2, 512, 1000)`, `(3, 1, 100, 1250)`, `(-5, 4, 300, 1500)`, `(0, 0, -480, 1750)`.
  Row 0 is the §13.4 reading. Nothing reads the sensor. Built:
  - **The board program,** `examples/transport_pairs/usb_accel_led_erlang_and_silica/accel_led_board/device_usb_accel_led.silica`
    (first written as `board/apps/silica_34_transport_usb_accel_led`).
    - It declares `carried_on usb: (:serial) (:usb_serial_jtag);` and registers its owner as `:accel_owner`.
    - The supervisor's one plain worker spawns the GPIO worker, an LED printer and the carrier, because device workers
      cannot be supervisor children. The GPIO worker (`device_esp32s3_gpio@gpio_worker`) starts with GPIO2/4/5/6 made
      outputs and off.
    - It runs in lockstep, one frame in flight. Reading i is encoded, framed and sent as one `:tx`. The reply is
      unframed and decoded into `(:led, { which, on })`. `which` maps to the board's pins (all active high): `:red`
      GPIO2, `:green` GPIO4, `:blue` GPIO5 (the RGB LED), `:single` GPIO6 (LED1).
    - For each reply the owner casts the GPIO worker three messages: a `:write` of the pin; a `:hold` of 1000 ticks,
      about 1 s, so each state is easy to see (added at Lee's request); and a `:notify` of `pin * 2 + level` to the
      printer. The printer prints `rgb red on|off (gpio2)` in the worker's message order, after the pin was written and
      held, then casts `(:driven, level)` back. Only then is reading i + 1 sent.
    - The frames are 52, 46, 52 and 49 bytes, all under the 64-byte IN FIFO. The FIFO never holds more than one frame,
      and the credit (8, then 1 per `:tx`) is never short.
    - After the fourth `:driven`, the board sends the end-of-stream frame `(:done, 4)` (15 bytes framed; Lee's decision
      after the first report). It closes the carrier at that `:tx`'s credit, and `:link_down :closed` ends the program
      with status 0.
    - `expected.scout` was written from the source. The first board run put `tx credit 8` after the first `reading`
      line, because the owner handles `:link_up` (which sends reading 1) before the queued `:tx_credit`. That order is
      deterministic, and the golden follows the board.
  - **The rule and the peers.** In both peers, `z > 256` gives `(:led, { which: :red, on: true })`, otherwise
    `on: false`.
    - The Silica peer, `mac_peer/dangerous_accel_led_peer.silica`, answers every reassembled reading. On `(:done, n)`
      it closes the port at once. Its fallback: it closes when no reading arrives within 3 s of its last reply. The
      fallback was raised from 1.5 s when the 1 s hold was added; it keeps a board program without `(:done, n)`
      working. To tell a reading from the end frame, it decodes as a reading first and as `(:done, int64)` when that
      is rejected.
    - The Erlang peer, `mac_peer/accel_led_peer.erl`, does the same. It encodes with
      `term_to_binary(T, [deterministic])`, because OTP 26 and later order small-map atom keys by the atom table (OTP 28
      here wrote the reading map `y, x, z, at_ms`). `deterministic` gives term order (`on, which`), which is the order
      Silica's `encode` writes record fields. It prints fixed fields rather than the map, so its output can be
      compared.
    - `programmer_tools/transport_beam_demo/silica_peer.erl` is back to its original one-reading form; the pairs have
      their own peers.
  - **`examples/transport_pairs/`,** created at Lee's request: one directory per board/Mac pair.
    - Each pair has its board program (a directory that `board/tools/run_app.sh` builds from any path, so `run_app.sh`
      needed no change), its Mac peers in `mac_peer/`, expected output, a README and a `run.sh`. The shared steps are
      in `lib/pair_lib.sh`, which also holds `find_usb_serial_jtag_port.py`.
    - An index `README.md` and `run_all.sh` run the pairs one at a time and report PASS / FAIL per pair.
    - A pair's check covers: the board console against `expected.scout` (`run_app.sh`), the peer's exit status, the
      peer's output against `expected/<peer>_peer.out` (the port name normalised), and, for the Erlang runs, the bytes
      the bridge moved each way against `expected/to_mac.hex` / `to_board.hex`.
    - `usb_accel_led_erlang_and_silica/run.sh --fake` runs both peers against `fake_board_readings.py` on a raw pty and
      checks their replies byte for byte, with no board.
    - The pairs: `usb_basic_exchange` (the S-A program `silica_33_transport_usb_serial_jtag_etf`, moved, with the S-A
      Silica peer and an Erlang peer printing fixed fields); `usb_accel_led_erlang_and_silica` (this stage);
      `usb_silica_pair` (Silica on both ends, requests from both sides: written by another session as
      `board/apps/silica_35_transport_usb_silica_pair` and `programmer_tools/transport_usb_silica_pair`, moved here
      unrun). The UART1 pair is listed but not included: it needs an adapter on the UART1 header.
    - Pointer READMEs stay at `programmer_tools/transport_usb_serial_jtag_demo/` and
      `board/apps/silica_33_transport_usb_serial_jtag_etf/`, because older documents and this log name them.
  - **Two compiler defects, found on the Silica pair's first run.** Both are worked around in the pair's sources, not
    fixed.
    - A conversion call written as an argument (`take_request(st, to_int64(rid), body)`) is evaluated in X0 after the
      first argument was placed there, so the callee receives the id as its state record. On the Mac this was a fault
      at address 0x9 in `serve_accel`, read from the `.sams`. On the board the same source ended with the carrier's
      `(:explicit, :actor_not_found)` and a timeout, and it matched once `id: int64 <- to_int64(rid)` was bound first.
      The Xtensa assembly was not inspected.
    - Its author had already recorded the second: a nested tagged-tuple literal written straight into `encode` is
      encoded flattened.
  - **The board trial was withdrawn.** For a while `trials/transport_board_addition/device_usb_serial_jtag_accel_led_tx`
    existed (output matched on the board). It was withdrawn when the pairs moved to `examples/`: the pairs are examples,
    not trials. The suite's `Makefile`, `README.md` and four `.esp32_s3.ascomp` goldens are back to their committed
    state, and the suite is 9 / 9 on the board again.
  - **Runs** (2026-11-10):
    - Setup: board console `/dev/cu.usbserial-8310`, native jack `/dev/cu.usbmodem83201` found by 303A:1001; IDF 6.1
      Python and esptool; `compiler/build/ESP32-S3_raw/silica-compiler` for the board,
      `compiler/build/apple_silicon_mac/silica-compiler` for the Silica peers.
    - `examples/transport_pairs/run_all.sh`: PASS for all three pairs, with both peers for the basic and accel/LED
      pairs.
    - Accel/LED board console, both peers: `link up usb_serial_jtag`, `reading 1 x=1 y=-2 z=512 at_ms=1000`,
      `tx credit 8`, `sent 52 bytes`, `led red on`, `rgb red on (gpio2)`, ... (readings 2 to 4: 46, 52, 49 bytes, off /
      on / off), `done 4 readings`, `sent 15 bytes`, `link down :closed`, status 0.
    - The bridge showed the replies `0000002383680277036c6564740000000277026f6e770474727565770577686963687703726564`
      (on, 39 bytes) and `0000002483680277036c6564740000000277026f6e770566616c7365770577686963687703726564` (off,
      40 bytes), alternating, and the board's `0000000b8368027704646f6e656104` (`(:done, 4)`). On the pty, the Silica
      peer's replies are the same bytes.
    - The Silica pair matched its `expected.scout` (`reply 1 led on`, `reply 3 led off`, `served 2 status requests`)
      after the workaround. Before it, the Mac peer faulted and the board printed `framing rejected :too_large`.
    - Earlier in the stage, before the RGB mapping, `(:done, n)` and the hold, the same flow driving LED1 matched
      twice with both peers, and `silica_33` matched with the looping peers.
    - `make integrate TRIAL_TARGET=ESP32-S3_raw TRIAL_SUITES=transport_board_addition`: 9 / 9.
    - `transport_beam_demo/run_demo.sh` exit 0.
    - No compiler source changed; no Apple suite was touched.
  - **Found on the way** (already broken, fixed because the Erlang peer was re-checked on its own demo):
    - `transport_beam_demo/run_demo.sh` still linked `carrier.silica` (E1009 since the rename to `Carrier`).
    - `dangerous_telemetry.silica` lacked the `transport` effect in two sequences (E3013).
    - Its watchdog subshell is now disowned.
    - The demo sometimes prints `link down: :closed` after `done` (status 0 either way); this is noted in its README.
  - **Not covered:**
    - real sensor data (I2C0, item 2);
    - more than one frame in flight in the accel/LED pair (the Silica pair has several);
    - framing recovery after a lost byte and the CP2102N path (S-E);
    - the two compiler defects above.

## 8. Change of target (2026-11-09): serial over USB-C; Wi-Fi deferred

**Why.** The test networks did not work out: the iPhone hotspot on this carrier is IPv6-only (the Mac got a CLAT
`192.0.0.2/32` and `nat64`, no IPv4 subnet), and macOS Internet Sharing would not start, first refusing the 802.1X campus
Ethernet as a source, then not applying the Wi-Fi settings with Thunderbolt Bridge as the source. Neither was a board
problem. The Wi-Fi radio work (stages 3 to 9) is **deferred, not cancelled**; R2 remains the chosen route when it resumes,
and the stage text above stays valid. The IPv6-only finding is recorded here because it also means a hotspot on this
carrier would need IPv6 in the board's stack.

**New target.** BEAM-codec (ETF) frames between the Apple Silicon Mac and the ESP32-S3 over USB-C serial, in both
directions, with the Mac peer either a Silica program (`(:serial)` carrier) or an Erlang node (through the existing
serial-to-TCP bridge of `programmer_tools/transport_uart1_demo`).

**The two USB-C paths on the board** (transport design §6.4):

| Path | Carrier tag | Host sees | State | Notes |
| --- | --- | --- | --- | --- |
| USB-UART jack (CP2102N to UART0) | `(:uart0)` | `/dev/cu.usbserial-*` (the board is on it now: `-8310`) | UART worker exists for the console only | the runtime console shares UART0, so frames interleave with prints unless the program prints nothing; the run/capture tooling also reads this port |
| native USB-C jack (USB-Serial-JTAG) | `(:usb_serial_jtag)` | `/dev/cu.usbmodem*`, 303A:1001 | **carrier exists, both directions (S-A, 2026-11-09, §7)**, beside the item F console worker | a second console on its own port; no console interleaving; device role only; the chosen path |

**Stages (replace stages 3 to 9 for now).**

- **S-A. Carrier worker on the chosen USB path.** Generalise the stage-1 UART worker to the chosen path, with both
  directions (`:tx` and `:rx`), the §6.2 contract and the pack rows; board demo sends an ETF frame and receives one.
  **Done 2026-11-09 on the USB-Serial-JTAG path (§7).**
- **S-B. Mac side.** `(:serial)` carrier against the port (macOS termios, already built); Silica peer and the Erlang peer
  through the bridge; both directions, with the real board. **Done with S-A for both peers (§7); the hosted carrier
  needed no change.**
- **S-C. Link naming (old stage 2).** `carried_on` with `(:usb_serial_jtag)` / `(:uart, 1, baud)` (UART0 is the console and is
  rejected, decision 17), `Link.silica`, E2412 to E2415 and E2417 (E2416 is phase D), `spawn_dangerous_carrier`;
  `getpeername` stays a Wi-Fi item. **Done 2026-11-09 on the Mac and the board (§7).**
- **S-D. End to end.** The board sends accelerometer readings; the Mac replies with an LED command; the same with the
  Erlang peer. Run by script outside `make integrate`, like the BEAM demo.
  **Done 2026-11-10 with both peers on the board (§7); the readings are a fixed synthetic table, not the
  MMA8452Q (the I2C0 worker, peripherals plan item 2, is not built). Run by `examples/transport_pairs/run_all.sh`.**
- **S-E. Hardening and docs.** Framing recovery after a lost byte, flow control (no hardware flow control on the CP2102N
  path: lossy under sustained load per §6.4), the console-interleaving rule, status in the designs.
