# usb_basic_exchange

The smallest exchange over the ESP32-S3's native USB-C jack. The board sends one accelerometer reading as an ETF frame,
the Mac answers with one LED command, and the board decodes it and prints `led red on`. It was the first transport
exchange with the board (stage S-A of `compiler/design_documents/transport_esp32s3_wifi_plan.md` §8). The board program
was `board/apps/silica_33_transport_usb_serial_jtag_etf`. The reading is the one in `transport_serialization_design.md`
§13.4: `(:accel, { x: 1, y: -2, z: 512, at_ms: 1000 })`, 48 bytes of ETF, 52 bytes framed. It is synthetic, since
no sensor is read.

## What is here

| Path | What |
| --- | --- |
| `basic_exchange_board/device_usb_serial_jtag_etf_demo.silica` | the board program (`carried_on usb: (:serial) (:usb_serial_jtag);`) |
| `basic_exchange_board/expected.scout` | the board's console output |
| `mac_peer/dangerous_basic_peer.silica` | the Silica Mac peer (the hosted `(:serial)` carrier): takes the reading, answers `(:led, { which: :red, on: true })`, closes a second later |
| `mac_peer/basic_peer.erl` | the Erlang Mac peer behind `programmer_tools/transport_uart1_demo/serial_to_tcp_bridge.py` |
| `expected/` | each peer's output, and the bytes each way |
| `run.sh` | builds, runs and checks; `--silica`, `--erlang` or `--both` (the default) |

The board's frame fits the controller's 64-byte IN FIFO, so the frame waits there until the Mac opens the port, and the
board can send first.

## Running it

```sh
examples/transport_pairs/usb_basic_exchange/run.sh
```

The board needs both jacks connected, as described in `../usb_accel_led_erlang_and_silica/README.md`. The environment
variables are in `../lib/pair_lib.sh`.

## What to expect

The board console is the same with either peer:

```
link up usb_serial_jtag
tx credit 8
sent 52 bytes
led red on
link down :closed
0
```

The Silica peer prints `frame 48 bytes`, `accel x=1 y=-2 z=512 at_ms=1000`, `sent 39 bytes` and `link down :closed`.
The Erlang peer prints `peer: reading x=1 y=-2 z=512 at_ms=1000 (48 bytes)` and `peer: reply led red on`.

The reply is the same 39 bytes from both peers:

`0000002383680277036c6564740000000277026f6e770474727565770577686963687703726564`

`run.sh` prints PASS for each peer.
