# memory_space_esp32s3_addition

Board-only trials of the memory spaces the ESP32-S3 board (`ESP32-S3_raw`) provides and refuses
(plan: `~/.claude/plans/distributed-seeking-fairy.md`; board README "Memory spaces").
Provided: `normal`, `normal_writeback`, `normal_noncacheable`, `atomic`. Refused: `normal_writethrough`, `device`.

| Trial | Shows |
| --- | --- |
| `mem_space_normal` | `alloc_region(normal)`, a ref cell: store 177 over 20, load it back; prints 177 |
| `mem_space_normal_writeback` | the same in `normal_writeback`; prints 177 |
| `mem_space_normal_noncacheable` | the same in `normal_noncacheable` (internal SRAM is uncached: exact); prints 177 |
| `mem_space_atomic_load_store` | an `atomic` ref (`sequence proc[mem(atomic), atomic]`): store 177, load it; every `read_ref`/`write_ref` is bracketed by `memw`; prints 177 |
| `mem_space_union_not_refused` | control: a parameter typed `List[int64, mem(normal) | mem(normal_writethrough) | mem(device)]` (a union of several `mem(...)` alternatives that includes refused spaces) still compiles, assembles and runs; only a single explicit space is refused. This protects `compiler/stdlib/Supervisor.silica` (lines 30-60: the spawn-spec `List[{...}, mem(normal) | ... | mem(device)]` return type), which every trial compiles. The union is expressible in a user program with the same `mem(a) | mem(b)` syntax as in that file. If the type checker rejects passing a `List[int64, mem(normal)]` to the union parameter (untested here), drop the call and keep the function |

## Refusals

`refusals/` has the programs this board refuses (one per refused space, plus one with the space only in a function
parameter type). The shared compiler accepts them (compile exits 0, "Compilation complete."), and the refusal is an
assembler `.error` line in the `.sams`, so it appears at assembly, not in the compiler output: a `.golden_fail`
cannot capture it. As with `../device_actor_stm32_addition/refusals`, the directory has its own Makefile, so the board
driver and the host driver skip it, and the check is run by hand:

```
make -C refusals check SILICA_COMPILER=../../../binaries/silica-compiler-ESP32-S3_raw
```

`check` compiles the programs, and requires each `refuse_*.sams` to contain a line matching
`.error "memory space '<space>' is not available on ESP32-S3; this board provides: <list>"`, printed for the eye
(`grep '\.error' refuse_*.sams`); a program without the line is reported `NOT refused` and `check` fails. The
expected text for each program:

| Program | Space refused | Expected `.error` line |
| --- | --- | --- |
| `refuse_normal_writethrough` | `alloc_region(normal_writethrough)`, `region`/`ref` types | `memory space 'normal_writethrough' is not available on ESP32-S3; this board provides: <list>` |
| `refuse_device` | `alloc_region(device)`, `region`/`ref` types | `memory space 'device' is not available on ESP32-S3; this board provides: <list>` |
| `refuse_param_normal_writethrough` | only in the parameter type `ref(R, normal_writethrough, int64)` | `memory space 'normal_writethrough' is not available on ESP32-S3; this board provides: <list>` |

`<list>` is whatever the board's `provided_spaces()` returns (taken from the real output when the goldens are checked).

## Goldens and targets

- The run trials carry `<stem>.ESP32-S3_raw.scout` only, **hand-derived and verified only after a board run**: each
  program stores 177 over 20 in a cell (or returns 7 for the union control) and the trial-support header's `wait_for_exit`
  status line prints it, as the `alloc_region_*` trials print `0`. If the run prints anything else, the golden is wrong, not the board.
- `<stem>.esp32_s3.ascomp` goldens are generated afterwards by `trials/targets/gen_board_ascomp.sh` from the board compiler's
  real output once the run matched; for `mem_space_atomic_load_store` they show `memw` before and after the load and the store.
- Directory is `INTEGRATE_PENDING`: the host run skips it. The Nucleo run skips it.
- Board run: `make integrate TRIAL_TARGET=ESP32-S3_raw TRIAL_SUITES=memory_space_esp32s3_addition` from `trials/` (announce the run; one board at a time).
