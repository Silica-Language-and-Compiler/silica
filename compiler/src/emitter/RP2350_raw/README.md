# RP2350_raw: Raspberry Pi Pico 2 W emit target

Status (2026-11-12): directory created; nothing is built yet.

- Board: Raspberry Pi Pico 2 W (a microcontroller board, not a hosted computer).
- Chip: RP2350, dual Arm Cortex-M33 (ARMv8-M Mainline, Thumb-2) at up to 150 MHz, about 520 KB SRAM, 4 MB flash.
  This target uses the Arm cores. (The chip can also boot its Hazard3 RISC-V cores; they are not currently targeted.)
  Whether the two core types can run together (one Arm core and one RISC-V core at once) is open: sources disagree.
  It could be explored through the datasheet (the Arm/RISC-V architecture switching section) and early
  experimentation on the board.
- Closest existing chip, assembly wise: **STM32-L476RG (Arm Cortex-M4, ARMv7E-M, Thumb-2)**, the chip of `STM32-L476RG_raw` (Nucleo).
  The M33 runs the same Thumb-2 instruction family as the M4 (the ESP32-S3's Xtensa LX7 is a different ISA), so
  the `STM32-L476RG_raw` (Nucleo) emitter is the base and `ESP32-S3_raw` is not.
- Wireless: Infineon CYW43439 (Wi-Fi and Bluetooth) over gSPI.
- Naming follows the other raw targets (`ESP32-S3_raw`, `STM32-L476RG_raw`): the chip, then `_raw`.

## Plan

1. **Port of the `STM32-L476RG_raw` (Nucleo) compiler.** This target starts as a port of that emitter and its board
   runtime to the RP2350 (Cortex-M4 to Cortex-M33: same Thumb-2 base; the differences to check are the ARMv8-M
   additions, the TrustZone and security state, the RP2350 memory map and peripherals, and the boot path).
   `../ESP32-S3_raw` is only a reference for how a raw target's board and transport parts are laid out.
2. **Wi-Fi and Bluetooth in Silica.** In addition to that port, wifi and bluetooth are added to this compiler's
   transport implementation (the transport pack and carriers, see
   `../../../design_documents/transport_serialization_design.md` and `transport_links_design.md`). The
   `(:wifi, n)` link and a Bluetooth carrier are provided by this target's pack.
3. **The blob is used; everything else is engineered in Silica.** The only non-Silica artefacts are the CYW43439
   firmware (and its CLM/calibration data and the Bluetooth controller firmware), which are proprietary Infineon
   binaries loaded into the chip at boot and embedded in the build as data. The gSPI bus protocol, the Wi-Fi host
   driver, the Bluetooth HCI transport and the host stack are written in Silica.

## Datasheets

- [RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf) (the chip: cores, memory map,
  peripherals, boot, the Arm/RISC-V architecture select).
- [Pico 2 W datasheet](https://pip-assets.raspberrypi.com/categories/1088-raspberry-pi-pico-2-w/documents/RP-008304-DS-2-pico-2-w-datasheet.pdf)
  (the board: pinout, the CYW43439 wiring).

## References (read for understanding; none is a source being ported)

The Silica implementation is written from the protocols and behaviour these projects document. No code is ported
from them. Check each project's licence before reading it closely, because some terms restrict commercial use.

- **Infineon Bluetooth controller firmware (the blob) and its host-side package:**
  [Infineon/ifx-linux-bluetooth](https://github.com/Infineon/ifx-linux-bluetooth) (lists CYW43439) and
  [Infineon/ifx-linux-firmware](https://github.com/Infineon/ifx-linux-firmware) (firmware directory). The exact
  CYW43439 Bluetooth firmware file is not yet confirmed in either; find it before relying on a path here. The
  Wi-Fi firmware and CLM blobs are also published with
  [Infineon/wifi-host-driver](https://github.com/Infineon/wifi-host-driver).
- **cyw43 driver** (the Pico SDK's driver for the chip, Wi-Fi and Bluetooth over gSPI):
  [georgerobotics/cyw43-driver](https://github.com/georgerobotics/cyw43-driver). Its licence is custom
  (free for non-commercial use; separate terms for Raspberry Pi hardware), which is another reason it is a
  reference and not a source.
- **NimBLE** (Apache's open-source Bluetooth host and controller stack):
  [apache/mynewt-nimble](https://github.com/apache/mynewt-nimble). A reference for the host-side protocol
  layering (HCI, L2CAP, ATT/GATT, SM) that the Silica Bluetooth implementation provides.
