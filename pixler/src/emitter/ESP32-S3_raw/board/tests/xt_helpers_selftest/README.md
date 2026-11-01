# Xtensa helper self-test

Checks the emitter's instruction helpers — `shared/xt_vr.silica`, `shared/xt_isa.silica`,
`shared/xt_mem.silica` — on the ESP32-S3 itself, before any emitter site depends on them.

`gen_selftest.py` builds a table of cases (operation, virtual registers, input values) and computes
each expected result with exact 64-bit two's-complement arithmetic in Python. It writes a Silica
program whose `main` calls the **real helpers** to emit one Xtensa test function per case, so what is
tested is exactly the code the emitter will produce. The cases cover:

- 64-bit add/sub/mul with carries and borrows across the word boundary; and/or/xor/bic; neg; mvn; mov
- 32-bit (W) forms, including that a W write clears the X register's high word
- shifts by 0, 1, 31, 32, 33, 63 and by register (amount taken modulo 64)
- signed/unsigned divide and remainder through libgcc and `quos`/`quou`/`rems`/`remu`, including zero
  divisors (AArch64 gives 0) and INT64_MIN / -1, and that a libgcc call leaves X0-X2 intact
- all ten compare conditions on values that differ only in the high or only in the low word, select,
  and zero tests (including a value whose low word is 0)
- loads/stores of every width and addressing form the emitter uses: `[Xn, #imm]` in and out of the
  displacement range, `[Xn, Xm]`, post-index, `[X29, #-N]` frame slots, and the auxiliary-stack
  push/pop forms `[SP, #-16]!` / `[SP], #16`
- destinations in registers, frame homes and the global transfer block, aliased with a source

```sh
./run_selftest.sh /tmp/xt_selftest --run
```

Result on the port test unit (2026-09-12): `cases 408 failures 0`.

`qualify.py` adds the `module@` prefix Silica requires on calls into another module; the generated
program is written without it.
