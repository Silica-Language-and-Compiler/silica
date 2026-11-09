#!/usr/bin/env python3
"""Play the board's end of the UART1 demo on a pseudo-terminal, for checking the Mac peer with no hardware.

    fake_board.py [--delay 3]

Opens a pty pair, prints "pty <slave path>" (the port the peer opens), waits --delay seconds, then writes the
52 bytes silica_32_transport_uart1_etf sends on UART1: the 4-byte length prefix 00 00 00 30 and the 48-byte
ETF term of transport_serialization_design.md §13.4 for (:accel, { x: 1, y: -2, z: 512, at_ms: 1000 }).
It then echoes whatever the peer writes back to its stdout as hex and stays open until killed. The bytes are
the design's, not read from a board: a board run is still the proof; this only checks the Mac side.
"""
import argparse, os, pty, select, sys, time

FRAME = bytes.fromhex(
    "00000030"
    "83"
    "6802"
    "77056163 63656c"
    "7400000004"
    "770561745f6d73" "62000003e8"
    "770178" "6101"
    "770179" "62fffffffe"
    "77017a" "6200000200"
)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--delay", type=float, default=3.0)
    a = ap.parse_args()
    assert len(FRAME) == 52, len(FRAME)
    master, slave = pty.openpty()
    print("pty " + os.ttyname(slave), flush=True)
    time.sleep(a.delay)
    os.write(master, FRAME)
    print("sent %d bytes" % len(FRAME), flush=True)
    while True:
        r, _, _ = select.select([master], [], [], 1.0)
        if r:
            try:
                data = os.read(master, 4096)
            except OSError:
                break
            if not data:
                break
            print("got " + data.hex(), flush=True)

if __name__ == "__main__":
    main()
