# ethernet_mac_erlang_remote_silica

An **Erlang** peer on this Apple Silicon Mac and the **Silica** Linux end of [`../ethernet_direct`](../ethernet_direct/)
on the Linux x86-64 remote (`manager@aalang.org`, 138.197.209.113 by default), over **one direct TCP connection**
across the Internet. There is no ssh tunnel. The Mac's Erlang peer dials the remote's Silica listener at
`138.197.209.113:4550`. Requests then flow **both ways over that one connection**, and every reply is matched to its
request by id.

It is `ethernet_direct` with the Mac's Silica end replaced by Erlang: the Silica program on the remote is the same
binary, and the Erlang peer speaks exactly the terms the Silica Mac end speaks. The mirror image, Silica on the Mac
and Erlang on the remote, is [`../ethernet_mac_silica_remote_erlang`](../ethernet_mac_silica_remote_erlang/).

```
        Mac (Erlang, accel side, behind the campus NAT)        Linux x86-64 (Silica, status side, public address)
  gen_tcp:connect -> 138.197.209.113:4550  === one TCP connection ===  listener "listen:4550" (eth0's address, port 4550)

  Mac -> Linux   {request, 1 | 3 | 5, {accel, #{x, y, z, at_ms}}}   Linux -> Mac  {reply, Id, {led, #{which => red, on => Z > 256}}}
  Linux -> Mac   {request, 2 | 4 | 6, status}                       Mac -> Linux  {reply, Id, {status, #{host, uptime_ms, requests_seen}}}
```

## The terms

The Silica source, `../ethernet_direct/dangerous_ethernet_direct_pair.silica`, defines the shapes. In Erlang:

| Silica | Erlang |
| --- | --- |
| `(:request, id, (:accel, { x, y, z, at_ms }))` | `{request, Id, {accel, #{x => X, y => Y, z => Z, at_ms => At}}}` |
| `(:reply, id, (:led, { which: :red, on }))` | `{reply, Id, {led, #{which => red, on => true \| false}}}` |
| `(:request, id, :status)` | `{request, Id, status}` |
| `(:reply, id, (:status, { host, uptime_ms, requests_seen }))` | `{reply, Id, {status, #{host => <<"mac-erlang">>, uptime_ms => Ms, requests_seen => N}}}` |

A tagged tuple is a tuple, a record is a map with atom keys, a Silica `string` is a binary, and a boolean is the atom
`true` or `false`. Each frame is one ETF term behind a 4-byte length prefix: `{packet, 4}` in `gen_tcp`, `wireframe`
in Silica.

**Byte-identical terms.** The peer encodes every term with `term_to_binary(T, [deterministic])`. That writes map
keys in term order, the order in which Silica's `encode` writes a record's fields. So for the same term the peer
sends the same bytes the Silica Mac end would. The other direction is checked on every run: the peer compares each
frame it receives with `term_to_binary(binary_to_term(F), [deterministic])`, byte for byte, and prints
`etf: 6 frames received, 6 in deterministic form`. Frames are decoded with `[safe]`.

**What legitimately differs** is the status reply's content. Its `host` is `mac-erlang` (the Silica Mac end says
`mac-arm64`), and its `uptime_ms` is the Erlang VM's uptime (`erlang:statistics(wall_clock)`), not Silica's
monotonic clock. The expected file has the Erlang host, and `uptime_ms` is replaced by `<n>` before comparing.

## The two ends

- **The Mac end: `accel_side_peer.erl`.** It runs with `erl -noshell` and does what the Silica accel side does,
  printing the same lines:
  - it dials; a refused dial is retried every 500 ms, at most 80 times, silently, and a connection lost before
    completion is dialed again with a fresh state;
  - on connect it sends its three accel requests 250 ms apart, so several are in flight;
  - it matches each led reply to its request by id and answers each status request at once;
  - with 3 replies matched and 3 requests answered it prints `pair complete`, waits 1.5 s so the peer can read the
    last reply, and exits 0;
  - with no completion 45 s after start it prints `timeout: pair not complete` and exits 5.
- **The Linux end** is the status side of `../ethernet_direct`. It listens on `"listen:4550"` (the address of its declared `eth0`), sends status
  requests and answers accel requests by the rule (red on when z > 256). **It is not rebuilt here.** `run.sh` copies
  the program that `../ethernet_direct/run_direct.sh` built on the remote
  (`~/silica_demo/ethernet_direct/build/dangerous_ethernet_direct_pair`) into this example's remote directory. It
  first checks that the source that program was built from has the same sha256 as the Linux copy `run_direct.sh`
  makes from today's source. `--rebuild-linux` builds it in this example's directory instead, with
  `../ethernet_direct/build_linux.sh`, and only when no other `silica-compiler` or `make` runs on the remote.
- **The Silica end's carrier declaration.** The Linux end declares `carried_on wire: (:tcp) (:interface, "eth0");`
  (the remote's public interface; `LINUX_IFACE` overrides it, and the `--local` copy declares `(:interface, "lo0")`). **The
  interface binding is enforced since stage E2 (built 2026-11-12; not yet re-run here)**: the named link binds the
  carrier to that interface's first IPv4 address and refuses `listen:any`, so the status side was changed from
  `"listen:any:4550"` to `"listen:4550"` in `../ethernet_direct`. **Choice made: the declaration is kept** and the
  listener narrows from 0.0.0.0 to `eth0`'s address; the port, the dial address and the traffic are unchanged. See
  `../ethernet_direct/README.md`.

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

The Erlang peer's `gen_tcp` connection is just as plain. For this pair:

- **The firewall is the only guard.** The remote's source-address rule (TCP 4550 from this Mac's public address
  only) is all that protects the listener, and every host behind the same campus NAT shares that address.
- **The listener is up only during a run.** The Linux end runs under `timeout 90` and closes its listener when the
  pair completes. The script kills it on any exit and checks that nothing listens on 4550.
- **The bytes cross the Internet in clear text.** They are synthetic readings and status records.

## Running it

```sh
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_mac_erlang_remote_silica/run.sh                  # one run
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_mac_erlang_remote_silica/run.sh --runs 2         # two in a row
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_mac_erlang_remote_silica/run.sh --timeout-check  # no remote end: exit 5
examples/transport_pairs/ethernet_mac_erlang_remote_silica/run.sh --local                                    # both ends on this Mac
examples/transport_pairs/ethernet_mac_erlang_remote_silica/run.sh --local --timeout-check                    # Erlang alone: exit 5
```

Options and overrides: `REMOTE_IP` (default 138.197.209.113), `--port` (default 4550; the reused Linux program
listens on 4550, so another port needs `--rebuild-linux`), `SILICA_COMPILER` for `--local`, `LINUX_COMPILER` for
`--rebuild-linux` (a path on the remote, default `~/silica_demo/toolchain/silica-compiler`).

`--local` builds the Silica status side on the Mac with `binaries/silica-compiler`. It listens on
`listen:any:45560`, and the Erlang peer dials `127.0.0.1:45560`. It compares with the same `expected/` files, needs no
network, and works with the Mac's OTP 28.

What `run.sh` does:

1. **Compiles the Erlang peer** with `erlc` into `build/`.
2. **Puts the Linux end in place** on the remote, under `~/silica_demo/ethernet_mac_erlang_remote_silica/build`
   (see above). No Silica compile runs on the remote unless `--rebuild-linux` is given.
3. **Runs the pair, once per run:**
   - checks the remote's 1-minute load and skips the run (counted as failed) above 4;
   - starts the Linux end under `timeout 90` and waits until `ss` shows it on `0.0.0.0:4550`;
   - runs the Erlang peer, which dials `138.197.209.113:4550`;
   - waits for the Linux end's `exit` line;
   - compares both outputs, sorted, with `expected/mac_erlang_end.txt` and `expected/linux_silica_end.txt` (the
     two directions' lines interleave differently from run to run);
   - kills the remote program and checks that the remote has no program and no listener on 4550. Only a positive
     ssh answer counts as checked.
4. **Tears down on exit.** A trap kills anything left on either side and repeats the check, which also covers the
   Mac.

The script never changes the remote's firewall or services, uses no sudo and installs nothing.

### What is left on the remote

`~/silica_demo/ethernet_mac_erlang_remote_silica/build/`, which holds the copied program, the source it was built
from and `peer.out`. Nothing is left running.

## Results (2026-11-10)

- **`--local`: PASS**, three runs (one, then two in a row); `--local --timeout-check`: PASS (exit 5).
- **Against `manager@aalang.org`: `--runs 2` PASS.** The Mac's Erlang peer (OTP 28) dialed `138.197.209.113:4550`;
  the Silica Linux end (the program built by `ethernet_direct`, source sha256 `6e9852ab8a444950...`, reused, not
  rebuilt) accepted. Both ends printed `pair complete: 3 replies matched, 3 peer requests answered` and exited 0,
  and both outputs matched `expected/` on both runs. All 6 Silica frames per run were in deterministic form. After
  each run: no program and no listener on 4550 on the remote, nothing left on the Mac.
- **`--timeout-check`: PASS.** The Erlang peer dialed `138.197.209.113:4550`, was refused, printed
  `timeout: pair not complete` and exited 5.

## Results (2026-11-11, `carried_on`)

After the switch of `../ethernet_direct` to `carried_on` (Linux end built on the remote with silica-999958):

- **`--runs 2`: PASS.** `run.sh` reused the program `ethernet_direct` had just built (`reused
  .../ethernet_direct/build/dangerous_ethernet_direct_pair (source sha256 7368c6b2a24afec3, program sha256
  a176f8fa9a79348b)`). Both runs: both ends printed `pair complete: 3 replies matched, 3 peer requests answered`,
  exit 0, `etf: 6 frames received, 6 in deterministic form`, `MATCH` on both ends; after each run
  `remote: no program, no listener on 4550`, `mac: no program left`.
- **`--timeout-check`: PASS** (exit 5, teardown clean). **`--local`: PASS.**
