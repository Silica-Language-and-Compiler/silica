# transport_beam_demo

The hosted BEAM demo of `compiler/design_documents/transport_serialization_design.md` §13: a Silica program
connects to an Erlang node's `gen_tcp` listener, sends one accelerometer reading as an ETF frame behind the
4-byte length prefix (`{packet, 4}`), and prints the LED command the Erlang side answers with.

- `dangerous_telemetry.silica`: the program. A `(:tcp)` carrier (`dangerous_tcp_carrier`) is installed with
  `spawn_dangerous` and opened against `127.0.0.1:<port>`; on `:link_up` the owner grants receive credit and
  sends `(:accel, { x: 1, y: -2, z: 512, at_ms: 1000 })` through `encode((:etf), ...)` and
  `wireframe@frame(frame, Carrier@mtu((:tcp)), Carrier@boundaries((:tcp)))`, the carrier tag spelled as the
  design spells it; the reply segment is reassembled with `wireframe@unframe` and decoded into
  `(:led, { which: :single | :red | :green | :blue, on: boolean })`. The program is the connecting end. The
  same carrier opened with `"listen:<port>"` is a listener: it announces every peer it accepts with
  `(:accepted, conn, info)` and the owner opens each connection carrier `conn` with `(:open, owner, "")`
  (design §6.2; the trial `trials/transport_addition/app_transport_tcp_listener` shows it serving two peers).
- `silica_peer.erl`: the Erlang end. Listens, takes the term, prints it, answers
  `{led, #{which => red, on => true}}`.
- `run_demo.sh [port]`: builds the program (the compiler at `SILICA_COMPILER`, by default the tree's Apple
  Silicon build), compiles the socket wrappers into `libsilica_sockets.a`, compiles the peer, starts it,
  runs the program and prints both ends. Not part of `make integrate`: it needs `erl` (OTP 26 or later).

Expected output:

```
--- erlang peer:
peer: listening on 4040
peer: got {accel,#{y => -2,z => 512,x => 1,at_ms => 1000}} (48 bytes)
peer: x=1 y=-2 z=512 at_ms=1000
--- silica program (exit 0):
connected
led red on
done
```

The 48 bytes are the ones §13.4 lists; Erlang prints the map in its own key order.
