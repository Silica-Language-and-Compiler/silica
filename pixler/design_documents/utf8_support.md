# UTF-8 Support for Char Literals in substring_until_char

## Implementation status (2026-10-16)

Implemented as designed, in every phase named below:

- Lexer: `advance_utf8_char` and `utf8_lead_byte_length` were removed. The lexer now checks UTF-8 validity itself (comments, strings, characters, atoms), and invalid bytes are error E0007 InvalidUtf8 (lone continuation bytes, C0/C1/F5-FF, truncated, overlong, surrogates, above U+10FFFF); a leading byte order mark is skipped. The text below describing those two helpers is the original design.
- Substring helper: its backward walk restarts from byte 0 on invalid input.
- SIR generator: `byte_to_int64` (256-case table), `char_lexeme_to_utf8_encoded` and the char-literal branch of `expr_to_sir_with_type` in `src/sir_generator/terms/literals.silica`; a char literal is the int64 `(len << 56) | packed`.
- Emitters: `L_substring_until_char_helper` with full code-point matching in `string_substring_mmap_nomte.silica` for all four backends (`apple_silicon_mac`, `linux_aarch64`, `linux_x86_64`, `ESP32-S3_raw`); the substring helper also has an ASCII fast path and a UTF-8 slow path with a cursor cache.
- Trials: `substring_utf8_cursor` and the `string_test_substring_until_char_*` set.

The "no calls out to Rust runtime functions" constraint is moot: the compiler is Rust-free. File paths below are given relative to `compiler/src/`; the emitter path is per target (`emitter/<target>/terms/`).

---

## Problem

The `char_lexeme_to_int64_string` function in `sir_generator/terms/literals.silica` converts char literal lexemes (e.g. `"' '"`, `"','"`) to decimal strings for the `substring_until_char` helper. Currently it uses a hardcoded lookup table covering only a few ASCII characters (` `, `,`, `x`, `z`, `\n`, `\t`). Unlisted characters fall through to `"0"`, producing incorrect behavior. Multi-byte UTF-8 characters (e.g. `'é'`) are not handled correctly.

## Constraint

**No calls out to Rust runtime functions.** All logic must be implemented in pure Silica that the bootstrap compiler can compile. We cannot add new built-ins like `byte_at` or `ord` that invoke the Rust runtime.

## Solution by Compiler Phase

### Lexer

**File:** `src/lexer/lexer_string_literals.silica`

**Change:** Add UTF-8-aware advance in `read_char_literal` for normal (non-escape) characters.

The lexer's `advance` advances by one byte (`position + 1`). For multi-byte UTF-8 characters (e.g. `'é'`), the lexer would treat the second byte as the closing quote and fail.

Add `advance_utf8_char(lexer)` or equivalent logic that advances by the full UTF-8 character length based on the first byte of `peek_char`:

- 1-byte: `0x00–0x7F` → advance 1
- 2-byte: `0xC2–0xDF` → advance 2
- 3-byte: `0xE0–0xEF` → advance 3
- 4-byte: `0xF0–0xF7` → advance 4

Use this in the normal-character branch (around line 166) instead of a single `advance`.

**Effect:** Lexemes like `'é'` span the full UTF-8 sequence instead of a single byte.

---

### Parser

**No changes.** Char literals are already parsed; the parser consumes the token produced by the lexer.

---

### Type Checker

**No changes.** `substring_until_char(s: string, start: int64, char: char)` already type-checks the third argument as `char`.

---

### SIR Generator

**File:** `src/sir_generator/terms/literals.silica`

**Changes:**

1. **Add `byte_to_int64(byte_str: string) -> int64`** — 256-case lookup mapping each single-byte string to 0–255. Uses `case substring(byte_str, 0, 1) of { "\x00" -> 0; "\x01" -> 1; ... "\xFF" -> 255 }`.

2. **Add `char_lexeme_to_utf8_encoded(lexeme: string) -> int64`** — Produces full UTF-8 encoding for the helper:
   - `inner = substring(lexeme, 1, length_chars(lexeme) - 1)`
   - `len = length_bytes(inner)` (1–4)
   - `packed = Σᵢ byte_to_int64(substring(inner, i, i+1)) × 256^i`
   - `return (len << 56) | packed`

3. **Update `expr_to_sir_with_type` for `type_name == "char"`** — Replace `char_lexeme_to_int64_string` with `char_lexeme_to_utf8_encoded`; convert result to decimal string (e.g. via `int64_to_decimal_string` from a shared module); produce `SIRTerm { kind: 0, type_name: "int64", value: decimal_string, ... }`.

**Effect:** Char literals are represented as `(len << 56) | packed` in the SIR, enabling full code-point matching in the assembly helper.

---

### Emitter

**File:** `src/emitter/terms/string_substring_mmap_nomte.silica`

**Change:** Rewrite `emit_string_substring_until_char_helper` to perform full UTF-8 code-point matching.

**Interface (unchanged):** X0 = string ptr, X1 = start byte offset, X2 = encoded char `(len << 56) | packed`.

**Helper logic:**

1. Decode: `len = X2 >> 56`, `packed = X2 & 0xFFFFFFFF`.
2. Compute byte length of the string (existing logic).
3. Clamp `start` to valid byte range.
4. Scan from `start`:
   - At each byte, compute UTF-8 length of the character at that position.
   - Compare the next `len` bytes with `packed` (byte0, byte1, …).
   - If they match, stop.
   - Otherwise advance by that UTF-8 length (never advance by 1 inside a multi-byte character).
5. Copy bytes from `start` to the found position (or end of string) into a new allocation.

**UTF-8 length from lead byte:**

- `< 0x80` → 1
- `0xC2–0xDF` → 2
- `0xE0–0xEF` → 3
- `0xF0–0xF7` → 4
- Otherwise → 1 (fallback)

**Effect:** `substring_until_char(s, 0, 'é')` stops only at the exact UTF-8 sequence for `'é'`, not at `'ê'` or other characters sharing the same lead byte.

---

## Summary Table

| Phase | File | Change |
|-------|------|--------|
| **Lexer** | `lexer_string_literals.silica` | UTF-8-aware advance in `read_char_literal` |
| **Parser** | — | No changes |
| **Type checker** | — | No changes |
| **SIR generator** | `sir_generator/terms/literals.silica` | `byte_to_int64`, `char_lexeme_to_utf8_encoded`, use encoded value for char literals |
| **Emitter** | `string_substring_mmap_nomte.silica` | Full UTF-8 sequence comparison in `L_substring_until_char_helper` |
