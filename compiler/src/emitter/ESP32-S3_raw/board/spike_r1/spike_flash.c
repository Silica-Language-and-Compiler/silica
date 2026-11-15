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

// Route R1 spike (transport_ble_plan.md stage 12): code and constants run from flash on the chip the
// bare-metal runtime owns. An image built with BOARD_FLASH_FILES (tools/flash_layout.py) has a part the
// ROM loads into RAM and two parts left in flash; spike_flash_map, in the RAM part, does what ESP-IDF's
// bootloader does for an application before it starts it: the cache and the flash chip set up, the two
// parts mapped at the addresses they were linked for, the cache on. It is ESP-IDF's own code, from its
// bootloader's libraries. Nothing in flash may be called before it returns.

#include <stdint.h>
#include "soc/soc.h"
#include "hal/cache_hal.h"
#include "hal/cache_ll.h"
#include "hal/mmu_hal.h"
#include "hal/mmu_types.h"
#include "bootloader_init.h"
#include "bootloader_flash_config.h"

int bootloader_init_spi_flash(void);
void rom_config_instruction_cache_mode(uint32_t size, uint8_t ways, uint8_t line);

extern char _silica_flash_text_start[], _silica_flash_text_end[], _silica_flash_text_offset[];
extern char _silica_flash_rodata_start[], _silica_flash_rodata_end[], _silica_flash_rodata_offset[];

int spike_flash_map(void)
{
    bootloader_init_ext_mem();
    bootloader_flash_update_id();
    int rc = bootloader_read_bootloader_header();
    if (rc != 0) {
        return rc;
    }
    rc = bootloader_init_spi_flash();
    if (rc != 0) {
        return rc;
    }
    uint32_t text = (uint32_t)_silica_flash_text_start, text_size = (uint32_t)(_silica_flash_text_end - _silica_flash_text_start);
    uint32_t rodata = (uint32_t)_silica_flash_rodata_start, rodata_size = (uint32_t)(_silica_flash_rodata_end - _silica_flash_rodata_start);
    uint32_t mapped = 0;
    cache_hal_disable(CACHE_LL_LEVEL_EXT_MEM, CACHE_TYPE_ALL);
    mmu_hal_unmap_all();
    // The instruction cache's size, ways and line: ESP-IDF's application sets them at its own start,
    // before its first code in flash, with its configuration's figures (16 KB, 8 ways, 32 bytes). Without
    // this the instruction bus reads zeros where the data bus reads the page.
    rom_config_instruction_cache_mode(0x4000, 8, 32);
    mmu_hal_map_region(0, MMU_TARGET_FLASH0, rodata, (uint32_t)_silica_flash_rodata_offset, rodata_size, &mapped);
    mmu_hal_map_region(0, MMU_TARGET_FLASH0, text, (uint32_t)_silica_flash_text_offset, text_size, &mapped);
    for (int core = 0; core < 2; core++) {
        cache_ll_l1_enable_bus(core, cache_ll_l1_get_bus(core, rodata, rodata_size));
        cache_ll_l1_enable_bus(core, cache_ll_l1_get_bus(core, text, text_size));
    }
    cache_hal_enable(CACHE_LL_LEVEL_EXT_MEM, CACHE_TYPE_ALL);
    return 0;
}
