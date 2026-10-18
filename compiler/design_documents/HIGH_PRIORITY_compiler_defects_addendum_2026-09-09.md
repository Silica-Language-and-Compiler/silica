# HIGH PRIORITY — addendum (2026-09-09): two more silent miscompilations

**Implementation status (2026-10-16):** both A7 and A8 are fixed. They are pinned by the installed trials `train_defect_a7_*` (one per integer width, in `int8_addition` ... `uint64_addition`) and `train_defect_a8_compound_compare_float32_0001` / `_float64_0001` (`float32_addition`, `float64_addition`); the `.sout` of each equals its hand-derived `.scout`. The fixes (operand staging in `left_reg`, quotient scratch X16, right-first with spill for a float prim on the left) landed in `emitter/*/terms/` and are described in [compiler_defects_execution_status_2026-09-10.md](./compiler_defects_execution_status_2026-09-10.md). The text below is the original report.

Companion to [HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md](./HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md).
Kept as a separate file because the main document was open in an editor when these were
found; fold A7 and A8 into Part A of the main document when convenient. Both were found by
the second batch of `train_*` trial generation (25 of 5,250 candidates were rejected because
their output was wrong; every rejected program is one of these two shapes). Same seed
compiler as before, `binaries/silica-compiler` → `silica-999994-macos-applesilicon`.
Neither was pinned by an installed trial at the time (both are now).

## A7. A parenthesised right operand that reads a parameter sees the left operand's value instead

```silica
fn k3(x: int64) -> int64 {
    20 + (x + 1)
}

fn main() -> int64 { k3(5) }
```

Exit status 41; expected 26. `x` is read as 20 — the literal that was just materialised
into the parameter's register. Probe table (all single-file, milliseconds):

| Function body | Call | Got | Expected | Verdict |
| --- | --- | --- | --- | --- |
| `43 - (x + x)` (`int8`) | `f(19)` | 213 (= −43) | 5 | wrong: `x` read as 43 |
| `20 + (x + 1)` (`int64`) | `k3(5)` | 41 | 26 | wrong: `x` read as 20 |
| `y % 27 + (z + x)` (`int32`, 3 params) | `g(10, 16, 16)` | 32 | 42 | wrong: `x` read as 0 |
| `(6 % 55) - (x + x)` (`uint16`) | `combine(1)` | 6 | 4 | wrong: `x` read as 0 |
| `y % x * (z % x)` (`int16`) | `combine(5, 17, 3)` | 0 | 6 | wrong |
| `(z % 11 % (x % y))` (`int32`) | `mix(5, 3, 3)` | `badarith`, exit 1 | 1 | wrong: a clobbered operand became a zero divisor |
| `20 + x` (`int64`) | `k2(5)` | 25 | 25 | ok |
| `10 * 2 + (x + x)` (`int64`) | `k(5)` | 30 | 30 | ok |
| `y + (x + 1)` (`int64`, 2 params) | `k4(5, 20)` | 26 | 26 | ok |
| `100 - (x + y)` (`int64`, 2 params) | `h(3, 4)` | 93 | 93 | ok |

Shape: the left operand of a binary expression is evaluated into the register that still
holds the first parameter (W0/X0), and the parenthesised right operand then reads the
parameter from that register. When the left operand is itself a parameter or a product
the value happens to survive; when it is a literal or a `%` result it does not. This is the
same family as A4 in the main document (tuple parameter staged through X0) and is the most
common shape in real code (`limit - (count + 1)`), so it should be first in line.
**Avoided by:** the generator only verified; every affected program was dropped.

## A8. Float comparison with compound operands on both sides compares the wrong values

```silica
fn main() -> atom {
    sequence proc[device_io]
        _: atom <- print_bool(3.0 + 4.0 > 1.0 + 1.0);
        println("");
        _: atom <- print_bool((5.5 + 29.0) > (9.375 + 18.0));
        println("");
        _: atom <- print_bool(3.0 * 4.0 > 1.0 * 1.0);
        println("");
        _: atom <- print_bool((25.0 + 0.125) >= 7.125);
        println("");
        a: float64 <- 3.0 + 4.0;
        b: float64 <- 1.0 + 1.0;
        done: atom <- print_bool(a > b)
    produces pure done end
}
```

Prints `false false false true true`; the first three should be `true`. Untyped float
literals in a `print_bool` argument default to `float32`, so this is the S-register path.
Emitted sequence for `(5.5 + 29.0) > (9.375 + 18.0)`:

```
FADD S1, S1, S2      ; left result left in S1
...                  ; right operands are loaded into S1 and S2 again
FADD S2, S1, S2      ; right result in S2 — S1 now holds 9.375, the left result is gone
FCMP S1, S2
CSET W0, GT
```

The left result is never spilled or moved out of S1 before the right operand reuses S1.
When only one side is compound the compare is correct, and when both sides are bound
variables the `float64` path saves them in D8/D9 first and is correct.
**Avoided by:** dropped by verification; installed comparison trials therefore have at most
one compound side. (The generator's `float64_addition` comparison programs also run in
`float32` for the same literal-typing reason; their goldens are still exact because every
value is dyadic.)

## Note on the diagnostics side

The second batch tried 5,250 more single-edit mistakes; the ones the compiler failed to
report are the same Part B items as before (extra call argument, integer literal to a
string parameter, wrong effect inside a `case` arm, duplicate `sequence` keyword in some
positions, empty `proc[]` on some pure blocks). No new diagnostic gap appeared.
