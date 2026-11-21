# size_check_board_addition (board only)

Run trials for the boards' allocation size check (ESP32-S3_raw and STM32-L476RG_raw). Sizes come from
run-time values. Console-only; host runs skip this suite (BOARD_ONLY).

| Trial | Expected |
| --- | --- |
| alloc_buf_size_check_board_main_a | uint8 buffer of 2^32 bytes in main: `invalid buffer size` abort, 71 |
| alloc_buf_size_check_board_main_b | uint8 buffer of 0xF0000000 bytes in main: the same abort, 71 |
| alloc_buf_size_check_board_actor | 100,000,000 bytes in an actor: the actor ends, the reporter prints, exit 0 |
| alloc_buf_size_check_board_atomic_region | atomic region buffer of 0xFFFFFFF0 bytes: the abort, 71 |

The `.esp32_s3.ascomp` and `.st_nucleo.ascomp` goldens are made from a board run once the output matches the
`.scout` (trials/targets/gen_board_ascomp.sh).

On the Nucleo, `alloc_buf_size_check_board_atomic_region` links with a main auxiliary stack of 8 KiB (the file
`alloc_buf_size_check_board_atomic_region.STM32-L476RG_raw.main_aux`, read by targets/board_suite.sh and passed to
build_image.sh as BOARD_MAIN_AUX). The atomic region's block is a 4,128-byte frame allocation and main's default 2 KB
auxiliary stack does not grow, so without it main aborts "out of memory" before the buffer size check is reached.
