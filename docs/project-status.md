---
title: Project Status
layout: default
permalink: /project-status/
---

# Where the Silica-based projects stand

*Status as of 2026-11-23.*

> **Pre-release.** Silica, BEES and to-silica are all pre-release. None of them has had a first release yet. A security review has been done, and the interfaces, wire contracts and file formats are stabilized, though they may see minor changes in the future. Try it, build on it for experiments, and tell us what breaks, but do not deploy it where failure matters.

This page is an update, from the Silica Steering Committee, on where the Silica-based projects it oversees stand. The committee works through the [Silica-Language-and-Compiler](https://github.com/Silica-Language-and-Compiler) GitHub organization ([website](https://silica-language-and-compiler.github.io/)), which is responsible for overseeing the Silica language and its standard components: the compiler, BEES, the transpilers, the book, and the CLI and examples repos. Everything below is public there. This is an overview; the repos have the details.

Two highlights for people who work with the BEAM:

- **`:etf` over Bluetooth LE.** A Silica program on an ESP32-S3 sends Erlang External Term Format frames over Bluetooth LE to a Silica program on a Mac, and gets replies. These are the same bytes `term_to_binary` produces, so the terms a microcontroller sends over its radio are ones a BEAM node already understands. The carrier has the same contract on the board and on the Mac, in either role (central or peripheral), and the same frames also travel over USB, UART, TCP and the ESP32-S3's Wi-Fi.
- **Talking to BEAM nodes.** BEES speaks standard Erlang distribution: EPMD, the version 6 handshake, cookie authentication, and TLS compatible with `inet_tls_dist`. A Silica node connects to stock OTP 27 and 28 nodes and exchanges messages with them in both directions, on one machine or between a Mac and a Linux box across a real network. Separately, Silica programs exchange plain `:etf` frames with Erlang peers over TCP and USB, with no distribution layer at all.

## Silica

[Silica](https://github.com/Silica-Language-and-Compiler/silica) is a systems language with actors, supervision and message passing in the BEAM tradition. Memory is region-based, there is no GC, and the compiler is written in Silica and builds itself.

**Where it runs**

- Hosted: macOS on Apple Silicon, Linux on AArch64, Linux on x86-64. The compiler reaches a fixed point on each.
- Boards with no OS: the ESP32-S3, and the STM32 Nucleo L476RG. On the Nucleo, programs can encode and decode `:etf` in memory and drive the UART through device actors, but there are no carriers yet, so no links.

**What you can do with it today**

- Actors, supervisors (including nested ones) and the usual Silica effect and memory rules, on all the targets above.
- Encode and decode to and from Erlang's External Term Format. `:etf` is the only wire format that exists so far. Tuples, records (as ETF maps), lists, atoms and other types round-trip, and the output is checked against `term_to_binary` on the Erlang side. CBOR, JSON and similar are designed, not built.
- Carriers declared with a `carried_on` line: TCP, UDP, serial, and an in-memory or file-backed log ("storage carrier") on the hosted targets. TCP includes mutual TLS in an example, though TLS is not part of the language.
- Examples under supervision, all over `:etf` and `:tcp`: a five-node full mesh, a six-spoke hub-and-spoke, and two hub-and-spoke groups joined by one link. These run as separate OS processes on one machine over loopback. A Mac and a Linux x86-64 machine have also run against each other over a direct TCP connection across the Internet, and Silica and Erlang nodes have exchanged the same frames.

**Physical links**

| Link | State |
| --- | --- |
| Ethernet | TCP and UDP, bound to an interface, on the three hosted targets. |
| Wi-Fi | Hosted: TCP and UDP on the three hosted targets; real Wi-Fi hardware has been exercised on a Raspberry Pi (`wlan0`). ESP32-S3: TCP over the chip's own radio (`carried_on lan: (:tcp) (:wifi, 0);`), dialling and listening, carrying `:etf` frames with the 4-byte length prefix `gen_tcp` `{packet, 4}` uses. No UDP on the board yet. |
| Serial / UART | Works on the ESP32-S3 (UART1) and as a serial carrier on the hosted targets. |
| USB | The ESP32-S3's USB-Serial-JTAG link to a Mac works, with Silica and Erlang peers. |
| Bluetooth LE | A `(:ble_gatt)` carrier works on the Mac and on the ESP32-S3, in both roles, carrying `:etf` frames between board and Mac. Not on Linux yet. |
| LoRa or other radio | Nothing yet. |

Some cautions. On the ESP32-S3, Silica's bare-metal runtime owns the chip and its actors run on one core, while Espressif's radio libraries (the Wi-Fi and Bluetooth controllers, NimBLE and lwIP) run as its guests on the other core. Silica does not have its own radio driver, since the radio's registers are undocumented. In the latest two-radio demo, Bluetooth ran 15 of 15 links but Wi-Fi only 1 of 15 before the board ran out of heap. That is an open item. Plain TCP carries no authentication or encryption, and the repo says so.

Where to look: the [README](https://github.com/Silica-Language-and-Compiler/silica), the [ROADMAP](https://github.com/Silica-Language-and-Compiler/silica/blob/main/ROADMAP.md), and `compiler/design_documents/transport_hosted_status.md` and `transport_ble_plan.md` for the link-by-link status.

## project-bees

[BEES](https://github.com/Silica-Language-and-Compiler/project-bees) is a transport and core management extension for Silica, written in Silica, that adds what the language itself leaves out. That includes Erlang distribution and mutual TLS, balancing actors across cores, and other BEAM behaviours. It leverages the full set of transport behaviours Silica provides. Any network topology you can build in Silica, such as a full mesh, hub and spoke, or linked hubs, you can build in BEES. On top of that it is the platform that BEAM-language applications are transpiled onto (the transpilers are in to-silica, below), where BEAM processes become Silica actors and the result runs as native code at the chip's full speed. It is not a BEAM emulator, and it does not load `.beam` files.

What is there now:

- Each BEES application chooses one of two modes, BEAM mode or SEMP mode. A node never runs both, because a network is only as secure as its least secure node.
  - **BEAM mode** is standard Erlang distribution (EPMD, cookie authentication, `inet_tls_dist`-compatible TLS). It has been tested live against stock OTP 27 and 28 nodes, including across machines.
  - **SEMP mode** is a secure overlay that keeps the Erlang way of calling functions on other nodes but replaces how nodes find each other, prove who they are and decide what they may do. A SEMP node runs TRUST, TEMPUS, or both as a bridge between them.
    - **TRUST** is for nodes that stay up, such as servers and services whose certificates are known ahead of time. Every connection is mutual TLS 1.3, peers must be on each other's whitelists, and nothing is allowed unless granted per peer and per function. Each call is its own short connection, with tokens making repeated calls quick, so there is no full mesh. A refused peer learns nothing, and peers that misbehave are scored and can be quarantined. A TRUST example is built: five nodes in a full mesh. In theory any network topology can be built with TRUST, since any topology is possible in Silica.
    - **TEMPUS** is for nodes that come and go, such as devices at the edge, which cannot be listed ahead of time. A sentinel admits a node on a short-lived signed token plus proof of the node's own key, and admitted nodes find each other by gossip sampling instead of a directory. Most of TEMPUS is built, with example clients in Python, Kotlin, Swift and Silica, and C# and Rust clients being written now.
    - **A bridge** runs both. Edge nodes reach stable services through it, and from there TRUST's rules apply: TEMPUS decides who may be a member, and TRUST decides what a member may do.
- A balancer that moves actors between cores the way the BEAM balances run queues, using `migrate_actor`. It is trialled on the three hosted targets, and an ESP32-S3 version of the example exists.

Still being developed for a full and complete BEES extension: TEMPUS configuration improvements and churn and soak measurements; the OTP `gen` call and cast protocol, so compiled code can call `gen_server`s on OTP nodes and the other way round; sending a node's logs through the storage carrier; reading `bees.config` at boot instead of at build time; TLS and transport on the boards, starting with the ESP32-S3; work stealing in the balancer; and an external security review before a first release. `development-plan/roadmap.md` has the detail.

## to-silica

[to-silica](https://github.com/Silica-Language-and-Compiler/to-silica) is where the language-to-Silica transpilers live. Each transpiler has two halves. The source side, the sender, is written by the language's owners, in any language they like: it parses their source, lowers their language's own semantics, and sends the program as frames over TCP under a published contract. The Silica side, the sink, is one shared Silica application that checks the frames and writes Silica. The people who know a language best handle its semantics, and every language lands on the same back end.

- Erlang, Elixir and Gleam senders exist as proofs of concept. They are templates and a working starting point for those languages' owners, not finished transpilers. Their two example programs each, with supervisors, convert with no gaps and were checked call by call against the original language. Haskell is only a reserved directory so far.
- Converted programs can run as nodes on BEES in its standard distribution mode. Three-node and five-node complete meshes exist in Erlang, Elixir and Gleam. A six-node mesh of Erlang, Elixir, Gleam and one hand-written Silica node ran on one Mac, with all thirty requests answered.
- It converts a subset, not whole programs. `APP_GAPS.md` lists what real applications ran into, and `HOWTO_language_creators.md` is the guide for a language owner who wants to write a sender.

## The Tao of Silica

[The Tao of Silica: Building a Society of Actors](https://github.com/Silica-Language-and-Compiler/The-Tao-of-Silica) is a book, written for people rather than compilers, about the path that led to Silica and the ideas behind it. Part I asks why Silica exists and tells how it got here. Part II sets out the ten principles the language is built on:

- Hide Nothing
- Say What You Do
- Share Nothing
- Fail Gently, Never Silently
- Leave Nothing to Chance
- One Way to Do Each Thing
- Make Danger Visible
- Refuse the Almost Right
- Respect the Machine
- Speak Across Every Boundary

It is a work in progress. Draft PDFs are attached to the repo's [releases](https://github.com/Silica-Language-and-Compiler/The-Tao-of-Silica/releases), and the LaTeX source is in the repo.

## What we would like from you

If you build for the BEAM and some of this looks useful, or wrong, tell us. We would especially like to hear which of the missing links or wire formats would matter to you, and what you would expect an Erlang node to be able to do with a Silica one. If you maintain a BEAM language, the sender for it is the part we hope you will write, and the proofs of concept are there to start from.

