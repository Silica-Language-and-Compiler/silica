# The ESP32-S3 board runtime as a guest of ESP-IDF

A second way to run what the `ESP32-S3_raw` compiler emits. On bare metal (`../runtime`, `../tools`) the Silica
image is the only software on the chip. Here ESP-IDF owns the chip (its bootloader, its start-up, its vector
table, FreeRTOS, its drivers) and the Silica runtime is its guest: each of Silica's two cooperative schedulers runs
in a FreeRTOS task pinned to its core. The emitted code is the same; only the runtime's start-up and fault entry
differ, and a few places in the shared runtime that are marked `SILICA_GUEST`.

It exists for what needs ESP-IDF's closed libraries, first the Bluetooth controller
(`compiler/design_documents/transport_ble_plan.md` §2.1). The application is configured with the controller
and NimBLE, ESP-IDF's Bluetooth host; a program that calls neither links neither. The compiler is not changed and there is one of it:
`binaries/silica-compiler-ESP32-S3_raw`.

## Layout

| Path | What it is |
|---|---|
| `idf_app/` | The ESP-IDF application: `main/main.c` starts the guest; `components/silica_guest/guest.c` holds the two scheduler tasks and the calls the runtime makes into FreeRTOS; `sdkconfig.defaults` is the configuration. |
| `runtime/rt_guest_start.S` | In place of `../runtime/rt_start.S`: each core entered from its task, the per-core register blocks. |
| `runtime/rt_guest_fault.S` | In place of `../runtime/rt_vectors.S`: Silica's fault handling reached from ESP-IDF's exception path. |
| `runtime/rt_guest_mem.S` | In place of the linker script's memory layout: main's stacks and the heap as one block of `.bss`. |
| `tools/build_image.sh` | Builds an image. Same interface as `../tools/build_image.sh`. |
| `tools/run_on_board.py` | Runs an image: `../tools/run_on_board.py` in its flash mode. |

## Use

```sh
# one app from ../apps
../tools/run_app.sh --guest silica_04_print

# the board trials (the ESP32-S3_raw compiler, this runtime)
cd trials && make integrate TRIAL_TARGET=ESP32-S3_idf TRIAL_SUITES=timers_addition
```

Needs what the bare-metal tools need, and ESP-IDF itself at `IDF_PATH` (default `~/esp/esp-idf-v6.2`). The version
is the one the bare-metal scripts name for their toolchain and Python environment: ESP-IDF 6.2 (its development
branch until 6.2 is released; the commit this was built against is recorded in the plan, §7).

The first build takes a few minutes: `build_image.sh` builds the ESP-IDF application once, without a program, into
its cache (`.cache/` here, or the directory given with `-r`). After that an image is the application's own link
command run again with the Silica runtime's and the program's objects added: about a second.

## Stress build

```sh
cd trials && GUEST_STRESS=1 make integrate TRIAL_TARGET=ESP32-S3_idf TRIAL_SUITES=supervisors_addition
```

`GUEST_STRESS=1` builds images in which what is rare in an ordinary run happens all the time, to find faults that
depend on where an interrupt or a task switch lands. A timer with an irregular period of 150 to 660 microseconds
wakes a task above each scheduler, so the schedulers are switched out at points that drift across their code; the
task that holds a busy scheduler back runs every 50 ms instead of every second; and every fault entry calls deep
enough to spill the fault stack's first frame. Programs print what they print in an ordinary build.

## What differs from bare metal

- **Start.** ESP-IDF's bootloader loads the application from flash; `app_main` creates the two scheduler tasks.
  A task makes its core's register block its `THREADPTR` (FreeRTOS keeps `THREADPTR` per task), moves to a Silica
  stack, and enters the runtime where bare metal's reset code would.
- **Code runs from flash.** Emitted code and the runtime are placed where ESP-IDF places any code. The runtime's
  one read of code as data (the marker word before a behaviour, `rt_actors.S`) reads the flash mapping directly.
- **Interrupts are on.** They are ESP-IDF's. An interrupt puts one exception frame on whatever stack is running,
  so every Silica stack keeps that much more above its guard band: `build_image.sh` adds
  `silica_guest_stack_allowance` (from ESP-IDF's frame size, `guest_consts.S`) to the reserve the bare-metal build
  measures. The runtime's own calls into FreeRTOS declare their stack need in `rt_guest_start.S`. Emitted code
  opens a function's frame before it checks the stack limit, so the reserve also covers the largest frame in
  the program: an interrupt between the two still lands above the guard band.
- **Faults.** A CPU exception or a stack-guard hit raised by a Silica scheduler's task ends the actor that was
  running, as on bare metal; outside an actor it is the process's fault report, status 70. A fault in another
  task, in an interrupt handler, or inside one of FreeRTOS's critical sections is ESP-IDF's panic.
- **Idle.** A scheduler with nothing ready blocks until the other core queues work for it or a tick passes (1 ms),
  so the idle tasks run. A scheduler that never goes idle is held back for one tick a second by a small task above
  it, for the same reason: the task watchdog watches the idle tasks and stays on.
- **Locks.** The runtime's spinlocks are taken only by the two scheduler tasks, never by an interrupt handler or
  another task. A scheduler that is paused while it holds one makes the other spin until it runs again; it cannot
  deadlock.
- **Foreign code.** A `.c` wrapper is compiled as ESP-IDF compiles the guest component, so it may call ESP-IDF. It
  runs on the Silica foreign-call stack of the scheduler's task: it may block, and Silica's scheduler on that core
  waits while it does. Code that ESP-IDF calls from its own tasks or interrupt handlers (a callback) must not call
  the Silica runtime: it hands its data to a wrapper call through a FreeRTOS queue.
- **Memory.** Silica's heap is a fixed block (`GUEST_RAM`, shared by the heap and main's two stacks): 240 KB by
  default, 208 KB for a program whose foreign code calls ESP-IDF's Bluetooth or Wi-Fi, which need memory of
  their own (with the controller and NimBLE advertising, ESP-IDF's heap has 43 KB left beside 208 KB). The
  rest of the RAM is ESP-IDF's. Bare metal has about 340 KB. Each of main's stacks is sized from its own bound; one the builder
  cannot bound gets a default (128 KB for the machine stack, 32 KB for the auxiliary stack).
- **The wall clock** is not set by the loader (the image is flashed, not loaded): `current_time` answers
  milliseconds since start.
- **The end.** The exit marker is written as on bare metal; the two scheduler tasks are then suspended and ESP-IDF
  keeps running.
