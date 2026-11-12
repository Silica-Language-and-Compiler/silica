# ethernet_mac_silica_remote_erlang

The **Silica** Mac end of [`../ethernet_direct`](../ethernet_direct/) on this Apple Silicon Mac and an **Erlang**
peer on the Linux x86-64 remote (`manager@aalang.org`, 138.197.209.113 by default, OTP 27), over **one direct TCP
connection** across the Internet. There is no ssh tunnel. The Mac's Silica end dials the remote's Erlang listener at
`138.197.209.113:4550`. Requests then flow **both ways over that one connection**, and every reply is matched to its
request by id.

It is `ethernet_direct` with the remote's Silica end replaced by Erlang: the Silica program on the Mac is built from
the same source with the same settings, and the Erlang peer speaks exactly the terms the Silica Linux end speaks.
The mirror image, Erlang on the Mac and Silica on the remote, is
[`../ethernet_mac_erlang_remote_silica`](../ethernet_mac_erlang_remote_silica/).

```
        Mac (Silica, accel side, behind the campus NAT)        Linux x86-64 (Erlang, status side, public address)
  dialer -> 138.197.209.113:4550  ======= one TCP connection =======  gen_tcp:listen(4550, [{ip, {0,0,0,0}}, ...])

  Mac -> Linux   (:request, 1 | 3 | 5, (:accel, { x, y, z, at_ms }))   Linux -> Mac  (:reply, id, (:led, { which: :red, on: z > 256 }))
  Linux -> Mac   (:request, 2 | 4 | 6, :status)                          Mac -> Linux  (:reply, id, (:status, { host, uptime_ms, requests_seen }))
```

## The terms

The Silica source, `../ethernet_direct/dangerous_ethernet_direct_pair.silica`, defines the shapes. In Erlang:

| Silica | Erlang |
| --- | --- |
| `(:request, id, (:accel, { x, y, z, at_ms }))` | `{request, Id, {accel, #{x => X, y => Y, z => Z, at_ms => At}}}` |
| `(:reply, id, (:led, { which: :red, on }))` | `{reply, Id, {led, #{which => red, on => true \| false}}}` |
| `(:request, id, :status)` | `{request, Id, status}` |
| `(:reply, id, (:status, { host, uptime_ms, requests_seen }))` | `{reply, Id, {status, #{host => <<"mac-arm64">>, uptime_ms => Ms, requests_seen => N}}}` |

A tagged tuple is a tuple, a record is a map with atom keys, a Silica `string` is a binary, and a boolean is the atom
`true` or `false`. Each frame is one ETF term behind a 4-byte length prefix: `{packet, 4}` in `gen_tcp`, `wireframe`
in Silica.

**Byte-identical terms.** The peer encodes every term with `term_to_binary(T, [deterministic])`. That writes map
keys in term order, the order in which Silica's `encode` writes a record's fields. So its led replies and status
requests are the bytes the Silica Linux end would send. The other direction is checked on every run: the peer
compares each frame it receives with `term_to_binary(binary_to_term(F), [deterministic])`, byte for byte, and prints
`etf: 6 frames received, 6 in deterministic form`. Frames are decoded with `[safe]`.

**What differs** is only in the status replies, and those come from Silica here: `host` is `mac-arm64` and
`uptime_ms` is the Mac's monotonic clock in milliseconds. The expected file replaces `uptime_ms` by `<n>`.

## The two ends

- **The Mac end** is the accel side of `../ethernet_direct`, built here with `binaries/silica-compiler` from that
  source. It dials `138.197.209.113:4550`, sends accel requests and answers status requests.
  - Its carrier declaration is `carried_on wire: (:tcp) (:interface, "en0");`, the interface of this Mac's
    default route (`run.sh` reads it from `route -n get default`; `MAC_IFACE` overrides it; the `--local` copy
    declares `(:interface, "lo0")`). The interface binding is enforced since stage E2 (built 2026-11-12; not yet re-run here):
    the dial leaves from `en0`'s address, which is the address the default route would pick. This end never listens,
    so the `listen:any` refusal does not touch it; its build script still passes a listen address, now
    `"listen:<port>"` for consistency with `../ethernet_direct`. **Choice made: the declaration is kept.** The
    remote end is the Erlang peer, which listens on 0.0.0.0 as before. See `../ethernet_direct/README.md`.
- **The remote end: `status_side_peer.erl`.** `run.sh` copies it to the remote and compiles it there with `erlc`
  (OTP 27). It runs with `erl -noshell` under `timeout 90` and does what the Silica status side does, printing the
  same lines:
  - it listens on `0.0.0.0:4550` (`{ip, {0,0,0,0}}`) and accepts one connection;
  - it sends its three status requests 250 ms apart and matches each status reply to its request by id;
  - it answers each accel request at once by the rule (red on when z > 256);
  - with 3 replies matched and 3 requests answered it prints `pair complete`, waits 1.5 s so the peer can read the
    last reply, closes the connection and the listener and exits 0;
  - with no completion 45 s after start it prints `timeout: pair not complete` and exits 5; a port it cannot bind
    prints `listen failed <why>` and exits 1.

## Security

**Security.** The `(:tcp)` carrier is plain TCP. It provides no authentication, no encryption and no peer identity:
anyone who can reach a listening port can connect and send frames, and anyone on the path can read and change the
bytes. Secure interchange is being built on top of this carrier in Project BEES
(https://github.com/Silica-Language-and-Compiler/project-bees): SEMP/TRUST over mutual TLS 1.3 (ALPN `trust/1`, a
certificate whitelist; the TLS engine is selected: OpenSSL on macOS and Linux, Mbed TLS on the NUCLEO-L476RG and the
ESP32-S3) and an Erlang-compatible BEAM mode with cookie authentication. As of 2026-11-10 BEES's TLS and TRUST code is
not built yet and its cookie handshake is in progress; both build on this carrier's non-loopback support. Today
BEES's BEAM-mode wire runs between BEES nodes on loopback only, without the cookie digest (test-only,
unauthenticated).

The Erlang peer's `gen_tcp` listener is just as plain (it is not distributed Erlang: no node name, no cookie, no
EPMD). For this pair:

- **The firewall is the only guard.** The remote's source-address rule (TCP 4550 from this Mac's public address
  only) is all that protects the listener, and every host behind the same campus NAT shares that address.
- **The listener is up only during a run.** The peer runs under `timeout 90` and closes its listener when the pair
  completes. The script kills it on any exit and checks that nothing listens on 4550.
- **The bytes cross the Internet in clear text.** They are synthetic readings and status records.

## Running it

```sh
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_mac_silica_remote_erlang/run.sh                  # one run
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_mac_silica_remote_erlang/run.sh --runs 2         # two in a row
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_mac_silica_remote_erlang/run.sh --timeout-check  # no remote peer: exit 5
examples/transport_pairs/ethernet_mac_silica_remote_erlang/run.sh --local                                    # both ends on this Mac
examples/transport_pairs/ethernet_mac_silica_remote_erlang/run.sh --local --timeout-check                    # Erlang alone: exit 5
```

Options and overrides: `REMOTE_IP` (default 138.197.209.113), `--port` (default 4550), `SILICA_COMPILER` for the
Mac end.

`--local` runs the Erlang peer on the Mac (OTP 28), listening on `127.0.0.1:45570` only (loopback, so the Mac's
application firewall is not involved), and the Silica accel side dials it. It compares with the same `expected/`
files and needs no network. `--local --timeout-check` runs the Erlang peer alone, and nobody dials it.

What `run.sh` does:

1. **Builds the Mac end** with `binaries/silica-compiler`.
2. **Puts the Erlang peer on the remote** under `~/silica_demo/ethernet_mac_silica_remote_erlang` and compiles it
   there with `erlc`. No Silica compile runs on the remote.
3. **Runs the pair, once per run:**
   - checks the remote's 1-minute load and skips the run (counted as failed) above 4;
   - starts the peer under `timeout 90` and waits until `ss` shows it on `0.0.0.0:4550`;
   - runs the Mac end, which dials `138.197.209.113:4550`;
   - waits for the peer's `exit` line;
   - compares both outputs, sorted, with `expected/mac_silica_end.txt` and `expected/linux_erlang_end.txt` (the
     two directions' lines interleave differently from run to run);
   - kills the remote `erl` and checks that the remote has no peer and no listener on 4550. Only a positive ssh
     answer counts as checked.
4. **Tears down on exit.** A trap kills anything left on either side and repeats the check, which also covers the
   Mac.

The script never changes the remote's firewall or services, uses no sudo and installs nothing.

### What is left on the remote

`~/silica_demo/ethernet_mac_silica_remote_erlang/`, which holds `status_side_peer.erl`, its `.beam` and `peer.out`.
Nothing is left running.

## Results (2026-11-10)

- **`--local`: PASS**, two runs in a row; `--local --timeout-check`: PASS (exit 5).
- **Against `manager@aalang.org`: `--runs 2` PASS.** The Silica Mac end dialed `138.197.209.113:4550`; the Erlang
  peer (OTP 27 on `aalang-web`) accepted. Both ends printed
  `pair complete: 3 replies matched, 3 peer requests answered` and exited 0, and both outputs matched `expected/` on
  both runs. All 6 Silica frames per run were in deterministic form. After each run: no peer and no listener on
  4550 on the remote, nothing left on the Mac.
- **`--timeout-check`: PASS.** The Silica Mac end dialed `138.197.209.113:4550`, was refused, printed
  `timeout: pair not complete` and exited 5.

## Results (2026-11-11, `carried_on`)

After the switch of `../ethernet_direct` to `carried_on` (the Mac end declares `(:interface, "en0")`):

- **`--runs 2`: PASS.** Both runs: both ends printed `pair complete: 3 replies matched, 3 peer requests answered`,
  exit 0, the Erlang peer printed `etf: 6 frames received, 6 in deterministic form`, `MATCH` on both ends; after each
  run `remote: no peer, no listener on 4550`, `mac: no program left`.
- **`--timeout-check`: PASS** (exit 5, teardown clean). **`--local`: PASS.**
