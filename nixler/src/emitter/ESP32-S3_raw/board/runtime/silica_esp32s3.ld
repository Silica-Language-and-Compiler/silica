/*
   Copyright 2026 Lee Scott Barney

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

/* Bare-metal ESP32-S3 image, loaded by the ROM from flash offset 0x0 (in place of the second-stage
   bootloader) straight into internal SRAM. No flash cache / XIP: everything runs from RAM.

   Internal SRAM1 is one physical array seen at two addresses: the instruction bus at 0x4037_8000
   and the data bus at 0x3FC8_8000 (offset 0x6F_0000). Code is placed first from the bottom on the
   instruction bus; data starts where the code ends, on the data bus, so the two never overlap.

   Upper limit 0x3FCE_9700: the ROM keeps its own stack and data above that while it loads the
   image (ESP-IDF's bootloader.memory.ld.in uses the same bound). SRAM0 (0x4037_0000-0x4037_7FFF)
   is left alone because the ROM can configure it as instruction cache.

   Byte and halfword loads from the instruction bus fault on this chip, so every byte of data --
   strings, tables, .rodata of any kind -- must be in a data-bus section. Only code and L32R
   literal pools go on the instruction bus. */

ENTRY(_start)

_silica_iram_dram_offset = 0x6F0000;
_silica_sram_dram_end    = 0x3FCE9700;
_silica_fault_stack_size = 0x800;

/* main's two stacks are sized per image: tools/build_image.sh links once with the defaults below,
   bounds `main` with tools/main_stack_bound.py (the deepest chain of windowed frames from _start and
   the deepest auxiliary-stack reservation, plus margin), and links again with
   --defsym _silica_main_stack_req=N --defsym _silica_main_aux_req=M (given before -T, so they are
   defined when the statements below run). A `main` the walk cannot bound (recursion reachable from
   it, or a call through a function value) keeps these defaults: 128 KB of machine stack (~2000
   nested 48-byte frames) and 64 KB of auxiliary stack, the budget the port had before the per-image
   bound (design_documents/actor_memory_budget_plan.md §4.1). _silica_rt_depth_reserve is the deepest
   runtime chain emitted code can call in this image (the same tool, --defsym _silica_rt_depth_req);
   the emitted prologue keeps that much above the machine stack's guard band. */
_silica_main_stack_size  = DEFINED(_silica_main_stack_req) ? _silica_main_stack_req : 0x20000;
_silica_main_aux_size    = DEFINED(_silica_main_aux_req)   ? _silica_main_aux_req   : 0x10000;
_silica_rt_depth_reserve = DEFINED(_silica_rt_depth_req)   ? _silica_rt_depth_req   : 0x400;

MEMORY
{
  iram (RX) : org = 0x40378000, len = 0x61700
  dram (RW) : org = 0x3FC88000, len = 0x61700
}

SECTIONS
{
  .iram0.text :
  {
    _silica_vecbase = ABSOLUTE(.);
    KEEP(*(.WindowVectors.text));
    . = 0x180;
    KEEP(*(.Level2InterruptVector.text));
    . = 0x1c0;
    KEEP(*(.Level3InterruptVector.text));
    . = 0x200;
    KEEP(*(.Level4InterruptVector.text));
    . = 0x240;
    KEEP(*(.Level5InterruptVector.text));
    . = 0x280;
    KEEP(*(.DebugExceptionVector.text));
    . = 0x2c0;
    KEEP(*(.NMIExceptionVector.text));
    . = 0x300;
    KEEP(*(.KernelExceptionVector.text));
    . = 0x340;
    KEEP(*(.UserExceptionVector.text));
    . = 0x3c0;
    KEEP(*(.DoubleExceptionVector.text));
    . = 0x400;
    *(.*Vector.literal)
    *(.literal .literal.* .text .text.*)
    . = ALIGN(16);
    _silica_iram_end = ABSOLUTE(.);
  } > iram

  .dram0.rodata (_silica_iram_end - _silica_iram_dram_offset) :
  {
    _silica_rodata_start = ABSOLUTE(.);
    /* {function address, name} records the emitter writes for every function (the actor failure
       report names the failing behaviour with them); placed before the general pattern below. Each
       record is a link-order section tied to its function's .text section, so --gc-sections drops
       the record with an unused function and keeps it with a used one (no KEEP here: KEEP would
       retain every function through the record's address word). */
    . = ALIGN(4);
    _silica_fnames_start = ABSOLUTE(.);
    *(.rodata.silica_fnames)
    _silica_fnames_end = ABSOLUTE(.);
    *(.rodata .rodata.* .srodata .srodata.*)
    . = ALIGN(8);
  } > dram

  .dram0.data :
  {
    _silica_data_start = ABSOLUTE(.);
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(8);
    _silica_data_end = ABSOLUTE(.);
  } > dram

  .dram0.bss (NOLOAD) :
  {
    . = ALIGN(16);
    _silica_bss_start = ABSOLUTE(.);
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(16);
    _silica_bss_end = ABSOLUTE(.);
    /* one fault stack per core: core 0's ends at _silica_fault_stack_top, core 1's just below it
       (rt_vectors.S FAULT_STACK_TOP) */
    _silica_fault_stack_bottom = ABSOLUTE(.);
    . += _silica_fault_stack_size * 2;
    _silica_fault_stack_top = ABSOLUTE(.);
    /* main's auxiliary stack (the emitter's SP); 64-byte aligned for the guard watchpoint */
    . = ALIGN(64);
    silica_rt_aux_stack_bottom = ABSOLUTE(.);
    . += _silica_main_aux_size;
    silica_rt_aux_stack_top = ABSOLUTE(.);
  } > dram

  _silica_heap_start = ALIGN(silica_rt_aux_stack_top, 16);
  _silica_stack_top  = _silica_sram_dram_end & ~15;
  _silica_heap_end   = (_silica_stack_top - _silica_main_stack_size) & ~63;

  ASSERT(_silica_heap_start < _silica_heap_end, "program too large: no room left for the heap")
  ASSERT((_silica_main_aux_size & 63) == 0, "_silica_main_aux_size must be a multiple of 64")
  ASSERT((_silica_vecbase & 0x3FF) == 0, "VECBASE must be 1 KB aligned")

  /* .xt.prop / .xt.lit are kept: the linker's literal and branch relaxation reads them. */
  /DISCARD/ : { *(.comment) *(.note.*) }
}
