# Transport serialization: the `Transportable`, `WireFormat` and `Carrier` traits

**Status (2026-11-05): design only.** Nothing in this document exists in the compiler, its built-in modules or
the trials. It is the design that controls the addition of wire transport to Silica: how a Silica value is
prepared for transport over TCP/IP and other links, in a form that lets the BEAM External Term Format (ETF) be
the language's first wire protocol, lets the hardware of the ESP32-S3 port test board and Bluetooth carry the
same frames, and lets other common protocols be added to the language in the same way. Branch:
`binary-transport-support`.

**Transport is part of the language (Lee, 2026-11-05).** Serialization, the wire protocols and the carrier
contract are defined by the specification and shipped with the compiler, like actors, regions and the device
prims. They are not libraries a program adds on, and a new protocol is an addition to the language: a
specification section, an implementation in the compiler's shared tree, trials and a roadmap chunk, never a
program-level trait implementation. Specification §20.4 still keeps the host's sockets outside the language,
reached through Fifi; what crosses them is the language's business.

**Not every transport is in every compiler (Lee, 2026-11-05).** The language defines the vocabulary of wire
protocols and carriers; which of them a given compiler build provides is decided per target, board or hosted
environment, and recorded in that target's transport pack (§6.0). A program that names a carrier or protocol its
target does not provide is rejected by that target's emitter, as a hosted emitter rejects `peek` and `poke`.

**Authority.** The language specification wins where this document differs from it; the sections this design
relies on are named in §11. The device-actor specification governs every carrier that is hardware
([silica_device_actor_specification.md](silica_device_actor_specification.md)); the FFI wrapper specification
governs every carrier that is a foreign socket or a foreign Bluetooth stack
([silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md)). The board networking plan is
[esp32s3_board_peripherals_plan.md](esp32s3_board_peripherals_plan.md) §4.4 and §4.6, whose decision of
2026-10-01 ("connections and endpoints are actors; no sockets; credit-based flow control") this design adopts
unchanged.

**Related.** [ROADMAP.md](../../ROADMAP.md) chunks 9 (networking through Fifi), 10 (actor identity), 13 (byte
buffers and re-creation); specification §4 (types), §3.4.8 to §3.4.13 (traits), §12.1.6 (what may cross a
message), §15.1.4 (actor identity on the wire), §16.3 (message types), §20.4 (networking is not in the
language); [region_memory_safety_design.md](region_memory_safety_design.md) §18.7 and
[chunk15_stack_memory_design.md](chunk15_stack_memory_design.md) §3.6 (the type descriptors and the
type-directed walk this design reuses); the ETF reference,
[erl_ext_dist.html](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html).

---

## 0. Summary

Transport is three separable concerns, each a trait, and one compiler derivation:

| Concern | Trait | Who implements it | What it answers |
| --- | --- | --- | --- |
| What may cross | `Transportable` | the program, on its own inline types, with limits | which values can be encoded and decoded, and how large a decoded value may be |
| How bytes are spelled | `WireFormat` | the language: one built-in implementation per wire protocol, each a numbered subsection of the specification, ETF first; a program cannot add one | the byte encoding of every primitive and container |
| How bytes travel | `Carrier` | the language and its ports: one built-in implementation per carrier tag such as `(:tcp)`, `(:uart1)` or `(:ble_gatt)`, hosted carriers in the compiler's shared tree, hardware carriers in the port's board tree; a program cannot add one | message boundaries, size limit, delivery guarantees, addressing |

The compiler derives, for every `Transportable` type `T` and every format tag `F` a program uses,

```
encode(F, x: T) -> string
decode(F, bytes: string) -> (:ok, T) | (:rejected, atom)
```

by walking the type, exactly as the message copier, the planned `recreate` and the planned `copy_to` walk it. The
walk calls the `WireFormat` implementation for the tag at every leaf and container boundary. `decode` is a
validator in the sense of the FFI wrapper specification §7.7: it checks the declared limits before it reads,
rebuilds every value from the type's own literals, and returns either a structurally pure value or a rejection
atom, never partial data.

An encoded value is a **frame**: a `string`, which in Silica is an arbitrary byte sequence with an explicit
length (specification §4.1.6). A frame is a message part on every target and crosses the Fifi boundary as a
pointer plus a length (FFI wrapper specification §6.1), so no new value type is introduced. A `Carrier` moves
frames; a small framing module puts a length prefix on byte-stream carriers and splits frames into segments on
carriers with a maximum transfer unit.

Nothing here changes an emitter's code generation. The derivation and the protocols are in the shared front end
and the compiler's built-in modules, so every port gets them at once; the one per-port element is which carriers
a port can actually provide, and that is already decided by the device-actor and FFI rules (a hosted port rejects
`peek` and `poke`; a raw port has no sockets).

---

## 1. Requirements

1. **Prepare Silica values for transport over TCP/IP** on the hosted paths, where the socket is reached through
   Fifi inside a dangerous actor (specification §20.4, ROADMAP chunk 9), and over the board's links on the raw
   path, where the link is a device worker (board plan §4.6).
2. **Support the eventual BEAM ETF protocol trait.** A Silica program must be able to exchange terms with an
   Erlang or Elixir node: `term_to_binary` output decodes in Silica, and Silica's output decodes with
   `binary_to_term`. The full distribution protocol (handshake, control messages, node names) is a later design
   that must need nothing from the compiler beyond what this one provides (§7).
3. **Support traits for the hardware found on the ESP32-S3 BYU-Idaho board, and Bluetooth.** Every link the
   board has must be expressible as a carrier of the same frames, under the device-actor rules: USB-UART (the
   CP2102N bridge on UART0), USB-Serial-JTAG, **USB CDC on the dual-role USB OTG controller, in both the device
   and the host role** (Lee, 2026-11-05), UART1, SPI2, SPI3, I2C0, the SD card as storage, and Bluetooth Low
   Energy; with the board's sensors and actuators as sources and sinks of transportable values (§6).
4. **Support expansion to other common protocols, as language.** CBOR, MessagePack, JSON, Protocol Buffers and
   a Silica-native compact format must each be addable to the language as one more built-in `WireFormat`
   implementation and one more specification subsection, with no change to the derivation or to any program's
   `Transportable` declarations (§8).

---

## 2. Principles

1. **Transport is part of the language.** The three traits, the derivation, every wire protocol and the carrier
   contract are specified in the language specification and implemented in the compiler and its built-in
   modules. A program declares what it transports; it does not define how bytes are spelled or how a link
   behaves. A new protocol or carrier is a change to the language, made in the compiler's tree with its own
   specification text, trials and roadmap chunk. The surface this adds to the language is small: no new value
   types, no new effects, and no new syntax beyond the `impl Transportable for T { limits }` form the FFI
   wrapper specification already uses for `Recreatable` (§7.7).
2. **Three concerns, three traits, chosen independently.** A program picks a format and a carrier separately:
   ETF over TCP, ETF over UART1, CBOR over BLE. Nothing in a format knows about carriers, and nothing in a
   carrier knows about formats.
3. **The frame is a `string`.** It is the one value kind that is a message part everywhere (§12.1.6 bars `buf`
   from messages), crosses Fifi already, and is `Collectable`. Zero-copy owned-buffer frames on the board are an
   option recorded in §12, not the base design.
4. **Decoding is validation.** Every received byte is untrusted input (ROADMAP chunk 9). The derived `decode` is
   the only path from wire bytes to a Silica value, it is written by the compiler and never by the program, and
   it follows the re-creation rules of the FFI wrapper specification §7.7 step for step. A type that can be
   decoded without a size bound is rejected at compile time.
5. **The receiving type is static.** A frame carries whatever the format carries (ETF carries full tags; a
   native format may carry nothing) but Silica never discovers a type at run time: `decode` builds the type the
   binding names, and anything else is `(:rejected, _)`. This is specification §1.3.1 (explicit annotations) and
   §16.3 (messages are typed statically) applied to the wire.
6. **Formats and carriers are built-in tags.** A format is a one-atom tagged tuple type `(:etf)`, a carrier
   `(:uart1)`, exactly as a board-pack device is `(:esp32s3_uart)` (device specification §4.7, §4.9.1), and like a
   board-pack device tag the set is the language's: a program names a tag the language provides and cannot
   describe one of its own (E2409, §9.3), as it cannot describe a board-pack device (E2239). The implementation
   for a tag is selected at compile time, so there is no run-time dispatch in the encoder.
7. **Hardware stays behind device workers; sockets stay behind dangerous actors.** A carrier is an actor the
   program talks to with messages (§6.2). The `Carrier` trait describes the carrier's properties for the framing
   layer; it never touches a register or a socket itself.
8. **Shared front end, per-target transport set.** The derivation, every protocol's implementation and every
   compile-time check live in the shared compiler, so a program is accepted or rejected for the same language
   reasons on every port. Which carriers and protocols a build actually provides is the target's decision,
   listed in its transport pack (§6.0) and enforced by its emitter: a tag the pack does not list is a
   compile-time error on that target (E2410), exactly as the device prims are on a hosted target (device
   specification §10). A hosted compiler need not carry UART1; a board cross compiler need not carry JSON.

---

## 3. Architecture

```
  program value  x : T
        |
        v
  encode((:etf), x)            compiler-derived walk over T  (§4.4)
        |   calls wireformat@encode_int64((:etf), ...), wireformat@begin_tuple((:etf), ...), ...
        v
  frame : string               the encoded term, version prefix included
        |
        v
  wireframe@frame(frame, carrier@mtu((:uart1)))      framing: length prefix, segmentation (§5)
        |
        v
  cast(carrier_actor, (:tx, segment, self()))        the carrier actor contract (§6.2)
        |
        v
  device worker (UART1 FIFO, SPI2 data words, BLE characteristic)   or   dangerous actor (socket send)
  ==================================================== link =====================================================
  device worker / dangerous actor receives bytes  ->  (:rx, segment)  ->  wireframe@unframe  ->  frame : string
        |
        v
  decode((:etf), frame)        compiler-derived walk over T, limits checked first (§4.5)
        |
        v
  (:ok, x : T) | (:rejected, reason : atom)
```

The two walks are the same walk the message copier performs today (`terms/term_message_copy.silica`, KIND 0 to
7 descriptors) and the walk `recreate` and `copy_to` are designed to perform: type-directed, driven by a
descriptor built at compile time from the type string, following only references the type names. This design
adds two consumers of that descriptor, it does not add a second descriptor.

---

## 4. `Transportable`: what may cross

### 4.1 Declaration

A program establishes `Transportable` on an inline type with the `Recreatable` form of the FFI wrapper
specification §7.7, limits included:

```silica
// A sensor reading.
impl Transportable for (:reading, { x: int16, y: int16, z: int16, at_ms: uint64 });

// A command with a variable-sized payload: limits are required.
impl Transportable for { op: :set | :get | :clear, key: string, values: List[int64, normal] }
    { max_bytes: 4096, max_depth: 4, max_length: 256 };
```

- `max_bytes`: the largest frame `decode` will read, in bytes. `encode` never produces a larger frame; if the
  value would exceed it, `encode` fails (§4.4).
- `max_depth`: the deepest nesting `decode` will follow (tuples, records, lists and recursive slots count one
  level each).
- `max_length`: the longest list, string or buffer `decode` will build.
- A fixed-size type (no `string`, no list, no recursive slot) needs no limits: its bounds are its own. A
  variable-sized type without an applicable limit is a compile-time error (E2402 below).

**`Transportable` implies `Recreatable`.** `decode` is `recreate` applied to bytes rather than to a tainted
in-memory value, with the same limits and the same rejection atoms. A type declared `Transportable` therefore
also has `recreate` once ROADMAP chunk 13 lands; the two declarations use one syntax and one derivation, and a
type may be declared either or both.

**Where.** `impl Transportable for T { ... }` appears at the top level of any module. One declaration per type
per program; a second is a compile-time error. Component types need no declaration of their own: the walk
covers the whole type, and the limits apply to the whole value.

### 4.2 Which types are transportable

The whole of specification §4, type by type. "Encodes as" names the abstract wire form; §4.6 and each format
binding say how the format spells it.

| Type (spec section) | Transportable | Encodes as | Decoding rule |
| --- | --- | --- | --- |
| `unit` (§4.1.1) | yes | the unit value | accept only the unit form |
| `boolean` (§4.1.2) | yes | boolean | accept only the two booleans |
| `int8` to `int64`, `uint8` to `uint64` (§4.1.3) | yes | an integer; the walk widens to `int64` or `uint64` before the format sees it | narrow and range-check against the declared width; out of range is `:out_of_range` |
| `float16`, `float32`, `float64` (§4.1.4) | yes | a `float64`; the walk widens | narrow by IEEE round-to-nearest; never rejected for precision (decision 4, §12) |
| `char` (§4.1.5) | yes | an integer, the Unicode scalar value | reject surrogates and values above U+10FFFF: `:out_of_range` |
| `string` (§4.1.6) | yes | a byte sequence, length explicit | `max_length` applies; `utf8: true` on the declaration adds a validity check (`:bad_utf8`) |
| `atom` (§4.1.7) | yes | the atom's name | the name must be in the program's atom table (`:unknown_atom`); if the position's type is an atom union such as `:ok \| :error`, the name must be one of its literals (`:bad_variant`) |
| function types (§4.2.1) | **no** | | E2401 |
| tuple `(T1, ..., Tn)` (§4.2.2) | yes | a tuple of arity n | arity must match (`:bad_tag`) |
| tagged tuple `(:tag, T1, ..., Tn)` (§3.7) | yes | a tuple whose first element is the atom `:tag` | first element must decode to exactly `:tag` |
| recursive tuple with `ref?(L, S, rec)` slots (§4.2.2) | yes | the tuple, each slot either the empty marker or the nested tuple | rebuilt in a region the caller owns, depth-limited by `max_depth`; a cycle cannot occur because the slot is a tree (immutable regions, no back edges) |
| record `{ f1: T1, ..., fn: Tn }` (§4.2.3) | yes | a keyed record: n (name, value) pairs, names as atoms, in name order | every declared field exactly once (`:missing_field`, `:duplicate_field`), no others (`:unknown_field`); order on the wire is free |
| `List[T, S]` (§4.2.4) | yes | a sequence of elements | `max_length` applies; the result is a list in the caller's space `S` |
| inline sum types `A \| B \| ...` (§4.2.5, §3.7) | yes | the active variant, as itself | variants must be distinguishable by wire kind and, for tuples, by tag or arity: the same distinction a `case` makes (§3.4.2); otherwise E2404 at the declaration |
| `proc[...] T` (§4.3) | **no** | | E2401 |
| `lifetime`, `region(L, S)`, `ref(L, S, T)` outside a recursive slot, `buf(L, S, T, N)` (§4.4) | **no** | owned memory does not cross a wire | E2401. A buffer's bytes cross as a `string` built by the program |
| `device_window(L, D)` (§4.4.6) | **no** | | E2401 |
| `actor_ref` (§4.5.1) | yes, outbound | the 64-bit identity of §15.1.4 as two 32-bit fields, plus the node's name and creation (§4.6) | decodes only when the node and creation are this program's: otherwise `:foreign_actor`. A remote actor reference type is a decision for the distribution design (§7), not this one |
| `dangerous_actor_ref`, `device_actor_ref`, `supervisor_ref` (§4.5.1) | **no** | capabilities never leave the program | E2401 |
| `timer_ref` (§4.5.2) | **no** | | E2401 |
| `core_id`, `core_set` (§4.6) | **no** | | E2401 |
| SIMD vector types and `Pred` (§4.7) | **no** at first | | E2401; decision 6 in §12 records the fixed-width option |

A type is transportable when every component of it is. The error for a non-transportable component names the
path to it (`.values[]` or `.2`), as the lifetime errors name their path.

### 4.3 Derived functions

```
encode(F, x: T) -> string                                          proc[mem(normal)]
decode(F, bytes: string) -> (:ok, T) | (:rejected, atom)           proc[mem(normal)]
```

- `F` is a format tag literal, `(:etf)`. A variable is a compile-time error: the implementation is selected at
  compile time, as a register name is in `peek` (device specification §4.7).
- `T` is static. For `encode` it is the argument's type. For `decode` it is resolved from context exactly as
  `List[Collectable, S]` is (specification §8.2.4): the binding annotation, the parameter or return position, or
  the scrutinee of a `case`. A `decode` whose `T` cannot be resolved is E2403.
- `T` must be `Transportable` (E2401, E2402).
- Both allocate, so they are called inside a `sequence proc[mem(normal)]` block. They declare no other effect.
- `decode` never returns partial data, and `(:rejected, reason)` names the first check that failed.

**Rejection atoms** (a superset of §7.7's, fixed so trials can name them):

| Atom | Meaning |
| --- | --- |
| `:bad_version` | the frame does not start as the format requires (ETF: no 131 byte) |
| `:truncated` | the frame ended inside a term |
| `:trailing_bytes` | bytes remain after the term |
| `:bad_tag` | a wire tag that cannot inhabit the expected position (a float where an integer is expected, a tuple of the wrong arity, the wrong atom in a tagged tuple's first slot) |
| `:too_large`, `:too_deep`, `:too_long` | `max_bytes`, `max_depth`, `max_length` exceeded |
| `:out_of_range` | an integer or char outside its type |
| `:bad_utf8` | a string declared `utf8: true` is not valid UTF-8 |
| `:unknown_atom` | an atom name the program's atom table does not contain |
| `:bad_variant` | an atom or tuple that is none of the declared variants |
| `:missing_field`, `:duplicate_field`, `:unknown_field` | record key errors |
| `:foreign_actor` | an actor reference from another node or creation |
| `:unsupported` | a wire construct the binding does not implement (ETF: compressed terms, atom cache references, bit binaries, funs, ports, references, big integers wider than 64 bits) |

### 4.4 The derived encoder

For each `(F, T)` pair the compiler emits one function. In outline, for the record type of §4.1:

```
encode_etf_cmd(x) =
    parts <- [ wireformat@begin_term((:etf)) ]                       // "\x83" for ETF
    parts <- wireformat@begin_record((:etf), 3) : parts
    // fields in name order: key, op, values
    parts <- wireformat@record_key((:etf), :key) : parts
    parts <- wireformat@encode_string((:etf), x.key) : parts
    parts <- wireformat@record_key((:etf), :op) : parts
    parts <- wireformat@encode_atom((:etf), x.op) : parts
    parts <- wireformat@record_key((:etf), :values) : parts
    parts <- wireformat@begin_list((:etf), length(x.values)) : parts
    for each v in x.values: parts <- wireformat@encode_int64((:etf), v) : parts
    parts <- wireformat@end_list((:etf)) : parts
    parts <- wireformat@end_record((:etf)) : parts
    join_bytes(reverse(parts))
```

- The encoder accumulates **fragments** in a prepend-only list and joins them once (`join_bytes`, a builtin this
  design adds, §9.2). One allocation per fragment and one for the result: O(n) total, not the O(n²) of repeated
  `concat`. A `WireFormat` implementation therefore returns a `string` from every method and keeps no state; it is
  pure Silica and trivially testable.
- A later optimisation may let the derived code size the frame with a measuring pass and write into one buffer
  (chunk 15's `L_mc_measure` is the precedent). The trait does not change for that.
- Encoding is canonical: record fields in byte order of their names, no optional forms. Two equal values encode
  to equal frames, so a frame can be compared, hashed and used as a golden.
- `max_bytes` is checked on the result; exceeding it is a run-time failure of the calling actor with reason
  `(:explicit, :frame_too_large)`, since the program declared a bound its own value broke.

### 4.5 The derived decoder

The decoder is the same walk driven by a cursor over the input string:

1. `length_bytes(bytes) <= max_bytes`, else `:too_large`. Then `wireformat@begin_decode(F, bytes)` checks the
   version prefix and returns the first position.
2. Each container boundary reads its arity or length from the format, checks it against the limits before any
   element is read, and checks `max_depth` before descending.
3. Each leaf asks the format for the widest value (`decode_int64`, `decode_float64`, `decode_atom_name`) and the
   derived code narrows, range-checks, resolves the atom name through the program's table (§9.2), or matches the
   tagged tuple's tag.
4. For a keyed record the derived code reads n keys and, for each, dispatches on the field name to that field's
   decoder, keeping a seen-set in registers (a record has a bounded, known field count).
5. For a sum type the derived code calls `wireformat@peek_kind` and selects the variant by kind, then by tag or
   arity for tuples. E2404 guarantees at compile time that the selection is unambiguous.
6. `wireformat@end_decode(F, bytes, pos)` rejects trailing bytes.
7. The value is built directly in a fresh region the caller owns (recursive slots) or on the actor's stack
   (everything else), as `recreate` builds its result. No part of it refers to the input string.

**Where `decode` may be called.** Anywhere the input string is not external-danger-touched (bytes from a device
worker, from a file, from another actor). Where the input is external-danger-touched (the handler that receives an
FFI result cast, or an `external_danger` sequence), `decode` is permitted exactly where `recreate` is (FFI
wrapper specification §7.7), and its `(:ok, T)` result is structurally pure under the same rules: it may go into
state, casts and replies; it remains barred from `hot_swap`, command execution and code loading. Calling `decode`
on tainted bytes anywhere else is E2406.

### 4.6 The abstract wire forms

The walk speaks to a format in these forms only. A format binding (§4.7 for ETF, §8 for others) maps each form
to its own bytes.

| Form | Produced by the walk for |
| --- | --- |
| term prefix, term end | the whole frame |
| unit, boolean, integer (`int64`/`uint64`), float (`float64`), char, byte string, atom name | the primitives, after widening |
| actor reference: `{ node: string, creation: uint32, id: uint32, serial: uint32 }` | `actor_ref`, with `id` the child number and `serial` the position (specification §15.1.4 names this mapping) |
| tuple begin (arity) / end | tuples and tagged tuples |
| list begin (length) / end | lists |
| record begin (field count) / key (atom) / end | records, keyed layout |
| record begin (field count) / end, no keys | records, positional layout, when `record_layout(F)` is `:positional` |
| slot empty / slot present | `ref?(L, S, rec)` positions |

### 4.7 The ETF binding

`(:etf)` is the language's first wire protocol, built in. Encoding follows `term_to_binary/1` in OTP 26 and
later with no options (no compression, no atom cache, the newest tag of every family); decoding accepts
everything `binary_to_term/1` produces for the same values, including the older tags, so a frame from any
supported OTP release decodes.

| Silica form | Encode (tag) | Decode accepts |
| --- | --- | --- |
| term prefix | `131` | `131`; `131 80` (compressed) is `:unsupported`; a distribution header (`131 68/69/70`) is `:unsupported` here and handled by the distribution layer (§7) |
| unit | `SMALL_TUPLE_EXT` (104) arity 0, Erlang `{}` | arity-0 tuple only |
| boolean | `SMALL_ATOM_UTF8_EXT` (119) `true` / `false` | any atom tag spelling `true` or `false` |
| integer | `SMALL_INTEGER_EXT` (97) for 0..255; `INTEGER_EXT` (98) for the signed 32-bit range; `SMALL_BIG_EXT` (110) with up to 8 digit bytes otherwise (needed for `uint64` above `int64` max and for `int64` below the 32-bit range) | 97, 98, 110 with n <= 8 and the value in the target's range; `LARGE_BIG_EXT` (111) and wider bigs are `:unsupported` |
| float | `NEW_FLOAT_EXT` (70), IEEE big-endian | 70; `FLOAT_EXT` (99, 31-byte text) `:unsupported` |
| char | as integer | as integer, then the char range check |
| byte string | `BINARY_EXT` (109) | 109; `STRING_EXT` (107, a byte list) and `NIL_EXT` (106, the empty list) also decode into a `string`, so an Erlang charlist arrives as bytes; `BIT_BINARY_EXT` (77) `:unsupported` |
| atom name | `SMALL_ATOM_UTF8_EXT` (119) when the name is at most 255 bytes, else `ATOM_UTF8_EXT` (118) | 118, 119, and the deprecated 100 (`ATOM_EXT`, Latin-1) and 115 (`SMALL_ATOM_EXT`); `ATOM_CACHE_REF` (82) `:unsupported` here |
| actor reference | `NEW_PID_EXT` (88): node as an atom, id, serial, creation | 88; `PID_EXT` (103) with its 1-byte creation. The node atom must equal this program's node name and the creation this run's, else `:foreign_actor` |
| tuple begin / end | `SMALL_TUPLE_EXT` (104) for arity <= 255, else `LARGE_TUPLE_EXT` (105); no end bytes | 104, 105 |
| list begin / end | `LIST_EXT` (108) with the length, then elements, then `NIL_EXT` (106) as the tail; an empty list is `NIL_EXT` alone | 108 with a `NIL_EXT` tail (an improper list is `:bad_tag`); 106; `STRING_EXT` (107) decodes into `List[uint8, S]` and `List[int64, S]` and the other integer lists, element by element |
| record begin / key / end | `MAP_EXT` (116) with atom keys; `record_layout((:etf))` is `:keyed` | 116; any key order; keys must be atoms |
| slot empty / present | the atom `none` / nothing (the nested tuple follows) | the atom `none`, or a tuple |
| not produced | `PORT_EXT` family, `REFERENCE_EXT` family, `NEW_FUN_EXT`, `EXPORT_EXT`, `LOCAL_EXT`, `RECORD_EXT` | all `:unsupported` |

Notes.

- **Records are maps, not Erlang records.** An Erlang record is a tagged tuple `{name, F1, F2}`; a Silica record
  has field names and no tag, so the map is the faithful form, and `#{x => 1}` in Elixir or Erlang round-trips
  into `{ x: int64 }`. A program that must speak to an Erlang record declares a tagged tuple
  `(:name, T1, T2)` instead; that is what the receiving Erlang code pattern-matches anyway.
- **`unit` is `{}`.** Silica's unit is the empty tuple `()` (§4.2.2), so the empty Erlang tuple is its image.
  The alternative, the atom `undefined`, would collide with a legitimate atom.
- **Atoms are names on the wire and indices in memory.** Silica interns atoms at build time and creates none at run
  time (§4.1.7). Decoding therefore needs a run-time name-to-index table; §9.2 adds it, built only for programs that
  decode into an atom-typed position.
- **PIDs.** The program's node name and creation come from the distribution layer when there is one, and are
  `nonode@nohost` and 0 otherwise, which is what a standalone BEAM uses. Specification §15.1.4 already defines the
  two 32-bit halves for exactly this use.
- **Interoperability goldens.** The trials carry ETF byte goldens generated once with `erl` (`term_to_binary`) and
  checked in with the OTP version recorded; the Silica encoder must produce those bytes and the decoder must read
  them. A loopback trial with a live BEAM node runs only when `erl` is on the path and is not part of `make
  integrate`.

---

## 5. Framing

A frame is one encoded term. Carriers differ in whether they preserve boundaries and how much they move at
once, so a small built-in module, `WireFrame`, sits between `encode` and the carrier:

- **Length prefix.** On a carrier whose `boundaries` are `:stream` (TCP, UART, USB-Serial-JTAG), every frame is
  sent as a 4-byte big-endian length followed by the bytes. This is the framing of the BEAM distribution channel
  and of `gen_tcp` with `{packet, 4}`, so a Silica program and an Erlang program agree on it with no
  negotiation. The receiver's reassembly state is `{ expected: uint64, parts: List[string, normal] }`, bounded by
  the carrier owner's declared `max_frame`.
- **Segmentation.** On a carrier whose `mtu` is smaller than the frame (BLE GATT at 20 to 244 bytes, I2C
  transactions), the frame is split into segments of at most `mtu` bytes, each with a 4-byte header
  `{ frame_seq: uint16, index: uint16 (bit 15: last) }`, and reassembled in order. A carrier with
  `delivery` `:unreliable` cannot carry a segmented frame; `frame` rejects the combination at run time with
  `:frame_exceeds_mtu`, and the compile-time check of §9.3 rejects it when both sides are literals.
- **Datagram carriers** with a sufficient `mtu` (`:datagram` boundaries, as UDP or a BLE characteristic holding a
  whole frame) send the frame bare.

```
wireframe@frame(frame: string, mtu: uint64, boundaries: atom) -> List[string, normal]
wireframe@unframe(state: FrameState, segment: string, max_frame: uint64)
    -> (:more, FrameState) | (:frame, string, FrameState) | (:rejected, atom)
```

`WireFrame` is pure Silica over `byte_at` and `join_bytes` (§9.2). It is not a trait: there is one framing,
chosen by the carrier's properties, and formats never see it.

---

## 6. `Carrier`: how bytes travel

### 6.0 The transport pack: what a target provides

Each target has a **transport pack**, a per-target module beside its board pack
(`emitter/<TARGET>/transport_pack.silica`), of flat tables the compiler reads as data, maintained with the
compiler and never supplied by a program. It lists:

- the **carrier tags** the target provides, each with the `Carrier` property values of §6.1 and the module that
  implements the carrier actor;
- the **wire protocol tags** the target provides (§8), each with its implementing module;
- the per-target ceiling on `max_bytes` (decision 12, §12), if the target sets one.

The language's vocabulary of tags is the union of every target's pack and is what the specification documents;
the pack is the subset a given compiler version ships for a given environment. Adding a carrier or protocol to a
target is a row in its pack plus the implementation; removing one is deleting the row. The shared front end checks
every program against the full vocabulary (so a misspelt tag is E2408 everywhere), and the target's emitter
rejects a tag its pack does not list (E2410) with an error naming the module, the function, the tag and the
target, through the ordinary diagnostics, never a silent fall-through. The tables in §6.3 and §6.4 are the
carriers each path **may** provide; a path's port notes and its pack say which it **does**.

### 6.1 The trait

```silica
// Carrier.silica (built in): the properties the framing layer needs, one built-in implementation per carrier tag.
export trait Carrier;
export mtu/1;
export boundaries/1;
export delivery/1;
export addressing/1;

required {
    fn mtu(c: Carrier) -> uint64;            // largest segment, in bytes; 0 means unbounded
    fn boundaries(c: Carrier) -> atom;       // :stream | :datagram | :storage
    fn delivery(c: Carrier) -> atom;         // :reliable_ordered | :ordered_lossy | :unreliable
    fn addressing(c: Carrier) -> atom;       // :none | :endpoint | :characteristic | :block
}
```

`Carrier` is a **closed tag-keyed trait** (§9.1): its implementations are the language's, one per carrier tag,
written in the compiler's tree (hosted carriers) or the port's board tree (hardware carriers), and the body of each
method is a literal. A program names a tag; it cannot implement one. `WireFormat` is closed in the same way. The
tag identifies the carrier: `(:tcp)`, `(:uart1)`, `(:ble_gatt)`.

### 6.2 The carrier actor contract

A carrier is an actor. The program never calls a carrier function; it casts frames to the carrier actor and
receives frames from it. The vocabulary is fixed so that a program written against one carrier runs against
another, which is the board plan's "programs look identical on every target; only the board has actors all the
way down" (§4.6) made concrete. All messages are cast-only (`:no_reply`), as device workers require.

| Direction | Message | Meaning |
| --- | --- | --- |
| program to carrier | `(:open, owner: actor_ref, address: string)` | bind or connect; `address` is carrier-specific text (`"10.0.0.2:4369"`, `""` for a UART, a characteristic UUID for BLE) |
| program to carrier | `(:tx, segment: string, from: actor_ref)` | send one segment; consumes one send credit |
| program to carrier | `(:credit, n: uint32)` | the owner will accept n more `:rx` messages |
| program to carrier | `(:close)` | orderly close; the carrier ends after `:link_down` |
| carrier to owner | `(:link_up, info: string)` | connected or bound; `info` is carrier-specific (negotiated MTU for BLE, peer address for TCP) |
| carrier to owner | `(:rx, segment: string)` | one received segment; consumes one receive credit |
| carrier to owner | `(:tx_credit, n: uint32)` | the carrier can take n more `:tx` messages |
| carrier to owner | `(:tx_failed, reason: atom)` | a segment was not sent (`:no_credit`, `:link_down`, `:too_long`) |
| carrier to owner | `(:link_down, reason: atom)` | the link ended (`:closed`, `:reset`, `:timeout`, `:fault`) |

Flow control is credit-based in both directions (board plan §4.6, decided 2026-10-01): nothing is pushed without
credit, and the receive window a TCP carrier advertises follows the owner's `:credit` messages. Ordering per
sender is mailbox order. Failure is the carrier actor exiting with a reason, handled by links, monitors and
supervisors like any actor; a program that needs the link back restarts the carrier under its supervisor.

The ETF frames of §4 and the segments of §5 are `string`s, so every message above is `ActorMessage` by a
type-level `impl` in the built-in `actormessage.silica`, and a program writes no marker for them.

### 6.3 Carriers the hosted paths may provide

Each hosted target's pack lists which of these its build includes; a macOS build and a Linux server build need
not list the same rows (BLE on a headless server, for instance).

| Tag | Provided by | `mtu` | `boundaries` | `delivery` | Notes |
| --- | --- | --- | --- | --- | --- |
| `(:tcp)` | a dangerous actor over the chunk 9 Fifi socket wrappers | 0 | `:stream` | `:reliable_ordered` | the connection actor of board plan §4.6, hosted form. One actor per connection; a listener actor spawns one per accepted peer |
| `(:udp)` | the same wrappers | 65507 | `:datagram` | `:unreliable` | an endpoint actor per bound port |
| `(:serial)` | a dangerous actor over a Fifi wrapper of the host's serial port (termios on macOS and Linux) | 0 | `:stream` | `:reliable_ordered` | `address` is the device path (`/dev/cu.usbserial-10`, `/dev/cu.usbmodem101`) and line settings. This is the host end of the board's USB-UART, USB-Serial-JTAG and USB CDC carriers, so a Mac and the board exchange frames Silica to Silica with no Erlang in between |
| `(:ble_gatt)` | a dangerous actor over a Fifi wrapper of the host's Bluetooth stack (CoreBluetooth on macOS, BlueZ D-Bus on Linux) | negotiated ATT_MTU minus 3 (20 by default, up to 244 after MTU exchange; a characteristic value is at most 512 bytes) | `:datagram` | `:ordered_lossy` for notifications, `:reliable_ordered` for indications and writes with response | `address` is a characteristic UUID; `:link_up` carries the negotiated MTU |
| `(:unix_dgram)` | later, if [IPC_OS.md](IPC_OS.md) is ever built | per OS | `:datagram` | `:reliable_ordered` | cross-process actors on one host |

Hosted carriers are all Fifi, as specification §20.4 requires; the bytes they deliver are external-danger-touched,
so the owner's `decode` runs in the FFI result-cast handler and is the de-taint point (§4.5).

### 6.4 Carriers the ESP32-S3 path may provide

The ESP32-S3 cross compiler's pack lists which of these a given board release includes; a release built for a
badge without an SD card or a BLE module omits those rows. Every row is a device worker under the device-actor specification (one worker per controller, exclusive window,
`peek`/`poke` only inside the worker), over the board pack's generated register descriptions. Bytes a device worker
reads are not external-danger-touched, so `decode` may run anywhere the frame reaches.

| Tag | Hardware (board doc) | `mtu` | `boundaries` | `delivery` | State of the worker | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `(:uart0)` | **USB-UART**: the CP2102N bridge on the USB-UART jack to UART0 (GPIO43/44); the host sees a USB serial device | 0 | `:stream` | `:reliable_ordered` (no flow control: lossy under sustained load) | exists (`device_esp32s3_uart.silica`, `:puts`) | shared with the runtime console; frames interleave with prints, documented not prevented (plan principle 4). For bring-up and for programs that give up the console |
| `(:uart1)` | UART1 header (TX GPIO35, RX GPIO36) | 0 | `:stream` | `:reliable_ordered` | plan item N | **the first board carrier.** A host bridges it to its network, or an Erlang port program reads it directly: the ETF-over-UART demo (§10) |
| `(:usb_serial_jtag)` | the native USB-C jack through the fixed-function USB-Serial-JTAG controller | 0 | `:stream` | `:reliable_ordered` | exists (item F worker, `:puts`/`:getc`) | the second console; enumerates as 303A:1001. Device role only; shares GPIO19/20 and the internal PHY with the OTG controller (next row), so a program owns one of the two |
| `(:usb_cdc)` | **USB CDC, dual role (DRD)**: the native USB-C jack through the USB OTG controller, CDC-ACM class. Device role: the board enumerates as a CDC-ACM serial port on a host. Host role: the board is the USB host and talks to an attached CDC-ACM device (another board, a modem). The role is chosen at `:open` (`address` is `"device"` or `"host"`, optionally with a VID:PID to accept) and reported in `:link_up` | 0 (CDC-ACM is a byte stream; the stack packs it into 64-byte full-speed bulk packets below the carrier) | `:stream` | `:reliable_ordered` | not started: plan items K (interrupts), H (DMA) and L (the USB OTG stack: enumeration, descriptors, endpoints, control transfers, and the host-side enumeration for DRD) | the PHY is routed to the OTG controller instead of USB-Serial-JTAG by a board-pack register (eFuse `USB_PHY_SEL` 0 leaves it on USB-Serial-JTAG at reset), and the two controllers' windows are owned by different workers, so a program maps one, never both. Host role may need GPIO control of the board's `pd_switch` / `dm_pd_switch` power-role lines (plan §6, open). The carrier is the CDC-ACM layer of the item L stack; CDC-NCM/ECM over the same stack is the network link of plan §4.6, not this carrier |
| `(:spi2)`, `(:spi3)` | SPI2 (display) and SPI3 (SD card) controllers, both as master | 64 (the controller's data buffer) | `:datagram` | `:reliable_ordered` | SPI2 driver exists (item A) | a carrier only toward an SPI peer that speaks the §5 segment protocol; the display and the SD card are not peers (next row) |
| `(:sd_blocks)` | SD card on SPI3 | 512 | `:storage` | `:reliable_ordered` | plan item I | a **storage carrier**: `:tx` appends a frame to the block log, `:rx` replays frames from it. `address` is a block range. Logging ETF-encoded readings to the card is the use |
| `(:i2c0)` | I2C0 (SCL GPIO42, SDA GPIO41) as master | 32 | `:datagram` | `:reliable_ordered` | plan item G | `address` is the 7-bit peer address; the accelerometer (0x1C) is a sensor, not a carrier (§6.6) |
| `(:ble_gatt)` | see §6.5 | 20 to 244 | `:datagram` | per §6.3 | not started | same tag and contract as on the hosted paths |

Not carriers: GPIO, LEDC (buzzer), RMT (the 24 addressable LEDs), the display on SPI2, the buttons, the joystick
and battery analog inputs, the accelerometer. They are sources and sinks of transportable values (§6.6).

### 6.5 Bluetooth

Bluetooth Low Energy is a carrier with one tag, `(:ble_gatt)`, and one contract (§6.2), whatever provides it:

1. **Hosted paths:** a Fifi wrapper of the OS stack (§6.3). This is the first BLE carrier to build, because it
   needs no radio decision and gives the trials a peer.
2. **The board, through an external module:** a BLE module on the UART1 header running a transparent-serial
   firmware (an HM-10 class module, or a second ESP32 running Espressif's AT firmware) is reachable today under the
   device-actor rules: the `(:uart1)` worker carries the bytes and a small protocol actor turns the module's
   connection events into `:link_up` / `:link_down`. The pair presents as `(:ble_gatt)` to the program.
3. **The board, through the chip's own radio:** the ESP32-S3's BLE 5 controller and host exist only as closed
   ESP-IDF libraries that expect an RTOS (board plan §4.4). If the radio decision ever adopts them, they arrive
   as foreign code through Fifi on the board pack's C runtime (ROADMAP chunk 13), inside a dangerous actor, and
   present the same `(:ble_gatt)` carrier. Nothing in this design depends on that decision.

BLE's constraints are what the `Carrier` properties exist for: the 20-byte default payload makes segmentation
(§5) the normal case, notifications are `:ordered_lossy` so a segmented frame must use indications or writes
with response, and the MTU is only known after `:link_up`.

### 6.6 The board's sensors and actuators as transportable values

The board's hardware that is not a link appears in transport as typed values. The port ships, beside its board
pack, `Transportable` declarations for a small vocabulary of board values so that a BEAM node and a Silica program
agree on them without further declaration:

| Hardware | Value type | Direction |
| --- | --- | --- |
| accelerometer (MMA8452Q over I2C0) | `(:accel, { x: int16, y: int16, z: int16, at_ms: uint64 })` | board to peer |
| buttons (Left, Right, Down, Up, A, B, Point) | `(:buttons, { mask: uint8, at_ms: uint64 })` | board to peer |
| joystick and battery (analog) | `(:analog, { x: uint16, y: uint16, battery_mv: uint16 })` | board to peer |
| single LED, RGB LED | `(:led, { which: :single \| :red \| :green \| :blue, on: boolean })` | peer to board |
| the 24 addressable LEDs | `(:led_row, List[{ r: uint8, g: uint8, b: uint8 }, normal])` with `max_length: 24` | peer to board |
| buzzer | `(:tone, { hz: uint32, ms: uint32 })` | peer to board |
| display | `(:text, { row: uint8, text: string })` with `max_length: 64` | peer to board |

These are ordinary declarations in the port's `board_values.silica`; a program may ignore them and declare its own types, since `Transportable` is the one trait of the three a program implements.

---

## 7. Toward the BEAM distribution protocol

The distribution protocol is a later design (`beam_distribution_protocol_design.md`), built entirely above this
one: a `Distribution` protocol actor over a `(:tcp)` carrier with the `(:etf)` format. This design provides, and
the distribution design must not need more than:

| Distribution needs | Provided here |
| --- | --- |
| terms with and without the 131 prefix (after a distribution header, terms are bare) | `wireformat@begin_term` is a separate method, so the walk can be invoked without it; the distribution layer parses the header (`131 68`, `131 69/70` fragments) itself |
| 4-byte length framing on the channel | §5, the `:stream` framing |
| PIDs with node name and creation | §4.6 actor-reference form; the distribution layer supplies the name and creation and owns the mapping of foreign PIDs |
| atoms by name, including atom cache references | §9.2's name table; the atom cache (`ATOM_CACHE_REF`) is a per-connection table the distribution layer keeps and resolves before handing the term to `decode`, or declines in the handshake flags |
| control messages (`LINK`, `SEND`, `EXIT`, `UNLINK`, `REG_SEND`, `MONITOR_P`, `DEMONITOR_P`, `MONITOR_P_EXIT`, `SEND_SENDER`, `PAYLOAD_EXIT`, `ALIAS_SEND`, ...) as tagged tuples | ordinary tagged-tuple `Transportable` types declared in the distribution module |
| `REG_SEND` to a registered name | the atom-keyed registry (`cast_registered`, ROADMAP chunk 10) |
| the handshake (versions 5 and 6, capability flags, MD5 challenge over the cookie), EPMD (`ALIVE2_REQ`, `PORT_PLEASE2_REQ` on port 4369), tick heartbeats | pure Silica in the distribution module; MD5 is a small pure function; the random challenge needs an entropy source (an open point for that design) |
| remote actor references | a decision that design must make: a `remote_actor_ref` type, or a mapping of foreign PIDs onto local proxy actors. This design rejects foreign PIDs (`:foreign_actor`) until then |

---

## 8. Expansion to other protocols

A new wire protocol is an addition to the language. It consists of: a numbered subsection of specification
§16.4 giving its tag and its mapping table in the form of §4.7; one built-in `WireFormat` implementation in the
compiler's tree; its byte goldens and round-trip and rejection trials; and a roadmap chunk that closes when those
are green on every path. The abstract forms of §4.6 were chosen so that the common protocols map without a
change to the derivation, which is what keeps each such addition small:

| Format | Tag | Record layout | Fit | Notes |
| --- | --- | --- | --- | --- |
| CBOR (RFC 8949) | `(:cbor)` | `:keyed`, text-string keys | direct | definite lengths only at first (indefinite is `:unsupported`); tags 2/3 for 64-bit values outside the int range; `unit` as `null`, slot-empty as `null`; atoms as text strings |
| MessagePack | `(:msgpack)` | `:keyed`, string keys | direct | `bin` for byte strings, `str` for `utf8: true` strings; atoms as `str` |
| JSON (RFC 8259) | `(:json)` | `:keyed`, string keys | direct, with losses | text; byte strings as base64 text; integers above 2^53 lose precision in most readers, so encoding one fails the calling actor with `(:explicit, :json_precision)`; tuples as arrays; atoms as strings; `unit` as `null` |
| Protocol Buffers | `(:protobuf)` | `:numbered` | needs one addition | fields are numbered, not named: the `Transportable` declaration gains an optional `fields: [...]` list assigning numbers, and `record_layout` gains `:numbered`, under which the walk passes the number instead of the name. Tuples encode as nested messages with fields 1..n. Decision 7 in §12 |
| Silica native | `(:silica_native)` | `:positional` | direct | the fastest Silica-to-Silica form: no keys, no tags for scalars, a 64-bit structural hash of the type string as the term prefix so that a mismatched type is `:bad_version` rather than garbage. The shape word of §3.7 is **not** used: it is numbered per build |
| ASN.1 DER, Cap'n Proto, FlatBuffers | | | not planned | schema-driven formats with their own type languages; adding one would mean a translator in the language, not a `WireFormat` |

A protocol that is not a serialization of Silica values (a text line protocol, HTTP, MQTT's fixed headers) is
outside `WireFormat`: a program builds its strings and casts them to a carrier, and its payloads can be `(:etf)`
or `(:cbor)` frames. Whether such a protocol later becomes a language carrier or protocol of its own (an `(:mqtt)`
carrier over `(:tcp)`, say) is a roadmap decision taken protocol by protocol, under the same rule: in the
language, or not at all.

The test of the expansion requirement is concrete: the second protocol in the tree (CBOR, §10 phase 6) must be
added without a change to the derivation, to the trait, or to any trial program's `Transportable` declarations.
Its whole cost must be its specification subsection, its implementation module and its trials.

---

## 9. Compiler work

### 9.1 Language rule: tag-keyed traits

`DeviceDescription` already breaks the rule that `impl fn` appears only in the trait's own file (specification
§3.4.9, device specification §4.9 rule 1), and the board pack already closes a set of tags against program
descriptions (§4.9 rule 5, E2239). This design names both as one rule and applies it to three built-in traits:

> A **tag-keyed trait** is a built-in trait whose required methods take a one-atom tagged tuple type `(:tag)` as
> their first parameter, with one implementation per tag per program (a second is a compile-time error). A
> tag-keyed trait is **open** when a program may implement it for tags the language does not provide, and
> **closed** when every tag and implementation is the language's and a program `impl fn` for it is a compile-time
> error. `DeviceDescription` (device specification §4.9) is open for programmer-described devices and closed for
> board-pack devices; `WireFormat` and `Carrier` are closed: their implementations live in the compiler's shared
> tree and, for hardware carriers, in the port's board tree, and are maintained with the compiler.

The "data only" clause of the device description stays with that trait and with `Carrier`; `WireFormat`
implementations are ordinary code, because an encoder is code. The implementations being closed is what makes
transport part of the language rather than of a program: a format or carrier exists when the specification
defines it and the compiler ships it, and not otherwise. This goes into specification §3.4.9 as one paragraph,
replacing the `DeviceDescription`-specific sentence.

### 9.2 Builtins this design adds

All in the shared front end and the runtime of every port; none change an emitter's model.

| Builtin | Why |
| --- | --- |
| `byte_at(s: string, i: int64) -> uint8` | a string has no byte accessor today (the UART worker spells characters through a `case` table). Every decoder needs it. Bounds-checked; out of range is a run-time failure |
| `join_bytes(parts: List[string, S]) -> string` | one-allocation concatenation for the fragment lists of §4.4 and §5 |
| `bytes_of(parts: List[uint8, S]) -> string`, `byte_string(n: uint64, bytes: ...)` form to be settled | building a short fragment from computed bytes (a tag byte and a big-endian length). The ETF binding is written against whichever form is chosen; decision 8 in §12 |
| `float64_to_bits(f: float64) -> uint64`, `float64_from_bits(b: uint64) -> float64`, and the `float32` pair | IEEE bytes on the wire. `float16` widens through `float32` |
| `atom_name(a: atom) -> string` | encode atoms by name. The runtime already keeps the names for printing; this exposes the table |
| `atom_of_name(s: string) -> (:ok, atom) \| :none` | decode atoms by name. The compiler emits a sorted name table with binary search only for programs that decode into an atom-typed position, so programs that never do pay nothing |

Byte order: ETF, CBOR and the native format are big-endian, every port is little-endian, and the bindings assemble
bytes explicitly. No byte-swap builtin is added.

### 9.3 Compile-time checks (numbers provisional, assigned by the diagnostics table at implementation)

| Code | Check |
| --- | --- |
| E2401 NotTransportable | a component of `T` is not transportable (§4.2); names the path |
| E2402 TransportableLimitRequired | `T` is variable-sized and the declaration gives no applicable limit |
| E2403 DecodeTargetUnresolved | `decode`'s result type cannot be resolved from context |
| E2404 SumVariantsIndistinguishable | two variants of a sum in `T` share wire kind and tag or arity |
| E2405 TagKeyedDuplicate / E2408 TagKeyedUnknown | two implementations for one format or carrier tag; a format or carrier tag with no implementation visible from the calling module |
| E2406 DecodeOnTaintedOutsideHandler | `decode` on external-danger-touched bytes outside an FFI result-cast handler or `external_danger` sequence |
| E2407 FrameExceedsMtu | `encode` of a type whose fixed size exceeds a literal carrier's `mtu` on an `:unreliable` carrier |
| E2409 ClosedTraitImplemented | a program `impl fn` for `WireFormat` or `Carrier`, whatever the tag; the counterpart of E2239 for board-pack devices |
| E2410 NotProvidedOnTarget | a carrier or protocol tag the target's transport pack does not list; raised by the target's emitter, as the device-prim rejection of device specification §10 is, wherever the tag appears, including in a function nothing calls |
| W2401 | every `impl Transportable` is reported as an advisory warning, as every `impl Recreatable` is (§7.7 auditability), because each is a point where foreign bytes become values |

### 9.4 Where the work lands

| Area | Work |
| --- | --- |
| lexer, parser | `impl Transportable for T { k: v, ... };` (the §7.7 form; shared with `Recreatable`); nothing else |
| trait checker (`trait_checker_core.silica`, `type_checker/traits/`) | the tag-keyed rule of §9.1 with its open and closed cases; `WireFormat` and `Carrier` as closed built-in traits beside `DeviceDescription`; E2409 |
| type checker | `encode` / `decode` as context-typed builtins (`type_checker_builtin_signatures.silica`, the `Collectable` resolution path in `type_checker_lists.silica` as the model); E2401 to E2408 |
| SIR generator | the derivation of §4.4 and §4.5 as ordinary SIR, driven by the type descriptor of `terms/term_message_copy.silica`; shared with the `recreate` derivation of chunk 13 and the `copy_to` of chunk 15 when they are built, so that one walker serves all three |
| emitters | no code-generation change: the derived code is ordinary functions. Each emitter reads its target's transport pack and rejects tags the pack does not list (E2410), the same shape as its device-prim rejection. The runtime of each port gains the six builtins of §9.2 (small; `byte_at` and `join_bytes` are a few instructions each) |
| per-target transport packs (`emitter/<TARGET>/transport_pack.silica`) | one per target, flat tables (§6.0); the port notes record what each build provides; the porting checklists gain a "transport pack" item |
| built-in modules (`compiler/stdlib/`, the language's modules shipped with the compiler, as `Supervisor.silica` and `DeviceDescription.silica` are today) | `Transportable.silica` (marker, like `Register32.silica`), `WireFormat.silica`, `Carrier.silica`, `WireFrame.silica`, `wire_etf.silica` (the ETF protocol, pure Silica), `actormessage.silica` entries for the §6.2 vocabulary. Each later protocol is one more `wire_<tag>.silica` here |
| hosted carriers (the compiler's shared tree) | `(:tcp)` and `(:udp)` connection and endpoint actors over the chunk 9 wrappers; `(:ble_gatt)` over a CoreBluetooth wrapper on macOS and a BlueZ wrapper on Linux, each a `dangerous_` module with its sidecar and exposure source (FFI wrapper specification §13, §14), maintained with the compiler |
| board carriers (the port's board tree, beside the board pack) | the `(:uart1)` worker (plan item N) with the carrier contract; the contract retrofitted onto the existing UART0 and USB-Serial-JTAG workers; `(:i2c0)` and `(:sd_blocks)` as plan items G and I are done; `board_values.silica` (§6.6) |

---

## 10. Order of work and what closes each phase

Apple Silicon first, Linux in lock-step, the board when its path gets there (ROADMAP rule). Each phase ends green
on every suite with goldens refreshed under the usual rule, and a hosted phase ends in a fixed point.

| Phase | Delivers | Closes when |
| --- | --- | --- |
| 0 | the builtins of §9.2; the tag-keyed rule of §9.1; the `impl Transportable for T { ... }` syntax; `Transportable`, `WireFormat`, `Carrier` marker and trait files; an empty transport pack per target and the E2410 rejection in each emitter | trials for each builtin (byte access, join, float bits, atom names both ways); error trials for E2405, E2408 and E2410 (a tag absent from the target's pack) |
| 1 | the derivation for every type of §4.2 with the `(:etf)` binding, scalars and containers, on Apple Silicon; the ETF byte goldens generated with `erl` | `transport_addition` suite: every row of §4.2 round-trips (`decode(encode(x)) == x`); every rejection atom of §4.3 has an error trial; the `term_to_binary` goldens match byte for byte; E2401 to E2404 and E2406 trials |
| 2 | Linux AArch64 and x86-64 lock-step | the same suite green on both; fixed points |
| 3 | `WireFrame`; the carrier contract; `(:tcp)`, `(:udp)` and `(:serial)` carriers over chunk 9 (its prerequisite); the hosted BEAM demo: a Silica program connects to a BEAM node's `gen_tcp` listener with `{packet, 4}` and exchanges terms | loopback trials Silica-to-Silica; a scripted `erl` peer trial run outside `make integrate` |
| 4 | the board: `(:uart1)` carrier worker, the contract on the existing console workers, `board_values.silica`; the ETF-over-UART demo: accelerometer and button readings arrive in an Erlang shell through a port program on the host | board suite trials for the worker; the demo recorded in `board/README.md` as the other apps are |
| 5 | `(:ble_gatt)` on macOS and Linux through Fifi; the board over an external UART BLE module (§6.5 item 2) | a Silica peripheral on one host and a Silica central on another exchange segmented frames; the board's readings reach a phone or laptop over BLE |
| 6 | `(:cbor)` as the second protocol: its §16.4 subsection, `wire_cbor.silica`, goldens | added without a change to the derivation or the trait; the `transport_addition` suite runs its round-trip rows under both tags from one source |
| later | `(:msgpack)`, `(:json)`, `(:silica_native)`, `(:protobuf)` after decision 7; the distribution protocol design (§7); `(:usb_cdc)` in the device role when plan item L lands and in the host role when its host-side enumeration does; `(:sd_blocks)` and `(:i2c0)` carriers when plan items I and G land; `(:unix_dgram)` if IPC_OS is built | each with its own trials; `(:usb_cdc)` device role proven by the Mac's `(:serial)` carrier against `/dev/cu.usbmodem*`, host role by two boards back to back |

**Proposed ROADMAP row** (for Lee to place; chunk numbers are identifiers, not an order):

> | 16 | **Transport serialization.** `Transportable` with limits, the compiler-derived `encode` and `decode`,
> the `WireFormat` trait with the ETF binding, the `Carrier` trait and actor contract with framing, hosted
> TCP/UDP/BLE carriers through Fifi and the board's UART1 carrier worker; CBOR as the second protocol. All of
> it language, specified in §16.4 and shipped with the compiler.
> **Prerequisites:** chunk 9 (sockets) for the hosted carriers; chunk 13 shares the derivation.
> | [transport_serialization_design.md](compiler/design_documents/transport_serialization_design.md) | Every
> type round-trips through ETF against `term_to_binary` goldens; every rejection atom has a trial; a Silica
> program exchanges terms with a BEAM node over TCP; the board's readings reach an Erlang shell over UART1; a
> second protocol lands as a specification subsection and one module, with no change to the derivation. |

---

## 11. Specification changes

| Section | Change |
| --- | --- |
| §3.4.9 | the tag-keyed trait paragraph of §9.1, replacing the `DeviceDescription`-only sentence |
| §4.1.6 | `byte_at` beside `length_bytes` as a user-available byte operation; §5.3 and §22.7 list the new string builtins |
| §4.1.7 | `atom_name` and `atom_of_name`; the sentence "No atom is created at run time" stands: `atom_of_name` only finds existing ones |
| §15.1.4 | already names the two 32-bit halves for the wire; add that `actor_ref` encodes as (node, creation, child number, position) and decodes only for this node |
| new §16.4 "Wire transport" | normative: the `Transportable` declaration, `encode` and `decode` signatures, the rejection atoms, where `decode` may be called, the abstract wire forms of §4.6, the `Carrier` trait and actor contract of §6, and the framing of §5. One numbered subsection per wire protocol, §16.4.1 being ETF with the table of §4.7; each later protocol adds the next subsection. One subsection on the transport pack (§6.0): the full vocabulary of carrier and protocol tags, the rule that a target provides a subset chosen per board or hosted environment, and E2410 |
| [porting_for_os_free_targets.md](porting_for_os_free_targets.md) §10 and the hosted porting checklists | the transport pack as part of the board-pack contract and of a hosted port |
| §20.4 | sockets stay outside the language, reached through Fifi, as written. Add: "Transport is part of the language: the preparation of values for a link, the wire protocols and the carrier contract are defined in §16.4 and shipped with the compiler. A new wire protocol is an addition to this specification, not a library." |
| §1.2 design principles | one line: transport and its protocols are language, as actors and regions are |
| §22 | the builtins of §9.2 |
| FFI wrapper specification §7.7 | `Transportable` implies `Recreatable`; `decode` is listed as the second validator, with the same call-site rule |
| device specification §5.2 | client messages to a carrier worker follow the §6.2 contract |

---

## 12. Decisions proposed for Lee, and open questions

**Decided (Lee, 2026-11-05): transport is part of the language, not a library.** New protocols are added to the
language, in the compiler and the specification, never as program-level implementations. §1, §8, §9.1 and §11
carry this decision; `WireFormat` and `Carrier` are closed traits because of it.

**Decided (Lee, 2026-11-05): the transport set is per target.** Support for each transport type need not be in
every compiler version; what a build includes is decided by its board or hosted environment and recorded in its
transport pack (§6.0), with E2410 for anything else. The tables of §6.3 and §6.4 are menus, not promises.

1. **Frames are `string`s on every target (proposed).** The alternative, owned `buf` regions moved between actors
   on the board (board plan §4.6 "buffers move, never copy"), saves a copy per hop on the board but is barred from
   messages by specification §12.1.6 as written and does not cross Fifi. Proposed: strings now; an owned-buffer
   frame variant for the board when chunk 13 and chunk 15 have settled what a moved buffer in a message means.
2. **Records encode as ETF maps, not tagged tuples (proposed, §4.7).** A program that must match an Erlang record
   declares a tagged tuple.
3. **`unit` is the empty tuple `{}` (proposed, §4.7).**
4. **Narrowing floats round, never reject (proposed, §4.2).** Rejecting would make a float32 field unable to
   receive most doubles, which is useless; range overflow becomes infinity under IEEE and is accepted.
5. **Unknown atoms are rejected, not created (required by §4.1.7).** A program that must accept open-ended atom
   vocabularies declares the field `string` and converts explicitly. This is the one visible difference from
   `binary_to_term`, which creates atoms (and is why Erlang offers `safe`).
6. **SIMD vectors are not transportable at first.** The fixed-width NEON types could encode as tuples of their
   elements; the scalable SVE types have no wire-stable width. Deferred.
7. **Protocol Buffers need field numbers.** Add `fields: [...]` to the declaration and `:numbered` to
   `record_layout` when `(:protobuf)` is taken up (§8), not before.
8. **The spelling of a computed-bytes fragment builtin (§9.2).** `bytes_of(List[uint8, S])` is simplest and
   costs a list per fragment; a fixed-arity `byte_string(n, b0, b1, ...)` form is cheaper for the common one-to-nine-byte
   fragments. The ETF binding needs one of them before phase 1.
9. **Error-code numbers** (§9.3) are provisional until the diagnostics table assigns them.
10. **Open: the node name and creation of a standalone program** (`nonode@nohost`, 0 proposed), and where a
    program that is also a distribution node sets them (the distribution design).
11. **Open: whether `encode` may be called on external-danger-touched data.** Proposed no: a tainted value is
    re-created first, then encoded, so taint never reaches the wire unexamined.
12. **Open: the maximum `max_bytes` on the board.** A frame and its decoded value both live in the roughly 170 KB
    heap ([actor_memory_budget_plan.md](actor_memory_budget_plan.md)); a per-target ceiling checked at the
    declaration (as the board checks stack budgets) would turn a run-time heap exhaustion into a compile-time
    error.

---

## 13. Worked example: readings to a BEAM node, commands back

A hosted Silica program streams accelerometer readings to an Erlang shell over TCP as ETF, and accepts LED
commands from it. The same owner actor runs on the board over UART1 with a two-line change (§13.5).

### 13.1 The shared vocabulary

```silica
// readings.silica: the values both ends agree on. Fixed-size, so no limits are needed.
impl Transportable for (:accel, { x: int16, y: int16, z: int16, at_ms: uint64 });
impl Transportable for (:led, { which: :single | :red | :green | :blue, on: boolean });
```

### 13.2 The owner actor

The root module carries the `dangerous_` prefix because the program depends on the TCP carrier, which is a
Fifi wrapper (FFI wrapper specification §3.1). Nothing else about it is dangerous: the owner is an ordinary
actor and never touches the socket.

```silica
// dangerous_telemetry.silica
use carrier;        // the Carrier trait and its (:tcp) implementation
use wireframe;      // length-prefix framing for :stream carriers
use wire_etf;       // the (:etf) WireFormat implementation
use tcp_carrier;    // the (:tcp) connection actor (a dangerous_ module behind it)

export owner/2;

// State: the carrier actor, the send credits it has granted, and the framing reassembly state.
// Messages: the carrier contract of §6.2, plus (:sample, ...) from whoever produces readings.
fn owner(msg: (:link_up, string) | (:tx_credit, uint32) | (:rx, string) | (:link_down, atom)
            | (:sample, int16, int16, int16, uint64),
         state: { link: dangerous_actor_ref, credits: uint32,
                  rx: { expected: uint64, parts: List[string, normal] } })
    -> { link: dangerous_actor_ref, credits: uint32,
         rx: { expected: uint64, parts: List[string, normal] } } {
    case msg of {
        (:link_up, _info: string) -> state;
        (:tx_credit, n: uint32) -> { link: state.link, credits: state.credits + n, rx: state.rx };
        (:sample, x: int16, y: int16, z: int16, at: uint64) if state.credits > 0 -> send_reading(state, x, y, z, at);
        (:sample, _x: int16, _y: int16, _z: int16, _at: uint64) -> state;   // no credit: the reading is dropped
        (:rx, segment: string) -> receive_segment(state, segment);
        (:link_down, reason: atom) -> fail_self((:explicit, reason))
    }
}
```

**Sending.** `encode` builds the frame; `wireframe@frame` puts the 4-byte length in front because `(:tcp)` is a
`:stream` carrier with `mtu` 0, so there is exactly one segment; the cast moves it to the carrier.

```silica
fn send_reading(state: { link: dangerous_actor_ref, credits: uint32,
                         rx: { expected: uint64, parts: List[string, normal] } },
                x: int16, y: int16, z: int16, at: uint64)
    -> { link: dangerous_actor_ref, credits: uint32,
         rx: { expected: uint64, parts: List[string, normal] } } {
    sequence proc[mem(normal), concurrency]
        frame: string <- encode((:etf), (:accel, { x: x, y: y, z: z, at_ms: at }));
        segments: List[string, normal] <- wireframe@frame(frame, carrier@mtu((:tcp)), carrier@boundaries((:tcp)));
        cast_dangerous(state.link, (:tx, head(segments), self()));
    produces
        pure { link: state.link, credits: state.credits - 1, rx: state.rx }
    end
}
```

**Receiving.** The carrier's bytes come from Fifi, so this handler is the FFI result-cast handler in which `decode`
is permitted (§4.5); its `(:ok, ...)` result is pure and may go anywhere. The binding annotation on `decoded` is
what tells the compiler which type to build.

```silica
fn receive_segment(state: { link: dangerous_actor_ref, credits: uint32,
                            rx: { expected: uint64, parts: List[string, normal] } },
                   segment: string)
    -> { link: dangerous_actor_ref, credits: uint32,
         rx: { expected: uint64, parts: List[string, normal] } } {
    sequence proc[mem(normal), concurrency]
        unframed: (:more, { expected: uint64, parts: List[string, normal] })
                | (:frame, string, { expected: uint64, parts: List[string, normal] })
                | (:rejected, atom)
            <- wireframe@unframe(state.rx, segment, 4096);
        next: { link: dangerous_actor_ref, credits: uint32,
                rx: { expected: uint64, parts: List[string, normal] } } <- case unframed of {
            (:more, rx2: { expected: uint64, parts: List[string, normal] }) ->
                { link: state.link, credits: state.credits, rx: rx2 };
            (:frame, frame: string, rx2: { expected: uint64, parts: List[string, normal] }) ->
                apply_command(frame, { link: state.link, credits: state.credits, rx: rx2 });
            (:rejected, reason: atom) -> fail_self((:explicit, reason))
        };
        cast_dangerous(state.link, (:credit, 1));     // one segment consumed, one more welcome
    produces
        pure next
    end
}

fn apply_command(frame: string,
                 state: { link: dangerous_actor_ref, credits: uint32,
                          rx: { expected: uint64, parts: List[string, normal] } })
    -> { link: dangerous_actor_ref, credits: uint32,
         rx: { expected: uint64, parts: List[string, normal] } } {
    sequence proc[mem(normal), concurrency]
        decoded: (:ok, (:led, { which: :single | :red | :green | :blue, on: boolean })) | (:rejected, atom)
            <- decode((:etf), frame);
        case decoded of {
            (:ok, (:led, cmd: { which: :single | :red | :green | :blue, on: boolean })) ->
                cast_registered(:led_driver, (:led, cmd));      // on the board, a cast_device_registered
            (:rejected, reason: atom) ->
                print_atom(reason)       // :bad_variant for {led, #{which => purple}}, :unknown_atom, ...
        };
    produces
        pure state
    end
}
```

### 13.3 Starting it

```silica
fn main() -> int64 {
    sequence proc[mem(normal), concurrency]
        sup: supervisor_ref <- spawn_registered_supervisor(:root, ...);
        me: actor_ref <- spawn({ link: link, credits: 0, rx: wireframe@fresh() }, owner,
                               stack_policy(0, :keep_last_message), 0);
        link: dangerous_actor_ref <- tcp_carrier@start(me, "127.0.0.1:4040");   // casts (:open, me, address) for us
        cast(me, (:sample, 1, -2, 512, 1000) impl ActorMessage {});
        wait_for_exit();
    produces
        pure 0
    end
}
```

(The owner needs the link and the link needs the owner; the real program hands the link to the owner in an
`(:open, ...)`-style first message, or starts both under the supervisor. The sketch above elides that.)

### 13.4 The Erlang end, and the bytes

```erlang
{ok, L} = gen_tcp:listen(4040, [binary, {packet, 4}, {active, false}, {reuseaddr, true}]),
{ok, S} = gen_tcp:accept(L),
{ok, Bin} = gen_tcp:recv(S, 0),
{accel, #{x := X, y := Y, z := Z, at_ms := T}} = binary_to_term(Bin),
ok = gen_tcp:send(S, term_to_binary({led, #{which => red, on => true}})).
```

`{packet, 4}` is the §5 length prefix, so the Erlang side never sees framing. The frame for
`(:accel, { x: 1, y: -2, z: 512, at_ms: 1000 })` is 48 bytes, and `term_to_binary({accel, #{...}})` produces the
same 48 (Erlang orders a small map's keys in term order, which for atoms is by name, the order §4.4 encodes):

```
83                         version
68 02                      SMALL_TUPLE_EXT arity 2
77 05 61 63 63 65 6C       SMALL_ATOM_UTF8_EXT "accel"
74 00 00 00 04             MAP_EXT, 4 pairs, keys in name order
77 05 61 74 5F 6D 73       "at_ms"
62 00 00 03 E8             INTEGER_EXT 1000
77 01 78                   "x"
61 01                      SMALL_INTEGER_EXT 1
77 01 79                   "y"
62 FF FF FF FE             INTEGER_EXT -2
77 01 7A                   "z"
62 00 00 02 00             INTEGER_EXT 512
```

On the wire it is preceded by `00 00 00 30`. The reply `{led, #{which => red, on => true}}` decodes into
`(:led, { which: :red, on: true })`; `#{which => purple, on => true}` is `(:rejected, :bad_variant)` because
`purple` is not one of the four literals, and `#{which => red}` is `(:rejected, :missing_field)`.

### 13.5 The same owner on the board

Replace the carrier: `use uart1_carrier;` for `use tcp_carrier;`, `(:uart1)` for `(:tcp)` in the two
`carrier@` calls, and `device_actor_ref` with `cast_device` for the link's type and casts. The module loses its
`dangerous_` prefix and gains the `device_` prefix, since the carrier is now a device worker and no Fifi is
involved. The frames are the same bytes, and on the host an Erlang port program reading the serial line with
`{packet, 4}` receives them unchanged. The readings themselves come from the I2C0 worker (plan item G) as
`(:sample, ...)` casts instead of from a test cast in `main`.
