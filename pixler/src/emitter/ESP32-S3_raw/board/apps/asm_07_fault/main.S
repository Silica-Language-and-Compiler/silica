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

// Bring-up app 07: fault reporting. Loads from address 0, which the ESP32-S3 does not map, so the
// CPU raises LoadProhibited (EXCCAUSE 28). The runtime's vector must turn that into the fatal fault
// report of spec §15.4.5.5 -- the path every emitted-code crash will take, so it has to work before
// any compiled program runs.
// Expected console: "about to load from 0x0", then "[silica] fault at 0x4037....  addr=0x00000000"
// (LoadProhibited sets EXCVADDR), then the exit marker with status 70 and, after it,
// " fault: exccause=28 epc=0x4037.... excvaddr=0x00000000".

    .section .text.main, "ax"
    .literal_position
    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 32
    movi    a10, msg
    call8   silica_rt_puts
    call8   silica_rt_flush
    movi    a3, 0
    l32i    a2, a3, 0
    movi    a2, 0
    movi    a3, 0
    retw
    .size   main, . - main

    .section .rodata.main, "a"
msg: .asciz "about to load from 0x0\n"
