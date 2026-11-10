#!/usr/bin/env python3
"""Bridge a serial port to a TCP peer, byte for byte, both ways.

    serial_to_tcp_bridge.py --port /dev/cu.usbserial-XXXX [--baud 115200] [--host 127.0.0.1] --tcp-port 4041
                            [--timeout 60] [--hex]

The board's UART1 carrier speaks the same length-prefixed bytes as a TCP (:stream) carrier, so the Erlang
peer of transport_beam_demo (gen_tcp, {packet, 4}) reads the board's frame unchanged once the serial bytes
are copied into its socket ("a host bridges it to its network", transport_serialization_design.md §6.4).
The bridge connects to the TCP peer, copies serial -> TCP and TCP -> serial, and ends when the peer closes
the socket or nothing moves for --timeout seconds; --hex prints every chunk it moves, as hex, with its
direction (the bytes of the ETF frames as they crossed). The port is the board's UART1 adapter or its
USB-Serial-JTAG port (/dev/cu.usbmodem*, 303A:1001); pyserial's default open leaves DTR and RTS high, which
that port needs (setting them low resets the chip). Needs pyserial (run it with the ESP-IDF environment's
Python, as the board tools are).
"""
import argparse, socket, sys, threading, time

try:
    import serial
except ImportError:
    sys.exit("serial_to_tcp_bridge: pyserial is not installed in this Python")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--tcp-port", type=int, required=True)
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--hex", action="store_true", help="print every chunk moved, as hex, with its direction")
    a = ap.parse_args()
    # Opened in two steps so that pyserial's open() does not flush the receive side: on the board's
    # USB-Serial-JTAG port a frame the board sent before the port was opened is already in the macOS
    # driver's buffer when open() runs, and pyserial 3.5's open() ends with tcflush(TCIFLUSH), which threw
    # it away (seen 2026-11-09: the Erlang peer timed out while the Silica peer, whose termios open does
    # not flush, read the same frame). DTR and RTS are left at pyserial's default, high (see the docstring).
    ser = serial.Serial()
    ser.port, ser.baudrate, ser.timeout = a.port, a.baud, 0.1
    ser._reset_input_buffer = lambda: None
    ser.open()
    sock = socket.create_connection((a.host, a.tcp_port))
    sock.settimeout(0.1)
    last = [time.monotonic()]
    done = threading.Event()
    counts = {"to_tcp": 0, "to_serial": 0}

    def serial_to_tcp():
        while not done.is_set():
            data = ser.read(4096)
            if data:
                sock.sendall(data)
                counts["to_tcp"] += len(data)
                last[0] = time.monotonic()
                if a.hex:
                    print("serial -> tcp %d bytes: %s" % (len(data), data.hex()), flush=True)

    def tcp_to_serial():
        while not done.is_set():
            try:
                data = sock.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            if not data:
                print("bridge: peer closed the socket")
                done.set()
                break
            ser.write(data)
            counts["to_serial"] += len(data)
            last[0] = time.monotonic()
            if a.hex:
                print("tcp -> serial %d bytes: %s" % (len(data), data.hex()), flush=True)

    t1 = threading.Thread(target=serial_to_tcp, daemon=True)
    t2 = threading.Thread(target=tcp_to_serial, daemon=True)
    t1.start(); t2.start()
    while not done.is_set():
        time.sleep(0.1)
        if time.monotonic() - last[0] > a.timeout:
            print("bridge: idle for %.0f s, giving up" % a.timeout)
            done.set()
    time.sleep(0.2)
    print("bridge: %d bytes serial -> tcp, %d bytes tcp -> serial" % (counts["to_tcp"], counts["to_serial"]))
    try: sock.close()
    except OSError: pass
    ser.close()
    return 0 if counts["to_tcp"] > 0 else 1

if __name__ == "__main__":
    sys.exit(main())
