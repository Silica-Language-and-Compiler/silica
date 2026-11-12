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

# estimate_actors.sh <image base (no extension)> <main.silica>
#
# Prints the flash footprint and the SRAM budget of a flash image from its linker map (<base>.map), then
# the number of worker actors that fit (MAX), by replaying the runtime's allocations against the two heap
# arenas (README.md, "The actor-count estimate"). Warns, and exits 1, when estimated_max_actors() in
# main.silica is not that MAX. Reads nothing from the board.
#
# The allocator (board/runtime/rt_heap.S): every block carries a 16-byte header and is rounded up to 16
# bytes; arena 0 is the SRAM1 heap, arena 1 the SRAM2 chunk arena; ACBs and every other runtime block come
# from arena 0; a stack chunk comes from arena 1 when it fits there, else from arena 0. Nothing is freed
# while the program runs, so each arena is a bump allocator here.

set -eu
base=$1
src=$2
map="$base.map"
bin="$base.bin"
[ -f "$map" ] || { echo "no $map: run make build first" >&2; exit 2; }

sym() {
    # the address the map gives a linker-script symbol: "                0x20000cd0   _silica_heap_start = ..."
    v=$(awk -v s="$1" '$2 == s && $1 ~ /^0x/ {print $1; exit}' "$map")
    [ -n "$v" ] || { echo "symbol $1 not in $map" >&2; exit 2; }
    printf '%d' "$v"
}

image_start=$(sym _silica_image_start)
text_end=$(sym _silica_text_end)
flash_end=$(sym _silica_flash_image_end)
data_start=$(sym _silica_data_start)
data_end=$(sym _silica_data_end)
bss_start=$(sym _silica_bss_start)
bss_end=$(sym _silica_bss_end)
heap_start=$(sym _silica_heap_start)
heap_end=$(sym _silica_heap_end)
stack_top=$(sym _silica_stack_top)
s2_used_start=$(sym _silica_sram2_used_start)
s2_used_end=$(sym _silica_sram2_used_end)
s2_heap_start=$(sym _silica_sram2_heap_start)
s2_heap_end=$(sym _silica_sram2_heap_end)

# silica_registry_slots: a word in the program's read-only data (flash), read from the raw image.
slots_addr=$(awk '$2 == "silica_registry_slots" && $1 ~ /^0x/ {print $1; exit}' "$map")
[ -n "$slots_addr" ] || { echo "silica_registry_slots not in $map" >&2; exit 2; }
slots=$(od -A n -t u4 -j $(( $(printf '%d' "$slots_addr") - image_start )) -N 4 "$bin" | tr -d ' ')

expected=$(sed -nE '/^fn estimated_max_actors\(\)/,/^}/ s/^[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$src" | head -n 1)

awk -v image_start="$image_start" -v text_end="$text_end" -v flash_end="$flash_end" \
    -v data_start="$data_start" -v data_end="$data_end" -v bss_start="$bss_start" -v bss_end="$bss_end" \
    -v heap_start="$heap_start" -v heap_end="$heap_end" -v stack_top="$stack_top" \
    -v s2_used_start="$s2_used_start" -v s2_used_end="$s2_used_end" \
    -v s2_heap_start="$s2_heap_start" -v s2_heap_end="$s2_heap_end" \
    -v slots="$slots" -v expected="${expected:-}" '
function blk(n) { return int((n + 16 + 15) / 16) * 16 }        # header + round up (rt_arena_alloc)
function a0(n) { b = blk(n); if (u0 + b > h0) return 0; u0 += b; return 1 }
function chunk(n) { b = blk(n); if (u1 + b <= h1) { u1 += b; return 1 } return a0(n) }
function actor_with_chunks() { return a0(ACB) && chunk(MCH) && chunk(ACH) }
BEGIN {
    ACB = 208; SB = 72; ROW = 112; MSG = 64; MCH = 2048; ACH = 512; MINSLOTS = 64
    h0 = heap_end - heap_start; h1 = s2_heap_end - s2_heap_start; u0 = 0; u1 = 0
    printf "flash:  %6d bytes at 0x%08x (.text+.rodata %d, .data load image %d; %d pages of 2 KiB)\n", \
        flash_end - image_start, image_start, text_end - image_start, flash_end - text_end, int((flash_end - image_start + 2047) / 2048)
    printf "SRAM1:  .data %d + .bss %d at 0x%08x; heap (arena 0) %d bytes 0x%08x-0x%08x; main machine stack %d\n", \
        data_end - data_start, bss_end - bss_start, data_start, h0, heap_start, heap_end, stack_top - heap_end
    printf "SRAM2:  fault stack + main aux stack %d bytes; chunk arena (arena 1) %d bytes 0x%08x-0x%08x\n", \
        s2_used_end - s2_used_start, h1, s2_heap_start, s2_heap_end
    # fixed: the registries (3 tables, 4 bytes per slot), the four actors of the program with their
    # first chunks (reporter, supervisor, tally, spawner), the supervision blocks and child rows, and
    # eight message nodes in flight
    n = (slots < MINSLOTS) ? MINSLOTS : slots
    a0(4 * n); a0(4 * n); a0(4 * n)
    actor_with_chunks()                                  # the reporter (its chunks at its first report)
    actor_with_chunks(); a0(SB)                          # the supervisor and its supervision block
    actor_with_chunks(); a0(SB); a0(ROW)                 # tally
    actor_with_chunks(); a0(SB); a0(ROW)                 # spawner
    for (i = 0; i < 8; i++) a0(MSG)
    f0 = u0; f1 = u1
    max = 0
    # the attempt that fails has already taken some blocks: report what was left before it
    while (1) { s0 = u0; s1 = u1; if (!actor_with_chunks()) break; max++ }
    u0 = s0; u1 = s1
    printf "fixed:  arena 0 %d bytes, arena 1 %d bytes (registries %d slots, 4 actors, 3 SBs, 2 rows, 8 message nodes)\n", f0, f1, n
    printf "worker: %d bytes (ACB %d + machine chunk %d + auxiliary chunk %d, headers included)\n", blk(ACB) + blk(MCH) + blk(ACH), blk(ACB), blk(MCH), blk(ACH)
    printf "MAX = %d workers (arena 0 left %d bytes, arena 1 left %d bytes); the app spawns MAX - 3 = %d\n", max, h0 - u0, h1 - u1, max - 3
    if (expected == "") { print "WARNING: no estimated_max_actors() constant found in the source"; exit 1 }
    if (expected + 0 != max) { printf "WARNING: estimated_max_actors() in the source is %d, the map gives %d: update main.silica\n", expected, max; exit 1 }
    printf "estimated_max_actors() in the source is %d: matches\n", expected
}'
