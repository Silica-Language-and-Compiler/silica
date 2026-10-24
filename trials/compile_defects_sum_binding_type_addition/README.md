# compile_defects_sum_binding_type_addition

One valid Silica program that today's compiler rejects (see `defect_sum_binding_type.silica` and the
`compile_defects_addition` README for why a compile-time defect gets a directory of its own).

- `defect_sum_binding_type`: a sequence binding whose declared type is an inline sum with a tuple
  variant, `kept: :none | (:some, int64) <- v;`. The grammar allows it: `statement ::= pattern "<-"
  expression ";"` (spec §3.3.4), `identifier_pattern ::= identifier ":" type` (§3.5), and a type is
  any inline type expression (§3.4.2), the one that already parses as a parameter type and as a
  record field type. The parser rejects the line with E1000 (the binding-type scanner in
  `parser/constraint_extract_*` does not take a sum with a tuple variant). Found 2026-10-23 while
  writing `supervisor_exit_reports_addition`.

Move the trial to `case_addition/sum_binding_type` once the parser accepts it and its behaviour matches
the golden, then delete this directory.
