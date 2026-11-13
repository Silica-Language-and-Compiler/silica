/*
   Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this is merged)

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

// The memory ../../runtime/silica_esp32s3.ld lays out for the bare-metal image, as one block of
// ESP-IDF's .bss (zeroed by ESP-IDF's start-up): main's auxiliary stack, the heap, main's machine
// stack, in the linker script's order and under its names. tools/build_image.sh assembles this file
// for each image with the sizes it chose:
//   GUEST_HEAP_SIZE        the Silica heap (actors' stacks are chunks of it)
//   GUEST_MAIN_STACK_SIZE  main's machine stack, GUEST_AUX_SIZE its auxiliary stack: from
//                          main_stack_bound.py, or the defaults for a main the walk cannot bound
//   GUEST_DEPTH_RESERVE    what every emitted prologue keeps above a stack's guard band: the deepest
//                          runtime chain emitted code calls (main_stack_bound.py rt_depth) plus what
//                          ESP-IDF puts on whatever stack is running when an interrupt or a fault
//                          arrives (silica_guest_stack_allowance, guest.c)
//   GUEST_FFI_STACK        the machine stack a foreign call runs on

    .global _silica_main_stack_size
    .global _silica_main_aux_size
    .global _silica_rt_depth_reserve
    .global _silica_ffi_stack_size
    .set    _silica_main_stack_size, GUEST_MAIN_STACK_SIZE
    .set    _silica_main_aux_size, GUEST_AUX_SIZE
    .set    _silica_rt_depth_reserve, GUEST_DEPTH_RESERVE
    .set    _silica_ffi_stack_size, GUEST_FFI_STACK

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
    .balign 16
_silica_stack_top:
    .space  64                           // the caller's spill area of the first frame
