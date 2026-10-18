# lexer_e0007_three_byte_file_addition

One compile-failure trial: `lexer_e0007_three_byte_file.silica` is exactly the three bytes
`C8 08 94` and must be rejected with E0007 InvalidUtf8 (spec §2.1) at line 1, column 1, offset 0.

This is a hang-class trial. Compilers older than the fixed-point build carrying the 2026-10-16
lexer changes never finish lexing this file, so it lives in its own directory and the Makefile
compiles it under a 120-second alarm instead of the shared 900 seconds. With an older compiler the
trial fails cleanly (exit 142, `.cur_fail differs from .golden_fail`) after two minutes.

The golden is the output of the gen1 compiler of that build (2026-10-16).
