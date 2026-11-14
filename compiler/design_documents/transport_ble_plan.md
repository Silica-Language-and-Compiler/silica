# Bluetooth Low Energy transport, `(:ble_gatt)`: development plan

Status: **2026-11-13. Stages 1 to 6 are closed (§6). The goal, the design and the
vocabulary are decided (§8: Matt Manley).** It refines §6.5 and phase 5 of
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
- **On the board, the carrier comes first**, over ESP-IDF's own Bluetooth host (NimBLE) behind a wrapper, as the
  Wi-Fi plan puts its carrier over lwIP. A host written in Silica is the long-term path (§2.4).
- **Demo:** the accelerometer frame and the LED reply of `silica_33_transport_usb_serial_jtag_etf`, over BLE, between
  the board and the Mac.
- **Hardware:** one board. Its peers are the Mac and a phone.

## 2. Design

Bluetooth has two halves that meet at a standard interface, the Host Controller Interface (HCI). The **controller**
owns the radio and the link timing. The **host** owns connections, services and characteristics (GAP, L2CAP, ATT and
GATT).

| Layer | On the Mac (built, stage 3) | On the ESP32-S3 board (stages 4 to 9) |
| --- | --- | --- |
| Program | casts to the carrier, receives from it | the same program |
| Carrier, the owner-facing end | `dangerous_ble_gatt_carrier`, a dangerous actor | an actor with the same messages |
| Host | CoreBluetooth, behind an Objective-C Fifi wrapper | NimBLE, ESP-IDF's host, behind a C Fifi wrapper |
| HCI | inside macOS | inside ESP-IDF |
| Controller and radio | macOS and Apple's hardware | Espressif's closed controller, run by ESP-IDF |
| Who owns the machine | macOS; Silica's runtime is its guest | ESP-IDF and FreeRTOS; Silica's runtime is their guest |

### 2.1 The board: Silica as a guest of ESP-IDF

Espressif's controller is closed code written for FreeRTOS and for ESP-IDF's hardware support (radio calibration,
clocks, power, timers, interrupts). The radio hardware is not documented, so the controller stays, and it runs in the
environment it was written for:

- **ESP-IDF owns the chip.** Its bootloader and start-up run first, its vector table and watchdogs stay, and
  FreeRTOS schedules both cores. It is built with the Bluetooth controller and NimBLE.
- **Silica's runtime is a guest, as it is on the Mac and on Linux.** Its two schedulers, one per core, each run as
  a FreeRTOS task on the core they use today. Actors stay pinned to their core and are never interrupted by another
  actor; FreeRTOS pauses a scheduler task briefly when the radio needs the core, and the actors see only that a turn
  took longer. Silica takes its memory as a block from ESP-IDF.
- **One compiler, two board runtimes.** The `ESP32-S3_raw` compiler emits the same code for both. The bare-metal
  runtime owns the chip, as today, for programs that need no radio. The guest runtime
  (`compiler/src/emitter/ESP32-S3_raw/board/guest`) shares the bare-metal runtime's scheduler, heap and device code
  and replaces the parts that own the chip: start-up, the vector table, the memory layout. A program that wants the
  radio is built into a guest image; the trial target for guest images is `ESP32-S3_idf`.
- **The wrapper is the boundary.** NimBLE's calls (advertise, connect, the attribute table, write, indicate) are
  foreign code, reached through Fifi. NimBLE's callbacks run in its own task and must not call the Silica runtime:
  they hand each event to a wrapper call through a FreeRTOS queue.
- **AtomVM's ESP32 port is the model**: an actor runtime started by ESP-IDF, with its schedulers as tasks and radio
  events delivered as messages. It is open source.

### 2.2 The actors above the wrapper

- **The radio actor** owns the wrapper. Every event NimBLE reports becomes a message; every request to the host is
  a cast to it. Nothing else calls the wrapper.
- **One connection actor per link** holds that link's state (the negotiated MTU, the subscription, the credit), as
  the TCP listener spawns one connection carrier per accepted peer. Two peers are two actors, and one failing does
  not touch the other.
- **The carrier** is the owner-facing end of a connection actor and speaks the §6.2 contract.
- A lost link is an actor ending, handled by supervision (links design §6.3), not a value the sender checks.

### 2.3 Shared with Wi-Fi

A board program may use Bluetooth, Wi-Fi or both. On this chip the two are one piece of work below the carriers,
so they are built on one base and to one pattern, and neither plan owns what is shared:

- **One radio.** Wi-Fi and Bluetooth share the 2.4 GHz hardware, and ESP-IDF arbitrates between them. A program
  that uses both depends on that arbitration being in the build.
- **One guest image.** One ESP-IDF application, one configuration, one image build (§2.1). The links a program
  declares choose what is enabled: Bluetooth, Wi-Fi or both. There is no Bluetooth image and Wi-Fi image.
- **One memory budget.** The controller, NimBLE, the Wi-Fi driver and lwIP take internal RAM from the pool
  Silica's block comes from. Both radios at once is the tightest case, and it decides whether Silica's heap moves
  to the board's PSRAM.
- **One pattern above the closed code.** A wrapper around the ESP-IDF library, one actor that owns the wrapper,
  callbacks handed to it through a queue, and a carrier that speaks the §6.2 contract (§2.2). The Wi-Fi plan's
  carrier over lwIP has the same shape.
- **The guest runtime is the common base.** It goes to the branch both plans start from when stage 5 closes,
  before either carrier is built on it.

To settle with Lee, whose decisions the Wi-Fi plan records: one owner for what is shared (the guest runtime, the
image build, the configuration and the memory budget), and how the two plans' stages are ordered against each
other.

### 2.4 Outside this plan

These are not built by any stage here, and no stage's code should lean toward them.

- **A Bluetooth host written in Silica**, as actors above HCI, in place of NimBLE. It is the long-term path, as the
  Silica network stack is in the Wi-Fi plan: moderate to large work (the central role and pairing most of all) and
  not on the path to the demo. HCI is a published standard, and stage 4 showed a Silica program reaching the
  controller through ESP-IDF's virtual HCI calls. The carrier's contract would not change, so a program written
  against the carrier would not see the host replaced.
- **Silica owning the chip with the controller as its guest** (the Wi-Fi plan's R1). A possible later project.
- **The stack check before a large frame is opened**, in the compiler's emitted code, in place of after it. It
  would close, on any runtime, the two-instruction window the guest's builder now covers with a larger reserve
  (§6, stage 5). It changes emitted code and its assembly goldens on the board target.
- **A second chip as a modem.** Dropped.
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

The guest runtime of §2.1, far enough to answer whether it works. It is also the radio spike the Wi-Fi plan left
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
  4. How is a guest image built, flashed and trialled?
- Throwaway code, as stage 1 was. Hardware: the board.
- **Closes when:** a Silica program on the board prints the controller's answer to an HCI Reset, or the reason it
  cannot is written into §6. If it cannot, the plan stops there and is reconsidered with what the spike found; no
  other route is started without that.

### Stage 5. The guest target, made sound (closed, §6)

The guest runtime of §2.1 in the board tools, in place of the spike's throwaway code, with what stage 4 found
settled (§6, stage 4):

- The guest runtime itself: its start-up, fault and memory pieces, its image build and flash, and the trial
  target `ESP32-S3_idf` in the board trial driver.
- **A fault in an actor ends that actor, not the program**, as on bare metal: Silica's fault handling is reached
  from ESP-IDF's exception path.
- **A scheduler with nothing to do blocks** until there is work, so FreeRTOS's idle tasks run and the watchdog's
  idle check stays on.
- **Silica's code runs from flash**, as ESP-IDF's does: the runtime's read of a marker through the data-bus alias
  of a function's address is replaced.
- **The stack reserve is derived**, not guessed: what an interrupt needs on the stack that is running, added to
  what the bare-metal build measures.
- The stack guards and the runtime's spinlocks under interrupts: a guard hit is Silica's fault report; a lock is
  taken only by the two scheduler tasks, so a holder that is paused makes the other core wait and cannot deadlock.
- **A foreign call can answer a record on the board**, so the board's wrappers use the hosted wrappers'
  `{ tag, value, error_code }`.
- **One ESP-IDF version is chosen** for guest images and for the board scripts, and this machine's tools match it.
  The four `.esp32_s3.ascomp` goldens left stale in stage 3 are refreshed by a bare-metal board run.
- **Closes when:** the board trials that exercise the runtime (actors, supervisors, timers, faults, stacks,
  devices, transports, foreign calls) pass in full as guest images (`ESP32-S3_idf`), and a sample of each language
  suite; the core of them passes in the stress build as well; a trial shows an actor's fault ending only that
  actor; the bare-metal trials those changes touch still pass on `ESP32-S3_raw`. The whole board tree is run on
  both runtimes once, before the branch merges.

### Stage 6. NimBLE behind a wrapper; the board advertises (closed, §6)

- The guest's ESP-IDF application built with NimBLE; what NimBLE and the controller cost in RAM, and the size of
  Silica's block beside them.
- The same application built with Wi-Fi and lwIP enabled as well, measured the same way (§2.3): what is left for
  Silica with both radios, and whether the heap has to move to PSRAM. Nothing of Wi-Fi is run.
- The wrapper and the radio actor (§2.2), as far as advertising: set the advertising data and start advertising.
- **Closes when:** a phone's scanner shows the board advertising the service, and goes on showing it while a
  Silica program keeps both cores busy.

### Stage 7. The board carrier, peripheral role

- The wrapper, the least that one service needs: accept a connection, the MTU exchange, an attribute table with
  the service and its two characteristics, writes with response in, indications out, disconnection.
- The connection actor and the carrier (§2.2); the board's pack rows; `carrier_spawn`; board trials
  (compile-time, assembly, diagnostics and one direction, §8 decision 7).
- No pairing and no encryption (§8, decision 4).
- **Closes when:** a board program compiles with `carried_on phone: (:ble_gatt) (:bluetooth, 0);` and exchanges a
  segmented frame with a phone, the connection held while a Silica program keeps both cores busy.

### Stage 8. End to end: Mac and board

- The Mac as central, the board as peripheral: the board sends accelerometer readings, the Mac replies with an LED
  command; both ends Silica. This is also the first run of the Mac carrier's central role against a real peripheral.
- **Closes when:** the demo runs by script with only the `carried_on` line differing from the USB-Serial-JTAG demo.

### Stage 9. Central role on the board

- The wrapper's central side: scan, connect, discover the service, subscribe, write.
- **Closes when:** the board as central and the Mac as peripheral exchange the frame.

### Stage 10. Hardening, Linux and docs

- Pairing and encryption, NimBLE's; `frame_seq` if more than one frame is ever in flight.
- On both carriers: reconnect; a soak; more than one session at a time; a link lost in the middle of a frame; the
  `:timeout` reason.
- BlueZ wrapper and the Linux pack rows in lock-step with the stale Linux goldens of the Wi-Fi plan's stage S-C.
- The transport design §6.3 to §6.5 and §10, the links design §3.1, the board plan §4.4, the demo README.

## 5. Risks, ranked

1. **The controller's timing beside Silica's actors (stages 6 and 7).** Stage 4 showed the runtime runs as a guest
   and that the controller answers; nothing was on the air. Silica's actors are never interrupted by each other, and
   its locks are taken with interrupts on. Advertising and then a held connection, each with both cores busy, are
   the tests.
2. **Memory.** NimBLE takes RAM of its own beside the controller, and Silica's block (208 KB with the controller
   alone, stage 5) shrinks by that much; Wi-Fi beside it takes more (§2.3). Stage 6 measures both. The board's
   2 MB of PSRAM is unused.
3. **No pairing or encryption until stage 10.** Any nearby device can connect and read or write the link. Nothing
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
      trials: the modem route it named is not built (§2.4).
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
    - The central role against a real peripheral. The code is written and compiles; stage 8 is its first run.
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

- **Stage 4, 2026-11-10, closed: yes. Silica's board runtime runs as a guest of ESP-IDF, and a Silica program on
  the board sent an HCI Reset to Espressif's controller and printed its answer.** Built, all in
  `programmer_tools/transport_ble_board_spike` (throwaway). Board: ESP32-S3, 4 MB flash, 2 MB PSRAM (unused).
  ESP-IDF v5.3.5, built with the controller and no Bluetooth host.
  - Runs:
    - Plain C under ESP-IDF, no Silica: the controller answered an HCI Reset with `040e0405030c00` (Command
      Complete, status 0).
    - `trials/cast_exit_board_addition/cast_exit_cross_core_call.silica`, unchanged, as a guest with the
      controller up: `reply 42`, exit 9, its `.scout`. `main` on core 0 called an actor on core 1.
    - `silica/dangerous_hci_reset.silica`: a dangerous actor calls a Fifi wrapper over the virtual HCI calls and
      casts the event to a plain owner actor, which printed `hci reset length=7 event=040E0405030C00`; exit 0.
  - Question 1, what was replaced. Of the runtime's sixteen `.S` files, twelve are used as they are (the
    schedulers, mailboxes, stacks and supervision among them), two with small changes, and two are left out.
    The emitted code is the `ESP32-S3_raw` compiler's, unchanged.
    - `rt_start.S` and `rt_vectors.S` are left out. In their place (`rt_guest_start.S`, `guest.c`): each core's
      scheduler is entered from a FreeRTOS task pinned to that core; "start core 1" creates the second task;
      "stall the other core" suspends its task. `silica_rt_start_windowed` is kept word for word.
    - The memory the linker script lays out (main's two stacks and the heap) is one zeroed block of ESP-IDF's
      `.bss` with the same symbol names (`rt_guest_mem.S`).
    - `rt_console.S`: the two places that halt a core with interrupts masked (`waiti 15`) return the task to
      FreeRTOS. `rt_ffi.S`: its `memcpy` and the four like it are dropped, ESP-IDF has them.
    - FreeRTOS saves and restores THREADPTR and SCOMPARE1 with each task (read in ESP-IDF's port and the chip's
      register list), so the runtime's per-core block and its locks survive a task switch.
  - Question 2: yes, above. The wrapper returns one integer, because the board's emitter does not yet take a
    record back from a foreign call (only a scalar, or the text record a string is made from). The hosted
    wrappers' `{ tag, value, error_code }` is therefore not available on the board.
  - Question 3, cost:

    | | Flash image | RAM free at start | RAM free with the controller up |
    | --- | --- | --- | --- |
    | ESP-IDF and the controller alone | 378,528 bytes | 349,384 | 315,152 |
    | with Silica's runtime and the HCI program | 427,136 bytes | 150,932 | 116,700 |

    The controller takes about 34 KB of RAM. Silica takes about 198 KB as built here: a fixed block of 135 KB
    (96 KB heap, 32 KB for main's stack, 4 KB auxiliary), which is a choice, and its code and constants, 57 KB,
    which sit in RAM (below). The HCI program used 55 KB of the 96 KB heap.
  - Question 4: an image is an ordinary ESP-IDF application (`run_guest.sh`: compile the program, copy the
    runtime, `idf.py build flash`), written to flash, where the bare-metal image is loaded into RAM. The console
    carries the same `SILICA:START` and `SILICA:EXIT` markers after ESP-IDF's boot log, so the board trial
    driver's reading of a run still applies.
  - Found, for stage 5 to settle. None stopped the spike:
    1. **A fault in an actor ends the whole program.** Silica's own exception vectors are gone, so a CPU exception
       is ESP-IDF's panic; on the bare-metal target it ends only the actor. Not tried on the board.
    2. **The schedulers spin when idle**, so FreeRTOS's idle tasks never run while a program does. The spike
       turns off the watchdog's idle check. A real target has the scheduler block until there is work.
    3. **Silica's code and constants are in RAM.** The runtime reads a marker word through the data-bus alias of
       a function's address (`rt_actors.S`), which exists only for code in RAM. Running from flash, as ESP-IDF
       code does, needs that read replaced, and returns 57 KB.
    4. **The stack reserve is a guess.** An interrupt now lands on whatever stack is running. The spike raises the
       reserve every prologue keeps above a chunk's guard band to 4 KB (the bare-metal build measures it per
       program, 2,768 bytes for a small one). It has to be derived, and it makes actor stacks larger.
    5. **The stack guards** still use both of the chip's data watchpoints; a hit is ESP-IDF's panic, not Silica's
       fault report.
    6. **The runtime's spinlocks are taken with interrupts on.** A task that is paused while holding one keeps the
       other core spinning until it runs again.
    7. **Both write UART0**: ESP-IDF's log and Silica's console. **Both read system timer unit 0**: ESP-IDF's
       timer and Silica's clock.
    8. C code called from a Silica task sees Silica's THREADPTR, so a wrapper must not use C thread-local
       variables.
  - Not covered: the controller's timing while a Silica program is busy (nothing was on the air; stage 6's
    advertising is the first test of it); more than one program; the existing board trials on the new target;
    PSRAM.
  - Tools on this machine: ESP-IDF 5.3.5 and the `esp-13.2.0` toolchain, where the board scripts name the 6.2
    environment and `esp-16.1.0`. A bare-metal image builds with `XTENSA_BIN` set, but `run_on_board.py` did not
    load it with this environment's esptool, so no bare-metal run was made for comparison, and the four board
    goldens left stale in stage 3 are still stale.

- **Stage 5, 2026-11-12, closed: the guest runtime is in the tree, the runtime's board suites pass on it in the
  ordinary and the stress build, and the whole board tree has been run on both runtimes with no difference
  left between them.** Built: `compiler/src/emitter/ESP32-S3_raw/board/guest`
  (its `README.md` describes it), the trial target `trials/targets/ESP32-S3_idf.conf` and `.skip`,
  `run_app.sh --guest`. The spike's own ESP-IDF project is deleted; `run_hci_reset.sh` runs its HCI program on
  the guest runtime (`hci reset length=7 event=040E0405030C00`, exit 0).
  - One compiler: `ESP32-S3_raw` emits the same code for both runtimes, and the guest target compares against
    the bare-metal goldens. The shared runtime files changed (`rt_actors.S`, `rt_console.S`, `rt_ffi.S`,
    `rt_supervisors.S`) assemble to the same bare-metal objects as before, byte for byte: every change is
    inside `SILICA_GUEST`.
  - ESP-IDF version: 6.2, its development branch until 6.2 is released (commit `0e6b480f858c`, toolchain
    `esp-16.1.0_20260609`), the version the bare-metal scripts already name. This machine's tools match it.
  - Stage 4's findings:
    1. A fault in an actor ends that actor. CPU exceptions reach Silica through
       `xt_set_exception_handler`, stack-guard hits through ESP-IDF's weak `xt_debugexception`; a fault outside
       a Silica scheduler task, or with interrupts masked, stays ESP-IDF's panic.
    2. A scheduler with nothing ready blocks for a notification or one tick; the watchdog's idle check is on.
       A scheduler that never goes idle is held back one tick a second by a task above it.
    3. Code and constants are in flash; the marker word is read from the flash mapping.
    4. The stack reserve is the bare-metal measurement plus one ESP-IDF exception frame and 192 bytes
       (`silica_guest_stack_allowance`); the runtime's calls into FreeRTOS declare their stack need.
    5. A stack-guard hit is Silica's fault report: `actor_aux_overflow_ends_actor` and
       `actor_machine_overflow_ends_actor` print on the guest what they print on bare metal (their goldens are
       stale on both).
    6. The locks are left unmasked. Only the two scheduler tasks take them, so a holder that is paused makes
       the other core wait and cannot deadlock. The window spill in the context switch is masked: an
       interrupt taken while the register window is rotated puts its frame on the wrong stack.
    7. The console is shared as before. The runtime no longer writes the system timer's configuration
       register as a guest: ESP-IDF updates that register for its own timer and a second writer can undo it.
  - A foreign call answers a record on the board (`ffi_foreign.silica`): the C struct is copied field by field
    into a record of the caller's frame. Trial `ffi_addition/app_foreign_tagged_result_e2e`, passing on the
    Mac, bare metal and the guest. A 16-byte record, which comes back in registers, was run by hand on bare metal and
    read back correctly; it is not in the trial because of the Mac defect below.
  - Memory: Silica has one block (`GUEST_RAM`) for the heap and main's stacks: 240 KB, or 208 KB for a program
    whose foreign code calls ESP-IDF's Bluetooth or Wi-Fi, so that the controller fits beside it. Bare metal
    has about 340 KB. Measured: 208 KB fails `cancelled_timers_release_messages`, `actor_deep_recursion_grows`
    and `thousand_actors_at_rest`; 224 KB fails the last; at 240 KB all three print what bare metal prints.
    About 260 KB is the most that links: the block shares a 342 KB region with ESP-IDF's own data. Each of
    main's two stacks is sized from its own bound when the walk reaches one; before, a main with one stack
    unbounded got the default for both (160 KB), which failed
    `report_sink_inherited_by_added_child_supervisor`. A main the walk cannot bound (recursion) gets the
    default for both: 128 KB and 32 KB.
  - Found and fixed on the way:
    - **The fault stack's first frame had no caller.** When that frame was spilled (an interrupt arriving
      while the fault report was a few calls deep), the window-overflow handler stored four registers at
      address -32: a double exception, and the core hung with interrupts masked. The frame now carries a
      caller's stack pointer. Bare metal has the same frame and is not affected: the store does nothing there
      (shown by forcing the spill).
    - **An interrupt between a large frame's allocation and its stack check landed on the guard.** Emitted
      code opens a function's frame and then checks the stack limit. With a frame larger than the reserve
      (the LED-row worker's is about 4 KB) the stack pointer is for two instructions at or below the guard
      band, and ESP-IDF's interrupt frame goes under it: a panic in `device_led_row_constant_heap` nine runs
      in ten, and with a larger frame a write below the stack with no fault. The builder's reserve now also
      covers the largest emitted frame of the image (11 of about 30,000 frames in the board goldens are
      larger than the runtime's depth). The trial passes six runs in six. The check could instead come
      before the allocation, in the compiler, which would close the window on any runtime; not done here.
    - **`device_esp32s3_uart1` took a full transmit FIFO for a stuck one.** Under ESP-IDF the CPU writes a
      204-byte segment faster than the FIFO drains, so the last byte leaves it full. The check now waits for
      room first. Both UART1 trials pass on both runtimes.
    - ESP-IDF's linker script scattered the table of function names, so failure reports printed
      `<unknown behavior>`; images link with a patched copy of the script.
    - **`device_esp32s3_usb_serial_jtag` timed its check that a host is attached by a loop count**, which
      under ESP-IDF's CPU speed was too short. It now reads the clock: it answers as soon as the frame counter
      moves and waits up to a second. Both USB trials pass on both runtimes; their two assembly goldens are
      refreshed.
    - **The trial driver left a trial skipped by the guest out of its suite's compile**, which changed numbers
      in the assembly of the suite's other programs (four timer trials differed from their goldens). Such a
      trial is now compiled with the rest and not run.
  - Stress build (`GUEST_STRESS=1`, the guest's `README.md`): a timer with an irregular period wakes a task above
    each scheduler, the breather runs every 50 ms, and every fault entry spills the fault stack's first frame.
  - Runs on the board as guest images (2026-11-11):
    - In full, about 800 trials: `ffi_addition`, `supervisors_addition`, `timers_addition`,
      `supervisors_board_defects_addition`, `supervisor_exit_reports_addition`, `scheduler_policy_addition`,
      `record_shapes_actors_addition`, `cast_exit_board_addition`, `transport_board_addition`,
      `device_actor_addition`, `stack_budget_board_addition`, `traits_addition`,
      `recursive_function_addition`. About 350 trials each of `list_addition`, `memory_region_addition` and
      `string_addition`, and 695 trials from the start of the whole tree, all matching.
    - What does not pass, and why. Fails on bare metal the same way (stale goldens in suites marked pending,
      or a hang): `actor_aux_overflow_ends_actor`, `actor_machine_overflow_ends_actor`,
      `stack_release_algorithms`, `actor_heap_exhausted_on_core1_aborts`, `supervisor_ref_after_calls`,
      `device_fault_lines`, `device_fault_lines_registered`. (`thousand_actors_at_rest` and `actor_deep_recursion_grows`
      are in that suite too: stale goldens, and bare metal's output since the block is 240 KB.)
    - Skipped with a reason in `ESP32-S3_idf.skip`: `current_time_plausible` (no loader sets the wall clock).
    - Stress build: `ffi_addition`, `supervisors_addition`, `timers_addition`,
      `supervisors_board_defects_addition`, `supervisor_exit_reports_addition`, `scheduler_policy_addition`,
      `cast_exit_board_addition`, `record_shapes_actors_addition`, `transport_board_addition` and
      `stack_budget_board_addition` print what the ordinary build prints, but for
      `timer_ref_equality_and_storage`: its two cancel lines came in the other order. The two actors that
      print them are on different cores and nothing in the program orders them, so the trial's expected order
      holds by timing, on any target.
    - After the last change (the reserve), the same suites and `device_actor_addition` again, in the
      ordinary build and in the stress build: as above.
  - Bare metal after the changes: `transport_board_addition` and `timers_addition` pass, and
    `device_fault_lines` and `device_fault_lines_registered` hang there as on the guest; the shared runtime
    objects are unchanged.
  - The whole board tree, 2026-11-11 to 12, ordinary build, 57 suites (the 21 suites of the shared skip list
    left out), a 40 s limit per program. Guest: 15 h 32 min, 11 failures. Bare metal: 5 h 17 min, 12 failures.
    - On both, 8: compile-error trials in `error_enforcement_addition` written for the Mac's links
      (`dangerous_carrier_*`, `dangerous_link_spawn_not_provided`, `link_baud_unsupported`,
      `link_ble_adapter_not_provided`, `link_not_provided_hosted`). The board compiler refuses the link
      first, with another error. They need a board expected file or a skip entry.
    - Guest only, 3: `recursive_ackermann` and two `train_recursive_function_ackermann_*` hung. Cause: the
      builder sized main's auxiliary stack from the walk's figure even when the walk had stopped at a
      recursion, which gave 256 bytes. Fixed: when the walk has no bound, both stacks get the default. The
      three pass, and `recursive_function_addition`, `supervisors_addition`, `timers_addition`,
      `ffi_addition`, `deep_frame_spill_addition`, `base`, `actor_registration_addition`,
      `failure_reason_line_addition`, `stack_budget_board_addition` and `device_actor_addition` were run
      again on the guest after the fix: clean, apart from the stale expected files and the two
      `device_fault_lines` hangs noted above.
    - Bare metal only, 4: `bees_sd7_message_region_released`, `bees_sd7_message_region_released_in_flight`,
      `tail_recursion_runs_in_constant_stack` and `report_hundred_thousand_reports_rss` ran past the 40 s
      limit of this run (the driver's default is 300 s). With a 200 s limit they pass on both runtimes.
      Bare metal is the slower of the two on them: 157 s against 52 s for the tail recursion trial, build
      and flash included.
    - After the fix, the stress build: `supervisors_addition`, `timers_addition`, `ffi_addition`,
      `supervisor_exit_reports_addition`, `scheduler_policy_addition`, `deep_frame_spill_addition`,
      `transport_board_addition`, the four pending board suites and the three Ackermann trials: clean, apart
      from the stale expected files, the two `device_fault_lines` hangs and `timer_ref_equality_and_storage`.
    - The eight error trials are now in `trials/targets/ESP32-S3_raw.skip`.
  - Found, not fixed: main running out of auxiliary stack on the guest hangs without a report.
  - Found, not fixed: on the Mac a 16-byte record returned by a foreign call reads back as 0. The new trial
    uses the 24-byte record only.
- **Stage 6, 2026-11-13, closed: the board advertises the service from a Silica program while both cores are
  busy; a phone's scanner and the Mac show it throughout; the memory is measured for Bluetooth and for both
  radios.**
  - The closing run: `run_board_advertise.sh --seconds 600`, with a phone's scanner and `find_service.sh ""
    540` on the Mac. The phone showed "Silica" offering the Nordic UART Service and went on showing it (Matt
    Manley). The phone connected and left twice in the first minute; the board printed `radio :connected 1`,
    `radio :disconnected 1` and `radio :advertising 0` each time. The Mac heard the service in 106 of 108
    five-second windows, 5 to 24 advertisements in each; the two silent windows are in the first twenty seconds,
    about when the phone was first connected (the board does not advertise while a central is connected;
    the times were not matched exactly). ESP-IDF's heap stayed at 43 KB free from the first report
    to the last, the least 43,304 bytes, the connections included.
  - Found in that run: with the four busy actors a five-second report comes some 5.7 s after the last, so
    the program had made 111 of its 120 reports when the driver's limit of 630 s ended the run. Nothing
    failed on the board. `run_board_advertise.sh` now allows a quarter more time. Why a timer's message
    waits some 0.7 s behind the busy actors is not looked into; a round of a busy actor takes about half a
    second.
  - Built: NimBLE in the guest's ESP-IDF application (`sdkconfig.defaults`: both roles, four connections, no
    pairing or encryption); the wrapper `compiler/stdlib/ble/silica_ble_nimble.c` and its
    `silica_ble_nimble_wrapper.meta`; `compiler/stdlib/dangerous_nimble.silica` (the bindings) and
    `dangerous_ble_radio.silica` (the radio actor); in `programmer_tools/transport_ble_demo`,
    `dangerous_ble_board_advertise.silica` with `run_board_advertise.sh` (the board) and `find_service.m`
    with `find_service.sh` (the Mac's scan for the service).
  - The wrapper never waits for the radio. A request answers at once; what NimBLE reports later (ready,
    reset, advertising ended, connected, disconnected) is put in a FreeRTOS queue by NimBLE's task and taken
    out by the radio actor, which looks for one event each 20 ms. The advertisement carries the flags and
    the service's UUID, the scan response the name "Silica". Advertising is connectable; after a central
    that connected has left, the radio actor advertises again.
  - Run: `run_board_advertise.sh --seconds 120` with `find_service.sh "" 100` on the Mac. The board printed
    `radio :ready 0`, `radio :advertising 0` and 24 reports, four busy actors on the two cores completing
    1020 rounds of 100,000 steps, and exited 0. The Mac heard "Silica" in 20 of 20 five-second windows, 4 to
    22 advertisements in each. The stage 4 HCI program still answers `hci reset length=7
    event=040E0405030C00` on this configuration.
  - Memory, Bluetooth alone (Silica's block 208 KB, the demo's image):
    - Static, against an image with no radio: 59 KB (code kept in RAM 30 KB, data 4 KB, zeroed data 25 KB).
    - ESP-IDF's internal heap: 110 KB free before the radio starts, 43 KB free while advertising, steady for
      two minutes. The controller and NimBLE take 67 KB when they start.
    - So the block stays at 208 KB for a radio program: 43 KB is left for connections (stage 7 measures
      them).
  - Memory, both radios. Measured in a copy of the board tools outside the tree, with `esp_wifi`,
    `esp_netif`, `esp_event` and `lwip` added to the application and a copy of the wrapper that also starts
    Wi-Fi in station mode without connecting. Starting it was needed to see what Wi-Fi takes from the heap;
    nothing of Wi-Fi is in the tree.
    - Static, Wi-Fi on top of Bluetooth: 40 KB (code kept in RAM 21 KB, data 4.5 KB, zeroed data 14 KB). A
      208 KB block no longer links.
    - Block 176 KB: Wi-Fi starts, then NimBLE fails to start for lack of memory (`BLE_INIT: hci inits
      failed`).
    - Block 136 KB: both start and the board advertises. ESP-IDF's heap has 144 KB free before, 29 KB after:
      Wi-Fi takes 50 KB when it starts, Bluetooth 65 KB. A Wi-Fi connection and traffic take more (its
      receive buffers are allocated as packets arrive).
    - So with both radios Silica's block in internal RAM is about 120 to 136 KB, against 208 KB with
      Bluetooth alone and 240 KB with no radio. A program that needs more heap than that beside both radios
      needs the heap in PSRAM; Bluetooth alone does not.
  - The guest suites on the NimBLE configuration, ordinary build: `supervisors_addition`, `timers_addition`,
    `ffi_addition`, `supervisor_exit_reports_addition`, `scheduler_policy_addition`,
    `deep_frame_spill_addition`, `transport_board_addition`, `stack_budget_board_addition` and
    `device_actor_addition`: as at the close of stage 5.
  - Noted: each flash of an image erases NVS, so the radio calibrates in full at every start and ESP-IDF
    prints `phy_init: failed to load RF calibration data` on the console before the program's own output.

## 7. Facts the design rests on

- Silica's board runtime today (`compiler/src/emitter/ESP32-S3_raw/board/runtime`, read 2026-11-10): its image is
  flashed in place of the second-stage bootloader; it masks interrupts, installs its own vector table and disables
  the watchdogs; it runs one cooperative scheduler per core, both cores; device actors poll hardware registers.
- ESP-IDF's controller has an HCI interface for an application that brings its own host
  ([Controller and HCI](https://docs.espressif.com/projects/esp-idf/en/v6.0/esp32h2/api-reference/bluetooth/controller_vhci.html);
  the page read is for another chip of the family).
- Guest images are built against ESP-IDF 6.2 (commit `0e6b480f858c` of its development branch, 2026-11-10).
- ESP-IDF does not support bare-metal code on one core beside FreeRTOS on the other
  ([pull request 12481](https://github.com/espressif/esp-idf/pull/12481)), which is why Silica's schedulers are
  tasks and not code outside FreeRTOS.

## 8. Decisions (Matt Manley, 2026-11-10 unless dated)

1. **The goal is the carrier, on the Mac and on the board. On the board it runs over NimBLE first** (2026-11-11),
   as the Wi-Fi plan's carrier runs over lwIP first: one approach for both radios, and the shortest path to a
   working, paired link. A host written in Silica above HCI is the long-term path (§2.4).

2. **On the board, ESP-IDF owns the chip and Silica's runtime is its guest**, as a second board runtime under the
   one `ESP32-S3_raw` compiler (§2.1). The bare-metal runtime keeps working unchanged for programs that need no
   radio. The route is the Wi-Fi plan's R2; the result of stage 4 serves that plan too.

3. **Silica keeps both cores.** Its two schedulers run as two tasks, each on the core it uses today.

4. **Pairing and encryption wait for stage 10.** Until then the link is open to any nearby device (§5, risk 3).

5. **`mtu` is the literal 20; the negotiated value arrives in `:link_up`.** Every `Carrier` method body is a literal,
   `Carrier@mtu(<name>)` resolves to the kind's row, and `wireframe@frame` takes the `mtu` as an argument, so an
   owner can use the negotiated value without a compiler change.

6. **One link tag, `(:bluetooth, n)`, on every target; the role and the service go in the `:open` address.** The
   links design §4 puts the hardware in the declaration and the peer in the address. A `(:ble_gatt)` carrier is
   `:datagram` everywhere: a carrier tag has one literal row.

7. **Decision 15 of the links design holds for BLE trials.** Board trials stay compile-time, assembly, diagnostics
   and one direction. The two-way runs are scripts outside `make integrate`.

8. **Linux comes after the board** (stage 10), together with the Linux goldens that already wait to be regenerated.
