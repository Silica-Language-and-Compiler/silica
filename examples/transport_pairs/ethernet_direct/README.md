# ethernet_direct

Silica runs on both ends of **one direct TCP connection** across the Internet: this Apple Silicon Mac and a Linux
x86-64 host (`manager@aalang.org`, 138.197.209.113 by default). There is no ssh tunnel. The Mac dials the remote's
Silica listener at `138.197.209.113:4550`. Requests then flow **both ways over that one connection**, because TCP is
full duplex. Every reply is matched to its request by id.

- **One source.** `dangerous_ethernet_direct_pair.silica` holds both ends. `run_direct.sh` makes the per-host copy
  with sed at compile time. It sets the addresses and the host name, and it picks the side.
- **The Mac end** is built with `binaries/silica-compiler`.
- **The Linux end** is built on the remote with the hosted Linux compiler: `binaries/silica-compiler-linux_x86_64`
  (silica-999959), which `../ethernet_remote` already staged at `~/silica_demo/toolchain/silica-compiler`. This pair
  only reads that file.
- **The carrier.** Both ends use the hosted `(:tcp)` carrier, `dangerous_tcp_carrier`, named by module
  (`spawn_dangerous` with an address string). silica-999959 predates `carried_on`.

```
        Mac (accel side, behind the campus NAT)                Linux x86-64 (status side, public address)
  dialer -> 138.197.209.113:4550  ===== one TCP connection =====  listener "listen:any:4550" (0.0.0.0:4550)

  Mac -> Linux   (:request, 1 | 3 | 5, (:accel, { x, y, z, at_ms }))   Linux -> Mac  (:reply, id, (:led, { which: :red, on: z > 256 }))
  Linux -> Mac   (:request, 2 | 4 | 6, :status)                          Mac -> Linux  (:reply, id, (:status, { host, uptime_ms, requests_seen }))
```

The terms are ETF, and each frame has a 4-byte length prefix (`wireframe`, the same as Erlang's `gen_tcp`
`{packet, 4}`).

## Why one connection

- **The Mac cannot be dialed.** It is behind the campus NAT, so a connection from the remote to the Mac cannot be
  made.
- **The remote can be dialed.** It has a public address, and its owner opened TCP 4550 in its firewall (`ufw`) for
  the Mac's public address 157.201.64.9 only.
- **So the Mac makes the connection and both sides use it.** Each end sends its own requests and answers the
  peer's requests over that connection. The Mac's ids are odd and the remote's are even, so the two directions'
  ids never collide.
- **This replaces `../ethernet_remote`.** That pair has two connections, one dialed by each side, and carries both
  through `ssh -L`/`ssh -R` forwards to loopback-only listeners.

## The listener binds every interface

`"listen:<port>"` binds 127.0.0.1 only. For this pair, `dangerous_tcp_carrier` gained one explicit form:

- **`"listen:any:<port>"`** binds `0.0.0.0:<port>` (`dangerous_sockets@tcp_listen_any`, the C wrapper
  `silica_sockets_tcp_listen_any`).
- **Nothing selects it by default.** A program must write it.
- **It is temporary.** It stands in until interface binding (`(:interface, name)`, `(:ethernet, n)`) exists: stage
  E2 of `compiler/design_documents/transport_hosted_ethernet_plan.md`.
- **Trial.** `trials/transport_addition/app_transport_tcp_listen_any` binds it on port 0 and connects through
  127.0.0.1.

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

For this pair that means:

- **The firewall is the only guard.** The remote's source-address rule (TCP 4550 from 157.201.64.9 only) is all
  that protects the listener. Anyone else behind the same campus NAT shares that public address.
- **The listener is up only during a run.** The Linux end runs under `timeout 90` and closes its listener when the
  pair completes. The script kills it on any exit and then checks that nothing listens on 4550.
- **The bytes cross the Internet in clear text.** They are synthetic readings and status records.

## How each end works

- **The coordinator.**
  - On the Linux end it owns the listener and gives every accepted connection a session actor.
  - On the Mac end it starts the dialer actor.
  - The dialer and the sessions share one behaviour (`connection`) and one state record, which has a `dials` flag.
- **Requests.** On `:link_up`, a connection actor sends its three requests 250 ms apart, so several are in flight
  at once. It keeps the outstanding ids in a bit mask and matches each reply by id. It answers each peer request as
  soon as it arrives.
- **Telling frames apart.** Every incoming frame is decoded first as a reply to this side's requests. If that is
  rejected, it is decoded as a peer request. Each side decodes only its own two shapes.
- **Flow control and framing** work as in `../usb_silica_pair`:
  - a frame goes out only while the end holds a transmit credit; otherwise it waits in an outbox string;
  - every `:rx` is reassembled with `wireframe@unframe` and drained.
- **Redialing.** A refused dial is retried every 500 ms, at most 80 times, with nothing printed. The script starts
  the Linux end first, so a normal run does not redial.
- **Completion.** An end is done when it has matched 3 replies and answered 3 requests, with every `:tx`
  confirmed. It prints `pair complete` and waits 1.5 s, so the peer can read the last reply. Then it exits 0; the
  Linux end closes its listener first.
- **Failure paths.**
  - With no completion 45 s after start, an end prints `timeout: pair not complete` and exits 5.
  - A listener that cannot bind prints `listen failed <why>` and exits 1.
  - A frame that decodes as neither shape prints `rejected <why>`.

### The side blocks

The source ends with two blocks, as in `../ethernet_remote`:

- **The accel side** is the Mac. It dials (`listens()` is false), sends accel requests and answers status requests.
- **The status side** is the Linux end. It listens, sends status requests and answers accel requests by the rule.

As written, the accel block is code and the status block is a `{- -}` comment. For the Linux copy, `run_direct.sh`
swaps them with sed. Each end compiles only its own block because of a limit of the Linux compiler: on the 3.9 GB
remote it runs out of memory (`(:explicit, :out_of_memory)` in its type-surface cache) when a unit holds both sides'
decoders. `../ethernet_remote/README.md` describes the limit.

## Running it

```sh
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_direct/run_direct.sh                  # build both ends, one run
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_direct/run_direct.sh --runs 2         # the run twice in a row
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_direct/run_direct.sh --timeout-check  # no Linux end: exit 5
examples/transport_pairs/ethernet_direct/run_direct.sh --local                                    # both ends on this Mac
```

Options and overrides:

- `REMOTE_IP` (default 138.197.209.113) and `--port` (default 4550);
- `SILICA_COMPILER` for the Mac end;
- `LINUX_COMPILER` for the Linux end (a path on the remote).

`--local` builds both sides on the Mac. The status side listens on `listen:any:45550` and the accel side dials
`127.0.0.1:45550`. It compares the outputs with the same `expected/` files. It is the self-test of the logic, and it
needs no network.

What the script does:

1. **Builds the Mac end.**
2. **Waits for the remote to be idle.** Another build may be running there; the remote has two CPUs, 3.9 GB of RAM
   and no swap. The script compiles only when no `silica-compiler` or `make` runs there, polling every 20 s for at
   most an hour. A remote that does not answer ssh counts as busy.
3. **Stages and builds the Linux end on the remote.** Under `~/silica_demo/ethernet_direct`, it copies the stdlib
   modules, `trial_wait_int64`, `silica_sockets.c` with its metadata, and `build_linux.sh`, then builds there.
4. **Runs the pair, once per run:**
   - starts the Linux end under `timeout 90` and waits until `ss` shows it listening on `0.0.0.0:4550`;
   - runs the Mac end;
   - waits for the Linux end's `exit` line;
   - compares both outputs with `expected/mac_end.txt` and `expected/linux_end.txt`, sorted (the two directions'
     lines interleave differently from run to run), with `uptime_ms` values replaced by `<n>`;
   - kills the remote program and checks that the remote has no program and no listener on 4550.
5. **Tears down on exit.** A trap kills any program left on either side and repeats the check. The check also
   covers the Mac.

The script never changes the remote's firewall or services, uses no sudo and installs nothing. It listens on no
remote port other than 4550, and only while a run is in progress.

### What is left on the remote

`~/silica_demo/ethernet_direct/`, which holds `build_linux.sh`, `stdlib/` (the sources) and `build/` (the program
and `peer.out`). Nothing is left running.

## Results (2026-11-10)

- **`--local`: PASS**, three runs (one, then two in a row). After each, the teardown check reported
  `mac: no program left`.
- **`--timeout-check`: PASS.** The Mac end dialed `138.197.209.113:4550` and was refused, since nothing listened.
  It printed `timeout: pair not complete` and exited 5.
- **The run against the remote has not been done yet.** The remote stopped answering ssh during an unrelated
  compiler build, and remote work was halted. Status: `compiler/design_documents/transport_hosted_ethernet_plan.md`
  §5b, D2.
