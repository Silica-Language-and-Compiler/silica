# ethernet_direct_udp

The UDP counterpart of `../ethernet_direct`. Silica runs on both ends of a **direct UDP exchange** across the
Internet: this Apple Silicon Mac and the Linux x86-64 host (`manager@aalang.org`, 138.197.209.113 by default, the same
remote `ethernet_direct` uses). There is no ssh tunnel. The Mac sends datagrams to `138.197.209.113:4551` and the Linux
end counts them.

**Status (2026-11-13): run Mac to nix (`lee@nix.local`, Linux x86-64) over the LAN and passed, both ends exit 0 and
both outputs match `expected/`.** The run used the freshly built compilers (Mac `silica-999916-macos-applesilicon`,
nix `silica-999949-linux-x86_64`), so the real `carried_on (:udp)` expansion compiled and ran. It has not been run
against `aalang.org` across the Internet. LAN invocation: `REMOTE=lee@nix.local REMOTE_IP=<nix ip> MAC_PUBLIC_IP=<Mac ip>
LINUX_IFACE=<nix iface> LINUX_COMPILER='$HOME/silica/binaries/silica-999949-linux-x86_64' ./run_direct_udp.sh`.
See "What is verified" below.

- **One source.** `dangerous_ethernet_direct_udp_pair.silica` holds both ends. `run_direct_udp.sh` makes the per-host
  copy with sed at compile time. It sets the carrier's declared link, the open address and the role (`sends()`).
- **The Mac end** (the sender) is built with `binaries/silica-compiler`. **The Linux end** (the receiver) is built on the
  remote with the hosted Linux compiler `~/silica_demo/toolchain/silica-compiler` (staged by `../ethernet_remote`; only
  read), through `build_linux_udp.sh`.
- **The carrier.** Both ends declare the hosted `(:udp)` carrier and start it with `spawn_dangerous_carrier(wire, ...)`,
  which the compiler expands to `dangerous_udp_carrier`; `Carrier@mtu(wire)` and `Carrier@boundaries(wire)` are the
  kind's row. The declaration is per host:

  | copy | declaration |
  |---|---|
  | Mac end | `carried_on wire: (:udp) (:interface, "en0");` (the interface of the Mac's default route; `run_direct_udp.sh` reads it from `route -n get default`, override with `MAC_IFACE`) |
  | Linux end | `carried_on wire: (:udp) (:interface, "eth0");` (the remote's public interface; override with `LINUX_IFACE`) |
  | `--local` (both ends on the Mac) | `carried_on wire: (:udp) (:interface, "lo0");` |

  No interface name is hard-coded in the program: the script passes both through sed, as `ethernet_direct` does.

## UDP and the link

The open string of the UDP carrier is `"host:port@local"`: the peer every `:tx` datagram goes to, and the local address
the endpoint binds. The local part has three forms:

| local | meaning |
|---|---|
| `<port>` | `127.0.0.1:<port>`; with a named link, that interface's **first IPv4 address** |
| `<ipv4>:<port>` | that one address (under a named link it must be one of the interface's addresses) |
| `any:<port>` | `0.0.0.0:<port>`, every IPv4 interface; **refused under any declared link** |

This example opens `"138.197.209.113:4551@4551"` on the Mac and `"<Mac public ip>:4551@4551"` on Linux, with
`(:interface, name)` declared on each end. So:

- **`@4551` binds the interface's address.** On the Mac the sender's datagrams leave from `en0`'s first IPv4 address; on
  Linux the receiver is bound to `eth0`'s first IPv4 address (the 138.197.209.113 the Mac sends to).
- **`@any:4551` would be refused.** A literal one is compile error **E2418** (a named link refuses it); one computed at run
  time makes the carrier send its owner `(:link_down, :fault)` and then end with `(:explicit, :link_unavailable)`. That is
  why the source writes `@4551`. A wrong `MAC_IFACE` or `LINUX_IFACE` fails the same way at `:open`: the end prints
  `link down fault` and exits 1 (the carrier's own failure banner follows).
- **The peer is the explicit host:port in the open string; the link does not restrict it.** The Linux end's peer is never
  sent to (it only receives) but the open string needs a dotted quad, so it is this Mac's public address
  (`MAC_PUBLIC_IP`, default 157.201.64.9, the address the TCP example's firewall rule names).

## Design: tolerating loss

UDP is datagram: no connection, no ordering and **no delivery guarantee**, and the carrier's `:rx` carries no sender
address, so the receiver cannot answer (and the Mac, behind the campus NAT, could not be dialed back reliably anyway).
So the exchange is one-way and the loss tolerance is repetition:

- The sender sends 5 samples `(:sample, n, 100 * n + 7)`, `n = 1..5`, in **three rounds** (15 datagrams, one every
  100 ms). Each is a bare ETF term behind wireframe's 4-byte length prefix, one per datagram.
- The receiver keeps a bit mask of the **distinct** numbers it has seen, prints `sample <n> value <v>` the first time
  each arrives and ignores repeats. It is done when all five have arrived: any two of the three copies of a number can
  be lost, and reordering does not matter.
- The sender does not wait for the receiver, so `run_direct_udp.sh` starts the receiver first and waits until `ss -lun`
  shows it bound to UDP 4551.
- The receiver prints `received all 5 numbers`, waits one second and exits 0 (closing its endpoint first). The sender
  prints `sent 15 datagrams: 5 numbers, 3 rounds` 500 ms after the last datagram and exits 0. A receiver that has not got
  all five 45 s after start prints `timeout: not all 5 numbers arrived` and exits 5.

**Determinism.** On a quiet LAN or Internet path the run is deterministic: no datagram is lost, so the same lines are
printed every time; the receiver's lines are compared **sorted** because a reordered datagram changes the order. It is not
guaranteed: if the path loses all three copies of one number, the receiver times out (exit 5) and the run is reported as a
failure. That is the honest UDP outcome, not a program fault; rerun it.

## How each end works

- **Sender** (`sends()` true). On `:link_up` it prints `sender up` and sends sample 1; each `(:tick, n, round)` timer
  (`send_after`, 100 ms) sends the next datagram with `cast(car, (:tx, segment, self()))`. After round 3 it waits 500 ms
  (`:finish`), prints the summary and exits 0. A `:link_down` before that prints `link down <why>` and exits 1.
- **Receiver** (`sends()` false). On `:link_up` it prints `receiver up` and grants 8 receive credits, then one more
  per datagram. Every `:rx` is one datagram, reassembled with `wireframe@unframe` and decoded as `(:sample, n, v)`; an
  undecodable or out-of-range datagram prints `rejected <why>`.
- **Small main.** `main` starts the supervisor (`trial_wait_int64@start`), casts the work that spawns the carrier and
  the endpoint and sends the open message, and ends with `wait_for_exit()`. The failure reporter is registered by
  `trial_wait_int64@start`, so a carrier that ends with `(:explicit, :link_unavailable)` is reported (an actor-failure
  banner after the end's own `link down` line and exit 1).

Expected output (`expected/mac_end.txt`, `expected/linux_end.txt`; both compared sorted):

```
Mac end:                                        Linux end:
sender up                                       receiver up
sent 15 datagrams: 5 numbers, 3 rounds          sample 1 value 107  ...  sample 5 value 507
exit 0                                          received all 5 numbers
                                                exit 0
```

## Security

**Security.** UDP is as unauthenticated as the `(:tcp)` carrier (see `../ethernet_direct`): no authentication, no
encryption, no peer identity, and a datagram's source address can be forged. While the Linux end runs, anyone who can
reach UDP 4551 on the remote can send it datagrams, and a forged `(:sample, ...)` is counted. The remote's firewall
source-address rule is the only guard; the receiver runs under `timeout 90` only during a run, and the script checks
afterwards that nothing is bound to UDP 4551. The datagrams cross the Internet in clear text (synthetic numbers).

## Running it

```sh
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_direct_udp/run_direct_udp.sh           # build both ends, one run
REMOTE=manager@aalang.org examples/transport_pairs/ethernet_direct_udp/run_direct_udp.sh --runs 2  # the run twice in a row
examples/transport_pairs/ethernet_direct_udp/run_direct_udp.sh --local                             # both ends on this Mac (lo0)
```

The remote host comes from the `REMOTE` environment variable (default `manager@aalang.org`) and `REMOTE_IP` (default
138.197.209.113), exactly as in `ethernet_direct`; the script reads no other host file. Other overrides: `--port`
(default 4551), `SILICA_COMPILER`, `LINUX_COMPILER` (a path on the remote), `MAC_IFACE`, `LINUX_IFACE`, `MAC_PUBLIC_IP`.

`--local` builds both ends on the Mac, declares `(:interface, "lo0")`, binds the receiver to 127.0.0.1:45551 and the
sender to 127.0.0.1:45552, and compares with the same `expected/` files. It needs no network.

The script waits for the remote to be idle (no `silica-compiler` or `make` there), stages the stdlib sources,
`silica_sockets.c` and `build_linux_udp.sh` under `~/silica_demo/ethernet_direct_udp`, builds the Linux end there, runs the
pair, compares, and tears down (kills the remote program, checks nothing is bound to UDP 4551 and no program is left on
either host). It changes no firewall and uses no sudo. **The remote's firewall must admit UDP 4551 from this Mac's public
address**, a rule the remote's owner makes (the TCP example's rule admits TCP 4550 only).

## What is verified

- The program was compiled on the Mac with the current `binaries/silica-compiler`, with the `carried_on` line and
  `spawn_dangerous_carrier(wire, ...)` replaced by `spawn_dangerous({...}, dangerous_udp_carrier@carrier, ...)` (the form
  `trials/ffi_addition/app_transport_tcp_loopback/dangerous_udp_loopback.silica` uses). With the real
  `spawn_dangerous_carrier(wire, ...)` under `carried_on wire: (:udp) ...` that binary stops with E2003 (struct literal
  field count) at the expansion: the UDP `carried_on` support in the transport packs is not built into it yet.
- In that spelling, a sender and a receiver on 127.0.0.1 (ports 45552 -> 45551, no link) printed exactly the expected
  Mac and Linux lines.
- **Not verified:** the `carried_on` UDP form and its link binding, the Linux x86-64 build, the run across the network,
  the remote firewall for UDP 4551, and the failure-path lines.
