#!/usr/bin/env python3
# Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this is merged)
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

"""Run a guest image (tools/build_image.sh here) on the board: ../../tools/run_on_board.py in its
flash mode. A guest image is an ESP-IDF application with its bootloader, so it is written to flash
and the board reset, where a bare-metal image is loaded into RAM. Every option of that script
passes through; --flash is added to a run that names an image.
"""

import os
import sys

target = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "run_on_board.py")
args = sys.argv[1:]
modes = {"--flash", "--no-flash", "--probe", "--list-ports"}
if not modes.intersection(args):
    args = ["--flash"] + args
os.execv(sys.executable, [sys.executable, target] + args)
