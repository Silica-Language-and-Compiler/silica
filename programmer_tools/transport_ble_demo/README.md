# transport_ble_demo

The Bluetooth Low Energy demo of `compiler/design_documents/transport_ble_plan.md`: a Mac, the ESP32-S3 board
and a phone exchange ETF frames over the `(:ble_gatt)` carrier. The carrier on the Mac is
`compiler/stdlib/dangerous_ble_gatt_carrier.silica` (CoreBluetooth); on the board it is
`compiler/stdlib/dangerous_ble_gatt_board_carrier.silica` (NimBLE, in a program built as a guest of ESP-IDF).
Both speak one contract, so the owner actors of the two ends differ only in the carrier's declaration. No
wiring. Not part of `make integrate`: it needs the board and a radio.

Each script's header gives its full usage.

| Script | What it runs |
| --- | --- |
| `run_accel_led.sh` | The end-to-end demo by one command: the board, a peripheral, sends one accelerometer reading; the Mac, the central, decodes it and answers one LED command. |
| `run_peer.sh peripheral\|central` | The Mac end alone (`dangerous_ble_peer.silica`): sends one 48-byte frame in 20-byte segments and prints the reading of the frame its peer sends back. |
| `run_board_peer.sh [--central]` | The board end alone (`dangerous_ble_board_peer.silica`): the same exchange, a peripheral unless `--central`, with a busy actor on each core throughout. |
| `run_board_advertise.sh` | The board advertises the service and reports its memory every five seconds. |
| `find_service.sh` | The Mac scans for the service and counts the advertisements it hears. |

The service is the Nordic UART Service unless a UUID is given (4, 8 or 36 characters), so a phone's test
application (nRF Connect, LightBlue) is a peer with no Silica on it.

## What is needed

- Both Silica compilers: `SILICA_COMPILER` for the Mac, `BOARD_SILICA_COMPILER` for the ESP32-S3 (by default
  the local builds under `compiler/build`).
- Apple's clang. macOS asks once to let the terminal use Bluetooth.
- For the board: ESP-IDF 6.2, the board tools' environment and the board on `BOARD_PORT`
  (`compiler/src/emitter/ESP32-S3_raw/board/guest/README.md`).

## The end-to-end demo

```sh
BOARD_PORT=/dev/cu.usbserial-CONSOLE programmer_tools/transport_ble_demo/run_accel_led.sh
```

The script builds both programs, flashes and starts the board, starts the Mac's program when the Mac hears
the board advertising, and prints both consoles. It exits 0 when both programs ended with status 0. Seen
2026-11-14:

```
board: link up mtu:253 / tx credit 8 / sent 48 bytes / led red on / link down :closed / 0
mac:   link up mtu:253 / frame 48 bytes / accel x=1 y=-2 z=512 at_ms=1000 / sent 35 bytes / link down :closed
```

## The two ends, one at a time

Start the peripheral first; the central scans for it.

```sh
# Mac central, board peripheral
BOARD_PORT=/dev/cu.usbserial-CONSOLE programmer_tools/transport_ble_demo/run_board_peer.sh
SILICA_COMPILER=$PWD/compiler/build/apple_silicon_mac/silica-compiler programmer_tools/transport_ble_demo/run_peer.sh central

# Board central, Mac peripheral
SILICA_COMPILER=$PWD/compiler/build/apple_silicon_mac/silica-compiler programmer_tools/transport_ble_demo/run_peer.sh peripheral
BOARD_PORT=/dev/cu.usbserial-CONSOLE programmer_tools/transport_ble_demo/run_board_peer.sh --central
```

The board's console is printed when its program ends, not line by line.

Options of both `run_peer.sh` and `run_board_peer.sh`:

- `--links <n>`: n whole exchanges, each on a link of its own, the carrier opened again after each
  `:link_down`.
- `--cut <k>`: on link k (counted from 0) this end sends only its first segment and closes, the other end's
  test of a frame cut short.
- `--hold <seconds>`: the link is kept that long after the exchange, for taking one end away while it is up
  (the reason is then `:timeout`).
- `--timeout <seconds>`: bounds the wait for the peer.

`run_peer.sh --second <address>` holds a second session at the same time, by a carrier and an owner of its
own; its lines are marked `B:` and the first session's `A:`. The second opens two seconds after the first:
of two carriers opened at the same moment on the Mac, one stays closed (the plan's §6, stage 10, part 2).
`SILICA_BLE_TRACE=1` prints the Mac wrapper's CoreBluetooth events.

## With a phone as the central

1. Start a peripheral: `run_board_peer.sh`, or `run_peer.sh peripheral`.
2. In nRF Connect's scanner, connect to "Silica". With filters set the scanner may not list it.
3. Enable indications on the TX characteristic (6E400003). A board asks the phone to pair: accept. The
   program prints the three segments it sent and the phone shows them.
4. Write these three values, as byte arrays and in this order, to the RX characteristic (6E400002):

   ```
   000000008368027705616363656C740000000477
   000000010561745F6D7362000003E87701786101
   0000800277017962FFFFFFFE77017A6200000200
   ```

   The program prints `frame in 48 bytes`, `accel x=1 y=-2 z=512 at_ms=1000`, `link down :closed` and exits 0.
   A value written twice is rejected (`:bad_tag`): the segments are checked for order.

## Limits

- **Encryption: the peripheral decides.** A link to a board as peripheral is paired and encrypted (LE Secure
  Connections, no code). A Mac program as peripheral has an open link: macOS lets only an application with a
  window pair in that role. The pairing keeps a listener out and does not prove who the peer is.
- **No keys are kept.** Every link pairs afresh, which takes about a second, and a phone asks its user each
  time. Flashing the board erases where its keys would be.
- **One link on the board.** The first carrier a program opens holds the radio; an `:open` to another answers
  `(:link_down, :fault)`. A Mac program holds up to four sessions.
- **A Mac's stale table.** A Mac that connected to the board while it ran another program may answer from
  the table it kept, with no characteristics: switch its Bluetooth off and on.
- **Linux** is not built (the plan's stage 11).
