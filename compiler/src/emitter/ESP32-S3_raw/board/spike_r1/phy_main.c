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

// Route R1 spike, step 1b (transport_ble_plan.md stage 12): on a chip the bare-metal runtime owns, start
// the radio. The steps are those of ESP-IDF's esp_phy_enable (esp_phy/src/phy_init.c) with nothing of
// FreeRTOS or NVS under them: the clocks as clocks_main.c brings them, the chip's analog settings
// (rtc_init), the modem's power domain and clocks, then Espressif's closed register_chipv7_phy with the
// default init data and a full calibration. Prints the library's version, what the call answered and
// how long it took. Built by build.sh with libphy.a and ESP-IDF's phy_init_data.c.

#include <stdint.h>
#include <string.h>
#include "soc/rtc.h"
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"
#include "soc/syscon_reg.h"
#include "soc/system_reg.h"
#include "soc/efuse_reg.h"
#include "soc/systimer_reg.h"
#include "esp_rom_serial_output.h"
#include "esp_rom_sys.h"
#include "esp_phy_init.h"
#include "esp_private/phy.h"
#include "phy_init_data.h"

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

// The system timer's count, 16 MHz from the crystal whatever the CPU's clock: unit 0, low word.
static uint32_t ticks(void)
{
    REG_WRITE(SYSTIMER_UNIT0_OP_REG, SYSTIMER_TIMER_UNIT0_UPDATE);
    while (!(REG_READ(SYSTIMER_UNIT0_OP_REG) & SYSTIMER_TIMER_UNIT0_VALUE_VALID)) {
    }
    return REG_READ(SYSTIMER_UNIT0_VALUE_LO_REG);
}

// What the radio library asks of its host. Interrupts are masked for the whole of the bare-metal
// runtime, so its critical sections are already held.
uint32_t phy_enter_critical(void)
{
    return 0;
}

void phy_exit_critical(uint32_t level)
{
    (void)level;
}

int phy_printf(const char *format, ...)
{
    silica_rt_puts("phy: ");
    silica_rt_puts(format);
    return 0;
}

// The library builds its version text with sprintf; without a C library the text is its format.
int sprintf(char *out, const char *format, ...)
{
    int n = 0;
    while (format[n] != 0) {
        out[n] = format[n];
        n++;
    }
    out[n] = 0;
    return n;
}

int coex_pti_print(const char *format, ...)
{
    (void)format;
    return 0;
}

static esp_phy_calibration_data_t cal_data;

long long main(void)
{
    esp_rom_output_tx_wait_idle(0);
    rtc_clk_config_t clk = RTC_CLK_CONFIG_DEFAULT();
    clk.cpu_freq_mhz = 80;
    rtc_clk_init(clk);
#ifdef SPIKE_RTC_INIT
    rtc_config_t rtc = RTC_CONFIG_DEFAULT();
    rtc_init(rtc);
#endif
    rtc_cpu_freq_config_t c;
    rtc_clk_cpu_freq_get_config(&c);
    silica_rt_puts("clocks: cpu ");
    put_dec(c.freq_mhz);
    silica_rt_puts(" MHz, source ");
    put_dec((uint32_t)c.source);
    silica_rt_puts("\n");

    // the modem's power domain on, its blocks reset under their common clock (esp_wifi_bt_power_domain_on)
    CLEAR_PERI_REG_MASK(RTC_CNTL_DIG_PWC_REG, RTC_CNTL_WIFI_FORCE_PD);
    esp_rom_delay_us(10);
    SET_PERI_REG_MASK(SYSTEM_WIFI_CLK_EN_REG, SYSTEM_WIFI_CLK_WIFI_BT_COMMON_M);
    SET_PERI_REG_MASK(SYSCON_WIFI_RST_EN_REG, MODEM_RESET_FIELD_WHEN_PU);
    CLEAR_PERI_REG_MASK(SYSCON_WIFI_RST_EN_REG, MODEM_RESET_FIELD_WHEN_PU);
    CLEAR_PERI_REG_MASK(RTC_CNTL_DIG_ISO_REG, RTC_CNTL_WIFI_FORCE_ISO);

    // the clocks of the radio's calibration, the random number generator and the Wi-Fi block, which the
    // library's calibration uses (esp_phy_common_clock_enable, phy_module_enable)
    SET_PERI_REG_MASK(SYSTEM_WIFI_CLK_EN_REG, SYSTEM_WIFI_CLK_PHY_EN_M | SYSTEM_WIFI_CLK_RNG_EN | SYSTEM_WIFI_CLK_WIFI_EN_M);
    silica_rt_puts("modem: power and clocks on\n");

    silica_rt_puts("phy version: ");
    silica_rt_puts(get_phy_version_str());
    silica_rt_puts("\n");

    phy_init_param_set(1);
    uint32_t lo = REG_READ(EFUSE_RD_MAC_SPI_SYS_0_REG);
    uint32_t hi = REG_READ(EFUSE_RD_MAC_SPI_SYS_1_REG);
    cal_data.mac[0] = (uint8_t)(hi >> 8);
    cal_data.mac[1] = (uint8_t)hi;
    cal_data.mac[2] = (uint8_t)(lo >> 24);
    cal_data.mac[3] = (uint8_t)(lo >> 16);
    cal_data.mac[4] = (uint8_t)(lo >> 8);
    cal_data.mac[5] = (uint8_t)lo;

    silica_rt_puts("register_chipv7_phy: calling\n");
    esp_rom_output_tx_wait_idle(0);
    uint32_t t0 = ticks();
    int answer = register_chipv7_phy(&phy_init_data, &cal_data, PHY_RF_CAL_FULL);
    uint32_t t1 = ticks();
    silica_rt_puts("register_chipv7_phy: answered ");
    put_dec((uint32_t)answer);
    silica_rt_puts(" after ");
    put_dec((t1 - t0) / 16000);
    silica_rt_puts(" ms\n");

    // the calibration the library made: a sum over it, to tell a filled table from an untouched one
    uint32_t sum = 0;
    for (unsigned i = 0; i < sizeof(cal_data.opaque); i++) {
        sum += cal_data.opaque[i];
    }
    silica_rt_puts("calibration data: sum ");
    put_dec(sum);
    silica_rt_puts("\n");
    return 0;
}
