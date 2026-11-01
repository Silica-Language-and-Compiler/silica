# Crypto Proposal Explained (Simplified)

> **Implementation status (2026-10-16).** This is a proposal. None of it is implemented: the lexer, type checker, effect checker and specification have no `Secret` / `Public` labels, no `CtMask` type and no `proc[secret]` effect, and there are no secret buffers. Random bytes, hashes and HMAC are not built-ins either. The paragraphs under "Random Bytes and Hash Functions" describe how a program obtains them today, through Fifi (`dangerous_*` wrappers in `spawn_dangerous` workers; networking and other foreign access likewise go through the FFI, specification §20.4), with results that stay external-danger-touched until re-created.

## What's Being Proposed: Making Cryptography Safer by Design

This proposal adds language-level protections to Silica so that cryptographic code is safer by default.

### The Core Problem It Solves

Today, crypto bugs often come from:
- **Timing leaks**: code that runs faster or slower based on secret data
- **Accidental exposure**: secrets ending up in logs or error messages
- **Control-flow leaks**: branching on secret values

These are hard to catch in code review and can slip into production.

### The Proposed Solution: Build Safety Into the Language

Instead of relying on guidelines and audits, the compiler enforces safety rules.

### Key Features

1. **Secret vs. public labels**
   - Values are marked `Secret` or `Public`
   - Secrets can't accidentally become public
   - The compiler tracks secrecy through the code

2. **Constant-time operations**
   - Comparisons of secrets return a special mask type (`CtMask`), not a boolean
   - This prevents timing-based leaks

3. **No secret-dependent branching**
   - Secrets can't be used in `case` expressions or guards (Silica has no `if` or loops; control flow is via `case` and recursion)
   - Recursion depth and which branch is taken must be determined by public values only—secrets can be *data* inside a recursive computation, but must not *control* how many steps run or which path is taken (that would leak via timing)
   - Prevents control-flow and work-factor leaks

4. **Safe memory access**
   - Secrets can't be used as indices into buffers or lists
   - Prevents address-based leaks

5. **Protected secret storage**
   - Special buffers for secrets that:
     - Can't be copied
     - Can't be printed/logged
     - Are overwritten (zeroized) by default when the buffer goes out of scope—the compiler enforces this behind the scenes so you don't have to remember
     - Can't use regular equality checks

6. **Special function contexts**
   - Functions marked with `proc[secret]` have extra restrictions:
     - No I/O or logging
     - No panics
     - No secret-dependent sizes or control flow

### What This Means in Practice

If you try to write insecure code, the compiler rejects it. For example:
- Using a secret in a `case` expression or guard → compile error
- Logging a secret value → compile error
- Using a secret as a buffer or list index → compile error

The compiler guides you toward safe patterns.

### Random Bytes and Hash Functions

Cryptographically secure random bytes and hash functions (the SHA-2 family and HMAC) are expected to become Silica
built-ins later. They are not built-ins at first.

Until they are:
- **Programs reach them through Fifi:** a `dangerous_*` wrapper called from a `spawn_dangerous` worker, like any
  other foreign library.
- **Their results are external-danger-touched.** A random token, a digest or a MAC leaves the handler that receives
  the FFI result cast only through re-creation
  ([silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md) §7.7). Only the re-created value may
  be stored in actor state, sent to other actors, or written to a socket.
- **Constant-time comparison** of secrets (a token check, for example) also happens inside the wrapper until
  `CtMask` exists. Its result only decides what the handler does next, so it needs no re-creation.

When these become built-ins, their results are ordinary Silica values subject to the `Secret` / `Public` rules above.

### The Big Picture

This shifts security from "hope developers follow guidelines" to "the compiler prevents mistakes." It's like a seatbelt: you can't forget to use it because it's built into the system.

The goal is to make it easier to write secure cryptographic code and harder to write insecure code, reducing entire classes of vulnerabilities at compile time.
