# Bluetooth Low Energy transport, `(:ble_gatt)`: development plan

Status: **2026-11-10. Stages 1 to 3 are closed (§6); stage 4 is next. The goal, the design and the
vocabulary are decided (§8: Matt Manley, 2026-11-10).** It refines §6.5 and phase 5 of
[transport_serialization_design.md](transport_serialization_design.md) (the "transport design" below). Link naming is
from [transport_links_design.md](transport_links_design.md) (the "links design"). The board's radio is hosted as
[transport_esp32s3_wifi_plan.md](transport_esp32s3_wifi_plan.md) (the "Wi-Fi plan") decided, its route R2. Branch:
`ble-transport-support`, cut from `binary-transport-support` at `9370085098`. Anything not checked is marked
*(unverified)*.

## 1. Goal

A Silica program reaches other Bluetooth Low Energy devices through one carrier, `(:ble_gatt)`, declared the same way
on a Mac and on an ESP32-S3 board (BYU-Idaho v4.0):

```
carried_on phone: (:ble_gatt) (:bluetooth, 0);
```

- **Contract:** the carrier contract of transport design §6.2 on every target, in both roles (central and
  peripheral). A program written against the Mac carrier runs against the board carrier unchanged.
- **Codec:** ETF, `(:etf)`, with `wireframe` between `encode` and the carrier, as in the serial demos.
- **On the board, the Bluetooth host is written in Silica**, as actors, above Espressif's closed controller (§2).
- **Demo:** the accelerometer frame and the LED reply of `silica_33_transport_usb_serial_jtag_etf`, over BLE, between
  the board and the Mac.
- **Hardware:** one board. Its peers are the Mac and a phone.

## 2. Design

Bluetooth has two halves that meet at a standard interface, the Host Controller Interface (HCI). The **controller**
owns the radio and the link timing. The **host** owns connections, services and characteristics (GAP, L2CAP, ATT and
GATT).

| Layer | On the Mac (built, stage 3) | On the ESP32-S3 board (stages 4 to 8) |
| --- | --- | --- |
| Program | casts to the carrier, receives from it | the same program |
| Carrier, the owner-facing end | `dangerous_ble_gatt_carrier`, a dangerous actor | an actor with the same messages |
| Host | CoreBluetooth, behind an Objective-C Fifi wrapper | **written in Silica**, as actors |
| HCI | inside macOS | one Silica actor owns it |
| Controller and radio | macOS and Apple's hardware | Espressif's closed controller, run by ESP-IDF |
| Who owns the machine | macOS; Silica's runtime is its guest | ESP-IDF and FreeRTOS; Silica's runtime is their guest |

### 2.1 The board: Silica as a guest of ESP-IDF

Espressif's controller is closed code written for FreeRTOS and for ESP-IDF's hardware support (radio calibration,
clocks, power, timers, interrupts). The radio hardware is not documented, so the controller stays, and it runs in the
environment it was written for:

- **ESP-IDF owns the chip.** Its bootloader and start-up run first, its vector table and watchdogs stay, and
  FreeRTOS schedules both cores. It is built with the Bluetooth controller and **without a Bluetooth host**.
- **Silica's runtime is a guest, as it is on the Mac and on Linux.** Its two schedulers, one per core, each run as
  a FreeRTOS task on the core they use today. Actors stay pinned to their core and are never interrupted by another
  actor; FreeRTOS pauses a scheduler task briefly when the radio needs the core, and the actors see only that a turn
  took longer. Silica takes its memory as a block from ESP-IDF.
- **This is a new target beside `ESP32-S3_raw`, not a change to it.** The new target shares the raw target's code
  generation and its scheduler logic and replaces the parts that own the chip: start-up, the vector table, the
  memory layout, and polling with interrupts masked. `ESP32-S3_raw` stays as it is, owning the chip, for programs
  that need no radio. A program that wants the radio is built for the new target.
- **HCI is the boundary.** ESP-IDF hands HCI packets to the application through its virtual HCI calls *(the
  configuration for the ESP32-S3 is unverified)*. They are foreign code, reached through Fifi.
- **AtomVM's ESP32 port is the model**: an actor runtime started by ESP-IDF, with its schedulers as tasks and radio
  events delivered as messages. It is open source.

### 2.2 The actors above HCI

- **The HCI actor** owns the pipe to the controller. Every packet the controller sends becomes a message; every
  command and data packet is a cast to it.
- **One connection actor per link** holds that link's state (the negotiated MTU, the subscription, the credit), as
  the TCP listener spawns one connection carrier per accepted peer. Two peers are two actors, and one failing does
  not touch the other.
- **The carrier** is the owner-facing end of a connection actor and speaks the §6.2 contract.
- A lost link is an actor ending, handled by supervision (links design §6.3), not a value the sender checks.

### 2.3 Outside this plan

These are not built by any stage here, and no stage's code should lean toward them.

- **Silica owning the chip with the controller as its guest** (the Wi-Fi plan's R1). The Silica host would not
  change, because it speaks HCI either way. It is a possible later project, considered only once stage 8 has closed.
- **A second chip as a modem.** Dropped.
- **Espressif's own Bluetooth host, or any host in C, on the board.** The host is Silica from the start.
- **A controller written in Silica.** Not possible: the radio hardware is undocumented.

## 3. Vocabulary

- **Carrier row** in `Carrier.silica`: `:ble_gatt` with `mtu` 20, `boundaries` `:datagram`, `delivery`
  `:reliable_ordered`, `addressing` `:characteristic`.
  - `mtu` 20 is the floor every connection has (ATT_MTU 23 minus 3). The negotiated value arrives in `:link_up` as
    `"mtu:<n>"`; an owner that wants larger segments passes it to `wireframe@frame`.
  - `:reliable_ordered` holds because the carrier uses writes with response toward the peripheral and indications
    toward the central, never notifications (transport design §6.5).
- **Link:** `(:bluetooth, n)`, the n-th Bluetooth adapter of the target. It carries `:ble_gatt` only (E2414
  otherwise). The Mac provides instance 0 (CoreBluetooth offers no choice of adapter); the board will provide
  instance 0, the chip's own radio.
- **Role and service at `:open`.** `"central:<uuid>"` scans for the service and connects; `"peripheral:<uuid>"`
  advertises it and waits. `<uuid>` is the service's UUID; nothing after the colon means the Nordic UART Service,
  which phone test applications know.
- **Service.** One service with one characteristic toward each side. A peripheral publishes them at the service's
  UUID plus 1 (written by the central) and plus 2 (indicated to the central) in the UUID's first group, the Nordic
  UART pattern; a central finds them by their properties.

## 4. Stages

Each stage ends with its own trials and leaves the tree green on Apple Silicon, with the fixed point re-checked after
any compiler-source change.

### Stage 1. macOS spike (closed, §6)

Whether CoreBluetooth can sit behind a Fifi wrapper in a program with no main run loop.

### Stage 2. Vocabulary in the compiler (closed, §6)

The kind and the link in the compiler's checks, the specification and the error trials.

### Stage 3. Hosted `(:ble_gatt)` carrier on macOS

- `dangerous_ble_gatt_carrier` over a CoreBluetooth wrapper: the §6.2 contract, both roles, credit both ways.
- The rows in `Carrier.silica`, `Link.silica` and the Mac pack.
- A segmentation trial that needs no radio; the two-way run is a script outside `make integrate`.
- **Closes when:** a program with `carried_on phone: (:ble_gatt) (:bluetooth, 0);` compiles on the Mac and is
  rejected with E2410 on the other targets, and a 48-byte ETF frame, in segments, crosses between the Mac and a
  second peer in both directions.

### Stage 4. Board spike: Silica as a guest of ESP-IDF (time-boxed decision gate)

The new target of §2.1, far enough to answer whether it works. It is also the radio spike the Wi-Fi plan left
unrun, so its result serves both plans.

- Read first: AtomVM's ESP32 port, and which parts of Silica's board runtime own the chip (`rt_start.S`,
  `rt_vectors.S`, the linker script, the watchdog and interrupt handling) against which do not (the schedulers,
  mailboxes, stacks, supervision).
- Build: an ESP-IDF application, with the controller and no Bluetooth host, that starts Silica's two schedulers as
  two tasks and runs an existing board program on them.
- Questions it answers:
  1. Do Silica's schedulers and an existing board program run unchanged as tasks under ESP-IDF, and what in the
     runtime had to be replaced to get there?
  2. Does a Silica program send an HCI Reset through the virtual HCI calls and receive the Command Complete event?
  3. What do ESP-IDF and the controller cost in flash and RAM, and what is left for the program?
  4. How is an image of the new target built, flashed and trialled?
- Throwaway code, as stage 1 was. Hardware: the board.
- **Closes when:** a Silica program on the board prints the controller's answer to an HCI Reset, or the reason it
  cannot is written into §6. If it cannot, the plan stops there and is reconsidered with what the spike found; no
  other route is started without that.

### Stage 5. The new target, and HCI as an actor

- The new target in the compiler and the board tools, in place of the spike's throwaway code: its pack, its
  start-up and memory pieces, its image build, and the existing board trials run on it.
- The HCI actor (§2.2) over the virtual HCI calls, through a Fifi wrapper.
- The host's first piece in Silica: set the advertising data and start advertising.
- **Closes when:** a phone's scanner shows the board advertising the service.

### Stage 6. The board carrier, peripheral role

- The Silica host, the least that one service needs: accept a connection, the MTU exchange, an attribute table with
  the service and its two characteristics, writes with response in, indications out, disconnection.
- The connection actor and the carrier (§2.2); the new target's pack rows; `carrier_spawn`; board trials
  (compile-time, assembly, diagnostics and one direction, §8 decision 7).
- No pairing and no encryption (§8, decision 4).
- **Closes when:** a board program compiles with `carried_on phone: (:ble_gatt) (:bluetooth, 0);` and exchanges a
  segmented frame with a phone.

### Stage 7. End to end: Mac and board

- The Mac as central, the board as peripheral: the board sends accelerometer readings, the Mac replies with an LED
  command; both ends Silica. This is also the first run of the Mac carrier's central role against a real peripheral.
- **Closes when:** the demo runs by script with only the `carried_on` line differing from the USB-Serial-JTAG demo.

### Stage 8. Central role on the board

- The host's central side: scan, connect, discover the service, subscribe, write.
- **Closes when:** the board as central and the Mac as peripheral exchange the frame.

### Stage 9. Hardening, Linux and docs

- Pairing and encryption; reconnect; a soak; `frame_seq` if more than one frame is ever in flight.
- BlueZ wrapper and the Linux pack rows in lock-step with the stale Linux goldens of the Wi-Fi plan's stage S-C.
- The transport design §6.3 to §6.5 and §10, the links design §3.1, the board plan §4.4, the demo README.

## 5. Risks, ranked

1. **Silica's runtime as a guest of ESP-IDF (stage 4).** The board runtime was written to own the chip: it replaces
   the bootloader, masks interrupts and polls, and lays out all of memory. How cleanly those parts separate from the
   schedulers is not known. The spike answers it before anything is built on it.
2. **The size of the Silica host.** A one-service peripheral is small; the central role and pairing are not. Stages 6,
   8 and 9 take them in that order so each closes on its own.
3. **No pairing or encryption until stage 9.** Any nearby device can connect and read or write the link. Nothing
   sensitive crosses it before then.
4. **Trials.** A radio and a second device cannot be in `make integrate`; most evidence is scripted runs, as for the
   board demos.
5. **Throughput.** 16 payload bytes per segment at the default MTU, each acknowledged. Enough for readings, not for
   bulk data.

## 6. Stage log

Each stage's result is recorded here when it closes: date, what was built, trials, and anything that changed the plan.

- **Stage 1, 2026-11-10, closed: the three technical questions are answered yes, and bytes crossed in both
  directions between a Silica program on the Mac and an iPhone.** Built, all in `programmer_tools/transport_ble_spike` (throwaway):
  - `silica_ble.m`: an Objective-C wrapper over CoreBluetooth in the shape of `silica_sockets.c` (tagged results,
    every call bounded by a timeout, received bytes through a `take`). The managers deliver callbacks on a private
    serial dispatch queue and the calls wait on a condition. Roles: central, peripheral, scan only. Service: the
    Nordic UART Service; the central writes with response, the peripheral sends by indication.
  - `harness.c`: drives the wrapper from plain C with no run loop. `dangerous_ble.silica` and
    `silica_ble_wrapper.meta`: the wrapper as a dangerous module. `dangerous_ble_spike.silica`: a dangerous actor that
    polls the wrapper between mailbox messages and reports to a plain owner actor. `run_spike.sh` builds and runs
    either.
  - Runs (macOS 26.6.2, Apple clang 21, `binaries/silica-compiler`): `run_spike.sh --c scan`: open ok, 35
    advertisers counted in 5 s. `run_spike.sh scan`, the Silica program: `open tag=0`, `advertisers seen=31`, exit 0.
  - Answers: (1) a Fifi wrapper can be Objective-C and link `CoreBluetooth` and `Foundation`: the archive is built
    with `/usr/bin/clang -fobjc-arc` and the two `-framework` flags are added to the program's link line; the
    compiler needed no change. (2) The callbacks arrive with the entry `-e main` and no main run loop, on the dispatch
    queue the manager was given, both from C and from a dangerous actor's thread. (3) The manager reported powered
    on and scanned when started from a terminal inside VS Code. Whether macOS showed a permission prompt, and to
    which application it attributes the permission, was not observed; the binary carries an
    `NSBluetoothAlwaysUsageDescription` in an embedded `Info.plist` section in case it is needed.
  - Loopback on one Mac: a peripheral process and a central process of the harness on the same Mac did not find each
    other in 15 s (one attempt). Stage 3's two-way run needs a second device.
  - The exchange (Mac as peripheral, `SILICA_BLE_TRACE=1 run_spike.sh peripheral`; iPhone with nRF Connect as the
    central): the phone enabled indications on the TX characteristic and the program printed `link up, mtu=512` and
    `sent, tag=0`; the phone showed `hello from silica`. The phone wrote `hi mac` to the RX characteristic and the
    program printed `rx: hi mac` and `sent, tag=0` for its `ack from silica`. The wrapper's trace showed the write as
    one request of 6 bytes on `6E400002`.
  - Found on the way:
    - `maximumUpdateValueLength` answered 512 for the iPhone, above the 244 the transport design §6.3 gives as the
      ceiling. The carrier row's literal 20 (§8, decision 5) is unaffected; the value `:link_up` carries can be larger
      than the design says.
    - A central that unsubscribes can still write and can subscribe again. The spike's wrapper ignores the
      unsubscription; stage 3's wrapper treats it as the end of the link (stage 3, below).
    - Every start of the program publishes the service again. A phone that stays connected to the Mac across a
      restart was seen to subscribe again on its own.
    - Several test writes were lost because they were sent to the Characteristic Extended Properties descriptor
      (2900) that macOS adds under the RX characteristic, not to the characteristic; nRF Connect shows a write
      button for both. Two changes made during that search (Write Without Response on the RX characteristic, strong
      references to the RX characteristic and the service) were backed out afterwards and the exchange was run
      again with the same result, so the RX characteristic is Write only.
  - Not covered: the central role against a real peripheral (the code exists and has only scanned); more than one
    segment; a frame through `wireframe` and ETF; timeouts and the failure paths; which application macOS credits
    with the Bluetooth permission. These are stage 3's.

- **Stage 2, 2026-11-10, closed: the compiler knows the vocabulary and checks it; no target provides it yet.**
  The stage was kept to checks only: the rows in `Carrier.silica`, `Link.silica` and the Mac pack waited for stage 3,
  so that the goldens they change were regenerated once, with a carrier that works, and no stub carrier was committed.
  - Built: in `type_checker_links.silica`, the kind `(:ble_gatt)` and the link `(:bluetooth, n)`, which takes one
    integer and carries only `(:ble_gatt)`; the kind is named in the E2408 text and the link in the vocabulary that
    the E2413 and E2417 texts print. Specification §16.4.9. The stage also added a second link, `(:esp_at, n)`, for a
    modem route that was planned then; stage 3 removed it when that route was dropped.
  - Trials, in `trials/error_enforcement_addition`: `link_ble_kind_not_provided` (E2410),
    `link_ble_link_cannot_carry_tcp` (E2414), `link_ble_kind_on_loopback` (E2414), `link_ble_adapter_missing` (E2417).
    Three goldens recorded again because the texts they hold list the new names: `link_kind_unknown`,
    `link_parameter_missing`, `link_unknown`.
  - Results (apple_silicon_mac): `make -C trials integrate JOBS=6`: 35,157 passed, 0 failed.
    `build_all_platforms.sh --targets "apple_silicon_mac"`: 374 units compared, none emitted differently by gen2
    than by gen1, gen3 byte-identical to gen2. The other targets were not built or run.
  - No compiler binary is committed with the stage. `binaries/silica-compiler` on this branch does not know the new
    names until a binary is published in the usual way.

- **Stage 3, 2026-11-10, closed: the hosted `(:ble_gatt)` carrier is built on the Mac, and a 48-byte ETF frame
  crossed in segments in both directions between a Silica program and an iPhone.**
  - Built:
    - `compiler/stdlib/ble/silica_ble.m` and `silica_ble_wrapper.meta`: the CoreBluetooth wrapper, from the stage 1
      spike. New in it: the service UUID is given at open, up to four sessions, the reason a link went down
      (closed, lost, fault), and a check of the UUID text before CoreBluetooth sees it. The scan-only role is gone.
    - `compiler/stdlib/dangerous_ble.silica` (the bindings) and `dangerous_ble_gatt_carrier.silica` (the carrier):
      the §6.2 contract in both roles; `:link_up` carries `"mtu:<n>"`; `(:tx_failed, :too_long)` for a segment
      longer than the link's mtu; `:link_down` with `:closed`, `:timeout` or `:fault`; a segment that arrived
      before the link went down is still delivered.
    - Rows: `:ble_gatt` in `Carrier.silica`; `:bluetooth` in `Link.silica`; the Mac pack's `provides_carrier`,
      `provides_link` (instance 0 only), `provided_links`, `carrier_module` and `carrier_spawn`.
    - Specification §16.4.8 (the carrier's row and a paragraph) and §16.4.9; one row of the transport design §6.3.
    - `programmer_tools/transport_ble_demo` (`dangerous_ble_peer.silica`, `run_peer.sh`): the two-way run.
  - Settled while building:
    - The UUID in the `:open` address names the service, not a characteristic: the service has two (§3).
    - A central that unsubscribes ends the link for a peripheral. It is the only sign CoreBluetooth gives a
      peripheral that its central went away.
    - `(:esp_at, n)`, added in stage 2, is removed from the compiler, `Link.silica`, the specification and the
      trials: the modem route it named is not built (§2.3).
  - Trials:
    - `transport_addition/transport_ble_segments` (new, no radio): a 48-byte frame at the row's mtu is three
      20-byte segments and reassembles; a short last segment; a frame the mtu holds travels bare; a negotiated
      mtu of 185 gives one segment; a frame with a segment missing is rejected (`:bad_tag`). Its `.scout` was
      derived by hand from transport design §5 before the first run.
    - `transport_carrier_tags` and `transport_link_tags`: the `:ble_gatt` row, the `(:bluetooth, n)` link and a
      carrier declared on it; `.scout` updated by hand.
    - `error_enforcement_addition`: `link_ble_adapter_not_provided` (new, E2412 for `(:bluetooth, 1)`);
      `link_ble_kind_not_provided` and `link_esp_at_uart_conflict` removed (the first now compiles on the Mac, the
      second names the removed link). Goldens recorded again because their texts list the links:
      `link_ble_adapter_missing`, `link_ble_kind_on_loopback`, `link_not_provided_hosted`, `link_parameter_missing`,
      `link_unknown`, `dangerous_link_spawn_not_provided`.
    - Apple assembly goldens recorded again, 25 files: the two new atoms (`:ble_gatt`, `:characteristic`) are in the
      atom table of every suite that links `Carrier.silica`, and the indices after them move. Read before
      recording: the differences are the table and the indices. `transport_addition` (17, with the new trial's)
      and `ffi_addition/app_transport_tcp_loopback` (8).
  - Results (apple_silicon_mac, the compiler built from this tree):
    - `make -C trials integrate JOBS=6`: 35,158 passed, 0 failed.
    - `build_all_platforms.sh --targets "apple_silicon_mac ESP32-S3_raw"`: 374 units compared, none emitted
      differently by gen2 than by gen1, gen3 byte-identical to gen2; the ESP32-S3 cross compiler built.
    - `carried_on phone: (:ble_gatt) (:bluetooth, 0);` compiles on the Mac and is E2410 with the ESP32-S3 compiler.
      The Linux and Nucleo compilers were not built; their packs provide no carrier kind.
  - The two-way run (`SILICA_BLE_TRACE=1 run_peer.sh peripheral`; iPhone with nRF Connect as the central), made
    before `(:esp_at, n)` was removed; the carrier, the wrapper and the demo did not change afterwards and the
    demo was built again: the phone enabled indications; the program printed `link up mtu:512`, `frame out 48
    bytes`, three `tx segment` lines of 20 bytes and `sent 3 segments`. The phone wrote the same three values to
    the RX characteristic; the program printed three `rx segment` lines, `frame in 48 bytes`,
    `accel x=1 y=-2 z=512 at_ms=1000`, `link down :closed`, and exited 0. Also run with no peer: an address that
    names no role, and an unreadable UUID, each give `link down :fault`.
  - Not covered:
    - The central role against a real peripheral. The code is written and compiles; stage 7 is its first run.
    - More than one session at a time; a link lost in mid-frame; the `:timeout` reason.
    - Which application macOS credits with the Bluetooth permission.
  - Left stale:
    - The four `.esp32_s3.ascomp` goldens of `trials/transport_board_addition` (a suite the host run skips). Compiled
      with the new ESP32-S3 compiler they differ in the atom table and its indices, for the same reason as the
      Apple goldens. `gen_board_ascomp.sh` writes a golden only after a board run has matched its `.scout`, and no
      board was connected, so they wait for the next board run.
    - The Linux goldens of the same suites join those already stale (the Wi-Fi plan's stage S-C).
  - No compiler binary is committed with the stage.
  - The files new in this stage carry a placeholder for the copyright holder, to be decided before the branch is
    merged.

## 7. Facts the design rests on

- Silica's board runtime today (`compiler/src/emitter/ESP32-S3_raw/board/runtime`, read 2026-11-10): its image is
  flashed in place of the second-stage bootloader; it masks interrupts, installs its own vector table and disables
  the watchdogs; it runs one cooperative scheduler per core, both cores; device actors poll hardware registers.
- ESP-IDF's controller has an HCI interface for an application that brings its own host
  ([Controller and HCI](https://docs.espressif.com/projects/esp-idf/en/v6.0/esp32h2/api-reference/bluetooth/controller_vhci.html);
  the page read is for another chip of the family).
- ESP-IDF does not support bare-metal code on one core beside FreeRTOS on the other
  ([pull request 12481](https://github.com/espressif/esp-idf/pull/12481)), which is why Silica's schedulers are
  tasks and not code outside FreeRTOS.

## 8. Decisions (Matt Manley, 2026-11-10)

1. **The goal is a Bluetooth host written in Silica above Espressif's closed controller.** HCI is a published
   standard, so everything above it can be Silica; the radio under it is undocumented.

2. **On the board, ESP-IDF owns the chip and Silica's runtime is its guest**, as a new target beside
   `ESP32-S3_raw`, which is not changed. This is the Wi-Fi plan's route R2, so the two plans host the shared radio
   code the same way.

3. **Silica keeps both cores.** Its two schedulers run as two tasks, each on the core it uses today.

4. **Pairing and encryption wait for stage 9.** Until then the link is open to any nearby device (§5, risk 3).

5. **`mtu` is the literal 20; the negotiated value arrives in `:link_up`.** Every `Carrier` method body is a literal,
   `Carrier@mtu(<name>)` resolves to the kind's row, and `wireframe@frame` takes the `mtu` as an argument, so an
   owner can use the negotiated value without a compiler change.

6. **One link tag, `(:bluetooth, n)`, on every target; the role and the service go in the `:open` address.** The
   links design §4 puts the hardware in the declaration and the peer in the address. A `(:ble_gatt)` carrier is
   `:datagram` everywhere: a carrier tag has one literal row.

7. **Decision 15 of the links design holds for BLE trials.** Board trials stay compile-time, assembly, diagnostics
   and one direction. The two-way runs are scripts outside `make integrate`.

8. **Linux comes after the board** (stage 9), together with the Linux goldens that already wait to be regenerated.
