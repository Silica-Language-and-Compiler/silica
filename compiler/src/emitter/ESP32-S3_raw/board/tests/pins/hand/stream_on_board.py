#!/usr/bin/env python3
"""Hand-run pin apps: tools/run_on_board.py with a live console.

run_on_board.py hands back the whole console only when the program has exited. A hand run needs the
lines as they appear (the "PULL THE JUMPER" cue), so this wrapper imports run_on_board, replaces its
capture loop with one that also prints each complete console line as soon as it arrives, and runs its
main() unchanged (same options: --port, --timeout, --out, image). Nothing else is changed: the load,
the wall clock stamp, the markers and the exit status are run_on_board's. Run it with the ESP-IDF Python.

    stream_on_board.py [--port P] [--timeout S] [--out FILE] image.bin
"""
import os
import sys
import time

TOOLS = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tools"))
sys.path.insert(0, TOOLS)
import run_on_board as rob  # noqa: E402


def streaming_capture(port, timeout, send=None, send_delay=1.0):
    buf = bytearray()
    deadline = time.time() + timeout
    shown = 0          # bytes after START already printed
    while time.time() < deadline:
        chunk = port.read(4096)
        if chunk:
            buf += chunk
        i = buf.find(rob.START)
        if i < 0:
            continue
        body_at = i + len(rob.START)
        j = buf.find(rob.EXIT_PREFIX, i)
        end = j if j >= 0 else len(buf)
        # print complete lines only
        nl = buf.rfind(b"\n", body_at, end)
        if nl >= 0 and nl + 1 - body_at > shown:
            sys.stdout.write(bytes(buf[body_at + shown:nl + 1]).decode(errors="replace"))
            sys.stdout.flush()
            shown = nl + 1 - body_at
        if j >= 0:
            k = buf.find(b"\x03", j + len(rob.EXIT_PREFIX))
            if k >= 0:
                tail_deadline = time.time() + 0.3
                while time.time() < tail_deadline:
                    buf += port.read(4096)
                out = bytes(buf[body_at:j])
                if len(out) > shown:      # a last line without its newline
                    sys.stdout.write(out[shown:].decode(errors="replace"))
                    sys.stdout.flush()
                status = buf[j + len(rob.EXIT_PREFIX):k].decode(errors="replace")
                diag = bytes(buf[k + 1:]).split(b"\n")[0]
                return out, status, diag
    return None, None, bytes(buf)


rob.capture = streaming_capture

if __name__ == "__main__":
    sys.exit(rob.main())
