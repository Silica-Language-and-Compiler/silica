/*
   Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this leaves the spike)

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

// Stage 4 spike: the memory silica_esp32s3.ld lays out for the bare-metal image, as one block of
// ESP-IDF's .bss (zeroed by ESP-IDF's start-up, as rt_start.S zeroes it). The names and their order
// are the linker script's: main's auxiliary stack, the heap, main's machine stack. Throwaway.

#define GUEST_AUX_SIZE        0x1000     // main's auxiliary stack (a multiple of 64)
#define GUEST_HEAP_SIZE       0x18000    // 96 KB
#define GUEST_MAIN_STACK_SIZE 0x8000     // main's machine stack
// The machine-stack reserve every emitted prologue keeps above a chunk's guard band. The bare-metal
// image measures it per program (2768 for a small one); here an interrupt frame can land on whatever
// stack is running, so it is larger.
#define GUEST_DEPTH_RESERVE   0x1000
#define GUEST_FFI_STACK       0x2000     // a foreign call now reaches ESP-IDF code

    .global _silica_main_stack_size
    .global _silica_main_aux_size
    .global _silica_rt_depth_reserve
    .global _silica_ffi_stack_size
    .global _silica_iram_dram_offset
    .set    _silica_main_stack_size, GUEST_MAIN_STACK_SIZE
    .set    _silica_main_aux_size, GUEST_AUX_SIZE
    .set    _silica_rt_depth_reserve, GUEST_DEPTH_RESERVE
    .set    _silica_ffi_stack_size, GUEST_FFI_STACK
    .set    _silica_iram_dram_offset, 0x6F0000

    .section .bss.silica_guest_mem, "aw", @nobits
    .balign 64
    .global silica_rt_aux_stack_bottom
    .global silica_rt_aux_stack_top
    .global _silica_heap_start
    .global _silica_heap_end
    .global _silica_stack_top
silica_rt_aux_stack_bottom:
    .space  GUEST_AUX_SIZE
silica_rt_aux_stack_top:
    .balign 16
_silica_heap_start:
    .space  GUEST_HEAP_SIZE
    .balign 64
_silica_heap_end:
    .space  GUEST_MAIN_STACK_SIZE
_silica_stack_top:
    .space  64                           // the caller's spill area of the first frame

// The {function address, name} table the linker script collects: empty here, so a failure report
// names no behaviour.
    .section .rodata.silica_guest_mem, "a"
    .balign 4
    .global _silica_fnames_start
    .global _silica_fnames_end
_silica_fnames_start:
_silica_fnames_end:
    .word   0
