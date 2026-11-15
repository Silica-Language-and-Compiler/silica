#!/usr/bin/env python3
"""Print the device node of the one ESP32-S3 USB-Serial-JTAG port (USB VID:PID 303A:1001).

    find_usb_serial_jtag_port.py [--wait S]

The node's name changes when the chip re-enumerates (a RAM load resets it), so the port is resolved by
its USB id, never by a /dev/cu.usbmodem* name (board/tools/usb_console_check.py does the same). Exit 0
and the path on stdout; 1 when no such device is present after --wait seconds (default 0); 2 when
several are present (name one yourself). Needs pyserial (run it with the ESP-IDF Python).
"""
import argparse, sys, time

ESPRESSIF_VID = 0x303A
USB_JTAG_SERIAL_PID = 0x1001

def find():
    from serial.tools import list_ports
    return sorted(p.device for p in list_ports.comports()
                  if p.vid == ESPRESSIF_VID and p.pid == USB_JTAG_SERIAL_PID and not p.device.startswith("/dev/tty."))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wait", type=float, default=0.0)
    a = ap.parse_args()
    try:
        import serial  # noqa: F401
    except ImportError:
        sys.exit("find_usb_serial_jtag_port: pyserial is not installed in this Python")
    deadline = time.time() + a.wait
    while True:
        ports = find()
        if len(ports) == 1:
            print(ports[0])
            return 0
        if len(ports) > 1:
            print("several USB-Serial-JTAG devices: " + " ".join(ports), file=sys.stderr)
            return 2
        if time.time() >= deadline:
            print("no ESP32-S3 USB-Serial-JTAG device (303A:1001) present", file=sys.stderr)
            return 1
        time.sleep(0.2)

if __name__ == "__main__":
    sys.exit(main())
