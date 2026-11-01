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

// Bring-up app 00: the runtime alone. Proves the ROM loads the image, _start takes over (vectors,
// stack, watchdogs), UART0 output works, and main's int64 result becomes the exit status.
// Expected console, between the markers: "hello from silica on esp32s3\n", then status 42.

    .section .text.main, "ax"
    .literal_position
    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 32
    movi    a10, hello_msg
    call8   silica_rt_puts
    movi    a2, 42                // int64 result: a2 = low word
    movi    a3, 0                 //               a3 = high word
    retw
    .size   main, . - main

    .section .rodata.main, "a"
hello_msg:
    .asciz  "hello from silica on esp32s3\n"
