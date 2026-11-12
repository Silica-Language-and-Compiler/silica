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
- **Interface binding: declared, not enforced.** `(:interface, name)`, `(:ethernet, n)`, `(:wifi, n)` are accepted and
  checked, and spawn the same carrier. The socket is NOT bound to the interface address (no `getifaddrs`; none in
  `compiler/stdlib`), so traffic uses the host's default route, and an absent interface does NOT fail at open with
  `(:explicit, :link_unavailable)` today. The address strings decide where each end listens and dials. Planned: plan
  stage E2, links design §3.2; trials `link_interface_absent`, `link_family_absent` wait for it.
- **No authentication, no encryption, no peer identity.** See the Security note in the plan (§5b) and
  `examples/transport_pairs/README.md`.

## Matrix

| Target | Carriers | Links | IP between machines | Interface binding |
| --- | --- | --- | --- | --- |
| apple_silicon_mac | tcp, udp, serial | loopback, interface, ethernet n, wifi n, serial_port | yes: verified (Mac dialed Linux x86-64, 2026-11-10/11) | accepted, not enforced |
| linux_x86_64 | tcp, udp, serial | same rows as the Mac | yes: verified as the listening end on `manager@aalang.org` | accepted, not enforced |
| linux_aarch64 | same rows in the tree since 2026-11-11 (pack is identical to x86-64's apart from the header comment) | same | UNKNOWN: pack not built or run on an AArch64 host (pix) | UNKNOWN, expected same as above |
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
- **Planned, not built:** interface binding and `link_unavailable` at open (E2); `getpeername` (listener reports
  `"peer:accepted"`); connect timeout (E8); TLS/auth (Project BEES, not built as of 2026-11-10).

## Wording to use

- "The hosted `(:tcp)` carrier connects a Mac and a Linux x86-64 machine by IP: one end writes `listen:any:4550`, the
  other dials `<ip>:4550`. Verified Mac to Linux x86-64."
- "`(:interface, ...)`, `(:ethernet, n)`, `(:wifi, n)` are accepted and checked but do not bind the socket; traffic
  takes the default route. Binding is planned."
- "The linux_aarch64 pack has the same rows as linux_x86_64 (written 2026-11-11); not yet built or run on pix."
- Do not write "Linux AArch64 is not done" (stale) or "AArch64 works" (unproven).
