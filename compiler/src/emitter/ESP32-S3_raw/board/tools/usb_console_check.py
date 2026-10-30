#!/usr/bin/env python3
# Copyright 2026 Lee Scott Barney
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Check the USB-Serial-JTAG side of the second-console gate (plan item F): run a board app that
uses UART0 and USB-Serial-JTAG together and play the USB host.

    usb_console_check.py [--app APP] [--port UART0_PORT] [--usb-port P] [--usb-timeout S]
                         [--send TEXT] [--expect TEXT] [run_app.sh options ...]

It starts tools/run_app.sh for APP (default silica_31_device_usb_console) with the options it does
not know (--timeout, --flash, --keep, ... pass through; --port, else $BOARD_PORT, is passed as the
UART0 port, because run_on_board.py will not pick one when several serial ports exist). The
USB side does nothing during the compile, image build and the upload over UART0: it starts when
run_app.sh prints "run_app: running ... on the board", then watches the USB-Serial-JTAG CDC port
(found by USB VID:PID 303A:1001, re-resolved on every open because the node's name can change; --usb-port
is only a check and a port with another id is refused) WITHOUT opening it until the chip has been reset
into the program (the node vanished and reappeared twice: ROM download mode, then the program) or
--usb-open-delay seconds (default 12) have passed. It then opens it
with DTR and RTS left high, the idle state (setting them low resets the chip: see open_port), writes --send (default "A") every
0.25 s and keeps everything the port sends, until --expect (default "hello from usb serial jtag\nA")
has arrived or --usb-timeout seconds (default 60, counted from run_app.sh's "running ... on the board" line) have passed.

Both consoles and a timestamped log of the USB port's events (appears, disappears, open, close, bytes
written, errors, bytes read) are printed; a port whose device node vanishes is closed and reopened. Exit status: 0 when run_app.sh exited 0 (the UART0 output matched
expected.scout) and the USB reply matched; run_app.sh's own status when that was not 0 (see its
header); 8 when the UART0 run matched but the USB reply did not arrive; 9 for a usage or
environment error (no pyserial, no run_app.sh).

Example:
    BOARD_PORT=/dev/cu.usbserial-310 usb_console_check.py
"""

import argparse
import os
import re
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RUN_APP = os.path.join(HERE, "run_app.sh")
USB_MISMATCH = 8
USAGE = 9
ESPRESSIF_VID = 0x303A           # esp_pylib/constants.py:19 (esptool ESPRESSIF_VID)
USB_JTAG_SERIAL_PID = 0x1001     # esp_pylib/constants.py:22 (esptool USB_JTAG_SERIAL_PID)
NO_DEVICE = "no ESP32-S3 USB-Serial-JTAG device (303A:1001) present: is the board's USB-CDC connector plugged in?"
RUNNING = re.compile(rb"^run_app: running .* on the board")


class UsbHost(threading.Thread):
    """Plays the USB host: reopens the CDC port whenever it (re)appears, writes `send` until the
    reply is seen, records every byte received, and logs every event with a time relative to `t0`."""

    def __init__(self, serial_mod, port, send, expect, timeout, open_delay, t0):
        super().__init__(daemon=True)
        self.serial = serial_mod
        self.port = port
        self.send = send
        self.expect = expect
        self.t0 = t0
        self.timeout = timeout
        self.open_delay = open_delay
        self.go = threading.Event()      # set when run_app.sh says it is running the image on the board
        self.deadline = None
        self.data = b""
        self.matched = False
        self.opens = 0
        self.written = 0
        self.events = []
        self.refused = False
        self.ambiguous = False
        self.ever_seen = False
        self.stop = threading.Event()

    def log(self, msg):
        line = "[usb t=%6.2fs] %s" % (time.time() - self.t0, msg)
        self.events.append(line)
        print(line, file=sys.stderr, flush=True)

    def find_port(self):
        """The device node of the one ESP32-S3 USB-Serial-JTAG (VID:PID 303A:1001), resolved afresh on
        every call (the node's name changes when the chip re-enumerates). Nothing else is ever
        opened: no other VID:PID, no glob of /dev/cu.usbmodem*."""
        from serial.tools import list_ports
        ports = list(list_ports.comports())
        matches = sorted(p.device for p in ports if p.vid == ESPRESSIF_VID and p.pid == USB_JTAG_SERIAL_PID
                         and not p.device.startswith("/dev/tty."))
        if self.port:
            # --usb-port is only a check: it must itself be an ESP32-S3 USB-Serial-JTAG
            listed = [p for p in ports if p.device == self.port]
            if listed and not (listed[0].vid == ESPRESSIF_VID and listed[0].pid == USB_JTAG_SERIAL_PID):
                if not self.refused:
                    self.refused = True
                    self.log("refusing %s: its USB id is %s, not %04X:%04X" % (
                        self.port, "%04X:%04X" % (listed[0].vid, listed[0].pid) if listed[0].vid is not None else "(none)",
                        ESPRESSIF_VID, USB_JTAG_SERIAL_PID))
                return None
            if self.port in matches:
                return self.port
        if len(matches) > 1:
            if not self.ambiguous:
                self.ambiguous = True
                self.log("several USB-Serial-JTAG devices (%s); choose one with --usb-port" % " ".join(matches))
            return None
        return matches[0] if matches else None

    def open_port(self, name):
        s = self.serial.Serial()
        s.port = name
        s.baudrate = 115200
        s.timeout = 0.05
        s.write_timeout = 0.5
        # DTR and RTS are left at pyserial's default, high: (DTR, RTS) = (1, 1) is the USB-Serial-JTAG
        # peripheral's idle state (esptool's usb_jtag_bootloader_reset, esp_pylib/serial_reset.py:367-391).
        # Do NOT set them low before open(). Likely cause (not measured): macOS raises both lines when the
        # node is opened, and pyserial then lowers DTR before RTS, passing through (0, 1), which the
        # peripheral takes as a chip reset. Seen on the board: opening with both low reset the chip into
        # ROM download mode (rst:0x15 USB_UART_CHIP_RESET, "waiting for download"), killing the program;
        # opening with both left high did not reset it.
        s.open()
        return s

    @staticmethod
    def identity(name):
        try:
            st = os.stat(name)
            return (st.st_ino, st.st_rdev)
        except OSError:
            return None

    def wait_for_reset(self):
        """After run_app.sh starts the board run: watch the device node without opening it, until the
        chip has been reset into the program (the node disappeared and reappeared twice: into the ROM
        download mode, then into the program) or open_delay seconds have passed, and the node is there."""
        t_go = time.time()
        appearances, present = 0, None
        stable_since = None
        while not self.stop.is_set() and time.time() < self.deadline:
            here = self.find_port() is not None
            self.ever_seen = self.ever_seen or here
            if here != present:
                if present is not None:
                    self.log("port %s (not opened yet)" % ("appeared" if here else "disappeared"))
                    appearances += here
                present = here
                stable_since = time.time()
            if here and time.time() - stable_since >= 0.5 and (appearances >= 2 or time.time() - t_go >= self.open_delay):
                return
            time.sleep(0.05)

    def run(self):
        self.go.wait()
        self.deadline = time.time() + self.timeout       # counted from the start of the board run
        self.log("board run started; watching for the chip reset")
        if self.find_port() is None:
            self.log(NO_DEVICE)
        self.wait_for_reset()
        present = None
        while not self.stop.is_set() and self.go.is_set() and time.time() < self.deadline and not self.matched:
            name = self.find_port()
            self.ever_seen = self.ever_seen or name is not None
            if (name is not None) != present:
                present = name is not None
                self.log("port %s %s" % (name or self.port or "(none)", "appeared" if present else "disappeared"))
            if name is None:
                time.sleep(0.05)
                continue
            try:
                s = self.open_port(name)
            except (self.serial.SerialException, OSError) as e:
                self.log("open %s failed: %s" % (name, e))
                time.sleep(0.2)
                continue
            self.opens += 1
            ident = self.identity(name)
            self.log("opened %s (open #%d)" % (name, self.opens))
            last_send = 0.0
            n_here = 0
            try:
                while not self.stop.is_set() and time.time() < self.deadline:
                    if self.identity(name) != ident:      # the device node vanished or was replaced: stale handle
                        self.log("%s vanished or was replaced; dropping the handle" % name)
                        break
                    chunk = s.read(256)
                    if chunk:
                        self.data += chunk
                        self.log("read %d byte(s): %r" % (len(chunk), chunk[:80]))
                        if self.expect in self.data:
                            self.matched = True
                            break
                    if time.time() - last_send >= 0.25:
                        last_send = time.time()
                        try:
                            n = s.write(self.send)
                            self.written += n or 0
                            n_here += n or 0
                        except self.serial.SerialTimeoutException:
                            self.log("write timed out")
                        except (self.serial.SerialException, OSError) as e:
                            self.log("write error: %s" % e)
                            raise
            except (self.serial.SerialException, OSError) as e:
                self.log("read/write error, port presumably gone: %s" % e)
            finally:
                self.log("closing %s (%d byte(s) written on this open, %d in all)" % (name, n_here, self.written))
                try:
                    s.close()
                except Exception:
                    pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], add_help=True)
    ap.add_argument("--app", default="silica_31_device_usb_console", help="app under board/apps (default %(default)s)")
    ap.add_argument("--port", default=os.environ.get("BOARD_PORT", ""), help="UART0 port for run_app.sh (default $BOARD_PORT)")
    ap.add_argument("--usb-port", help="check only: this port must be an ESP32-S3 USB-Serial-JTAG (303A:1001) or it is refused; the device is found by VID:PID, whatever its name")
    ap.add_argument("--usb-timeout", type=float, default=60.0, help="seconds to wait for the USB reply, counted from run_app.sh's \"running ... on the board\" line (default %(default)s)")
    ap.add_argument("--usb-open-delay", type=float, default=12.0, help="open the USB port at the latest this many seconds after that line, if the chip's reset was not seen (default %(default)s)")
    ap.add_argument("--send", default="A", help="text written to the USB port every 0.25 s (Python escapes; default A)")
    ap.add_argument("--expect", default="hello from usb serial jtag\\nA", help="text the USB side must send (Python escapes)")
    a, passthrough = ap.parse_known_args()

    try:
        import serial
    except ImportError:
        print("usb_console_check: pyserial is not installed for %s (use the ESP-IDF Python)" % sys.executable, file=sys.stderr)
        return USAGE
    if not os.path.exists(RUN_APP):
        print("usb_console_check: no %s" % RUN_APP, file=sys.stderr)
        return USAGE

    def unescape(t):
        return t.encode("utf-8").decode("unicode_escape").encode("latin-1")

    send, expect = unescape(a.send), unescape(a.expect)
    cmd = ["bash", RUN_APP]
    if a.port:
        cmd += ["--port", a.port]
    cmd += passthrough + [a.app]

    t0 = time.time()
    host = UsbHost(serial, a.usb_port, send, expect, a.usb_timeout, a.usb_open_delay, t0)
    host.start()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    uart_out = b""
    for line in proc.stdout:
        uart_out += line
        sys.stderr.write(line.decode("utf-8", "replace"))
        sys.stderr.flush()
        if RUNNING.search(line):
            host.go.set()           # the image is loaded next; the USB phase starts now
    rc = proc.wait()

    # The program ends right after the worker answers; give the USB reader a moment to take the rest.
    host.join(timeout=3.0 if rc == 0 else 0.0)
    host.stop.set()
    host.join(timeout=2.0)

    print("=== UART0 console (run_app.sh %s, exit %d) ===" % (a.app, rc))
    sys.stdout.write(uart_out.decode("utf-8", "replace"))
    if uart_out and not uart_out.endswith(b"\n"):
        print()
    print("=== USB-Serial-JTAG console (%s, opened %d time(s)) ===" % (host.port or "auto", host.opens))
    sys.stdout.write(host.data.decode("utf-8", "replace"))
    if host.data and not host.data.endswith(b"\n"):
        print()
    print("=== USB host log ===")
    for line in host.events:
        print(line)
    print("=== result ===")
    print("UART0:  %s" % ("matched" if rc == 0 else "run_app.sh exit %d" % rc))
    if not host.ever_seen:
        print("USB:    %s" % NO_DEVICE)
    else:
        print("USB:    %s" % ("reply matched %r" % expect.decode("latin-1") if host.matched else "reply %r NOT seen" % expect.decode("latin-1")))
    if rc != 0:
        return rc
    return 0 if host.matched else USB_MISMATCH


if __name__ == "__main__":
    sys.exit(main())
