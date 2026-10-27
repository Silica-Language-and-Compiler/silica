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

"""Run a bare-metal ESP32-S3 image on the board and capture the program's run.

    run_on_board.py [--port P] [--timeout S] [--out FILE] [--flash | --no-flash]
                    [--send TEXT [--send-delay S] [--send-marker M [--send-marker-count N]]] image.bin
    run_on_board.py --probe [--port P] [--expect-mac MAC]
    run_on_board.py --list-ports

Modes:
  (default)   Load the image into RAM through the ROM download mode and start it; nothing is
              written to flash. The upload runs at 921600 baud (the ROM loader rejects anything
              faster); the ROM is switched back to 230400 before the jump, because at 921600 the
              console output of images larger than about 40 KB arrives corrupted (measured
              2026-09-13; cause not established). The output is captured on the same open port,
              so the start marker cannot be missed. The host's Unix time in milliseconds is
              written into the runtime's wall clock (rt_actors.S silica_rt_wall_clock) last, just
              before the start, so current_time answers epoch milliseconds (spec §22.14.1); the
              flash modes leave it unset (milliseconds since the system timer started).
  --flash     Write the image to flash at 0x0, reset, capture (the image then survives resets).
  --no-flash  Reset and capture whatever is already in flash.
  --probe     Connect, check that the device is an ESP32-S3 (and, with --expect-mac, that it is
              that particular board), print "port chip mac", reset the board, exit.
  --list-ports  Print the candidate serial ports, one per line.

Port: --port, else $BOARD_PORT, else the one candidate USB serial port. No candidate, or more than
one, is an error (exit 4) so a caller never runs on an unexpected device.

Input: --send TEXT writes TEXT to the console's receive side (the program's standard input on this
target, spec §15.1.2.5) once the start marker has been seen and --send-delay seconds (default 1)
have passed; Python escapes are honoured, so --send 'exit\\n' sends the exit line that makes a
main waiting in wait_for_exit return 0 (the program ends when main returns, spec §15.1.2.5). The
delay lets the program's output settle first,
as the host harness sends `exit` only after a trial's marker. With --send-marker M (and
--send-marker-count N, default 1) the text also waits until N occurrences of M are on complete
output lines and the output has then been quiet for 1.5 s (10 s at most), the host harness's
rule (trials/*/run_integration_exit_after_marker.py), so a trial that needs longer than the delay
to reach its marker is not cut short.

The runtime (board/runtime/rt_start.S, rt_console.S) brackets program output with
    \\x02SILICA:START\\x03 ... \\x02SILICA:EXIT:<status>\\x03 [diagnostic]
This prints (or writes to --out) exactly what the trial harness writes to a .sout file:
the program's bytes followed by the status on its own line. A process-fatal report (spec
§15.4.5.5: "[silica] fault at 0x<pc>..." with status 70, "[silica] abort: <reason> at 0x<pc>"
with status 71) is part of the program's bytes, as the host's stderr line is part of a .sout.
Anything after the exit marker (the board-only fault details) goes to stderr. Compare with an
expected.scout through tools/compare_sout.sh, which folds the addresses in those report lines.

Exit status: 0 a marker pair was seen; 3 no exit marker before the timeout (the raw console goes
to stderr); 4 the board is unavailable (no or ambiguous port, cannot connect, not an ESP32-S3,
MAC mismatch, serial error); 2 usage.

Must run under the ESP-IDF Python environment (it provides esptool and pyserial), e.g.
    ~/.espressif/python_env/idf6.2_py3.14_env/bin/python run_on_board.py image.bin
"""

import argparse
import glob
import os
import struct
import subprocess
import sys
import time

START = b"\x02SILICA:START\x03"
EXIT_PREFIX = b"\x02SILICA:EXIT:"
WALL_CLOCK_TAG = b"SILICA:WALLCLOCK"
UPLOAD_BAUD = 921600
RUN_BAUD = 230400

EXIT_TIMEOUT = 3
EXIT_BOARD = 4


class BoardUnavailable(Exception):
    pass


def candidate_ports():
    pats = ["/dev/cu.usbserial*", "/dev/cu.usbmodem*", "/dev/cu.wchusbserial*",
            "/dev/cu.SLAB_USBtoUART*", "/dev/ttyUSB*", "/dev/ttyACM*"]
    return sorted(set(p for pat in pats for p in glob.glob(pat)))


def pick_port(explicit):
    port = explicit or os.environ.get("BOARD_PORT", "")
    if port:
        if not os.path.exists(port):
            raise BoardUnavailable("serial port %s does not exist (is the board plugged in and switched on?)" % port)
        return port
    ports = candidate_ports()
    if not ports:
        raise BoardUnavailable("no USB serial port found (is the board plugged in and switched on?)")
    if len(ports) > 1:
        raise BoardUnavailable("several serial ports (%s); choose one with --port or BOARD_PORT" % " ".join(ports))
    return ports[0]


def quiet_esptool():
    try:
        from esptool.logger import log
        log.set_verbosity("silent")
    except Exception:
        pass


def connect(port):
    """ROM download mode connection (esptool's default reset sequence).

    Opening the port right after the previous run closed it occasionally fails with "the port is
    busy" (the USB bridge is not back yet); that is retried a few times before the board is
    reported unavailable, since a trial run treats that as the board being gone for good."""
    quiet_esptool()
    from esptool.cmds import detect_chip
    attempt = 0
    while True:
        try:
            esp = detect_chip(port, 115200, "default-reset")
            break
        except Exception as e:  # esptool raises FatalError / serial exceptions
            msg = str(e).strip().splitlines()[0] if str(e).strip() else type(e).__name__
            attempt += 1
            if attempt < 4 and ("busy" in msg or "Could not open" in msg or "could not open" in msg):
                time.sleep(1.0)
                continue
            raise BoardUnavailable("cannot connect to the board on %s: %s" % (port, msg))
    if "ESP32-S3" not in esp.CHIP_NAME:
        raise BoardUnavailable("the device on %s is an %s, not an ESP32-S3" % (port, esp.CHIP_NAME))
    return esp


def mac_of(esp):
    mac = esp.read_mac()
    return ":".join("%02x" % b for b in mac)


# --send-marker (main): with a marker, --send waits, beyond --send-delay, until the program's output
# holds --send-marker-count occurrences of the marker on complete lines and has then been quiet for
# MARKER_IDLE seconds (at most MARKER_DRAIN_CAP after the marker), as the host harness does
# (trials/*/run_integration_exit_after_marker.py). Without one only the delay counts.
SEND_MARKER = None
SEND_MARKER_COUNT = 1
MARKER_IDLE = 1.5
MARKER_DRAIN_CAP = 10.0


def marker_reached(out):
    lines = bytes(out).split(b"\n")[:-1]
    return sum(line.count(SEND_MARKER) for line in lines) >= SEND_MARKER_COUNT


def capture(port, timeout, send=None, send_delay=1.0):
    buf = bytearray()
    deadline = time.time() + timeout
    send_at = None
    last_rx = time.time()
    marker_at = None
    while time.time() < deadline:
        chunk = port.read(4096)
        if chunk:
            buf += chunk
            last_rx = time.time()
        i = buf.find(START)
        if i >= 0:
            if send is not None:
                now = time.time()
                if send_at is None:
                    send_at = now + send_delay
                ready = now >= send_at
                if ready and SEND_MARKER is not None:
                    if marker_at is None and marker_reached(buf[i + len(START):]):
                        marker_at = now
                    ready = marker_at is not None and (now - last_rx >= MARKER_IDLE or now - marker_at >= MARKER_DRAIN_CAP)
                if ready:
                    port.write(send)
                    port.flush()
                    send = None
            j = buf.find(EXIT_PREFIX, i)
            if j >= 0:
                k = buf.find(b"\x03", j + len(EXIT_PREFIX))
                if k >= 0:
                    # grab the diagnostic line after the marker, if any
                    tail_deadline = time.time() + 0.3
                    while time.time() < tail_deadline:
                        buf += port.read(4096)
                    out = bytes(buf[i + len(START):j])
                    status = buf[j + len(EXIT_PREFIX):k].decode(errors="replace")
                    diag = bytes(buf[k + 1:]).split(b"\n")[0]
                    return out, status, diag
    return None, None, bytes(buf)


def run_from_ram(port_name, image, timeout, send=None, send_delay=1.0):
    from esptool.bin_image import LoadFirmwareImage
    from esptool.util import div_roundup
    esp = connect(port_name)
    try:
        esp.change_baud(UPLOAD_BAUD)
        with open(image, "rb") as f:
            img = LoadFirmwareImage(esp.CHIP_NAME, f.read())
        for seg in img.segments:
            data = seg.data
            esp.mem_begin(len(data), div_roundup(len(data), esp.ESP_RAM_BLOCK), esp.ESP_RAM_BLOCK, seg.addr)
            seq = 0
            while data:
                esp.mem_block(data[:esp.ESP_RAM_BLOCK], seq)
                data = data[esp.ESP_RAM_BLOCK:]
                seq += 1
        # The wall clock (rt_actors.S silica_rt_wall_clock): the board has none, so the host's Unix
        # time in milliseconds goes into the word after the runtime's tag, written last so that it
        # is as close as possible to the start; the runtime adds the system timer's count from there.
        for seg in img.segments:
            k = seg.data.find(WALL_CLOCK_TAG)
            if k >= 0:
                stamp = struct.pack("<Q", int(time.time() * 1000))
                esp.mem_begin(len(stamp), 1, esp.ESP_RAM_BLOCK, seg.addr + k + len(WALL_CLOCK_TAG))
                esp.mem_block(stamp, 0)
                break
        esp.change_baud(RUN_BAUD)
        # MEM_END without reading its response (esptool's mem_finish would read it): the program
        # starts printing as soon as the ROM jumps to the entry point, and when the host is slow
        # esptool's SLIP reader consumes those first bytes (the START marker included) with the
        # response, so the capture below never sees the marker. Same packet as mem_finish
        # (checked against esptool 5.4.0).
        esp.command(esp.ESP_CMDS["MEM_END"], struct.pack("<II", int(img.entrypoint == 0), img.entrypoint),
                    wait_response=False)
    except BoardUnavailable:
        raise
    except Exception as e:
        raise BoardUnavailable("loading the image into RAM failed: %s" % (str(e).strip().splitlines()[0] if str(e).strip() else type(e).__name__))
    port = esp._port
    port.timeout = 0.05
    try:
        return capture(port, timeout, send, send_delay)
    finally:
        port.close()


def flash(port, image):
    esptool = os.path.join(os.path.dirname(sys.executable), "esptool")
    cmd = [esptool, "--chip", "esp32s3", "--port", port, "--baud", "921600",
           "--before", "default-reset", "--after", "no-reset",
           "write-flash", "--flash-mode", "dio", "--flash-size", "detect", "0x0", image]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if r.returncode != 0:
        sys.stderr.write(r.stdout.decode(errors="replace"))
        raise BoardUnavailable("flashing failed")


def reset_and_capture(port_name, timeout, send=None, send_delay=1.0):
    import serial  # from the ESP-IDF Python environment
    try:
        s = serial.Serial(port_name, 115200, timeout=0.05)
    except Exception as e:
        raise BoardUnavailable("cannot open %s: %s" % (port_name, e))
    # Classic auto-reset: EN via RTS, BOOT (GPIO0) via DTR. Keep DTR released so the chip boots the
    # flashed image instead of the ROM download mode.
    s.dtr = False
    s.rts = True
    time.sleep(0.1)
    s.reset_input_buffer()
    s.rts = False
    try:
        return capture(s, timeout, send, send_delay)
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image", nargs="?")
    ap.add_argument("--port")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--out")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--flash", action="store_true", help="write the image to flash first (default: load into RAM)")
    mode.add_argument("--no-flash", action="store_true", help="reset and run what is already in flash")
    mode.add_argument("--probe", action="store_true", help="check the board and print port, chip and MAC")
    mode.add_argument("--list-ports", action="store_true", help="print the candidate serial ports")
    ap.add_argument("--expect-mac", default=os.environ.get("BOARD_MAC", ""),
                    help="with --probe: fail unless the board has this MAC (default $BOARD_MAC)")
    ap.add_argument("--send", help="text to write to the console after the start marker (Python escapes, e.g. 'exit\\n')")
    ap.add_argument("--send-delay", type=float, default=1.0, help="seconds after the start marker before --send is written")
    ap.add_argument("--send-marker", help="with --send: also wait until the output holds this marker (then quiet), as the host harness does")
    ap.add_argument("--send-marker-count", type=int, default=1, help="occurrences of --send-marker to wait for (default 1)")
    a = ap.parse_args()
    global SEND_MARKER, SEND_MARKER_COUNT
    if a.send_marker:
        SEND_MARKER = a.send_marker.encode("utf-8")
        SEND_MARKER_COUNT = max(1, a.send_marker_count)
    send = None
    if a.send is not None:
        send = a.send.encode("utf-8").decode("unicode_escape").encode("latin-1")

    if a.list_ports:
        for p in candidate_ports():
            print(p)
        return 0

    try:
        port = pick_port(a.port)
        if a.probe:
            esp = connect(port)
            mac = mac_of(esp)
            if a.expect_mac and mac.lower() != a.expect_mac.lower():
                raise BoardUnavailable("the board on %s has MAC %s, expected %s" % (port, mac, a.expect_mac))
            print("%s %s %s" % (port, esp.get_chip_description(), mac))
            try:
                esp.hard_reset()
            except Exception:
                pass
            esp._port.close()
            return 0
        if not a.image:
            ap.error("an image is required")
        if a.flash:
            flash(port, a.image)
            out, status, diag = reset_and_capture(port, a.timeout, send, a.send_delay)
        elif a.no_flash:
            out, status, diag = reset_and_capture(port, a.timeout, send, a.send_delay)
        else:
            out, status, diag = run_from_ram(port, a.image, a.timeout, send, a.send_delay)
    except BoardUnavailable as e:
        sys.stderr.write("run_on_board: %s\n" % e)
        return EXIT_BOARD
    except OSError as e:  # the serial port vanished mid-run
        sys.stderr.write("run_on_board: serial error: %s\n" % e)
        return EXIT_BOARD

    if out is None:
        sys.stderr.write("run_on_board: no exit marker within %.0fs; raw console:\n" % a.timeout)
        sys.stderr.write(diag.decode(errors="replace") + "\n")
        return EXIT_TIMEOUT
    text = out + status.encode() + b"\n"
    if a.out:
        with open(a.out, "wb") as f:
            f.write(text)
    else:
        sys.stdout.buffer.write(text)
    if diag.strip():
        sys.stderr.write(diag.decode(errors="replace").strip() + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
