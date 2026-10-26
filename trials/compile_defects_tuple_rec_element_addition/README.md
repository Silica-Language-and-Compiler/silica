# compile_defects_tuple_rec_element_addition

An ill-typed program that the compiler ACCEPTED until chunk 15 phase 1 (2026-10-25): its trial is the
expected compile error, compiled alone and compared with `.golden_fail` (the single-file rule of
`../error_enforcement_addition/Makefile`, copied here without multi-file trials).

- `tuple_literal_rec_element`: a function declared to return `(region(L, normal), ref?(L, normal, rec))`
  (the `rec` is the pair, Q19) produced `(r, c)` with `c` a ref to an `(int64, ref?(L, normal, rec))` node.
  Root cause: the tuple-literal check (`type_checker_expressions_tuples@check_tuple_literal_inline_plain`)
  cut the expected tuple's text into element texts, which left the element's `rec` unanchored, and an
  unanchored `rec` matches any recursive tuple. Fix: `type_checker_recursive_tuples@unfold_outer_rec`
  replaces such a `rec` in the cut element by the whole tuple. Found in the phase-0 gate follow-up
  (scratch repro `retpair_a`, controls `retpair_b` rejected and `retpair_c` accepted).

The `.golden_fail` is the fixed compiler's real output. Run:

```
make -C compile_defects_tuple_rec_element_addition integrate SILICA_COMPILER=<compiler>   # from trials/
```

Topic suite: `error_enforcement_addition` (the trial can move there once a published compiler carries the fix).
