#!/usr/bin/env python3
# Stage 4 spike: reset the board and print what it writes on its console for a few seconds.
#   capture.py <port> [seconds] [baud]
import sys, time, serial
port = sys.argv[1]; seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 8; baud = int(sys.argv[3]) if len(sys.argv) > 3 else 115200
s = serial.Serial(port, baud, timeout=0.2)
s.dtr = False; s.rts = True; time.sleep(0.1); s.rts = False   # pulse EN, leave GPIO0 high: run the application
end = time.time() + seconds; out = b""
while time.time() < end:
    out += s.read(4096)
sys.stdout.write(out.decode("utf-8", "replace"))
