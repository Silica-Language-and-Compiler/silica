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

// Transport builtins for the bare-metal ESP32-S3 runtime (transport_serialization_design.md §9.2):
// the six of them that read or build a string or walk a list. On the hosted targets these are the
// L_tr_* helpers the emitter pastes into a module (terms/prims/prims_transport.silica there); here
// the emitter calls them (this target's terms/prims/prims_transport.silica), as it calls rt_string.S
// and rt_list.S. The scalar transport prims (float bits, conversions, widths) are register work in
// the emitter and have no routine here.
//
// Layouts are the emitter's: a string is the 24-byte header of rt_string.S (+8 data, +16 length), a
// list the handle and data chunks of rt_list.S ([0] length, [8] first chunk, [16] cursor; 8-byte
// slots, two per 16-byte chunk data area, the next chunk at [chunk + 16]). The atom tables are the
// runtime unit's silica_rt_atom_name_count and silica_rt_atom_names (a word table of pointers to
// NUL-terminated lexemes, one per atom index; weak zero defaults in rt_actors.S); a lexeme carries its
// leading colon, the name on the wire has none, so both atom routines skip it.
//
// Silica pair ABI (arguments in a2:a3, a4:a5, a6:a7; result a2:a3; a8-a15 temporaries):
//   silica_rt_tr_byte_at(s, i)           -> int64   byte i of s; i outside [0, length) fails
//   silica_rt_tr_byte_slice(s, b0, b1)   -> string  bytes [b0, b1) of s; b1 > length or b0 > b1 fails
//   silica_rt_tr_bytes_of(xs)            -> string  the low byte of each int64 of xs
//   silica_rt_tr_join_bytes(parts)       -> string  the strings of parts, concatenated once
//   silica_rt_tr_atom_name(a)            -> string  the name of atom a; an index past the table fails
//   silica_rt_tr_atom_index(s)           -> int64   the atom whose name is s, or -1
// A fresh string is built in the running frame's dynamic part (silica_rt_string_alloc /
// silica_rt_string_from_bytes, rt_string.S, through silica_rt_frame_alloc), so the emitted function
// that holds the prim has a frame floor (emitter_core frame_allocating_prim). An empty result is the
// shared silica_rt_empty_string. A bounds failure is the string's byte range failure: inside an actor
// it ends the actor with (:explicit, :buf_bounds), in main it is the runtime abort of the same site
// (silica_rt_buf_bounds_failed, rt_console.S), where the hosted helpers trap with BRK #1.

    .section .text.silica_rt_transport, "ax"
    .literal_position

    .align  4
    .global silica_rt_tr_byte_at
    .type   silica_rt_tr_byte_at, @function
silica_rt_tr_byte_at:
    entry   a1, 32
    beqz    a2, 9f
    bnez    a5, 9f                // index at or above 2^32, or negative
    l32i    a8, a2, 16            // length
    bgeu    a4, a8, 9f
    l32i    a8, a2, 8             // data
    add     a8, a8, a4
    l8ui    a2, a8, 0
    movi    a3, 0
    retw
9:  call8   silica_rt_buf_bounds_failed
    retw
    .size   silica_rt_tr_byte_at, . - silica_rt_tr_byte_at

    .align  4
    .global silica_rt_tr_byte_slice
    .type   silica_rt_tr_byte_slice, @function
silica_rt_tr_byte_slice:
    entry   a1, 32
    beqz    a2, 9f
    bnez    a5, 9f
    bnez    a7, 9f
    l32i    a8, a2, 16            // length
    bltu    a8, a6, 9f            // end > length
    bltu    a6, a4, 9f            // start > end
    sub     a7, a6, a4            // n
    beqz    a7, 8f
    l32i    a10, a2, 8
    add     a10, a10, a4          // p = data + start
    movi    a11, 0
    mov     a12, a7               // n
    movi    a13, 0
    call8   silica_rt_string_from_bytes
    mov     a2, a10
    movi    a3, 0
    retw
8:  movi    a2, silica_rt_empty_string
    movi    a3, 0
    retw
9:  call8   silica_rt_buf_bounds_failed
    retw
    .size   silica_rt_tr_byte_slice, . - silica_rt_tr_byte_slice

// Local: a2 = list handle (0 = nil), a4 = element count. Walks the chunks: a7 = chunk, a3 = cursor.
    .align  4
    .global silica_rt_tr_bytes_of
    .type   silica_rt_tr_bytes_of, @function
silica_rt_tr_bytes_of:
    entry   a1, 32
    movi    a4, 0
    beqz    a2, 1f
    l32i    a4, a2, 0             // count
1:  beqz    a4, 8f
    mov     a10, a4
    call8   silica_rt_string_alloc
    mov     a5, a10               // result
    addi    a6, a10, 24           // dst
    l32i    a7, a2, 8             // chunk
    l32i    a3, a2, 16            // cursor
2:  beqz    a4, 3f
    add     a8, a7, a3
    l32i    a8, a8, 0             // the element's low word
    s8i     a8, a6, 0
    addi    a6, a6, 1
    addi    a3, a3, 8
    movi    a8, 16
    bltu    a3, a8, 4f
    l32i    a7, a7, 16            // next chunk
    movi    a3, 0
4:  addi    a4, a4, -1
    j       2b
3:  mov     a2, a5
    movi    a3, 0
    retw
8:  movi    a2, silica_rt_empty_string
    movi    a3, 0
    retw
    .size   silica_rt_tr_bytes_of, . - silica_rt_tr_bytes_of

// Two walks over the parts: the byte total (a5), then the copy. A nil part contributes nothing.
    .align  4
    .global silica_rt_tr_join_bytes
    .type   silica_rt_tr_join_bytes, @function
silica_rt_tr_join_bytes:
    entry   a1, 32
    movi    a5, 0                 // total
    beqz    a2, 1f
    l32i    a4, a2, 0             // count
    l32i    a7, a2, 8             // chunk
    l32i    a3, a2, 16            // cursor
2:  beqz    a4, 1f
    add     a8, a7, a3
    l32i    a8, a8, 0             // the part
    beqz    a8, 3f
    l32i    a8, a8, 16            // its length
    add     a5, a5, a8
3:  addi    a3, a3, 8
    movi    a8, 16
    bltu    a3, a8, 4f
    l32i    a7, a7, 16
    movi    a3, 0
4:  addi    a4, a4, -1
    j       2b
1:  beqz    a5, 8f
    mov     a10, a5
    call8   silica_rt_string_alloc
    mov     a5, a10               // result
    addi    a6, a10, 24           // dst
    l32i    a4, a2, 0
    l32i    a7, a2, 8
    l32i    a3, a2, 16
5:  beqz    a4, 7f
    add     a8, a7, a3
    l32i    a8, a8, 0             // the part
    beqz    a8, 6f
    l32i    a9, a8, 8             // src
    l32i    a8, a8, 16            // n
51: beqz    a8, 6f
    l8ui    a12, a9, 0
    s8i     a12, a6, 0
    addi    a9, a9, 1
    addi    a6, a6, 1
    addi    a8, a8, -1
    j       51b
6:  addi    a3, a3, 8
    movi    a8, 16
    bltu    a3, a8, 52f
    l32i    a7, a7, 16
    movi    a3, 0
52: addi    a4, a4, -1
    j       5b
7:  mov     a2, a5
    movi    a3, 0
    retw
8:  movi    a2, silica_rt_empty_string
    movi    a3, 0
    retw
    .size   silica_rt_tr_join_bytes, . - silica_rt_tr_join_bytes

    .align  4
    .global silica_rt_tr_atom_name
    .type   silica_rt_tr_atom_name, @function
silica_rt_tr_atom_name:
    entry   a1, 32
    bnez    a3, 9f
    movi    a8, silica_rt_atom_name_count
    l32i    a8, a8, 0
    bgeu    a2, a8, 9f
    movi    a8, silica_rt_atom_names
    addx4   a8, a2, a8
    l32i    a4, a8, 0             // the lexeme
    l8ui    a8, a4, 0
    movi    a9, 58                // ':'
    bne     a8, a9, 1f
    addi    a4, a4, 1
1:  movi    a5, 0                 // length
2:  add     a8, a4, a5
    l8ui    a8, a8, 0
    beqz    a8, 3f
    addi    a5, a5, 1
    j       2b
3:  beqz    a5, 8f
    mov     a10, a4
    movi    a11, 0
    mov     a12, a5
    movi    a13, 0
    call8   silica_rt_string_from_bytes
    mov     a2, a10
    movi    a3, 0
    retw
8:  movi    a2, silica_rt_empty_string
    movi    a3, 0
    retw
9:  call8   silica_rt_buf_bounds_failed
    retw
    .size   silica_rt_tr_atom_name, . - silica_rt_tr_atom_name

// Linear over the table (the hosted helper's walk): a4 = the name's byte count, a5 = its bytes,
// a6 = the atom count, a7 = the index tried.
    .align  4
    .global silica_rt_tr_atom_index
    .type   silica_rt_tr_atom_index, @function
silica_rt_tr_atom_index:
    entry   a1, 32
    beqz    a2, 9f
    l32i    a4, a2, 16
    l32i    a5, a2, 8
    movi    a8, silica_rt_atom_name_count
    l32i    a6, a8, 0
    movi    a7, 0
1:  bgeu    a7, a6, 9f
    movi    a8, silica_rt_atom_names
    addx4   a8, a7, a8
    l32i    a8, a8, 0             // the lexeme
    l8ui    a9, a8, 0
    movi    a10, 58
    bne     a9, a10, 2f
    addi    a8, a8, 1
2:  mov     a9, a5                // p
    mov     a10, a4               // bytes left
3:  beqz    a10, 4f
    l8ui    a11, a8, 0
    l8ui    a12, a9, 0
    bne     a11, a12, 5f
    beqz    a11, 5f               // the lexeme ended inside the name
    addi    a8, a8, 1
    addi    a9, a9, 1
    addi    a10, a10, -1
    j       3b
4:  l8ui    a11, a8, 0
    bnez    a11, 5f               // the lexeme is longer
    mov     a2, a7
    movi    a3, 0
    retw
5:  addi    a7, a7, 1
    j       1b
9:  movi    a2, -1
    movi    a3, -1
    retw
    .size   silica_rt_tr_atom_index, . - silica_rt_tr_atom_index
