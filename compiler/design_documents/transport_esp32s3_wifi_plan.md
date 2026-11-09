# ESP32-S3 Wi-Fi TCP transport to a Mac and a BEAM node: Phase D plan and development plan

Status: **target changed by Lee, 2026-11-09: serial over USB-C is the transport between the Mac and the board; the Wi-Fi
stages (3 to 9) are deferred (§8).** Route R2 was chosen for Wi-Fi (§3) and stays the Wi-Fi route when it resumes. Stage 1
is closed (§7); stage S-A and the board part of S-B are done (§7, 2026-11-09). Stage results are recorded in §7. It refines Phase D of
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
- **S-C. Link naming (old stage 2).** `carried_on` with `(:usb_serial_jtag)` / `(:uart, 0, baud)`, `Link.silica`, E2412 to E2417,
  `getpeername` stays a Wi-Fi item.
- **S-D. End to end.** The board sends accelerometer readings; the Mac replies with an LED command; the same with the
  Erlang peer. Run by script outside `make integrate`, like the BEAM demo.
- **S-E. Hardening and docs.** Framing recovery after a lost byte, flow control (no hardware flow control on the CP2102N
  path: lossy under sustained load per §6.4), the console-interleaving rule, status in the designs.
