# Transport pairs: a board program and its Mac peer

Each directory here is a small, readable example of Silica's transport between the ESP32-S3 board (the BYU-I eBadge
v4.0) and an Apple Silicon Mac. Each one is also a check: its `run.sh` runs the pair on the real board and compares
what both ends print with the expected output.

| Pair | Shows | Mac peers | Board program |
| --- | --- | --- | --- |
| [`usb_basic_exchange`](usb_basic_exchange/) | one reading to the Mac, one LED command back, decoded on the board (stage S-A) | Silica, Erlang | `basic_exchange_board/` |
| [`usb_accel_led_erlang_and_silica`](usb_accel_led_erlang_and_silica/) | a sequence of (synthetic) accelerometer readings; each answered by an LED command that the board carries out on the RGB LED; an end-of-stream frame; byte-identical replies from both peers (stage S-D) | Silica, Erlang | `accel_led_board/` |
| [`usb_silica_pair`](usb_silica_pair/) | Silica on both ends; requests from both sides, several in flight, matched by id; credit flow control with an outbox | Silica | `silica_pair_board/` |

Two pairs need no board:

| Pair | Shows | Ends |
| --- | --- | --- |
| [`ethernet_remote`](ethernet_remote/) | Silica on both ends of TCP across the Internet: this Mac and a Linux x86-64 host (`manager@aalang.org`). Each end listens and dials, so there are two connections, with requests from both sides interleaved and matched by id. The links are `ssh -L` and `ssh -R` forwards to loopback-only listeners. The carrier is declared `carried_on wire: (:tcp) (:loopback);`. The Linux end is built on the remote with the hosted Linux compiler. Run with `ethernet_remote/run_mac_linux.sh`, outside `run_all.sh` (it needs the network and the remote). `check_remote.sh` is the earlier readiness check (stage E0), against an Erlang peer | Mac (Silica, the `(:tcp)` carrier), Linux x86-64 (Silica, the same source) |
| [`ethernet_direct`](ethernet_direct/) | Silica on both ends of **one direct TCP connection** across the Internet, no tunnel: the Mac (behind NAT) dials the Linux end's listener at `138.197.209.113:4550` (`"listen:any:4550"`, bound to every interface; the remote firewall admits that port from the Mac's address only), and requests flow both ways over that connection, matched by id (odd ids from the Mac, even from Linux). The carrier is declared `(:interface, "en0")` on the Mac and `(:interface, "eth0")` on Linux, a declaration only: hosted interface binding is not enforced yet (stage E2), the address strings decide. The Linux end is built on the remote and runs under `timeout` only during a run. Run with `ethernet_direct/run_direct.sh` (`--local` runs both ends on the Mac), outside `run_all.sh` | Mac (Silica, the `(:tcp)` carrier), Linux x86-64 (Silica, the same source) |
| [`ethernet_direct_mtls`](ethernet_direct_mtls/) | `ethernet_direct` under **mutual TLS 1.3**: the same program over a TLS carrier of the example's own (`dangerous_tls_carrier`, wrappers over the host's OpenSSL 3). Both ends present a certificate, made once from the node's existing `~/.ssh/id_ed25519`, and each accepts only the peers whose certificates were put in its `~/.silica_mtls/peers/` by hand; there is no certificate authority. An example, not the language's TLS (that is Project BEES's TRUST). `./ethernet_direct_mtls/run_mtls.sh` | Mac (Silica), Linux x86-64 (Silica), OpenSSL 3 on both |
| [`ethernet_mac_erlang_remote_silica`](ethernet_mac_erlang_remote_silica/) | `ethernet_direct` with an **Erlang** peer on the Mac: it dials the Silica Linux end (the program `ethernet_direct` built on the remote, reused) at `138.197.209.113:4550`, one connection, requests both ways, matched by id; the Erlang terms are byte-identical to Silica's (`term_to_binary(T, [deterministic])`, and every Silica frame is checked against it). Run with `ethernet_mac_erlang_remote_silica/run.sh` (`--local` runs both ends on the Mac), outside `run_all.sh` | Mac (Erlang, `gen_tcp` `{packet, 4}`), Linux x86-64 (Silica) |
| [`ethernet_mac_silica_remote_erlang`](ethernet_mac_silica_remote_erlang/) | `ethernet_direct` with an **Erlang** peer on the remote: the Silica Mac end dials an OTP 27 `gen_tcp` listener on `0.0.0.0:4550` (compiled there with `erlc`, run under `timeout` only during a run), one connection, requests both ways, matched by id, byte-identical terms as above. Run with `ethernet_mac_silica_remote_erlang/run.sh` (`--local` runs both ends on the Mac), outside `run_all.sh` | Mac (Silica, the `(:tcp)` carrier), Linux x86-64 (Erlang, OTP 27) |

**Security.** The `(:tcp)` carrier is plain TCP. It provides no authentication, no encryption and no peer identity: anyone who can reach a listening port can connect and send frames, and anyone on the path can read and change the bytes. Secure interchange is being built on top of this carrier in Project BEES (https://github.com/Silica-Language-and-Compiler/project-bees): SEMP/TRUST over mutual TLS 1.3 (ALPN `trust/1`, a certificate whitelist; the TLS engine is selected: OpenSSL on macOS and Linux, Mbed TLS on the NUCLEO-L476RG and the ESP32-S3) and an Erlang-compatible BEAM mode with cookie authentication. As of 2026-11-10 BEES's TLS and TRUST code is not built yet and its cookie handshake is in progress; both build on this carrier's non-loopback support. Today BEES's BEAM-mode wire runs between BEES nodes on loopback only, without the cookie digest (test-only, unauthenticated).

Not included:

- The UART1 pair (`compiler/src/emitter/ESP32-S3_raw/board/apps/silica_32_transport_uart1_etf` with
  `programmer_tools/transport_uart1_demo`). It needs a 3.3 V USB-serial adapter wired to the UART1 header (GPIO35/36),
  so it cannot run with the board's two USB jacks alone.
- The hosted BEAM demo (`programmer_tools/transport_beam_demo`). It runs over TCP on the Mac and needs no board.
  (`ethernet_remote` and `ethernet_direct`, also boardless, are listed above because they are Silica pairs.)

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
