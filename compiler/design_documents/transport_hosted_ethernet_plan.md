# Hosted Ethernet transport: development plan (Mac to a remote Erlang peer)

Status: plan, 2026-11-10. Nothing here is built yet. Companion to `transport_serialization_design.md` (carriers, ETF,
wire framing), `transport_links_design.md` (`carried_on`, `(:ethernet, n)`, `(:interface, name)`) and
`transport_esp32s3_wifi_plan.md` (the serial plan whose demos this one mirrors).

## 1. Goal

A hosted Silica program on the Apple Silicon Mac and an Erlang node on `manager@aalang.org` exchange ETF frames over
TCP across the Internet, with **connections and requests made from both sides**: either end can dial the other, and
either end can send a request and get the reply. It reuses the demo shape of the serial demo (a Silica peer and an
Erlang peer, run by script outside `make integrate`, output compared with an `expected` file).

## 2. Probe of the remote (2026-11-10, read-only, over ssh with the existing key)

| Fact | Value | Consequence |
| --- | --- | --- |
| Host | `aalang-web`, Ubuntu, Linux 6.17, x86-64 | a Linux x86-64 Silica peer is possible later (stage E7); the Erlang peer is the required one |
| Erlang | OTP 27 installed, `erl` on the path; EPMD already listening on 4369 (all interfaces) | `gen_tcp` with `{packet, 4}` works as in `silica_peer.erl`; ETF from OTP 27 decodes with `wire_etf` (map and atom forms already covered). Stage E0 checks this by round trip. Distributed Erlang is not used |
| Address | `138.197.209.113` (public) | the Mac can dial it directly |
| Listening | 22, 80, 443 open to the world; 5432 on loopback; `ufw` present | **a new public port needs a firewall change on a web host**: avoid it (decision 2) |
| Mac side | `en0` `10.25.164.98` behind the campus NAT, also wired Ethernet (802.1X) | the remote **cannot dial the Mac directly**: inbound needs a tunnel (decision 3) |

## 3. Decisions (proposed; each can be overruled)

1. **The link is the carrier we already have.** `(:tcp)` over `carried_on`. `(:ethernet, n)` and `(:interface, name)`
   are the hosted link tags of links-design decisions 10 and 11; this plan builds them (stage E2) so the Mac side can
   say `carried_on wire: (:tcp) (:ethernet, 0);` and the demo is genuinely "Ethernet". Until then the demo declares
   `(:tcp)` by module (`spawn_dangerous` with an address string), which already works.
2. **No new public port on aalang.org.** The remote's Erlang listens on loopback (`127.0.0.1:<port>`) and is reached
   through an SSH local forward (`ssh -L`). No `ufw` change, no exposure of the web host. (Overrule only if you want a
   raw port open; it needs `sudo ufw allow` and is plain, unauthenticated TCP.)
3. **Remote-to-Mac connections use a reverse tunnel** (`ssh -R 127.0.0.1:<rport>:127.0.0.1:<mport>`): the Erlang node
   dials its own loopback and arrives at the Mac's Silica listener. The Mac listener binds `127.0.0.1` only.
4. **Both ends play both roles in one run**: each end runs a listener and a dialer. The Mac dials the remote listener
   and the remote dials the Mac listener, so there are two TCP connections, each with a request sent in each
   direction (decision 5).
5. **Request/reply vocabulary** (ETF terms, `{packet, 4}` framing, no new wire format):
   `(:request, id: uint32, body)` and `(:reply, id: uint32, body)`. Bodies: Mac to remote `(:accel, {x,y,z,at_ms})`
   answered by `(:led, {which, on})` with the serial demo's rule (z above a threshold gives red on), so the answer is
   comparable with S-D; remote to Mac `(:status)` answered by `(:status, {host, otp, uptime_ms})`-style map. The id
   pairs a reply with its request, so several can be in flight.
6. **Encryption is out of scope for the transport** (your earlier ruling); the SSH tunnel carries the bytes
   encrypted in practice. The plan records that the TCP carrier itself is plain.
7. **Keys stay in `~/.ssh`**; scripts use `ssh -o BatchMode=yes` and never print or copy keys. The scripts take the
   target as `REMOTE=manager@aalang.org` so nothing is hard-wired to your account.
8. **Outside `make integrate`**, like the BEAM and serial demos (needs the network and the remote). Hosted loopback
   trials (stage E3) are the in-suite coverage.

## 4. What exists and what is missing

Exists: `dangerous_tcp_carrier` (connect and listener serving many peers, `(:accepted, conn, info)`), `wireframe`,
`wire_etf`, `carried_on` (`(:interface, name)` and `(:ethernet, n)` are accepted and bind nothing, links design
§3.2), `programmer_tools/transport_beam_demo` (one-shot, one direction).

Missing:

- Binding for `(:interface, name)` (getifaddrs at `:open`) and `(:ethernet, n)` / `(:wifi, n)` (enumeration by family)
  in `dangerous_sockets`/`silica_sockets.c` and `Link.silica`/the Mac pack. Absent interface fails at open with
  `(:explicit, :link_unavailable)`.
- `getpeername` (the listener reports `"peer:accepted"` today): needed so the demo can print who connected.
- A request/reply demo with both roles; today's demo is one-shot.
- Erlang peer that both listens and dials, with the same rule as the Silica peer.
- Tunnel/run scripts.

## 5. Stages

- **E0. Remote readiness (no code).** **Done 2026-11-10.** Script `examples/transport_pairs/ethernet_remote/check_remote.sh`
  (the pairs live under `examples/transport_pairs/`, not `programmer_tools/`): ssh with BatchMode, `erl` version, the BEAM
  demo's unchanged `silica_peer.erl` copied to `~/silica_demo` on the remote and started on `127.0.0.1:4540` only, an
  `ssh -L` forward to it, and the hosted Silica demo program (`(:tcp)` carrier) through the forward. Result: remote
  `aalang-web` (Linux x86_64) OTP 27 decoded the 48-byte accel term (`#{x => 1, y => -2, z => 512, at_ms => 1000}`) and
  Silica decoded the OTP 27 reply (`led red on`), exit 0. The script tears down the forward and the remote `erl` (trap);
  afterwards the remote holds only `~/silica_demo/` (peer.erl, .beam, peer.out) and no listener. Gate met.
- **E1. Request/reply Silica peer and Erlang peer.** `dangerous_ethernet_peer.silica` (dials; listens) and
  `ethernet_peer.erl` (listens; dials), both with the `(:request, id, body)` rule, both exiting 0 after N exchanges.
  First on one Mac (127.0.0.1, both directions, no ssh): proves the logic before the network. Output compared with an
  `expected.txt`.
- **E2. Hosted link binding.** Implement `(:interface, name)` and `(:ethernet, n)` for the Mac (and the shared
  front end unchanged: pack rows already answer true); `getpeername`; the trials listed in links design §6
  (`link_interface_absent`, `link_family_absent`, `app_transport_tcp_interface_link`, `app_transport_family_link`
  host-dependent, outside `make integrate`). Delegate to a Fable agent restricted to Apple Silicon, as before.
- **E3. In-suite trials** (`trials/transport_addition` and `trials/ffi_addition`): two Silica peers on loopback doing
  the request/reply exchange from both sides (dial and listen in the same program, two connections), plus a failure
  trial for a request with no reply (peer closes) that must end with `(:link_down, ...)` rather than hang. Apple
  goldens regenerated; Linux goldens stay stale until a Linux host (known, see the serial plan).
- **E4. Remote demo, Mac dials.** `run_demo.sh --remote`: starts the Erlang listener on the remote over ssh (loopback
  port), opens `ssh -N -L`, runs the Silica dialer, compares the output, tears down tunnel and remote process
  (trap; no orphan `erl` left on the web host).
- **E5. Remote demo, remote dials.** Silica listener on the Mac loopback; `ssh -N -R` reverse forward; the remote
  Erlang dials its own loopback and sends `(:request, 1, (:status))`; the Silica listener answers.
- **E6. Both at once.** One run, two connections, requests from both sides interleaved, ids matched; timeouts and
  cleanup; run twice in a row to prove no stale state. Expected output compared byte for byte.
- **E7 (optional). Linux x86-64 Silica peer on aalang.org.** The compiler targets Linux x86-64; build the peer there
  and replace the Erlang peer in a run, so Silica talks to Silica across the Internet. Needs the toolchain on the web
  host (probe first: do not install on a production machine without asking), so the build may instead be done on the
  Mac and the binary copied.
- **E8. Hardening and docs.** Reconnect after a drop, connect timeout, large frames (the 4-byte prefix is the limit),
  status lines in the transport and links designs, memory note.

## 6. Risks

- **Web host is production**: the demo starts a user-level `erl` on loopback only, then kills it; no `ufw` or service
  changes, no files outside `~/silica_demo` on the remote.
- **Campus network** may block outbound ssh or idle-kill long tunnels: demos are short; `ServerAliveInterval` set.
- **`(:ethernet, 0)` on this Mac** is the 802.1X wired port; if it is down, the carrier fails with `:link_unavailable`
  by design. The Internet leg then uses Wi-Fi; the demo documents which interface carried it.
- **OTP 27 vs 26 ETF differences** (atom encoding, `NEW_FLOAT`): checked in E0.
- **Environment**: the published `binaries/silica-compiler` predates `carried_on`; use
  `compiler/build/apple_silicon_mac/silica-compiler` (`SILICA_COMPILER`).

## 7. Open questions

1. Is a tunnel acceptable, or do you want a real public port (needs `sudo ufw allow <port>/tcp` on the web host)?
2. Should E7 (Silica on the remote) be in scope, and may I probe it for a C toolchain (`clang`/`ar`)?
3. Which demo content: the accel/LED terms (same as the serial demo) plus the `:status` request, or something else?
