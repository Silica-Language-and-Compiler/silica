# compile_defects_fn_atom_param_in_aggregate_addition

Valid programs the compiler rejected with E2003 because `strip_named_params_work` (type_interner_surface_text.silica)
cut a fn type at its first top-level `:` without checking that a name precedes it, corrupting an atom-led
parameter type (`msg: :close | :poll`) on repeated passes. One directory: the fix covers every shape, and a rejected
unit fails the whole directory's compile step. Each program stores the function in an aggregate, reads it back and
calls it, then prints "done" (`.wait_for_exit`). No `.ascomp` goldens yet: create them after a run where `.sout` equals `.scout`.

- `fn_atom_param_in_record_list`, `fn_atom_param_in_tuple_list`, `fn_atom_param_in_wrapped_record_list` (`[r]`),
  `fn_atom_param_in_nested_record`, `fn_carrier_message_param_in_record_list`, `fn_atom_param_in_supervisor_row`: E2003 today.
- `fn_single_atom_param_in_record`, `fn_tuple_led_param_in_record`: controls that compile today and must keep compiling.
