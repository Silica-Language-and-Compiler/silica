# transport_usb_serial_jtag_demo

The Mac end of stage S-A / S-B of `compiler/design_documents/transport_esp32s3_wifi_plan.md` §8: the ESP32-S3
board and the Mac exchange ETF frames over the board's native USB-C jack through the `(:usb_serial_jtag)`
carrier (`compiler/src/emitter/ESP32-S3_raw/board/apps/device_lib/device_esp32s3_usb_serial_jtag.silica`,
`usb_serial_jtag_carrier`; the board program `board/apps/silica_33_transport_usb_serial_jtag_etf`). The board
sends one accelerometer reading, the Mac answers one LED command, and each side prints what it decoded. No
wiring: the USB-Serial-JTAG controller enumerates on the Mac as `/dev/cu.usbmodem*` with USB id 303A:1001
(the node's name changes when the chip re-enumerates, so the tools find it by id).

- `dangerous_usb_serial_jtag_peer.silica`: the Silica peer. The hosted `(:serial)` carrier
  (`dangerous_serial_carrier`; the controller ignores the baud) is opened on the port; on `:link_up` the owner
  grants receive credit, reassembles the `:rx` bytes with `wireframe@unframe`, decodes the frame with
  `decode((:etf), ...)` into `(:accel, { x: int16, y: int16, z: int16, at_ms: uint64 })`, answers
  `(:led, { which: :red, on: true })` as one framed `:tx` (the term the Erlang peer answers with), and closes
  the port a second later. Prints `serial open <port@baud>`, `frame 48 bytes`, `accel x=1 y=-2 z=512
  at_ms=1000`, `sent 39 bytes`, `link down :closed`; exit 0 (2: the term was rejected, 3: the framing was
  rejected, 1: the port failed; killed after `--timeout` when nothing arrives).
- `find_usb_serial_jtag_port.py`: prints the port's device node, resolved by USB id (pyserial).
- `run_peer.sh`: builds and runs the Silica peer (`--port` optional), or the Erlang peer of
  `../transport_beam_demo` (`silica_peer.erl`, `gen_tcp` with `{packet, 4}`) behind
  `../transport_uart1_demo/serial_to_tcp_bridge.py --hex` (`--erlang [tcp_port]`), which prints the bytes it
  moves in each direction. `--build-only` / `--no-build` split the compile from the run so the peer starts
  quickly once the board is running. Not part of `make integrate`: it needs the board.

## Order of operations

The RAM load (`run_app.sh`) resets the chip, and the USB-Serial-JTAG device re-enumerates: a port opened before
that goes stale. Start the board program first, wait for `run_app: running ... on the board`, then start the
peer; the board's frame (52 bytes, under the controller's 64-byte IN FIFO) waits in the FIFO until the port is
opened. The port must never be opened with DTR and RTS set low (that resets the chip, item F of the
peripherals plan); the Silica carrier's termios open and pyserial's default open leave both high. The macOS
driver has the pending frame as soon as the port opens, so a tool that flushes its input at open loses it:
the bridge opens without pyserial's `tcflush` (see its docstring).

```sh
# terminal 1: the board program (RAM load; see board/README.md for the environment variables)
BOARD_PORT=/dev/cu.usbserial-CONSOLE compiler/src/emitter/ESP32-S3_raw/board/tools/run_app.sh --timeout 120 silica_33_transport_usb_serial_jtag_etf
# terminal 2, once terminal 1 prints "running ... on the board": the peer
SILICA_COMPILER=binaries/silica-compiler programmer_tools/transport_usb_serial_jtag_demo/run_peer.sh
#   or the Erlang peer behind the bridge:
SILICA_COMPILER=binaries/silica-compiler programmer_tools/transport_usb_serial_jtag_demo/run_peer.sh --erlang
```

Seen on the board 2026-11-09 (BYU-I eBadge v4.0, console on `/dev/cu.usbserial-8310`, USB-C jack on
`/dev/cu.usbmodem83201`), both peers, the board console matching the app's `expected.scout` each time:

```
board:  link up usb_serial_jtag / tx credit 8 / sent 52 bytes / led red on / link down :closed / 0
silica: serial open /dev/cu.usbmodem83201@115200 / frame 48 bytes / accel x=1 y=-2 z=512 at_ms=1000 / sent 39 bytes / link down :closed
bridge: serial -> tcp 52 bytes: 000000308368027705616363656c7400000004770561745f6d7362000003e8770178610177017962fffffffe77017a6200000200
        tcp -> serial 39 bytes: 0000002383680277036c6564740000000277026f6e770474727565770577686963687703726564
erlang: peer: got {accel,#{y => -2,z => 512,x => 1,at_ms => 1000}} (48 bytes) / peer: x=1 y=-2 z=512 at_ms=1000
```

The 52 bytes are the design's (`transport_serialization_design.md` §13.4: the 4-byte length prefix and the
48-byte term); the 39 are Erlang's `term_to_binary({led, #{which => red, on => true}})` behind its prefix, and
the Silica peer's `encode` of the same term is the same 39 bytes.
