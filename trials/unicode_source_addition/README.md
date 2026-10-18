# unicode_source_addition

Positive trials for UTF-8 source text (spec §2.1), added with the 2026-10-16 lexer changes
(E0001-E0007). The suite has its own directory because the Unicode atoms add entries to the atom
table, and atoms are numbered per application (one suite is one application): in a shared suite
they would shift every later atom.

- `unicode_leading_byte_order_mark`: the file begins with a byte order mark (EF BB BF), which the
  lexer skips.
- `unicode_comments_and_strings`: Unicode in line and block comments, string literals and a
  character literal compiles, and the strings print their exact bytes.
- `unicode_atom_names`: atoms with two-, three- and four-byte characters print their names.
  Open emitter defect when written: the atom name table writes '?' for each non-ASCII character
  (and NUL padding), so this trial fails until that is fixed.

The lexer's rejections of invalid UTF-8 and other lexical errors are compile-failure trials in
`error_enforcement_addition/lexer_e000*` and `lexer_e0007_three_byte_file_addition`.
