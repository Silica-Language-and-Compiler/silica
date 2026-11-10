# Bluetooth Low Energy transport, `(:ble_gatt)`: development plan

Status: **plan, 2026-11-10. Nothing here is built. The route and the vocabulary are decided (§8: Matt Manley,
2026-11-10); the decisions have not been reviewed by Lee.** It refines §6.5 and phase 5 of
[transport_serialization_design.md](transport_serialization_design.md) (the "transport design" below) and follows the
shape of [transport_esp32s3_wifi_plan.md](transport_esp32s3_wifi_plan.md) (the "Wi-Fi plan"). Link naming is from
[transport_links_design.md](transport_links_design.md) (the "links design"). Branch: `ble-transport-support`, cut from
`binary-transport-support` at `9370085098`. Facts below were read from those three documents,
`compiler/stdlib` (`Carrier`, `Link`, `wireframe`, `dangerous_serial_carrier`, `dangerous_sockets`) and the Mac and
ESP32-S3 transport packs; anything not checked is marked *(unverified)*.

## 1. Goal

An ESP32-S3 board (BYU-Idaho v4.0) and an Apple Silicon Mac exchange Silica values over Bluetooth Low Energy:

- **Codec:** ETF, `(:etf)`, with `wireframe` between `encode` and the carrier, as in the serial demos.
- **Carrier:** one tag, `(:ble_gatt)`, speaking the carrier contract of transport design §6.2 on every target.
- **Order (transport design §6.5):** the hosted carrier first, because it needs no radio decision and gives the trials
  a peer; then the board through an external module on the UART1 header; the chip's own radio stays deferred with
  Wi-Fi (§3).
- **Demo:** the accelerometer frame and the LED reply of `silica_33_transport_usb_serial_jtag_etf`, over BLE.

## 2. What is built, and what is not

Built (checked 2026-11-10 on `binary-transport-support`):

- `wireframe@frame` and `unframe` already segment for a `:datagram` carrier whose `mtu` is smaller than the frame: a
  4-byte header `{ frame_seq: uint16, index: uint16 }` per segment, bit 15 of `index` marking the last, `frame_seq`
  always 0. The `mtu` is an argument, so a caller can pass a value learned at run time. Whether a trial covers this
  path is *(unverified)*.
- The hosted carriers are dangerous actors over a C wrapper (`compiler/stdlib/net/silica_sockets.c`, its `.meta`
  sidecar, `dangerous_sockets.silica`): a handle, calls that answer `{ tag, value, error_code }`, and a `send_after`
  poll with a 20 ms timeout. A BLE wrapper can keep that shape.
- `carried_on`, `Link.silica`, the pack functions (`provides_link`, `carrier_spawn`, `carrier_module`, ...) and
  E2412 to E2415 and E2417, on the Mac and the ESP32-S3 only.
- The board's `(:uart1)` carrier (`device_esp32s3_uart1.silica`): it sends; its receive poll compiles and has never run
  on hardware; nothing is wired to the UART1 header; the baud is fixed at 115200.

Not built: any `(:ble_gatt)` row (`Carrier.silica`, every pack), any Bluetooth link tag, any Bluetooth wrapper, any
board module protocol. The Linux packs list no link at all, and their goldens for the transport suites are stale
(Wi-Fi plan §7, stage S-C).

## 3. Routes for the board (decided: M2, 2026-11-10)

| Route | What it is | Cost | Risk |
| --- | --- | --- | --- |
| **M1. Transparent-serial module on UART1** (HM-10 class) | the module owns the radio and the GATT server; the board writes and reads plain bytes | smallest; reuses the UART1 worker | the module decides where notifications are cut, so segment boundaries are not the board's (§8, decision 5); a default of 9600 baud *(unverified)* against the worker's fixed 115200; connection state only through a status pin or text notices *(unverified)* |
| **M2. A second ESP32 running Espressif's AT firmware on UART1** | the board drives the module with AT commands; each notification is sent with an explicit length | moderate: an AT protocol actor above the UART1 worker | needs a second board and its firmware; 115200 by default *(unverified)*; the same module is route R3 of the Wi-Fi plan, so the work is shared |
| **M3. The chip's own radio** | Espressif's closed BLE controller and host as foreign code | largest | the same open question as Wi-Fi route R2 (a polling runtime against code that expects an RTOS); the Wi-Fi radio spike never ran |

**Decision (§8, decision 1): M2**, because it keeps segment boundaries and the negotiated MTU visible to the board, and because the
module serves the Wi-Fi fallback as well. M3 is not started by this plan; it waits for the Wi-Fi radio decision.

## 4. Vocabulary (decided, 2026-11-10)

- **Carrier row** in `Carrier.silica`: `:ble_gatt` with `mtu` 20, `boundaries` `:datagram`, `delivery`
  `:reliable_ordered`, `addressing` `:characteristic`.
  - `mtu` 20 is the floor every connection has (ATT_MTU 23 minus 3). The negotiated value arrives in `:link_up`'s
    `info`, as transport design §6.2 already says; an owner that wants larger segments passes it to
    `wireframe@frame`. The table stays a literal.
  - `:reliable_ordered` holds only if the carrier uses writes with response toward the peripheral and indications
    toward the central. Notifications are faster and `:ordered_lossy`; a segmented frame cannot use them (transport
    design §6.5).
- **Links.** `Link.silica` has no Bluetooth tag. Added:
  - `(:bluetooth, n)` on hosted targets: the host's n-th adapter. CoreBluetooth offers no adapter choice
    *(unverified)*, so the Mac pack would provide instance 0 only.
  - `(:esp_at, n)` on the board, for route M2: an ESP-AT module on UART n. The links design §8 already names this tag
    ("the link there is the module"). It must count as a user of UART n for E2415. Route M1 would need a tag of its
    own.
  - Both carry `:ble_gatt` only (E2414 otherwise).
- **Role and service at `:open`.** The address names the role and the characteristic, in the style of
  `"listen:<port>"`: `"central:<uuid>"` scans and connects; `"peripheral:<uuid>"` advertises and waits.
- **Service.** One service with one characteristic toward each side. The Nordic UART Service UUIDs are the common
  choice and phone test apps know them; a module of route M1 fixes its own.

## 5. Development plan

Each stage ends with its own trials and leaves the tree green on Apple Silicon, with the fixed point re-checked after
any compiler-source change, as in the Wi-Fi plan §4.

### Stage 0. Decisions and hardware (no code)

- The decisions of §8 recorded (done 2026-11-10); a second ESP32 with Espressif's AT firmware in hand.

### Stage 1. macOS spike (time-boxed decision gate)

- An Objective-C wrapper over CoreBluetooth with the manager on its own dispatch queue, behind the same handle and
  tagged-result calls as `silica_sockets.c`; a throwaway Silica program in the central role exchanges bytes with a
  phone test app.
- The open technical questions it answers: whether a Fifi wrapper may be Objective-C and link a framework; whether
  CoreBluetooth's callbacks arrive in a program whose entry is `-e main` and that runs no main run loop; how macOS
  grants the Bluetooth permission to a command-line binary. All three *(unverified)*.
- **Closes when:** bytes cross in both directions, or the reason they cannot is written into §7.

### Stage 2. Vocabulary in the compiler

- The `:ble_gatt` row; the link tags in `Link.silica` and `type_checker_links.silica`; the Mac pack's
  `provides_carrier`, `provides_link`, `carrier_module` and `carrier_spawn`; specification §16.4.8 and §16.4.9;
  error trials for E2410, E2412, E2414 and E2417 on the new tags.
- Costs known from stage S-C: new atoms in `Carrier.silica` renumber the atom indices of every suite that links it
  (Apple goldens regenerated; Linux goldens join the stale set); a full ESP32-S3 cross-compiler rebuild was about
  70 minutes.
- **Closes when:** a program with `carried_on phone: (:ble_gatt) (:bluetooth, 0);` compiles on the Mac and is rejected
  with E2412 on the other targets.

### Stage 3. Hosted `(:ble_gatt)` carrier on macOS

- `dangerous_ble_gatt_carrier.silica` over the stage 1 wrapper: the §6.2 contract, both roles, credit both ways,
  `:link_up` carrying the negotiated MTU, the links design §6.3 failure atoms.
- A loopback trial is not possible on one Mac *(unverified)*, so the run is a script outside `make integrate`, like
  the BEAM demo. The segmentation path of `wireframe` gets a trial that needs no radio.
- **Closes when:** a 48-byte ETF frame, in segments, crosses between the Mac and a second peer in both directions.

### Stage 4. UART1 receive on the board

- Wire the UART1 header (3.3 V) and run the receive path that stage 1 of the Wi-Fi plan left untested. A second baud
  in the worker and in `link_baud_ok` if the chosen module needs it.
- **Closes when:** the board decodes a frame received on UART1.

### Stage 5. Board carrier through the module

- A protocol actor above the UART1 worker that turns the module's connection events into `:link_up` and
  `:link_down` and its data into `:rx`; the ESP32-S3 pack rows; `carrier_spawn` for the pair.
- Known gaps it inherits: a device worker cannot be a supervisor child, so the owner spawns it; decision 15 of the
  links design forbids a board trial that both sends and receives.
- **Closes when:** a board program compiles with `carried_on phone: (:ble_gatt) (:esp_at, 1);` and sends a
  frame the Mac carrier of stage 3 decodes.

### Stage 6. End to end

- The board sends accelerometer readings; the Mac replies with an LED command; both ends Silica.
- **Closes when:** the demo runs by script with only the `carried_on` line differing from the USB-Serial-JTAG demo.

### Stage 7. Linux, hardening and docs

- BlueZ wrapper and the Linux pack rows in lock-step; reconnect; a soak; `frame_seq` if more than one frame is ever in
  flight; the transport design §6.3 to §6.5 and §10, the links design §3.1, the board plan §4.4, the demo README.

## 6. Risks, ranked

1. **CoreBluetooth behind Fifi (stage 1).** Callback-driven framework, permission prompt, Objective-C in the wrapper
   build. The spike answers it cheaply.
2. **The board's receive path (stage 4).** It has never run, and no hardware is attached yet.
3. **Trials.** A radio, a permission and a second device cannot be in `make integrate`; most evidence will be scripted
   runs, as for the board demos.
4. **Throughput.** 16 payload bytes per segment at the default MTU, each acknowledged. Enough for readings, not for
   bulk data.

## 7. Stage log

Empty. Each stage's result is recorded here when it closes: date, what was built, trials, and anything that changed
the plan.

## 8. Decisions (Matt Manley, 2026-11-10)

These were the plan's seven open questions. Each is decided as recommended, and each names the Wi-Fi or serial work it
rests on. They are recorded here so the work can start; Lee has not reviewed them, and a change by Lee is recorded in
§7 with its date.

1. **Board route: M2**, a second ESP32 running Espressif's AT firmware on UART1. M3, the chip's own radio, is left to
   the Wi-Fi radio spike. The Wi-Fi plan built the UART1 carrier first because every route needed it (§3 there), kept
   the AT-firmware modem as the fallback (R3), and made the closed radio libraries a time-boxed spike that has not
   run. M2 is that same modem, so one module and one AT protocol actor serve both plans.

2. **Link tags: `(:bluetooth, n)` and `(:esp_at, n)`.** `(:bluetooth, n)` mirrors `(:wifi, n)`: instance-indexed, and
   resolved through the host on a hosted target (links design decision 11). `(:esp_at, n)` is the tag the links
   design §8 already names for an ESP-AT module; it takes no baud because the pack fixes the UART1 worker at 115200
   (`link_baud_ok`). Stage S-C set the precedent for adding a tag the design had not listed (`(:usb_serial_jtag)`).

3. **`mtu` is the literal 20; the negotiated value arrives in `:link_up`.** Every `Carrier` method body is a literal,
   `Carrier@mtu(<name>)` resolves to the kind's row, and the links design §7 leaves the link-narrowing hook for
   later. `wireframe@frame` takes the `mtu` as an argument, so an owner can use the negotiated value without a
   compiler change.

4. **Role and characteristic go in the `:open` address**, not in the declaration. The links design §4 puts the
   hardware in the declaration and the peer in the address: stage S-C moved the serial path and baud into the
   declaration because they name the port, while TCP kept `"host:port"` and `"listen:<port>"` at `:open`.

5. **No `:stream` framing over a BLE characteristic.** A carrier tag has one literal row, so `(:ble_gatt)` cannot be
   `:datagram` on the Mac and `:stream` on the board. This rules out route M1 as a `(:ble_gatt)` carrier; a
   transparent module would be the kind `(:serial)` on its own link, which this plan does not build.

6. **Decision 15 of the links design holds for BLE trials.** Board trials stay compile-time, assembly, diagnostics
   and one direction. The two-way run is the stage 6 script, outside `make integrate`, as in stage S-A, whose trial
   sends one frame and whose demo against a real peer is the evidence for both directions.

7. **Linux comes after the board.** Stage S-C went Mac and board first: the Linux packs still list no link, and 16
   Linux goldens wait to be regenerated on a Linux host. Until the BlueZ wrapper exists the Linux packs answer false
   for the new tags (E2410, E2412), and the Linux work of stage 7 is done together with that existing debt.
