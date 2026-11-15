# usb_silica_pair

Silica runs on both ends of the ESP32-S3's native USB-C jack, and requests are made **from both sides** at once:

- the board program `silica_pair_board/device_usb_silica_pair.silica` uses the `(:usb_serial_jtag)` carrier;
- the Mac peer `mac_peer/dangerous_usb_silica_pair_peer.silica` uses the hosted `(:serial)` carrier.

Each end declares its link with `carried_on`. The two ends exchange ETF terms over one stream framed by `wireframe`, with
a 4-byte length prefix on every frame:

```
(:request, id: uint32, body)      ids: the board's are odd, the Mac's are even
(:reply,   id: uint32, body)      the answer to the request with that id

board -> Mac   (:request, 1, (:accel, { x: 1, y: -2, z: 512, at_ms: 250 }))   Mac -> board  (:reply, 1, (:led, { which: :red, on: true }))
board -> Mac   (:request, 3, (:accel, { x: 3, y: 1,  z: 100, at_ms: 500 }))   Mac -> board  (:reply, 3, (:led, { which: :red, on: false }))
Mac -> board   (:request, 2, :status)                                         board -> Mac  (:reply, 2, (:status, { uptime_ms, requests_seen: 1 }))
Mac -> board   (:request, 4, :status)                                         board -> Mac  (:reply, 4, (:status, { uptime_ms, requests_seen: 2 }))
```

- **LED rule.** The Mac uses the rule of `../usb_accel_led_erlang_and_silica`: the red LED is on when z > 256. The
  board only prints the replies; it drives no LED.
- **Readings.** They are synthetic.
- **The status body.** It is the atom `:status`, not a one-atom tuple `(:status)`, because a one-atom tuple is not a
  run-time value in Silica.

## How each end works

- **Several requests in flight.** The Mac sends requests 2 and 4 together as soon as the port opens. The board sends
  request 1 at `:link_up`, and request 3 when the first bytes from the Mac arrive. Each end records its outstanding ids
  in a bit mask and matches every reply to its request by id.
- **Any order, any segmentation.** A single `:rx` can carry part of a frame or several frames. `wireframe@unframe` is
  called again with `""` until it answers `:more`. Each frame is decoded into the sum of the two shapes the end can
  receive (a request or a reply), and dispatched.
- **Credit flow control.** A frame goes out only while the end holds a transmit credit. Without one, the frame is added
  to an outbox string, and the whole outbox goes out as one `:tx` at the next credit (frames concatenate on a `:stream`
  carrier).
- **The 64-byte IN FIFO.** Nothing reads the board's IN FIFO until the Mac opens the port, so at `:link_up` the board
  sends only request 1, a 62-byte frame. (`at_ms` is 250 so that the integer fits in ETF's 2-byte SMALL_INTEGER_EXT.)
- **Completion.** An end is done when its replies are all matched, the other side's two requests are answered, and
  every `:tx` is confirmed. It then waits a little, closes the carrier and exits 0.
- **Failure paths.** Each end has a timeout (the board 45 s, the Mac 30 s), which prints `timeout: ...` and exits 5.
  The other failures are:
  - `rejected <why>`: exit 2;
  - `framing rejected <why>`: exit 3;
  - `link down :fault`: exit 1.

The board prints only a few lines as events happen and a summary in id order at the end, so its `expected.scout` is
fixed. The Mac peer prints each event as it happens, so its order and the uptimes vary. `run.sh` therefore checks that
each line of `expected/peer_lines.txt` appears exactly once in the peer's output, in any order.

## Running it

```sh
examples/transport_pairs/usb_silica_pair/run.sh
```

The board needs both jacks connected, as in the other pairs. The environment variables are in `../lib/pair_lib.sh`.

## What to expect

The board console (`MATCH` against `silica_pair_board/expected.scout`):

```
link up usb_serial_jtag
request 1 accel x=1 y=-2 z=512 at_ms=250 (62 bytes)
tx credit 8
reply 1 led on
reply 3 led off
served 2 status requests
link down :closed
0
```

The Mac peer, from the first board run on 2026-11-10 (the uptimes vary):

```
serial open /dev/cu.usbmodem83201@115200
request 2 status
request 4 status
board request 1 accel x=1 y=-2 z=512 at_ms=250 -> reply led red on
board request 3 accel x=3 y=1 z=100 at_ms=500 -> reply led red off
board reply 2 status uptime_ms=8500 requests_seen=1
board reply 4 status uptime_ms=8503 requests_seen=2
pair complete: 2 status replies matched, 2 board requests answered
link down :closed
```

## Two compiler defects this pair works around

1. **Flattened nested tuples in `encode`.** A nested tagged-tuple literal written straight into `encode`'s argument is
   encoded flattened. For example, `encode((:etf), (:request, id, (:accel, {...})))` gives the 4-tuple
   `{request, 1, accel, #{...}}`. Both ends therefore bind the term to an annotated name before encoding it.
2. **A conversion call as an argument clobbers an earlier argument.** In `take_request(st, to_int64(rid), body)` the
   Apple Silicon compiler placed `st` in X0 and then evaluated `to_int64(rid)` in X0, so the callee received the id as
   its state record. On the Mac this was a fault at address 0x9 in `serve_accel`. On the board, with the same source,
   the run failed in a way that fits the same defect: the carrier ended with `(:explicit, :actor_not_found)`, and the run
   timed out. With the workaround it matched. The Xtensa assembly was not inspected. Both ends now bind `id: int64 <- to_int64(rid)` before the call.

Both defects were seen on 2026-11-10, the first time this pair ran, and neither is fixed in the compiler.
