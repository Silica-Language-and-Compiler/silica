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

"""Run a bare-metal STM32L476RG (NUCLEO-L476RG) RAM image in QEMU instead of on the board.

    SILICA_BOARD_EMULATOR=qemu run_on_board.py [--timeout S] [--out FILE]
                    [--send TEXT [--send-delay S] [--send-marker M [--send-marker-count N]]] image.elf
    SILICA_BOARD_EMULATOR=qemu run_on_board.py --probe | --list-ports | --print-qemu image.elf
    run_in_qemu.py ...                (the same, without the variable)

run_on_board.py hands its whole command line to this module when SILICA_BOARD_EMULATOR=qemu, as the
ESP32-S3_raw runner does, so the STM32-L476RG_raw trial target runs in QEMU with that variable set
(see ../QEMU.md). The interface, the console protocol (the START / EXIT markers, --send after the start
marker and the trial's marker) and the exit statuses are those of the board runner, whose capture code
this one imports; only the load differs. The image is the one build_image.sh builds with
SILICA_BOARD_EMULATOR=qemu (the board's runtime, linker script and emitted code, BOARD_QEMU defined).

The machine: QEMU's `b-l475e-iot01a`, an STM32L475VG. The L475 and the L476 are the same STM32L4x5/L4x6
die family: Cortex-M4F at 80 MHz, SRAM1 96 KiB at 0x2000_0000, SRAM2 32 KiB at 0x1000_0000, the same RCC,
GPIO, EXTI, SYSCFG and USART blocks at the same addresses. The runtime's console is USART2 (PA2/PA3), the
Nucleo's ST-LINK virtual COM port; QEMU attaches its serial devices to USART1, USART2, ... in order, so
the first -serial is null and the second is the console, a TCP socket on 127.0.0.1 this runner reads.

The load: the board's OpenOCD resumes at `_start` after `reset halt`; QEMU instead starts a Cortex-M from
the vector table at address 0 (the flash alias). The runner writes an 8-byte vector table into flash at
0x0800_0000 (initial sp = the top of SRAM1, reset = _start) and loads the ELF's segments into SRAM with
QEMU's generic loader; `_start` then sets sp and VTOR itself, as on the board. Nothing else is in flash.
The wall clock: as on the board, the host's Unix time in milliseconds is written into the runtime's
`silica_rt_wall_clock` (.data) before the start, here by patching a copy of the ELF.

What the model does not have (see ../QEMU.md): the ST-LINK, real timing (QEMU runs as fast as the host
lets it, SysTick follows the host's clock), the flash interface (FLASH_ACR is an unimplemented device:
reads give 0, so build_image.sh assembles the runtime with BOARD_QEMU under SILICA_BOARD_EMULATOR=qemu),
and bus faults on unmapped addresses that the silicon raises.

Environment: SILICA_QEMU_ARM, the qemu-system-arm to run (default: the one on PATH, then Homebrew's);
SILICA_QEMU_MACHINE (default b-l475e-iot01a); SILICA_QEMU_EXTRA, extra QEMU arguments (shell words).

Exit status: 0 a marker pair was seen; 3 no exit marker before the timeout (the raw console goes to
stderr); 4 the emulator is unavailable (no qemu-system-arm, it exited before the console opened, a
missing symbol); 2 usage. Needs only the standard library.
"""

import argparse
import importlib.util
import os
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BOARD_RUNNER = os.path.join(HERE, "run_on_board.py")

sys.dont_write_bytecode = True   # no __pycache__ left in tools/
_spec = importlib.util.spec_from_file_location("stm32_run_on_board", BOARD_RUNNER)
board = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(board)

EXIT_TIMEOUT = board.EXIT_TIMEOUT
EXIT_BOARD = board.EXIT_BOARD
BoardUnavailable = board.BoardUnavailable

MACHINE = os.environ.get("SILICA_QEMU_MACHINE", "b-l475e-iot01a")
FLASH_BASE = 0x08000000
SRAM1_TOP = 0x20018000
CONNECT_TIMEOUT = 20


def qemu_binary():
    q = os.environ.get("SILICA_QEMU_ARM", "")
    if q:
        if not (os.path.isfile(q) and os.access(q, os.X_OK)):
            raise BoardUnavailable("SILICA_QEMU_ARM is not an executable (%s)" % q)
        return q
    q = shutil.which("qemu-system-arm")
    if q:
        return q
    for c in ("/opt/homebrew/bin/qemu-system-arm", "/usr/local/bin/qemu-system-arm"):
        if os.access(c, os.X_OK):
            return c
    raise BoardUnavailable("qemu-system-arm not found on PATH (brew install qemu, or set SILICA_QEMU_ARM)")


def qemu_version(qemu):
    try:
        r = subprocess.run([qemu, "--version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise BoardUnavailable("%s does not start: %s" % (qemu, e))
    text = r.stdout.decode(errors="replace").strip()
    if r.returncode != 0:
        raise BoardUnavailable("%s does not start: %s" % (qemu, " | ".join(text.splitlines()[:3])))
    return text.splitlines()[0] if text else "qemu"


def machine_available(qemu):
    r = subprocess.run([qemu, "-machine", "help"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
    return any(line.split()[:1] == [MACHINE] for line in r.stdout.decode(errors="replace").splitlines())


def elf_patch_word64(path, addr, value):
    """Write the 64-bit little-endian value at load address addr of the ELF32 file at path (in place).
    Returns False when no loaded segment holds the address in its file image."""
    with open(path, "r+b") as f:
        ident = f.read(52)
        if ident[:4] != b"\x7fELF" or ident[4] != 1 or ident[5] != 1:
            raise BoardUnavailable("%s is not a little-endian ELF32 file" % path)
        e_phoff, = struct.unpack_from("<I", ident, 28)
        e_phentsize, e_phnum = struct.unpack_from("<HH", ident, 42)
        for i in range(e_phnum):
            f.seek(e_phoff + i * e_phentsize)
            p_type, p_offset, p_vaddr, p_paddr, p_filesz = struct.unpack("<IIIII", f.read(20))
            if p_type == 1 and p_vaddr <= addr and addr + 8 <= p_vaddr + p_filesz:
                f.seek(p_offset + (addr - p_vaddr))
                f.write(struct.pack("<Q", value & 0xFFFFFFFFFFFFFFFF))
                return True
    return False


def write_vector_elf(path, payload, addr):
    """A minimal ELF32 (ARM, one PT_LOAD) holding payload at addr. QEMU's generic loader takes a raw
    file only up to the machine's RAM size (0 on this machine), but places an ELF anywhere, flash too."""
    ehsize, phsize = 52, 32
    data_off = ehsize + phsize
    ehdr = struct.pack("<4sBBBB8xHHIIIIIHHHHHH", b"\x7fELF", 1, 1, 1, 0,
                       2, 40, 1, addr | 1, ehsize, 0, 0x05000200, ehsize, phsize, 1, 0, 0, 0)
    phdr = struct.pack("<IIIIIIII", 1, data_off, addr, addr, len(payload), len(payload), 5, 4)
    with open(path, "wb") as f:
        f.write(ehdr + phdr + payload)


def stage_image(image, workdir, wall_ms):
    """The files QEMU loads: the boot vector table and a copy of the ELF with the wall clock set."""
    syms = board.elf_symbols(image, ("_start", "silica_rt_wall_clock"))
    if "_start" not in syms:
        raise BoardUnavailable("%s has no _start symbol" % image)
    if board.is_flash_image(syms):
        raise BoardUnavailable("%s is a flash image (_start 0x%08x); the QEMU target runs RAM images only" % (image, syms["_start"]))
    vectors = os.path.join(workdir, "boot_vectors.elf")
    write_vector_elf(vectors, struct.pack("<II", SRAM1_TOP, syms["_start"] | 1), FLASH_BASE)
    elf = os.path.join(workdir, "image.elf")
    shutil.copyfile(image, elf)
    if wall_ms is not None and "silica_rt_wall_clock" in syms:
        elf_patch_word64(elf, syms["silica_rt_wall_clock"], wall_ms)
    return vectors, elf


def qemu_command(qemu, vectors, elf, port):
    cmd = [qemu, "-machine", MACHINE, "-display", "none", "-nographic", "-monitor", "none",
           "-serial", "null",                                        # USART1
           "-serial", "tcp:127.0.0.1:%d,server=on,wait=on" % port,   # USART2: the console (the guest starts once the runner is attached)
           "-device", "loader,file=%s" % vectors,
           "-device", "loader,file=%s" % elf]
    cmd += shlex.split(os.environ.get("SILICA_QEMU_EXTRA", ""))
    return cmd


class SocketPort:
    """The read/write/flush subset of a pyserial port that board.capture uses."""

    def __init__(self, sock):
        self._sock = sock
        self._sock.settimeout(0.05)

    def read(self, n):
        try:
            return self._sock.recv(n)
        except socket.timeout:
            return b""
        except OSError:
            return b""

    def write(self, data):
        self._sock.sendall(data)

    def flush(self):
        pass


def _drain(pipe, bucket, limit=65536):
    try:
        while True:
            chunk = pipe.read(4096)
            if not chunk:
                break
            bucket.extend(chunk)
            if len(bucket) > limit:
                del bucket[:len(bucket) - limit]
    except Exception:
        pass


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _connect(port, proc, stderr_tail, drainer):
    deadline = time.time() + CONNECT_TIMEOUT
    last = "timed out"
    while time.time() < deadline:
        if proc.poll() is not None:
            drainer.join(timeout=2)
            note = " | ".join(l.strip() for l in bytes(stderr_tail).decode(errors="replace").splitlines() if l.strip())[:400]
            raise BoardUnavailable("qemu exited before the console opened (status %s)%s"
                                   % (proc.returncode, (": " + note) if note else ""))
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=1)
        except OSError as e:
            last = str(e)
            time.sleep(0.05)
    raise BoardUnavailable("qemu console did not accept a connection: %s" % last)


def run_under_qemu(image, timeout, send=None, send_delay=1.0):
    qemu = qemu_binary()
    workdir = tempfile.mkdtemp(prefix="silica-stm32-qemu-")
    proc = None
    try:
        vectors, elf = stage_image(image, workdir, int(time.time() * 1000))
        # The free port can be taken between the probe and QEMU's bind; a lost race is retried.
        for attempt in range(3):
            port = _free_port()
            stderr_tail = bytearray()
            proc = subprocess.Popen(qemu_command(qemu, vectors, elf, port), stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
            drainer = threading.Thread(target=_drain, args=(proc.stderr, stderr_tail), daemon=True)
            drainer.start()
            try:
                sock = _connect(port, proc, stderr_tail, drainer)
                break
            except BoardUnavailable as e:
                if attempt == 2 or "Address already in use" not in str(e):
                    raise
                proc = None
        try:
            out, status, diag = board.capture(SocketPort(sock), timeout, send, send_delay)
        finally:
            sock.close()
        if out is None:
            note = bytes(stderr_tail).decode(errors="replace").strip()
            if note:
                diag = diag + b"\n" + note.encode()
            if proc.poll() is not None:
                diag = diag + ("\nqemu exited %s" % proc.returncode).encode()
        return out, status, diag
    finally:
        if proc is not None:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except OSError:
                    proc.kill()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        shutil.rmtree(workdir, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image", nargs="?")
    ap.add_argument("--port", help="accepted and ignored (the console is QEMU's TCP socket)")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--out")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--probe", action="store_true", help="check QEMU and its machine; print a description")
    mode.add_argument("--list-ports", action="store_true", help="print the pseudo port name, qemu")
    mode.add_argument("--print-qemu", action="store_true", help="print the QEMU command for the image and exit")
    ap.add_argument("--exec", dest="exec_mode", choices=("ram", "flash"), default="ram",
                    help="ram only: QEMU runs RAM images (flash is refused)")
    ap.add_argument("--expect-serial", default="", help="accepted and ignored (board interface)")
    ap.add_argument("--expect-mac", default="", help="accepted and ignored (board interface)")
    ap.add_argument("--send", help="text to write to the console after the start marker (Python escapes, e.g. 'exit\\n')")
    ap.add_argument("--send-delay", type=float, default=1.0, help="seconds after the start marker before --send is written")
    ap.add_argument("--send-marker", help="with --send: also wait until the output holds this marker (then quiet)")
    ap.add_argument("--send-marker-count", type=int, default=1, help="occurrences of --send-marker to wait for (default 1)")
    a = ap.parse_args()
    if a.exec_mode != "ram":
        sys.stderr.write("run_on_board: --exec flash is refused under SILICA_BOARD_EMULATOR=qemu (RAM images only)\n")
        return 2
    if a.send_marker:
        board.SEND_MARKER = a.send_marker.encode("utf-8")
        board.SEND_MARKER_COUNT = max(1, a.send_marker_count)
    send = None
    if a.send is not None:
        send = a.send.encode("utf-8").decode("unicode_escape").encode("latin-1")

    if a.list_ports:
        print("qemu")
        return 0
    try:
        if a.probe:
            qemu = qemu_binary()
            version = qemu_version(qemu)
            if not machine_available(qemu):
                raise BoardUnavailable("%s has no machine %s (QEMU 9.0 or later models the STM32L4x5)" % (qemu, MACHINE))
            print("qemu %s (STM32L4x5 model standing in for the NUCLEO-L476RG; %s)" % (MACHINE, version))
            return 0
        if not a.image:
            ap.error("an image is required")
        if a.print_qemu:
            workdir = tempfile.mkdtemp(prefix="silica-stm32-qemu-")
            vectors, elf = stage_image(a.image, workdir, int(time.time() * 1000))
            print(" ".join(shlex.quote(c) for c in qemu_command(qemu_binary(), vectors, elf, 5555)))
            print("(staged files kept in %s)" % workdir, file=sys.stderr)
            return 0
        out, status, diag = run_under_qemu(a.image, a.timeout, send, a.send_delay)
    except BoardUnavailable as e:
        sys.stderr.write("run_on_board: %s\n" % e)
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
