# Open defect: ended (:tcp) carrier memory on a loaded Mac

Recorded 2026-11-20. Status: **open**. The trial that shows it is skipped on the Mac until this is fixed.

## What fails

Trial `trials/transport_addition/app_transport_tcp_close_after_end/dangerous_tcp_carrier_end_memory`
(apple_silicon_mac only). The program runs 60,000 `(:tcp)` carriers whose dial is refused at once; each tells
its owner `(:link_down, :fault)` and ends itself. The harness measures the peak resident set against the
ceiling in `dangerous_tcp_carrier_end_memory.max_rss_mb` (60 MB).

| Run | Peak resident set |
| --- | --- |
| Full parallel trial run on the Mac, 2026-11-19 (run directory `20261119-235543`) | 261.4 MB (fails) |
| Earlier full parallel run the same day, older trial source (`20261119-180851`) | 77.1 MB (fails) |
| The same binary run alone on the Mac, twice | 10.8 MB, 11.0 MB |
| The same binary with 20 CPU-bound processes running (10 cores) | 13.8 MB, 16.4 MB |
| linux_aarch64 and linux_x86_64, full parallel run | under the ceiling (passes) |

The program's output is correct in every run (`60000 carriers ended`, exit code 0). Only the memory ceiling
fails, and only inside a full parallel trial run on the Mac.

## What is known

- The trial source bounds the carriers the program has started and not yet heard from: `main` starts 64, and
  the owner starts one replacement for each `:link_down` it receives. A carrier sends `:link_down` before its
  own thread has finished ending, so the number of threads that still exist can be higher than 64.
- 261 MB is close to 4,096 threads (the hosted thread cap) times a 64 KiB stack (262 MB). This suggests that
  ended carrier threads were not yet released and piled up to the cap. **This is an inference from the number;
  it has not been confirmed by measurement.**
- CPU load alone did not reproduce it. What in a full trial run causes it (memory pressure, many processes
  starting and ending, socket activity from the other tcp trials) is not known.

## What is not known

- Whether the cause is in the Silica runtime's thread exit path on the Mac (for example, an ended actor's
  thread waiting on something before its stack is released) or is the operating system releasing thread
  stacks late under load.
- Why the Linux hosts do not show it.
- Whether a long-running program on a busy Mac can reach the thread cap this way. If it can, the effect is a
  refused `spawn_dangerous`, not only a larger resident set.

## Next steps

1. Reproduce outside the full run: run the binary while the `transport_addition` and `ffi_addition` suites run
   in parallel, and sample the thread count (`ps -M` or `proc_pidinfo`) once a second.
2. If the thread count climbs, find what an ending carrier thread waits on in `actor_thread_main`'s exit path
   (`compiler/src/emitter/apple_silicon_mac/terms/prims/prims_actors_runtime_asm.silica`).
3. If the thread count stays near 64, the memory is held elsewhere; compare `vmmap` summaries of a passing and
   a failing run.
4. When fixed, remove the Mac filter on `APP_EXECUTABLES` in
   `trials/transport_addition/app_transport_tcp_close_after_end/Makefile` and refresh the trial's `.ascomp`.

## Where the skip is

`trials/transport_addition/app_transport_tcp_close_after_end/Makefile`: `APP_EXECUTABLES` leaves
`dangerous_tcp_carrier_end_memory` out when `SILICA_EMIT_TARGET` is `apple_silicon_mac`. The Linux hosts still
run it.
