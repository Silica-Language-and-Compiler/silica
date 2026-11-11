# transport_uart1_demo

The Mac end of stage 1 of `compiler/design_documents/transport_esp32s3_wifi_plan.md`: the ESP32-S3 board
sends one ETF frame over its UART1 header through the `(:uart1)` carrier
(`compiler/src/emitter/ESP32-S3_raw/board/apps/device_lib/device_esp32s3_uart1.silica`, the board program
`board/apps/silica_32_transport_uart1_etf`), and a peer on the Mac decodes it. The board only sends
(`transport_links_design.md` decision 15), so the peer only receives.

- `dangerous_uart1_peer.silica`: the Silica peer. The hosted `(:serial)` carrier (`dangerous_serial_carrier`,
  115200 8N1) is opened on the adapter's port; on `:link_up` the owner grants receive credit, reassembles the
  `:rx` bytes with `wireframe@unframe` and decodes the frame with `decode((:etf), ...)` into
  `(:accel, { x: int16, y: int16, z: int16, at_ms: uint64 })`. Prints `serial open <port@baud>`, `frame 48
  bytes`, `accel x=1 y=-2 z=512 at_ms=1000`, closes the carrier and exits 0 on its `link down :closed` (2: the
  term was rejected, 3: the framing was rejected, 1: the port failed; killed after `--timeout` when nothing
  arrives).
- `serial_to_tcp_bridge.py`: copies the port's bytes into a TCP connection and back, so the Erlang peer of
  `../transport_beam_demo` (`silica_peer.erl`, `gen_tcp` with `{packet, 4}`) reads the board's frame unchanged
  (`transport_serialization_design.md` §6.4: "a host bridges it to its network"). Its LED reply goes back to
  the port; the stage-1 board program does not read it. `--hex` prints every chunk moved with its direction.
  It is also the bridge of the USB-C pairs in `examples/transport_pairs/` (formerly `../transport_usb_serial_jtag_demo`; stage S-A, 2026-11-09), which is why it opens
  the port without pyserial's flush-at-open: a frame the board sent before the port was opened is already in
  the driver's buffer and `tcflush` threw it away.
- `fake_board.py`: plays the board on a pseudo-terminal with the 52 bytes of design §13.4, to check the Mac
  side without hardware. It is not evidence about the board.
- `run_peer.sh`: builds and runs the Silica peer (`--port <device>`), or the Erlang peer behind the bridge
  (`--erlang [tcp_port]`), or the Silica peer against `fake_board.py` (`--fake-board`). Not part of
  `make integrate`: it needs a serial device (or a pty) and, for `--erlang`, `erl` and pyserial.

## Wiring

The board's UART1 header carries TX on GPIO35 and RX on GPIO36 (`PORT_TEST_BOARD_byu_idaho_v4.0_feb26.md`,
J4 jumpers in place for those two pins). A 3.3 V USB-serial adapter goes adapter RX to GPIO35 (board TX),
adapter GND to board GND; adapter TX to GPIO36 is only needed once a board program receives. The adapter
appears on the Mac as a second `/dev/cu.usbserial-*` beside the console's; the console port
(`BOARD_PORT`, UART0) is never the carrier's port. No jumper from TX to RX is assumed anywhere.

## Running

```sh
# terminal 1: the peer, waiting for the frame
SILICA_COMPILER=binaries/silica-compiler programmer_tools/transport_uart1_demo/run_peer.sh --port /dev/cu.usbserial-ADAPTER
# terminal 2: the board program (RAM load; see board/README.md for the environment variables)
BOARD_PORT=/dev/cu.usbserial-CONSOLE compiler/src/emitter/ESP32-S3_raw/board/tools/run_app.sh silica_32_transport_uart1_etf
```

Expected, peer:

```
serial open /dev/cu.usbserial-ADAPTER@115200
frame 48 bytes
accel x=1 y=-2 z=512 at_ms=1000
link down :closed
```

board console (`run_app.sh` compares it with the app's `expected.scout`):

```
link up uart1@115200
tx credit 8
sent 52 bytes
link down :closed
0
```

With `--erlang`, the Erlang peer prints `peer: got {accel,#{...}} (48 bytes)` and `peer: x=1 y=-2 z=512
at_ms=1000` as in `transport_beam_demo`. `run_peer.sh --fake-board` runs the Silica peer against
`fake_board.py` and must print the three peer lines above with the pty's path.
