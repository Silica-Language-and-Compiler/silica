# compile_defects_nested_print_in_call_arg_addition

One program that compiled but did not assemble before 2026-10-09 (see
`nested_print_in_call_arg.silica` and the `compile_defects_addition` README for why a compile-time
defect gets a directory of its own).

- `nested_print_in_call_arg`: a print built-in nested in a call argument, `show(print_int8(1))`,
  inside a sequence that declares `device_io`. The emitters' rodata and helper walkers stopped at a
  user call instead of searching its arguments, so the assembly referenced labels (`L_pi8_0`,
  `L_pf64_helper`, `L_pb_helper`, ...) that were never emitted. Fixed in every emitter's
  `atoms/int_rodata`, `float*_rodata`, `string_rodata` and `atom_table` walkers. Expected: each
  printed value then `:ok`, exit 2.

Topic suite: `atoms_addition` (sibling of `print_builtins_return_ok`). Move it there once the
goldens of every host and the board agree.
