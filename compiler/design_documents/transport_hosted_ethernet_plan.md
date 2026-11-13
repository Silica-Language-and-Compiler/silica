# Hosted Ethernet transport: development plan (Mac to a remote Erlang peer)

Status: 2026-11-10. E0 done. E1 dropped: work-network restrictions rule out the local-Mac test. In its place, stages
L0 to L3 (§5a) ran a Silica-to-Silica interchange between this Mac and the remote Linux x86-64 host; they are done.
**Tunnels dropped the same day (user ruling): stages D0 to D2 (§5b) run that interchange over one direct TCP
connection, with the Mac dialing `138.197.209.113:4550` and requests flowing both ways. This adds the carrier's
`"listen:any:<port>"` wildcard listener.** **E2 is BUILT and partly verified (branch `E2-transport-work`, pushed in `b943620c00` and merge `2423f477b4`, 2026-11-12; widened by Lee 2026-11-11 to all three hosted targets, a `"listen:<ipv4>:<port>"` listener form, interface binding, refusal rules and the compile guard `E2418`). What is verified, what is only built and what is open are listed in the E2 status table below.** The rest of the stages below are not started. Companion to `transport_serialization_design.md` (carriers, ETF,
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
2. **Superseded 2026-11-10 (user): one public port, no tunnels.** Originally the remote listened on loopback only,
   reached through `ssh -L`. The user has since opened TCP 4550 in the remote's `ufw` for this Mac's public address
   (157.201.64.9) only, and ruled out ssh tunnels. The Mac now dials the remote's Silica listener directly at
   `138.197.209.113:4550` (§5b). The listener uses the carrier's explicit wildcard address `"listen:any:4550"`, and
   it runs only during a run. This is plain, unauthenticated TCP: the source-address rule is its only protection.
3. **Superseded 2026-11-10: no reverse tunnel.** The remote cannot dial the Mac, which is behind the campus NAT. So
   there is one connection, made by the Mac, and the remote's requests travel back over it (decision 4).
4. **Both ends make requests in one run.** Originally each end ran a listener and a dialer, giving two connections
   (§5a, through tunnels). Since 2026-11-10 there is **one connection**, dialed by the Mac. TCP is full duplex, so
   both ends send requests and replies over it, the ids matched (odd from the Mac, even from the remote; §5b).
5. **Request/reply vocabulary** (ETF terms, `{packet, 4}` framing, no new wire format):
   `(:request, id: uint32, body)` and `(:reply, id: uint32, body)`. Bodies: Mac to remote `(:accel, {x,y,z,at_ms})`
   answered by `(:led, {which, on})` with the serial demo's rule (z above a threshold gives red on), so the answer is
   comparable with S-D; remote to Mac `(:status)` answered by `(:status, {host, otp, uptime_ms})`-style map. The id
   pairs a reply with its request, so several can be in flight.
6. **Encryption is out of scope for the transport** (your earlier ruling). The TCP carrier itself is plain. The
   tunnels of §5a encrypted the bytes in practice; the direct connection of §5b does not (see the security note
   in §5b).
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
- **E1. (Dropped 2026-11-10: the local-Mac test is not possible under the work-network restrictions. Replaced by
  L0 to L3, §5a, which run the request/reply exchange Silica to Silica between the Mac and the remote.)**
  Request/reply Silica peer and Erlang peer. `dangerous_ethernet_peer.silica` (dials; listens) and
  `ethernet_peer.erl` (listens; dials), both with the `(:request, id, body)` rule, both exiting 0 after N exchanges.
  First on one Mac (127.0.0.1, both directions, no ssh): proves the logic before the network. Output compared with an
  `expected.txt`.
- **E2. Hosted link binding. BUILT, PARTLY VERIFIED (2026-11-12, branch `E2-transport-work`, implemented by Fable: the
  Linux x86-64, Linux AArch64 and Mac packs together; pushed in `b943620c00`, merge `2423f477b4`). Widened (Lee, 2026-11-11) as follows.** Today the only listener choices are loopback (`listen:<port>`) or every interface
  (`listen:any:<port>`), and `(:interface, name)`/`(:ethernet, n)` are accepted but not enforced, so a declaration can
  imply a restriction it does not give; a multi-homed host cannot restrict an off-host listener to one network.
  1. **Interim guard (first inside E2; may land before the full binding).** A `(:interface, ...)`, `(:ethernet, n)` or
     `(:wifi, n)` declaration next to a `listen:any:` address must not pass silently. Decision: a runtime refusal at
     `:open` in `dangerous_tcp_carrier` (`(:explicit, :link_unavailable)`), plus a compile diagnostic with a
     code `E2418` where the checker sees both literals.
  2. **New listener form `"listen:<ipv4>:<port>"`.** Binds one given IPv4 address: a new
     `dangerous_sockets@tcp_listen_addr`, parsed in `dangerous_tcp_carrier` next to `"listen:any:"` and
     `"listen:<port>"`.
  3. **Interface binding.** `(:interface, name)`, `(:ethernet, n)`, `(:wifi, n)` bind the socket to that interface's
     address through `getifaddrs` at `:open`; failure ends `(:explicit, :link_unavailable)`. Linux needs its own
     `getifaddrs` binding.
  4. **Refusal rules.** Once `(:loopback)` refuses non-loopback addresses it also refuses `"listen:any:"` and
     `"listen:<ip>"` (non-loopback). A named interface/ethernet/wifi link refuses `"listen:any:"` and any
     `listen:<ip>` that is not that interface's address. A bare `"listen:<port>"` under a named link binds that
     interface's address (decided: yes).
  5. **All three hosted targets:** `apple_silicon_mac`, `linux_x86_64`, `linux_aarch64`. The three
     `compiler/src/emitter/<target>/transport_pack.silica` stay identical in logic; carrier and socket code are in
     `compiler/stdlib/dangerous_tcp_carrier.silica` and the `dangerous_sockets` sources. `getpeername` also here.
  6. **Trials:** `link_interface_absent`, `link_family_absent`, `app_transport_tcp_interface_link`,
     `app_transport_family_link` (links design §6); plus a listen_ip loopback trial (`listen:127.0.0.1:<port>`),
     listen_ip refused under `(:loopback)` for a non-loopback address, and any-refused-under-interface; per-target
     `golden_fail` files for linux_aarch64, linux_x86_64 and the Mac. Host-dependent ones run outside
     `make integrate`.
  7. **`"listen:any:<port>"` stays** (Lee, 2026-11-11: "don't remove"). E2 only adds the refusal rules of item 4 and
     the guard of item 1; the form is not deprecated or removed. Its users (`ethernet_direct`, `ethernet_remote`,
     trial `app_transport_tcp_listen_any`, BEES N1) keep working when no named link is declared.
     **As implemented (2026-11-12).** `ethernet_direct` declared `(:interface, "en0")` and listened on `listen:any:4550`;
     that combination is now refused (the named link refuses `listen:any`), so its source and `run_direct.sh` use
     `"listen:4550"`, which binds `en0`'s address. The examples that declare no named link keep `listen:any`.
     Family counting: `(:ethernet, n)` and `(:wifi, n)` count only interfaces that hold an IPv4 address (n counts from 0
     in `getifaddrs` order, an interface once). Dials under `(:loopback)` are unchanged; a dial under a named link leaves
     from the interface's address. The UDP carrier still binds nothing. Behaviour table (also links design §3.2,
     transport design §6.3): no link: `listen:<port>` 127.0.0.1, `listen:any:<port>` 0.0.0.0, `listen:<ip>:<port>` that
     ip; `(:loopback)`: `listen:<port>` 127.0.0.1, `listen:any` refused, `listen:<ip>` only in 127.0.0.0/8; named links:
     `listen:<port>` that interface's first IPv4 address, `listen:any` refused, `listen:<ip>` only that interface's
     addresses. Refusal: `(:link_down, :fault)` to the owner, then the carrier ends `(:explicit, :link_unavailable)`;
     malformed IPv4 ends `(:explicit, :bad_address)`. E2418 (compile) covers `spawn_dangerous_carrier` plus a
     `cast(x, (:open, _, "<literal>"))` in one function, TCP carriers on a link the target serves; else E2412.
     **Built vs verified.** Built: all three packs, `silica_sockets.c`, `dangerous_sockets`, `dangerous_tcp_carrier`,
     the E2418 scan. Verified and unverified: see the E2 status lists below (superseded: the probe-only and "no suite run" wording was 2026-11-12 morning).
     **Open point:** IPv4 literals with leading zeros (`010.0.0.1`) are parsed by `inet_aton`/`inet_pton`; macOS and
     glibc differ on them (octal or rejected), so `parse_ipv4` can accept on one host and refuse on the other.
     **Trials written (2026-11-12; since run, see the status lists below):** `trials/transport_addition/app_transport_tcp_link_rules` (interface and
     family absent, listen_ip, `(:loopback)` refusing 10.x, a named link refusing any: each runtime refusal is one
     program; refusal programs end on the failure report through the program's own reporter, see the trial lesson below),
     `trials/error_enforcement_addition/link_{interface_listen_any,loopback_listen_any,loopback_listen_ip}_trial`
     (E2418, one directory each; one Mac `golden_fail` each, the text is host-independent), and the host-dependent
     `programmer_tools/transport_interface_link` (lo0 on macOS, lo on Linux, outside `make integrate`).
  **E2 status (2026-11-12; the three lists are the record, the items above are the design).**
  - **Done / Verified (runs):** hosted link binding on the three hosted targets: `(:loopback)`, `(:interface, name)`,
    `(:ethernet, n)`, `(:wifi, n)` selection and ownership (C sidecar `tcp_listen_addr`, `tcp_connect_from`,
    `parse_ipv4`, `link_select`, `link_owns`, `peer_addr`, `peer_port`; macOS `SIOCGIFFUNCTIONALTYPE`, Linux sysfs
    `wireless`/`phy80211` and `type==1` plus `device` for wired); `listen:<ipv4>:<port>`; `listen:any` retained; the
    refusal rules of the behaviour table; the refusal path (owner gets `(:link_down, :fault)`, the carrier ends
    `(:explicit, :link_unavailable)`, or `(:explicit, :bad_address)` for a malformed IPv4, folded into main's failed-open
    branch); `E2418` (TCP only, link served by the target, literal address refused by the link, same function);
    `SO_NOSIGPIPE` on `tcp_connect_from`; the three hosted compilers rebuilt and the hosted trials run (Mac 35,225 pass;
    pix and nix ran before the final fixes); goldens regenerated on Mac, pix and nix. Trials: `app_transport_tcp_link_rules`
    (6 programs), three `E2418` compile-defect trials, two `dangerous_carrier_spawn_*` `golden_fail` trials, four
    `silica.link.scout` symbol additions. Verified by runs on all three hosted targets: loopback behaviour, the refusal
    behaviours and `E2418`; the macOS interface-classifier path only against `lo0`.
  - **Built, not verified:** the Linux interface classifier and the Wi-Fi family; the Linux branch of
    `programmer_tools/transport_interface_link/run.sh`; binding to a real non-loopback interface address (every trial
    uses loopback or a refused address); the final regenerated goldens had no confirming run (Lee's instruction), and the
    169 rewritten goldens and the wireframe golden (differs from main's) are not reviewed by hand; the x86-64
    `emitter_core` `use_full_param_shadow` change (`n >= 2` for string helpers) regenerated goldens in `string_addition`,
    `compiler_addition` and `modules_addition` on x86 only (not run on Mac or pix, whose emitters already had it); the
    ESP32-S3 and Nucleo cross compilers were not rebuilt (`E2418` is gated on the pack serving the link, so they should
    be unaffected; unchecked).
  - **Open (gaps):** (1) `spawn_dangerous_carrier` expands to a plain unsupervised spawn, so the supervisor restart as
    retry (specification 16.4.9, links design 6.3) happens only if the program supervises the carrier; the links design
    test plan ("a supervisor restart is counted") is met by no trial. (2) The UDP carrier binds nothing, so
    `listen:<ip>:<port>` and the refusal rules do not apply to UDP. (3) Leading-zero IPv4 literals (`010.0.0.1`) parse
    differently on macOS and glibc: needs a ruling. (4) `dangerous_tcp_listener` round 2 can in principle start before
    round 1's header lines are written (held in 100 parallel runs); a real fix has the reporter trigger round 2.
    (5) BEES N1: check the interface link plus `listen:any` pattern. (6) The three Linux packs do not cover
    `(:sd_blocks)` and `(:flash_region)` on hosted targets (`E2412`), unchanged and not E2.
  - **Trial lesson:** a run that ends on a carrier failure must end on the failure report itself, through the program's
    own failure reporter (`trial_wait_int64` registers its own reporter); otherwise the stdout and stderr banners race.
    The refusal programs use this pattern.
  8. **Sequencing and merge (Lee, 2026-11-12: "start E2 and update the plan. do no work for the persistence").** E2
     merges to main FIRST. The separate branch `origin/local-data-storage-as-transport` (a docs-only design, §6.8 of
     `transport_serialization_design.md`, storage carriers `(:store)`) is NOT part of E2 and no E2 work is done for it.
     When that design is later built it will add rows to the same three transport packs and to `Link.silica` and
     `Carrier.silica`. Rules for both streams: pack changes are added rows and new helper functions (do not reformat or
     reorder existing arms); `.ascomp` and `.golden_fail` goldens are never merged by hand (regenerate with the
     trial-then-update rule after a merge); the persistence sidecar goes in a new C file (not `silica_sockets.c`); error
     codes: E2418 is E2's, and the persistence design reuses E2412 to E2415 and E2417 and needs no new code.
  9. **Who:** Fable implements (compiler/stdlib and packs are compiler code); Sonnet writes the trials; Haiku
     builds and runs. ESP32-S3 and Nucleo are unaffected.
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
- **E7 (optional). Linux x86-64 Silica peer on aalang.org.** (Done in another form by L0 to L2, §5a: the Silica
  peer is built on the remote with the copied hosted compiler and talks to the Mac's Silica end.) The compiler
  targets Linux x86-64; build the peer there and replace the Erlang peer in a run, so Silica talks to Silica across the Internet. Needs the toolchain on the web
  host (probe first: do not install on a production machine without asking), so the build may instead be done on the
  Mac and the binary copied.
- **E8. Hardening and docs.** Reconnect after a drop, connect timeout, large frames (the 4-byte prefix is the limit),
  status lines in the transport and links designs, memory note.

## 5a. Silica on both ends, Mac and Linux x86-64 (replaces E1; done 2026-11-10)

The work for this stage is in `examples/transport_pairs/ethernet_remote/`: `run_mac_linux.sh`,
`dangerous_ethernet_silica_pair.silica`, `build_linux.sh`, `expected/` and `README.md`. Rules on the remote: everything
under `~/silica_demo/`, no sudo, no installs, no firewall or service change, and listeners on loopback only. The old
checkout `~/silica` there is not used.

- **L0. A Linux x86-64 toolchain on the remote. Done.**
  - **The toolchain.** The Mac checkout's `binaries/silica-compiler-linux_x86_64` (silica-999959, the hosted compiler
    of the 2026-11-08 trials) is copied to `~/silica_demo/toolchain`, about 23 MB. With it go the stdlib modules a
    `(:tcp)` program needs (Supervisor, wire_etf, wireframe, Carrier, dangerous_sockets, dangerous_tcp_carrier),
    `trial_wait_int64` and `compiler/stdlib/net` (`silica_sockets.c`). No bootstrap was needed.
  - **First check.** The current stdlib, including Carrier with the `transport` effect, compiled with that binary. The
    unchanged trial `ffi_addition/app_transport_tcp_loopback` built on the remote in 5 s and printed
    `ping 7 / pong 8 / done`, exit 0.
  - **Gaps.** silica-999959 predates `carried_on`, so the program names its carrier by module. `silica_sockets.c`
    needs `-D_GNU_SOURCE` with `-std=c11` on glibc, as the trials already pass. **Update 2026-11-10:**
    silica-999958-linux-x86_64 now has `carried_on`; see "Compiler problems found". **Update 2026-11-11:** the demos
    are switched to `carried_on` and `~/silica_demo/toolchain` holds 999958 (sha256 `bbf3fe21...`); see the
    "Carrier declaration" item of §5b.
- **L1. One program for both ends. Done.**
  - **Shape.** `dangerous_ethernet_silica_pair.silica` is a listener and a dialer in one program. The vocabulary is
    decision 5's: `(:request, id, (:accel, {x,y,z,at_ms}))` is answered by `(:reply, id, (:led, {which,on}))`
    (z > 256), and `(:request, id, :status)` by `(:reply, id, (:status, {host, uptime_ms, requests_seen}))`.
  - **Per-host differences.** The ports, the host name and the side are set at compile time by sed. The side is
    chosen by two blocks in the one source, one of which is a `{- -}` comment.
  - **Loopback self-test.** The logic was first checked on the Mac by running two copies against each other on
    loopback.
- **L2. `run_mac_linux.sh`. Done: five PASS runs (three in a row, then two more in a row after the last script
  change), about 37 s each with both builds.**
  - **What it does.** It builds both ends (the Linux end on the remote) and starts the Linux end, which listens on
    127.0.0.1:4550. One ssh connection carries `-L 127.0.0.1:4560 -> remote 4550` and
    `-R remote 127.0.0.1:4561 -> Mac 4551`. The script then runs the Mac end, which listens on 127.0.0.1:4551.
  - **Checks.** Both outputs are compared, sorted, with `expected/`, and both ends must exit 0.
  - **Teardown.** A trap tears everything down. The script then checks that neither side has a program, listener or
    forward left. That check reported none after every run.
  - **Timeout path.** `--timeout-check` runs without the Linux end: the Mac prints
    `timeout: dialer done no listener done no` and exits 5.
  - **Redialing.** The remote's dialer reaches the `-R` forward before the Mac listens. It redials (ssh logs
    `connect_to 127.0.0.1 port 4551: failed`) until the Mac listener is up, and nothing of that shows in the output.
- **L3. Docs. Done.** This section; the example's README; the entry in `examples/transport_pairs/README.md`.

### Compiler problems found

- **The hosted Linux compiler on a 3.9 GB host (no swap).** The `type_surface_cache` actor fails with
  `(:explicit, :out_of_memory)` on a unit with somewhat more types than the usb pair's Mac peer, and the driver
  reports a crash. The process stays near 500 MB RSS, and no system call fails.
  - **Likely cause.** The actor's state area outgrows the per-actor reservation (physical memory plus swap) in
    address space. This is inferred, not confirmed.
  - **Workaround.** Each end compiles only its own side.
  - **Fix needed.** In the Linux runtime's state-area reuse, or in the cache's reservation. The usb pair's Mac peer
    compiled there. The first version of this program, with both sides in one unit, did not.
  - **On 16 GB RAM (2026-11-10, the host temporarily upgraded): the crash does not occur.**
    - Both versions of the both-sides unit compile, with 999959 and with the new 999958, at about 640 MB peak RSS:
      the module-named version and the `carried_on` version (the latter with 999958 only).
    - This fits the reservation hypothesis: the limit grows with physical memory.
    - On a 4 GB host the limit is presumably still there. No runtime fix was made.
  - **Building the compiler itself needs the memory too.** The native build of the compiler on that host, at 380
    units, peaked at 4.4 GB RSS for one unit (`type_checker_expressions_actor_spawn`). Five more units were above
    2.7 GB and about a dozen above 2.3 GB. The attempt on the 3.9 GB host starved the machine.
- **`carried_on` on Linux x86-64: fixed 2026-11-10.**
  - **Compiler.** silica-999958-linux-x86_64 was built natively on the remote from this tree, with 999959 as the host
    compiler, in 48 min at low priority. It is installed as `binaries/silica-compiler-linux_x86_64`.
  - **Pack change.** `emitter/linux_x86_64/transport_pack.silica` got the Mac's carrier and link rows. Before that,
    the tree's Linux pack listed no carrier and no link, so a current-tree build still rejected `carried_on ... (:tcp)`
    with E2410.
  - **Results on the remote.** `app_transport_tcp_loopback_link` and a copy of it on `(:interface, "lo")` both print
    `ping 7 / pong 8 / done`. The whole linux_x86_64 trial tree passes, apart from goldens that were already stale
    with 999959.
  - **Not verified.** The fixed-point check (the new compiler rebuilding itself byte-identically) was not run.
  - **linux_aarch64.** Its pack has the same rows since 2026-11-11 (`emitter/linux_aarch64/transport_pack.silica`). Pending:
    a build on an AArch64 host (pix) and trial verification there.
- **Two defects seen in `usb_silica_pair` and worked around on both ends:** an inline nested tuple in `encode` is
  encoded flattened, and a `to_int64(...)` argument can clobber an earlier argument.

What is left on the remote: `~/silica_demo/toolchain` (the compiler and the stdlib sources), `~/silica_demo/ethernet_pair`
(the build) and the E0 files.

## 5b. One direct TCP connection, requests both ways (replaces the tunnels; 2026-11-10)

The work is in `examples/transport_pairs/ethernet_direct/`: `run_direct.sh`, `dangerous_ethernet_direct_pair.silica`,
`build_linux.sh`, `expected/` and `README.md`. The rules on the remote are §5a's, with two changes. The listener binds
every interface, on port 4550 only, and only during a run. Nothing changes in the firewall: the `ufw` rule (TCP 4550
from 157.201.64.9) was made by the user beforehand.

- **D0. The wildcard listener. Done.**
  - **What `"listen:<port>"` does.** `dangerous_tcp_carrier` binds `127.0.0.1` only, and that does not change.
  - **The new form.** `"listen:any:<port>"` binds `0.0.0.0:<port>`. It goes through
    `dangerous_sockets@tcp_listen_any`, the C wrapper `silica_sockets_tcp_listen_any` (`INADDR_ANY`), which shares one
    bind routine with `silica_sockets_tcp_listen`.
  - **Explicit only.** A program must write the form; nothing selects it by default. It is the stdlib's explicit
    wildcard until stage E2 binds `(:interface, name)` and `(:ethernet, n)` to one interface's address.
  - **Platforms.** The same C file builds on macOS and on glibc (with `-D_GNU_SOURCE`, as before).
  - **New trial.** `trials/transport_addition/app_transport_tcp_listen_any` opens `"listen:any:0"` and connects
    through 127.0.0.1. Its output is `ping 7 / pong 8 / done`, exit 0. It has Apple goldens only; the Linux goldens
    of the transport apps stay stale, as before.
  - **Regenerated goldens.** Adding the wrapper changes several existing goldens, though not what the loopback
    listener does:
    - the `dangerous_sockets` and `dangerous_tcp_carrier` `.ascomp` and `silica.link.scout` of
      `app_transport_tcp_listener`, `app_transport_tcp_loopback_link` and `ffi_addition/app_transport_tcp_loopback`;
    - four `error_enforcement_addition/dangerous_carrier_*` `.golden_fail` files: one more W4001 FFI warning, and
      shifted line numbers and offsets.
  - **Prerequisite for BEES.** This form and the direct dial to a non-loopback address are what Project BEES's
    milestone N1 needs. N1 is "a transport that is not loopback-only", and BEES lists that part as not started.
- **D1. One program, one connection, requests both ways. Done.**
  - **Vocabulary.** As in §5a: odd ids carry `(:accel, ...)` from the Mac, even ids carry `:status` from Linux.
  - **Roles.** The Linux end (the status side) listens on `"listen:any:4550"`. The Mac end (the accel side) dials
    `138.197.209.113:4550`.
  - **One connection actor per end.** After `:link_up` it sends that end's three requests and answers the peer's
    three. It decodes every incoming frame first as a reply and, if that is rejected, as a request.
  - **Why one connection.** The Mac is behind the campus NAT and cannot be dialed. TCP is full duplex, so one
    connection carries both directions.
  - **Side blocks.** As in §5a, the side is chosen by swapping two blocks with sed. Each end compiles only its own
    side, because of the Linux compiler's memory limit.
  - **Carrier declaration (2026-11-11).** The four ethernet examples declare their carrier with `carried_on`
    (`spawn_dangerous_carrier(wire, ...)`, `Carrier@mtu(wire)`, `Carrier@boundaries(wire)`), compiled on the Mac
    with `binaries/silica-compiler` and on the remote with silica-999958. The link choice:
    - `ethernet_remote` (ssh-tunnelled loopback ports): `carried_on wire: (:tcp) (:loopback);`;
    - `ethernet_direct` and its two Erlang siblings (direct TCP): a per-host line that `side_copy` rewrites,
      `(:interface, "en0")` on the Mac (the interface of its default route, read from `route -n get default`;
      `MAC_IFACE`), `(:interface, "eth0")` on the remote (its public interface, 138.197.209.113; `LINUX_IFACE`), and
      `(:loopback)` for `--local`.
    - **Not enforced.** A hosted link declaration binds nothing yet (`transport_links_design.md` §3.2; binding is
      stage E2). The compiler checks the declaration's tags only and does not look the interface up; the traffic is
      not pinned to `en0` or `eth0`. The address strings (`"listen:any:4550"`, the dial address) still decide where
      each end listens and dials. The sources and READMEs say so.
    - **Re-verified 2026-11-11 against `manager@aalang.org`:** `ethernet_remote` two runs and `--timeout-check`;
      `ethernet_direct`, `ethernet_mac_erlang_remote_silica` and `ethernet_mac_silica_remote_erlang` each `--runs 2`,
      `--timeout-check` and `--local`: all PASS, teardown clean after every run.
  - **Self-test.** `run_direct.sh --local` runs both sides on the Mac (`listen:any:45550`, dial 127.0.0.1).
- **D2. `run_direct.sh`. Done 2026-11-10 (20:2x UTC), after the remote was rebooted and temporarily upgraded to 16 GB / 8 CPUs.**
  - **Result against `manager@aalang.org` (Linux x86_64) over direct TCP 4550, no tunnels:** `--runs 2` PASS. The Mac end
    dialed `138.197.209.113:4550`; the Linux end (compiled on the remote with the Mac checkout's 999959 compiler,
    listening on `listen:any:4550`) accepted; 3 accel requests (ids 1, 3, 5) from the Mac were answered `led red
    on/off/on`, and 3 status requests (ids 2, 4, 6) from the remote went back over the same connection and were answered;
    both ends printed `pair complete: 3 replies matched, 3 peer requests answered`, exit 0, outputs MATCH `expected/`
    both runs. After each run: no program and no listener on 4550 on the remote, nothing left on the Mac.
  - (The text below was written before this run and is kept as the record of what the script does.)
  - **What it does.** It builds the Mac end, then waits until the remote is idle. A remote that does not answer
    ssh counts as busy. It stages and builds the Linux end under `~/silica_demo/ethernet_direct`, starts it under
    `timeout 90` and waits for `0.0.0.0:4550` in `ss`. It then runs the Mac end and compares both outputs, sorted,
    with `expected/`. After each run, and in an exit trap, it kills the remote program and checks that no program
    and no listener on 4550 is left. A remote check passes only if ssh answered.
  - **Verified on the Mac:**
    - `--local` passed three runs (one, then two in a row): both sides on the Mac, `listen:any:45550`.
    - `--timeout-check` passed: the Mac end dialed `138.197.209.113:4550`, was refused (reachable, nothing
      listening), printed `timeout: pair not complete` and exited 5.
  - **Not run yet.** The remote stopped answering ssh at about 19:36 UTC 2026-11-10, after another agent's compiler
    build overloaded it. Remote work was halted on the coordinator's instruction. No file was staged under
    `~/silica_demo/ethernet_direct` and nothing was started there. The real run (`--runs 2`) is still to do.
- **D3. Erlang on either end. Done 2026-11-10 (20:4x UTC).** Two siblings of `ethernet_direct`, same terms, same
  one connection: `examples/transport_pairs/ethernet_mac_erlang_remote_silica/` (Erlang dialer on the Mac, OTP 28;
  the Silica Linux end reused from `ethernet_direct`, not rebuilt) and `ethernet_mac_silica_remote_erlang/` (the
  Silica Mac end; an OTP 27 `gen_tcp` listener on the remote's `0.0.0.0:4550`). Both `--runs 2` PASS against
  `manager@aalang.org`, `--local` and `--timeout-check` PASS; every Silica frame equals Erlang's
  `term_to_binary(T, [deterministic])`; no program or listener left after each run.

### Security

**Security.** The `(:tcp)` carrier is plain TCP. It provides no authentication, no encryption and no peer identity: anyone who can reach a listening port can connect and send frames, and anyone on the path can read and change the bytes. Secure interchange is being built on top of this carrier in Project BEES (https://github.com/Silica-Language-and-Compiler/project-bees): SEMP/TRUST over mutual TLS 1.3 (ALPN `trust/1`, a certificate whitelist; the TLS engine is selected: OpenSSL on macOS and Linux, Mbed TLS on the NUCLEO-L476RG and the ESP32-S3) and an Erlang-compatible BEAM mode with cookie authentication. As of 2026-11-10 BEES's TLS and TRUST code is not built yet and its cookie handshake is in progress; both build on this carrier's non-loopback support. Today BEES's BEAM-mode wire runs between BEES nodes on loopback only, without the cookie digest (test-only, unauthenticated).

- **This pair.** The remote's source-address rule (TCP 4550 from 157.201.64.9 only) is the listener's only
  protection, and every host behind the campus NAT shares that address.
- **Limiting exposure.** The Linux end runs under `timeout 90` and closes its listener on completion. The script
  kills it on any exit and checks that no listener is left on 4550.
- **Readable bytes.** The bytes, synthetic readings and status records, cross the Internet in clear text.
- **A dropped connection attempt.** `silica_sockets_tcp_connect` has no connect timeout. A dial to a port whose
  firewall drops packets, instead of refusing them, would block the dialing carrier's thread until the OS gives up.
  This is stage E8's "connect timeout".

## 6. Risks

- **Web host is production**: the demo starts a user-level `erl` on loopback only, then kills it; no `ufw` or service
  changes, no files outside `~/silica_demo` on the remote.
- **Campus network** may block outbound ssh or idle-kill long tunnels: demos are short; `ServerAliveInterval` set.
- **`(:ethernet, 0)` on this Mac** is the 802.1X wired port; if it is down, the carrier fails with `:link_unavailable`
  by design. The Internet leg then uses Wi-Fi; the demo documents which interface carried it.
- **OTP 27 vs 26 ETF differences** (atom encoding, `NEW_FLOAT`): checked in E0.
- **Environment**: since 2026-11-10 the published `binaries/silica-compiler` (999925) has `carried_on`, and the
  demos use it. The published Linux x86-64 compiler (`binaries/silica-compiler-linux_x86_64`) was 999959, which does
  not. Since late 2026-11-10 it is 999958, which does.

## 7. Open questions

1. ~~Is a tunnel acceptable, or do you want a real public port?~~ **Answered 2026-11-10:** a real port. TCP 4550 is
   open in `ufw` from the Mac's address only, and the tunnels are dropped (§5b).
2. Should E7 (Silica on the remote) be in scope, and may I probe it for a C toolchain (`clang`/`ar`)?
3. Which demo content: the accel/LED terms (same as the serial demo) plus the `:status` request, or something else?
