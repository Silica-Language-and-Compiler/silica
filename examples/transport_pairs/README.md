# Transport pairs: a board program and its Mac peer

Each directory here is a small, readable example of Silica's transport between the ESP32-S3 board (the BYU-I eBadge
v4.0) and an Apple Silicon Mac. Each one is also a check: its `run.sh` runs the pair on the real board and compares
what both ends print with the expected output.

| Pair | Shows | Mac peers | Board program |
| --- | --- | --- | --- |
| [`usb_basic_exchange`](usb_basic_exchange/) | one reading to the Mac, one LED command back, decoded on the board (stage S-A) | Silica, Erlang | `basic_exchange_board/` |
| [`usb_accel_led_erlang_and_silica`](usb_accel_led_erlang_and_silica/) | a sequence of (synthetic) accelerometer readings; each answered by an LED command that the board carries out on the RGB LED; an end-of-stream frame; byte-identical replies from both peers (stage S-D) | Silica, Erlang | `accel_led_board/` |
| [`usb_silica_pair`](usb_silica_pair/) | Silica on both ends; requests from both sides, several in flight, matched by id; credit flow control with an outbox | Silica | `silica_pair_board/` |

Not included:

- The UART1 pair (`compiler/src/emitter/ESP32-S3_raw/board/apps/silica_32_transport_uart1_etf` with
  `programmer_tools/transport_uart1_demo`). It needs a 3.3 V USB-serial adapter wired to the UART1 header (GPIO35/36),
  so it cannot run with the board's two USB jacks alone.
- The hosted BEAM demo (`programmer_tools/transport_beam_demo`). It runs over TCP on the Mac and needs no board.

## What every pair has in common

- **The link.** The carrier is the board's native USB-C jack, through the USB-Serial-JTAG controller: the
  `(:usb_serial_jtag)` carrier, declared as `carried_on usb: (:serial) (:usb_serial_jtag);`. On the Mac it is a
  `/dev/cu.usbmodem*` port with USB id 303A:1001, opened by the hosted `(:serial)` carrier
  (`carried_on board: (:serial) (:serial_port, path, 115200);`).
- **The bytes.** Messages are ETF terms (`encode((:etf), ...)` / `decode`), each behind a 4-byte length prefix
  (`wireframe`). That is what Erlang's `gen_tcp` `{packet, 4}` speaks. The Erlang peers are reached through
  `programmer_tools/transport_uart1_demo/serial_to_tcp_bridge.py`, which copies the serial bytes to a local TCP socket
  and back.
- **The readings are synthetic.** The board's MMA8452Q accelerometer is on I2C0, and the I2C0 worker is not built.
- **The layout.** The board program is a directory holding its `.silica` source, `expected.scout` (the board's console
  output, then its exit status) and `extra_sources.txt` (the library modules it is compiled with, relative to
  `compiler/`). `compiler/src/emitter/ESP32-S3_raw/board/tools/run_app.sh` builds and runs such a directory from any
  path. The Mac peers are in `mac_peer/`.
- **The run order.** `run.sh` loads the board program into RAM (nothing is written to flash) and waits for
  `running ... on the board`, then 8 s more. The load resets the chip, and the USB node re-enumerates, possibly under a
  new name, so the port is found by USB id. Only then does it start the peer.
- **The native port.** It is never flushed at open: the board's first frame is already in the driver. DTR and RTS are
  never set low: that resets the chip.

## Running

Connect both of the board's jacks to the Mac:

- the USB-UART jack: UART0, used for the RAM load and the console;
- the native USB-C jack: the carrier.

Then run:

```sh
examples/transport_pairs/run_all.sh                       # every pair, one at a time; PASS/FAIL per pair
examples/transport_pairs/usb_accel_led_erlang_and_silica/run.sh --erlang     # one pair, one peer
```

The defaults are the development Mac's. Override them with environment variables:

- `BOARD_PORT`: `/dev/cu.usbserial-8310`;
- `BOARD_PYTHON`: the ESP-IDF 6.1 Python, with esptool and pyserial;
- `BOARD_SILICA_COMPILER`, `HOST_SILICA_COMPILER`: the tree's ESP32-S3 and Apple Silicon compilers.

The shared steps are in `lib/pair_lib.sh`. These runs are not part of `make integrate`, because they need the board
(and `erl`, for the Erlang peers).
