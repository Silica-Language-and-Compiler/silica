#!/usr/bin/env python3
"""Play the board's end of the accel/LED pair (accel_led_board/) on a pseudo-terminal, for checking
the Mac peers with no hardware and for comparing their reply bytes.

    fake_board_readings.py [--delay 2]

Opens a pty pair (raw mode, so nothing is echoed), prints "pty <slave path>" (the port the peer opens), waits
--delay seconds, then plays the board's lockstep: it writes the frame of reading 1 (the 4-byte length prefix
and the ETF term, record fields in the order Silica's encode writes them: at_ms, x, y, z), reads the reply
frame, prints "reply <n> <hex>", and goes on with the next reading; after the last reply it writes the
end-of-stream frame (:done, 4), prints "done", and stays open until the peer closes the port (or 5 s pass). The readings are the board app's table, encoded here
by hand: a board run is still the proof; this only checks the Mac side and lets the two peers' replies be
diffed byte for byte.
"""
import argparse, os, pty, select, struct, sys, time, tty

READINGS = [(1, -2, 512, 1000), (3, 1, 100, 1250), (-5, 4, 300, 1500), (0, 0, -480, 1750)]

def atom(name):
    b = name.encode()
    return bytes([119, len(b)]) + b                     # SMALL_ATOM_UTF8_EXT

def integer(v):
    if 0 <= v <= 255:
        return bytes([97, v])                           # SMALL_INTEGER_EXT
    return bytes([98]) + struct.pack(">i", v)           # INTEGER_EXT

def reading_frame(x, y, z, at_ms):
    fields = [("at_ms", at_ms), ("x", x), ("y", y), ("z", z)]
    body = bytes([131, 104, 2]) + atom("accel") + bytes([116]) + struct.pack(">I", len(fields))
    for k, v in fields:
        body += atom(k) + integer(v)
    return struct.pack(">I", len(body)) + body

def done_frame(n):
    body = bytes([131, 104, 2]) + atom("done") + integer(n)
    return struct.pack(">I", len(body)) + body

def read_frame(fd, timeout):
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            data = os.read(fd, 4096)
        except OSError:
            return None
        if not data:
            return None
        buf += data
        if len(buf) >= 4 and len(buf) >= 4 + struct.unpack(">I", buf[:4])[0]:
            return buf
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--delay", type=float, default=2.0)
    ap.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for each reply")
    a = ap.parse_args()
    master, slave = pty.openpty()
    tty.setraw(slave)
    print("pty " + os.ttyname(slave), flush=True)
    time.sleep(a.delay)
    for i, r in enumerate(READINGS, 1):
        frame = reading_frame(*r)
        os.write(master, frame)
        print("reading %d sent %d bytes" % (i, len(frame)), flush=True)
        reply = read_frame(master, a.timeout)
        if reply is None:
            print("no reply to reading %d" % i, flush=True)
            return 1
        print("reply %d %s" % (i, reply.hex()), flush=True)
    os.write(master, done_frame(len(READINGS)))
    print("done", flush=True)
    read_frame(master, 5.0)
    return 0

if __name__ == "__main__":
    sys.exit(main())
