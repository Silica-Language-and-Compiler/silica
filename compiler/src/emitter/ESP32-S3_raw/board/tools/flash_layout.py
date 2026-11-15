#!/usr/bin/env python3
# Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this is merged)
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

"""Code and constants that run from flash, for a bare-metal image (transport_ble_plan.md stage 12).

    flash_layout.py script <silica_esp32s3.ld> <out.ld> <file pattern>...
    flash_layout.py ram <linked.elf> <ram.elf>
    flash_layout.py merge <ram.bin> <rodata.bin> <text.bin> <out.bin>

script: writes a copy of the runtime's linker script in which the code (.literal, .text) and the
constants (.rodata) of the files matching the patterns (as the linker matches them: *libphy.a) are
placed at the addresses the flash is mapped to, with every section named .flash.text* or
.flash.rodata*. Everything else stays in RAM as before: data, .bss, and code a file marks for RAM
(.iram1). The script defines _silica_flash_{text,rodata}_{start,end} and _silica_flash_{text,rodata}_offset.

ram: writes a copy of the linked ELF in which the two flash sections are marked as holding no bytes
(as .bss is), so the image tool builds the part the ROM loads into RAM from the rest. The sections
stay: the function-name records in RAM are linked to the code they name.

merge: writes the flash image: the RAM part the ROM loads at offset 0, then the constants and the
code at the offsets below, each on a 64 KB page boundary, where the program maps them at its start.
"""

import struct
import sys

RODATA_OFFSET = 0x80000     # 512 KB for the RAM part before it
TEXT_OFFSET = 0xC0000       # 256 KB of constants before it
# The chip has one table of flash pages, seen through both buses: page n is at 0x3C000000 + n * 64 KB on
# the data bus and at 0x42000000 + n * 64 KB on the instruction bus. The constants take pages 0 to 3 and
# the code the pages from 4.
RODATA_ADDRESS = 0x3C000000
TEXT_ADDRESS = 0x42040000


def script(src, out, patterns):
    text = open(src).read()
    files = ' '.join(patterns)

    def exclude(names):
        return ' '.join('EXCLUDE_FILE(%s) %s' % (files, n) for n in names.split())

    def swap(old):
        nonlocal text
        if text.count(old) != 1:
            sys.exit('flash_layout: the linker script has no single "%s"' % old)
        text = text.replace(old, '*(' + exclude(old[2:-1]) + ')')

    swap('*(.literal .literal.* .text .text.*)')
    swap('*(.rodata .rodata.* .srodata .srodata.*)')
    memory = '  dram (RW) : org = 0x3FC88000, len = 0x61700\n'
    if text.count(memory) != 1:
        sys.exit('flash_layout: the linker script has no dram region as expected')
    text = text.replace(memory, memory +
                        '  irom (RX) : org = 0x%X, len = 0x140000\n  drom (R)  : org = 0x%X, len = 0x40000\n'
                        % (TEXT_ADDRESS, RODATA_ADDRESS))
    tail = '  /* .xt.prop / .xt.lit are kept'
    if text.count(tail) != 1:
        sys.exit('flash_layout: the linker script has no place for the flash sections')
    text = text.replace(tail, '''  _silica_flash_text_offset = 0x%X;
  _silica_flash_rodata_offset = 0x%X;

  .flash.text :
  {
    _silica_flash_text_start = ABSOLUTE(.);
    *(.flash.text .flash.text.*)
    *(.literal .literal.* .text .text.*)
    /* the names Espressif's Wi-Fi and radio libraries give code that ESP-IDF may keep in RAM: no flash
       operation here ever takes the flash away from under it */
    *(.wifi0iram .wifi0iram.* .wifirxiram .wifirxiram.* .wifislpiram .wifislpiram.* .wifislprxiram .wifislprxiram.*)
    *(.wifiextrairam .wifiextrairam.* .wifiorslpiram .wifiorslpiram.* .phyiram .phyiram.* .coexiram .coexiram.* .coexsleepiram .coexsleepiram.*)
    . = ALIGN(4);
    _silica_flash_text_end = ABSOLUTE(.);
  } > irom

  .flash.rodata :
  {
    _silica_flash_rodata_start = ABSOLUTE(.);
    *(.flash.rodata .flash.rodata.*)
    *(.rodata .rodata.* .srodata .srodata.*)
    *(.rodata_wlog .rodata_wlog_*)
    . = ALIGN(4);
    _silica_flash_rodata_end = ABSOLUTE(.);
  } > drom

''' % (TEXT_OFFSET, RODATA_OFFSET) + tail)
    open(out, 'w').write(text)


def ram(src, out):
    elf = bytearray(open(src, 'rb').read())
    if elf[:6] != b'\x7fELF\x01\x01':
        sys.exit('flash_layout: %s is not a 32-bit little-endian ELF' % src)
    shoff, = struct.unpack_from('<I', elf, 32)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', elf, 46)
    names_at, = struct.unpack_from('<I', elf, shoff + shstrndx * shentsize + 16)
    found = 0
    for i in range(shnum):
        at = shoff + i * shentsize
        name_off, = struct.unpack_from('<I', elf, at)
        name = bytes(elf[names_at + name_off:elf.index(b'\0', names_at + name_off)]).decode()
        if name in ('.flash.text', '.flash.rodata'):
            struct.pack_into('<I', elf, at + 4, 8)      # SHT_NOBITS
            found += 1
    if found != 2:
        sys.exit('flash_layout: %s has %d of the two flash sections' % (src, found))
    open(out, 'wb').write(elf)


def merge(ram, rodata, code, out):
    parts = [(0, open(ram, 'rb').read()), (RODATA_OFFSET, open(rodata, 'rb').read()), (TEXT_OFFSET, open(code, 'rb').read())]
    if len(parts[0][1]) > RODATA_OFFSET:
        sys.exit('flash_layout: the RAM part is %d bytes, over %d' % (len(parts[0][1]), RODATA_OFFSET))
    if len(parts[1][1]) > TEXT_OFFSET - RODATA_OFFSET:
        sys.exit('flash_layout: the constants are %d bytes, over %d' % (len(parts[1][1]), TEXT_OFFSET - RODATA_OFFSET))
    image = bytearray()
    for offset, data in parts:
        image += b'\xff' * (offset - len(image))
        image += data
    open(out, 'wb').write(image)


if __name__ == '__main__':
    if len(sys.argv) >= 5 and sys.argv[1] == 'script':
        script(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif len(sys.argv) == 4 and sys.argv[1] == 'ram':
        ram(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 6 and sys.argv[1] == 'merge':
        merge(*sys.argv[2:])
    else:
        sys.exit(__doc__)
