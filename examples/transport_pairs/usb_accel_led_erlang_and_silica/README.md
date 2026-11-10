# usb_accel_led_erlang_and_silica

The ESP32-S3 board sends accelerometer readings to the Mac over the board's native USB-C jack. The Mac answers each
reading with an LED command, and the board switches that LED on or off. The Mac end is written twice, once in Silica
and once in Erlang, and the two send the same bytes. This is stage S-D of
`compiler/design_documents/transport_esp32s3_wifi_plan.md` §8.

**The readings are synthetic.** The board's MMA8452Q accelerometer is on I2C0, and the I2C0 worker is not built
(`esp32s3_board_peripherals_plan.md` item 2). The board program sends four readings from a fixed table:

| reading | x | y | z | at_ms | LED command from the Mac |
| --- | --- | --- | --- | --- | --- |
| 1 | 1 | -2 | 512 | 1000 | red on |
| 2 | 3 | 1 | 100 | 1250 | red off |
| 3 | -5 | 4 | 300 | 1500 | red on |
| 4 | 0 | 0 | -480 | 1750 | red off |

The Mac's rule: the red LED is on when `z > 256`, off otherwise.

## What is here

| Path | What |
| --- | --- |
| `accel_led_board/device_usb_accel_led.silica` | the board program: `carried_on usb: (:serial) (:usb_serial_jtag);`, the readings table, the GPIO device worker for the LEDs |
| `accel_led_board/expected.scout` | the board's console output, the exit status last |
| `mac_peer/dangerous_accel_led_peer.silica` | the Silica Mac peer: the hosted `(:serial)` carrier on the board's USB port |
| `mac_peer/accel_led_peer.erl` | the Erlang Mac peer: `gen_tcp` with `{packet, 4}`, behind `programmer_tools/transport_uart1_demo/serial_to_tcp_bridge.py` |
| `expected/silica_peer.out`, `expected/erlang_peer.out` | each peer's output (the port name is normalised before comparing) |
| `expected/to_mac.hex`, `expected/to_board.hex` | the bytes each way, as the bridge sees them |
| `fake_board_readings.py` | plays the board on a pty, for checking the peers without hardware |
| `run.sh` | builds and runs everything, compares the output, prints PASS or FAIL |

## How it works

- **Framing.** Every message is an ETF term behind a 4-byte length prefix. The `(:serial)` kind is mtu 0 and
  `:stream`, so `wireframe@frame` adds the prefix and `wireframe@unframe` reassembles frames from the received bytes.
- **One frame in flight.** The board sends reading 1 and waits for its reply before it sends reading 2, and so on.
  Each frame is 46 to 52 bytes. The USB-Serial-JTAG controller's IN FIFO holds 64 bytes, so it never holds more than
  one frame, and the carrier's transmit credit never runs out. The first frame waits in the FIFO until the Mac opens
  the port.
- **The LED.** The command `(:led, { which, on })` names an LED: `:red` is GPIO2, `:green` GPIO4, `:blue` GPIO5 (the
  RGB LED's channels), and `:single` is GPIO6 (LED1). All four are active high. The board casts the GPIO device worker
  three messages:
  - a `:write` of the LED's pin;
  - a `:hold` of about one second, so each state is easy to see;
  - a `:notify` to a printer actor, which prints `rgb red on (gpio2)` once the pin has been written and held.

  The next reading goes out only after that line is printed.
- **End of stream.** After the fourth LED change, the board sends `(:done, 4)`, which is 15 bytes framed. Both peers
  stop when they receive it. If a board program sends no `(:done, n)`, each peer stops when no reading has arrived for
  3 s after its last reply.
- **Byte-identical replies.** The Erlang peer encodes with `term_to_binary(T, [deterministic])`. This writes the map
  keys in term order (`on`, `which`), which is the order Silica's `encode` writes a record's fields. Without the
  option, OTP 26 and later order a small map's atom keys by the atom table, and the bytes would differ.

## Running it

The board needs both jacks connected to the Mac:

- the USB-UART jack: UART0, used for the RAM load and the console (`BOARD_PORT`, default `/dev/cu.usbserial-8310`);
- the native USB-C jack: the carrier, found by USB id 303A:1001.

```sh
examples/transport_pairs/usb_accel_led_erlang_and_silica/run.sh            # both peers, one board run each
examples/transport_pairs/usb_accel_led_erlang_and_silica/run.sh --silica   # or --erlang
examples/transport_pairs/usb_accel_led_erlang_and_silica/run.sh --fake     # no board: the peers' replies on a pty
```

`run.sh` does the following:

1. Builds the Silica peer.
2. Starts the board program with `board/tools/run_app.sh` (a RAM load; nothing is written to flash).
3. Waits for `running ... on the board`, then 8 s more. The load resets the chip, and the USB node re-enumerates.
4. Starts the peer.
5. Checks the run against the expected files.

The environment variables and the rules for the native port (never flush it at open, never set DTR/RTS low) are in
`../lib/pair_lib.sh`.

## What to expect

The board console. With either peer, `run_app.sh` reports `MATCH` against `accel_led_board/expected.scout`:

```
link up usb_serial_jtag
reading 1 x=1 y=-2 z=512 at_ms=1000
tx credit 8
sent 52 bytes
led red on
rgb red on (gpio2)
reading 2 x=3 y=1 z=100 at_ms=1250
sent 46 bytes
led red off
rgb red off (gpio2)
...
done 4 readings
sent 15 bytes
link down :closed
0
```

The order of the first lines is fixed. The board handles `:link_up`, which prints and sends reading 1, before the
`:tx_credit 8` that the carrier queued behind it.

On the board, the RGB LED is red for about a second, off for about a second, red again, then off.

The Silica peer prints `frame 48 bytes`, `accel x=1 y=-2 z=512 at_ms=1000`, `reply led red on`, `sent 39 bytes`, and so
on for each reading, then `board done after 4 readings` and `link down :closed after 4 readings`. The Erlang peer
prints the same facts as `peer: ...` lines.

The replies are 39 bytes for on and 40 bytes for off, from either peer:

- on: `0000002383680277036c6564740000000277026f6e770474727565770577686963687703726564`
- off: `0000002483680277036c6564740000000277026f6e770566616c7365770577686963687703726564`

`run.sh` prints `=== silica peer: PASS` and `=== erlang peer: PASS`, and exits 0.
