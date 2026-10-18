---
title: Required software
layout: default
permalink: /required-software/
---

# Required software

Everything that must be installed for the compiler to build and for the trials to run. The
checkout brings the compiler binaries (`binaries/`), the trial tree and the board support files;
the tools below come from outside the repository. Nothing here is a Rust toolchain: Silica's
compiler is written in Silica and builds itself.

Versions are the ones the project is built and tested with (September 2026). Newer versions of the
same tools usually work; older ones are untested.

## At a glance

| Task | Needs |
| ---- | ----- |
| Build the compiler for this machine | Host tools for this machine: [macOS](#host-tools-macos-on-apple-silicon) or [Linux](#host-tools-linux) |
| Run the trials on this machine (`make integrate`) | The same host tools |
| Build or run trials on another machine over ssh | Host tools on both, plus [`rsync` and key-based `ssh`](#building-across-machines) |
| Build the ESP32-S3 cross compiler | Host tools on the machine you build it from |
| Build ESP32-S3 images, run programs or trials on a board | Host tools plus the [ESP32-S3 board tools](#esp32-s3-board-tools) and a [board](#the-board) |

## Host tools (macOS on Apple Silicon)

| Software | Version used | Used for |
| -------- | ------------ | -------- |
| macOS on an arm64 (Apple Silicon) Mac | 26.6 | The emitted programs target macOS 26 (`-mmacosx-version-min=26.0`). |
| Xcode Command Line Tools | Apple clang 21.0 | `clang` assembles every `.sams` file and links (compiler and trial programs); the tools also provide **GNU Make 3.81** (drives every build and the trial tree), **perl 5** (compile timeouts, the trial watchdog, process groups and the board lock in the trial harness), **bash**, and the usual `find`, `awk`, `sed`, `diff`, `xargs`. |
| Homebrew LLVM (optional) | clang 21.1 | When `/opt/homebrew/opt/llvm/bin/clang` exists, the compiler build prefers it for linking. |

Install the command line tools with:

```bash
xcode-select --install
```

Nothing else is needed for the host build or the host trials: `binaries/silica-compiler` is the
newest compiler built for this host, and every build starts from it. If that link is missing or
stale, `bash binaries/update_silica_compiler_link.bash` repairs it.

## Host tools (Linux)

The same three things are needed on a Linux host: **GNU Make**, **clang** (or `cc`) to assemble the
emitted `.sams` and link, and **perl 5** plus the usual `find`, `awk`, `sed`, `diff` and `xargs`
for the trial harness. GNU `as` and `ld` serve where clang's integrated assembler is not used.

| Host | Verified with |
| ---- | ------------- |
| Linux on x86-64 (`linux-x86_64`) | Ubuntu 24.04.3, clang 18.1.3, GNU as/ld 2.42, GNU Make 4.3 ([trials/platform/linux_x86_64.mk](https://github.com/yenrab/silica/blob/main/trials/platform/linux_x86_64.mk)) |
| Linux on AArch64 (`linux-aarch64`) | 64-bit Raspberry Pi OS / Debian-family AArch64; `uname -m` must print `aarch64` ([linux_aarch64_port_checklist.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/ports/linux_aarch64_port_checklist.md)) |

On a Debian-family host:

```bash
sudo apt install build-essential clang
```

## Building across machines

An OS-hosted platform builds its own compiler on its own machine, so
[`programmer_tools/build_all_platforms.sh`](https://github.com/yenrab/silica/blob/main/programmer_tools/build_all_platforms.sh)
and its siblings reach other machines over ssh. That needs **`rsync`** and **public/private key
ssh**: the scripts run `ssh` in batch mode and never type a password.

```bash
ssh-keygen                       # if you have no key yet
ssh-copy-id user@host
ssh -o BatchMode=yes user@host true
```

A compiler build needs 6–8 GB of RAM for its heaviest unit, on every machine that runs one.

## ESP32-S3 board tools

Needed to turn the ESP32-S3 compiler's output into board images, and to load and run them. No
ESP-IDF component, header or library is linked into a Silica program; only the toolchain and the
flashing tool are used.

| Software | Version used | Used for |
| -------- | ------------ | -------- |
| Espressif Xtensa toolchain `xtensa-esp-elf` (`xtensa-esp32s3-elf-gcc`) | esp-16.1.0_20260609 (GCC 16.1) | Assembles the emitted Xtensa `.sams` and the board runtime, links with its `libgcc` (64-bit division, float64). |
| ESP-IDF Python environment with **esptool** and **pyserial** | Python 3.14, esptool 5.4.0, pyserial 3.5 | Builds the image (`esptool elf2image`), loads it into the board's RAM (or flashes it), and reads the console. |

Both come from the ESP-IDF 6.2 installer, which puts them under `~/.espressif`:

```bash
git clone -b v6.2 --recursive https://github.com/espressif/esp-idf.git
cd esp-idf
./install.sh esp32s3
```

The board tools look for them in those default places; if yours are elsewhere, point the tools at
them:

| Variable | Default | Read by |
| -------- | ------- | ------- |
| `XTENSA_BIN` | `~/.espressif/tools/xtensa-esp-elf/esp-16.1.0_20260609/xtensa-esp-elf/bin` | `board/tools/build_image.sh` |
| `ESPTOOL` | `~/.espressif/python_env/idf6.2_py3.14_env/bin/esptool` | `board/tools/build_image.sh` |
| `BOARD_PYTHON` | `~/.espressif/python_env/idf6.2_py3.14_env/bin/python` | `board/tools/run_app.sh` (and through it `run_on_board.py` and `main_stack_bound.py`) and the board trial target (`trials/targets/`) |

(`board/` is `compiler/src/emitter/ESP32-S3_raw/board/`.)

### The ESP32-S3 compiler

Board programs and board trials are compiled by `binaries/silica-compiler-ESP32-S3_raw`: a compiler
that runs on a hosted machine and emits ESP32-S3 (Xtensa) assembly. The ESP32-S3 has no OS and
cannot host a compiler, so this cross compiler is built on whichever machine you start from:

```bash
bash programmer_tools/build_all_platforms.sh --targets ESP32-S3_raw
```

It is installed as `binaries/silica-NNNNNN-ESP32_S3_raw-<platform>`, with its own numbering, and
`binaries/silica-compiler-ESP32-S3_raw` points at the newest one. It never replaces
`binaries/silica-compiler`. (`make TARGET=ESP32-S3_raw` in `compiler/src/` is what the script runs.)

### The board

- An ESP32-S3 board whose UART0 (GPIO43/44) is wired to a USB serial bridge. The port was brought
  up and is tested on the board described in
  [PORT_TEST_BOARD_byu_idaho_v4.0_feb26.md](https://github.com/yenrab/silica/blob/main/compiler/src/emitter/ESP32-S3_raw/board/PORT_TEST_BOARD_byu_idaho_v4.0_feb26.md)
  (BYU-I eBadge v4.0, ESP32-S3-MINI-1-N4R2, CP2102N bridge).
- A USB **data** cable (charge-only cables enumerate nothing). macOS's built-in driver serves the
  CP2102N; the board appears as `/dev/cu.usbserial-*`. If the board has a power switch, it must be on.
- The trial runner and `board/tools/run_app.sh` use the one USB serial port they find. With several, set `BOARD_PORT=/dev/cu....`
  (an interactive trial run asks). `BOARD_MAC=<mac>` makes a run refuse any board but that one.

## Checking an installation

```bash
make --version | head -1          # GNU Make (3.81 on macOS, 4.x on Linux)
clang --version | head -1         # Apple clang 21 (or newer) on macOS; clang 18 or newer on Linux
perl -v | sed -n 2p               # perl 5

# ESP32-S3 board tools
~/.espressif/tools/xtensa-esp-elf/esp-16.1.0_20260609/xtensa-esp-elf/bin/xtensa-esp32s3-elf-gcc --version | head -1
~/.espressif/python_env/idf6.2_py3.14_env/bin/python -c "import esptool, serial; print(esptool.__version__, serial.VERSION)"
~/.espressif/python_env/idf6.2_py3.14_env/bin/python \
    compiler/src/emitter/ESP32-S3_raw/board/tools/run_on_board.py --probe
```

The last command connects to the board and prints its port, chip and MAC address; it fails with a
plain message when no board is connected.

## See also

- [Build and test the compiler]({{ '/build-and-test/' | relative_url }}): building the compiler and running the trials.
- [trials/README.md](https://github.com/yenrab/silica/blob/main/trials/README.md) and [trials/targets/README.md](https://github.com/yenrab/silica/blob/main/trials/targets/README.md): the trial tree, and running it on a board.
- [board/README.md](https://github.com/yenrab/silica/blob/main/compiler/src/emitter/ESP32-S3_raw/board/README.md): the ESP32-S3 board support files, and how to run the Silica sample apps on the board with `tools/run_app.sh`.
