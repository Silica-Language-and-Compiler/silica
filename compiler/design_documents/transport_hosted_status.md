# Hosted transport: status note for agents (2026-11-11)

Read this before reporting what the hosted Ethernet transport can do. Sources: `transport_hosted_ethernet_plan.md`
(§5a, §5b), `transport_links_design.md` (§3.2, §5.1), the packs `compiler/src/emitter/<TARGET>/transport_pack.silica`,
`compiler/stdlib/dangerous_tcp_carrier.silica`, `examples/transport_pairs/`.

## What works today (hosted)

- **Carriers.** `(:tcp)`, `(:udp)`, `(:serial)` as dangerous FFI actors over `compiler/stdlib/net/silica_sockets.c`
  (pack rows: `provides_carrier`, lines 62-69 of the Mac, x86-64 and AArch64 packs).
- **Links.** `carried_on <name>: (<kind>) (<link>...)` with `(:loopback)`, `(:interface, name)`, `(:ethernet, n)`,
  `(:wifi, n)`, `(:serial_port, path, baud)`. The compiler checks that the tag exists (E2412 if not).
- **IP between machines.** A Mac and a Linux x86-64 host exchange ETF frames over one direct TCP connection, no tunnel.
  The listening end writes the address string `"listen:any:4550"` (binds 0.0.0.0:4550, every IPv4 interface;
  `dangerous_tcp_carrier.silica:24`, `:190-196`); the dialing end gives `"<ip>:4550"` as the remote address
  (example: Mac dials `138.197.209.113:4550`). Plain `"listen:<port>"` still binds 127.0.0.1 only.
  Requests flow both ways over the one connection (plan §5b D1).
- **Interface binding (stage E2, built 2026-11-12 and pushed; verified by real runs 2026-11-13/14 except the items under "Not verified" at the end of this item).** Behaviour, all three hosted targets:
  no link: `listen:<port>` 127.0.0.1, `listen:any:<port>` 0.0.0.0, `listen:<ipv4>:<port>` that address.
  `(:loopback)`: `listen:<port>` 127.0.0.1, `listen:any` refused, `listen:<ipv4>` only inside 127.0.0.0/8, dials unchanged.
  `(:interface, n)`/`(:ethernet, n)`/`(:wifi, n)`: `listen:<port>` binds that interface's first IPv4 address, `listen:any`
  refused, `listen:<ipv4>` only one of that interface's addresses, dials leave from the interface's address.
  Refusal: the owner gets `(:link_down, :fault)` and the carrier ends `(:explicit, :link_unavailable)`; a malformed IPv4
  ends `(:explicit, :bad_address)`. Ethernet/Wi-Fi counting counts only interfaces holding an IPv4 address. UDP binds the same way (local forms `<port>`, `<ipv4>:<port>`, `any:<port>`, `silica_sockets_udp_bind_on`) and IPv4 literals use the strict dotted-quad parse (leading zeros rejected, `:bad_address` on all three platforms; Lee's ruling): verified by trials 2026-11-13/14. Compile-time E2418 (TCP and UDP) for a spawn plus refused literal in one function. A listener now
  reports `"peer:<ipv4>:<port>"` (getpeername). `ethernet_direct` declared `(:interface, "en0")` with `listen:any`, which
  is now refused, so it uses `listen:4550`. **Verified by runs:** loopback and refusal behaviour, `E2418`, on all three hosted targets. **Verified 2026-11-13/14:** the interface classifier (nix `enp5s0f0` ethernet, `lo` none; pix `eth0` ethernet, `wlan0` wifi; Mac `en0` ethernet, `en1` wifi, `en2`-`en7` and `bridge0` ethernet); `programmer_tools/transport_interface_link/run.sh` (Mac `lo0`; nix and pix `lo`); real non-loopback TCP binds across the LAN in three directions (nix .211 with a Mac client, pix .224 with a nix client, Mac .250 with a pix client; bare listen binds the interface's first IPv4 address; a 127.0.0.1 connect is refused); refusals (`(:wifi, 0)` with no wifi address on Mac, pix and nix, `(:ethernet, 1)`, unknown interface, `(:ethernet, 0)` with `listen:127.0.0.1`, an address not on the link's interface, `192.168.88.0300` gives `:bad_address`, `listen:any` under a link is `E2418`); real Wi-Fi on pix (`wlan0` 192.168.88.207 beside `eth0` .224, same subnet: `(:wifi, 0)` binds .207 and refuses .224, `(:ethernet, 0)` refuses .207, `(:interface, "wlan0")` binds .207, a client over `(:wifi, 0)` is seen by the peer as .207, UDP to a `(:wifi, 0)` receiver delivered all 5 numbers, `(:wifi, 1)` refused; strict `rp_filter` dropped nothing); UDP example `ethernet_direct_udp` Mac to nix over the LAN (both ends exit 0, outputs match `expected/`; `silica-999916` Mac, `silica-999949` nix); UDP link binding and the strict IPv4 parser by trials; full hosted trials green on all three targets (35296/35305/35305 passed, 0 failed, before the later work; 54/54 on the two suites touched afterwards). **Closed gaps:** the supervised retry is met by trial `dangerous_link_refused_supervised_retry` (2 restarts allowed, 3 refusals counted, supervisor gives up; 20 identical runs); listener round 2 is started by the failure reporter after `pong 8` (100 identical runs). **Not verified:** wireless on nix (no hardware; refusal only), the Mac's `en1` (inactive; refusal only), two IPv4 addresses on one interface, a second wired interface so `(:ethernet, 1)` succeeds, the UDP example over the Internet to aalang.org, the final regenerated goldens by hand review. **Open:** `(:sd_blocks)`/`(:flash_region)` hosted rows (`E2412`, not E2); BEES N1 check. Compiler fixes made along the way: SD-41 (`silica_rt_stack_trim_scratch` in `copy_all` and `evacuate`) and the interner fix (`strip_named_params_work` in `type_interner_surface_text.silica`). See the plan's E2 status.
- **No authentication, no encryption, no peer identity.** See the Security note in the plan (§5b) and
  `examples/transport_pairs/README.md`.

## Matrix

| Target | Carriers | Links | IP between machines | Interface binding |
| --- | --- | --- | --- | --- |
| apple_silicon_mac | tcp, udp, serial | loopback, interface, ethernet n, wifi n, serial_port | yes: verified (Mac dialed Linux x86-64, 2026-11-10/11) | E2 verified (loopback, refusals, classifier `en0` ethernet / `en1` wifi, LAN binds; Wi-Fi port inactive, refusal only) |
| linux_x86_64 | tcp, udp, serial | same rows as the Mac | yes: verified as the listening end on `manager@aalang.org` | E2 verified (loopback, refusals, classifier, LAN binds on nix; no wireless hardware, refusal only) |
| linux_aarch64 | same rows in the tree since 2026-11-11 (pack is identical to x86-64's apart from the header comment) | same | UNKNOWN: pack not built or run on an AArch64 host (pix) | built E2, verified on pix (full hosted integrate on the merged tree, then the transport_addition and ffi_addition suites with the rewritten TCP programs, all outputs matching .scout; assembly goldens regenerated afterward); classifier, LAN binds and real Wi-Fi (`wlan0`) verified 2026-11-13/14 |
| ESP32-S3_raw | serial, uart1, usb_serial_jtag (no tcp/udp) | `(:uart, 1, baud)`, `(:usb_serial_jtag)` | no (no Ethernet or Wi-Fi link; out of scope, links design §8) | n/a |
| STM32-L476RG_raw | none (`provides_carrier` is false for every tag) | none | no | n/a |

## Verified vs planned

- **Verified (run, per the plan's own records):** `examples/transport_pairs/ethernet_direct`, `ethernet_remote`,
  `ethernet_mac_erlang_remote_silica`, `ethernet_mac_silica_remote_erlang` between this Mac and `manager@aalang.org`
  (Linux x86-64): `--runs 2`, `--timeout-check`, `--local` PASS, re-verified 2026-11-11 (plan §5b). In-suite:
  `transport_addition/app_transport_tcp_listen_any` (loopback, Apple goldens only), `app_transport_tcp_loopback_link`
  (also run on linux_x86_64 incl. an `(:interface, "lo")` copy; links design §5.1 status). These example runs are
  outside `make integrate`; I did not re-run them for this note.
- **Not verified:** linux_aarch64 anything (pack rows only); the fixed point of the Linux x86-64 compiler (plan line
  180); Linux goldens of the transport trials are known stale in places (plan §5b D0).
- **Planned, not built:** connect timeout (E8); TLS/auth (Project BEES, not built as of 2026-11-10).

## Wording to use

- "The hosted `(:tcp)` carrier connects a Mac and a Linux x86-64 machine by IP: one end writes `listen:any:4550`, the
  other dials `<ip>:4550`. Verified Mac to Linux x86-64."
- "`(:interface, ...)`, `(:ethernet, n)`, `(:wifi, n)` bind the carrier to that interface's IPv4 address and refuse
  `listen:any` (E2, verified 2026-11-13/14: loopback, refusals, classifier, real LAN binds on all three hosted targets, real Wi-Fi on pix; not verified: wireless on nix and the Mac, two addresses on one interface)."
- "The linux_aarch64 pack has the same rows as linux_x86_64 (written 2026-11-11); not yet built or run on pix."
- Do not write "Linux AArch64 is not done" (stale) or "AArch64 works" (unproven).
