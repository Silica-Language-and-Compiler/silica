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

// What ESP-IDF puts on the stack that is running when an interrupt or an exception arrives: one
// exception frame (xtensa_context.h XT_STK_FRMSZ; a nested interrupt lands on ESP-IDF's interrupt
// stack), and for a fault the frames of the handler that carries it to Silica (guest.c
// silica_guest_exception and silica_guest_fault_enter, 48 + 32 bytes with their spill areas, rounded
// up). tools/build_image.sh reads the symbol from the built application and adds it to the reserve
// every Silica stack keeps above its guard band.
#include "xtensa_context.h"

    .global silica_guest_stack_allowance
    .set    silica_guest_stack_allowance, XT_STK_FRMSZ + 192
