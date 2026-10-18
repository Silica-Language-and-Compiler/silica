# refusals

Programs the shared compiler accepts and the `ESP32-S3_raw` emitter refuses. The refusal is an
assembler `.error` line in the `.sams` (device spec §11, per-emitter rows; plan work items 15-16),
so it appears when the image is assembled, not in the compiler's output: a `.golden_fail` cannot
capture it, and the board driver would report an image-build failure. The directory has its own
Makefile so both drivers skip it; look at the refusals by hand:

```
make compile SILICA_COMPILER=../../../binaries/silica-compiler-ESP32-S3_raw
grep '\.error' *.sams
```

| Program | Refusal |
| --- | --- |
| `device_map_outside_window` | `map_device((:test_uart), 0x3FC88000)` — SRAM, not a `board_pack.silica` window |
| `device_peek_register64` | `peek(...) impl Register64 {}` — a 64-bit access is not one load on this bus |

When the emitter's refusals move onto the pre-emit diagnostic channel (plan "Still to decide"),
these become ordinary `.ESP32-S3_raw.golden_fail` trials in the suite above.
