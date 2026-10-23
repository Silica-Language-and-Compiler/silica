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

## measure.sh: time and RAM

`./measure.sh` runs both 1000 x 1000 apps under `/usr/bin/time -l` and prints wall time, maximum resident set size and peak memory footprint. The Silica app spawns its workers with the `:keep_last_message` stack-release policy (stacks keep what the last message used).
