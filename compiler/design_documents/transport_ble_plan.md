# Bluetooth Low Energy transport, `(:ble_gatt)`: development plan

Status: **2026-11-15. Stages 1 to 9 are closed, stage 10 is open (§6), stage 11, Linux, is deferred, and stage 12 studies the route on which Silica owns the chip, for Bluetooth and, from part 6, for Wi-Fi. The goal, the design and the
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
  the TCP listener spawns one connection carrier per accepted peer. On the Mac two peers are two actors (up to
  four), and one failing does not touch the other. The board holds one link: the first carrier a program opens
  takes the radio, and an `:open` to another answers `(:link_down, :fault)`. One board reaches several peers in
  turn, by closing and opening again.
- **The carrier** is the owner-facing end of a connection actor and speaks the §6.2 contract. It calls no foreign
  code, so on the board it is an ordinary actor (an `actor_ref`); the Mac's carrier calls its wrapper itself and is
  a `dangerous_actor_ref`.
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
- **The stack check before a large frame is opened**, in the compiler's emitted code, in place of after it. It
  would close, on any runtime, the two-instruction window the guest's builder now covers with a larger reserve
  (§6, stage 5). It changes emitted code and its assembly goldens on the board target.
- **More than one link at a time on the board** (decided 2026-11-14): a board as the hub of several boards, or
  linked to a board and a phone at once. It is confined to the wrapper, the radio actor and the board carrier
  (the link's state by connection handle in each), costs about 9 KB of ESP-IDF's heap for each further link, and
  does not change the carrier's contract. A Mac can be the hub today.
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
  otherwise). The Mac provides instance 0 (CoreBluetooth offers no choice of adapter); the board provides
  instance 0, the chip's own radio, to a program built as a guest of ESP-IDF.
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

### Stage 7. The board carrier, peripheral role (closed, §6)

- The wrapper, the least that one service needs: accept a connection, the MTU exchange, an attribute table with
  the service and its two characteristics, writes with response in, indications out, disconnection.
- The connection actor and the carrier (§2.2); the board's pack rows; `carrier_spawn`; board trials
  (compile-time, assembly, diagnostics and one direction, §8 decision 7).
- No pairing and no encryption (§8, decision 4).
- **Closes when:** a board program compiles with `carried_on phone: (:ble_gatt) (:bluetooth, 0);` and exchanges a
  segmented frame with a phone, the connection held while a Silica program keeps both cores busy.

### Stage 8. End to end: Mac and board (closed, §6)

- The Mac as central, the board as peripheral: the board sends accelerometer readings, the Mac replies with an LED
  command; both ends Silica. This is also the first run of the Mac carrier's central role against a real peripheral.
- **Closes when:** the demo runs by script; the board and Mac programs differ from the USB-Serial-JTAG demo's
  only in the carrier's declaration, its reference type and send call, the `:open` address, and the segment size
  given to the framing (the link's, from `:link_up`).

### Stage 9. Central role on the board (closed, §6)

- The wrapper's central side: scan, connect, discover the service, subscribe, write.
- **Closes when:** the board as central and the Mac as peripheral exchange the frame.

### Stage 10. Hardening and docs

In this order, each part with its own entry in §6:

1. **Links that end and come back, on both carriers:** a carrier opened again after `:link_down`; many rounds in a
   row (a soak); a link lost in the middle of a frame; the `:timeout` reason; a segment that arrives while the
   receive queue is full.
2. **More than one session at a time:** two links held at once by one Mac program; on the board, a second
   carrier refused while the first holds the radio (§2.2).
3. **Pairing and encryption**, NimBLE's on the board and CoreBluetooth's on the Mac: a board as peripheral
   requires an encrypted link, and a central pairs when its peripheral requires it.
4. **`frame_seq`**, if more than one frame is ever in flight (closed as not needed, §6).
5. **Documents:** the transport design §6.3 to §6.5 and §10, the links design §3.1, the board plan §4.4, the demo
   README.

### Stage 11. Linux (deferred, decided 2026-11-14)

- The BlueZ wrapper and the Linux pack rows, in lock-step with the stale Linux goldens of the Wi-Fi plan's
  stage S-C.
- It waits for a Linux machine with Bluetooth. Until then the Linux pack provides no `(:ble_gatt)` carrier.
- **Closes when:** a Linux program and the board exchange the frame, in each role.

### Stage 12. Route R1: Silica owns the chip, the controller its guest (a study, opened 2026-11-14)

The route the Wi-Fi plan names R1. The bare-metal runtime keeps the chip, and Espressif's closed controller and
radio libraries run inside it, given the operating system they expect by Silica's runtime in place of
FreeRTOS. Nothing above the controller changes: the wrapper's calls, the radio actor and the carrier stay. The
guest of ESP-IDF (§2.1) stays the built route and the reference an R1 build is compared against. Lee's
decisions on the radio routes are in the Wi-Fi plan.

The spike is an experiment on a branch of its own, `r1-radio-spike` (named `ble-r1-spike` until 2026-11-15),
cut from `ble-transport-support` (Matt Manley, 2026-11-14). Wi-Fi on this route is worked out on the same
branch (Matt Manley, 2026-11-15), and what the route changes in the runtime stays on it until the route is
put to Lee. If it succeeds it is merged into `ble-transport-support`.

1. **A reading pass**, with no board: every call the closed libraries make outside themselves, sorted into
   what the bare-metal runtime answers today, what needs new runtime work, and what is unclear.
2. **A decision** from that list: whether a spike is worth its time.
3. **A spike, time-boxed:** the controller answers one HCI command on a chip Silica owns. The guest route is
   the fallback.

## 5. Risks, ranked

1. **The controller's timing beside Silica's actors (stages 6 and 7).** Stage 4 showed the runtime runs as a guest
   and that the controller answers; nothing was on the air. Silica's actors are never interrupted by each other, and
   its locks are taken with interrupts on. Advertising and then a held connection, each with both cores busy, are
   the tests.
2. **Memory.** NimBLE takes RAM of its own beside the controller, and Silica's block (208 KB with the controller
   alone, stage 5) shrinks by that much; Wi-Fi beside it takes more (§2.3). Stage 6 measures both. The board's
   2 MB of PSRAM is unused.
3. **The peer is not proved.** A link to a board as peripheral is encrypted (stage 10), so a listener reads
   nothing; the pairing has no code, so any nearby device can still pair and use the link. A link to a Mac
   program as peripheral is open, since macOS does not let such a program pair. Nothing that needs the peer
   proved crosses the link.
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
- **Stage 7, 2026-11-14, closed: a board program declared `carried_on phone: (:ble_gatt) (:bluetooth, 0);`
  exchanges a segmented frame with a phone, and with the Mac as central, with a busy actor on each core.**
  - The closing run: `run_board_peer.sh` on the board's own address, the central a phone with nRF Connect
    (Matt Manley). The board's console: `link up mtu:253`, the three 20-byte segments sent, the same three
    received in order, `frame in 48 bytes`, `accel x=1 y=-2 z=512 at_ms=1000`, `link down :closed`, status 0.
    The two busy actors went from 2,860 rounds to 3,540 while the link was held. On the phone: the service's
    two characteristics were listed; the values the board indicated were shown as "invalid data" on the
    characteristic and appear in the application's log; the three values were then written by hand. Earlier in the run the phone listed no
    characteristics and then, for a while, no "Silica" in its scan; what cleared each was not recorded (a
    table the phone kept from stage 6 is the likely cause of the first).
  - Built:
    - The wrapper's peripheral role (`silica_ble_nimble.c`): one service with the characteristic the central
      writes (with response) and the one the board indicates on, as the Mac's wrapper publishes them. Writes
      wait in a queue of eight segments; a write that finds it full is refused. Indications go out one at a
      time from a queue of eight (NimBLE allows one outstanding per connection). One central at a time.
    - The radio actor's peripheral role (`dangerous_ble_radio`): `:serve`, `:send`, `:rx_credit`, `:drop`.
    - `compiler/stdlib/dangerous_ble_gatt_board_carrier.silica`, the connection actor and carrier, and the
      board's pack rows (`(:ble_gatt)`, `(:bluetooth, 0)`, `carrier_spawn`).
    - `programmer_tools/transport_ble_demo`: `dangerous_ble_board_peer.silica` with `run_board_peer.sh`.
  - Run: `run_board_peer.sh` on the board and `run_peer.sh central` on the Mac. The link came up with an mtu of
    253. The board sent the 48-byte frame in three 20-byte segments and the Mac sent it back; each end
    reassembled and decoded it (`accel x=1 y=-2 z=512 at_ms=1000`) and closed the link, and both ended with
    status 0. The two busy actors went on throughout.
  - That run used a random address on the board, a change made for the test and not kept: on the board's own
    address the Mac answers characteristic discovery itself, with error 8 ("UUID not allowed"), and lists the
    Nordic UART Service even when the board serves another. The Mac holds a stale table for that address; it
    is not looked into further, and switching the Mac's Bluetooth off and on is the expected remedy (not
    tried). A phone that connected during stage 6 may hold the stage 6 table in the same way.
  - Memory, Silica's block 208 KB:
    - ESP-IDF's heap: 109 KB free before the radio, 42 KB while advertising, 37 KB with the link up and after
      the exchange. The service's two queues take 4 KB of that, the connection under 1 KB.
    - Silica's block is the tight one. The demo (carrier, radio actor, owner, a heap meter, two busy actors
      and the trial support's, 12 actors in all) had 196 KB of its 206 KB in use at its end. An actor costs some
      10 KB of the block, a dangerous actor some 16 KB. With four busy actors and the meter the radio actor
      ended with `:out_of_memory`.
  - Trials:
    - `transport_board_addition/link_bluetooth_instance_not_provided` (E2412 for `(:bluetooth, 1)`);
      `link_uart0_console_reserved`'s expected text now lists `(:bluetooth, 0)`. The suite on the guest: 10
      of 10.
    - A new suite, `transport_ble_board_addition`, runs the carrier on the board with no peer: the central
      role refused, a service that is no UUID refused, and open, a `:tx` with no central, close. Its programs
      need the NimBLE wrapper in the image, so the board driver (`trials/targets/board_suite.sh`) now reads
      a suite's `guest_c_sources`: the C sources are compiled into each image as ESP-IDF code on
      `ESP32-S3_idf`, and the suite's programs are skipped on bare metal. On the guest: 6 of 6 (three runs,
      three assembly goldens).
    - The advertising demo of stage 6 still runs to status 0.
  - The wrapper now lets only errors of ESP-IDF's `phy_init` through: its warning that the radio calibrates
    in full (stage 6) was the first line of a radio program's output.
  - Found in the compiler, not fixed; the carrier is written round both:
    - An atom that a program first meets as the tag of a tuple pattern is numbered 0 in that module's code on
      the first compiler pass, and the compiler ends with status 0. No message then matches (`no case arm
      matched`) until the program is compiled a second time. Seen on the Mac and the board with a ten-line
      program: a behaviour in one module, `(:open, n: int64) -> ...`, cast to from another.
    - In a call `f(a, (:tag, b, g(...)))` the call inside the later argument's tuple overwrites the earlier
      argument: `a`, a boolean, reached `f` as neither true nor false.
  - Found in the language, as it stands:
    - `spawn_dangerous` refuses a behaviour that calls no foreign code (E4045), so the board's carrier is an
      ordinary actor (§2.2).
    - A `cast_dangerous_registered` to a name no actor holds ends the sender with `(:explicit,
      :actor_not_found)`, so the carrier keeps a flag for having spawned the radio actor. Two carriers opened
      in one program would both spawn it; the board has one carrier until stage 9.
  - The timer delay noted at stage 6 is the scheduler's rule, not a defect: an actor is never interrupted in
    the middle of a message, so the owner waited for the busy actors' rounds.
  - Fixed on the way: `run_board_advertise.sh` as committed at stage 6 lacked a space in its last line and did
    not run the board; `run_peer.sh` cleared the whole `build` directory, the board scripts' work with it.
- **Stage 8, 2026-11-14, closed: the end-to-end demo runs by one script on the board's own address, both ends
  Silica.**
  - Built, in `programmer_tools/transport_ble_demo`: `dangerous_ble_board_accel_led.silica` (the USB-C demo's
    board program, `board/apps/silica_33_transport_usb_serial_jtag_etf`, on the `(:ble_gatt)` carrier),
    `dangerous_ble_mac_led.silica` (the USB-C demo's Mac peer on the hosted carrier as central) and
    `run_accel_led.sh`, which builds both, flashes and starts the board, starts the Mac's program when the
    Mac hears the board advertising, and prints both consoles.
  - Run, `run_accel_led.sh`, status 0:
    - Board: `link up mtu:253`, `tx credit 8`, `sent 48 bytes`, `led red on`, `link down :closed`, 0.
    - Mac: `link up mtu:253`, `frame 48 bytes`, `accel x=1 y=-2 z=512 at_ms=1000`, `sent 35 bytes`,
      `link down :closed`, 0.
  - What differs from the USB-C demo's two programs: the carrier's declaration, its reference type and send
    call on the board (`actor_ref` and `cast` for `device_actor_ref` and `cast_device`), the `:open` address,
    and the mtu given to `wireframe@frame`, which is the link's, read from `:link_up` (decision 5), where the
    USB-C programs give the kind's (added to the closing condition, Matt Manley, 2026-11-14). At the kind's own mtu of 20 the
    frame would be three segments, and the USB-C programs send one. The Mac's program also prints `link up`
    where the USB-C peer prints `serial open`.
  - The Mac's stale table (stage 7) was cleared by switching its Bluetooth off and on (Matt Manley): on the
    board's own address the Mac then found both characteristics, and the stage 7 exchange ran to status 0 on
    both ends with nothing changed for the test.
  - Fixed in the radio actor, found by this demo:
    - Order. The actor looked for a written segment before the host's events, so the Mac's reply overtook
      the event that said the board's own segment was confirmed; the carrier had closed by then and the
      owner never got its `:tx_credit`. The wrapper now reports each write as an event (8, written) in the
      one queue, and the actor takes the segment when that event comes, or when the owner's credit does.
    - Memory. The image builder gives every actor's stack a reserve of the largest frame in the program
      when that is more than the runtime's 2,800 bytes, and the radio actor's behaviour had a frame of 4,352
      bytes (4,144 at stage 6). With the notifications and the next state in small functions and
      `dangerous_nimble` answering scalars (a record costs a frame far more than its fields: passing the
      values as three records made the frame 6,000 bytes), the frame is 2,432. The stage 7 demo then has 162
      KB of its 208 KB in use at its end, with 44 KB never touched (196 KB of 206 KB before); the advertising
      demo of stage 6 has 93 KB in use (155 KB before). Before this fix the stage 7 demo, which had run at
      its close, ended with `:out_of_memory` once the order fix had added 208 bytes to the frame.
  - Trials: the three assembly goldens of `transport_ble_board_addition` were regenerated (the radio actor's
    atoms changed order). `transport_ble_board_addition` and `transport_board_addition` on the guest: 16 of
    16. The stage 6 and stage 7 demos run to status 0.
- **Stage 9, 2026-11-14, closed: the board as central and the Mac as peripheral exchange the segmented frame.**
  - Built:
    - The wrapper's central side (`silica_ble_nimble.c`, `silica_nimble_seek`): an active scan for a peripheral
      that advertises the service, the connection, the MTU exchange, the service's characteristic to write
      and the one that indicates found by their properties (as the Mac's wrapper finds them), the
      subscription, writes with response out, indications in. A peripheral without those is a fault event;
      a connection that fails, or a peripheral that goes before the link is up, is sought again.
    - The radio actor's `:seek`, and the carrier's `"central:<uuid>"` address. The rest of the carrier is as
      it was: the radio actor reports the same events in either role.
    - `run_board_peer.sh --central`.
  - Run: `run_peer.sh peripheral` on the Mac, then `run_board_peer.sh --central`. The board found the Mac,
    the link came up with an mtu of 253, each end sent the 48-byte frame in three 20-byte segments and
    reassembled and decoded the other's (`accel x=1 y=-2 z=512 at_ms=1000`), and both ended with status 0,
    the two busy actors running on the board throughout. ESP-IDF's heap with the link up: 37 KB free, as in
    the peripheral's role. The radio actor's frame is 2,624 bytes, still under the runtime's reserve.
  - Not covered: an indication that arrives while eight wait untaken is lost (NimBLE confirms it before the
    wrapper sees it); a peripheral other than the Mac; a peripheral that offers notifications only (the code
    subscribes to those, untried).
  - Trials: `transport_ble_board_addition/dangerous_ble_gatt_link_central` now opens as a central for a UUID
    nothing offers, sends with no link, and closes (it used to show the role refused); the three assembly
    goldens regenerated. `transport_ble_board_addition` and `transport_board_addition` on the guest: 16 of
    16. The stage 8 script still runs to status 0 on both ends.
- **Stage 10, part 1, 2026-11-14, done: links that end and come back, on both carriers. Not covered: the
  `:timeout` reason on the board; a segment arriving at a full receive queue (the link now ends with a fault,
  untried).**
  - Built: the two demo peers (`dangerous_ble_peer`, `dangerous_ble_board_peer`) make any number of exchanges,
    each on a link of its own, opening the carrier again after `:link_down` and starting their framing
    afresh; an end can cut one link short after its first segment, and can keep a link for a time after the
    exchange. `run_peer.sh` and `run_board_peer.sh`: `--links`, `--cut`, `--hold`.
  - A carrier opened again, and a soak. Twenty exchanges in a row, each on a new link, both ends to status 0:
    - Mac central, board peripheral: 20 of 20. ESP-IDF's heap with the link up: 36,980 bytes free at the first
      link and at the twentieth.
    - Board central, Mac peripheral: 20 of 20; 36,876 bytes free at the first and at the twentieth.
  - A link ended in the middle of a frame (Mac central, board peripheral, each end cutting in turn): the end
    that had one segment of three reported `link down :closed`, discarded it, opened again, and the next two
    exchanges were whole on both ends.
  - Reasons:
    - The Mac reports `link down :timeout` when the board is restarted under a link that is held, opens
      again, and makes the next exchange with the restarted board.
    - The board reports `link down :closed` when the Mac's program is killed under a held link (macOS ends
      the link) and advertises again within two seconds.
    - The board's `:timeout` (the peer's radio gone, NimBLE's 0x208) is mapped and not seen: it needs the Mac
      or a phone taken out of range. The carrier now also reads 0x214 and 0x215 (the peer short of resources,
      powering off) as `:closed`, and 0x222 and 0x23E (no answer, never established) as `:timeout`.
  - Found: both ends close as soon as they have finished, and the confirmation of an end's last segment can
    be lost in the other's close. The demo counts an exchange whole when the peer's frame is in; a program
    that must know its last segment arrived needs an answer from the peer's program, not the carrier's
    `:tx_credit` alone, before the link is closed.
  - Changed: an indication that reaches the board (as central) while eight segments wait for the owner's
    credit used to be lost, since NimBLE confirms it before the wrapper sees it. The wrapper now ends the link
    with a fault (`:link_down :fault`). Not tried: the demo's frame is three segments.
  - Rechecked: `transport_ble_board_addition` on the guest 6 of 6; three links with the board as central;
    the stage 8 script.
- **Stage 10, part 2, 2026-11-14, done: one Mac program held two links at once, to the board and to an iPhone,
  and a frame crossed whole on each; the board holds one link and refuses a second carrier. Found: of two Mac
  carriers opened at the same moment, one stays closed and says nothing (not explained; worked round).**
  - Decided (Matt Manley): the board holds one link at a time. Several at once is outside this plan (§2.4).
  - Built:
    - `dangerous_ble_peer` and `run_peer.sh --second <address>`: a second session with a carrier and an owner
      of its own, its lines marked `A:` and `B:`; the program ends when both sessions have, with the worse
      status.
    - `dangerous_ble_gatt_board_carrier`: the first carrier a program opens takes the radio, by registering
      itself as `:dangerous_ble_gatt_board_carrier`, and keeps it for as long as the program runs. An `:open`
      to any other carrier answers `(:link_down, :fault)`. Before, the second carrier ended at its spawn of
      the radio actor (the name was taken) and its owner heard nothing.
    - Trial `transport_ble_board_addition/dangerous_ble_gatt_link_second_carrier`: the refusal, and the first
      carrier closing as usual afterwards. Its `.scout` was written by hand before the first run.
    - `silica_ble.m`: a trace line for what `open` answers.
  - The two links (Mac: session A central to the board's service, session B peripheral of the Nordic UART
    Service; iPhone with nRF Connect as B's central; both links held after their exchange):
    - A: `link up mtu:253`, the 48-byte frame out and the board's in. B, with A's link still up:
      `link up mtu:512`, three segments indicated to the phone, the phone's three writes, `frame in 48 bytes`
      and the reading. Then `A: link down :closed`, `B: link down :closed`, status 0; the board status 0.
    - A write of 40 bytes from the phone (one value entered twice) gave a 68-byte frame, `rejected :bad_tag`,
      and the next three writes a whole frame on the same link.
    - Earlier, with no phone: A made three exchanges with the board, each on a new link, while B advertised.
  - Found, not explained: two hosted `(:ble_gatt)` carriers opened at the same moment. The wrapper opens both
    sessions and answers each `open` with its handle; one of the two carriers is afterwards in phase 0, sends
    its owner no `:link_down`, does not poll, and leaves its session advertising. A second `:open` to it then
    works. All eight runs showed it, on one carrier or the other. With the second `:open` two seconds after
    the first, both carriers polled in nine runs of nine; spawning both at once makes no difference, and a
    timer armed before either opens makes none. It lies between the wrapper's answer and the carrier's next
    state, in the runtime or the emitted call, not in the Bluetooth code. The demo opens its second session
    two seconds after the first; the carrier's header says to open carriers one after another.
  - Fixed, from part 1: the two demo owners ignored a `:link_down` that came before `:link_up`, so a carrier
    that failed at `:open` left the program waiting for its time limit. They now count it (status 1 for
    `:fault`). Seen on the Mac with an unreadable UUID; the board's program was built and ran one whole link
    with the change, its failing case not tried.
  - Rechecked: `transport_ble_board_addition` and `transport_board_addition` on the guest, 18 of 18, after
    the Bluetooth suite's assembly goldens were written again (the carrier names one more atom); two links
    between the Mac with one session and the board, both ends status 0, 36,980 and 36,968 bytes of ESP-IDF's
    heap free at the two.
  - Not covered: more than two sessions on the Mac; two links with the Mac as the central of both.
- **Stage 10, part 3, 2026-11-14, done: a link to a board as peripheral is paired and encrypted, from the Mac
  and from an iPhone. A Mac program as peripheral cannot pair, so the board as central has an open link to it.
  Not covered: board to board.**
  - The rule: the peripheral decides.
    - A board as peripheral requires an encrypted link. It asks its central to pair as soon as it is
      connected; its written characteristic and its subscription are refused until the link is encrypted,
      and `:link_up` comes only then. A central whose pairing fails is disconnected.
    - A central pairs when its peripheral requires it: macOS and iOS do so by themselves; the board does when
      the peripheral asks or refuses its subscription for want of encryption, and subscribes again.
    - A Mac program as peripheral has an open link. macOS lets a peripheral pair only from an application
      with a window (reports on Apple's developer forum say the same); with the Mac's characteristics marked
      as needing encryption, the board's pairing request was refused within 150 ms (the Security Manager's
      "unspecified reason"), with and without bonding asked for, and macOS asked for no pairing of its own.
  - The pairing: LE Secure Connections with no code ("Just Works"), a 16-byte key. It keeps a listener out
    and does not prove who the peer is (§5, risk 3).
  - No keys are kept (no bonding): every link pairs afresh. Flashing a guest image erases the board's NVS,
    where keys would be, and a Mac or phone that still held keys for the board would then be refused until
    its user removed the device by hand. The cost: about a second for each link, and an iPhone asks its user
    at every connection.
  - Built:
    - `silica_ble_nimble.c`: NimBLE's Security Manager set up at the start; the written characteristic with
      `WRITE_ENC`, the indicated one with `NOTIFY_INDICATE_ENC`; the `:subscribed` event of a peripheral held
      until the link is encrypted; as central, pairing and a second subscription when the first is refused
      for want of encryption; fault 5, the pairing failed.
    - `sdkconfig.defaults`: NimBLE's security on, Secure Connections only, nothing kept in NVS.
    - The carriers' and the radio actor's headers say the rule. The contract and the Mac's wrapper are
      unchanged.
  - Results:
    - Mac central, board peripheral: three exchanges, each on a new link, both ends status 0. The board read
      each link as encrypted, not authenticated, not bonded, key size 16 (a line added to the wrapper for
      the run and removed). Before the subscription needed encryption, the Mac declared its link up while
      the pairing ran and two of its three writes passed their two-second limit (`tx failed`), though they
      arrived; with it, none failed.
    - Board central, Mac peripheral (open): three of three, both ends status 0.
    - iPhone (nRF Connect) central, board peripheral: the phone asked to pair when indications were enabled;
      three segments each way, `frame in 48 bytes`, the reading, status 0. Done twice with the board flashed
      between: the phone asked both times and the second pairing worked.
    - The stage 8 script (Mac central, board peripheral): status 0 on both ends, over an encrypted link.
    - `transport_ble_board_addition` and `transport_board_addition` on the guest: 18 of 18.
    - The core suites on the guest, since ESP-IDF's configuration changed for every guest image:
      `supervisors_addition` 284, `timers_addition` 26, `ffi_addition` 67, `deep_frame_spill_addition` 16,
      `scheduler_policy_addition` 12, `supervisor_exit_reports_addition` 25, all passing. In the two suites
      marked pending the output differs only where it did at the close of stage 5
      (`stack_release_algorithms`, `thousand_actors_at_rest`, and the two `device_fault_lines` hangs).
  - Memory: ESP-IDF's heap with a link up 35,150 bytes free (36,980 before); the application's code 30 KB
    larger.
  - Not covered: board to board (one board); a peripheral other than a board that requires encryption, with
    the board as central.

- **Stage 10, part 4, 2026-11-14, closed with nothing built: `frame_seq` stays 0, since no link has more than
  one frame in flight.**
  - A link's owner frames one frame and sends its segments in order through one carrier. Each segment is
    confirmed by the peer (an indication, or a write with response), and the link delivers them in order.
  - The receiver rejects a segment whose index is not the next (`:bad_tag`), so a segment lost or repeated is
    seen. A link that ends in the middle of a frame starts the next with fresh reassembly state (part 1).
  - `frame_seq` would be needed by an owner that sent the segments of two frames interleaved on one link, as
    to let a short urgent frame pass a long one. Nothing does. The receiver also tells the first segment of a
    segmented frame from a bare frame by its four zero bytes, so a sequence other than 0 would change
    `wireframe@unframe` as well as `wireframe@frame`.

- **Stage 10, part 5, 2026-11-14, done: the documents say what was built.**
  - The transport design: §6.3 (the Mac's row: four sessions, opened one after another; Linux not built),
    §6.4 (the board's row: an ordinary actor above the radio actor, one link), §6.5 rewritten (the three
    providers as built, the service, what BLE asks of the carrier's properties, the encryption rule, how many
    links) and §10 (phase 5 as delivered).
  - The links design §3.1: the `(:bluetooth, n)` row.
  - The board plan §4.4: Bluetooth as built, through the guest of ESP-IDF.
  - The guest's README: one link, the encrypted link, the heap figure with a paired link.
  - `programmer_tools/transport_ble_demo/README.md`, new: the scripts, the runs in each role, the phone's
    steps and the limits.
  - Not changed: the specification, whose §16.4.7 and §16.4.8 already give the framing and the carrier
    contract.

- **Stage 12, part 1, 2026-11-14, done: the closed libraries ask for little by name. What they need comes
  through one table of functions and through ESP-IDF's open start-up code. One question is left that reading
  cannot answer: how long the controller may be kept waiting.** Read in ESP-IDF 6.2
  (`components/bt/controller`, `esp_phy`, `esp_coex`), the libraries' symbols listed with the toolchain's `nm`.
  - The controller, `libbtdm_app.a` (104 objects): 184 symbols from outside itself. 179 are in the chip's ROM
    (60 controller functions, the controller's data, `memcpy` and its kind, `ets_delay_us`, `ets_printf`); the
    other 5 are in the radio library (`bt_bb_*`, `bt_track_pll_cap`). It names nothing of FreeRTOS or ESP-IDF.
  - Its operating system is a table of 61 functions (`osi_funcs_t`, filled by the open `esp32c3/bt.c`, 2,472
    lines, which the ESP32-S3 shares):
    - interrupts: allocate on a core at level 3, free, enable, disable, mask all and restore, "am I in a
      handler";
    - one task (the controller's, 3,584 bytes of stack, near the highest priority), yield, yield from a
      handler;
    - semaphores, mutexes and queues, each with a form called from a handler;
    - memory, the MAC address from eFuse, random numbers, the time in microseconds, a delay;
    - sleep (five phases and the slow clock's conversions), radio power up and down;
    - coexistence with Wi-Fi (ten entries).
  - The radio libraries: `libphy.a` needs five symbols beyond the ROM (a critical section, two prints,
    `sprintf`), `libbtbb.a` four, `libcoexist.a` two.
  - Behind the table, `bt.c` calls ESP-IDF's own services: `esp_intr_alloc` (through a call to the other
    core), FreeRTOS tasks, queues and semaphores, `esp_timer`, power-management locks, the modem's clock and
    power domain (`periph_module_enable`, `esp_wifi_bt_power_domain_on`), the slow clock's calibration, and
    `esp_phy_enable`.
  - Radio start-up, `esp_phy/src/phy_init.c` (1,253 lines, open): the modem's clocks on, then the closed
    `register_chipv7_phy` with the board's init data and calibration data. The calibration data is kept in
    NVS, or made afresh at each start.
  - Sorted, so far:
    - Answered today or small: memory, the MAC address, random numbers, time and delay, the prints, the
      `memcpy` kind (in ROM).
    - Answered by saying no:
      - Sleep. The guest image already runs the controller with its sleep off and ESP-IDF's power management
        off, so "never sleeps" is the configuration every stage here ran on.
      - Coexistence with Wi-Fi. Each of `bt.c`'s wrappers has a form for a build without it that answers 0.
      - Five entries of the table are empty in ESP-IDF itself.
    - Memory, no conflict: the ROM's Bluetooth code keeps its data at fixed addresses, `0x3FCEF81C` to
      `0x3FCEFFFC`. The bare-metal runtime's RAM ends at `0x3FCE9700`, below them.
    - New runtime work:
      - Interrupts. The controller takes its interrupts at level 3 on one core; the bare-metal runtime masks
        them all (the board plan's item K). Stage 5 worked out what an interrupt costs a Silica stack.
      - The controller's task: run when a handler gives its semaphore, ahead of the actors on its core, on a
        stack of its own.
      - Semaphores, mutexes and queues, each usable from a handler.
      - Clocks. The bare-metal start leaves the chip as the ROM does, on the 40 MHz crystal. The radio needs
        the 480 MHz PLL running and the bus clock at 80 MHz (`bt.c` holds ESP-IDF's "bus clock at its
        highest" lock while the controller is on). ESP-IDF's bootloader and start-up do this in open code:
        `rtc_clk.c`, `rtc_clk_init.c` and `rtc_init.c`, 993 lines for this chip. A faster bus clock changes
        the divisor of every peripheral clocked from it, the console's UART first.
      - Radio start-up. `phy_init.c` and `phy_common.c` (1,700 lines, open) turn the modem's clocks and power
        domain on and call the closed `register_chipv7_phy`. Without NVS the radio is calibrated in full at
        every start, which ESP-IDF offers as an option; its cost in time is not measured.
    - Not answered by reading: how long the controller's handlers and its task may be kept waiting. The link
      layer is closed. It can be measured on the guest image, by holding the controller's task back by a known
      time and watching the link, before any R1 code is written.
  - What this says for the decision (part 2):
    - For a spike: the seam is clean (one table), the memory does not collide, sleep and coexistence drop
      out, and every piece of start-up the radio needs is open code that can be read and carried over.
    - Against: R1 needs interrupts in the bare-metal runtime, which changes its central rule that nothing
      interrupts an actor's core, and a pre-empting task beside the schedulers. That is the work of item K
      and more, and it is the same work whatever the timing turns out to be.
    - The spike's first two steps need no interrupts and little time: the clocks and the radio's start-up
      on a chip Silica owns (the closed `register_chipv7_phy` returning), then the timing measurement on the
      guest.

- **Stage 12, part 2, 2026-11-14, decided: the spike goes ahead, as an experiment on the branch
  `ble-r1-spike` (Matt Manley), renamed `r1-radio-spike` on 2026-11-15.**

- **Stage 12, part 3, step 1, 2026-11-14, done: on a chip the bare-metal runtime owns, the clocks reach what
  the radio needs and Espressif's closed radio start returns, four runs of four. Nothing was on the air.**
  - Built, in `board/spike_r1`:
    - `build.sh`: a bare-metal image from one C file, compiled by ESP-IDF's own command for its bootloader
      (no FreeRTOS), linked with the runtime, the archives named, and ESP-IDF's linker scripts for the ROM's
      symbols and the peripherals' addresses. It reads the guest's cached ESP-IDF build.
    - `clocks_main.c` (step 1a): ESP-IDF's `rtc_clk_init`, from its bootloader's library.
    - `phy_main.c` (step 1b): the clocks, the modem's power domain and clocks by their registers, then
      `register_chipv7_phy` from `libphy.a` with the default init data and a full calibration.
    - `spike_support.c`: `abort`, the assertion and the log's time, answered on the bare-metal runtime.
  - Results:
    - Step 1a: `before: cpu 40 MHz, source 0` (the crystal), `after: cpu 80 MHz, source 1` (the PLL), bus
      80 MHz, and the runtime ran on to its normal end.
    - Step 1b: `register_chipv7_phy: answered 1 after 32 ms` (29 to 35 ms over four runs; 1 is the library's
      "calibration data made anew"), the calibration table filled, status 0. The same with ESP-IDF's
      `rtc_init` (the chip's analog settings) run first.
    - The image: 60 KB of code with the radio library in it, 30 KB without.
  - Learned:
    - The console is untouched by the clock change: the ROM clocks UART0 from the crystal, not the bus. The
      system timer is the crystal's too.
    - The radio library's needs of its host were four functions: two for a critical section (interrupts
      are masked already), a print, and `sprintf`.
    - ESP-IDF's code names sections of its own for RAM (`.iram1`, `.dram1`). The bare-metal linker script
      did not place them, and they landed on the instruction bus at the addresses the data takes on the
      data bus: text read as garbage and the program stopped. The script now places them.
  - Changed outside the spike's directory: `runtime/silica_esp32s3.ld` (those sections) and
    `tools/build_image.sh` (`BOARD_LDFLAGS`, further link options; archives linked as one group).
    `silica_09_lists` builds and matches with both.
  - Found, not from this work: the assembly apps (`asm_00_hello`) no longer link. The runtime names
    `silica_registry_shape_exit_report`, which only compiled Silica code defines.
  - Not shown: that the radio works. The call returned and filled its table; no packet was sent or heard.

- **Stage 12, part 3, step 2, 2026-11-14, done: the controller may be kept waiting 100 ms now and then, its
  interrupt handlers included, and the link holds. Step 4 shows this is not leave to serve the handlers
  late every time.**
  - Built: `board/spike_r1/guest_hold.c`, added to the guest image of the stage 7 demo
    (`run_board_peer.sh`, `BOARD_EXTRA_SOURCES`). A task on the controller's core, above the controller's
    own, keeps the core for a set time at a set period: by running (the controller's task and the host's
    wait; the handlers run), or with interrupts masked up to level 3 (the handlers wait too).
  - Each run: Mac central, board peripheral, four exchanges each on a link of its own, pairing included.

    | Held | For | Every | Links | Mac's time |
    | --- | --- | --- | --- | --- |
    | nothing | | | 8 of 8 | |
    | the task | 20 ms | 200 ms | 4 of 4 | 42 s |
    | the task | 100 ms | 200 ms | 4 of 4 | 48 s |
    | the task | 500 ms | 1 s | 4 of 4 | 46 s |
    | the handlers too | 1 ms | 200 ms | 4 of 4 | 40 s |
    | the handlers too | 5 ms | 200 ms | 4 of 4 | 39 s |
    | the handlers too | 20 ms | 200 ms | 4 of 4, at the second run | 39 s |
    | the handlers too | 100 ms | 200 ms | 4 of 4 | 101 s |

  - The hold was in every held image: ESP-IDF's heap at the start was 2,156 bytes less, its task's stack.
  - The 20 ms run failed once at its first link, as a run with nothing held also did: the Mac's subscription
    was refused for want of encryption (below). It is not counted against the hold.
  - What it means: a stall now and then costs the radio events it was in the middle of, and the link
    outlives them; slower service costs speed (the 101 s). Between the stalls the controller was served at
    once, so this run does not say how late its handlers may be served as a rule (step 4 does).
  - Limits of the measurement: one peer (a Mac, at the connection timing it chooses), four links a run, a
    48-byte frame. A link held up for long, heavy traffic, and the board as central were not run.
  - Found on the way, in stage 10's work: with a Mac as central and a board as peripheral, the Mac's
    subscription can reach the board before the pairing the board asked for is done. The board refuses it
    ("encryption is insufficient") and the Mac's wrapper took that for a fault: one link of the first
    two-link run. `silica_ble.m` now asks again, up to ten times at half a second. The refusal has not come
    since in a run that could show the retry working; one later run had the board end the link after the
    refusal, which the retry does not cover.

- **Stage 12, part 3, step 3, 2026-11-14, done, and the spike's aim met: on a chip the bare-metal runtime
  owns, with every interrupt disabled, Espressif's controller answers HCI commands and advertises, and the
  Mac hears it.**
  - Built, in `board/spike_r1`:
    - `hci_shim.c`: the 66 functions ESP-IDF's glue (`bt.c`) asks of FreeRTOS and of ESP-IDF, on the
      bare-metal runtime. The glue itself is linked as the guest's cached build compiled it, unchanged.
      - Interrupts: `esp_intr_alloc` routes the source to a CPU interrupt line that stays disabled; a poll
        reads the line's pending bit and calls the handler in ordinary context.
      - The controller's task: one coroutine. A call that would block polls the interrupts and passes
        control to the other line of control until it can go on.
      - Queues, semaphores and mutexes: one structure. Memory: a block handed out from the front.
      - Sleep's timer never fires; coexistence answers 0; the radio's start is step 1's.
    - `spike_co.S`: the switch between the two lines of control, 20 instructions: spill the register
      windows (Cadence's `xthal_window_spill`), exchange the return address and the stack pointer, return.
    - `hci_main.c` and `run_hci.sh`: the test and its build.
  - Run (`run_hci.sh`, loaded into RAM, status 0):
    - `controller init: 0`, `controller enable: 0`; the controller made one task (`btController`) and took
      one interrupt (source 8, the Bluetooth link layer's).
    - HCI Reset answered `04 0E 04 05 03 0C 00`, command complete with status 0. Read Address answered the
      board's address.
    - Advertising parameters, data and enable each answered with status 0. For 30 s the chip advertised
      the Nordic UART Service as "R1" every 100 ms; the Mac's `find_service.sh` heard it in 7 of 7
      five-second windows (7 to 13 advertisements in each, signal -45 to -55). The poll called the
      controller's handler 572 times in the 30 s.
  - The image: 154 KB of code and 15 KB of constants in RAM (the guest keeps code in flash; a bare-metal
    image is loaded whole into RAM), and the controller took 27 KB of memory. With main's stacks at 36 KB
    the heap had 107 KB.
  - Learned:
    - Bluetooth's clock bits are off after the ROM. ESP-IDF's start-up sets every modem clock bit once
      (`esp_perip_clk_init`), and its own mask for Bluetooth is empty. Without them the controller stops
      at an assertion in its exchange-memory check (`emi.c 164`).
    - `build_image.sh` could not bound main's stacks through ESP-IDF's code and gave it 192 KB; the image
      sets them.
  - Not shown:
    - A connection. Advertising is the least of the radio's timing; a link's events come every few tens of
      milliseconds for as long as it is up.
    - The controller beside Silica's actors. Main alone ran here, polling without pause (6.8 million
      passes in the run). Step 2 says a poll every few tens of milliseconds is enough.
    - Both cores, a host above the controller (NimBLE, or the carrier), and the image's code in flash.

- **Stage 12, part 3, step 4, 2026-11-14, done: a connection. The Mac connected to the controller on the
  chip Silica owns and the link held 30 s, until the Mac ended it. The controller's handlers must be served
  within about a millisecond; its task may wait 100 ms.**
  - Built: `hci_main.c` asks for a link's events, advertises as connectable and prints each packet the
    controller sends up with its time. `POLL_GAP_MS` sets how often the controller is visited (each visit
    serves it until no interrupt waits); `HANDLERS_PROMPT` serves the handlers without pause and leaves
    only the task to the visits.
  - The link, visited without pause (the Mac's `run_peer.sh central`):
    - 1,346 ms after advertising began: connection complete, status 0, the board the peripheral. Then the
      channel selection, the change to the 2M PHY and the data length change, each an event with status 0.
    - 2,149 ms: the Mac's first request as data (its ATT MTU request). No host is on the board to answer.
    - 32,120 ms: disconnection, reason 0x13, the Mac ending the link when its request went unanswered for
      30 s. The link was up 30.8 s; the poll called the handler 2,989 times, about 97 a second.
  - How often the controller must be visited:

    | Handlers | Task | Result |
    | --- | --- | --- |
    | every visit, without pause | the same | link up 30.8 s |
    | every 1 ms | the same | link up 30.9 s |
    | every 2, 3, 5, 10 or 30 ms | the same | the Mac never heard an advertisement; the interrupt was waiting at every visit |
    | at once | every 30 ms | link up 30.6 s |
    | at once | every 100 ms | link up 30.7 s |

  - What it means for the design:
    - The handler cannot be polled between actors' turns: a turn is not bounded to a millisecond. It has
      to be a real interrupt, at level 3 on one core. It is short, runs on the stack that is running and
      returns to the same actor; it switches no actor out. Stage 5 worked out what such an interrupt costs
      a Silica stack on the guest, where ESP-IDF's interrupts already land on Silica's stacks.
    - The controller's task can be a turn of the scheduler, run when the handler has given its semaphore.
      No task pre-empts an actor.
    - So R1 adds one interrupt path to the bare-metal runtime (the board plan's item K, for one source) and
      keeps the rule that an actor is never switched out by another.
  - Not shown: data in both directions (no host), the controller beside actors, both cores, the board as
    central, the handler as an interrupt.
  - What stands between this and a build: the level 3 interrupt path in the bare-metal runtime; the
    coroutine made the runtime's (a task run when its semaphore is given); NimBLE on the same shim or a
    host in Silica (§2.4); and room for the code, 155 KB of the 399 KB a RAM-loaded image has.

- **Stage 12, part 3, step 5, 2026-11-14, done: the controller's handler as a real interrupt, through a
  level-3 path added to the bare-metal runtime. With it the link holds while the main program is busy for
  100 ms at a time.**
  - Built:
    - `runtime/rt_vectors.S`: the level-3 vector, a fatal report until now, calls a handler that foreign
      code stores in `silica_rt_level3_handler`; with none stored it is the fatal report still. The
      handler is called as if the interrupted code had made the call: by `call8`, in the interrupted
      window, on the interrupted stack, the stack pointer untouched, so the window overflow and underflow
      paths find every frame where an ordinary call leaves it. Kept and put back: a8 to a15, the shift
      amount, the loop registers, the compare register. 50 instructions, no register windows spilled, no
      stack switched.
    - `hci_shim.c`, built with `SPIKE_INTERRUPT`: the controller's source on CPU line 23 (level 3),
      enabled; the queues, the memory block and the switch between the two lines of control done with the
      level masked.
  - Run, the Mac connecting as in step 4:

    | Main between visits to the controller's task | Link | Handler calls |
    | --- | --- | --- |
    | not busy | up 30.4 s | 2,928 |
    | busy 30 ms | up 30.6 s | 2,940 |
    | busy 100 ms | up 30.8 s | 2,958 |

    With the handler polled, step 4's link failed at 2 ms.
  - The bare-metal apps `silica_04_print`, `silica_08_stack_guard` (a fault report) and `silica_09_lists`
    match their expected output with the changed vectors.
  - What the path asks of the runtime before actors run beside it:
    - Room on every stack for the handler's frames, as the guest's builder adds for ESP-IDF's interrupts
      (stage 5), or a stack of its own for the handler.
    - The level masked wherever the runtime has no valid stack pointer or window state for a moment (a
      switch of stacks). The guest runtime met the same need under ESP-IDF's interrupts.
    - A save area for each core, if the second core is to take interrupts.
    - The handler must not use the floating-point registers; the controller's was not checked for it.
  - Not shown: data in both directions (no host), actors beside the controller, both cores, the board as
    central.

- **Stage 12, part 4, 2026-11-14, begun: a host on the chip Silica owns. NimBLE first, on the shim; its
  reading pass is done. It asks for 21 functions more than the controller did, and its code does not fit
  in RAM beside a Silica program.**
  - Why NimBLE first (Matt Manley agreed): the wrapper, the radio actor and the carrier stand on its API,
    so the stage 7 demo would run unchanged on either runtime, and pairing comes with it. A host in Silica
    (§2.4) stays the later work; it speaks HCI and can be built on either base.
  - Read from the guest's build of the stage 7 demo: the wrapper's object followed through ESP-IDF's
    libraries by symbol, stopping at the edge of the Bluetooth and radio code.
    - Inside the edge: the wrapper, 58 objects of `libbt.a` (NimBLE's host, its port to FreeRTOS, its
      own cryptography, and `bt.c`), 87 of the controller, 19 of the radio libraries.
    - Asked of the outside: 87 functions. The shim answers 66 already. The 21 more:
      - FreeRTOS, 10: how full a queue is (four forms), a queue emptied, a mutex taken twice by its holder
        (two), a delay, "which task am I", "is the scheduler running".
      - Timers, 2 more, and they must fire now: NimBLE's timeouts are ESP-IDF timers.
      - Memory, 4 more (free, resize, two measures), so the block must take memory back.
      - `snprintf`, a log level, NVS's start and erase (nothing is kept, so they answer "done").
    - A second task: NimBLE's host runs in a task of its own beside the controller's.
  - Size, from the guest image's map:

    | Library | Code | Constants and data |
    | --- | --- | --- |
    | NimBLE and the glue (`libbt.a`) | 105 KB | 6 KB |
    | the controller | 81 KB | 6 KB |
    | the radio libraries | 36 KB | 8 KB |

    A bare-metal image is loaded whole into RAM, 399 KB for code, data, stacks and heap together. Step
    4's image, without NimBLE, left 104 KB. NimBLE's code and the memory it takes when it starts come to
    more than that.
  - What follows: a test of NimBLE on the shim can be made to fit only with nothing else in the image,
    and a Silica program beside it cannot. Route R1 needs the bare-metal runtime to run code from flash,
    as the guest image does through ESP-IDF's bootloader. That is its own piece of work and comes before
    a whole demo on R1.

- **Stage 12, part 4, step 1, 2026-11-14, done: code and constants run from flash on the chip the
  bare-metal runtime owns. With the controller and the radio libraries in flash the image's RAM for the
  heap doubles, and step 5's connection holds as before.**
  - Built:
    - `tools/flash_layout.py` and `BOARD_FLASH_FILES` in `tools/build_image.sh`: the code and constants
      of the files named are linked at the addresses flash is mapped to, with any section named
      `.flash.text*` or `.flash.rodata*`. Data, `.bss` and code a file marks for RAM stay in RAM. The
      image is then three parts in one file: the part the ROM loads into RAM at offset 0, the constants
      at 512 KB, the code at 768 KB.
    - `spike_r1/spike_flash.c`: the mapping, at main's start, by ESP-IDF's own code from its bootloader's
      libraries: the cache and the flash chip set up, the two parts mapped, the cache on.
    - `spike_r1/flash_main.c`: a function linked into flash that prints a text linked into flash.
    - `run_hci.sh --flash`: step 5's image with the controller, the radio libraries and ESP-IDF's glue
      in flash.
  - Results:
    - `flash_main`: `hello from flash, text and all`, `the function answered 40`, status 0.
    - The HCI image (handler by interrupt, main busy 30 ms between visits): the Mac's link up 30.9 s,
      2,936 handler calls, status 0.

      | | All in RAM | Bluetooth code in flash |
      | --- | --- | --- |
      | Code in RAM | 155 KB | 64 KB |
      | Code in flash | | 95 KB |
      | Constants in flash | | 11 KB |
      | Left for the heap | 104 KB | 206 KB |

  - Learned:
    - The chip has one table of flash pages, seen through both buses: page n is at `0x3C000000` + n × 64 KB
      for data and at `0x42000000` + n × 64 KB for code. Constants and code cannot both start at page 0.
    - The instruction cache must be given its size, ways and line length before it is used
      (`rom_config_instruction_cache_mode`). ESP-IDF does it at the application's start, not in the
      bootloader. Without it the instruction bus reads zeros where the data bus reads the page.
    - An image with parts in flash cannot be loaded into RAM for a run; it is written to flash each time,
      as a guest image is.
  - `silica_08_stack_guard` and `silica_09_lists` match with the changed builder.
  - Not done: Silica's own code in flash. The runtime and a compiled program are still loaded into RAM;
    the guest runtime already runs both from flash, so what it changed for that is the guide. The mapping
    belongs in the runtime's start, before main, when that is done.
  - Next: NimBLE on the shim (the 21 functions, a second task, timers that fire), then the wrapper under
    a C main: the frame exchanged with the Mac, pairing included.

- **Stage 12, part 4, step 2, 2026-11-14, done: NimBLE runs on the chip Silica owns and the stage 7
  exchange, pairing included, passes against the Mac. The fault that ended one run in three was in step
  5's interrupt path, and is fixed (step 3 below).**
  - Built, in `board/spike_r1`:
    - `hci_shim.c` grown for the host: up to three tasks as coroutines beside main, passed control in
      turn; ESP-IDF's one-shot timers, run when a line of control yields; a memory block that takes
      memory back; the further queue calls and the mutex its holder takes twice; `snprintf`; `rand`
      (the ROM's keeps its state through a record of the C library that nothing here sets up).
    - `nimble_main.c`: drives the board's own wrapper (`silica_ble_nimble.c`, unchanged) as the radio
      actor does: the peripheral role of the stage 7 demo. `HCI_TRACE=1` prints every packet between
      the host and the controller.
    - `run_nimble.sh`: the image. NimBLE and ESP-IDF's glue come from the guest's cached `libbt.a`.
      196 KB of code and 23 KB of constants in flash, 73 KB of code in RAM, 146 KB of RAM left with the
      shim's 112 KB block taken out; the host and the controller used 88 KB of the block.
  - What ran (the Mac's `run_peer.sh central`; the controller's handler by interrupt):
    - The host and the controller agreed 6 ms after the start; advertising; the Mac connected and read
      the service and both characteristics.
    - Pairing: the Mac's request, the board's answer (no code, Secure Connections, no keys kept), the
      public keys each way, and the link encrypted about 4 s after the connection. The board's key pair
      took about 0.8 s to compute at 80 MHz.
    - The exchange: three segments each way, each confirmed. Board: `frame out 48 bytes, frame in 48
      bytes: the same`, the Mac ending the link (reason 0x213), status 0. Mac: `frame in 48 bytes`,
      `accel x=1 y=-2 z=512 at_ms=1000`, `link down :closed`, status 0.
  - Of three runs with the handler by interrupt: one whole as above; one whole on both ends' evidence,
    the board then faulting in NimBLE as the link closed; one faulting while advertising, before a
    central came.
  - Found and fixed on the way:
    - A task's stack was sized as FreeRTOS is asked for it. The controller's handler runs on whichever
      stack is current and a switch spills the register windows there: the stack guard of the runtime
      reported the overflow. Stacks are now twice the request and 4 KB.
    - A new line of control's first frame had no caller's record under it. The window overflow path
      reads "the caller's stack pointer" from 12 bytes under a frame and stores four registers 32 bytes
      under that; on a fresh stack that was a store to wherever the block's old contents pointed.
      `spike_co_start` now writes the record.
    - With the handler polled, the link was lost during the 0.8 s of the key pair: nothing serves the
      controller while a task computes. This is step 4's rule seen from the host's side, and why the
      handler is an interrupt.
  - Left for step 3: what corrupted a return address now and then with the handler by interrupt (an
    illegal instruction in the ROM with a meaningless caller, once; a null read in NimBLE's event queue,
    once). The polled runs did not show it.
  - `stdlib/ble/silica_ble.m`, `silica_ble_nimble.c` and the demo's Mac program are unchanged: the same
    wrapper and the same peer as on the guest.

- **Stage 12, part 4, step 3, 2026-11-14, done: the fault found, in the level-3 path of step 5, and
  fixed. The handler is now called by call4.**
  - The fault: step 5 called the handler by `call8` from the interrupted window, "as the interrupted
    code would". When the handler's calls go deep enough to spill that window, a window that made a
    `call8` has a4 to a7 stored 32 to 16 bytes under its caller's stack pointer: the top of its own
    frame, room a function has only if it makes such calls itself. A leaf with a 16-byte frame has its
    caller's saved a0 to a3 there, so the store replaced its caller's return address. The ROM's
    `memcpy` is such a leaf. Step 5's runs did not go deep enough to spill; NimBLE's did.
  - The fix, `runtime/rt_vectors.S`: the call is `call4`. A window that made a `call4` has only a0 to a3
    stored when it is spilled, in its callee's frame. A `call4` gives a4 to a15 to the callee, so the path
    keeps and puts back those twelve.
  - Run after the fix, the NimBLE exchange with the Mac, pairing included:

    | Main busy between visits to the tasks | Runs | The frame whole on both ends |
    | --- | --- | --- |
    | not busy | 4 | 4 |
    | 30 ms | 4 | 4 |
    | 100 ms | 5 | 5 |

    No run faulted. At 100 ms the board sees two of its three segments confirmed: the Mac ends the link
    when it has the frame, and main, taking one event each 100 ms, loses the third confirmation to the
    disconnection. The Mac had all three. `nimble_main.c` first counted that as a failure; it now prints
    the count and requires the segments sent and received.
  - `silica_04_print`, `silica_08_stack_guard` and `silica_09_lists` match with the changed vectors.
  - Where route R1 stands: on a chip the bare-metal runtime owns, the clocks, the radio, the controller,
    NimBLE, pairing and the frame both ways, with the Bluetooth code in flash and the handler by
    interrupt. What is left is the runtime's own part: the tasks and the turn-taking, done here by a C
    main and coroutines, made the scheduler's, so that a Silica program's actors run beside the
    controller (stack room for the handler, the level masked where the runtime switches stacks, Silica's
    code in flash).

- **Stage 12, part 5, step 1, 2026-11-14, done: a Silica program with its actors runs on route R1. The
  stage 8 demo's board program, compiled as for the guest, exchanged the frame and the LED command with
  the Mac over an encrypted link, three runs of three. A program whose actors take long turns starves the
  Bluetooth tasks: the next step is theirs.**
  - Changed in the bare-metal runtime (`board/runtime`):
    - `rt_start.S`: before main, the start calls `silica_rt_board_prepare` when an image links one. It
      maps the flash, where main itself may now be.
    - `rt_actors.S`: the switch between actors masks level 3 while it spills the register windows, as
      it did in a guest only; the word before a behaviour is read from flash when the code is there;
      `NCORES_RUN` may be set by the builder.
    - `tools/build_image.sh`: `BOARD_ASFLAGS` (here `-DNCORES_RUN=1`) and `BOARD_STACK_ALLOWANCE` (here
      2,048 bytes kept above every stack's guard band for the handler); `tools/flash_layout.py ram`,
      since the function-name records in RAM are linked to code that is now in flash.
  - Built, in `board/spike_r1`:
    - `r1_port.c`: `silica_rt_board_prepare` (the flash mapped, the clocks up), and the radio actor's
      poll of the wrapper (`silica_nimble_event`, linked through here) gives the controller's and
      NimBLE's tasks and the timers their turns, on the stack of the actor's foreign call.
    - `run_r1_peer.sh [--accel]`: the image. The program's own compiled code runs from flash with the
      Bluetooth libraries': 383 KB of code and 55 KB of constants in flash, 74 KB of code in RAM, and
      84 KB in all loaded by the ROM. One core.
  - Run, `--accel` (the stage 8 program; the Mac's `dangerous_ble_mac_led`), three of three:
    - Board: `link up mtu:253`, `tx credit 8`, `sent 48 bytes`, `led red on`, `link down :closed`, 0.
    - Mac: `link up mtu:253`, `frame 48 bytes`, `accel x=1 y=-2 z=512 at_ms=1000`, `sent 35 bytes`,
      `link down :closed`, 0.
    - The same lines as stage 8's on the guest.
  - The stage 7 program (`dangerous_ble_board_peer`, two actors kept busy without pause) does not make a
    link on this image. The host and the controller agree and advertising starts, but the radio actor's
    polls come 1.35 s apart, not 20 ms: the two busy actors share the one core, and an actor's turn is
    not cut short. The Bluetooth tasks run only at those polls, and step 4 gave them 100 ms.
  - What it means: with the tasks' turns given by an actor, their service is as slow as the slowest
    actor's turn. A guest does not have this: FreeRTOS takes the core from an actor for them. The ways
    out, to choose between:
    - The second core for the Bluetooth tasks alone: the controller's handler and both tasks on core 1,
      served without pause; actors on core 0, the wrapper's calls crossing cores (the shim's queues and
      mutexes made safe for two cores). No actor is ever interrupted by a task. A program that uses the
      radio has one core for its actors.
    - A timer's interrupt that runs the tasks on their own stacks from the handler's level: the tasks
      take the core from an actor, as in a guest. Both cores stay for actors. It is pre-emption by
      foreign tasks, the thing R1 set out to avoid.

- **Stage 12, part 5, step 2, 2026-11-14, done: the second core given to the Bluetooth tasks (Matt Manley's
  choice of the two ways out). The stage 7 program, its two actors busy without pause, exchanges the frame
  with the Mac on route R1, ten links in a row. The pairing fault of stage 10 shows on this image too and
  its cause is not established.**
  - The arrangement: the runtime is built for one core, core 0, where the program's actors run. Core 1
    passes control round the controller's and NimBLE's tasks and runs their timers without pause, and the
    controller's handler interrupts core 1 only. No task or handler ever takes core 0 from an actor, and no
    actor's stack needs room for the handler. A program that uses the radio has one core for its actors.
  - Built:
    - `runtime/rt_start.S`: core 1's entry calls `silica_rt_board_core1` when an image links one; the
      prepare hook before main is a direct call to a function that is empty unless the image links its
      own. (Step 1's hook was a call through a register: the builder could no longer bound main's stacks
      for any image, gave each 192 KB, and `timers_addition/cancelled_timers_release_messages` ran out of
      memory. With the direct call `timers_addition` is 28 of 28 on bare metal; `scheduler_policy_addition`
      and `ffi_addition` passed with it, 106 trials in the three suites.)
    - `spike_r1/hci_shim.c`, built with `SPIKE_BT_CORE=1`: one lock for what the two cores share (the
      queues, the memory block, the timers, the task table), taken with level 3 masked and taken again
      freely by its holder; a call from core 0 that would block waits without passing control, since
      the tasks run beside it; the controller's interrupt line routed to core 1 and enabled there.
    - `spike_r1/r1_port.c`: starts core 1 from the prepare hook; core 1 moves to an 8 KB stack and loops.
      The radio actor's poll no longer gives the tasks their turns.
  - Found and fixed:
    - The shim's lock was taken at each entry to a nested critical section and given back once, so core
      1 kept it and core 0 waited for ever at the controller's enable.
    - Silica's heap: with the handler off the actors' stacks the allowance of step 1 went, and the shim's
      block came down to 96 KB (88 KB used at most); the program's owner had run out of memory.
  - The pairing fault of stage 10 ("encryption is insufficient" at the Mac's subscription, then the link
    lost before it is up), not explained:
    - It ends a run now and then at a first link: here two runs of five on this image before the soak
      below, and one run of one on the guest image afterwards.
    - A cause was named and a fix tried, and both are withdrawn. The claim was that NimBLE holds a
      pairing's key in memory and so answers "encryption is insufficient" where it would say
      "authentication is insufficient"; the fix cleared NimBLE's store at each connection. NimBLE's
      source says otherwise: it stores a pairing's keys only when both ends ask for bonding
      (`ble_sm.c`), and the board does not. The guest run that failed had the fix in it. The fix is
      taken out of `silica_ble_nimble.c`; the runs below that passed with it prove nothing about it.
    - What is known: NimBLE gives that answer only when its store holds a key for the peer
      (`ble_att_svr.c`), and nothing here should put one there. Not checked: whether the answer the
      Mac reports is the board's at all, or macOS's own after an encryption it started with a key it
      kept from an earlier pairing. A trace of the packets on a run that fails would settle it
      (`HCI_TRACE` in `nimble_main.c` is the means on this route).
  - Run, the Mac as central (`run_peer.sh central`), the program's two busy actors running throughout:
    - One link, twice: board `frame out 48 bytes`, `frame in 48 bytes`, `accel x=1 y=-2 z=512
      at_ms=1000`, `link down :closed`, status 0; the Mac the same, status 0.
    - Four links in a row, then ten: every frame whole each way, no refusal, both ends status 0.
    - The stage 8 program (`--accel`), three runs: the board's lines whole and status 0 each time. The
      Mac's ended in `tx failed :link_down`, `link down :timeout`, status 1, in one of the three: the
      board had the LED command and closed the link before the Mac had the answer to its write. A link
      closed by one end the moment it has what it wants can cost the other end its last confirmation;
      not looked into further.

- **Stage 12, part 5, step 3, 2026-11-14: a trace of the packets is in the two-core image, and the
  pairing fault did not come in eight runs with it on. What a good link's pairing looks like is now on
  record; the fault is still not explained.**
  - Built: `hci_shim.c` with `R1_HCI_TRACE` (`HCI_TRACE=1 ./run_r1_peer.sh`): every packet between NimBLE
    and the controller while a link is up, printed by the Bluetooth core.
  - Run: the stage 7 program, one link a run, eight runs, each from a fresh start of the board: eight of
    eight whole on both ends.
  - A good link, from the trace (times from the connection):
    - The board's security request at once. The Mac reads the services meanwhile.
    - About 0.8 s: the Mac's pairing request and the board's answer (Secure Connections, no bonding).
    - About 1 s: the Mac's subscription. The board refuses it with "authentication is insufficient".
    - About 3 s: the Mac's public key; the board's a second later (its key pair takes that long at
      80 MHz); the confirm, random and check values within 0.2 s.
    - About 4.2 s: the Mac starts encryption, the board gives the key, the link is encrypted.
    - The Mac then makes the subscription again by itself, it is accepted, and the segments follow.
  - So the refusal a good link gets is the other one, "authentication is insufficient", and macOS
    answers it by waiting for the pairing and asking again. The fault's refusal, "encryption is
    insufficient", was not seen on the wire here. Whether the board ever sends it is the open point.
  - When the fault has come (five times in all, on both routes): after another link to the same Mac,
    in the same start of the board or a start before. A run that follows a failed one has always passed.

- **Stage 12, part 5, step 4, 2026-11-14: macOS asks its user to approve every pairing, in a dialog, and
  with no keys kept every link is a pairing. A test switch builds a board that asks for none. The dialog
  left unanswered is a likely cause of stage 10's pairing fault, not confirmed.**
  - Learned from Matt Manley, who has been pressing "Connect" at each link: the plan said macOS pairs by
    itself. It does not. Every run here that paired had a person at the Mac.
  - What follows for the fault ("encryption is insufficient", the link lost before it is up): a pairing
    nobody approves does not finish, the Mac's subscription stays refused, and the link fails. That is
    the fault's shape, and it would come and go as the dialogs were answered or not. Not confirmed: no
    record was kept of which dialogs were left.
  - Built: `stdlib/ble/silica_ble_nimble.c` compiled with `SILICA_BLE_OPEN_LINK`: as peripheral it asks
    its central for no pairing and its characteristics for no encryption. `--open` on
    `run_board_peer.sh` (the guest) and on `spike_r1/run_r1_peer.sh` sets it. The default is unchanged:
    an encrypted link is required.
  - Run, `run_r1_peer.sh --open --links 4`: four frames each way, both ends status 0.
  - The overnight hunt for the fault (step 3) was stopped at its first run: each of its links raised the
    dialog.
  - For later: keys kept on both ends (bonding), so that a Mac asks once for a board. It needs somewhere
    on the board to keep them that outlives a flash, or a way back from a key only one end still has
    (§8, decision 4).

- **Stage 12, part 5, step 5, 2026-11-14, done: thirty links in a row with nobody at the Mac, on each
  route. Both are whole; route R1 takes three times as long with this program, whose two busy actors now
  share the one core its actors have.**
  - Run: the stage 7 program built with `--open`, `--links 30`; the Mac's `run_peer.sh central --links 30`.

    | Route | Links whole, both ends | Reasons for the links' ends | The Mac's time | Each link |
    | --- | --- | --- | --- | --- |
    | R1 (Silica owns the chip; Bluetooth on core 1) | 30 of 30 | 30 `:closed` | 631 s | 21 s |
    | Guest of ESP-IDF | 30 of 30 | 30 `:closed` | 201 s | 6.7 s |

    Both ends status 0 on both routes.
  - The time: on R1 the program's actors have core 0 alone. Its two busy actors take turns of some
    0.65 s each, so the radio actor is run every 1.35 s (step 1), and each step of the exchange that the
    program takes itself waits for that. On the guest the actors have both cores and FreeRTOS takes a
    core from them for the Bluetooth tasks. The Bluetooth tasks themselves are served at once on R1: no
    link was lost or timed out in the thirty.
  - Memory of the Bluetooth side, steady from the first link to the last on both: R1's block of 96 KB had
    10,448 bytes free with a link up; ESP-IDF's heap on the guest had 35,420.
  - Not compared: a program without busy actors, where R1's one core for actors costs less; the board as
    central; links held up for long.

- **Stage 12, part 5, step 6, 2026-11-15, done: the processor's clock on route R1 raised from 80 MHz. Thirty
  links of thirty at 160 and at 240 MHz; at the guest's clock R1 takes 1.7 times the guest's time.**
  - `R1_CPU_MHZ=80|160|240` on `run_r1_peer.sh` (`r1_port.c`; 80 unless given). All three come from the
    480 MHz PLL and the bus the radio is on stays at 80 MHz. The guest runs at 160 MHz
    (`CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ`), so step 5 compared R1 at half the guest's clock.
  - Run as step 5 (the stage 7 program, `--open`, `--links 30`, the Mac central):

    | Route and clock | Links whole, both ends | The Mac's time | Each link |
    | --- | --- | --- | --- |
    | R1, 80 MHz (step 5) | 30 of 30 | 631 s | 21 s |
    | R1, 160 MHz | 30 of 30 | 344 s | 11.5 s |
    | R1, 240 MHz | 30 of 30 | 249 s | 8.3 s |
    | Guest, 160 MHz (step 5) | 30 of 30 | 201 s | 6.7 s |

    Every link ended `:closed`, both ends status 0.
  - What is left of the gap at 160 MHz is the one core R1's actors have (step 5).
  - The images' sizes in flash, this program: R1 522 KB (85 KB loaded to RAM, 383 KB of code and 55 KB
    of constants run in place); the guest's application 733 KB, beside ESP-IDF's bootloader.
  - Not measured: the time from reset to the first advertisement on each route; RAM, like for like.

- **Stage 12, part 6, 2026-11-15: Wi-Fi on route R1. A reading pass, then a first image: on the chip the
  bare-metal runtime owns, Espressif's Wi-Fi libraries join a WPA2/WPA3 access point and stay joined.**
  The Wi-Fi plan chose the guest route (its R2) and names this one, its R1, as the long-term path; its
  stages are deferred and it is not changed here.
  - **Reading pass** (the guest's cached ESP-IDF build, a station that sends and takes raw frames, no
    network stack):

    | | Bluetooth (built) | Wi-Fi station |
    | --- | --- | --- |
    | Functions needed from outside the radio's libraries, cryptography apart | 87 | 111, of which the R1 image had 39 |
    | Code | 383 KB | 382 KB as linked (below), Mbed TLS's part in it |
    | Above it | NimBLE, in the figure | lwIP: 137 KB and 28 outside functions, nearly all in the shim already (not linked yet) |

    The closed libraries (`libnet80211.a`, `libpp.a`, `libcore.a`) reach the OS through a table of 128
    functions that ESP-IDF's open `esp_wifi/esp32s3/esp_adapter.c` fills. The mesh library (219 KB),
    which the reading counted, is not pulled into the link.
  - **Built** (`spike_r1/wifi_main.c`, `wifi_shim.c`, `run_wifi.sh`): a C main on the bare-metal runtime,
    one core, the Wi-Fi interrupt at level 3. `wifi_shim.c` answers what Wi-Fi asks beyond `hci_shim.c`:
    event groups, the ROM's timers, events kept for main, per-task values, the C library's locks, a
    store that keeps nothing, the Wi-Fi MAC's clock and reset. Linked from the guest's build: ESP-IDF's
    glue, its WPA supplicant, Mbed TLS, the register code of the chip's AES, SHA and big-number
    hardware, and Espressif's own coexistence library. `flash_layout.py` places the sections these
    libraries name for RAM (`.wifi0iram` and the like) in flash. The access point's name and passphrase
    come from a file outside git (`run_wifi.sh`'s header).
  - **What ESP-IDF's start-up does that a bare-metal image must do itself**, each found by a hang or a
    fault:
    - every modem clock bit set (`SYSTEM_WIFI_CLK_EN`) and the MAC's low-power clock chosen: without
      them the MAC never answers its start and `libpp.a`'s `hal_init` waits for ever;
    - the Wi-Fi MAC's own reset when the glue asks for it (the shim reset Bluetooth's blocks);
    - `esp_coex_adapter_register` and `coex_pre_init`: the chip's ROM holds coexistence code that the
      Wi-Fi library calls, and its tables are empty until then (a load from address 0x28 in the ROM's
      `coex_schm_interval_set`). Stand-ins for the coexistence calls cannot be used with Wi-Fi;
    - `psa_crypto_init`: without it every key operation fails, and a WPA3 join is refused at once
      (reason 202);
    - a C-library mutex declared ready is all ones, not zero.
  - **Result**, the access point offering WPA2 and WPA3 (the station takes WPA3's exchange), 160 MHz:

    | Main busy between visits to the tasks | Joined after asking | Stayed joined | Frames taken |
    | --- | --- | --- | --- |
    | 0 ms | 1.0 s | 57 s, the run's end | 283 (86 KB) |
    | 20 ms | 3.1 s | 24 s, the run's end | 67 |
    | 100 ms | 5.3 s | 21 s, the run's end | 44 |

    So the Wi-Fi tasks, like Bluetooth's, bear 100 ms between turns once the interrupt is taken. Most
    memory given by the shim's block: 61 KB of 160 KB. The image: 52 KB of code and 10 KB of data in
    RAM, 382 KB of code and 65 KB of constants in flash.
  - **Open.**
    - With the radio's power saving on (the default) the station joins but takes 2 frames in 21 s and
      reports beacons missed twice; the runs above have it off (`esp_wifi_set_ps(WIFI_PS_NONE)`). The
      shim's radio start has none of ESP-IDF's wake-up path.
    - Forced to WPA2's exchange alone (`-DWIFI_NO_SAE`) the join fails with reason 1; not looked into.
      A WPA2-only access point is untried.
    - Nothing is sent: no network stack is in the image (step 2 below adds lwIP).
    - Both radios in one image; the Wi-Fi tasks on core 1 beside a Silica program.
    - The shim's random numbers are not fit for keys outside a spike.
    - The DMA paths of the AES and SHA hardware stop the program if reached; none was.
  - **Tools for a hang** (`-DSPIKE_DEBUG`): `spike_debug_watch` reports every two seconds where the
    processor is and who called, from a level-3 timer interrupt; Espressif's ROM ELF
    (`~/.espressif/tools/esp-rom-elfs`) names an address in the ROM. `-DWIFI_LOG` turns on the Wi-Fi
    library's own log, which prints the access point's name.

- **Stage 12, part 6, step 2, 2026-11-15, done: lwIP above the station on route R1. The board takes an
  address from the access point by DHCP and exchanges the demo's frame with the Mac over TCP, thirty
  connections of thirty.**
  - Built: `spike_r1/wifi_net.c`, the least there can be between the station and lwIP, in place of
    ESP-IDF's own layer (esp_netif): one interface whose frames go out by `esp_wifi_internal_tx` and
    come in from the station's receive callback, each copied once; DHCP; lwIP's sockets for one TCP
    exchange. lwIP is the guest build's `liblwip.a` with ESP-IDF's FreeRTOS port, its task one more of
    the shim's coroutines. `spike_r1/wifi_peer.py` is the Mac's end: it takes one frame behind a 4-byte
    length (what Erlang's `gen_tcp` `{packet, 4}` speaks) on each connection and sends it back.
    `run_wifi.sh --tcp [--links <n>]` builds, starts the peer and runs both.
  - What lwIP asked beyond the shim: a queue in the caller's record and storage whose handle is that
    record (`xQueueGenericCreateStatic`, now in `hci_shim.c`; lwIP's mailboxes), the tick count, the C
    library's error number and its table of character classes.
  - Run, 160 MHz, power saving off, the Mac and the board on one home network:

    | Connections whole, both ends | Address after the join | Each exchange | Most memory given |
    | --- | --- | --- | --- |
    | 30 of 30 | 1.5 s | 74 ms mean, 334 ms the longest | 73 KB of 160 KB |

    The frame is the 48 bytes of ETF the Bluetooth demo sends; the Mac printed the same bytes each time.
  - The image: 53 KB of code and 11 KB of data in RAM, 463 KB of code and 82 KB of constants in flash.
  - Not done: a Silica program in the image (this is a C main); the peer a Silica program or an Erlang
    node; the board listening; IPv6; a frame larger than one segment; main busy between its calls.

- **Stage 12, part 6, step 3, 2026-11-15, done: a Silica program with its actors exchanges the demo's
  frame with the Mac over Wi-Fi and TCP on route R1, thirty links of thirty.**
  - Built, each the Bluetooth piece of the same place with the names changed and little else:

    | Piece | File | Made from |
    | --- | --- | --- |
    | The wrapper | `compiler/stdlib/wifi/silica_wifi_lwip.c` and its `.meta` | new, in the shape of `silica_ble_nimble.c`: the same calls, the same event numbers |
    | Its Silica module | `compiler/stdlib/dangerous_wifi.silica` | `dangerous_nimble` |
    | The radio actor | `compiler/stdlib/dangerous_wifi_radio.silica` | `dangerous_ble_radio`, the wrapper's module changed and nothing else |
    | The carrier | `compiler/stdlib/dangerous_tcp_board_carrier.silica` | `dangerous_ble_gatt_board_carrier`, the address's forms changed |
    | The program | `programmer_tools/transport_wifi_demo/dangerous_wifi_board_peer.silica` | the stage 7 board program, framing by wireframe's `:stream` mode |
    | The script | `spike_r1/run_r1_wifi_peer.sh [--links <n>]` | `run_r1_peer.sh` |

    The image is step 2's with the program in place of the C main, built as part 5's: the runtime and
    the program's actors on core 0, the Wi-Fi libraries' tasks, lwIP's task and the Wi-Fi interrupt on
    core 1. No file of the shim changed for the second core.
  - The wrapper never waits: it makes the connection on a socket that does not block and reads it
    with `MSG_DONTWAIT`, and `silica_wifi_event` does one step of each thing that goes on by itself.
    A TCP connection has no second step after it is made, so the wrapper reports NimBLE's
    `:subscribed` at once and the radio actor is unchanged.
  - **No compiler change.** The pack for this target has no `(:tcp)` carrier and no `(:wifi, n)` link,
    so the program has no `carried_on`: it spawns the carrier as an ordinary actor, with the state
    written out (a call into a `dangerous_` module is allowed only in an FFI worker, E4042), and reads
    the carrier's row by its tag, `Carrier@mtu(:tcp)`. The pack rows are the Wi-Fi plan's stage 7.
  - Run, 160 MHz, power saving off, the Mac's end `wifi_peer.py` (it sends each frame back):

    | Links whole, both ends | Reasons for the links' ends | Each link | The radio's memory, a link up |
    | --- | --- | --- | --- |
    | 30 of 30, status 0 | 30 `:closed` | about 8.5 s | 49 KB free of 112 KB, the least 42 KB, steady |

    The program's two busy actors share core 0 with the radio actor as in part 5, which is most of a
    link's time; the Bluetooth program takes 11.5 s a link at this clock.
  - The image: 56 KB of code and 16 KB of data in RAM, 646 KB of code and 112 KB of constants in flash.
  - **Beside the hosted work on `main`** (fetched 2026-11-15; this branch was cut from 2026-11-09's):
    - Lee's stage E2 gave the hosted `(:tcp)` carrier link binding (`carried_on` with `(:ethernet, n)`,
      `(:wifi, n)`, `(:loopback)`, an interface by name), the addresses `listen:<ipv4>:<port>` and
      `listen:any:<port>`, and a carrier that ends itself after `(:link_down, :fault)` when its link is
      unavailable. It is the Mac's and Linux's carrier; nothing there is the board's. The board carrier
      here takes that carrier's address forms (a peer is `a.b.c.d:port`, a listener `listen:...`) and
      none of its link binding or its endings yet.
    - Project BEES (secure interchange above the `(:tcp)` carrier: mutual TLS 1.3, a BEAM mode with a
      cookie) names Mbed TLS as its TLS engine on the ESP32-S3. This image has Mbed TLS linked, for
      WPA3's key exchange.
    - `main` does not merge cleanly into this branch: four files conflict (`Carrier.silica`, the Apple
      transport pack, `type_checker_links.silica`, the transport design), each where both sides added
      rows, and the goldens under them. `ble-transport-support` has the same merge ahead of it.
  - Not done: the board listening; the peer a Silica program or an Erlang node; a link lost in the
    middle (the access point gone, the peer gone); a frame over 1024 bytes; both radios in one image.

- **Stage 12, part 7, 2026-11-15, done: `main` merged into the branch; the board's `(:tcp)` carrier
  declared as a hosted one is, `carried_on lan: (:tcp) (:wifi, 0);`.**
  - The merge (`main` at `82d1bb0d99`: transport stage E2, the storage carriers, the Nucleo port, the
    pin tests). Conflicts where both sides had added rows to one table, both kept: `Carrier.silica`,
    `Link.silica`, the type checker's link table, the Apple transport pack, the transport design's
    phase table, the board's skip list and `board_suite.sh`. Twenty-nine Apple goldens that conflicted
    were taken from `main`; they are stale until the merged Apple compiler records them again (not
    done: the Apple trial tree has not been run on the merged tree).
  - Both compilers rebuilt from the merged source, neither published: the Apple one by `main`'s
    binary, then again from clean by itself; the ESP32-S3 one by that.
  - On the merged tree, the board: timers, scheduler policy, supervisors, board transport and foreign
    calls, 396 of 401, the five all assembly goldens gone stale (four by the atoms' numbers, which
    the two sides' new atoms moved; one by `main`'s behaviour-frame fix under a golden this branch
    had recorded). Recorded again (`gen_board_ascomp.sh`, which writes a golden only for a trial whose
    board output matched); board transport and foreign calls then 77 of 77. Both radio demos on route
    R1, three links of three each.
  - The pack rows (`emitter/ESP32-S3_raw/transport_pack.silica`): the kind `(:tcp)` and the link
    `(:wifi, 0)`, the carrier `dangerous_tcp_board_carrier`, spawned as the `(:ble_gatt)` one is. The
    demo program declares `carried_on lan: (:tcp) (:wifi, 0);` and reads `Carrier@mtu(lan)`; three
    links of three. A trial for the row: `transport_board_addition/link_wifi_instance_not_provided`
    (`(:wifi, 1)` is E2412); the two goldens that quote the board's links name the new one.
  - Not carried over from the hosted carrier yet: the link handed to the carrier as text (the board
    has one station), `listen:` addresses, and a carrier that ends itself after `(:link_down, :fault)`.

- **Stage 12, part 8, 2026-11-15, done: the board's `(:tcp)` carrier is the hosted one. The hosted
  carrier and its sockets module run on the board as they are, above socket wrappers written over
  lwIP; thirty links of thirty.** This replaces the carrier of part 6, step 3, and its radio actor,
  module and wrapper, which are removed.
  - Why: the hosted carrier (`dangerous_tcp_carrier.silica`, as stage E2 left it) is a dangerous actor
    over `dangerous_sockets`, whose wrappers (`compiler/stdlib/net/silica_sockets.c`) are BSD socket
    calls. lwIP has the same calls. A board carrier made to behave as the hosted one would follow it
    for ever; the hosted one itself needs only its wrappers answered.
  - Built:
    - `compiler/stdlib/wifi/silica_sockets_lwip.c`: every symbol of the hosted wrapper, with the same
      answers, over lwIP. `silica_sockets_link_select` answers for `(:wifi, 0)`: the station's address,
      or ENXIO while it has none. Its first call starts the station; a task of the wrapper's on the
      radio's core joins the access point, starts lwIP, and joins again when the access point is
      lost. UDP and the serial port answer ENOSYS. A connection is given 5 s to be made.
    - The pack: `(:tcp)` on `(:wifi, 0)` spawns `dangerous_tcp_carrier` with `link_spec: "wifi:0"`, as
      the hosted packs do.
    - The demo program speaks the hosted contract: the carrier is a `dangerous_actor_ref`, it ends
      with its link, so each link has a carrier of its own, spawned by the owner.
  - **The hosted rules, seen on the board.** While the station is joining, an `:open` answers
    `(:link_down, :fault)` and the carrier ends with `(:explicit, :link_unavailable)`, three times in
    each run before the link is there; the program opens again half a second later. A link that
    closes ends its carrier `:normal`.
  - **The compiler and the runtime: a foreign call of eight argument words.** The board refused more
    than six (the registers), and `dangerous_sockets`' receive takes eight: a result returned through
    a hidden pointer and three `int64`. C takes the seventh and eighth from the caller's stack.
    `terms/ffi_foreign.silica` stages them at the end of the call block's struct area (allowed when
    the returned struct is at most 24 bytes) and adds 4 to the block's mode word; `rt_ffi.S` puts
    them at the bottom of its own frame before the call. A call of six words or fewer is emitted as
    before: no golden changed. No trial yet calls with seven or eight.
  - Run, 160 MHz, power saving off, the Mac's end `wifi_peer.py`:

    | Links whole, both ends | Reasons for the links' ends | Each link | Board suites after the change |
    | --- | --- | --- | --- |
    | 30 of 30, status 0 | 30 `:closed`; 3 `:fault` while joining | about 5.5 s | foreign calls and board transport, 78 of 78 |

    The image: 56 KB of code in RAM, 651 KB in flash.
  - **Found.**
    - A cast to a carrier that has ended ends the sender with `(:explicit, :actor_not_found)`. A
      carrier ends itself when its peer closes, so an owner still answering the last `:rx` (a
      `:credit`, a `:close`) is ended by its own cast: seen here when the Mac's end closed first, and
      the busy actors that cast to the owner went the same way. `wifi_peer.py` now waits for the
      board to close. Whether a hosted owner meets the same is not tried.
    - Each carrier's end is printed as an actor failure report, the normal ones too, because the
      demo's carriers have no supervisor.
  - Not done: the board listening (`listen:<port>` binds the station's address by the same code; no
    program here takes `:accepted` yet); a trial for the eight-word call; the hosted trials of the
    `(:tcp)` carrier run on the board; a link lost in the middle.
- **Stage 12, part 9, 2026-11-15, done: the board listens, and the libraries share the runtime's
  heap.**
  - **Listening.** The Wi-Fi demo's board program, run with `run_r1_wifi_peer.sh --listen`, opens its
    carrier at `listen:<port>` under `(:wifi, 0)`: the hosted carrier binds the station's address,
    answers `(:link_up, "port:<n>")`, and for each peer sends the owner
    `(:accepted, conn, "peer:<ipv4>:<port>")`; the owner opens `conn` and exchanges the frame on it as
    on a connection it made. While the station has not joined, the listener ends with
    `(:explicit, :link_unavailable)` as a connecting carrier does, and the owner opens another. The
    Mac's end (`wifi_peer.py` with this Mac's address as its fourth argument) finds the board by
    trying the port on every address of its /24 network.
  - **One heap.** The first listening runs ended each accepted connection's carrier with
    `(:explicit, :out_of_memory)`: the runtime's heap was 144 KB, in use to within 4 KB (an actor that
    makes foreign calls holds about 15 to 20 KB of it), beside 112 KB set aside for the libraries'
    `malloc`. With `-DSPIKE_ONE_HEAP`, `hci_shim.c` takes the libraries' blocks from the runtime's
    heap (`silica_rt_alloc_or_null`, `silica_rt_free`; 16-byte alignment kept; the radio's interrupt
    masked around each call, the heap's lock being a spin lock): one heap of 259 KB, and neither side
    keeps memory the other could use. `run_r1_wifi_peer.sh` builds so. The Bluetooth image still has
    its arena.
  - **The foreign calls' stack** in the Wi-Fi image is 6 KB for each actor that makes them (was
    16 KB); the station starts within it.
  - Runs, 160 MHz, power saving off:

    | Run | Result |
    | --- | --- |
    | The board listening, three peers | 3 accepted, 3 exchanges whole on both ends, status 0 |
    | The board connecting, thirty links | 30 of 30, status 0, no allocation refused |
    | Bluetooth on route R1 (arena), three links | 3 of 3 on both ends |

  - Not done: a trial for the eight-word call; the hosted trials of the `(:tcp)` carrier run on the
    board; a link lost in the middle; the Bluetooth image on the one heap.
- **Stage 12, part 10, 2026-11-15, done: the merged tree verified on the Mac, and a trial for the
  eight-word call.**
  - **The Mac's whole tree on the merged source**: 35,190 trials passed and 75 differed, every one a
    golden the merge left stale and no program's behaviour: 66 assembly goldens of the transport
    suites main added (the atom table two atoms longer, `:ble_gatt` and `:characteristic`, and the
    numbers after them moved) and 9 diagnostics whose lists of carriers and links now hold both
    branches' entries (`(:ble_gatt)`, `(:bluetooth, n)` beside the `(:store)` links). The 66 were
    recorded again with `programmer_tools/update_goldens.sh --apply` for `transport_addition` and
    `ffi_addition/app_transport_tcp_loopback`, the 9 from the compiler's output after reading each
    difference. Run again: `transport_addition` 109 of 109, `ffi_addition` 94 of 94,
    `error_enforcement_addition` 11,114 of 11,114.
  - **Trial `ffi_addition/app_foreign_three_int64_result_e2e`**: a C function of three `int64`
    returning the tagged result (`silica_abi_i64_result_of3` in the fixtures' `silica_abi_types.c`),
    the shape of `dangerous_sockets`' receive: eight argument words on the ESP32-S3, the last two on
    the C stack. It answers `a * 10000 + b * 100 + c`; the trial prints `10203`. Passes on the Mac and
    on the board, assembly goldens recorded for both (the board's shows the stores at the call
    block's +56 and +60); the board's `ffi_addition` 69 of 69. Left out on the STM32-L476RG
    (`trials/targets/STM32-L476RG_raw.skip`): its emitter takes six words, so the hosted `(:tcp)`
    carrier's receive would not compile there either.
  - **The Bluetooth image on the one heap**: `run_r1_peer.sh` builds with `-DSPIKE_ONE_HEAP` (a heap
    of 264 KB); three links of three on both ends.
  - `flash_layout.py script --iram` (`BOARD_FLASH_IRAM=1`): the listed libraries' code marked for RAM
    (`.iram1`) goes to flash as well, for an image that never takes its flash away. Not used by the
    single-radio scripts.
- **Stage 12, part 11, 2026-11-15, done with a limit: both radios in one image, and Wi-Fi power
  saving.** One Silica program exchanges the demos' frame over Wi-Fi and over Bluetooth from one
  image, under Espressif's coexistence. Memory is at its edge: five links on each radio pass; in
  fifteen, Bluetooth passes and Wi-Fi loses a carrier to a refused allocation.
  - **The program and the script.** `programmer_tools/transport_both_demo/dangerous_both_board_peer.silica`
    declares `carried_on lan: (:tcp) (:wifi, 0);` and `carried_on phone: (:ble_gatt) (:bluetooth, 0);`
    and has an owner for each (the Wi-Fi demo's owner written twice, for the two carriers' reference
    types and rules) and a coordinator that ends the program when both owners' links are done.
    `spike_r1/run_r1_both.sh` builds it with the hosted `(:tcp)` carrier above lwIP, the board's
    `(:ble_gatt)` carrier above NimBLE, both wrappers, the shims and every library of the two
    single-radio images: 45 KB of code in RAM, 956 KB in flash, a heap of 273 KB. `--only wifi|ble`
    opens one radio's carrier only. The Mac's ends are `wifi_peer.py` and `run_peer.sh central`.
  - **What was wrong when both were on.** Each radio worked alone in the image and neither with
    the other. The shim's `esp_wifi_bt_power_domain_on` reset the modem at every call: the second
    radio's start took away the first one's MAC and the radio's calibration. ESP-IDF counts the
    domain's users and resets for the first only; `hci_shim.c` now does. Besides: the coexistence
    library is prepared once by whichever radio starts first (`spike_coex_start`; the Bluetooth
    controller's start hung without it when Wi-Fi had not started).
  - **Wi-Fi power saving works.** Coexistence shares the one radio by time and needs the station in
    modem sleep. `-DSOCKETS_WIFI_PS` sets `WIFI_PS_MIN_MODEM` (the two-radio image always; the Wi-Fi
    image when asked). The C test with it (`run_wifi.sh`, `-DWIFI_PS_ON`): joined, five exchanges of
    five, 33 ms to 1.4 s each against 74 ms with power saving off. The Silica demo with it: ten links
    of ten. What part 6 saw (beacons lost) is not seen now; which of the changes since ended it was
    not isolated. The shim still never closes the radio between beacons, so no power is saved yet:
    the station's protocol sleeps, the radio does not.
  - **Memory.** Measured, 160 MHz:

    | What | Bytes |
    | --- | --- |
    | The heap (the RAM left after code, constants, data and main's stack) | 273,088 |
    | The libraries hold, both radios at work | 92,000 to 115,000 |
    | The demo's actors hold at rest, Wi-Fi image, seven actors | about 100,000 |
    | A live `(:tcp)` carrier, more | about 20,000 |
    | The libraries' growth with each Wi-Fi link (not found) | about 230 |

    What was done for it:
    - the Bluetooth libraries' `.iram1` code and the wrappers' code moved to flash
      (`BOARD_FLASH_IRAM=1`): the code in RAM went from 85 KB to 45 KB;
    - tasks' stacks come from 32 KB of RAM the heap does not reach, 0x3FCF0000 to 0x3FCF8000
      (ESP-IDF's memory layout gives it to its heap when the data cache is 32 KB or less;
      `spike_flash.c` sets the data cache's size as ESP-IDF's start does). With `-DSPIKE_STACK_TIGHT`
      each task has what ESP-IDF asks for and no more, and all five fit; `spike_stack_report` measured
      their use with both radios at work: 3.2 KB of 6.7 KB for Wi-Fi's task, 0.9 to 1.7 KB of 4 KB for
      the others. The single-radio images keep twice the asked size and 4 KB;
    - in the two-radio image: main's stack 8 KB, the foreign calls' stack 4 KB, six of the station's
      1.6 KB receive buffers in place of ten (`-DSOCKETS_WIFI_RX_BUFFERS=6`);
    - reports: `hci_shim.c` prints what the libraries hold when a task is made and when an
      allocation is refused; `-DSOCKETS_HEAP_REPORT` prints it every five seconds, with
      `-DSOCKETS_HEAP_SUMMARY` the runtime's summary of the heap too.
  - Runs, 160 MHz, the two-radio image, the Mac both peers:

    | Run | Wi-Fi | Bluetooth | Status |
    | --- | --- | --- | --- |
    | Three links on each | 3 of 3 | 3 of 3 | 0 |
    | Five links on each | 5 of 5 | 5 of 5 | 0 |
    | Fifteen on each, the two overlapping (three runs) | 7, 8 and 9 of 15 | 15 of 15 each | none: the Wi-Fi owner waits |

    In the fifteen-link runs a `(:tcp)` carrier ends with `(:explicit, :out_of_memory)` when its
    stack asks the heap for a block of 8 to 10 KB: the heap's use was sampled between 198 and 244 KB
    of 273 KB, in free blocks of 2 KB, so the one heap is broken up by the libraries' blocks among
    the actors'. The demo's owner has no supervisor and is not told its carrier ended, so it waits.
    The single-radio images after these changes: Wi-Fi five links of five, Bluetooth three of three.
  - **Open.** The one heap's fragmentation, and a limit for the libraries on it (when they take all
    of it the runtime's own allocation aborts the program, `heap exhausted`); 16 KB of instruction
    RAM at 0x40374000 that nothing uses; the 230 bytes a Wi-Fi link leaves behind; the radio closed
    between beacons; while Bluetooth has a link the station at times loses the access point and
    joins again (`:link_unavailable` between links).

- **Stage 12, part 12, 2026-11-15, done: the two-radio image's memory.** Fifteen links on each
  radio, the two overlapping, now pass: three runs of three, status 0, where part 11 lost a Wi-Fi
  carrier in each.
  - **What part 11 had wrong.** The heap was not only broken up; it was full. A walk of every block
    (`-DSPIKE_HEAP_WALK`, with `-DSOCKETS_HEAP_SUMMARY`) showed 223 KB of 271 KB in use with both
    radios idle, 244 KB with one `(:tcp)` carrier live, and the runtime's `heap exhausted` when a
    Bluetooth link came on top.
  - **RAM the image did not use.** The runtime's image ends at 0x3FCE9700, the bound the ROM needs
    while it loads the image. Above it, 0x3FCE9800 to 0x3FCEF000 (22 KB) is the ROM's only during
    the load; the ROM's own variables, which the libraries' code in ROM uses, start at 0x3FCEF81C.
    With part 11's 32 KB at 0x3FCF0000 that is 54 KB the heap does not reach. (A first attempt took
    the region from 0x3FCE9700 and the Wi-Fi start faulted: the frame above main's stack top is
    written to.)
  - **The libraries' regions** (`hci_shim.c`). The libraries' blocks, tasks' stacks among them,
    first fill regions of their own, with the shim's own allocator in each: the two pieces above,
    then one block of `SPIKE_LIB_REGION_KB` taken from the runtime's heap at the first allocation
    (64 KB in the two-radio image, 32 KB in the Wi-Fi image, 16 KB otherwise). What fits in none
    comes block by block from the heap, as in part 9. So the libraries' many small blocks no longer
    lie among the actors' stack chunks. `SPIKE_LIB_LIMIT_KB` (160) bounds all they hold: beyond it
    they are refused, which they report, where an exhausted heap ends the runtime. A region's
    blocks are zeroed when handed out, as the runtime's are.
  - **Measured**, 160 MHz:

    | Image | The libraries hold (most) | In the regions | The heap in use, of |
    | --- | --- | --- | --- |
    | Both radios, fifteen links on each | 118 KB (134 KB) | 119 KB of 120 KB | 206 to 235 KB of 271 KB |
    | Wi-Fi, eight links | 80 KB (84 KB) | 68 KB of 71 KB (before the region was 32 KB) | 149 KB of 258 KB |

  - **The demos' owners watch their links.** A carrier refused its memory ends without a word to
    its owner, which waited for ever. The Wi-Fi demo's owner now sends itself `(:watch, n)` when it
    opens link n and ends the run with status 6 if that link is still in hand `watch_ms()` (60 s)
    later; the two-radio demo's Wi-Fi owner the same, telling the coordinator 6. Checked with
    `watch_ms()` at 1.5 s: status 6.
  - Runs after these changes: the two-radio image 15 and 15 three times; the Wi-Fi image eight links
    of eight; the Bluetooth image five of five.
  - **Open.** As part 11, less the heap: 16 KB of instruction RAM at 0x40374000 (ESP-IDF loads
    applications' code there with its default 16 KB instruction cache, so the ROM leaves it free;
    it holds code only); the 230 bytes a Wi-Fi link leaves behind; the radio closed between
    beacons; the station at times loses the access point while Bluetooth has a link. The runtime's
    linker script could give the 22 KB above the image to every ESP32-S3 program's heap; here only
    the radio images use it.

- **Stage 12, part 13, 2026-11-16, done: the hosts' `(:tcp)` trials on the board.** The trial
  programs of `transport_addition` and `ffi_addition` that use the hosted `(:tcp)` carrier are built
  unchanged as R1 images and run on the board; the console output is compared with each trial's
  `.scout`, the output the hosts must give (`spike_r1/run_r1_tcp_trials.sh`, the comparison by
  `tools/compare_sout.sh`).
  - Both ends of these trials are in the one program, on 127.0.0.1. lwIP has a loopback interface
    of its own; it had been started only when the station joined. `spike_net_core` (`wifi_net.c`)
    starts lwIP's task alone, and the wrapper calls it before it makes a socket, so a program that
    never opens `(:wifi, 0)` has TCP on 127.0.0.1 with no access point and no peer.
  - Of the ten programs:

    | Program | On the board |
    | --- | --- |
    | `app_transport_tcp_listener/dangerous_tcp_listener` (a listener, two peers accepted, a session each) | as the `.scout` |
    | `app_transport_tcp_listen_any/dangerous_tcp_listen_any` (`listen:any:0`) | as the `.scout` |
    | `ffi_addition/app_transport_tcp_loopback/dangerous_tcp_loopback` | as the `.scout` |
    | `app_transport_tcp_link_rules/dangerous_link_listen_ip` | as the `.scout` |
    | `dangerous_tcp_loopback_link`, `dangerous_link_listen_ip_refused_loopback` (`(:loopback)`) | refused by the compiler, E2412 |
    | `dangerous_link_ethernet_absent`, `dangerous_link_interface_absent`, `dangerous_link_listen_any_refused_interface`, `dangerous_link_wifi_absent` | refused by the compiler, E2412 |

    The six refused name a link the board's pack does not provide; four of them are the hosts' trials
    of a link that is absent at run time, which the board refuses when it compiles.
  - The Wi-Fi image three links of three and the two-radio image three and three after the change.
  - **Open.** Whether the board's pack should provide `(:loopback)` where lwIP is in the image (the
    two trials above would then run); the trials are not in the board's trial harness, which builds
    images without the radio libraries.

- **Stage 12, part 14, 2026-11-16, tried, not adopted: actors on both cores beside the radios.**
  `run_r1_both.sh --both-cores` builds the runtime for two cores (`-DNCORES_RUN=2`,
  `-DR1_BOTH_CORES`) and puts the demo's busy actor on core 1. Bluetooth is whole in every run;
  Wi-Fi is not: TCP connections time out while a Bluetooth link is up. Route R1 stays as it was:
  actors on core 0, core 1 the radios' alone, which this part's changes leave untouched.
  - **What was built.**
    - The radios' handlers on a stack of their own. A level-3 handler ran on whichever stack it
      interrupted; an actor's is a small chunk. `rt_vectors.S`: when foreign code stores a stack's
      top in `silica_rt_level3_stack`, the path spills every live window but the interrupted one to
      its own stack and calls the handler on that stack. With the word 0 the path is as before.
    - The tasks' turn at every pass of core 1's scheduler: `rt_actors.S` calls a weak
      `silica_rt_board_pass(core)` at each pass, idle or between two dispatches; `r1_port.c` gives
      the libraries' tasks one round there. An actor of core 1 that waits inside a foreign call
      passes control to the tasks as a task would.
    - The tasks' turn under a handler (`hci_shim.c preempt`). A dispatch may run long (the busy
      actor's is 200 ms). When a handler has interrupted the program's or the runtime's code on
      core 1, the tasks have a round before that code goes on, the handler's frame standing for it
      among the lines of control; the runtime's save area and the interrupt's registers are kept
      meanwhile. Not inside a foreign call or the scheduler's own pass (library code the tasks are
      not written to run under), nor while the heap's or the console's lock is held.
    - A tick for the timers: the processor's second cycle timer, level 3, at the earliest timer's
      time and every 2 ms at the latest. Without it the station took 18 s to join, with a fixed
      2 ms tick 6 s, with the timers' times 2 to 3 s, as on one core.
    - In a handler the shim's allocator keeps to the regions and frees a heap block later: the
      handler may have interrupted an actor that holds the heap's lock.
  - **Measured**, 160 MHz, fifteen links on each radio, the busy actor on core 1:

    | Image | Wi-Fi | Bluetooth | Carriers ended `:link_unavailable` |
    | --- | --- | --- | --- |
    | Actors on core 0 (as part 12; this part's code in the image) | 15 of 15 | 15 of 15 | 3, before the station has its address |
    | Actors on both cores | 8 of 15 in 480 s | 15 of 15 | 35 |

    On both cores the station joins and keeps its access point, and DHCP is bound; the carriers
    that fail are refused by `connect`, errno 116, after its five seconds, each beside a Bluetooth
    link coming up. One carrier in that run ended `:out_of_memory` (the second core's scheduler and
    the handlers' 8 KB stack come out of the same RAM).
  - **What it is taken to mean.** Espressif's libraries are written for a scheduler that runs
    their tasks and timers at once, above everything else. Beside cooperative actors on the same
    core they get their turn only where the actor's code allows: not during a foreign call, nor a
    console line (9 to 14 ms measured). Which of these costs Wi-Fi its share of the radio under
    coexistence was not found: a count of refused turns (`-DSOCKETS_PREEMPT_REPORT`) cannot tell a
    foreign call that waits, and so gives the tasks their turns, from one that does not.
  - Switches left in for the next attempt: `-DR1_NO_PREEMPT`, `-DR1_TICK_US=<n>`,
    `-DSOCKETS_STATION_REPORT` (why the station lost its access point, why `link_select` or
    `connect` refused), `-DSOCKETS_PREEMPT_REPORT`.

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
   As built (2026-11-14): pairing with no code and no keys kept; the peripheral decides whether a link is
   encrypted, and a board as peripheral always requires it. A code shown on the board's console, which would
   prove the peer, is not built.

5. **`mtu` is the literal 20; the negotiated value arrives in `:link_up`.** Every `Carrier` method body is a literal,
   `Carrier@mtu(<name>)` resolves to the kind's row, and `wireframe@frame` takes the `mtu` as an argument, so an
   owner can use the negotiated value without a compiler change.

6. **One link tag, `(:bluetooth, n)`, on every target; the role and the service go in the `:open` address.** The
   links design §4 puts the hardware in the declaration and the peer in the address. A `(:ble_gatt)` carrier is
   `:datagram` everywhere: a carrier tag has one literal row.

7. **Decision 15 of the links design holds for BLE trials.** Board trials stay compile-time, assembly, diagnostics
   and one direction. The two-way runs are scripts outside `make integrate`.

8. **Linux comes after the board** (stage 11), together with the Linux goldens that already wait to be regenerated.
   Deferred on 2026-11-14 until a Linux machine with Bluetooth is at hand.
