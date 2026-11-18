# Benchmarking

Small Erlang and Silica programs for comparing how each runtime handles many lightweight actors/processes.

## spawn_bench.erl (Erlang): process spawn cost

Spawns N idle Erlang processes (default 1,000,000) and reports spawn time, memory per process and teardown time. With `--send` it also sends every process one message and waits for all replies, timing delivery and the round trip.

```sh
./run.sh                    # 1,000,000 processes
./run.sh 100000             # a different count
./run.sh 100000 --send      # also run the send/reply phase
```

`run.sh` compiles the module and starts the VM with `+P` raised to twice the count (the default process limit is only 262,144).

## erlang_app/ (Erlang): 1000 processes x 1000 messages

Spawns 1000 processes and sends each 1000 messages. Each message is `{Id, N, Last}`; the process calls `work(Id, N)` (`Id * N + 1`), adds the returned value to its running sum, and on the last message sends the sum to the main process. The main process adds the 1000 sums and prints the total and elapsed time.

```sh
./erlang_app/run.sh
```

Expected output: `1000 actors x 1000 messages, total 250501250000`.

## silica_app/ (Silica): 1000 actors x 1000 messages

The same workload as `erlang_app/`, written in Silica: 1000 actors, each cast 1000 messages `(id, n, last)`. The behavior calls `work(id, n)`, accumulates the result in its state, and on the last message casts its sum to a registered `:collector` actor. The collector prints the grand total and ends the program.

```sh
./silica_app/build.sh       # compile and link ./silica_app/actor_msgs
./silica_app/run.sh         # build if needed, run, and time it
```

Requirements: the Silica compiler at `/Volumes/2T/silica/binaries/silica-compiler` (override with `SILICA_COMPILER=/path/to/compiler`), and `clang` on macOS, Apple silicon.

Expected output: `1000 actors x 1000 messages, total 250501250000`.

## claim_free_app/ (Silica, NUCLEO-L476RG): memory claim speed

Claims one block of memory, frees it, and repeats: 10,000 cycles of the same 8 KiB claim, on the ST NUCLEO-L476RG board (emit target `STM32-L476RG_raw`). A claim is `alloc_buf` into a `normal` region; the compiled code zeroes every element of the buffer before the program sees it, and the buffer is freed when the function that claimed it returns. The app has no zeroing loop of its own, so the time it reports is the cost of the claim's zeroing plus the fixed cost of one claim and free. **Not yet compiled or run.**

The claim size is the one constant `claim_bytes()` at the top of `main.silica` (a multiple of 8); `cycle_count()` is the number of timed cycles. 8 KiB fits the chip's 96 KiB + 32 KiB of SRAM with room to spare: the buffer takes one stack chunk of about 9.1 KiB out of the 29,696-byte SRAM2 chunk arena. Sixteen untimed warm-up cycles run first, so the timed cycles do not include the runtime taking that chunk from the heap. Time comes from `monotonic_time()`, which on this board resolves 12.5 ns (SysTick at 80 MHz).

```sh
./claim_free_app/build.sh   # compile and link build/image/claim_free.elf (touches no board)
./claim_free_app/run.sh     # build if needed, load into the board's RAM, run, print the console
```

Requirements: the cross compiler at `/Volumes/2T/silica/binaries/silica-compiler-STM32-L476RG_raw` (override with `SILICA_COMPILER`, keeping that file name), Homebrew's `arm-none-eabi-gcc` and `openocd`, a Python with pyserial (`BOARD_PYTHON`, default the ESP-IDF environment), and the board attached with nothing else using it. The image is loaded into RAM by `board/tools/run_on_board.py`; nothing is written to flash. `BOARD_PORT` chooses the serial port and `BOARD_TIMEOUT` the wait in seconds (default 120).

Expected output shape (the times and speeds are whatever the board measures; the other numbers are fixed):

```
claim size bytes: 8192
cycles: 10000
total bytes: 81920000
total time ns: <elapsed>
time per cycle ns: <elapsed / 10000>
bytes per second: <speed>
KiB per second: <speed / 1024>
MB per second: <speed / 1048576>
checksum: 50005000 expected 50005000
```

`bytes per second` is the benchmark speed: bytes claimed (and so zeroed) per second. Each cycle stores its number in the buffer's first and last element and reads the last element before storing; a claim that was not zeroed would make the checksum larger than expected. Exit status 0 means the checksum matched, 1 that it did not.

## measure.sh: time and RAM

`./measure.sh` runs both 1000 x 1000 apps under `/usr/bin/time -l` and prints wall time, maximum resident set size and peak memory footprint. The Silica app spawns its workers with the `:keep_last_message` stack-release policy (stacks keep what the last message used).

## memory_use_reports/: RAM use of each compiler build

Each compiler build writes a RAM profile (`<UTC>_<compiler>.tsv`) to `memory_use_reports/data/`; `build_display.py` turns them into pages. `SILICA_RAM_PROFILE=0` disables the profile. The build's job count is RAM-aware (`JOBS` defaults to `max(1, min(ncpu, floor(usable_RAM_MB / PER_JOB_MB)))`, `PER_JOB_MB` defaults to 2048 from the newest profile; `make JOBS=N` overrides, `make print-jobs` shows it). Details: [memory_use_reports/README.md](memory_use_reports/README.md) and [../compiler/src/README.md](../compiler/src/README.md).
