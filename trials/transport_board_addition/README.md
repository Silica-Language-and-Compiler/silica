# transport_board_addition

Board-only trials of the transport carriers the ESP32-S3 board provides (`transport_serialization_design.md`
§6.4; stages 1, S-A and S-C of `transport_esp32s3_wifi_plan.md`, phase B of `transport_links_design.md`). Each
carrier is a device worker, so every register access is inside its `sequence proc[register_rwr]` and the
programs only spawn, cast and wait; the workers, the pack descriptions they map (UART1, GPIO, IO_MUX, SYSTEM,
USB-Serial-JTAG), the board pack, the field constants (`board_pack_uart0_values`, shared by UART0 and UART1;
`board_pack_usb_serial_jtag_values`) and the framing modules (`wireframe`, `Carrier`) are named by the Makefile
from `compiler/`. The board's native USB-C jack must be on a USB host for the `(:usb_serial_jtag)` trial (its
bring-up checks that SOFs arrive); nothing needs to read that port.

| Trial | Shows |
| --- | --- |
| `device_uart1_carrier_tx` | the `(:uart1)` carrier (`device_esp32s3_uart1`: UART1 header, TX GPIO35, RX GPIO36, 115200 8N1) speaking the §6.2 carrier contract: `(:open, owner, "")` brings UART1 up and answers `(:link_up, "uart1@115200")` and `(:tx_credit, 8)`; one 204-byte `:tx` (a `wireframe` frame larger than the 128-byte FIFO, so the worker waits for FIFO room byte by byte) returns `(:tx_credit, 1)` once every byte is in the FIFO; `:close` answers `(:link_down, :closed)`. The board only sends (links design decision 15): nothing needs to be wired to the header, and no trial here receives |
| `device_usb_serial_jtag_carrier_tx` | the `(:usb_serial_jtag)` carrier (`device_esp32s3_usb_serial_jtag@usb_serial_jtag_carrier`: the native USB-C jack through the USB-Serial-JTAG controller) speaking the same contract: `(:open, owner, "")` checks the link (SOF frame index advancing) and answers `(:link_up, "usb_serial_jtag")` and `(:tx_credit, 8)`; one 60-byte `:tx` (under the controller's 64-byte IN FIFO, so it needs no reader: the frame waits in the FIFO until a host opens the port, and the next RAM load clears it) returns `(:tx_credit, 1)`; `:close` answers `(:link_down, :closed)`. The receive direction has no board-only trial (it needs a peer): it is shown by `board/apps/silica_33_transport_usb_serial_jtag_etf` with `programmer_tools/transport_usb_serial_jtag_demo` |
| `device_uart1_link_tx` | the same UART1 program through its link declaration (transport_links_design.md §3.3, stage S-C of transport_esp32s3_wifi_plan.md §8): `carried_on host_line: (:serial) (:uart, 1, 115200);`, `spawn_dangerous_carrier(host_line, ...)` (expanded by the ESP32-S3 pack's `carrier_spawn` to `spawn_device(:idle, device_esp32s3_uart1@uart1_carrier, ...)`) and `Carrier@mtu(host_line)` / `Carrier@boundaries(host_line)` (the `(:serial)` kind's rows); same output as `device_uart1_carrier_tx` |
| `device_usb_serial_jtag_link_tx` | the same USB-Serial-JTAG program through `carried_on usb: (:serial) (:usb_serial_jtag);` and `spawn_dangerous_carrier(usb, ...)`; same output as `device_usb_serial_jtag_carrier_tx` |
| `link_uart0_console_reserved` | compile-failure trial (`link_uart0_console_reserved.ESP32-S3_raw.golden_fail`, the board driver's `--fail-one` mode): `carried_on console_line: (:serial) (:uart, 0, 115200);` is E2412 with the console note of links design decision 17 (UART0 is the console) and the list of links this board provides |

## Goldens and targets

- The trials carry `<stem>.ESP32-S3_raw.scout` only: on a hosted target the shared compiler accepts them and the
  emitter rejects the prims with E2220, so this directory is `INTEGRATE_PENDING` (skipped and not counted by the
  host run), as `device_actor_addition` is.
- `<stem>.esp32_s3.ascomp` is the ESP32-S3 compiler's own output for the program, written by
  `trials/targets/gen_board_ascomp.sh` after a board run matched the `.scout`.
- The goldens are hand-derived from the source: the output does not depend on a peer (the UART transmits whether
  or not anything listens; the USB frame fits the FIFO).
- The `.esp32_s3.ascomp` goldens depend on the suite's whole compile set (atom indices are assigned across the
  `silica.config`): adding the USB-Serial-JTAG modules on 2026-11-09 renumbered the atoms in
  `device_uart1_carrier_tx`'s assembly, and its golden was regenerated with the new one by `gen_board_ascomp.sh`
  (delete the stale golden first; the script never overwrites one).
- These trials are in their own suite rather than `device_actor_addition` because adding the carrier chain there
  made the compiler's per-unit restarts lose a board-pack description: a `use`d description module whose `.iface`
  is fresh is parse-skipped, and the `.iface` carries no register rows, so a driver compiled in a later process
  reported E2213 (`register :out_w1tc is not in the description of (:esp32s3_gpio)`; which driver fails depends
  on the compile order). Recorded in the stage log of `transport_esp32s3_wifi_plan.md` (stage 1).

Board run: `make integrate TRIAL_TARGET=ESP32-S3_raw TRIAL_SUITES=transport_board_addition` from `trials/`.
