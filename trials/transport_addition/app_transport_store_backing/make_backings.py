#!/usr/bin/env python3
"""Writes the backings the (:backing) trials open, in the on-medium form of
compiler/stdlib/storelog.silica (transport_serialization_design.md §6.8.4), independently of it:
4096-byte blocks; a block header of first_seq (8 bytes), state (4: 1 in use) and CRC-32C of those 12
bytes; records of length (4), seq (8), CRC-32C over length, seq and payload (4), then the payload.
All integers are big-endian. usage: make_backings.py DIR"""
import os, struct, sys

def crc32c(data):
    c = 0xFFFFFFFF
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    return c ^ 0xFFFFFFFF

def header(first_seq, state=1):
    body = struct.pack(">QI", first_seq, state)
    return body + struct.pack(">I", crc32c(body))

def record(seq, payload):
    head = struct.pack(">IQ", len(payload), seq)
    return head + struct.pack(">I", crc32c(head + payload)) + payload

def write(path, capacity, blocks):
    data = bytearray(capacity)
    for i, content in enumerate(blocks):
        data[i * 4096:i * 4096 + len(content)] = content
    with open(path, "wb") as f:
        f.write(data)

d = sys.argv[1]
# three good records, then the first 20 bytes of a fourth
write(os.path.join(d, "store_backing_torn.sildat"), 8192,
      [header(0) + record(0, b"r0") + record(1, b"r1") + record(2, b"r2") + record(3, b"torn-record-payload")[:20]])
# records 0 to 2 with one byte of record 1's payload wrong; records 3 and 4 in the tail block
flipped = bytearray(header(0) + record(0, b"r0") + record(1, b"r1") + record(2, b"r2"))
flipped[16 + 18 + 16 + 1] ^= 0x01
write(os.path.join(d, "store_backing_flipped.sildat"), 8192, [bytes(flipped), header(3) + record(3, b"r3") + record(4, b"r4")])
# a reused block: records 10 and 11, then two whole records of the lap before
write(os.path.join(d, "store_backing_stale.sildat"), 4096,
      [header(10) + record(10, b"r10") + record(11, b"r11") + record(2, b"old2") + record(3, b"old3")])
# a backing of 4096 bytes, declared as 8192
write(os.path.join(d, "store_backing_mismatch.sildat"), 4096, [])
for name in ("store_backing_restart.sildat", "store_backing_in_use.sildat"):
    p = os.path.join(d, name)
    if os.path.exists(p):
        os.remove(p)
