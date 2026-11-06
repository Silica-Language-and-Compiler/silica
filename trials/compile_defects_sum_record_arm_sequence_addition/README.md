# compile_defects_sum_record_arm_sequence_addition (INTEGRATE_PENDING)

One valid Silica program whose compiled code faults today; see `../compile_defects_addition/README.md`
for why such a trial gets a directory of its own.

- `sum_record_arm_sequence`: `show/1` matches the record variant of `(:a, int64) | { x: int64, y: string } | :none`
  with the arm `{ x: wx, y: wy } -> { sequence proc[device_io] ... println(wy) ... end }`. The value is
  built by `mk/1` (a record bound into the sum type, returned). Reading `wy` inside the nested sequence
  faults (`[silica] fault ... addr=0x1`); the same arm written as `{ x: wx, y: wy } -> show_xy(wx, wy)`,
  with a helper function holding the sequence, prints `3` and `yy` (`transport_addition/transport_etf_list_sum`).
  Found 2026-11-05 while deriving record variants of a sum for transport.

| today (branch binary-transport-support compiler, Mac, 2026-11-05) | `.scout` (correct behaviour) |
|---|---|
| prints `3`, then faults reading `wy` | `3yy`, `0` |

`INTEGRATE_PENDING` keeps this directory out of tree-wide runs. Run it by hand:

```
make -C compile_defects_sum_record_arm_sequence_addition integrate TRIAL_TARGET=host SILICA_COMPILER=/Users/yenrab/silica/compiler/build/apple_silicon_mac/silica-compiler   # from trials/
```

When the arm prints `yy`, move the trial to `case_addition` with `.ascomp` goldens and delete this directory.
