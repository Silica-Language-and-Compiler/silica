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

/* Bare-metal STM32L476RG image that runs FROM FLASH (build_image.sh BOARD_EXEC=flash; design:
   compiler/design_documents/stm32_flash_execution_design.md). Programmed into the main flash by the
   hand-run loader only (board/tools/run_on_board.py --exec flash --yes-wear-flash): every load costs
   one erase cycle of each page the image covers, so the trial harness never builds or loads this
   layout (it uses silica_stm32l476rg.ld, which this file does not change).

   The vector table, code and read-only data sit at 0x0800_0000, the start of the 1 MiB flash (the
   hardware reads the table there at reset through the boot alias at 0x0, and _start points VTOR at
   it). .data is linked in SRAM1 and loaded from flash right after the read-only data; _start copies
   it before anything reads it (rt_start.S, BOARD_EXEC_FLASH). SRAM1 then holds only .data, .bss, the
   heap and main's machine stack; SRAM2 is laid out exactly as in the RAM image (the fault stack,
   main's auxiliary stack, then the stack-chunk arena). Every budget symbol, default and assert of the
   RAM script is kept with the same name and meaning; see its header comment for the budget. */

ENTRY(_start)

_silica_flash_base = 0x08000000;
_silica_flash_end  = 0x08100000;
_silica_sram1_base = 0x20000000;
_silica_sram1_end  = 0x20018000;
_silica_sram2_base = 0x10000000;
_silica_sram2_end  = 0x10008000;
_silica_fault_stack_size = 0x400;

_silica_main_stack_size  = DEFINED(_silica_main_stack_req) ? _silica_main_stack_req : 0x1800;
_silica_main_aux_size    = DEFINED(_silica_main_aux_req)   ? _silica_main_aux_req   : 0x800;
_silica_rt_depth_reserve = DEFINED(_silica_rt_depth_req)   ? _silica_rt_depth_req   : 0x200;
_silica_ffi_stack_size   = DEFINED(_silica_ffi_stack_req)  ? _silica_ffi_stack_req  : 0x800;

MEMORY
{
  flash (RX)  : org = 0x08000000, len = 0x100000
  sram1 (RW)  : org = 0x20000000, len = 0x18000
  sram2 (RW)  : org = 0x10000000, len = 0x8000
}

SECTIONS
{
  .text :
  {
    _silica_image_start = ABSOLUTE(.);
    KEEP(*(.vectors));
    . = ALIGN(4);
    *(.text .text.*)
    . = ALIGN(4);
    /* the {function address, name} records, as in the RAM script (link-order sections tied to their
       function's .text section, dropped with it by --gc-sections) */
    _silica_fnames_start = ABSOLUTE(.);
    *(.rodata.silica_fnames)
    _silica_fnames_end = ABSOLUTE(.);
    *(.rodata .rodata.*)
    . = ALIGN(16);
    _silica_text_end = ABSOLUTE(.);
  } > flash

  .data :
  {
    _silica_data_start = ABSOLUTE(.);
    *(.data .data.*)
    . = ALIGN(16);
    _silica_data_end = ABSOLUTE(.);
  } > sram1 AT> flash
  _silica_data_load = LOADADDR(.data);
  _silica_flash_image_end = _silica_data_load + SIZEOF(.data);

  .bss (NOLOAD) :
  {
    . = ALIGN(16);
    _silica_bss_start = ABSOLUTE(.);
    *(.bss .bss.* COMMON)
    . = ALIGN(16);
    _silica_bss_end = ABSOLUTE(.);
  } > sram1

  .sram2 (NOLOAD) :
  {
    . = ALIGN(16);
    _silica_sram2_used_start = ABSOLUTE(.);
    _silica_fault_stack_bottom = ABSOLUTE(.);
    . += _silica_fault_stack_size;
    _silica_fault_stack_top = ABSOLUTE(.);
    . = ALIGN(64);
    silica_rt_aux_stack_bottom = ABSOLUTE(.);
    . += _silica_main_aux_size;
    silica_rt_aux_stack_top = ABSOLUTE(.);
    _silica_sram2_used_end = ABSOLUTE(.);
  } > sram2

  _silica_sram2_heap_start = ALIGN(_silica_sram2_used_end, 16);
  _silica_sram2_heap_end   = _silica_sram2_end;

  _silica_heap_start = ALIGN(_silica_bss_end, 16);
  _silica_stack_top  = _silica_sram1_end;
  _silica_heap_end   = (_silica_stack_top - _silica_main_stack_size) & ~63;

  /* The hardware takes the table at the start of flash at reset, and VTOR needs the table aligned to
     its size rounded up to a power of two (98 words: 512 bytes); the flash base satisfies both. */
  ASSERT(silica_rt_vectors == _silica_flash_base, "the vector table must be the first thing in flash")
  ASSERT(_silica_data_start == _silica_sram1_base, ".data must start SRAM1 (nothing else lives below it)")
  ASSERT(_silica_flash_image_end <= _silica_flash_end, "image too large for the 1 MiB flash")
  ASSERT(_silica_heap_start + 0x4000 < _silica_heap_end, "program too large: less than 16 KiB left for the heap")
  ASSERT(_silica_sram2_heap_start <= _silica_sram2_heap_end, "SRAM2 overflow: the fault stack and main's auxiliary stack exceed 32 KiB")
  ASSERT((_silica_main_aux_size & 63) == 0, "_silica_main_aux_size must be a multiple of 64")

  /DISCARD/ : { *(.comment) *(.note.*) *(.ARM.exidx*) *(.ARM.attributes) }
}
