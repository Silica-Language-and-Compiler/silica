# fail_stdin_tainted_chunk_printed (pending)

The owner of the `(:stdin)` carrier prints the raw `(:rx, chunk)` it receives, without `recreate`. By the FFI
wrapper specification this must not compile: the chunk is the payload of an FFI result cast, so it is
external-danger-touched (§7.6), and external-danger-touched data may not be used in a sequence that declares
`device_io` (§7.4). The expected error is E2103 at line 15, column 17 (`dangerous_stdin_tainted_chunk_printed.golden_fail`).

**Why it is pending (2026-11-18).** The compiler tracks taint only inside the worker that makes the foreign call
(the `error_app_ffi_result_cast` trials). It does not treat a payload a behaviour *receives* from a dangerous actor
as tainted, so this program compiles. The gap is not specific to standard input: it holds for every dangerous
carrier (`(:tcp)`, `(:udp)`, `(:serial)`, `(:backing)`), whose owners `decode` or `recreate` by convention, not by
an enforced rule. Enforcing it needs a static rule for which received payloads are tainted (the carrier learns its
owner only at run time, from `:open`), which is an open question for the language owner; see
`compiler/design_documents/stdin_carrier_design.md` §11.

The suite skips this trial while `INTEGRATE_PENDING` exists. Remove that file when the rule is enforced.
