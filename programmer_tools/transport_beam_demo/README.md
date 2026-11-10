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
  `{led, #{which => red, on => true}}`. (The board pairs over USB-C have their own Erlang peers, under
  `examples/transport_pairs/`.)
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

The 48 bytes are the ones §13.4 lists; Erlang prints the map in its own key order. A last line `link down: :closed`
sometimes follows `done`: the program's own `:close` races its `cast_exit(0)` (the exit status is 0 either way).

**Security.** The `(:tcp)` carrier is plain TCP. It provides no authentication, no encryption and no peer identity: anyone who can reach a listening port can connect and send frames, and anyone on the path can read and change the bytes. Secure interchange is being built on top of this carrier in Project BEES (https://github.com/Silica-Language-and-Compiler/project-bees): SEMP/TRUST over mutual TLS 1.3 (ALPN `trust/1`, a certificate whitelist; the TLS engine is selected: OpenSSL on macOS and Linux, Mbed TLS on the NUCLEO-L476RG and the ESP32-S3) and an Erlang-compatible BEAM mode with cookie authentication. As of 2026-11-10 BEES's TLS and TRUST code is not built yet and its cookie handshake is in progress; both build on this carrier's non-loopback support. Today BEES's BEAM-mode wire runs between BEES nodes on loopback only, without the cookie digest (test-only, unauthenticated).
