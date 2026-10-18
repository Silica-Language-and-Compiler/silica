# compile_defects_trait_typed_record_call_x8_addition

An assembly-golden trial for an emitter defect, in a directory of its own (see the
`compile_defects_addition` README). The stdlib units it needs, `wbt_map` and `OrderedMap`, are
symlinked in `lib/`, so their `.sams`/`.o` are built in this directory's `lib/` and not in
`compiler/stdlib`; the Makefile assembles and links `lib/*.sams` as helpers.

- `defect_trait_typed_record_call_x8`: a record-returning callee copies its result through the
  buffer in X8 when X8 is non-zero. The trait-typed call site
  `users: OrderedMap[string, int64, mem(normal)] <- wbt_map@empty({...})` never set X8, so
  `wbt_map_empty` copied its record through a stale X8. The fix: every call clears X8
  (`MOV X8, XZR`) unless it passes a buffer on purpose. The overrun is usually harmless, so a run
  seldom shows it. The `.ascomp` is the check: it pins `MOV X8, XZR` in the call sequence of
  `wbt_map_empty` and of the generic `wbt_map_insert` calls, and the buffer (`SUB X8, X29, #96`) for
  the trait-dispatched `OrderedMap_get`. Expected output: `41`, `2`, exit 0.

Linux goldens (`.linux_aarch64.ascomp`, `.linux_x86_64.ascomp`) are still to be captured.
