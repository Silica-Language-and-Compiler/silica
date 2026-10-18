# Writing FFI Wrappers and Makefiles

This tutorial shows the current Silica shape for outbound FFI: a small C-compatible wrapper library, sidecar metadata under `dangerous_exposure_source/`, a `dangerous_*` Silica module that declares raw `foreign c_wrapper` bindings, and an app that reaches the foreign call only through an FFI worker actor.

The normative rules live in [silica_ffi_wrapper_specification.md](../design_documents/silica_ffi_wrapper_specification.md). This file is a practical build recipe.

---

## What FFI Changes

Using FFI is intentionally loud in Silica:

- Every module that declares a raw foreign binding must be named `dangerous_*`.
- Every module that imports a `dangerous_*` module must also be named `dangerous_*`.
- Application actors do not call dangerous modules directly.
- Foreign work goes through a cast-only FFI worker actor.
- The actual call happens inside `sequence proc[external_danger] ... produces pure ... end`.
- The compiler emits `W4001` once for each accepted `foreign c_wrapper` binding.

`W4001` is only a warning. It does not fail compilation. Its job is to make the security boundary visible:

```text
FFI_Warning at
W4001

DANGER DANGER DANGER: this module uses FFI wrapper '<local_name>' for foreign symbol '<symbol_name>'. FFI breaks the Silica security model for this app and exposes the entire application to memory insecurity, ABI unsafety, undefined behavior, privilege-boundary collapse, and other security issues from the foreign code and wrapper boundary.
```

---

## Project Layout

A minimal FFI project looks like this:

```text
my_ffi_app/
  Makefile
  silica.config
  dangerous_legacy_math.silica
  dangerous_math_app.silica
  dangerous_exposure_source/
    legacy/
      silica_legacy_math_wrapper.h
      silica_legacy_math_wrapper.meta
    lib/
      libsilica_legacy_math.a
    src/
      silica_legacy_math.c
```

The important convention is `dangerous_exposure_source/`. `wrapper_meta` and per-binding `meta` paths must be rooted there. The compiler does not discover sidecars by walking directories or guessing from header names.

---

## Step 1: Write a C Wrapper

Wrap the external library behind a stable C ABI. Keep the Silica-facing signature explicit and boring: fixed-width integers, pointer-plus-length strings, and result records for errors.

```c
/* dangerous_exposure_source/legacy/silica_legacy_math_wrapper.h */
#include <stdint.h>

int64_t silica_legacy_math_add_int64(int64_t left, int64_t right);
```

```c
/* dangerous_exposure_source/src/silica_legacy_math.c */
#include "silica_legacy_math_wrapper.h"

int64_t silica_legacy_math_add_int64(int64_t left, int64_t right) {
    return left + right;
}
```

Avoid exposing raw pointers, `void *`, recursive C structs, `size_t`, `long`, or platform-dependent C types to Silica. Translate those inside the wrapper into Silica-compatible scalars, records, buffers, strings, or explicit error results.

---

## Step 2: Add Sidecar Metadata

The sidecar tells the compiler which library to link and which wrapper symbols are expected.

```text
# dangerous_exposure_source/legacy/silica_legacy_math_wrapper.meta
link_library: "silica_legacy_math"

wrapper silica_legacy_math_add_int64 {
    symbol: "silica_legacy_math_add_int64"
    result: "scalar"
    error_domain: "dangerous_legacy_math"
}
```

Each `foreign c_wrapper "symbol"` declaration must have exactly one matching `wrapper symbol { ... }` entry in a referenced sidecar.

---

## Step 3: Declare a Dangerous Silica Wrapper Module

Raw foreign bindings have no Silica body. Export a normal Silica adapter function instead.

```silica
module dangerous_legacy_math;

export add/2;

wrapper_meta "dangerous_exposure_source/legacy/silica_legacy_math_wrapper.meta";

foreign c_wrapper "silica_legacy_math_add_int64"
fn add_raw(left: int64, right: int64) -> int64;

fn add(left: int64, right: int64) -> int64 {
    add_raw(left, right)
}
```

Do not export `add_raw/2`. Raw `foreign c_wrapper` declarations are never application-facing API. The exported adapter has a body and gives the rest of the program a Silica-level function name.

When this module compiles successfully, the compiler emits `W4001` for `add_raw`.

---

## Step 4: Call It Through an FFI Worker Actor

Any module that imports `dangerous_legacy_math` must also be `dangerous_*`.

The worker executes the dangerous call inside `external_danger`. A client actor sends requests by `cast`, and the worker returns results by `cast`.

```silica
module dangerous_math_app;

use dangerous_legacy_math;

fn ffi_worker_behavior(msg: int64, reply_to: actor_ref) -> (:no_reply, actor_ref) {
    sequence proc[external_danger, concurrency]
        sum: int64 <- dangerous_legacy_math@add(msg, 40);
        cast(reply_to, sum);
    produces
        pure (:no_reply, reply_to)
    end
}
```

The exact actor message shape depends on the app. The important pieces are:

- The worker behavior is the function passed directly to `spawn`.
- The dangerous module call is in the sequence portion of `sequence proc[external_danger]`.
- External-danger-touched data does not leave through `produces pure`.
- Any result cast carrying FFI data is sent from inside the `external_danger` sequence.

---

## Step 5: List Silica Sources

The compiler reads `silica.config` from the build directory. Put one `.silica` file per line:

```text
dangerous_legacy_math.silica
dangerous_math_app.silica
```

For trials, the Makefiles usually generate this file from the app directory:

```make
find "$(APP_TRIAL_DIR)" -maxdepth 1 -name '*.silica' \
  | sed "s|^$(APP_TRIAL_DIR)/||" \
  | sort > silica.config
```

---

## Step 6: Build the Wrapper Archive

Here is the fixture-building part of a Makefile:

```make
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

FIXTURES_DIR := $(THIS_DIR)dangerous_exposure_source
SRC_DIR := $(FIXTURES_DIR)/src
LIB_DIR := $(FIXTURES_DIR)/lib
BUILD_DIR := $(FIXTURES_DIR)/build

CC := clang
ARCH := arm64
CFLAGS := -std=c11 -Wall -Wextra -O2 -arch $(ARCH) -mmacosx-version-min=26.0 \
	-I$(FIXTURES_DIR)/legacy

LEGACY_OBJ := $(BUILD_DIR)/silica_legacy_math.o
LEGACY_ARCHIVE := $(LIB_DIR)/libsilica_legacy_math.a

.PHONY: fixtures clean-fixtures

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(LIB_DIR):
	@mkdir -p $(LIB_DIR)

$(LEGACY_OBJ): $(SRC_DIR)/silica_legacy_math.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(LEGACY_ARCHIVE): $(LEGACY_OBJ) | $(LIB_DIR)
	ar rcs $@ $^

fixtures: $(LEGACY_ARCHIVE)

clean-fixtures:
	@rm -rf "$(BUILD_DIR)"
	@rm -f "$(LEGACY_ARCHIVE)"
```

The archive name must match the sidecar `link_library` value. `link_library: "silica_legacy_math"` maps to `libsilica_legacy_math.a`.

---

## Step 7: Compile Silica, Assemble, Link, and Run

The repository FFI app trials use [common_app.mk](../../trials/ffi_addition/common_app.mk), which does this work:

1. Build the wrapper fixture archives (`integrate: fixtures` compiles C sources via [fixtures.mk](../../trials/ffi_addition/fixtures.mk)).
2. Symlink `dangerous_exposure_source/` into the app trial.
3. Generate `silica.config`.
4. Run `src/silica-compiler`.
5. Assemble each emitted `.sams` file with `clang`.
6. Read `silica.link` through [silica_link.sh](../../trials/silica_link.sh).
7. Link the app object, runtime object, and wrapper archives.
8. Run executables and compare `.sout` to `.scout` goldens.

A small app Makefile can reuse that shared trial harness:

```make
THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
APP_TRIAL_DIR := $(abspath $(THIS_DIR))
APP_LABEL := app_my_ffi_demo
APP_EXECUTABLES := dangerous_math_app

include $(abspath $(THIS_DIR)/../common_app.mk)

.PHONY: all integrate clean fixtures

all: integrate

integrate: fixtures
integrate:
	$(APP_INTEGRATE_BODY)

clean:
	@cd "$(THIS_DIR)" && rm -f *.sams *.o $(APP_EXECUTABLES) silica.config silica.link .integrate_counts *.sout dangerous_exposure_source
```

For a standalone project outside the trial tree, copy the same sequence rather than depending on relative trial paths. The key link inputs are:

- the app object, for example `dangerous_math_app.o`;
- `__silica_runtime.o` if emitted;
- every object for local imported Silica modules;
- archives named by `silica.link` / sidecar `link_library`;
- linker entrypoint `main`.

---

## Full Trial References

Useful working examples live under [trials/ffi_addition](../../trials/ffi_addition/):

- `fixtures.mk` / `fixtures/` build wrapper archives from C sources under `fixtures/src/`.
- `app_sidecar_legacy_math_add/` shows sidecar metadata and a legacy math wrapper.
- `app_cast_worker_legacy_add/` shows the cast-only client and FFI worker model.
- `app_ffi_result_cast_add/` shows result delivery by cast.
- `app_foreign_abi_valid/` shows accepted Silica-side ABI declarations.
- `app_e2e_scalar_string_echo/` shows scalar and string FFI calls end to end.

Warning goldens for `W4001` live under [trials/warning_enforcement_addition](../../trials/warning_enforcement_addition/).

---

## Checklist

Before expecting an FFI build to work, check:

- The Silica module declaring `foreign c_wrapper` is named `dangerous_*`.
- Importing modules are also named `dangerous_*`.
- Every raw binding has a module `wrapper_meta` or per-binding `meta`.
- Sidecar paths begin with `dangerous_exposure_source/`.
- Sidecar `wrapper <symbol>` matches the `foreign c_wrapper "<symbol>"`.
- `link_library` maps to an archive under `dangerous_exposure_source/lib/`.
- Raw bindings are not exported.
- Exported dangerous functions are Silica adapter functions with bodies.
- Dangerous calls happen only inside an FFI worker `external_danger` sequence.
- The app treats `W4001` as a warning, not as a compile failure.
