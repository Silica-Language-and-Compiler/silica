# refusals

Programs the shared compiler accepts and the `STM32-L476RG_raw` emitter refuses (the NUCLEO twins of
`../../device_actor_addition/refusals`). The refusal is an assembler `.error` line in the `.sams`
(device spec §11, per-emitter rows), so it appears when the image is assembled, not in the compiler's
output: a `.golden_fail` cannot capture it, and the board driver would report an image-build failure.
The directory has its own Makefile so both drivers skip it; look at the refusals by hand:

```
make compile SILICA_COMPILER=../../../binaries/silica-compiler-STM32-L476RG_raw
grep '\.error' *.sams
```

| Program | Refusal |
| --- | --- |
| `device_map_outside_window` | `map_device((:test_uart), 0x20000000)`: SRAM1, not a `board_pack.silica` window |
| `device_peek_register64` | `peek(...) impl Register64 {}`: a 64-bit access is not one load on this bus |

A computed base outside the windows is the run-time abort trial `../device_map_computed_outside_window`.
