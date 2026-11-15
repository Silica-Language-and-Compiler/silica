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

"""Run a bare-metal STM32L476RG (ST NUCLEO-L476RG) image on the board and capture the program's run.

    run_on_board.py [--port P] [--timeout S] [--out FILE]
                    [--send TEXT [--send-delay S] [--send-marker M [--send-marker-count N]]] image.elf
    run_on_board.py --probe [--port P] [--expect-serial SERIAL]
    run_on_board.py --list-ports
    run_on_board.py --exec flash --yes-wear-flash [--port P] [--timeout S] [--out FILE] image.elf   (by hand only)

Same interface and output protocol as the ESP32-S3 driver (../../../ESP32-S3_raw/board/tools/run_on_board.py).

Loading: the image (build_image.sh's <name>.elf) goes into RAM through the Nucleo's ST-LINK with
OpenOCD; nothing is written to flash. The console port is opened FIRST (pyserial, 115200), so the start
marker cannot be missed, and then
    openocd -f interface/stlink.cfg -f target/stm32l4x.cfg -c "adapter serial <ST-LINK serial>"
            -c init -c "reset halt" -c "load_image <elf>"
            [-c "mww <silica_rt_wall_clock> <lo>" -c "mww <silica_rt_wall_clock+4> <hi>"]
            -c "resume <_start>" -c shutdown
runs to completion (the program keeps running after OpenOCD exits) and the console is captured on the
same open port. `_start` and `silica_rt_wall_clock` come from `arm-none-eabi-nm` on the ELF; `_start` sets
the stack pointer and VTOR itself. The host's Unix time in milliseconds is written into the runtime's wall
clock last, just before the start, so current_time answers epoch milliseconds (spec §22.14.1); an image
without that symbol just skips it.

Port: --port, else $BOARD_PORT, else the one /dev/cu.usbmodem* port. Only usbmodem ports (the ST-LINK
virtual COM port) are candidates; a /dev/cu.usbserial* port (the ESP32 board) is refused, even when
named, so this target can never touch it.

--probe: `st-info --probe` must show exactly one ST-LINK (serial $BOARD_ST_SERIAL or --expect-serial,
default 066CFF343654393143174720, must match); prints "port chip serial". (st-info resets the target.)
--expect-mac is accepted and ignored (the trial harness passes it for the ESP32 board only).
--print-openocd: print the OpenOCD command line for the image and exit (nothing is run; for checking).

--exec flash (BY HAND ONLY; it WEARS THE FLASH): programs a flash image (build_image.sh BOARD_EXEC=flash,
linked at 0x0800_0000) into the main flash and starts it from a hardware reset:
    openocd ... -c init -c "reset halt" -c "program <elf> verify" -c "reset halt" -c resume -c shutdown
Every run erases and reprograms each 2 KiB page the image covers (about 10,000 cycles per page), so it
is refused unless --yes-wear-flash is given, and it prints a warning first. The trial harness never
passes either option (flash is never used for trials). The program stays in flash afterwards and runs
again at every reset or power-up. The wall clock is not written in flash mode (_start's .data copy would
overwrite it), so current_time counts from the start. The default, --exec ram, refuses a flash image
(it would never reach RAM) and flash mode refuses a RAM image.

Alternative if OpenOCD misbehaves (not the default): st-util in one shell, then
    arm-none-eabi-gdb -batch -ex "target extended-remote :4242" -ex "load" -ex "set $pc=<_start>" -ex continue image.elf
with the console captured on the same port.

Exit status: 0 a marker pair was seen; 3 no exit marker before the timeout (the raw console goes to
stderr); 4 the board is unavailable (no or refused port, no or several or unexpected ST-LINK, OpenOCD
failed, serial error); 2 usage.

Needs pyserial: run it under the ESP-IDF Python environment, e.g.
    ~/.espressif/python_env/idf6.2_py3.14_env/bin/python run_on_board.py image.elf
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import time

START = b"\x02SILICA:START\x03"
EXIT_PREFIX = b"\x02SILICA:EXIT:"
BAUD = 115200
DEFAULT_ST_SERIAL = "066CFF343654393143174720"
OPENOCD_TIMEOUT = 60
OPENOCD_FLASH_TIMEOUT = 180   # erase + program + verify of a few dozen pages; unmeasured, generous

FLASH_WEAR_WARNING = """\
run_on_board: *** WARNING: --exec flash ERASES AND REPROGRAMS THE STM32L476RG MAIN FLASH ***
run_on_board: every run costs one erase cycle on each 2 KiB page the image covers (about 10,000 per page).
run_on_board: by hand only, never from the trials. The program stays in flash and runs at every reset.
"""

EXIT_TIMEOUT = 3
EXIT_BOARD = 4


class BoardUnavailable(Exception):
    pass


def candidate_ports():
    # The ST-LINK virtual COM port only. Never /dev/cu.usbserial* (the ESP32 board).
    return sorted(set(glob.glob("/dev/cu.usbmodem*") + glob.glob("/dev/ttyACM*")))


def pick_port(explicit):
    port = explicit or os.environ.get("BOARD_PORT", "")
    if port:
        if "usbserial" in port or "ttyUSB" in port or "wchusbserial" in port or "SLAB_USBtoUART" in port:
            raise BoardUnavailable("refusing %s: not an ST-LINK port (only /dev/cu.usbmodem* is used for the STM32 target)" % port)
        if not os.path.exists(port):
            raise BoardUnavailable("serial port %s does not exist (is the board plugged in?)" % port)
        return port
    ports = candidate_ports()
    if not ports:
        raise BoardUnavailable("no ST-LINK serial port (/dev/cu.usbmodem*) found (is the Nucleo plugged in?)")
    if len(ports) > 1:
        raise BoardUnavailable("several ST-LINK serial ports (%s); choose one with --port or BOARD_PORT" % " ".join(ports))
    return ports[0]


def require_tool(name):
    path = shutil.which(name)
    if not path:
        raise BoardUnavailable("%s not found on PATH (brew install %s)" % (name, {"arm-none-eabi-nm": "arm-none-eabi-gcc"}.get(name, name)))
    return path


def parse_st_info(text):
    """Returns [(serial, chipid, dev_type)] for the ST-LINKs `st-info --probe` printed."""
    found = []
    cur = None
    for line in text.splitlines():
        m = re.match(r"\s*serial:\s*(\S+)", line)
        if m:
            cur = {"serial": m.group(1), "chipid": "", "dev": ""}
            found.append(cur)
            continue
        if cur is not None:
            m = re.match(r"\s*chipid:\s*(\S+)", line)
            if m:
                cur["chipid"] = m.group(1)
            m = re.match(r"\s*dev-type:\s*(\S+)", line)
            if m:
                cur["dev"] = m.group(1)
    return [(f["serial"], f["chipid"], f["dev"]) for f in found]


def probe(expect_serial):
    st_info = require_tool("st-info")
    try:
        r = subprocess.run([st_info, "--probe"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    except subprocess.TimeoutExpired:
        raise BoardUnavailable("st-info --probe timed out")
    found = parse_st_info(r.stdout.decode(errors="replace"))
    if not found:
        raise BoardUnavailable("st-info --probe found no ST-LINK (is the Nucleo plugged in?)")
    if len(found) > 1:
        raise BoardUnavailable("st-info --probe found %d ST-LINKs (%s); exactly one is required" % (len(found), ", ".join(f[0] for f in found)))
    serial, chipid, dev = found[0]
    if expect_serial and serial.upper() != expect_serial.upper():
        raise BoardUnavailable("the ST-LINK has serial %s, expected %s" % (serial, expect_serial))
    return serial, chipid, dev


def elf_symbols(image, names):
    """Addresses (ints) of the named symbols of the ELF, through arm-none-eabi-nm; missing ones are absent."""
    nm = require_tool("arm-none-eabi-nm")
    r = subprocess.run([nm, image], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise BoardUnavailable("arm-none-eabi-nm failed on %s: %s" % (image, r.stderr.decode(errors="replace").strip()))
    out = {}
    for line in r.stdout.decode(errors="replace").splitlines():
        f = line.split()
        if len(f) == 3 and f[2] in names:
            out[f[2]] = int(f[0], 16)
    return out


FLASH_BASE = 0x08000000
FLASH_END = 0x08100000


def is_flash_image(syms):
    """True when the image's code is linked in the main flash (build_image.sh BOARD_EXEC=flash)."""
    return FLASH_BASE <= syms["_start"] < FLASH_END


def openocd_flash_command(image, serial):
    """The OpenOCD command line that programs a flash image into the main flash (erase, write, verify)
    and starts it from a hardware reset (the vector table at 0x0800_0000 gives sp and _start)."""
    syms = elf_symbols(image, ("_start",))
    if "_start" not in syms:
        raise BoardUnavailable("%s has no _start symbol" % image)
    if not is_flash_image(syms):
        raise BoardUnavailable("%s is not a flash image (_start 0x%08x is outside 0x%08x-0x%08x): build it with BOARD_EXEC=flash"
                               % (image, syms["_start"], FLASH_BASE, FLASH_END - 1))
    cmd = [require_tool("openocd"), "-f", "interface/stlink.cfg", "-f", "target/stm32l4x.cfg"]
    if serial:
        cmd += ["-c", "adapter serial %s" % serial]
    cmd += ["-c", "init", "-c", "reset halt", "-c", "program %s verify" % image,
            "-c", "reset halt", "-c", "resume", "-c", "shutdown"]
    return cmd


def openocd_command(image, serial, wall_ms=None):
    """The OpenOCD command line that loads the ELF into RAM and starts it at _start."""
    syms = elf_symbols(image, ("_start", "silica_rt_wall_clock"))
    if "_start" not in syms:
        raise BoardUnavailable("%s has no _start symbol" % image)
    if is_flash_image(syms):
        raise BoardUnavailable("%s is a flash image (_start 0x%08x): RAM loading cannot run it; flash is only "
                               "programmed by hand with --exec flash --yes-wear-flash" % (image, syms["_start"]))
    # A Thumb function symbol carries bit 0; resume takes the instruction address, and the Thumb state is
    # already set by `reset halt` (EPSR.T), so the bit is cleared.
    start = syms["_start"] & ~1
    cmd = [require_tool("openocd"), "-f", "interface/stlink.cfg", "-f", "target/stm32l4x.cfg"]
    if serial:
        cmd += ["-c", "adapter serial %s" % serial]
    cmd += ["-c", "init", "-c", "reset halt", "-c", "load_image %s" % image]
    if wall_ms is not None and "silica_rt_wall_clock" in syms:
        a = syms["silica_rt_wall_clock"]
        cmd += ["-c", "mww 0x%08x 0x%08x" % (a, wall_ms & 0xFFFFFFFF),
                "-c", "mww 0x%08x 0x%08x" % (a + 4, (wall_ms >> 32) & 0xFFFFFFFF)]
    cmd += ["-c", "resume 0x%08x" % start, "-c", "shutdown"]
    return cmd


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


def load_and_start(image, serial, exec_mode="ram"):
    """Run OpenOCD: load the ELF into RAM and resume at _start (or, exec_mode "flash", program it into
    flash and start it from reset). Returns when OpenOCD has exited."""
    if exec_mode == "flash":
        cmd = openocd_flash_command(image, serial)
        timeout = OPENOCD_FLASH_TIMEOUT
    else:
        cmd = openocd_command(image, serial, int(time.time() * 1000))
        timeout = OPENOCD_TIMEOUT
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise BoardUnavailable("openocd timed out while loading %s" % image)
    if r.returncode != 0:
        text = r.stdout.decode(errors="replace")
        errs = [l for l in text.splitlines() if "Error" in l] or text.strip().splitlines()[-1:]
        raise BoardUnavailable("loading the image through OpenOCD failed: %s" % " | ".join(e.strip() for e in errs[:3]))


def run_on_board(port_name, image, timeout, send=None, send_delay=1.0, exec_mode="ram"):
    import serial  # pyserial, from the ESP-IDF Python environment
    st_serial, _, _ = probe(os.environ.get("BOARD_ST_SERIAL", "") or DEFAULT_ST_SERIAL)
    try:
        port = serial.Serial(port_name, BAUD, timeout=0.05)
    except Exception as e:
        raise BoardUnavailable("cannot open %s: %s" % (port_name, e))
    try:
        port.reset_input_buffer()
        load_and_start(image, st_serial, exec_mode)
        return capture(port, timeout, send, send_delay)
    finally:
        port.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image", nargs="?")
    ap.add_argument("--port")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--out")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--probe", action="store_true", help="check the ST-LINK and print port, chip and serial")
    mode.add_argument("--list-ports", action="store_true", help="print the candidate serial ports")
    mode.add_argument("--print-openocd", action="store_true", help="print the OpenOCD command for the image and exit")
    ap.add_argument("--expect-serial", default=os.environ.get("BOARD_ST_SERIAL", "") or DEFAULT_ST_SERIAL,
                    help="with --probe: the ST-LINK serial required (default $BOARD_ST_SERIAL, then the lab board's)")
    ap.add_argument("--expect-mac", default="", help="accepted and ignored (ESP32 interface)")
    ap.add_argument("--send", help="text to write to the console after the start marker (Python escapes, e.g. 'exit\\n')")
    ap.add_argument("--send-delay", type=float, default=1.0, help="seconds after the start marker before --send is written")
    ap.add_argument("--send-marker", help="with --send: also wait until the output holds this marker (then quiet), as the host harness does")
    ap.add_argument("--send-marker-count", type=int, default=1, help="occurrences of --send-marker to wait for (default 1)")
    ap.add_argument("--exec", dest="exec_mode", choices=("ram", "flash"), default="ram",
                    help="ram (default): load into SRAM1; flash: program the main flash (BY HAND ONLY, wears the flash; needs --yes-wear-flash)")
    ap.add_argument("--yes-wear-flash", action="store_true",
                    help="with --exec flash: confirm that this run erases and reprograms flash pages")
    a = ap.parse_args()
    if a.exec_mode == "flash" and not a.yes_wear_flash:
        sys.stderr.write(FLASH_WEAR_WARNING)
        sys.stderr.write("run_on_board: refused: --exec flash needs --yes-wear-flash\n")
        return 2
    if a.yes_wear_flash and a.exec_mode != "flash":
        ap.error("--yes-wear-flash is only meaningful with --exec flash")
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
        if a.print_openocd:
            if not a.image:
                ap.error("an image is required")
            cmd = (openocd_flash_command(a.image, a.expect_serial) if a.exec_mode == "flash"
                   else openocd_command(a.image, a.expect_serial, int(time.time() * 1000)))
            print(" ".join("'%s'" % c if " " in c else c for c in cmd))
            return 0
        port = pick_port(a.port)
        if a.probe:
            serial_no, chipid, dev = probe(a.expect_serial)
            print("%s %s %s" % (port, dev or chipid, serial_no))
            return 0
        if not a.image:
            ap.error("an image is required")
        if a.exec_mode == "flash":
            sys.stderr.write(FLASH_WEAR_WARNING)
        out, status, diag = run_on_board(port, a.image, a.timeout, send, a.send_delay, a.exec_mode)
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
