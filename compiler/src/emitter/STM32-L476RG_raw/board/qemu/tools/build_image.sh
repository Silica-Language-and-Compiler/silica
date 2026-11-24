#!/bin/sh
# Copyright 2026 Lee Scott Barney
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Build a STM32L476RG RAM image for the QEMU trial target (STM32-L476RG_qemu): the board's image builder,
# ../../tools/build_image.sh, with the same arguments, runtime, linker script and emitted code, and the one
# difference QEMU's model needs: every source is assembled with BOARD_QEMU defined, so rt_start.S does not
# wait for the FLASH_ACR read-back QEMU cannot give (see ../README.md). Flash images are refused: the QEMU
# runner loads RAM images only.

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
if [ "${BOARD_EXEC:-ram}" != ram ]; then
    echo "$0: the QEMU target builds RAM images only (BOARD_EXEC=${BOARD_EXEC})" >&2
    exit 2
fi
BOARD_ASFLAGS="${BOARD_ASFLAGS:-} -Wa,--defsym,BOARD_QEMU=1" exec sh "$HERE/../../tools/build_image.sh" "$@"
