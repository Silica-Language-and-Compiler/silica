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

/* Bare-metal STM32L476RG image, loaded into SRAM by the debug probe (OpenOCD over the Nucleo's
   ST-LINK: board/tools/run_on_board.py) and started at _start; nothing is written to flash.

   Two RAM regions, as probed on the board on 2026-11-07 (BOARD_DESCRIPTION.md): SRAM1, 96 KiB at
   0x2000_0000-0x2001_7FFF, and SRAM2, 32 KiB at 0x1000_0000-0x1000_7FFF. SRAM2 is NOT mapped at
   0x2001_8000 on this part (a write there bus-faults), so the two are separate regions. SRAM1 holds
   the image: the vector table first (VTOR points at it: rt_start.S), code and read-only data, data,
   bss, then the heap as the leftover below main's machine stack, which ends at the top of SRAM1.
   SRAM2 holds the stacks that must survive an SRAM1 stack problem: the fault stack (the fatal report
   runs on it whatever state the main stack is in) and main's auxiliary stack (the emitter's SP); the
   rest of SRAM2 is the second heap arena, for actor stack chunks only (rt_heap.S arena 1; Lee
   2026-11-09): the chunk allocator tries it first and falls back to the SRAM1 heap.

   Budget: main's machine stack 6 KiB by default (build_image.sh BOARD_MAIN_STACK / --defsym
   _silica_main_stack_req), main's auxiliary stack 2 KiB (BOARD_MAIN_AUX), the fault stack 1 KiB, the
   scheduler's stack 1 KiB (rt_actors.S .bss, SRAM1); an actor costs its ACB (208 B, SRAM1 heap) plus
   2 KiB machine + 512 B auxiliary chunks at its first dispatch (SRAM2 arena first), growing by
   doubling. With the default main aux stack the SRAM2 arena is 29,696 bytes (0x10000C00-0x10008000):
   the first chunks of 11 actors (2,592 B each with their block headers). The smoke images leave about
   76 KiB of SRAM1 heap; a base-suite image (program ~10-15 KiB) about 64 KiB. */

ENTRY(_start)

_silica_sram1_base = 0x20000000;
_silica_sram1_end  = 0x20018000;
_silica_sram2_base = 0x10000000;
_silica_sram2_end  = 0x10008000;
_silica_fault_stack_size = 0x400;

_silica_main_stack_size  = DEFINED(_silica_main_stack_req) ? _silica_main_stack_req : 0x1800;
_silica_main_aux_size    = DEFINED(_silica_main_aux_req)   ? _silica_main_aux_req   : 0x800;
/* The deepest runtime chain emitted code can call (every emitted prologue keeps that much above the
   chunk's band): the runtime routines here are shallow; 512 bytes covers them and an exception frame. */
_silica_rt_depth_reserve = DEFINED(_silica_rt_depth_req)   ? _silica_rt_depth_req   : 0x200;
_silica_ffi_stack_size   = DEFINED(_silica_ffi_stack_req)  ? _silica_ffi_stack_req  : 0x800;

MEMORY
{
  sram1 (RWX) : org = 0x20000000, len = 0x18000
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
    /* {function address, name} records the emitter writes for every function (the actor failure
       report names the failing behaviour with them). Each record is a link-order section tied to its
       function's .text section, so --gc-sections drops the record with an unused function. */
    _silica_fnames_start = ABSOLUTE(.);
    *(.rodata.silica_fnames)
    _silica_fnames_end = ABSOLUTE(.);
    *(.rodata .rodata.*)
    . = ALIGN(16);
    _silica_text_end = ABSOLUTE(.);
  } > sram1

  .data :
  {
    _silica_data_start = ABSOLUTE(.);
    *(.data .data.*)
    . = ALIGN(16);
    _silica_data_end = ABSOLUTE(.);
  } > sram1

  .bss (NOLOAD) :
  {
    . = ALIGN(16);
    _silica_bss_start = ABSOLUTE(.);
    *(.bss .bss.* COMMON)
    . = ALIGN(16);
    _silica_bss_end = ABSOLUTE(.);
  } > sram1

  /* SRAM2: the fault stack and main's auxiliary stack (rt_start.S zeroes [_silica_sram2_used_start,
     _silica_sram2_used_end) before anything uses them: the aux stack's high-water mark is read at exit),
     then the stack-chunk arena up to the end of SRAM2 (rt_heap.S zeroes every block it hands out). */
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

  ASSERT(_silica_heap_start + 0x4000 < _silica_heap_end, "program too large: less than 16 KiB left for the heap")
  ASSERT(_silica_sram2_heap_start <= _silica_sram2_heap_end, "SRAM2 overflow: the fault stack and main's auxiliary stack exceed 32 KiB")
  ASSERT((_silica_main_aux_size & 63) == 0, "_silica_main_aux_size must be a multiple of 64")

  /DISCARD/ : { *(.comment) *(.note.*) *(.ARM.exidx*) *(.ARM.attributes) }
}
