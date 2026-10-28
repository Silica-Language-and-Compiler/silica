# ESP32-S3 board peripherals — development plan

**Scope:** supporting all of the port test board's on-board hardware from Silica through device workers
(`peek`/`poke` over board-pack descriptions), and the agreed program of efficient Silica versions of the
hand-built assembly bring-up apps. `ESP32-S3_raw` only; not one of the numbered
[ROADMAP.md](../../ROADMAP.md) chunks.
**Authority:** [silica_device_actor_specification.md](silica_device_actor_specification.md) wins where this
plan differs from it (§4.7 poke prims, §4.9 and §4.9.1 descriptions and the board pack, §5.1 exclusive
windows, §5.3 DMA buffers, §9 runtime IRQ contract, §11 compile-time enforcement).
**Related:** [porting_for_os_free_targets.md](porting_for_os_free_targets.md) §10 (board-pack contract),
[ports/esp32s3_port_status.md](ports/esp32s3_port_status.md),
[actor_memory_budget_plan.md](actor_memory_budget_plan.md),
[board_pack.silica](../src/emitter/ESP32-S3_raw/board_pack.silica),
[PORT_TEST_BOARD_byu_idaho_v4.0_feb26.md](../src/emitter/ESP32-S3_raw/board/PORT_TEST_BOARD_byu_idaho_v4.0_feb26.md).

The board is the BYU-I eBadge v4.0 (ESP32-S3-MINI-1-N4R2). Four Silica device apps ran on it by 2026-10-01
(`silica_16_device_uart`, `silica_17_device_gpio`, `silica_18_device_display`, `silica_19_device_led_hold`);
three more exist (`silica_20_device_buttons_led`, `silica_21_device_led_row`, `silica_22_device_buzzer`).

**Implementation status (2026-10-28).** Items A to C are in the tree; D is done on the board except two open
points; E to R are not started, and no item beyond the ones named here has code.

| Item | Status | Where it lives |
| --- | --- | --- |
| A | Display on SPI2: `silica_18_device_display` redraws the `asm_13_display_hello` picture through the SPI2 peripheral | `board/apps/device_lib/device_esp32s3_spi2.silica`, `device_st7789.silica`; SPI2 values in `board/pack/board_pack_spi2_values.silica`. The SPI2 base is still marked TRM-unconfirmed in `board_pack.silica` (`window_base_verified`); the board result of the app is not recorded in `board/README.md` beyond its expected output |
| B | Done: the generator reads Espressif's register headers and writes per-peripheral value and description modules with access modes (GPIO, IO_MUX, UART0, SPI2, SYSTEM, LEDC, RMT). Not done for the other chip windows (RTC_CNTL, TIMG0/1, SYSTIMER, USB-Serial-JTAG, I2C0, SPI3, GDMA, USB OTG): the generator covers the seven peripherals above only. Whether spec §4.9.1 gained the "every register" sentence was not checked (no hit for the wording in `silica_device_actor_specification.md`) | `board/tools/gen_board_pack.py` (`--check` diffs it against the tree), `board/pack/` |
| C | Done: buzzer on LEDC timer 0 (`silica_22_device_buzzer`: 440, 880, 2730 Hz); 24 WS2813B LEDs from RMT channel 0 (`silica_21_device_led_row`, matched its `expected.scout` on the board 2026-10-15). RMT channel RAM is written one `poke` per word; `poke_n` was not needed so far | `device_lib/device_esp32s3_ledc.silica`, `device_buzzer.silica`, `device_esp32s3_rmt.silica`, `device_ws2813b.silica` |
| D | Done on the board 2026-10-28 except two open points (the Point button's change was not observed; the `silica_24` colours were not visually recorded). The GPIO worker carries `silica_17`, `silica_19` and `silica_20_device_buttons_led` and the twins `silica_23_device_blink` (`asm_01`), `silica_24_device_rgb` (`asm_02`), `silica_25_device_buttons_full` (`asm_03`, all seven buttons), `silica_26_device_gpio_diag` (`asm_08`), `silica_27_device_pin_readback` (`asm_09`) and `silica_28_device_pin_hunt` (`asm_10`; 440 Hz square on pins 2, 3, 7, 8, 9, 12 to 18, 45, 46 for about 4 s, run inside the worker by the `:square` op over the `out_w1ts`/`out_w1tc` and `out1_w1ts`/`out1_w1tc` masks). The worker gained the ops `:input_buffer`, `:peek`, `:route_oen`, `:square`, `:watch_all` and the pins 8, 9, 12 to 18, 33, 34 (exact list in the driver's header comment). Coverage check of the native apps: see "Coverage of the native apps" in section 3; gaps filled with `silica_29_recursion_wide` and `silica_30_heap_list`. Board results (`run_app.sh`, RAM load, ESP32-S3 rev v0.2 on /dev/cu.usbserial-310, compiler `silica-999973`): `silica_23` matched `expected.scout` twice and LED1 was seen blinking 10 times; `silica_24` console matched, visual not recorded; `silica_25` see below; `silica_26` ran clean with consistent register values (IO_MUX_GPIO6 0x1800 to 0x1A00 with FUN_IE; IO_MUX_GPIO21 0x1300, pull-up and IE; GPIO_ENABLE and GPIO_OUT bit 6 follow the writes; GPIO_IN bit 6 follows only with the input buffer on, 0xfc000041; FUNC6_OUT_SEL_CFG 0x100 to 0x500) and LED1 was confirmed; `silica_27` printed `pin N: 1 0` for 1, 2, 4, 5, 6, 7, 48 (every pad driven); `silica_28` matched `expected.scout` twice and was confirmed by the observer; `silica_29` matched. `silica_30`: the first version (sum by `[h, t]` pattern walk) aborted "heap exhausted" after printing 2000; it now sums by index with `list_at` (tail-recursive) and matched. `silica_25`: the first version aborted "[silica] abort: heap exhausted" after about 8 s (about 357 B retained per 10 ms round); the 30 s poll now runs inside the worker as `:watch_all` (one peek of GPIO_IN and one of GPIO_IN1 per round; casts the 7-bit button mask on start and on each change, 128 for done; LED1 lit while the mask differs from idle). The second run completed 30 s, printed `done`, status 0; idle levels Left/Right/Down/Up/A/B 0 and Point 1 (six buttons active high, Point/BOOT active low); Left, Right, Up, Down, B and A each logged press and release and LED1 was seen lit while each was held. Point never logged a change in either run (whether it was pressed is not established): open. See "Known issue: board emitter heap" in section 6 and "Environment notes" below it | `device_lib/device_esp32s3_gpio.silica`, `board/apps/silica_23_device_blink` to `silica_30_heap_list` |
| E to R | Not started | none |

The board pack's own window table now has 12 windows (`window_count()` in `emitter/ESP32-S3_raw/board_pack.silica`):
UART, GPIO, RTC_CNTL, IO_MUX, TIMG0, TIMG1, SYSTIMER, USB-Serial-JTAG, SYSTEM, SPI2, RMT and LEDC (RMT and LEDC
bases from ESP-IDF headers, TRM-unconfirmed). The "State today" column of section 2 and principle 2 below are
the 2026-10-01 starting position.

## 1. Principles (decided 2026-10-01)

1. **Direct access to every part of the device.** Every register of every on-board peripheral is reachable
   with `peek`/`poke`, even where a convenience exists (our drivers, the runtime's GPIO/console/delay
   helpers, ROM routines). A convenience is an additional layer over the same descriptions, never the only
   way in.
2. **The board pack is the only description of on-board devices** (spec §4.9.1), so it must describe every
   register of every on-board peripheral, with access modes. Hand-copying the chip's register map is
   impractical: generate it from Espressif's register headers (spec §3.3 anticipates a generator), checked
   in per target. The current ESP32-S3 pack lists about 33 registers in 10 windows and records no access
   modes (only `register_runtime_use`), so it is not yet conforming.
3. **Efficient means the peripheral does the timing-critical work**; `peek`/`poke` configure it and feed it
   data. Measured motivation: the Silica display app (bit-banged SPI, one poke per clock edge) took about
   26 s for a fill plus text, and the panel showed horizontal stripes sweeping to black because DISPON came
   before the fill.
4. **Runtime-shared windows** (UART0 console, SYSTIMER restart clock) stay mappable. The byte-level
   interleaving with the console is documented, not prevented.
5. **Board runs that need a person watching are announced first and run one at a time.**

## 2. Shared prerequisites

| Prerequisite | State today | Needed by |
| --- | --- | --- |
| Board-pack windows and registers for every controller involved: I2C0, SPI2, SPI3, USB-Serial-JTAG, USB OTG, RMT, LEDC, GDMA, plus the rest of the chip via the generator | 10 windows (UART, GPIO, RTC_CNTL, IO_MUX, TIMG0, TIMG1, SYSTIMER, USB-Serial-JTAG, SYSTEM, SPI2), ~33 registers, no access modes; USB-Serial-JTAG has one register (CONF0); SPI2's base `0x60024000` is TRM-unconfirmed (`window_base_verified`) | every item |
| Interrupts | The runtime runs with interrupts off and polls. Spec §9's contract (the handler only acknowledges and enqueues a message to the owning device worker; the pack names IRQ to worker) is not implemented | USB OTG; optional elsewhere. Polling suffices for I2C and SD |
| DMA (spec §5.3: buffer moved to the worker and moved back in the result) | Not implemented | Optional for I2C; very useful for SD and the display; close to required for USB at speed |
| `poke_n` | Not in the spec | Only if a driver shows the need: runs of stores to consecutive registers (SPI2's 16 data words, RMT channel RAM). Needs a spec addition first: one store per value, in order, to consecutive described registers |

## 3. Efficient Silica versions of the hand-built apps

Agreed order, steps 1 to 4. Reference apps are under `src/emitter/ESP32-S3_raw/board/apps/`.

| Step | asm app | Silica version | How it is made efficient |
| --- | --- | --- | --- |
| 1 | `asm_13_display_hello` | `silica_18_device_display` (rework) | Fill before DISPON, so the first visible frame is black. Then the SPI2 peripheral with its 64-byte data buffer (16 x 32-bit registers) instead of bit-banging: about 0.3 pokes per byte instead of about 16, and the clock rate is independent of the CPU |
| 2 | (none) | board pack generated; `device_lib` descriptions removed | See below |
| 3 | `asm_04_buzzer` | new, LEDC | Hardware PWM sets frequency and duty; no software square wave |
| 3 | `asm_11_addressable_leds` | new, RMT | RMT generates the WS2813B waveform (24 LEDs) from a RAM table; bit-banging cannot meet the nanosecond timing from Silica |
| 4 | `asm_01_blink`, `asm_02_rgb`, `asm_03_buttons`, `asm_08_gpio_diag`, `asm_09_pin_readback`, `asm_10_pin_hunt` | on the GPIO device worker (extends `silica_17_device_gpio`) | Port reads and writes through the worker's described registers (set/clear/enable-style registers), no per-pin helper loops |
| 4 | `asm_00_hello`, `asm_05_recursion`, `asm_06_heap`, `asm_07_fault` | coverage check against `silica_00` to `silica_15` (and `silica_16` to `silica_19`); write whatever is missing (done 2026-10-28, see below) | Native Silica already; the work is finding gaps |

### Coverage of the native apps (item D, 2026-10-28)

Only four native apps exist under `board/apps/` (`asm_00_hello`, `asm_05_recursion`, `asm_06_heap`, `asm_07_fault`), not five; every other `asm_*` app is GPIO, display, LEDC or RMT. Each behaviour of the four and the Silica app that covers it:

| asm app | Behaviour | Covering Silica app(s) |
| --- | --- | --- |
| asm_00_hello | UART0 text output ("hello from silica ...") | silica_04_print (prints "hello from silica", then int64 values) |
| asm_00_hello | main's int64 result becomes the exit status (42) | silica_00_return42 (status 42) |
| asm_00_hello | text and a non-zero int64 status in one run | silica_04 (text) with silica_00 (status); silica_15 shows output followed by an int64 result. No single app prints and returns 42; judged covered by the two halves |
| asm_05_recursion | 1000-deep recursion forcing window overflow and underflow | silica_07_recursion_depth (2000 deep), silica_29_recursion_wide (1000 deep) |
| asm_05_recursion | int64 add with carry into the high word | silica_05_int64_wide (no recursion), silica_29_recursion_wide (1000 x 4294967295 through recursion; new) |
| asm_05_recursion | values survive across deep calls (sentinels a2..a7) | silica_29_recursion_wide (six bound values checked after both deep calls; new). Register sentinels as such are not expressible: Silica has no register access, the closest is bound values |
| asm_06_heap | 2000 allocations, linked list of nodes, walk and sum | silica_09_lists (100 elements), silica_30_heap_list (2000 elements, length, sum, end elements; new) |
| asm_06_heap | blocks are zeroed and 8-byte aligned | not expressible: Silica has no raw allocation or pointer reads; closest silica_11_regions (alloc_ref/alloc_buf read back, region growth) |
| asm_06_heap | heap usage figure ("heap used 64000") | not expressible: no Silica builtin exposes the runtime heap counter; closest silica_30_heap_list (2000 nodes must fit) |
| asm_07_fault | load from address 0 gives the fatal fault report and status 70 | not expressible as a load: peek/poke only accept a map_device window (a base outside a window is the runtime abort "illegal device map", status 71, not a fault), and plain Silica has no pointers. Closest: silica_08_stack_guard (fatal fault report "[silica] fault at <PTR>", status 70) |
| asm_07_fault | output before the fault is flushed ahead of the report | silica_08 prints nothing first; silica_15_list_index_abort prints "9" before its abort report (status 71, abort path, not fault) |
| asm_07_fault | board-only details after the exit marker (exccause=28 LoadProhibited, EXCVADDR) | not expressible, board-only text (stderr); only asm_07 reaches exccause 28 |

Gaps filled: `silica_29_recursion_wide` (1000-deep recursion, int64 wide sum, values bound across deep calls) and `silica_30_heap_list` (2000-element list built, walked and summed). Not expressible in Silica: register sentinels, block zeroing and alignment, the heap-usage figure, and a load from address 0 (`peek` and `poke` reach only `map_device` windows; a bad base is the "illegal device map" abort, status 71). The closest covered behaviours are named in the table. Both new apps' expected output matches the macOS host run, and both matched on the board 2026-10-28.

**Step 2 detail.** Generate the full register map with access modes into `board_pack`. The compiler reads
board-pack descriptions (spec §4.9.1), and the hand-written `device_lib` descriptions
(`board/apps/device_lib`) that duplicate board-pack devices are removed. Add one sentence to spec §4.9.1:
a board pack describes every register of every on-board device, and a convenience layer never replaces
direct access.

## 4. Peripheral support

### 4.1 USB

The board has two USB-C connectors.

| Connector | Path | Work |
| --- | --- | --- |
| USB-UART | CP2102N bridge to UART0 | None: already the console |
| USB-CDC (native USB, GPIO19/20) | Two controllers share these pins: see (a) and (b) | |

- **(a) USB-Serial-JTAG:** a fixed-function serial plus JTAG device (a FIFO and a few status registers).
  A device worker gives a second console; small, similar to the UART worker. Its window is in the pack
  today with one register (CONF0).
- **(b) USB OTG:** the full-speed device/host controller. Making the board a custom USB device (mass
  storage, HID, MIDI) or a host needs a USB stack (enumeration, descriptors, endpoints, control transfers),
  effectively porting something like TinyUSB to Silica. Large; needs interrupts.
- **Open:** the board's USB power-role switching hardware (the `pd_switch` / `dm_pd_switch` sheets in the
  eBadge design) may need GPIO control. Check against the schematic.

### 4.2 Minibadge A and B

Each header carries a clock, three I/O lines and the shared I2C bus (SCL GPIO42, SDA GPIO41; the MMA8452Q
accelerometer at 0x1C is on the same bus).

Support: an I2C0 controller device worker (start, address, read/write, stop, ACK and timeout handling),
which also gives the accelerometer, plus the GPIO worker for the CLK/IO lines.

| Header | CLK | IO1 | IO2 | IO3 | Source |
| --- | --- | --- | --- | --- | --- |
| Minibadge A | 13 | 14 | 15 | 16 | board sheet |
| Minibadge B | 45 | 17 | 18 | 12 | board sheet |
| Minibadge B | 16 | 17 | 18 | n/a | silkscreen |

Cautions:

- The pin assignments disagree between the board sheet in our docs and the silkscreen. Settle from the
  netlist.
- Under the sheet's assignment, Minibadge B shares GPIO45 with the display D/C and GPIO12 with the battery
  voltage sense. Spec §5.1 requires one worker per controller, so they cannot be driven independently.

### 4.3 SD card on SPI3 (MISO 37, MOSI 39, CLK 38, CS 40)

1. **Block access:** an SPI3 device worker speaking the card's SPI-mode protocol (CMD0, CMD8, ACMD41
   initialisation; 512-byte block read and write; CRC and timeouts). Moderate; the same shape as the SPI2
   display work, which it reuses.
2. **A filesystem** layered on the block worker, needed only for files rather than raw blocks. The choice is
   open and is not necessarily FAT. `file_io` is refused as unsupported on this target today; a filesystem
   gives it a backend.

| Option | For | Against |
| --- | --- | --- |
| FAT32 | Readable everywhere; default on SDHC up to 32 GB | No power-loss safety; 4 GB file limit |
| exFAT | Default on SDXC above 32 GB; spec published by Microsoft in 2019 | More complex; same power-loss weakness |
| littlefs-style log-structured copy-on-write | Power-loss safe, wear-aware, small RAM | Not readable on a PC without a tool |
| Silica-native store (append-only record log or block-indexed store) | Smallest; fits the badge's needs | Only Silica reads it |
| Raw blocks | No filesystem to build | No files, no names |

Power loss mid-write is a real risk on a battery-powered badge, which favours a log-structured design.
FAT32 or exFAT matter only when the card is moved to a computer. Several can coexist above the same block
worker.

### 4.4 Bluetooth and Wi-Fi

The ESP32-S3 has Bluetooth 5 Low Energy (LE only, no Bluetooth Classic) and 2.4 GHz Wi-Fi. On this
bare-metal, ESP-IDF-free port both are effectively out of reach: the radio's registers are undocumented,
and the controller, PHY calibration and Wi-Fi MAC exist only as closed binary libraries inside ESP-IDF that
expect an OS layer (FreeRTOS-style tasks, queues, timers). Using them means linking the blobs and writing
that OS adaptation, which conflicts with the port being ESP-IDF-free and with the direct-access principle
(the radio's internals are not reachable). This is a separate decision, together with
[ROADMAP.md](../../ROADMAP.md) chunk 9, "Networking through Fifi": networking is not part of the language
(spec §20.4) and is reached through the Foreign Function Interface, so a radio stack would arrive as foreign
code under that model rather than as device workers. The radio decision is independent of the Silica
network stack of §4.6, which can sit on a wired link (UART1, USB, SPI Ethernet) and, if Wi-Fi is ever
adopted, on top of the radio's link layer.

### 4.5 Order of effort, smallest first

| Rank | Item | Size |
| --- | --- | --- |
| 1 | USB-Serial-JTAG console | small |
| 2 | I2C: minibadges and accelerometer | small to moderate |
| 3 | SD block access | moderate |
| 4 | SD plus a filesystem | substantial (depends on the choice) |
| 5 | USB OTG with a stack | large; interrupts |
| 6 | Networking in Silica over SLIP/PPP on UART1 (§4.6) | moderate to large (the stack); the link is small |
| 7 | Networking over USB CDC-NCM (§4.6) | moderate on top of rank 5 and rank 6 |
| 8 | SPI Ethernet add-on link (§4.6), optional | moderate; needs add-on hardware |
| n/a | Bluetooth / Wi-Fi radio | off the scale; separate decision |

### 4.6 Networking in Silica

**Principle.** The network stack is a Silica library, not a language feature. This is consistent with spec
§20.4: networking adds no language surface, no built-in types and no runtime support. The stack is ordinary
Silica modules. Its structure:

- Supervised actors for IPv4, ARP, ICMP, UDP, TCP, DHCP and DNS.
- A device worker owns the link hardware, under the device-actor rules (one worker per controller, spec
  §5.1).
- Packets move between actors as owned buffers (spec §5.3 move rules): a layer that forwards a packet
  gives it up.

On hosted targets the same library could ride on a link the OS provides, but the hosted path stays Fifi per
[ROADMAP.md](../../ROADMAP.md) chunk 9. The board library is the OS-free path. Whether the library also
becomes the recommended route on hosted targets is a decision for the roadmap, not this plan.

**Link layer.** The board has no Ethernet controller, and the radio's MAC/PHY exist only as closed ESP-IDF
libraries (§4.4). The options:

| Link | Silica end to end? | Depends on | Notes |
| --- | --- | --- | --- |
| SLIP or PPP over UART1 (the UART1 header: GPIO35 TX, GPIO36 RX) | Yes | A UART1 device worker | The smallest first step. A host bridges the serial line to its network (for example `slattach` or `pppd`). Proves the stack |
| USB network device, CDC-NCM or CDC-ECM, over the USB OTG controller | Yes | The USB OTG stack (§4.1(b), item L) | The board appears to a computer as a USB network adapter |
| SPI Ethernet add-on (a raw Ethernet MAC such as the ENC28J60 on an SPI header) | Yes | An SPI device worker and an add-on board | A device worker moves Ethernet frames |
| Wi-Fi | Only above the link | The closed 802.11 MAC/PHY, reached through Fifi and an OS adaptation layer | Conflicts with the ESP-IDF-free port and with the direct-access principle (§4.4). IPv4 and everything above can still be the Silica stack. A separate decision |

**Recommended order.** SLIP/PPP over UART1 first (stack bring-up), then USB CDC-NCM (after the USB OTG
work), with SPI Ethernet as an optional hardware path and Wi-Fi left to the separate decision.

**Stack requirements.**

- **Timers.** TCP needs retransmission and delayed-ACK timers: [ROADMAP.md](../../ROADMAP.md) chunk 11
  (time: monotonic clock, `send_after`), or a board-local timer worker over SYSTIMER/TIMG via `peek`/`poke`.
- **Untrusted bytes.** Every received byte is untrusted input: buffer bounds checking (ROADMAP chunk 4).
- **Owned packet buffers** per spec §5.3 move rules.
- **Memory.** A TCP connection's buffers plus its actors must fit the roughly 170 KB heap; see
  [actor_memory_budget_plan.md](actor_memory_budget_plan.md).
- **Helpers.** Checksums (IP, ICMP, UDP, TCP) and byte-order conversion.
- **Program API.** The actor surface of "Connections and endpoints are actors" below: no socket layer.

**Connections and endpoints are actors (decided 2026-10-01, project owner).** There are no sockets. A
connection or an endpoint is an actor, and the program talks to it with messages.

- **Connect.** A TCP connection is an actor. A program sends the stack a connect message (peer address and
  port, and the owner actor); the stack starts a connection actor for that peer and the program receives its
  `actor_ref`. Sending is a cast of an owned buffer to the connection actor; the buffer moves (spec §5.3).
  Received data arrives as messages to the owner actor the program named when connecting.
- **Listen.** Listening is an actor: a listener actor for a port starts one connection actor per accepted
  peer and tells the owner with a message carrying the new connection's ref (or starts it under the
  program's supervisor).
- **Close and failure.** Closing is the actor ending. Failure is an exit with a reason (reset, timeout),
  handled by links, monitors and supervisors like any actor: the "crash to the supervisor" rule applies to
  networking unchanged.
- **UDP.** An endpoint actor per bound port; each datagram is a message.

Chain on the board (no socket layer anywhere):

| Layer | Actor | Role |
| --- | --- | --- |
| 1 | Link device worker | Owns the link hardware (§5.1); frames in and out |
| 2 | IP/ARP actor | Address resolution, IPv4 dispatch, ICMP |
| 3 | TCP demultiplexer | Routes each segment by the address/port 4-tuple |
| 4 | Connection actors | Each holds its own TCP state machine, sequence numbers and timers (ROADMAP chunk 12's StateMachine trait fits) |
| 5 | Program actors | Owners, and senders to the connection actors |

**Flow control is credit-based.** A mailbox does not block a writer the way a socket buffer does, so
nothing may be pushed without credit:

- Receive: the connection actor delivers data to the owner up to a window of credits; the owner returns
  credits as it consumes, and the TCP receive window advertised to the peer follows the owner's actual
  consumption.
- Send: the same scheme in reverse. The connection actor grants the program send credits as the peer
  acknowledges.
- Data messages to one owner stay in order (per-sender mailbox order). Buffers move, never copy.

**Memory.** Each connection costs an actor plus its buffers against the board's roughly 170 KB heap (see
[actor_memory_budget_plan.md](actor_memory_budget_plan.md)), so the number of simultaneous connections
is a budget item (§6).

**Hosted targets.** The OS owns the network, so there are sockets underneath there, reached through Fifi as
spec §20.4 requires. The program-facing model is the same: a connection actor wraps the OS socket inside a
dangerous actor. Programs look identical on every target; only the board has actors all the way down.
Whether hosted targets use this library or a Fifi wrapper with the same actor surface remains the roadmap's
decision (§6).

## 5. Work

Items A to D are the agreed steps 1 to 4, in that order. Prerequisites sit where first required.

| Item | Delivers | Depends on | Board-pack windows |
| --- | --- | --- | --- |
| A | Step 1: display fill before DISPON; display on SPI2's 64-byte buffer | SPI2 base confirmed against the TRM; SPI2 registers in the pack | SPI2, GPIO, IO_MUX, SYSTEM (clock gate), SYSTIMER |
| B | Step 2: register-map generator from Espressif headers; generated pack checked in with access modes; compiler reads the pack; `device_lib` duplicates removed; spec §4.9.1 sentence | A (so the SPI2 rows are confirmed before generation replaces them) | all chip windows, via the generator |
| C | Step 3: buzzer on LEDC; 24 WS2813B LEDs on RMT (channel RAM written one `poke` per word; decide `poke_n` here if the cost shows) | B | LEDC, RMT, SYSTEM, GPIO, IO_MUX |
| D | Step 4: GPIO apps on the GPIO worker; coverage check of the four native apps against `silica_00` to `silica_19`, filling gaps | B | GPIO, IO_MUX, RTC_CNTL, TIMG0/1, SYSTIMER |
| E | `poke_n` spec addition and implementation, only if C or a later driver needs it | spec decision first (§2) | none |
| F | USB-Serial-JTAG second-console worker | B | USB-Serial-JTAG (full register set) |
| G | I2C0 controller worker; accelerometer readings; minibadge I2C; GPIO worker for minibadge lines | B; minibadge pin question (§6) settled | I2C0, GPIO, IO_MUX |
| H | DMA per spec §5.3 (GDMA window, buffer move-and-return) | B; optional for G | GDMA |
| I | SD block access on SPI3 | B; H recommended | SPI3, GDMA, GPIO, IO_MUX |
| J | Filesystem layer chosen per §4.3 and its `file_io` backend for this target | I; choice settled (§6) | none beyond I |
| K | Interrupt runtime per spec §9 (handler acks and enqueues to the owning worker; pack names IRQ to worker) | design decision (§6) | interrupt matrix, SYSTEM |
| L | USB OTG device/host stack | B, H, K | USB OTG, GDMA |
| M | Radio: a decision, not scheduled work | networking chunk | n/a |
| N | UART1 device worker and SLIP (or PPP) link worker | B | UART1, GPIO, IO_MUX, SYSTEM (clock gate) |
| O | Silica network stack core: owned packet buffers, checksum and byte-order helpers, IPv4, ARP (Ethernet links), ICMP, DHCP, DNS as supervised actors; UDP endpoint actors (one per bound port, a datagram per message) | N; bounds checking (chunk 4) | none beyond N |
| P | TCP demultiplexer, connection actors (own state machine, retransmission and delayed-ACK timers) and listener actors; the actor surface for programs (connect message returning the connection ref, owner delivery, owned-buffer cast to send, credit-based flow control in both directions) | O; timer source settled (§6) | SYSTIMER or TIMG0/1 if a board-local timer worker is used |
| Q | USB CDC-NCM (or ECM) link worker; DHCP over it | L, O | USB OTG, GDMA |
| R | SPI Ethernet add-on link worker (optional) | O; add-on hardware; SPI worker (item A's SPI2 work, or SPI3 if the SD card is absent) | SPI2 or SPI3, GPIO, IO_MUX |

## 6. Open questions

- Minibadge pin assignment (board sheet versus silkscreen); settle from the netlist.
- The `pd_switch` / `dm_pd_switch` control lines: does the board need GPIO control for USB power-role
  switching?
- Whether `poke_n` is needed at all.
- The interrupt runtime design (spec §9) for USB.
- Base addresses for SPI2, RMT, LEDC, I2C0, SPI3 and USB to be confirmed against the TRM (SPI2's base is
  already marked TRM-unconfirmed in `board_pack.silica`; the other bases and the 4 KB extents are
  likewise unconfirmed).
- The SD filesystem: FAT32, exFAT, a log-structured copy-on-write design, a Silica-native store, raw blocks, or
  several of them above the one block worker (§4.3).
- The radio, as a separate decision with the networking chunk.
- (Settled 2026-10-01: no sockets; connections and endpoints are actors with credit-based flow control. See
  §4.6.)
- The timer source for TCP: ROADMAP chunk 11 time facilities, or a board-local timer worker over
  SYSTIMER/TIMG.
- Whether hosted targets adopt the Silica network library as the recommended route, or stay on Fifi
  (ROADMAP chunk 9); a roadmap decision.
- Buffer budget per connection against the roughly 170 KB heap, and how many simultaneous connections
  that allows.
- SLIP or PPP for the first link (PPP adds negotiation and authentication; SLIP is smaller).

### Known issue: board emitter heap (recorded 2026-10-28)

On the board emitter, before chunk 15 phase 9 (`chunk15_stack_memory_design.md` §9.1, §11.1; phase 2 changed only the hosted emitters):

- (a) Tuple results of functions that a caller destructures (the GPIO driver's `read_level`/`serve` returning `(g, level)`/`(g1, m)`) are heap-promoted (24 B each) and never freed, so a device worker leaks per message.
- (b) Each `[h, t]` list match allocates a 32-byte tail handle (`silica_rt_list_tail`) that is never freed, and dead list handles from prepend are not freed either.

Long-running workers and long list walks therefore exhaust the heap ("[silica] abort: heap exhausted"). Fix: chunk 15 phase 9 (large, planned). Workarounds used in item D: the `:watch_all` and `:square` loops run inside the worker; `silica_30` sums by index. The reproducers below were derived from code reading and have not been run.

Reproducer 1, tuple results (board today prints 1000 then 24000; after the fix 1000 then 0):

```
fn pair(a: int64, b: int64) -> (int64, int64) {
    (a + 1, b)
}
fn spin(n: int64, acc: int64) -> int64 {
    case n == 0 of {
        true -> acc;
        false -> {
            (x, y) <- pair(acc, n);
            spin(n - 1, x + y - n)
        }
    }
}
fn main() -> atom {
    sequence proc[mem(normal), device_io]
        h0: int64 <- heap_used();
        r: int64 <- spin(1000, 0);
        h1: int64 <- heap_used();
        p1: atom <- print_int64(r);
        println();
        p2: atom <- print_int64(h1 - h0);
        println()
    produces pure :ok end
}
```

Reproducer 2, list tails: `silica_30`'s original `count_down` and pattern-matching `sum_list` (`[h: int64, t: List[int64, mem(normal)]] -> h + sum_list(t)`) over `count_down(100, none)`, printing the sum and `heap_used()` before and after the sum. Board today: 5050 and 3168 (99 x 32); after the fix: 5050 and 0.

### Environment notes (2026-10-28)

`binaries/silica-compiler-ESP32-S3_raw` currently points (uncommitted) at `silica-999970`, which hangs compiling GPIO-worker apps (`silica_17` did not finish in 300 s); the item D runs used `silica-999973`. `build_image.sh` defaults to xtensa `esp-16.1.0_20260609` and the idf6.2 `esptool`, which are not installed on this machine; the runs used `XTENSA_BIN=esp-15.2.0_20251204` and `ESPTOOL`/`BOARD_PYTHON` from `idf6.1_py3.14_env`.

## 7. Gate

| Item | Passing on the board |
| --- | --- |
| A | First visible frame is black; full-screen fill visibly fast (seconds, against about 26 s for the bit-banged app) |
| B | Generated pack validates under spec §4.9.1's rules (unique names, widths, alignment, no overlap, access modes, registers inside windows); no `device_lib` description duplicates a pack device |
| C | Buzzer at a set frequency (measured, after RV1 is turned up); the 24 LEDs show commanded colours |
| D | Each GPIO app behaves as its asm twin (met 2026-10-28 on the board, except the open points: Point button change not observed, `silica_24` colours not visually recorded); coverage list for the four native apps recorded (section 3), gaps filled (`silica_29`, `silica_30`) |
| F | A second console works on USB-Serial-JTAG alongside UART0 |
| G | Accelerometer readings change when the board tilts; I2C ACK and timeout paths exercised |
| I | An SD block written and read back |
| J | A file created, written, and read back through `file_io` |
| L | Enumerates on a host and passes a transfer |
| N | A frame sent through the UART1 link worker arrives at the host bridge and the reply returns |
| O | The board answers ping over SLIP; a UDP echo through an endpoint actor and a DNS lookup succeed over the bridge |
| P | A listener actor accepts a connection from the host, starts a connection actor, and the owner receives its ref and echoes data by casting owned buffers; a retransmission is exercised by dropped packets; a connect message from the board returns a connection ref and the connection ends with an exit reason (reset, timeout) reaching its supervisor; a slow consumer makes the peer's advertised window shrink (credits honoured) rather than the owner's mailbox growing without bound |
| Q | The host sees a USB network adapter; DHCP obtains an address over USB NCM and ping succeeds |
| R | (optional) The board answers ping through the SPI Ethernet add-on |

Across all items: programs can still `peek` and `poke` every described register directly, including those
the convenience layers use, and a run that needs a person watching is announced and run alone.
