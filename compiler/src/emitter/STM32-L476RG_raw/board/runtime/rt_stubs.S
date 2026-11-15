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

// Runtime entries the emitter can reference that stage 1 of the STM32-L476RG_raw port does not
// implement yet. Each is a Thumb function that ends the program with the runtime abort
// "[silica] abort: runtime entry not yet ported to STM32-L476RG_raw at 0x<pc>" (status 71), the
// address being the stub's own, so a program that needs one fails loudly at the first use and the
// image always links. Remove an entry here when its real routine lands in another rt_*.S file
// (a duplicate definition is a link error, which is the point). The list is derived from every
// `silica_rt_*` name the emitter tree references (board/tools/list_runtime_stubs.sh regenerates it).

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

    .section .text.silica_rt_stubs, "ax", %progbits

.macro STUB name
    FUNC \name
    bl      silica_rt_unsupported
    .size   \name, . - \name
.endm

    // message_copy / message_measure: named only in a comment of terms/term_message_copy.silica (the
    // script counts comments too); no emitted code calls them and the ESP32-S3 runtime defines neither
    // (the copier's entries are message_buffer / message_forward / reply_place, rt_state.S).
    STUB silica_rt_message_copy
    STUB silica_rt_message_measure
    // region_alloc / region_grow: named only in comments (emitter_core.silica, term_emit_kind_compound_part2,
    // prims_memory.silica: "the heap path through silica_rt_region_grow is gone"); chunk 15 removed both from
    // emitted code (a frame's allocations live in its dynamic part, rt_frame.S) and the ESP32-S3 runtime
    // defines neither (rt_heap.S there: "The aliases silica_rt_region_alloc ... are gone").
    STUB silica_rt_region_alloc
    STUB silica_rt_region_grow
    // supervisor_start: named only in a comment of module_linkage.silica ("to be wired in a subsequent
    // phase"); no emitted code calls it and the ESP32-S3 runtime defines none (a supervisor starts through
    // its start trampoline and silica_rt_supervisor_materialize_init_children, rt_supervisors.S).
    STUB silica_rt_supervisor_start
