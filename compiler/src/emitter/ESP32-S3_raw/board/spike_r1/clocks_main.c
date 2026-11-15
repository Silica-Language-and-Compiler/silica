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

// Route R1 spike, step 1a (transport_ble_plan.md stage 12): on a chip the bare-metal runtime owns,
// bring the clocks to what the radio needs: the 480 MHz PLL running, the CPU and the bus at 80 MHz.
// The clock code is ESP-IDF's own (esp_hw_support/port/esp32s3/rtc_clk*.c), linked as its bootloader
// build compiles it, with no FreeRTOS. Prints the CPU's clock before and after. Built by build.sh.

#include <stdint.h>
#include "soc/rtc.h"
#include "soc/soc.h"
#include "soc/uart_reg.h"
#include "esp_rom_serial_output.h"

void silica_rt_puts(const char *s);

static void put_dec(uint32_t n)
{
    char buf[12];
    int i = 11;
    buf[i] = 0;
    do {
        buf[--i] = (char)('0' + n % 10);
        n /= 10;
    } while (n != 0);
    silica_rt_puts(&buf[i]);
}

// The bus clock, in MHz, from the CPU's clock: the CPU's own up to 80 MHz, 80 MHz when the CPU runs from
// the PLL. (rtc_clk_apb_freq_get reads a figure ESP-IDF's bootloader stores, which nothing has stored here.)
static uint32_t bus_mhz(void)
{
    rtc_cpu_freq_config_t c;
    rtc_clk_cpu_freq_get_config(&c);
    return c.source == SOC_CPU_CLK_SRC_PLL ? 80 : c.freq_mhz;
}

static void show(const char *what)
{
    rtc_cpu_freq_config_t c;
    rtc_clk_cpu_freq_get_config(&c);
    silica_rt_puts(what);
    silica_rt_puts(": cpu ");
    put_dec(c.freq_mhz);
    silica_rt_puts(" MHz, source ");
    put_dec((uint32_t)c.source);
    silica_rt_puts(", bus ");
    put_dec(bus_mhz());
    silica_rt_puts(" MHz\n");
}

long long main(void)
{
    show("before");

    // let the console's bytes out before the clocks move
    esp_rom_output_tx_wait_idle(0);

    rtc_clk_config_t cfg = RTC_CLK_CONFIG_DEFAULT();
    cfg.cpu_freq_mhz = 80;
    rtc_clk_init(cfg);

    // The console keeps its speed: the ROM clocks UART0 from the crystal (source 3), not from the bus.
    silica_rt_puts("uart0 clock source ");
    put_dec((REG_READ(UART_CLK_CONF_REG(0)) >> 20) & 3);
    silica_rt_puts("\n");
    show("after");
    return 0;
}
