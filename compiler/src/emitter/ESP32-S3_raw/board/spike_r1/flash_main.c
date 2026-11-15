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

// Route R1 spike (transport_ble_plan.md stage 12): the first code run from flash on the chip the
// bare-metal runtime owns. main, in RAM, maps the flash (spike_flash.c) and calls a function that was
// linked into the flash's code, which prints a text linked into the flash's constants.

#include <stdint.h>

void silica_rt_puts(const char *s);
int spike_flash_map(void);

static const char text[] __attribute__((section(".flash.rodata.hello"))) = "hello from flash, text and all\n";

static uint32_t __attribute__((noinline, section(".flash.text.hello"))) hello(uint32_t n)
{
    silica_rt_puts(text);
    return n * 3 + 1;
}

static void put_hex32(uint32_t v)
{
    char buf[11] = "0x00000000";
    for (int i = 0; i < 8; i++) {
        buf[9 - i] = "0123456789ABCDEF"[(v >> (4 * i)) & 15];
    }
    silica_rt_puts(buf);
}

long long main(void)
{
    int rc = spike_flash_map();
    if (rc != 0) {
        silica_rt_puts("flash not mapped\n");
        return 1;
    }
    silica_rt_puts("flash mapped; calling ");
    put_hex32((uint32_t)hello);
    silica_rt_puts("\n");
    static const uint32_t regs[] = { 0x600C4060, 0x600C4064, 0x600C4000, 0x600C4004, 0x600C5010 };
    silica_rt_puts("icache ctrl, ctrl1, dcache ctrl, ctrl1, page 4:");
    for (unsigned i = 0; i < 5; i++) {
        silica_rt_puts(" ");
        put_hex32(*(volatile uint32_t *)regs[i]);
    }
    silica_rt_puts("\n");
    // what the two mappings show, as words, for comparison with the image's parts
    silica_rt_puts("code ");
    put_hex32(*(volatile uint32_t *)0x42040000);
    silica_rt_puts(" ");
    put_hex32(*(volatile uint32_t *)0x42040008);
    silica_rt_puts(", the code's page through the data bus ");
    put_hex32(*(volatile uint32_t *)0x3C040000);
    silica_rt_puts(", constants ");
    put_hex32(*(volatile uint32_t *)0x3C000000);
    silica_rt_puts("\n");
    uint32_t answer = hello(13);
    silica_rt_puts(answer == 40 ? "the function answered 40\n" : "the function answered wrongly\n");
    return answer == 40 ? 0 : 1;
}
