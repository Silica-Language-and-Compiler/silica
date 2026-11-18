# Open items in the design and plan documents, checked against the code

Made on 2026-11-18 from the audit of `ROADMAP.md` and `compiler/design_documents/` on branch
`update_design_plan_docs` (commit 28799ea475). Items the audit found done were corrected in the documents
and are not listed here.

- **Part 1, still open:** 299 items. The document records each as open or partly done, and the code,
  trials or git history did not show it done.
- **Part 2, undecided:** 54 items. The audit could not settle these by reading.

How the list was made, and its limits:

- The audit read code, trials and git history. Nothing was built or run.
- Line numbers are approximate.
- The same item can appear under more than one area, because the roadmap and the specification repeat
  items that a topic document also records (for example `call_with_timeout`). They are not merged.
- A few entries rest on a search or on the document's own status text, not on a full read of the code;
  the "Found" line says what was checked.

| Area | Open | Undecided |
| --- | --- | --- |
| Language specification | 40 | 6 |
| Transport and storage carriers | 40 | 3 |
| Memory: region safety and chunk 15 | 33 | 7 |
| Actors | 31 | 2 |
| Data structures | 27 | 1 |
| Boards and ports | 53 | 8 |
| Compiler and phase notes | 40 | 18 |
| Roadmap, FFI and the remaining documents | 35 | 9 |
| **Total** | **299** | **54** |

# Part 1: still open

## Language specification (40)

### 1. The word region is not rejected with a reserved-word diagnostic, and a record field named region is not rejected

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 2.2.1 Keywords, about line 238
- **Recorded as:** "No diagnostic yet says that `region` is a reserved word, and the field case is not rejected"
- **Found:** Searched the parser sources for a reserved-word message for region and found none; no commit since 2026-10-16 mentions one. Bindings and parameters still get the generic E1040 and E1000.

### 2. Function literals cannot capture anything except a binding holding an integer literal, so closure environments do not exist and a capturing literal cannot be returned

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 3.3.6 Function Literals, about line 2170
- **Recorded as:** "Closure environments are not implemented"
- **Found:** E1072 and E1067 are still the rejections and no commit since 2026-10-16 mentions closures or capturing; make_multiplier style examples are still rejected.

### 3. Exceptions do not exist; error handling is by return values only

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 6.2.3 Result Handling, about line 3795
- **Recorded as:** "exceptions not yet implemented"
- **Found:** No exception or handler construct appears in the lexer keywords, type checker or emitters; section 16.1.2 also states Silica has no exception handler.

### 4. read_lines returns the whole file as one string instead of a list of lines, and there is no read_file

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 5.2.1 File Reading, about line 3537 (also 22.6, about line 15040)
- **Recorded as:** "`read_lines(path: string) -> string` returns the whole content of the file as one string, not a list of lines; there is no `read_file`"
- **Found:** type_checker_builtin_signatures.silica lists only read_lines, file_exists, delete_file and append_file as file built-ins, and read_lines is typed as string. read_file appears only in runtime shims and file_io_inline.silica, not as a type-checked built-in.

### 5. write_file is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 5.2.2 File Writing, about line 3537 (also 22.6, about line 15040)
- **Recorded as:** "`write_file` ... are not implemented"
- **Found:** grep for write_file across compiler/src and compiler/stdlib finds nothing.

### 6. get_file_size is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 5.2.3 File Operations, about line 3537 (also 22.6, about line 15040)
- **Recorded as:** "`get_file_size` ... are not implemented"
- **Found:** grep for get_file_size across compiler/src and compiler/stdlib finds nothing.

### 7. The directory operations are not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 5.2.4 Directory Operations, about line 3537 (also 22.6, about line 15040)
- **Recorded as:** "the directory operations (§5.2.4) ... are not implemented"
- **Found:** The type checker's file-I/O name list has no directory operation, and no emitter lowers one.

### 8. exec_command is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 5.4 and 22.8 Process Execution, about line 3537 and about line 15099
- **Recorded as:** "`exec_command` (§5.4) ... are not implemented"
- **Found:** grep for exec_command across compiler/src and compiler/stdlib finds nothing.

### 9. get_cpu_topology_info is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 5.5 and 22.9 System Information, about line 3537 and about line 15107
- **Recorded as:** "`get_cpu_topology_info` (§5.5) ... are not implemented"
- **Found:** grep for get_cpu_topology_info across compiler/src and compiler/stdlib finds nothing.

### 10. panic is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 22.16 Control Flow (also 15.1.2.3 and 22 intro), about line 15332 and about line 7738
- **Recorded as:** "`panic` (§22.16) ... not implemented"
- **Found:** grep for panic as a built-in name in compiler/src finds no signature or lowering.

### 11. The :stop of section 15.5 (state-machine stop) is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 15.1.2.3 Actor Termination, about line 7738
- **Recorded as:** "`panic` (§22.16) and the `:stop` of §15.5 are not implemented"
- **Found:** It belongs to state-machine actors, which have no support in the compilers (see the state-machine item).

### 12. Spawner positions in the actor identity are numbered at run time, not at build time

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 15.1.4 Actor Identity, about line 8623
- **Recorded as:** "The compilers do not yet number positions at build time ... Build-time positions remain the specified design."
- **Found:** ROADMAP chunk 10 still records build-time numbering as design, and no compiler pass or commit since 2026-10-12 assigns positions at build time.

### 13. The supervisor maintenance call :terminate_actor is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 15.4.8.3 Supervisor Maintenance Calls, about line 9175
- **Recorded as:** "`:terminate_actor` is not implemented"
- **Found:** grep for terminate_actor across compiler/src and compiler/stdlib (including Supervisor.silica) finds nothing.

### 14. The shutdown time limit of a supervisor child is not enforced; a child always finishes its current dispatch

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 15.4.12.2 Coordinated Shutdown of Live Children (and 15.4.13.2, about line 9482), about line 9412
- **Recorded as:** "The `shutdown` time limit is not enforced on any target."
- **Found:** ROADMAP chunk 10 still lists enforcement of the shutdown time limit as not done, and git log since 2026-10-16 has no commit that enforces it.

### 15. The region_dumps argument of FailureReporter handle_report is not delivered; region data appears only in the report text

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 15.4.13.4 FailureReporter Trait, about line 9593 (milestone b at about line 9583)
- **Recorded as:** "The `region_dumps` argument of `handle_report` is not delivered"
- **Found:** The reporter is an ordinary cast-only actor taking a string; no sources deliver region payload bytes, and no commit since 2026-10-16 changes this.

### 16. A pooled FFI worker that would lift the cap on dangerous-actor threads is not built

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 15.4.13.5 FFI Fault Containment, about line 9652
- **Recorded as:** "a pooled FFI worker that would lift the cap is not built"
- **Found:** No pooled worker exists in compiler/stdlib or the emitters; commit ffafc09791 instead makes a refused dangerous-actor thread fail the spawner with (:explicit, :thread_limit).

### 17. State-machine actors (StateMachine trait, spawn_state_machine, state_machine_behavior) are not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 15.5 State-Machine Actors, about line 9755
- **Recorded as:** "State-machine actors are not implemented"
- **Found:** spawn_state_machine and state_machine_behavior appear only in the cast and call convention checker; there is no trait support, no SIR lowering and no trial. ROADMAP removed the state-machine chunk (commit d8835559c6).

### 18. call_with_timeout is not implemented, so a caller cannot stop waiting for a reply

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 16.1.1.2 call_with_timeout (under 16.1.1 Synchronous Call), about line 9931
- **Recorded as:** "`call_with_timeout` is not implemented: a caller cannot yet stop waiting for a reply."
- **Found:** The type checker has only its convention check in type_checker_cast_convention.silica; there is no builtin signature, no lowering, the emitters mention it only in comments, and no trial calls it.

### 19. The E2240 self-call check does not cover call_with_timeout

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 16.2.6.5 Self-Call Deadlock Prevention, about line 10224
- **Recorded as:** "`call_with_timeout` is not covered by this check."
- **Found:** Follows from call_with_timeout not existing; no check for it is present.

### 20. register, whereis and unregister (the atom-keyed registry operations) are not implemented; names bind only at spawn

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 20.3.1 Actor Registry (and 22 intro), about line 12706
- **Recorded as:** "`register`, `whereis` and `unregister` are not implemented."
- **Found:** grep for whereis and unregister finds nothing in compiler/src or compiler/stdlib; register appears only in a convention-checker comment about register_failure_reporter.

### 21. assert and unreachable are not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 22.16 Control Flow, about line 14853
- **Recorded as:** "these are absent: `panic`, `assert`, `unreachable` (§22.16 ...)"
- **Found:** No signature or lowering for either in the type checker or SIR generator. The word unreachable appears in emitters only as a comment or label.

### 22. random_int and hash are not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 22.14 Runtime Operations, about line 14853
- **Recorded as:** "`random_int` and `hash` (§22.14)"
- **Found:** grep for random_int and "hash" as built-in names in compiler/src and compiler/stdlib finds nothing.

### 23. get_sve_vector_length is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 22.11 SVE Vector Length Queries, about line 14853
- **Recorded as:** "`get_sve_vector_length` (§22.11)"
- **Found:** grep across compiler/src and compiler/stdlib finds nothing.

### 24. The atomic operations of section 22.12 are not implemented, and alloc_atomic is not added

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 22.12 Atomic Operations, about line 14853
- **Recorded as:** "the atomic operations (§22.12; `alloc_atomic` is not added, Q8)"
- **Found:** grep for atomic_load, atomic_add, compare_and_swap and alloc_atomic finds nothing in the type checker or emitters.

### 25. size_of, align_of, buffer_length and buffer_capacity are not implemented as language built-ins

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 22.13 Type Operations and 22.3 Buffer Operations, about line 14853
- **Recorded as:** "`size_of`, `align_of`, `buffer_length`, `buffer_capacity`"
- **Found:** align_of, buffer_length and buffer_capacity do not occur in compiler/src; size_of occurs only inside device-description and FFI emitter code, not as a type-checked built-in.

### 26. string_slice is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 22.15 String Operations, about line 14853
- **Recorded as:** "`string_slice`"
- **Found:** grep across compiler/src and compiler/stdlib finds nothing.

### 27. int_to_string and string_to_int are not implemented as language built-ins

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 22.15 String Operations, about line 14853
- **Recorded as:** "`int_to_string` and `string_to_int`"
- **Found:** int_to_string does not occur; string_to_int occurs only in the compiler's own data-structure helpers (string_parse), not as a built-in in the type checker.

### 28. actor_carrier_index has no lowering on the ESP32-S3

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 22.10 CPU Affinity Operations, about line 15218
- **Recorded as:** "`actor_carrier_index` is implemented on the three hosted targets only; the ESP32-S3 emitter has no lowering for it."
- **Found:** grep of compiler/src/emitter/ESP32-S3_raw finds no actor_carrier_index; only the three hosted emitters have it.

### 29. The STM32-L476RG_raw transport pack lists no carrier links

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 16.4.9 Carrier links, about line 10705 and about line 10777
- **Recorded as:** "The Linux and Nucleo packs do not list any link yet" (Linux part closed 2026-11-18; Nucleo remains)
- **Found:** STM32-L476RG_raw/transport_pack.silica provides_link returns false for everything and provided_links says the links are not written yet.

### 30. UART2 on the ESP32-S3 and the supervised bring-up actor for it are not done

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 16.4.9 Carrier links, about line 10777 and about line 10788
- **Recorded as:** "UART2 waits for its window" and "UART2, the supervised bring-up actor pending"
- **Found:** ESP32-S3_raw/transport_pack.silica provides_link accepts only uart instance 1 and usb_serial_jtag.

### 31. UART links support only 8N1 with no flow control; parity, stop bits and flow control are deferred

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 16.4.9 Carrier links, about line 10772
- **Recorded as:** "parity, stop bits and flow control are deferred"
- **Found:** The packs' link parameters are only the UART number and baud; nothing accepts parity, stop bits or flow control.

### 32. Phase C (UART on STM32-L476RG_raw) and Phase D (network links on boards) of the link plan are not done

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 16.4.9 Carrier links, about line 10789
- **Recorded as:** "C UART on the STM32-L476RG_raw; D network links on boards, later."
- **Found:** The STM32 pack lists no links and E2416 is described as reserved with nothing reaching it.

### 33. Rule 3.2, duplicate computation, is a hard error in the specification but has no diagnostic

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification-additional.md, Implementation status table (rule 3.2), about line 20
- **Recorded as:** "NOT implemented; no diagnostic exists"
- **Found:** No such rule or error code in compiler/error_codes.md or compiler/src.

### 34. Rule 3.3, redundant algebraic operations, is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification-additional.md, Implementation status table (rule 3.3), about line 21
- **Recorded as:** "NOT implemented"
- **Found:** No such rule or error code in compiler/error_codes.md or compiler/src.

### 35. Rule 3.4, invariant guards in case, is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification-additional.md, Implementation status table (rule 3.4), about line 22
- **Recorded as:** "NOT implemented"
- **Found:** No such rule or error code in compiler/error_codes.md or compiler/src.

### 36. Rules 3.5 and 3.6, loop-invariant code and constant hoisting, are not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification-additional.md, Implementation status table (rules 3.5, 3.6), about line 23
- **Recorded as:** "NOT implemented"
- **Found:** No such rule or error code in compiler/error_codes.md or compiler/src.

### 37. Rule 3.7, redundant constant expressions, is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification-additional.md, Implementation status table (rule 3.7), about line 24
- **Recorded as:** "NOT implemented (the compiler folds nothing and rejects nothing here)"
- **Found:** No such rule or error code in compiler/error_codes.md or compiler/src.

### 38. Rule 3.8, multiply by a power of two, is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification-additional.md, Implementation status table (rule 3.8), about line 25
- **Recorded as:** "NOT implemented"
- **Found:** No such rule or error code in compiler/error_codes.md or compiler/src.

### 39. Region uniqueness across the application lifetime has no mechanism

- [ ] reviewed
- **Document:** compiler/design_documents/recursive_tuple_specification.md, 8 Open Items, about line 169 (also status note at line 9 and table row at line 22)
- **Recorded as:** "Region uniqueness: R must be unique across application lifetime. Mechanism postponed."
- **Found:** Searched compiler/src and the design documents for a uniqueness mechanism and found none; only fresh_lifetime and per-scope uniqueness exist.

### 40. The Layer 1 formal-verification rules of section 4 have no compiler counterpart

- [ ] reviewed
- **Document:** compiler/design_documents/recursive_tuple_specification.md, Implementation status, about line 9
- **Recorded as:** "Not verified: the Layer 1 formal-verification rules in section 4 are a proof-side statement with no compiler counterpart."
- **Found:** The compiler has no mechanized proof checker or proof-term output; nothing has been added since 2026-10-16.

## Transport and storage carriers (40)

### 41. The board medium for storage carriers (phase S3) is not built

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.8 status and 6.8.7 phase table, about line 698 and 930
- **Recorded as:** "S3 is not built"
- **Found:** No flash or SD block worker exists in the ESP32-S3 or STM32 trees and no board `(:store)` link is provided by any board pack.

### 42. The `(:sd_blocks, n, retention)` link for the ESP32-S3 needs the SPI3 block worker, which does not exist

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.8.6 link table, about line 909
- **Recorded as:** "needs the SPI3 block worker (peripherals plan item I, not built)"
- **Found:** `board/apps/device_lib` has an SPI2 driver (display) but no SPI3 or SD card worker.

### 43. The `(:flash_region, n, retention)` link for the ESP32-S3 and STM32 needs a flash controller worker, which does not exist

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.8.6 link table, about line 910
- **Recorded as:** "needs a flash controller worker; which medium comes first is open"
- **Found:** No flash controller worker for storage exists in either board tree.

### 44. Which medium comes first on the board, internal flash or the SD card, and the board pack's region table, is undecided

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.8.8 Open item 2, about line 971
- **Recorded as:** "Which medium comes first on the board, internal flash or the SD card"
- **Found:** No document or commit message records Lee's choice.

### 45. Hash chain or MAC per record for tamper evidence, and encryption at rest, are not part of the storage design

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.8.8 Open item 6 and 6.8.7 "later" row, about line 976 and 932
- **Recorded as:** "not in this design; the CRC detects accidents and not an adversary"
- **Found:** storelog.silica has CRC-32C only; no MAC, chain or encryption code exists.

### 46. Whether a named-stream scheme (several logs in one region found by atom) is ever needed is unanswered

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.8.8 Open item 7, about line 978
- **Recorded as:** "the answer waits for a use"
- **Found:** Regions are declared per link; no named-stream code exists and no use has arisen in the tree.

### 47. The spelling of the `(:store)` tag and of the retention atoms is still provisional

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.8.8 Open item 8, about line 980
- **Recorded as:** "(provisional)"
- **Found:** The spellings are built and used in Carrier.silica, Link.silica and the trials, but no document records Lee confirming them.

### 48. Trials in which an owner sends to an already ended carrier exist only for `(:tcp)`, not for the other carrier kinds

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.2 upgrade note item 4, about line 559
- **Recorded as:** "the other carrier kinds have none yet"
- **Found:** Only `transport_addition/app_transport_tcp_close_after_end` exists; no udp, serial, memory-store or backing-store equivalent was found.

### 49. A cast to an ended actor returning false has not been run on Linux AArch64, Linux x86-64 or STM32-L476RG_raw

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.2 upgrade note item 1, about line 543
- **Recorded as:** "changed but not run on Linux AArch64, Linux x86-64, STM32-L476RG_raw"
- **Found:** The trial `actors_addition/cast_to_ended_actor_returns_false` exists; the only run record found is Apple Silicon and the ESP32-S3 board (commit b52e214d66).

### 50. What becomes of the legacy builtin `send`, which still raises for an ended target, is not decided

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.2 upgrade note item 1, about line 547
- **Recorded as:** "what becomes of it is not decided"
- **Found:** No decision by Lee is recorded in any document or commit message.

### 51. The `(:usb_cdc)` carrier (USB OTG, device and host roles) is not started

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.4 table, about line 627; also 10 "later" row about line 1243
- **Recorded as:** "not started: plan items K (interrupts), H (DMA) and L (the USB OTG stack)"
- **Found:** No USB OTG worker or `usb_cdc` row exists in the ESP32-S3 pack or device_lib.

### 52. The `(:ble_gatt)` carrier on hosted targets and boards, and phase 5, are not built

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.4 table, 6.5 and 10 phase 5, about line 631 and 1239
- **Recorded as:** "not started"
- **Found:** Carrier.silica, Link.silica and all transport packs have no ble or bluetooth row, and no BLE stdlib module exists.

### 53. The `(:silica_shape)` format (phase 6) is not built

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 10 phase 6, about line 1240
- **Recorded as:** "`(:silica_shape)` as the second protocol (decided 2026-11-12, ahead of CBOR)"
- **Found:** No `wire_silica_shape.silica` in compiler/stdlib; only `wire_etf.silica` exists.

### 54. The `(:cbor)` format (phase 7) is not built

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 10 phase 7, about line 1241
- **Recorded as:** "`(:cbor)` as the third protocol"
- **Found:** No `wire_cbor.silica` exists; `(:cbor)` is still the tag the E2410 trial uses as an unprovided protocol.

### 55. The `(:unix_dgram)` carrier is only a possibility if IPC_OS is ever built

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.3 table, about line 598
- **Recorded as:** "later, if IPC_OS.md is ever built"
- **Found:** No unix_dgram carrier row or code exists.

### 56. The `(:uart0)` carrier (the console shares UART0) and UART2 are not built

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 14 stage S-C note, about line 1738; compiler/design_documents/transport_links_design.md, header status, about line 29; compiler/design_documents/transport_esp32s3_wifi_plan.md, 7 S-A note, about line 287
- **Recorded as:** "Still not done: the `(:uart0)` carrier (the console shares UART0), UART2"
- **Found:** The ESP32-S3 transport pack provides only "uart1" and "usb_serial_jtag"; no UART0 carrier or UART2 window exists.

### 57. E2407 (WireFrame segmentation under a real BLE mtu) is deferred and its number is still provisional

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 14 phase 2 notes, about line 1673; compiler/design_documents/transport_links_design.md, 12 item 11, about line 647
- **Recorded as:** "Deferred ... E2407"; "E2406 and E2407 numbers ... are still provisional"
- **Found:** grep finds no E2407 in compiler/src or in error trials; E2406 exists.

### 58. The tag-keyed closed-trait dispatch of 9.1 is not built and the trait checker does not enforce it

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 14 phase 2 notes and ETF note, about line 1619 and 1693
- **Recorded as:** "The tag-keyed trait dispatch of §9.1 is not built; the module is the closed set"
- **Found:** Carrier.silica is a case-per-tag table; E2409 (program impl of WireFormat or Carrier) exists, but no tag-keyed dispatch was found.

### 59. A hole between two storage blocks (the header of a new block written, the last records of the block before it not) is found only by a replay, not by open

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.8.10 "Not built, not tried", about line 1098
- **Recorded as:** "Only the tail block is checked at open."
- **Found:** dangerous_store_backing_carrier.silica recovers by reading block headers and the tail block only.

### 60. `(:link_down, :medium)` on a backing has no trial because a write or flush cannot be made to fail on demand

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.8.10 "Not built, not tried", about line 1100
- **Recorded as:** "`(:link_down, :medium)` has no trial"
- **Found:** No store trial in app_transport_store_backing or error_enforcement_addition forces a medium failure.

### 61. The exclusive lock across two processes on a backing has no trial of its own

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.8.10 "Not built, not tried", about line 1102
- **Recorded as:** "has no trial of its own"
- **Found:** Only the in-process `dangerous_store_backing_in_use` trial exists.

### 62. A device worker cannot be a supervisor child, so board carriers are restarted by the program and the supervised board bring-up is not built

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 14 implementation notes, about line 1723; compiler/design_documents/transport_links_design.md, header status, about line 29 and 6.4
- **Recorded as:** "A device worker cannot be a supervisor child (`flavor` has no `:device`)"
- **Found:** No `:device` flavor was found in the Supervisor library; no later commit mentions adding one.

### 63. The Nucleo UART link (phase C of the links design) and any STM32 carrier are not built

- [ ] reviewed
- **Document:** compiler/design_documents/transport_links_design.md, header status and 9 phase table, about line 29 and 530; compiler/design_documents/transport_hosted_status.md, matrix STM32 row
- **Recorded as:** "(phase C)"; STM32 "none (`provides_carrier` is false for every tag)"
- **Found:** The STM32-L476RG_raw transport pack provides no carrier and its header says the design has no carrier table for this board yet.

### 64. Network links on boards (phase D, Wi-Fi and Ethernet TCP on the ESP32-S3 and the STM32) and E2416 are not designed or built

- [ ] reviewed
- **Document:** compiler/design_documents/transport_links_design.md, 8 and 9 phase D, about line 504 and 531
- **Recorded as:** "Out of scope: Wi-Fi and Ethernet TCP on boards (phase D, later)"; "decided later"
- **Found:** Neither board has a network stack or a radio driver and no E2416 check exists.

### 65. UART parity, stop bits and flow control are deferred; 8N1 stays fixed

- [ ] reviewed
- **Document:** compiler/design_documents/transport_links_design.md, 3 decision 13 and 12 item 7, about line 91 and 632
- **Recorded as:** "deferred to later"
- **Found:** No parity, stop-bit or flow-control parameter exists in Link.silica or the packs.

### 66. The ESP32-S3 Wi-Fi stages 3 to 9 (radio route R2, TCP, etc.) are deferred

- [ ] reviewed
- **Document:** compiler/design_documents/transport_esp32s3_wifi_plan.md, status and 8, about line 4 and 469
- **Recorded as:** "the Wi-Fi stages (3 to 9) are deferred (§8)"
- **Found:** No radio, interrupt runtime, DMA or network stack exists in the board tree.

### 67. Stage S-E hardening (framing recovery after a lost byte, flow control, console-interleaving rule) is not recorded as done

- [ ] reviewed
- **Document:** compiler/design_documents/transport_esp32s3_wifi_plan.md, 8 stage S-E, about line 504
- **Recorded as:** "S-E. Hardening and docs." with no done note
- **Found:** No dated done note, trial or commit was found for it.

### 68. Decisions for Lee on the stage S-C parser reading the pack's `carrier_spawn` text, the `(:usb_serial_jtag)` link and E2415's limit are listed without a recorded ruling

- [ ] reviewed
- **Document:** compiler/design_documents/transport_esp32s3_wifi_plan.md, 7 stage S-C, about line 360
- **Recorded as:** "Decisions for Lee"
- **Found:** The behaviour is built as described, but no document or commit message records his acceptance.

### 69. Wireless interface binding is not verified on the nix host (no hardware) or on the Mac (en1 inactive); only the refusal is checked

- [ ] reviewed
- **Document:** compiler/design_documents/transport_hosted_ethernet_plan.md, 5 E2 status, about line 159; compiler/design_documents/transport_hosted_status.md, Interface binding, about line 27; compiler/design_documents/transport_serialization_design.md, 6.3 `(:tcp)` row, about line 594; compiler/design_documents/transport_links_design.md, 3.2, about line 206
- **Recorded as:** "Still not verified: the nix host has no wireless hardware"
- **Found:** No run record of a wireless bind on nix or the Mac exists.

### 70. Two IPv4 addresses on one interface, and a second wired interface so that `(:ethernet, 1)` succeeds, are not verified

- [ ] reviewed
- **Document:** compiler/design_documents/transport_hosted_ethernet_plan.md, 5 E2 status, about line 159; compiler/design_documents/transport_hosted_status.md, Interface binding, about line 27; compiler/design_documents/transport_links_design.md, 3.2, about line 206
- **Recorded as:** "two IPv4 addresses on one interface; a second wired interface"
- **Found:** No run record exists for either case.

### 71. The UDP example `ethernet_direct_udp` over the Internet to aalang.org is not verified; it passed Mac to nix over the LAN only

- [ ] reviewed
- **Document:** compiler/design_documents/transport_hosted_ethernet_plan.md, 5 E2 status, about line 159; compiler/design_documents/transport_hosted_status.md, Interface binding, about line 27
- **Recorded as:** "the UDP example over the Internet to aalang.org"
- **Found:** No run record to aalang.org for the UDP example was found.

### 72. The 169 rewritten goldens and the wireframe golden of the E2 merge have not been reviewed by hand, and an x86-64 emitter change regenerated goldens in three suites on x86 only

- [ ] reviewed
- **Document:** compiler/design_documents/transport_hosted_ethernet_plan.md, 5 E2 status, about line 159; compiler/design_documents/transport_hosted_status.md, Interface binding "Not verified", about line 27
- **Recorded as:** "the final regenerated goldens by hand review"; "Earlier unreviewed items remain"
- **Found:** No record of a hand review exists; the goldens were refreshed again later by `c063517bd9`.

### 73. The fixed point of the current Linux x86-64 and Linux AArch64 compilers has not been run (by rule, fixed points only on request)

- [ ] reviewed
- **Document:** compiler/design_documents/transport_hosted_ethernet_plan.md, 5a, about line 268; compiler/design_documents/transport_hosted_status.md, Verified vs planned, about line 49
- **Recorded as:** "Not verified: the fixed point of the current Linux x86-64 compiler (not run, by rule ...)"
- **Found:** Commit 39b6a5a50b says the build is a --no-fixpoint build and no later fixed-point record was found.

### 74. The mTLS example's `happy_path` check runs on the Mac only, not on pix or nix

- [ ] reviewed
- **Document:** compiler/design_documents/transport_hosted_status.md, E8 and mTLS paragraph, about line 59
- **Recorded as:** "`happy_path` runs on the Mac only"
- **Found:** Only `run_timeout_checks.sh` (11 checks) is recorded on the three hosts.

### 75. `E2418` does not yet look at IPv6 listen literals; the carrier's refusal at `:open` is the only guard

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.3 IPv6 paragraph "Link rules", about line 606
- **Recorded as:** "`E2418` does not yet look at IPv6 literals"
- **Found:** The effect and type checker changes of c063517bd9 did not add IPv6 handling to E2418.

### 76. Authentication, encryption and peer identity for `(:tcp)` (SEMP/TRUST over mutual TLS, cookie handshake) are planned in Project BEES and not built

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.3 Security, about line 610 and 1340; compiler/design_documents/transport_hosted_status.md, Verified vs planned, about line 66
- **Recorded as:** "Planned, not built: TLS/auth (Project BEES, not built as of 2026-11-10)"
- **Found:** The tree has only the mTLS example under examples/transport_pairs/ethernet_direct_mtls, which is an example and not language TLS; BEES is another repository and I did not check it.

### 77. First-class quantum-safe TLS (types, intrinsics, supervised session actors) is not implemented and is out of scope for the language

- [ ] reviewed
- **Document:** compiler/design_documents/tls_quantum_safe_future.md, status and 11 implementation order, about line 5 and 259
- **Recorded as:** "Future development. Not implemented"; "Implementation order (still future)"
- **Found:** grep finds no tls_connect, tls_session or tls_close in compiler/src or compiler/stdlib.

### 78. The secret and public labels, the `CtMask` type and the `proc[secret]` effect are not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/crypto-proposal-introduction.md, implementation status, about line 5
- **Recorded as:** "None of it is implemented: ... no `Secret` / `Public` labels, no `CtMask` type and no `proc[secret]` effect"
- **Found:** grep of compiler/src finds none of these names.

### 79. Secret buffers with automatic zeroization, and random bytes, hash and HMAC built-ins, are not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/crypto-proposal-introduction.md, implementation status and "Random Bytes and Hash Functions", about line 5 and 48
- **Recorded as:** "there are no secret buffers. Random bytes, hashes and HMAC are not built-ins either"
- **Found:** The builtin signature table has no random, hash or HMAC entries, and compiler/stdlib has no such module.

### 80. The `(:silica_shape)`, `(:msgpack)`, `(:json)` and `(:protobuf)` formats named as later work are not built

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 10 "later" row, about line 1243
- **Recorded as:** "`(:msgpack)`, `(:json)`, `(:protobuf)` after decision 7; the distribution protocol design (§7)"
- **Found:** Only wire_etf.silica exists in compiler/stdlib, and no distribution protocol module exists.

## Memory: region safety and chunk 15 (33)

### 81. The atomic surface (the four atomic_* builtins, lowering on four targets, shared atomic regions) is not built

- [ ] reviewed
- **Document:** compiler/design_documents/region_memory_safety_plan.md, stage 7 row and work item 14, about lines 28 and 62; compiler/design_documents/region_memory_safety_design.md, section 9 and hazard H10, about lines 634 and 137; compiler/design_documents/Phase1_TODOs/region_memory_safety_todo.md, section 2.5 and checklist, about lines 173, 228 and 229
- **Recorded as:** "the atomic_* builtins (§9; alloc_atomic will not be added, Q8)" not built; "Atomic references ... full atomic lowering is not complete"
- **Found:** grep of compiler/src and compiler/stdlib finds no atomic_load, atomic_store, atomic_cas or atomic_* builtin in the signatures; only alloc_ref into region(L, atomic) with plain accesses exists.

### 82. The atomic run trials, two-actor counter and CAS trials and the two-core board runs are not written

- [ ] reviewed
- **Document:** compiler/design_documents/region_memory_safety_plan.md, work item 15 and stage 7 gate, about lines 63 and 28; compiler/design_documents/region_memory_safety_design.md, section 14.2 run trials (atomic row), about line 826
- **Recorded as:** "atomic: atomic_counter_two_actors, atomic_cas_loop, atomic_orderings, on hosts and the board's two cores"
- **Found:** no trial with atomic_counter or atomic_cas in its name exists under trials/; only the alloc_atomic_int64 and alloc_ref_atomic_space single-cell trials.

### 83. Errors E2315, E2316 and E2317 (atomic operand not atomic, cell type not a word scalar, ordering invalid) are not emitted

- [ ] reviewed
- **Document:** compiler/design_documents/region_memory_safety_design.md, section 10 error table and section 14.1, about lines 723 to 725 and 805; compiler/design_documents/region_memory_safety_plan.md, stage 8 row, about line 29
- **Recorded as:** "Stays (atomics)"; "static buffer checks E2315 to E2318 not emitted" in ROADMAP
- **Found:** grep for E2315, E2316 and E2317 in compiler/src, compiler/error_codes.md and trials finds nothing; they depend on the atomic builtins that do not exist.

### 84. Error E2318 (comparison operators on region, ref, buf or device_window types) is not emitted

- [ ] reviewed
- **Document:** compiler/design_documents/region_memory_safety_design.md, section 10 error table and section 14.1, about lines 726 and 806
- **Recorded as:** "Stays (comparison on region-kind types)"
- **Found:** grep for E2318 in compiler/src, the registry and trials finds nothing.

### 85. Error E2310 (cross-region reference, isolation) is not emitted or registered, and the isolation check of spec 12.4.1 is not enforced as the design describes

- [ ] reviewed
- **Document:** compiler/design_documents/region_memory_safety_design.md, section 10 and 14.1, about lines 718 and 802; compiler/design_documents/region_memory_safety_plan.md, stage 5 row, about line 27; compiler/design_documents/Phase1_TODOs/region_memory_safety_todo.md, section 2.3 and checklist, about lines 119 and 226
- **Recorded as:** "Stays (isolation)"; "Partial, type syntax is validated, but semantic checks are not enforced"
- **Found:** E2310 appears nowhere in compiler/src, compiler/error_codes.md, error_codes.jsonld or trials.

### 86. The region check is not on by default; E2300, E2301 and E2302 are errors only in a unit that declares strict region_check

- [ ] reviewed
- **Document:** compiler/design_documents/region_memory_safety_plan.md, stage 5 row, about line 27; compiler/design_documents/chunk15_stack_memory_plan.md, section 11.1 phase 6, about lines 23 and 56
- **Recorded as:** "region_check defaults to error"; "report-only unless the unit declares strict region_check"
- **Found:** region_checker_core.silica returns early unless the program declares strict region_check; nothing switches it on by default.

### 87. E2300 cases (b) and (c) (a reference into a shared atomic cell, an undescribed closure) are not built

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_design.md, section 6.4, about line 596; compiler/design_documents/chunk15_stack_memory_plan.md, phase 6, about line 56
- **Recorded as:** "E2300 (b)/(c) ... are later stages"
- **Found:** the header of region_checker_core.silica says only case (a), the retaining foreign parameter, is implemented; no code for (b) or (c).

### 88. E2242 (device_window single owner, moved twice) is not implemented and its trials are not written

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_design.md, sections 6.6 and 12 (P9), about lines 605 and 786; compiler/design_documents/chunk15_stack_memory_plan.md, section 11.3, about line 106; compiler/design_documents/data_structure_redesign_requirements.md, section 7.5 item 9, about line 264
- **Recorded as:** "Open: the device_window single-owner check code"; "E2242 ... are later stages"
- **Found:** E2242 appears only in a comment of region_checker_core.silica; no device_window_used_after_spawn_device or device_window_sent_twice trial exists.

### 89. E2321, the strict state_release error, is not emitted

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_design.md, section 12 (P3), about line 780; compiler/design_documents/chunk15_stack_memory_plan.md, section 11.1 phase 3 and 11.3, about lines 53 and 92; compiler/design_documents/data_structure_redesign_requirements.md, section 7.5 item 2, about line 257
- **Recorded as:** "E2321 in strict mode, spelled strict state_release; at module level"
- **Found:** the declaration strict state_release; parses (tag 10) but main_compile_pipeline.silica only mentions E2321 in a comment; no code emits it and no trial exists.

### 90. Warning W2300 is not registered in the error registry and has no trial

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_plan.md, sections 11.3 and 11.6, about lines 92 and 164
- **Recorded as:** "W2300, E2301, E2302, E2310, E2311, E2321, E2242 registered"
- **Found:** compiler/error_codes.md mentions W2300 only inside the E4037 text and error_codes.jsonld has no entry; trials/warning_enforcement_addition has no state_release trial.

### 91. The specification text for the new memory model (state area, lifetime-scoped regions, spawn copies state, messages copy, W2300) is not written, and the error registry rows for E2310, E2321, E2242 and W2300 are not added

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_plan.md, section 11.6, about lines 142 to 164; compiler/design_documents/region_memory_safety_plan.md, work item 17, about line 65; compiler/design_documents/data_structure_redesign_requirements.md, section 7.5 item 12, about line 267
- **Recorded as:** "partly done ... The specification has no state area or lifetime-scoped-region text yet"
- **Found:** grep of silica-specification.md for state area, lifetime-scoped and E2302 finds no such text; data_structure_designs still shows the r: region field (common_contract.md about line 150).

### 92. The scrub-on-free and zero-on-alloc requirement for runtime memory is not implemented and the before and after speed table is empty

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_design.md, section 2.8, about lines 179 to 220
- **Recorded as:** "requirement and measurement plan; not implemented, not measured"
- **Found:** git log since 2026-11-16 shows only the design commit cd085f7cc1 and a Nucleo benchmark app (35633ef039, not compiled or run); no scrub store was found in the runtimes.

### 93. The return-time copy-or-keep rule for a callee frame is not implemented and its threshold is not measured

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_design.md, section 3.3 and 3.4 amendments, about lines 290 and 310; compiler/design_documents/Phase3_memory_analysis.md, section 7, about line 128; compiler/design_documents/data_structure_redesign_requirements.md, section 7.5 item 3, about line 258
- **Recorded as:** "Amendment, 2026-10-28 (not yet implemented, not yet measured)"
- **Found:** grep of compiler/src for copy-or-keep or a keep threshold finds nothing.

### 94. call_with_timeout is not started, so the timed-out call and late reply trial is not written

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_design.md, section 5.3, about line 546; compiler/design_documents/region_memory_safety_design.md, section 18.6, about line 1128
- **Recorded as:** "call_with_timeout (chunk 11, not started)"; "not written; blocked on chunk 11"
- **Found:** call_with_timeout is absent from type_checker_builtin_signatures.silica and no trial uses it.

### 95. A returned closure that captures frame data is an open defect; KIND 9 CLOSURE in the copier is rejected at compile time until closure environments are described

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_design.md, sections 3.6 and 5.1, about lines 344 and 509
- **Recorded as:** "a returned closure that captures frame data is an open defect"
- **Found:** region_checker_core.silica says a lambda as a closure environment is a later stage (E2300 (c)); nothing describes closure environments.

### 96. The decision 40 trials (state_policy_keep_state_area_holds_pages, shrink and compact_on_request trials, compact_state_noop_under_keep, and the E2005 state_policy_missing trials) are not in the tree

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_plan.md, section 11.3, about lines 89 and 90
- **Recorded as:** "Trials to add (named; one per rule)"
- **Found:** no file named state_policy_* exists under trials/; only stack_policy_missing_in_spawn and the stack_keep_*_unproven_state_survives trials exist.

### 97. The compiler-proven release trials (proven_release_flat_memory, evacuation_fills_exact_holes, fallback_copy_compacts_holes, and the warning_enforcement state_release_* trials) are not in the tree

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_plan.md, section 11.3, about lines 91 to 97
- **Recorded as:** "Trials to add (named; one per rule)"
- **Found:** none of those names exists under trials/; warning_enforcement_addition holds only dangerous_legacy_stub and device_w1c_read_modify_write.

### 98. The mailbox, reply, forward and spawn trials of decisions 11, 15, 31, 32 and 33 are not in the tree (crashed_actor_queued_message_buffers_released, forwarded_message_not_copied, reply_in_caller_stack_pops_with_frame, reply_too_large_for_lowered_reservation, spawn_state_in_child_base, supervised_child_restarts_with_version)

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_plan.md, section 11.3, about lines 98 to 102; compiler/design_documents/region_memory_safety_design.md, section 18.6, about lines 1122 to 1129
- **Recorded as:** "Trials to add"; "not written (§18.7)"
- **Found:** none of these names exists under trials/; the section 18.6 rows (message_part_kept_evacuated_to_stack_base, crashed_actor_queued_message_regions_released, send_to_dead_actor_releases_region, caller_dies_reply_region_dropped) are likewise absent.

### 99. The ref-cell error trials of decision 35 (write_ref_fresh_into_state_cell, write_ref_fresh_into_param_cell, write_ref_old_into_state_cell) and any E2302 error trial are not written

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_plan.md, section 11.3, about line 104; compiler/design_documents/region_memory_safety_design.md, section 14.1, about line 800
- **Recorded as:** "Trials to add"
- **Found:** no golden_fail in trials/ carries E2302; region_hazards_open_addition/write_ref_young_into_older_cell is a run trial, not an error trial.

### 100. The error trial catalogue of section 14.1 and the send_then_use_* catalogue of section 18.6 are largely not written

- [ ] reviewed
- **Document:** compiler/design_documents/region_memory_safety_plan.md, work item 13, about line 61; compiler/design_documents/region_memory_safety_design.md, sections 14.1 and 18.6, about lines 796 to 806 and 1112
- **Recorded as:** "E2301 (no use after an explicit move send, §18.1, not written ...)"
- **Found:** only region_use_after_move_trial (E2301), lifetime_conflict_at_call (E2311), the E2300 retaining-wrapper trial and an E2313 trial exist.

### 101. The change-result trials (no_op_change_returns_unchanged, change_result_variants, no_op_change_on_moved_version) are not written under those names

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_plan.md, section 11.3, about line 109; compiler/design_documents/region_memory_safety_design.md, section 14.2, about line 822
- **Recorded as:** "no_op_change_returns_unchanged ... change_result_variants"
- **Found:** no trial by those names exists under trials/ordered_data_structures or elsewhere.

### 102. The board trial state_chain_1000_actors does not exist

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_plan.md, section 11.1 phase 9 and 11.3, about lines 26 and 113
- **Recorded as:** "Caveat: the state_chain_1000_actors trial of §11.3 does not exist in the tree"
- **Found:** stack_budget_board_addition/thousand_actors_at_rest.silica exists and stands in for it; the named trial is still absent.

### 103. The run trials region_released_in_calling_scope, region_second_param_released, region_in_record_released, crashed_actor_regions_released, region_param_sent_by_cast_not_freed, region_spawn_state_param_not_freed, region_moved_between_actors and device_window_moved_once are not in the tree under those names

- [ ] reviewed
- **Document:** compiler/design_documents/region_memory_safety_design.md, section 14.2, about lines 811 to 824
- **Recorded as:** "leaks today" and the trial table of section 14.2
- **Found:** no file with those names exists; several are moot after chunk 15 (owner lists and drop_owned dropped), so which are still wanted is Lee's call.

### 104. Non-literal buffer sizes and indexes are still checked only at run time, not against N

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/region_memory_safety_todo.md, section 2.2, about line 113
- **Recorded as:** "Not done: the check uses the run-time count, not the N of buf(R, Space, T, N)"
- **Found:** E2313 and E2314 check literals only; the run-time check uses the stored count.

### 105. The checklist items "no program can return a reference whose region does not outlive the call", "no program can use a reference after its region is deallocated" and "cross-module region usage is validated" are unchecked

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/region_memory_safety_todo.md, section 4 checklist, about lines 223, 224 and 227
- **Recorded as:** "[ ] No program can return a reference whose region does not outlive the call"
- **Found:** the lifetime checks (E2300 case a, E2302, E2311) cover only part of this and only under strict region_check; no cross-module region check was found.

### 106. Hosted emitters ignore the memory space operand of alloc_region and there are no per-space pools or runtime space tag

- [ ] reviewed
- **Document:** compiler/design_documents/memory-effects-aarch64-implementation-plan.md, status table, Phase 0.2 and Phase 1, about lines 16 and 88
- **Recorded as:** "NOT done: the emitters ignore the space operand"
- **Found:** prims_memory.silica of the Mac emitter still says "X1 = space (unused)"; the boards only refuse unprovided spaces at assembly.

### 107. Atomic ref loads and stores on the AArch64 hosted targets are plain loads and stores, not LDAR and STLR

- [ ] reviewed
- **Document:** compiler/design_documents/memory-effects-aarch64-implementation-plan.md, status table and Phase 2.1, about lines 17 and 112
- **Recorded as:** "NOT done: ref and buffer accesses are plain loads and stores for every space"
- **Found:** no ldar or stlr in the Mac or Linux AArch64 prims_memory.silica; the board emitters add memw or dmb sy only.

### 108. Phase 1 AArch64 OS-free pools and MAIR_EL1 programming, and the ESP32-S3 per-space pools and cache modes, are not built

- [ ] reviewed
- **Document:** compiler/design_documents/memory-effects-aarch64-implementation-plan.md, status table and Phase 1, about lines 18, 19 and 88
- **Recorded as:** "NOT done; no AArch64 bare-metal target exists"; "Per-space pools and cache modes are NOT implemented"
- **Found:** no bare-metal AArch64 emitter exists and the ESP32-S3 emitter has a single internal SRAM heap and no pools.

### 109. Phase 4 verification of what the runtime does per space (cacheability, DMA round trip, SPIRAM, dual-core atomic and litmus tests, a board by space matrix) is not done

- [ ] reviewed
- **Document:** compiler/design_documents/memory-effects-aarch64-implementation-plan.md, Phase 4 and Phase 5 note, about lines 134 and 147
- **Recorded as:** "the row stays open because Phase 4's verification ... is not done"
- **Found:** the memory_space_*_addition suites test function and refusal only; no attribute or DMA tests exist.

### 110. The NUCLEO-L476RG board README has no memory space table

- [ ] reviewed
- **Document:** compiler/design_documents/memory-effects-aarch64-implementation-plan.md, Phase 5, about line 147
- **Recorded as:** "The STM32L476 board has no README table yet"
- **Found:** compiler/src/emitter/STM32-L476RG_raw/board/README.md has no memory space section, though trials/memory_space_nucleo_addition/README.md cites one.

### 111. Splitting the compiler into more granular actors (phase actors) is not done

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_memory_analysis.md, section 7, about line 126
- **Recorded as:** "Direction: split the compiler into more granular actors"
- **Found:** main.silica still runs a unit in one pipeline actor; parse_in_actor.silica is no longer in compiler/src.

### 112. The footprint comparison of 999939 against stage 1 over time is not written up, and the general mid-dispatch stack trim after any evacuation (and the proven path trim trial) is not done

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_memory_analysis.md, sections 4 and 8, about lines 95 and 146
- **Recorded as:** "Still open: the 999939-versus-stage-1 over-time comparison below is not written up"; "a general in-dispatch trim after any evacuation is not done"
- **Found:** benchmarking/memory_use_reports/data holds per-unit tsv files but no over-time comparison; only silica_rt_stack_trim_scratch after the state copy exists.

### 113. Known residuals of the chunk 15 Linux port (raw_alloc has no callers, comments still name deleted modules) are not fixed

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_plan.md, Phase 8 notes, about line 38
- **Recorded as:** "Known residuals, mirrored from the Mac and not fixed"
- **Found:** not re-checked in code today; recorded as left open by the document.

## Actors (31)

### 114. The runtime has no monitor or link table, and `link`, `monitor` and `demonitor` are still stubs

- [ ] reviewed
- **Document:** compiler/design_documents/Phase2_TODO/actor_monitor_demonitor_todo.md, Implementation status and Required Runtime Behavior, about line 13
- **Recorded as:** "`link`, `monitor` and `demonitor` are still benign stubs in every runtime"
- **Found:** The Apple, Linux and ESP32-S3 runtimes still return immediately in `silica_rt_actor_monitor` and the demonitor and link entries, and no commit mentions monitor work.

### 115. Real monitor state, DOWN delivery with `:noproc`, demonitor cancellation and the trials for them do not exist

- [ ] reviewed
- **Document:** compiler/design_documents/Phase2_TODO/actor_monitor_demonitor_todo.md, Completion Criteria, about line 48
- **Recorded as:** "Runtime monitor tables exist and are cleaned up on actor exit" (criteria not met)
- **Found:** No runtime keeps a monitor table and no trial under trials/ calls monitor or demonitor.

### 116. Protocol-typed actor references, protocol expressions, capability splitting and consumption tracking are not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica_actor_capabilities_specification.md, header Implementation status, about line 5
- **Recorded as:** "Not implemented, and still a draft."
- **Found:** No `actor_ref cast with` form appears in compiler/src and no trial uses one.

### 117. The diagnostics E3500 to E3506 for protocol violations are not allocated

- [ ] reviewed
- **Document:** compiler/design_documents/silica_actor_capabilities_specification.md, header Implementation status and section 13, about line 5
- **Recorded as:** "the E3500 to E3506 diagnostics of section 13 are not allocated in error_codes.md"
- **Found:** grep finds no E3500 or E3501 in compiler/src, error_codes.md or the error_enforcement trials.

### 118. The marker file INTEGRATE_PENDING still makes integrate skip trials/cpu_discovery_and_spawn_pinning (remove it or keep it)

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/cpu_topology_implementation_plan.md, Phase H Verification, about line 176
- **Recorded as:** "still open: `trials/cpu_discovery_and_spawn_pinning/INTEGRATE_PENDING` is still present ... (decision with Lee)"
- **Found:** The file is still in the directory, although the trials have real goldens and ran 14/14 on the Mac, pix and nix on 2026-10-21. Only Lee can decide.

### 119. `core_info.frequency_mhz` is still always 0 because no IOKit or other non-sysctl source is implemented

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/cpu_topology_implementation_plan.md, Current State remaining gaps and Phase G follow-up, about line 39
- **Recorded as:** "`core_info.frequency_mhz` from a non-sysctl source (e.g. IOKit) is not implemented"
- **Found:** The Apple runtime sets frequency_mhz to 0 on success and the ESP32-S3 runtime reports 0 as well. No IOKit code exists.

### 120. Phase H still checks only the Apple runtime source statically, with no static check for the other targets

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/cpu_topology_implementation_plan.md, Implementation status banner (Phase H), about line 22
- **Recorded as:** "`phase_h_static.sh` still checks only the Apple runtime source."
- **Found:** I did not find a change to phase_h_static.sh, and git log shows no later commit to it.

### 121. A trial that holds more than 1,000 idle actors (the "million idle actors" gate trial) does not exist

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/actor_stack_growth_plan.md, Gate and Status of the gate, about line 156; compiler/design_documents/actor_memory_budget_plan.md, sections 15 and 18, about lines 2002 and 2102; compiler/design_documents/actor_growable_stack_design.md, Implementation status, about line 33
- **Recorded as:** "Open: the 'million idle actors' trial" and "no trial holds more than 1,000 actors"
- **Found:** Carriers exist and the Mac was measured up to 1,000,000 actors, but the largest trial is stack_many_idle_actors_hold_nothing at 1,000 actors.

### 122. Whether the runtime checks or documents `vm.max_map_count` at start, and what a target without demand paging does, is undecided

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/actor_stack_growth_plan.md, Still to decide, about line 138; compiler/design_documents/actor_memory_budget_plan.md, section 15 item 2 and section 18, about lines 2007 and 2102
- **Recorded as:** "Awaiting discussion" and "still undecided"
- **Found:** grep finds no max_map_count in compiler/src, the stdlib or the trials.

### 123. Linux idle-actor counts, the zero-committed-stack probe and the mapping count recorded against `vm.max_map_count` are not measured

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, section 18 and Remaining gaps item 6, about lines 1491 and 2102
- **Recorded as:** "Linux idle-actor capacity, `get_actor_memory_usage` and x86-64 timing are unmeasured (held)."
- **Found:** Section 16 has only Mac figures, and the record says the zero-committed-stack figure was inferred from RSS and not probed.

### 124. Lazy page migration and NUMA-node-local commitment are not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/actor_growable_stack_plan.md, Phase 2 and Phase 3, about lines 35 and 53; compiler/design_documents/actor_growable_stack_design.md, Implementation status, about line 33; compiler/design_documents/Phase1_TODOs/actor_stack_growth_plan.md, Work item 7, about line 78
- **Recorded as:** "Not implemented: it applies only where the platform reports NUMA nodes"
- **Found:** Only `migrate_actor` exists and it moves execution, not pages. The Mac and the Pi report no NUMA nodes, so nothing was built.

### 125. Proactive growth hints (`hint_stack_usage`) are not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/actor_growable_stack_design.md, Implementation status and section 13.2, about lines 33 and 1936
- **Recorded as:** "the proactive growth hints of 13.2" under "Not implemented"
- **Found:** grep finds no hint_stack_usage in compiler/src.

### 126. Acquire mode 2 (row-child drain protection under a carrier-style supervisor) is not on the ESP32-S3 board

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, Remaining gaps item 3, about line 1451
- **Recorded as:** "Board gap (open)."
- **Found:** The board has no restart token and drains in the caller's context, and ROADMAP lists it as the open design question.

### 127. There is no ESP32-S3 board trial for the gap 3 row-asks pieces (a row asking its own supervisor to terminate or restart itself)

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, Remaining gaps item 3, about line 1459
- **Recorded as:** "Still open: ... a dedicated board trial for this row."
- **Found:** carriers_addition/workers_zzzgap_row_asks_* have goldens only for hosted and the Nucleo.

### 128. Board results with the current ESP32-S3 compiler (silica-999953) are unknown

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, Remaining gaps item 3 update, about line 1460
- **Recorded as:** "the board results with it are unknown"
- **Found:** Commit c063517bd9 says its board runs were stopped part way and its board goldens were not regenerated from a completed run.

### 129. The pooled FFI worker thread (option A) is deferred, so a dangerous actor is still one OS thread

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, Remaining gaps item 2, about line 1445
- **Recorded as:** "Option A, a pooled FFI worker, is deferred"
- **Found:** Only option C (thread cap, ffafc09791) is built, and the five option A trials are only named, not written.

### 130. The 1,000-actor board target's free-heap figure of at least 100 KB has not been re-measured since the ACB grew to 144 B and chunk 15 landed

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, section 13 Gate (board) F + I + J, about line 1932
- **Recorded as:** "Still open: the >=100 KB free-heap figure is not recorded"
- **Found:** Only the 2026-10-09 measurement (162,584 B free with the 128 B ACB) exists.

### 131. The chunk 15 trial `state_chain_1000_actors` does not exist

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, section 13 Gate (board), about line 1932
- **Recorded as:** "the chunk 15 design's `state_chain_1000_actors` trial does not exist in the tree"
- **Found:** grep over trials/ finds no such name.

### 132. Whether `INGRESS_LIMIT` (1024) holds under a mass child failure was never revisited

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, item J, about line 427
- **Recorded as:** "`INGRESS_LIMIT` (1024) was not revisited."
- **Found:** Checked by grep only; no later note or trial about it. It is also recorded in runtime_failure_reporting.md section 4 as a full ingress that is not reachable in practice.

### 133. The update of plan text for chunk 15 is partly done, and the item B, F and I text and the Part I and III figures still describe the old heap design

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, Update 2026-11-14 banner, about line 20
- **Recorded as:** "the 'update plan text for chunk 15' item is partly done"
- **Found:** The banner and a few notes were updated, but the §14 and §16 figures and the item F text still use the ACB, arena and heap numbers of the old design.

### 134. Linux x86-64 `spawn_linked` calls `silica_rt_beh_convention` with the stack 8 bytes off 16-byte alignment (latent, unfixed)

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, Remaining gaps item 10, about line 1503
- **Recorded as:** "Latent and deliberately unfixed"
- **Found:** Read from source only; no later commit addresses it.

### 135. E2094 and E2095 (a `:dangerous` row must be cast-type and carry a `:dangerous_` id) are enforced only for a module's `init`, not for child supervisors' start functions

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, Remaining gaps item 9, about line 1500
- **Recorded as:** "Checker gap, to be filed and not fixed"
- **Found:** No later commit or trial mentions it.

### 136. Stale `__silica_runtime.*.ascomp` goldens are never compared by the harness

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, Remaining gaps item 7, about line 1493
- **Recorded as:** "Stale `__silica_runtime.*.ascomp` goldens (the harness never compares them)."
- **Found:** The files are still in each suite directory.

### 137. About 30 trial comments still mention `SILICA_CARRIERS=0`

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, Remaining gaps item 8, about line 1494
- **Recorded as:** "left as history"
- **Found:** Not re-counted; the document records it as deliberate.

### 138. The `shutdown` time limit of a supervisor child is not enforced on any target

- [ ] reviewed
- **Document:** compiler/design_documents/runtime_failure_reporting.md, section 6 Limits, about line 350
- **Recorded as:** "The `shutdown` time limit is not enforced on any target, because nothing preempts a running message."
- **Found:** No later commit or trial enforces it.

### 139. A fault inside the handler on a thread created by foreign code, and an exhausted 64 KB alternate stack, still end with status 139

- [ ] reviewed
- **Document:** compiler/design_documents/runtime_failure_reporting.md, section 6 Limits, about line 330
- **Recorded as:** "a fault inside the handler on such a thread still ends with status 139"
- **Found:** This is a stated limit with no later change to the handler.

### 140. Two threads failing together can interleave their report lines, and Linux reports lack symbols until the emitters write `.size`

- [ ] reviewed
- **Document:** compiler/design_documents/runtime_failure_reporting.md, section 6 Limits, about line 334
- **Recorded as:** "can interleave their lines" and "the symbol is missing from most reports until the emitters write `.size`"
- **Found:** No later commit addresses either.

### 141. Allocator failures, a full supervision ingress and the stack-commit refusal are not reachable from Silica source and have no trial

- [ ] reviewed
- **Document:** compiler/design_documents/runtime_failure_reporting.md, section 4, about line 287
- **Recorded as:** "Not reachable in practice"
- **Found:** No trial exercises them.

### 142. The fatal report on the board still has no actor fields

- [ ] reviewed
- **Document:** compiler/design_documents/runtime_failure_reporting.md, section 6 Limits, about line 339
- **Recorded as:** "The fatal report still has no actor fields."
- **Found:** No change found in rt_console.S history.

### 143. No `ForeignFault` result type and no isolated helper-process mode exist for guarded foreign calls

- [ ] reviewed
- **Document:** compiler/design_documents/macos_crash_handling_for_silica.md, Implementation status, about line 15
- **Recorded as:** "no `ForeignFault` result type or isolated helper-process mode exists"
- **Found:** grep of compiler/src and the stdlib finds neither; Mach exception ports are also still not used.

### 144. Other OSes (FreeBSD, Solaris and illumos, Windows) have no affinity backend

- [ ] reviewed
- **Document:** compiler/design_documents/actor_spawn_core_affinity_os_semantics.md, Implementation status, about line 17
- **Recorded as:** "No backend exists; the sections for them are reference material for a future port."
- **Found:** No emitter target exists for them.

## Data structures (27)

### 145. The BinaryTree substrate delta has no StubBinaryTree and none of the compiler_substrate binary_tree_* trials

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_implementation_plan.md, 7.10 BinaryTree family registration delta, about line 518; compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/requirements_to_trials_ledger.md, closing Open items line, about line 481; compiler/design_documents/Phase1_TODOs/data_structure_designs/binary_tree_trait.md, Implementation status, about line 3
- **Recorded as:** Partially met; the remainder is not scheduled
- **Found:** grep finds StubBinaryTree only in the documents, and trials/ordered_data_structures/compiler_substrate has no binary_tree_* trial.

### 146. The five trial_compile_fail_binary_tree_* constructor-record compile-fail trials are not written

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_implementation_plan.md, 7.10 and 37, about lines 518 and 2166; compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/requirements_to_trials_ledger.md, Open items, about line 481; compiler/design_documents/Phase1_TODOs/data_structure_designs/binary_tree_trait.md, about line 3
- **Recorded as:** not written
- **Found:** trials/error_enforcement_addition/standard_data_structures has 18 compile-fail trials and none is for BinaryTree.

### 147. The dated ledger record reaffirming the deferral of WBT join, split and concat is still owed

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_implementation_plan.md, 14, about line 1516 and item 9 near line 2184; compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/requirements_to_trials_ledger.md, row 13 and Open items, about lines 90 and 481
- **Recorded as:** the dated ledger record is still owed
- **Found:** wbt_set.silica and wbt_map.silica export no join, concat or split, but row 13 of the ledger still reads as deferred without the dated reaffirmation.

### 148. The cross_representation three-way conformance leaf is not landed

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_implementation_plan.md, 32 to 36 status, about line 2164 and 37, about line 2166
- **Recorded as:** Not landed: the cross_representation/ three-way conformance leaf
- **Found:** trials/ordered_data_structures/cross_representation holds only a README and build scaffolding; the same comparison is made inside gd_equivalence and gcsr_equivalence_large.

### 149. BinaryTree complexity counters and the binary_tree_complexity_observations trial are not landed

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_implementation_plan.md, 32 to 36 status, about line 2164; compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/requirements_to_trials_ledger.md, BinaryTree rows 16 and 17, about lines 117 and 424
- **Recorded as:** binary_tree_complexity_observations was not landed
- **Found:** No such trial exists in binary_tree_core.

### 150. No negative suite exists for heap orientation mismatch, malformed CSR offsets or dense-capacity overflow

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_implementation_plan.md, 32 to 36 status, about line 2164
- **Recorded as:** Not landed: ... a negative suite for heap orientation mismatch, malformed CSR offsets and dense-capacity overflow
- **Found:** No trial of those names or shapes exists under trials/ordered_data_structures or trials/error_enforcement_addition.

### 151. The CSR freeze overflow trial csr_freeze_overflow_fail and a dense V-squared overflow trial are not landed

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/requirements_to_trials_ledger.md, CSR snapshot row 9, about line 198; compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/csr_dense_representation_contract.md, coverage lines, about lines 53 and 84
- **Recorded as:** overflow failure path not reachable in a trial (planned csr_freeze_overflow_fail); A V-squared overflow trial was not landed
- **Found:** No such trial exists in graph_csr_core or graph_dense_core.

### 152. The terminal_structures, live_graphs and cross_representation leaves contain only smoke_harness_ready, and snapshot_graphs only a README

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_implementation_plan.md, 37, about line 2166
- **Recorded as:** Open. Phase 1 is not declared complete
- **Found:** The directories exist with build scaffolding and one smoke_harness_ready marker (README only for snapshot_graphs and cross_representation); no real trial programs are in them.

### 153. The ledger still has planned rows, so Phase 1 is not declared complete

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_implementation_plan.md, 37, about line 2166; compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/requirements_to_trials_ledger.md, status header, about line 4
- **Recorded as:** the ledger still has planned rows
- **Found:** The ledger header names rows marked was not landed and one planned csr_freeze_overflow_fail; those are the items listed separately here.

### 154. Constructor-record compile-fail trials for the graph, Heap, PriorityQueue and Tree families are not landed

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/requirements_to_trials_ledger.md, rows at about lines 284, 324, 325, 345, 364, 385 and Open items, about line 481
- **Recorded as:** was not landed; no error_enforcement trial exists for this family
- **Found:** The compile-fail constructor trials all use StubWbtSet; no stub or trial exists for the directed, weighted, Heap, PriorityQueue or Tree constructors.

### 155. The neighbors_fold_no_temp trial in live_graphs is not landed

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/requirements_to_trials_ledger.md, materialization row 11, about line 69
- **Recorded as:** neighbors_fold_no_temp was not landed
- **Found:** live_graphs holds only smoke_harness_ready; gl_directed_folds_reachable covers part of the intent.

### 156. The BinaryTree randomized-oracle trial is not landed

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/requirements_to_trials_ledger.md, Open items, about line 481; compiler/design_documents/Phase1_TODOs/data_structure_designs/binary_tree_trait.md, about line 3; compiler/design_documents/Phase1_TODOs/standard_data_structures_implementation_plan.md, 17 and 20 status
- **Recorded as:** Not landed: ... the randomized-oracle and complexity trials
- **Found:** binary_tree_core has 13 programs and none is an oracle comparison.

### 157. Several named BinaryTree trials are not landed: binary_tree_inline_recursive_shape, the count_overflow error trial, binary_tree_inline_surface_compile, binary_tree_failure_matrix and binary_tree_string_example

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/requirements_to_trials_ledger.md, BinaryTree rows at about lines 104, 106, 410, 421 and 425
- **Recorded as:** was not landed / not landed
- **Found:** None of these names exist under trials/ordered_data_structures/binary_tree_core.

### 158. The graph_layout_not_in_source compile-fail trial for CSR-D1 is not landed

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/requirements_to_trials_ledger.md, CSR-D1 row, about line 437
- **Recorded as:** the compile-fail graph_layout_not_in_source was not landed
- **Found:** No such trial exists.

### 159. The tree_string_example trial is not landed

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_baseline/requirements_to_trials_ledger.md, Tree row 16, about line 399
- **Recorded as:** tree_string_example was not landed
- **Found:** tree_collections has rt_generic_payloads only.

### 160. Materialized map, filter and reduce over List are not built (TODO 1, including its empty-input trials)

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/list_map_filter_reduce_and_hardening_todo.md, TODO 1, about line 31 and Implementation status, about line 9; compiler/design_documents/list_implementation_design.md, Implementation status Not implemented bullet, about line 34
- **Recorded as:** TODO 1 (map, filter, reduce): not done
- **Found:** No such builtin in the type checker signature table, and no map, filter or reduce trial in trials/list_addition.

### 161. Explicit negative trials for unsupported or non-Collectable list element shapes are missing (TODO 2)

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/list_map_filter_reduce_and_hardening_todo.md, TODO 2, about line 55 and status, about line 10
- **Recorded as:** Negative trials for unsupported element shapes were not found
- **Found:** Positive record and tuple element trials exist in trials/list_addition; no compile-fail trial for an element shape was found there.

### 162. The closing spec-alignment audit of lists, diagnostic cleanup and the primary-cursor audit are not done (TODO 3)

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/list_map_filter_reduce_and_hardening_todo.md, TODO 3, about line 70 and status, about line 11
- **Recorded as:** not done as a closing audit
- **Found:** The implementation differences are recorded in list_implementation_design.md but no closing audit is recorded.

### 163. Chunk SIMD slab size is not wired from the target into codegen (item 1)

- [ ] reviewed
- **Document:** compiler/design_documents/list_chunk_vector_alignment_todo.md, TODO items item 1, about line 29; compiler/design_documents/list_implementation_design.md, 4.5, about line 102
- **Recorded as:** still open, nothing in the list below has been done
- **Found:** chunk_data_bytes in each emitter's prims_list.silica is still max(16, elem_slot_bytes) with a literal 16 floor.

### 164. The allocator alignment contract for list chunks is not written or enforced (item 2)

- [ ] reviewed
- **Document:** compiler/design_documents/list_chunk_vector_alignment_todo.md, item 2, about line 31
- **Recorded as:** still open
- **Found:** No vector-width alignment requirement appears in the emitters or in section 4.5 of the list design.

### 165. SIMD fast paths for list chunk loads and stores are not built (item 3)

- [ ] reviewed
- **Document:** compiler/design_documents/list_chunk_vector_alignment_todo.md, item 3, about line 33
- **Recorded as:** still open
- **Found:** List codegen is scalar loads and stores in the emitters.

### 166. Cross-backend reconciliation of SVE or other variable-width vectors with the fixed CDATA is not done (item 4)

- [ ] reviewed
- **Document:** compiler/design_documents/list_chunk_vector_alignment_todo.md, item 4, about line 35
- **Recorded as:** still open
- **Found:** No SVE or target feature plumbing exists; CDATA is one constant.

### 167. Trial inventory and document-history sync for per-target slab sizes is not done (item 5)

- [ ] reviewed
- **Document:** compiler/design_documents/list_chunk_vector_alignment_todo.md, item 5, about line 37
- **Recorded as:** still open
- **Found:** CDATA has not diverged per target, so there is nothing yet to sync; the item depends on items 1 to 3.

### 168. Actor-wrapped data structures (Extension 1) are not started

- [ ] reviewed
- **Document:** compiler/design_documents/Phase2_TODO/stateful_and_sharded_data_structures.md, Extension 1, about line 54 and status, about line 5
- **Recorded as:** not started
- **Found:** No actor wrapper for any collection exists in compiler/stdlib or examples.

### 169. The five open questions on actor-wrapped structures (families covered, call and cast variants, reply types, restart, snapshot message) are undecided

- [ ] reviewed
- **Document:** compiler/design_documents/Phase2_TODO/stateful_and_sharded_data_structures.md, Open Questions, about line 157
- **Recorded as:** Open Questions
- **Found:** No decision for any of them is recorded in the document or in commit messages.

### 170. Sharded actor-backed data structures (Extension 2), the shard function and the Phase 2 experiments are not started, and the graph sharding policies are open

- [ ] reviewed
- **Document:** compiler/design_documents/Phase2_TODO/stateful_and_sharded_data_structures.md, Extension 2, about line 168, Open graph sharding policies, about line 270, and Suggested Phase 2 Experiments, about line 325
- **Recorded as:** not started; Open graph sharding policies
- **Found:** No hash_key or shard code exists in compiler/stdlib or examples.

### 171. The exact generated helper syntax for actor wrappers is open

- [ ] reviewed
- **Document:** compiler/design_documents/Phase2_TODO/stateful_and_sharded_data_structures.md, Constructor Sketch, about line 132
- **Recorded as:** The exact generated helper syntax is open
- **Found:** No wrapper generator exists.

## Boards and ports (53)

### 172. I2C0 `:timeout` outcome has not been provoked on the board

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, Item G not completed table, about line 291
- **Recorded as:** "not provoked, not completed"
- **Found:** Logged by Lee on 2026-11-16; silica_36 and silica_37 cover only :nack and :stuck, and the README says the other two are NOT completed.

### 173. I2C0 `:arbitration_lost` outcome has not been provoked on the board

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, Item G not completed table, about line 292
- **Recorded as:** "not provoked, not completed"
- **Found:** Same as :timeout; no app or board record provokes it.

### 174. Minibadge I2C and its GPIO lines are not done

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, Item G status 2026-11-16 (about line 284) and section 4.2 (line 106)
- **Recorded as:** "Not done: the minibadge I2C and its GPIO lines"
- **Found:** No minibadge app exists under board/apps; silica_34 to silica_37 use only the on-board accelerometer.

### 175. A bus worker that serves several I2C devices is not built

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, Item G status 2026-11-16, about line 284
- **Recorded as:** "a bus worker that serves several devices" listed as not done
- **Found:** Only device_mma8452q over device_esp32s3_i2c0 exists.

### 176. The minibadge pin assignment disagrees between the board sheet and the silkscreen and is not settled from the netlist

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, section 6 Open questions, about line 311 (also section 4.2 Cautions)
- **Recorded as:** "Minibadge pin assignment (board sheet versus silkscreen); settle from the netlist."
- **Found:** No document records the settlement.

### 177. Whether USB power-role switching (pd_switch / dm_pd_switch) needs GPIO control for USB OTG host mode is open

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, section 4.1 (about line 103) and section 6 (about line 312)
- **Recorded as:** "Still open for USB OTG host mode (item L)"
- **Found:** Device mode enumerated without it (2026-10-30); item L has no code.

### 178. Item A: the SPI2 base is still TRM-unconfirmed and the display app's board result is not recorded

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, Implementation status table row A, about line 25; gate A about line 398
- **Recorded as:** "marked TRM-unconfirmed ... the board result of the app is not recorded in board/README.md"
- **Found:** board_pack.silica window_base_verified still returns false for window 9; the README lists only the expected output for silica_18.

### 179. Item D: the Point button's change was never observed on the board

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, table row D, about line 28; gate D about line 401
- **Recorded as:** "Point never logged a change ... open"
- **Found:** No later run is recorded.

### 180. Item D: the silica_24 colours were not visually recorded

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, table row D, about line 28
- **Recorded as:** "visual not recorded"
- **Found:** No later record found.

### 181. Bases of SPI2, RMT, LEDC, I2C0, SPI3 and USB are not confirmed against the TRM

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, section 6, about line 320
- **Recorded as:** "to be confirmed against the TRM"
- **Found:** window_base_verified is false for windows 9 to 13; the plan says I2C0 is confirmed only by the part answering WHO_AM_I.

### 182. The generator covers only some chip windows; RTC_CNTL, TIMG0/1, SYSTIMER, SPI3, GDMA and USB OTG have no generated descriptions

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, table row B, about line 26, and section 2 first row
- **Recorded as:** "Not done for the other chip windows"
- **Found:** gen_board_pack.py and board/pack/ were checked; pack_descriptions.silica lists no such tags.

### 183. Interrupt runtime per spec section 9 is not implemented (item K)

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, section 2 Interrupts row (about line 65), item K (line 300), section 6 (line 319)
- **Recorded as:** "not implemented"
- **Found:** rt_start.S and rt_vectors.S keep interrupts off (INTENABLE 0); no handler or IRQ-to-worker code found.

### 184. DMA per spec 5.3 (GDMA window, buffer move and return) is not implemented (item H)

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, section 2 DMA row (about line 66) and item H (line 297)
- **Recorded as:** "Not implemented"
- **Found:** No GDMA window in board_pack.silica and no DMA code in the board tree.

### 185. Item I: SD block access on SPI3 is not built

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, item I, about line 298; gate I about line 404
- **Recorded as:** table lists it with no status; summary says G to M, O to R not started
- **Found:** No SPI3 window or SD driver in board/apps/device_lib or board_pack.silica.

### 186. Item J: filesystem layer and file_io backend for the ESP32-S3 is not built, and the filesystem choice is unsettled

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, item J (line 299), section 4.3, section 6 (about line 323)
- **Recorded as:** "The choice is open"
- **Found:** The emitter still refuses file io with an .error line (terms/file_io_inline.silica).

### 187. Item L: USB OTG device/host stack is not built

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, item L, about line 301; gate L about line 406
- **Recorded as:** not started
- **Found:** No USB OTG window or stack found.

### 188. Item M: the radio work (stages 3 to 9 of the Wi-Fi plan) is deferred and has no code

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, item M, about line 302; section 4.4 and section 6 (about line 325)
- **Recorded as:** "deferred, not cancelled ... no radio code exists"
- **Found:** Decision of 2026-11-09 recorded; no radio code in the tree.

### 189. Item N: the SLIP/PPP link worker is not started, and the gate (frame through the UART1 link and reply returns) is unmet

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, item N, about line 303 and table row N about line 31; gate N about line 407
- **Recorded as:** "the SLIP/PPP link worker of this item is not started"
- **Found:** Only the (:uart1) carrier, TX direction, exists. Also open: SLIP or PPP choice, section 6 about line 334.

### 190. Item O: Silica network stack core (IPv4, ARP, ICMP, DHCP, DNS, UDP endpoint actors) is not built

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, item O, about line 304; gate O about line 408
- **Recorded as:** not started
- **Found:** No such stdlib or board modules found.

### 191. Item P: TCP demultiplexer, connection and listener actors, credit-based flow control is not built; timer source and buffer budget per connection undecided

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, item P (line 305), section 6 (about lines 328 and 332), gate P (line 409)
- **Recorded as:** not started
- **Found:** No TCP code found.

### 192. Item Q: USB CDC-NCM link worker and DHCP over it is not built

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, item Q, about line 306; gate Q about line 410
- **Recorded as:** not started
- **Found:** Depends on item L, which has no code.

### 193. Item R: SPI Ethernet add-on link worker (optional) is not built

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, item R, about line 307; gate R about line 411
- **Recorded as:** not started
- **Found:** No code found.

### 194. Whether hosted targets adopt the Silica network library or stay on Fifi is undecided

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, section 6, about line 330
- **Recorded as:** "a roadmap decision"
- **Found:** No decision recorded in a document or commit that I found.

### 195. The ESP32-S3 device apps silica_16 to silica_28 still use the pre-chunk-15 spawn form and fail E2005

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_port_status.md, section 4.2, about line 124; also compiler/src/emitter/ESP32-S3_raw/board/README.md, Known issues, about line 474
- **Recorded as:** "still use the pre-chunk-15 three-argument spawn and fail E2005"
- **Found:** silica_16 source still has spawn with stack_policy only, no state_policy argument; silica_31, 34 and later have it.

### 196. Peek and poke are 32-bit only on the ESP32-S3 board

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_port_status.md, section 3 and section 4.2, about line 125
- **Recorded as:** "32-bit only on this board"
- **Found:** prims_device.silica still refuses other widths.

### 197. Device interrupts and DMA are not implemented (same item as peripherals plan K and H)

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_port_status.md, section 4.2, about line 126
- **Recorded as:** "not implemented"
- **Found:** See the peripherals plan blocks.

### 198. The ESP32-S3 diagnostic channel is narrow: other refusals are still .error lines at assembly

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_port_status.md, section 4.2, about line 127; compiler/design_documents/ports/esp32s3_peek_poke_implementation_plan.md, Still to decide, about line 378
- **Recorded as:** "deferred" / "narrow now, wide later"
- **Found:** emitter_core.silica still emits .error lines for file io and frame size; marked as to be confirmed with Lee.

### 199. ordered_data_structures is skipped on the ESP32-S3 board by the driver

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_port_status.md, section 4.4, about line 159
- **Recorded as:** "skipped (driver:)"
- **Found:** ESP32-S3_raw.skip still lists it.

### 200. Sub-suites with their own Makefile (the 7 under error_enforcement_addition) are skipped by the board driver

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_port_status.md, section 4.4, about line 160
- **Recorded as:** "skipped automatically, reported"
- **Found:** The skip file comments say the driver skips them; I did not check board_suite.sh for a change.

### 201. The board runs one trial at a time on a single board

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_port_status.md, section 4.4, about line 162
- **Recorded as:** "One board"
- **Found:** trials/targets/README.md still describes one board per target.

### 202. The ESP32-S3 emitter has no per-space pools; alloc_region uses no pool per space

- [ ] reviewed
- **Document:** compiler/design_documents/porting_for_os_free_targets.md, status paragraph (line 5), section 4 Space row, and Phase B (about line 301)
- **Recorded as:** "per-Space pools" listed under Not delivered
- **Found:** Only the board space tables and atomic barriers exist (b9bdc0d547).

### 203. A timer-IRQ clock is not built; the boards poll the system timer

- [ ] reviewed
- **Document:** compiler/design_documents/porting_for_os_free_targets.md, status paragraph (line 5), section 4 Time row, Phase F (about line 323)
- **Recorded as:** "Still open: timer-IRQ clock (polling today)"
- **Found:** Runtime keeps interrupts off.

### 204. No bare-metal AArch64 / QEMU board pack exists (Phases B, D, E, and the AArch64 parts of C and F)

- [ ] reviewed
- **Document:** compiler/design_documents/porting_for_os_free_targets.md, sections 11 and 12, about lines 301 to 327
- **Recorded as:** "Still open: the bare-metal AArch64/QEMU pack"
- **Found:** No such emitter directory; RP2350_raw is a README only.

### 205. No per-board fault/IRQ document, no AArch64 vectors, and stack-guard breakpoints not verified

- [ ] reviewed
- **Document:** compiler/design_documents/porting_for_os_free_targets.md, section 4 Fatal fault row, about line 91
- **Recorded as:** "no per-board fault/IRQ document and no AArch64 vectors yet; stack-guard breakpoints not verified"
- **Found:** No such document found.

### 206. Peek/poke widths other than 32 bits and any other OS-free target remain open

- [ ] reviewed
- **Document:** compiler/design_documents/porting_for_os_free_targets.md, section 4 Volatile MMIO row, about line 82
- **Recorded as:** "Other widths, and any other OS-free target, remain"
- **Found:** See the width block above.

### 207. The wide emitter diagnostic channel is not built

- [ ] reviewed
- **Document:** compiler/design_documents/porting_for_os_free_targets.md, status paragraph, line 5
- **Recorded as:** "the wide emitter diagnostic channel"
- **Found:** Same as the narrow channel block.

### 208. Recorded-open decisions: descriptions seen only through an .iface, spawn_device inside a register_rwr sequence, the move-only rule for device_window, and the restart-time init rule are not checked

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_peek_poke_implementation_plan.md, Implementation status, about line 43; Still to decide, about lines 420 and 429; also compiler/design_documents/silica_device_actor_specification.md, Implementation status Not enforced, line 12
- **Recorded as:** "not re-checked on 2026-10-16" / "Nothing in this plan enforces it"
- **Found:** Error codes list (error_codes.md) has no code for any of them; I did not test the compiler.

### 209. Exclusive-overlap rule for live map_device windows is not enforced or verified

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_peek_poke_implementation_plan.md, Still to decide; compiler/design_documents/silica_device_actor_specification.md, line 12
- **Recorded as:** "needs confirmation" / "not verified"
- **Found:** No overlap check found in the type checker or rt_device.S.

### 210. Widths 8, 16 and 64 on the board await TRM confirmation

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_peek_poke_implementation_plan.md, Still to decide, about line 415
- **Recorded as:** "to be confirmed from the TRM"
- **Found:** Emitter still refuses them.

### 211. The peek/poke plan gate still lists re-establishing the fixed point, done only when Lee asks

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_peek_poke_implementation_plan.md, Gate status, about line 437
- **Recorded as:** "Still open: re-establishing the fixed point"
- **Found:** No later note found.

### 212. Programmer-described devices on a hosted target, a generator from SVD files, DMA buffer move laws, the IRQ-enqueue contract and pack-level checks (window overlap, register inside window) are not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica_device_actor_specification.md, Implementation status, lines 12, 13 and 281
- **Recorded as:** "Not enforced" / "Not implemented" / "not found in the compiler"
- **Found:** grep of the compiler for pack-level checks found nothing.

### 213. Linux x86-64: deploy/linux/install_silica.sh does not exist (Phase 6)

- [ ] reviewed
- **Document:** compiler/design_documents/porting_to_linux_x86_64_hosted.md, status line 5 and Phase 6, about line 387
- **Recorded as:** "Phase 6 is only partly done ... install_silica.sh does not"
- **Found:** deploy/ directory absent from the repo.

### 214. Linux x86-64: project_makefiles per-host fragments incomplete and silica_link.sh returning ELF archives not verified

- [ ] reviewed
- **Document:** compiler/design_documents/porting_to_linux_x86_64_hosted.md, Phase 6, about line 388
- **Recorded as:** "not verified"
- **Found:** Only platforms.mk and platforms.patch exist in project_makefiles/platform.

### 215. STM32 flash mode: the flash/RAM equality, convention-check, fault-path and power-cycle checks have not been run on the board

- [ ] reviewed
- **Document:** compiler/design_documents/stm32_flash_execution_design.md, section 4 items 2 to 5, about line 207
- **Recorded as:** "Steps 2 to 5 have not been run on the board (2026-11-14)"
- **Found:** No board record of flash runs; flash is by hand only.

### 216. STM32 flash mode: the measurements of section 5 (section sizes, ACR effect, OpenOCD reliability, option bytes) are not recorded

- [ ] reviewed
- **Document:** compiler/design_documents/stm32_flash_execution_design.md, section 5, about line 219
- **Recorded as:** "What must be measured first"
- **Found:** No note found.

### 217. STM32 flash mode: whether the ART is enabled in the RAM image is undecided

- [ ] reviewed
- **Document:** compiler/design_documents/stm32_flash_execution_design.md, section 6, about line 232
- **Recorded as:** "the ART in the RAM image is still undecided"
- **Found:** Still the status text of 2026-11-14.

### 218. STM32 flash mode: several design facts are marked unverified (programming flags, wear figure, option bytes, FPB count)

- [ ] reviewed
- **Document:** compiler/design_documents/stm32_flash_execution_design.md, sections 2.5, 2.6, 3 and 7
- **Recorded as:** "unverified"
- **Found:** No board confirmation recorded.

### 219. Optional wired pin-test fixture is not written

- [ ] reviewed
- **Document:** compiler/design_documents/board_pin_builtins_design.md, section 10 Open, about line 284
- **Recorded as:** "The optional wired fixture (section 7) is not written"
- **Found:** No such fixture under board/tests/pins.

### 220. pin_read on an ESP32-S3 pad with the input buffer off reads 0; the builtins do not switch it on

- [ ] reviewed
- **Document:** compiler/design_documents/board_pin_builtins_design.md, section 10 Open, about line 284
- **Recorded as:** "reads 0"
- **Found:** Still the recorded behaviour.

### 221. Pin builtins: alternate functions, drive strength, analog and interrupts are not provided

- [ ] reviewed
- **Document:** compiler/design_documents/board_pin_builtins_design.md, section 2, about line 33
- **Recorded as:** "Open items for later"
- **Found:** Not in the builtin signatures.

### 222. IPC_Bare: publish/subscribe, DMA message producers, the large-payload path and payload arenas are absent

- [ ] reviewed
- **Document:** compiler/design_documents/IPC_Bare.md, Future Extensions, about line 459
- **Recorded as:** "Still absent"
- **Found:** Nothing in rt_actors.S for these.

### 223. IPC_Bare: interrupt handling, mailbox-full policy, cross-application shared-SRAM transport and the datagram header have no implementation

- [ ] reviewed
- **Document:** compiler/design_documents/IPC_Bare.md, Implementation status, line 3
- **Recorded as:** "has no implementation" / "there is no mailbox-full policy"
- **Found:** Mailbox-full policy is marked superseded (about line 254); the others stand.

### 224. Brokered IPC isolation architecture is design only: no broker, no helper-process runtime, no NetOpen intrinsics

- [ ] reviewed
- **Document:** compiler/design_documents/brokered_ipc_isolation_architecture.md, Implementation status, line 3
- **Recorded as:** "Design only"
- **Found:** grep of compiler/src and compiler/stdlib for broker, NetOpen and helper-process found nothing.

## Compiler and phase notes (40)

### 225. The emitter function record_make_link_promotes_field still gives callee-saved shadows for a promote call that no longer exists, and has not been removed

- [ ] reviewed
- **Document:** compiler/design_documents/Phase2_notes.md, section 3 item 3 (S7 removals), about line 139
- **Recorded as:** "remove it when a trial shows it can go. Still open (2026-11-14 check)"
- **Found:** The function is still defined in compiler/src/emitter/linux_aarch64/emitter_core.silica (line 771) and STM32-L476RG_raw/emitter_core.silica (line 888); no trial or commit removing it was found.

### 226. There is no error trial that expects E2302 for a write_ref of a frame-young value into an older cell

- [ ] reviewed
- **Document:** compiler/design_documents/Phase2_notes.md, section 3 item 4 (known hazards), about line 154
- **Recorded as:** "the trial is still a positive hazard trial (.scout 7,0) and no E2302 error trial exists yet; still open: add it"
- **Found:** E2302 is implemented in region_checker_core.silica, but grep of trials/ finds no golden naming E2302, and region_hazards_open_addition/write_ref_young_into_older_cell is still the positive trial.

### 227. The trials directory has no codegen_regressions suite

- [ ] reviewed
- **Document:** compiler/design_documents/Phase2_notes.md, section 3 item 7, about line 172
- **Recorded as:** "No codegen_regressions suite exists in trials/ (gate list item)"
- **Found:** ls of trials/ shows no codegen_regressions directory.

### 228. strict state_release; parses, but E2321 (turning W2300 into an error) is not emitted anywhere and is not in the error code list

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_notes.md, section 10.8.4 first bullet, about line 706 (also stage table row 3c, about line 19; Phase6_notes.md section 1, about line 127)
- **Recorded as:** "Still open: E2321 is not emitted anywhere"
- **Found:** grep of compiler/src and trials finds E2321 only in main_compile_pipeline.silica, as a comment; W2300 is emitted at main_compile_pipeline.silica line 204.

### 229. The trials actors_addition/proven_release_flat_memory, actors_addition/fallback_copy_compacts_holes, warning_enforcement_addition/state_release_not_proven_alias, the three actor_stacks_addition/state_policy_* trials, memory_region_addition/retire_outside_actor_is_noop and the retire type-error pair (E2010, E2003) are not written under those names

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_notes.md, section 10.8.5 item 4, about line 751
- **Recorded as:** "Partly done (2026-11-14 check): none of proven_release_flat_memory, fallback_copy_compacts_holes or the state_policy_* trials exists by name"
- **Found:** ls of actor_stacks_addition shows only stack_keep_high_water_{proven,unproven}_state_survives as related trials; I did not search for the other names beyond the first four.

### 230. The whole-batch compiler memory target (4 GB) fails at 180k tokens, and parse time and memory still grow quadratically

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_notes.md, section 9 (stage 2 results), about line 347; compiler/design_documents/Phase3_stage2_analysis.md, section 2
- **Recorded as:** "Open (removed from the phase-3 completion gate by Lee, 2026-10-30)"
- **Found:** No newer measurement of the parser batch was found; only per-unit self-build footprint tsv files under benchmarking/memory_use_reports/data exist, and the analysis note already says so.

### 231. Measure the stage 2 self-build footprint over time with swap state recorded

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_stage2_analysis.md, section 5 measure 1, about line 92
- **Recorded as:** "it has not produced a self-build number yet (2026-11-14 check, partly done)"
- **Found:** Per-unit peak_footprint_MB data exists in benchmarking/memory_use_reports/data/*.tsv, but no over-time analysis for stage 2 is recorded in any document I read.

### 232. Count tokens per self-build unit and record the largest unit's phase timeline (lex, parse, check, SIR, emit)

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_stage2_analysis.md, section 5 measure 2, about line 93
- **Recorded as:** "What must be measured next"
- **Found:** No token-count or phase-timeline record was found in the documents or benchmarking data I looked at.

### 233. Run the stage 2 parser batch with finer sizes and capture the exit-70 banner at k=10000 and the shape-6 point

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_stage2_analysis.md, section 5 measure 3, about line 94
- **Recorded as:** "What must be measured next"
- **Found:** No later record of these runs was found.

### 234. Attribute the quadratic term by sampling stage 2 on k=2500 and counting retained adopted bytes and committed stack bytes

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_stage2_analysis.md, section 5 measure 4, about line 95
- **Recorded as:** "What must be measured next"
- **Found:** No attribution record was found.

### 235. Rerun the shape probe with more sizes and repeats, shape 6 to completion, and footprint per point

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_stage2_analysis.md, section 5 measure 5, about line 96
- **Recorded as:** "What must be measured next"
- **Found:** No later probe results were found.

### 236. Gather G and R at the return of the hot builders (the input to the copy-or-keep threshold)

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_stage2_analysis.md, section 5 measure 6, about line 97
- **Recorded as:** "the threshold input the amendment says is an open measurement"
- **Found:** No record of this measurement was found.

### 237. Lee has not decided which number is the pass criterion for the compiler memory target (maximum per-unit self-build footprint or the synthetic parse batch)

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_stage2_analysis.md, section 5 Decisions for Lee, first bullet, about line 101
- **Recorded as:** "Decisions for Lee"
- **Found:** No document or commit message records his decision.

### 238. Lee has not decided whether the remaining quadratic parse time and memory is in scope before the memory target is declared met

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_stage2_analysis.md, section 5 Decisions for Lee, second bullet, about line 102
- **Recorded as:** "Decisions for Lee"
- **Found:** No recorded decision was found.

### 239. Lee has not decided the direction and order of the 3.3/3.4 amendment and the actor-split work

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_stage2_analysis.md, section 5 Decisions for Lee, third bullet, about line 103
- **Recorded as:** "Decisions for Lee"
- **Found:** No recorded decision was found; the copy-or-keep threshold is still unmeasured.

### 240. The exit-70 failures (k=10000 parse, probable shape-6 n=20000) have no captured message, so it is unknown whether they are a stack-policy limit, a memory ceiling or a defect

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_stage2_analysis.md, section 5 Decisions for Lee, fourth bullet, about line 104
- **Recorded as:** "They need a captured message before any memory conclusion is drawn"
- **Found:** No captured banner was found in any document.

### 241. Several runtime-support helpers (md_type_needs_copy, md_descriptor_rodata, md_site_label, mc_site_is_last_use, module_uses_alloc_region) are unused but still defined

- [ ] reviewed
- **Document:** compiler/design_documents/Phase4_notes.md, section 6b (phase 4 close), about line 737; also section 6.5, about line 690
- **Recorded as:** "Still open: ... are still defined (unused, harmless)"
- **Found:** Checked on 2026-11-14 and not removed by any commit I found; I did not re-grep each name today.

### 242. Diagnostic E2242 (region checker, section 6.4 to 6.6) is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/Phase6_notes.md, opening status paragraph, about line 7
- **Recorded as:** "E2242 still open (named only in a comment at region_checker_core.silica:27, not in error_codes.md)"
- **Found:** grep of compiler/src, trials and the design documents finds E2242 only in that comment.

### 243. The ESP32-S3_raw tree still refers to L_region_grow in prims_memory.silica and other board files

- [ ] reviewed
- **Document:** compiler/design_documents/Phase6_notes.md, section 4.5 fourth bullet, about line 379; compiler/design_documents/Phase2_notes.md, section 3 item 3, about line 144
- **Recorded as:** "ESP32-S3_raw prims_memory.silica:135,544 still refer to it"
- **Found:** grep finds region_grow in ESP32-S3_raw emitter_core, prims_memory, term_reg_spill, xt_frame, rt_heap.S and rt_ordering.S.

### 244. The process-wide _silica_rt_region_lock word is still defined with no user now that L_region_grow is not emitted on the Mac

- [ ] reviewed
- **Document:** compiler/design_documents/Phase5_notes.md, section 8.3 first bullet, about line 473
- **Recorded as:** "It goes when L_region_grow goes" (my 2026-11-18 note: partly done)
- **Found:** prims_actors_runtime_asm.silica line 3789 still defines it; no other use was found on the Mac.

### 245. The use-tree first pass (prefix parse to the first function, banner "Building use tree") is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/Phase2_TODO/use_tree_first_pass.md, Implementation status, about line 9 (also silica-compiler-code-organization.md, pipeline paragraph, about line 77; module_interface_cache_and_bottom_up_typecheck_plan.md, section on first process, about line 197)
- **Recorded as:** "not implemented"
- **Found:** main_parse.silica still prints Parsing, Lexing... and runs the full parse_program on every config path; grep finds no parse_use_prefix or use-tree banner.

### 246. Iface-cache Phase 5 trial: a stale iface is rejected

- [ ] reviewed
- **Document:** compiler/design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md, Phase 5, about line 396
- **Recorded as:** "Still open: a trial named for stale iface rejected"
- **Found:** grep of trials/ for stale iface wording finds nothing; iface_usable_for_source exists in module_iface.silica but no trial pins it.

### 247. Iface-cache Phase 5 trial: E4001 still fires from iface keys

- [ ] reviewed
- **Document:** compiler/design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md, Phase 5, about line 396 and checklist line 408
- **Recorded as:** "Still open: ... and E4001 from iface keys"
- **Found:** grep of trials/ finds no golden naming E4001.

### 248. Correctness checklist: cross-module export conflicts (E4001) are still detected

- [ ] reviewed
- **Document:** compiler/design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md, section 11, about line 408
- **Recorded as:** "- [ ] Cross-module export conflicts (E4001) still detected"
- **Found:** No trial golden naming E4001 was found.

### 249. Correctness checklist: self-import (E4008) is unchanged

- [ ] reviewed
- **Document:** compiler/design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md, section 11, about line 409
- **Recorded as:** "- [ ] Self-import (E4008) unchanged"
- **Found:** No trial golden naming E4008 was found.

### 250. Direct machine-object emitter plan, Phase 0 (spike Mach-O object with one add)

- [ ] reviewed
- **Document:** compiler/design_documents/direct_machine_object_emitter_plan.md, section 13 Phase 0, about line 15
- **Recorded as:** "Status: open work remains"
- **Found:** No Instr, CodeObject or object-writer code exists in compiler/src; the emitters write assembly text only.

### 251. Direct machine-object emitter plan, Phase 1 (code buffer and integer subset)

- [ ] reviewed
- **Document:** compiler/design_documents/direct_machine_object_emitter_plan.md, section 13 Phase 1, about line 48
- **Recorded as:** "Status: open work remains"
- **Found:** No code buffer or encoder exists in compiler/src.

### 252. Direct machine-object emitter plan, Phase 2 (symbols and relocations)

- [ ] reviewed
- **Document:** compiler/design_documents/direct_machine_object_emitter_plan.md, section 13 Phase 2, about line 86
- **Recorded as:** "Status: open work remains"
- **Found:** No relocation or symbol writer exists in compiler/src.

### 253. Direct machine-object emitter plan, Phase 3 (literal pools and runtime references)

- [ ] reviewed
- **Document:** compiler/design_documents/direct_machine_object_emitter_plan.md, section 13 Phase 3, about line 129
- **Recorded as:** "Status: open work remains"
- **Found:** Nothing implemented; literal pools are still emitted as assembly text.

### 254. Direct machine-object emitter plan, Phase 4 (trial parity subset)

- [ ] reviewed
- **Document:** compiler/design_documents/direct_machine_object_emitter_plan.md, section 13 Phase 4, about line 185
- **Recorded as:** "Status: open work remains"
- **Found:** No direct-emitter trials exist under trials/.

### 255. Direct machine-object emitter plan, Phase 5 (full Apple Silicon replacement candidate)

- [ ] reviewed
- **Document:** compiler/design_documents/direct_machine_object_emitter_plan.md, section 13 Phase 5, about line 217
- **Recorded as:** "Status: open work remains"
- **Found:** Nothing implemented.

### 256. Direct machine-object emitter plan, Phase 6 (additional object formats and chips)

- [ ] reviewed
- **Document:** compiler/design_documents/direct_machine_object_emitter_plan.md, section 13 Phase 6, about line 254
- **Recorded as:** "Status: open work remains"
- **Found:** Nothing implemented.

### 257. The direct machine-object emitter design as a whole (Silica-owned instruction encoders and object writers replacing the assembler step)

- [ ] reviewed
- **Document:** compiler/design_documents/direct_machine_object_emitter_future.md, header and Implementation status, about lines 3 and 7
- **Recorded as:** "Future development. Not implemented"
- **Found:** The four hosted and board backends and the STM32 backend all still produce .sams text that the platform assembler turns into objects.

### 258. string_literal_pool still deduplicates by linear list scan instead of a WBT map (Step 3.3)

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/bootstrap_retirement_and_self_host_plan.md, status section about line 47 and Step 3.3 about line 354
- **Recorded as:** "Step 3.3 (string_literal_pool) is NOT migrated" and "Status 2026-09-08: not started"
- **Found:** compiler/src/emitter/apple_silicon_mac/atoms/string_literal_pool.silica still defines and calls find_index_in_list (lines 111 to 128) and uses no wbt_map.

### 259. Recursion phase 4 (source-mapped stack traces from an explicit frame list) is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/recursion_implementation.md, Implementation status, about line 15, and Phase 4 about line 63
- **Recorded as:** "open design"
- **Found:** Only comments and stubs for fuel and trace hooks exist in emitter/apple_silicon_mac/recursion/recursion_support.silica.

### 260. Recursion phase 6 (trampoline fallback where tail calls are unavailable) is not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/recursion_implementation.md, Implementation status, about line 15, and Phase 6 about line 74
- **Recorded as:** "open design"
- **Found:** emit_trampoline_fallback_stub is a comment placeholder; no emitted trampoline.

### 261. The compiler cannot compile a whole application as one unit; it still builds one unit per file with exit 75 between units and .iface files

- [ ] reviewed
- **Document:** compiler/design_documents/APPLICATION_IS_ONE_COMPILATION_UNIT.md, section "What happens today is a work-around", about line 49 (also Phase1_TODOs/bootstrap_retirement_and_self_host_plan.md, open items list, about line 50)
- **Recorded as:** "the compiler is still not able to compile an application as one unit"
- **Found:** main_driver_first.silica and the silica.config per-file model are unchanged; commit c6efd99635 only lets up-to-date units keep their .sams and .iface.

### 262. Returned closures lose their captured values; closure environments (a two-word function value of code pointer and environment) are not implemented and the design decision is not taken

- [ ] reviewed
- **Document:** compiler/design_documents/HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md, Implementation status Open paragraph, about line 38, and A2 about line 82; compiler/design_documents/compiler_defects_resolution_plan.md, Implementation status, about line 5; compiler/design_documents/compiler_defects_execution_status_2026-09-10.md, status and Still open, about lines 3 and 45
- **Recorded as:** "closure environments NOT implemented"
- **Found:** E1067 and E1072 still reject the cases in compiler/src/parser/constraint_extract_validate.silica; the three train_defect_a2_* trials are error goldens, and no environment code exists.

### 263. The E2003 wording "type mismatch: <name>" names only the identifier and not the expected and actual types

- [ ] reviewed
- **Document:** compiler/design_documents/HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md, section "Inconsistent or misleading diagnostics", about line 218; compiler_defects_resolution_plan.md, Phase 6 message-text cleanups
- **Recorded as:** "not re-checked and are still open"
- **Found:** type_checker_expressions_identifiers.silica lines 1051 and 1076 still emit concat("type mismatch: ", node.name).

### 264. The E1040 message still does not say which statement or token is missing its semicolon

- [ ] reviewed
- **Document:** compiler/design_documents/HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md, section "Inconsistent or misleading diagnostics", about line 222
- **Recorded as:** "the E1040 message does not say which"
- **Found:** The message at constraint_extract_validate.silica line 396 now reads "expected ';' after this statement before the next statement", which is clearer but still names no token.

## Roadmap, FFI and the remaining documents (35)

### 265. The I2C0 driver outcomes :timeout and :arbitration_lost, the minibadge I2C and its GPIO lines were not provoked or completed on the ESP32-S3 board

- [ ] reviewed
- **Document:** ROADMAP.md, The four paths table, ESP32-S3 row, about line 25
- **Recorded as:** "`:timeout` and `:arbitration_lost` were not provoked and are logged there as not completed, as are the minibadge I2C and its GPIO lines"
- **Found:** The note names `device_esp32s3_i2c0.silica`, `device_mma8452q.silica`, apps `silica_34` to `silica_37`; no later commit or run record in the documents shows these outcomes run.

### 266. Acquire mode 2 (row-child drain protection under a carrier-style supervisor) does not exist on the ESP32-S3 board, and whether the board needs it is a design question

- [ ] reviewed
- **Document:** ROADMAP.md, Open item: the ESP32-S3 board gap, item 1, about line 88; also chunk 2 row, about line 132
- **Recorded as:** "is not on the board ... whether the board needs it, and in what form, is the open design question"
- **Found:** Only Lee can decide it; no document or commit records a decision, and the board has no restart token.

### 267. There is no ESP32-S3 board trial for the gap 3 self check (a row child asking its own supervisor to terminate or restart its own row now gets :error with :language_error)

- [ ] reviewed
- **Document:** ROADMAP.md, Open item: the ESP32-S3 board gap, item 2, about line 92; also chunk 2 row, about line 132
- **Recorded as:** "there is still no ESP32-S3 board trial for them (open)"
- **Found:** `trials/carriers_addition/workers_zzzgap_row_asks_*` has goldens on the Nucleo and hosted only; no ESP32-S3_raw golden exists for them.

### 268. The results of the ESP32-S3 and Nucleo board trial runs with compiler 999953 are unknown because the runs were stopped part way and the board goldens were not regenerated

- [ ] reviewed
- **Document:** ROADMAP.md, Open item: the ESP32-S3 board gap, item 4, about line 105; Later paths, about line 160
- **Recorded as:** "the board results with 999953 are unknown (open)"
- **Found:** `c063517bd9` states the board runs were stopped and not fully tested; the STM32 link `silica-999985` carries the same caveat. A board run is Lee's and could not be checked.

### 269. All board work for the gap is to be done on a separate branch by Lee, and nothing is verified on the board until he builds the board compiler and runs the trials

- [ ] reviewed
- **Document:** ROADMAP.md, Open item: the ESP32-S3 board gap, "How it will be done", about line 107
- **Recorded as:** "Board runs are Lee's: nothing here is verified on the board until he builds the board compiler and runs the trials"
- **Found:** No commit records such a run for the gap pieces.

### 270. The pooled FFI worker (dangerous-actor thread cap option A) is deliberately deferred

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 2, about line 132
- **Recorded as:** "only option A (a pooled FFI worker) is deliberately deferred"
- **Found:** It is a recorded deferral, not a defect; no code for a pooled worker exists.

### 271. The Linux get_actor_memory_usage and x86-64 timing measurements are still held

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 2, about line 132
- **Recorded as:** "the held Linux `get_actor_memory_usage` and x86-64 timing measurements"
- **Found:** `actor_memory_budget_plan.md` line about 1490 says the same ("unmeasured (held)"), and git log since 2026-10-21 shows no commit that takes the measurements.

### 272. The list builtins map, filter and reduce do not exist

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 3, about line 133; compiler/design_documents/README.md, entry for list_map_filter_reduce_and_hardening_todo.md, about line 176
- **Recorded as:** "Not delivered ... there are no `list_map`, `list_filter` or `list_reduce` builtins"; README: "`map` / `filter` / `reduce` (not started)"
- **Found:** No such name in `type_checker_builtin_signatures.silica` or anywhere under `compiler/src`; no trial in `trials/list_addition`. Only the ordered-map and set stdlib modules have fold-style functions.

### 273. Stage 0 of region memory safety: hazard H8 has not been re-read and hazard H10 (atomics) is open

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 4, about line 134
- **Recorded as:** "stage 0 partly done ... H10, atomics, remains open; ... done except H8, which is not re-read, and H10"
- **Found:** No atomic builtins exist in the type checker (only the `atomic_ref` type); `region_memory_safety_plan.md` audit states the same. H8 I did not read.

### 274. The region checker's errors (E2301, E2300, E2302) are errors only when a unit declares `strict region_check;`, not by default

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 4, stage 5, about line 134
- **Recorded as:** "stage 5 partly done ... not on by default"
- **Found:** `main_compile_pipeline.silica` runs `check_program_regions` and notes it is report-only under `strict region_check;`; no change to a default-on mode.

### 275. Stage 7 of region memory safety, atomic references and the four atomic builtins, is not implemented

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 4, about line 134; chunk 6, about line 136
- **Recorded as:** "7 atomics (Q7, Q8)"; chunk 6: "Atomic operations and synchronization guarantees audited against the spec and completed"
- **Found:** `atomic_load`, `atomic_store`, `atomic_fetch_add` and `atomic_compare_exchange` appear in no emitter or type checker file; only the `atomic_ref` type kind exists. No trial uses them.

### 276. Stage 8 static buffer checks E2315 to E2318 are not emitted

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 4, about line 134
- **Recorded as:** "static buffer checks E2315 to E2318 not emitted"
- **Found:** Grep for E2315 and E2318 in `compiler/src` and `trials` returns nothing.

### 277. Typed variant constructors (spec §4.2.5) and §6.1.2 are not implemented, and there is no dedicated trial for effect composition

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 5, about line 135
- **Recorded as:** "Open: spec §4.2.5 constructor-with-type variants and §6.1.2 are still not implemented ... no dedicated trial for effect composition exists"
- **Found:** Lee decided no typed variant bindings, so this stays open by his decision; no trial named for effect composition under `trials`.

### 278. Extended numerics (big integers, big floats, rationals, big rationals, 128-bit integers) do not exist

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 7, about line 137
- **Recorded as:** "Extended numerics. Big integers, big floats, rationals, big rationals, and 128-bit integers"
- **Found:** No such type in the lexer, parser or type checker, and no trial directory for them.

### 279. Many-connection trials for the Fifi socket wrappers do not exist

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 9, about line 139
- **Recorded as:** "Open: many-connection trials (none exist)"
- **Found:** `trials/transport_addition` and `ffi_addition` have loopback, listener, peer-close, large-frame and both-sides trials only; none opens many connections.

### 280. Malformed-packet trials beyond the two rejection cases do not exist

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 9, about line 139
- **Recorded as:** "malformed-packet trials beyond those two rejection cases"
- **Found:** Only `app_transport_tcp_max_frame` (too_large) and `transport_etf_rejections` exist.

### 281. Chunk 10 lists `panic`, supervisor `:terminate_actor`, the `register`, `whereis` and `unregister` builtins and enforcement of the `shutdown` time limit as not built

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 10, about line 140
- **Recorded as:** "Open (rechecked 2026-11-18, unchanged): `panic`; supervisor `:terminate_actor`; `register`, `whereis` and `unregister` (names bind only at spawn); enforcement of the `shutdown` time limit"
- **Found:** Rechecked in the earlier pass; not re-read in this one.

### 282. Spawner positions in actor identity are numbered at run time, and build-time numbering is still design

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 10, about line 140
- **Recorded as:** "spawner positions are numbered at run time, build-time numbering is still design"
- **Found:** Not re-checked against the emitters in this pass.

### 283. The cast-to-ended-actor change (cast returns false) was made by reading and not run on Linux AArch64, Linux x86-64 and STM32, and the Linux goldens for the trial are assembly goldens only

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 10, about line 140
- **Recorded as:** "the Linux AArch64, Linux x86-64 and STM32 runtime changes were made by reading and not run"
- **Found:** `trials/actors_addition/cast_to_ended_actor_returns_false` exists; no run-output golden or commit message for those platforms.

### 284. A race in exit and failure-report ordering can lose one expected report banner when an actor is killed abnormally and its supervisor chain ends

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 10, open item 2026-10-27, about line 140
- **Recorded as:** "Open item 2026-10-27 ... the root can exit before the killed actor's `(:explicit, :killed)` report banner is printed"
- **Found:** No commit since then names a fix for report ordering; `Phase2_notes.md` section 6 is the cited evidence.

### 285. The supervisor guarded-fault FFI trials fail intermittently under load on a 4-CPU linux_aarch64 host

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 10, related open item 2026-10-27, about line 140
- **Recorded as:** "fail their sorted output compare intermittently ... a pre-existing load-sensitive ordering race"
- **Found:** Tied to the report-ordering race above; no fix recorded in git.

### 286. call_with_timeout is not implemented

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 11, about line 141
- **Recorded as:** "`call_with_timeout` is still open ... specification §16.1.1.2 says it is not implemented"
- **Found:** Only the cast/call convention check in `type_checker_cast_convention.silica` mentions it; no builtin signature, emitter prim or trial.

### 287. Composite Recreatable and recreate: the limit checks and the rebuild for composite values are not implemented, only scalar recreate exists

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 13, about line 142; compiler/design_documents/silica_ffi_wrapper_specification.md, section 7.7 status and Implementation status block, about lines 8 and 1075; compiler/design_documents/dangerous_ffi_security_model.md, sections 9 and 13, about lines 160 and 226
- **Recorded as:** "Open: `Recreatable` / `recreate` for composites"; spec: "Composite types are ROADMAP chunk 13"
- **Found:** `transport_derive.silica` derives `recreate` as `(:ok, v)` for any type with no limit check or rebuild; E2406 is in `ffi_taint_checker.silica`.

### 288. Chunk 13 closing condition that every rejection atom of spec §7.7 has a trial

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 13, about line 142
- **Recorded as:** "every rejection atom of §7.7 has a trial; re-created values pass the taint checks that raw foreign values fail"
- **Found:** Only one trial file under `trials` mentions `recreate`; with no limit checks in the derived function there is nothing to reject on.

### 289. Chunk 15 has no ESP32-S3 state_chain_1000_actors trial

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 15, about line 144
- **Recorded as:** "no `state_chain_1000_actors` trial"
- **Found:** No such directory under `trials`.

### 290. Storage carrier phase S3 (a board medium) is not built

- [ ] reviewed
- **Document:** ROADMAP.md, Transport and storage carriers, about line 153
- **Recorded as:** "phase S3 (a board medium) is not built"
- **Found:** Only the `(:memory)` and hosted `(:backing)` store kinds exist in `compiler/stdlib`; no board store carrier.

### 291. Board runs of `c063517bd9` (BEES requests) were not completed, and the Mac trial app_transport_tcp_close_after_end/dangerous_tcp_carrier_end_memory still failed under the macOS thread cap

- [ ] reviewed
- **Document:** ROADMAP.md, Transport and storage carriers, about line 153
- **Recorded as:** "the board runs were not completed and that one Mac trial ... still failed under the macOS thread cap (analysed there as a load artefact)"
- **Found:** The commit message is the only record; no later commit shows a clean rerun.

### 292. RP2350_raw has only a README and no emitter

- [ ] reviewed
- **Document:** ROADMAP.md, Later paths, about line 160
- **Recorded as:** "`RP2350_raw` is started (a README only, no emitter)"
- **Found:** `compiler/src/emitter/RP2350_raw` holds a README only.

### 293. A bare-metal AArch64 emitter, RISC-V and Windows paths do not exist

- [ ] reviewed
- **Document:** ROADMAP.md, Later paths, about lines 160 and 162
- **Recorded as:** "bare-metal AArch64 is not started (no emitter) ...; RISC-V after; Windows later"
- **Found:** `compiler/src/emitter` holds only the four emitters, the STM32 one and the RP2350 README.

### 294. The ROADMAP says the specification's wrapper-related builtin get_dangerous_pid_registry() does not exist

- [ ] reviewed
- **Document:** compiler/design_documents/silica_ffi_wrapper_specification.md, section 4.9.2 table, about line 502
- **Recorded as:** "**Not implemented:** this builtin does not exist"
- **Found:** No `get_dangerous_pid_registry` in `compiler/src`.

### 295. Package declarations (spec §14.3) and building C wrapper sources are future work

- [ ] reviewed
- **Document:** compiler/design_documents/silica_ffi_wrapper_specification.md, 14.3 and Implementation status block, about lines 9 and 1984
- **Recorded as:** "Package declarations (§14.3) and building C wrapper sources are also future"
- **Found:** No package manifest handling beyond `silica.link` in `compiler/src/ffi`.

### 296. FFI specification open design questions: sidecar .meta field syntax beyond the required fields, standard request and result cast message shapes, how many FFI workers to spawn by convention, and when the build tool compiles C wrapper sources

- [ ] reviewed
- **Document:** compiler/design_documents/silica_ffi_wrapper_specification.md, section 16, about line 2234; compiler/design_documents/dangerous_ffi_security_model.md, section 13, about line 227
- **Recorded as:** "The following questions remain open"
- **Found:** These are design decisions for Lee; I found no document or commit that records them as decided.

### 297. Cross-process messaging (Unix-domain-datagram transport, process supervisor, inter-process mailbox) does not exist

- [ ] reviewed
- **Document:** compiler/design_documents/IPC_OS.md, Implementation status note, about line 3
- **Recorded as:** "Design only. No Unix-domain-datagram transport, process supervisor or inter-process mailbox exists"
- **Found:** Grep of the emitters for `AF_UNIX` and `sendto` finds nothing.

### 298. No Silica target runs on an RTOS and the actor-per-RTOS-task mapping does not exist

- [ ] reviewed
- **Document:** compiler/design_documents/IPC_RTOS.md, Implementation status note, about line 3
- **Recorded as:** "Design only. No Silica target runs on an RTOS"
- **Found:** Only a board README and `rt_start.S` mention FreeRTOS; the board runtimes use their own cooperative schedulers.

### 299. Future designs recorded as not implemented: language TLS, the direct machine-object emitter, general recursion with fuel, and list chunk sizing that follows SIMD width

- [ ] reviewed
- **Document:** compiler/design_documents/README.md, entries for tls_quantum_safe_future.md, direct_machine_object_emitter_future.md, recursion_implementation.md, list_chunk_vector_alignment_todo.md, about lines 156, 162, 224 and 180
- **Recorded as:** "Future development (not implemented)"; "no fuel"; "Open work (nothing done)"
- **Found:** No TLS engine, no instruction encoders or object writers under `compiler/src`, `recursion_support.silica` says the fuel and trampoline phases are not implemented, and `prims_list.silica` still describes the fixed 16-byte layout.

# Part 2: undecided

## Language specification (6)

### 300. Static region lifetime analysis Phases B (nested scopes) and C (cross-function analysis) are not done

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 12.1.4 Static Region Lifetime Analysis, about line 6673
- **Recorded as:** "Phase A (single scope) is implemented. Phases B (nested scopes) and C (cross-function analysis) require implementation after functions are fully supported."
- **Why undecided:** The comment in type_checker_memory_regions.silica still says B and C are to come, but compiler/src/region_checker now exists (E2300, E2301, E2302 under strict region_check;, with flow-sensitive and callee handling). I could not tell without a deep read whether that checker is what Phases B and C meant.

### 301. A device worker cannot yet be a supervisor child on the ESP32-S3

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 16.4.9 Carrier links, about line 10756
- **Recorded as:** "a device worker cannot yet be a supervisor child"
- **Why undecided:** I did not check the supervisor and device-worker code for this, so I cannot say whether it still holds.

### 302. The failure report reason line has not been run on the ESP32-S3 board

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 15.4.6.4 Stack Unwinding for Diagnostics, about line 9028
- **Recorded as:** "verified on the Mac, Linux verification in progress, ESP32-S3 board run pending"
- **Why undecided:** trials/failure_reason_line_addition has .esp32_s3.ascomp assembly goldens and Mac .sout files but no Linux or board run output, and I found no commit recording a board run; Linux is probably covered by the later hosted runs but the trial's own record does not say so.

### 303. The variant-pattern example says sum types and variant patterns are not yet implemented in experiments

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 6.1.2 Variant Patterns, about line 3759
- **Recorded as:** "Sum types and variant patterns not yet implemented in experiments"
- **Why undecided:** This is a comment inside an example. Sum types and sum literals exist in the compiler (the language notes and trials use them), but I did not verify variant patterns against this example, so I left the comment.

### 304. The Phase 2 use-tree first pass (parse only declarations through the first function, then sort) may not be implemented

- [ ] reviewed
- **Document:** compiler/design_documents/silica-specification.md, 19.4.5 Module Dependency Resolution Algorithm, about line 12277
- **Recorded as:** "Phase 2 compiler (use-tree first pass) ... It does not parse function bodies." (the linked Phase2_TODO note says "not implemented", 2026-10-16)
- **Why undecided:** I did not re-read main_parse.silica or main_driver_first.silica; commit c6efd99635 (units in silica.up_to_date are not compiled again) is related but does not obviously implement this pass.

### 305. Whether every extended region-lifetime judgment of section 6 is enforced by the compiler is not established

- [ ] reviewed
- **Document:** compiler/design_documents/silica-formal-verification-specification.md, Implementation status (Section 6), about line 15
- **Recorded as:** "region lifetime analysis is partly implemented ... Not verified here: whether every extended-judgment rule in section 6 is enforced."
- **Why undecided:** The region checker (compiler/src/region_checker, E2300 to E2302) and type_checker_memory_regions.silica now exist, but mapping each section 6 rule to a check needs a rule-by-rule read that I did not do.

## Transport and storage carriers (3)

### 306. Whether the handler that receives an FFI result cast is a taint source (FFI specification 7.6) is left open, so E2406 fires only for a nested plain sequence

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 14 checks of 9.3, about line 1684
- **Recorded as:** "FFI wrapper specification §7.6 is open"
- **Why undecided:** I did not trace the taint checker, and FFI spec 7.6 (line about 1028) was not read for its current state, so I cannot say whether this has since been resolved.

### 307. Whether the ESP32-S3 and Nucleo cross compilers are unaffected by the E2418 change is recorded as unchecked

- [ ] reviewed
- **Document:** compiler/design_documents/transport_hosted_ethernet_plan.md, 5 E2 status, about line 159
- **Recorded as:** "the ESP32-S3 and Nucleo cross compilers were not rebuilt ... unchecked"
- **Why undecided:** Newer cross compilers (silica-999956 and 999953) were built from later trees, but I did not check that E2418 is gated on the pack for the boards, so I cannot say if this is closed.

### 308. The IPv6 and name-bind forms of the `(:tcp)` carrier have no record of a real-network run, and the Linux hosts are recorded as not run

- [ ] reviewed
- **Document:** compiler/design_documents/transport_serialization_design.md, 6.3 IPv6 paragraph, about line 600
- **Recorded as:** "the Linux hosts not run"
- **Why undecided:** Trials and hosted goldens exist and commit c063517bd9 says hosted goldens were refreshed where output matched, but the commit does not name pix or nix for these trials, so I could not tell whether they ran on Linux.

## Memory: region safety and chunk 15 (7)

### 309. Whether hazard H8 (the Phase A return lifetime check misses ref?, records and lists) is still true

- [ ] reviewed
- **Document:** compiler/design_documents/region_memory_safety_design.md, section 1.3 table, about line 135
- **Recorded as:** "Phase A misses ref?, records and lists"
- **Why undecided:** the function check_sequence_return_lifetime still exists, but I did not read it against the example, and the region checker may cover it.

### 310. Whether the staged trial directories (region_hazards_open_addition, region_hazards_open_errors_addition, bees_regions_open_addition) now run in the gate

- [ ] reviewed
- **Document:** compiler/design_documents/region_memory_safety_design.md, section 14.2 status note and section 1.3, about line 815; compiler/design_documents/region_memory_safety_plan.md, work item 1, about line 47
- **Recorded as:** "INTEGRATE_PENDING" in the suites' READMEs
- **Why undecided:** each directory still has an INTEGRATE_PENDING file, but the Linux and board goldens suggest they were run; no record says they were promoted.

### 311. Whether isolation (ref of one lifetime stored in a region of another) is enforced under some other error code

- [ ] reviewed
- **Document:** compiler/design_documents/region_memory_safety_design.md, section 10 and hazard H6, about lines 718 and 133
- **Recorded as:** "Stays (isolation)"
- **Why undecided:** E2310 is not emitted and E2311 covers only call-site lifetime conflicts; I did not test a program that stores a ref across regions.

### 312. Whether E2005 is raised on a missing state_policy argument

- [ ] reviewed
- **Document:** compiler/design_documents/data_structure_redesign_requirements.md, section 7.5 item 13, about line 268
- **Recorded as:** "E2005 on a missing argument not individually verified"
- **Why undecided:** the only trials are the stack_policy ones, whose goldens show E2005; no trial isolates a missing state_policy, and I ran nothing.

### 313. Whether the STM32-L476RG board runtime was moved to the chunk 15 stack model

- [ ] reviewed
- **Document:** compiler/design_documents/chunk15_stack_memory_plan.md, section 11.1 phases 8 and 9, about lines 25 and 26; compiler/design_documents/Phase1_TODOs/region_memory_safety_todo.md, section 1.2, about line 54
- **Recorded as:** "Phase 9 ESP32-S3 ... done"
- **Why undecided:** the plan names only the ESP32-S3 for phase 9, and the STM32 emitter still contains body_has_moving_call, so I could not tell whether the Nucleo follows the new model.

### 314. Whether the verification checklist item "error messages reference specification sections" is met

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/region_memory_safety_todo.md, section 4 checklist, about line 230
- **Recorded as:** "[ ] Error messages reference specification sections (e.g., spec:§12.1.4)"
- **Why undecided:** the region checker prints sect12.1.4 and E2313 uses sect12.3.3, but the box is general and not every code is implemented.

### 315. Whether the report collection over the stdlib, compiler and trials (stage 3 triage) was done as the plan describes

- [ ] reviewed
- **Document:** compiler/design_documents/region_memory_safety_plan.md, work item 9 and stage 3 gate, about lines 57 and 24
- **Recorded as:** "report collection over stdlib, compiler and trials/; triage into misuse vs checker defect"
- **Why undecided:** the checker exists and the compiler builds with it, but no record of the triage was found.

## Actors (2)

### 316. Whether the Phase 4 compiler-integration item "type system enforcement: no inter-actor region passing, ActorBoundary constraints" is done

- [ ] reviewed
- **Document:** compiler/design_documents/actor_growable_stack_plan.md, Phase 4 item 2, about line 77
- **Recorded as:** "Type system enforcement - No inter-actor r passing; ActorBoundary constraints"
- **Why undecided:** The wording is old and vague, and I did not trace it to the region checker or copy-on-send work of chunk 15, so I could not tell whether it is done or superseded.

### 317. Whether the stage 2 to 4 "Unverified" lists of the carriers record (supervisors_host_defects, device actors, dangerous row, and so on) were all closed by later runs

- [ ] reviewed
- **Document:** compiler/design_documents/actor_memory_budget_plan.md, item N stage statuses, about lines 904 to 1330
- **Recorded as:** "Unverified:" and "Not done in stage 2/3/4"
- **Why undecided:** Later fixed points and full runs probably cover them, but I did not match each named suite and path to a later run, and the section is marked as history.

## Data structures (1)

### 318. Whether the Section 12 housekeeping carried into 13 is finished cannot be decided: reclassifying residual workaround comments in src/ and wiring or deleting HOST_COMPILER in src/Makefile

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/standard_data_structures_implementation_plan.md, 12 status Open line, about line 1485
- **Recorded as:** Housekeeping carried into 13: ... reclassify the residual workaround comments, and either wire or delete HOST_COMPILER in src/Makefile
- **Why undecided:** grep finds no HOST_COMPILER in src/Makefile now, so that part looks done, but whether the residual workaround comments were reclassified cannot be told without reading all of src/.

## Boards and ports (8)

### 319. Step 4 coverage check is recorded in section 3 but the original open point of poke_n reopening is conditional only; no action

- [ ] reviewed
- **Document:** compiler/design_documents/esp32s3_board_peripherals_plan.md, section 2 poke_n row, about line 67
- **Recorded as:** "Closed 2026-10-29 as not needed"
- **Why undecided:** Not an open item in practice; listed only because the row still says to reopen if a driver shows the cost.

### 320. Very large functions compile about 9 times slower on the ESP32-S3 emitter

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_port_status.md, section 4.5, about line 164
- **Recorded as:** "Emitter performance"
- **Why undecided:** No later measurement or fix found in git log.

### 321. Whether the tuple-literal record field and float-parameter fixes reached the linux_aarch64 and linux_x86_64 trees was not re-checked

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_port_status.md, section 4.6, about line 170
- **Recorded as:** "was not re-checked on 2026-10-16"
- **Why undecided:** I did not compare the three emitter trees.

### 322. The barrier choice (memw before every peek and poke, after every poke) is recorded as proposed

- [ ] reviewed
- **Document:** compiler/design_documents/ports/esp32s3_peek_poke_implementation_plan.md, Still to decide, about line 387
- **Recorded as:** "Proposed"
- **Why undecided:** The emitter implements it as proposed; the TRM check on caching the document asks for is not recorded.

### 323. Linux x86-64: Phase 5 fresh-clone exit gate and Phase 6 exit gate (new droplet to compiling project with one script) remain

- [ ] reviewed
- **Document:** compiler/design_documents/porting_to_linux_x86_64_hosted.md, status line 3, and Phase 6 exit gate
- **Recorded as:** "remain"
- **Why undecided:** No record of a fresh-clone run; I did not look for one beyond git log.

### 324. Linux x86-64: a GOLDEN_MISSING=warn knob is not present; the 43 inline toolchain blocks and SKIP_TRIALS use are unchecked

- [ ] reviewed
- **Document:** compiler/design_documents/porting_to_linux_x86_64_hosted.md, Step 2.2 items 1, 2 and 4, about line 184
- **Recorded as:** "Still to do, in order"
- **Why undecided:** No GOLDEN_MISSING in trials/*.mk; SKIP_TRIALS appears only in trials/platform/*.mk; I did not count the inline blocks. Phase 3 is complete so these may be moot.

### 325. Linux x86-64: app_sd18_worker_second_message still faults (the documented SD-18 defect)

- [ ] reviewed
- **Document:** compiler/design_documents/porting_to_linux_x86_64_hosted.md, about line 373
- **Recorded as:** "still faults"
- **Why undecided:** The trial is listed in ESP32 skip as having no sources; I did not run it.

### 326. STM32 flash mode: the harness refusal of BOARD_EXEC=flash is not implemented in board_suite.sh and run_one_trial.sh

- [ ] reviewed
- **Document:** compiler/design_documents/stm32_flash_execution_design.md, section 2.6, about line 170
- **Recorded as:** "must refuse BOARD_EXEC=flash outright"
- **Why undecided:** grep of trials/targets for BOARD_EXEC found nothing, so there is no refusal; the harness just never passes it.

## Compiler and phase notes (18)

### 327. The Phase 2 hazards that heap-mode evacuation rewrites an old aggregate in place, and that write_ref of a pointer to a younger frame's node into an older REF cell is not scanned, have no covering trials

- [ ] reviewed
- **Document:** compiler/design_documents/Phase2_notes.md, section 3 item 4 (known hazards), about lines 155 and 159
- **Recorded as:** "Known hazards, not covered by trials yet"
- **Why undecided:** I did not trace the evacuator code or check every region_hazards_open trial against these two bullets, so I cannot say whether a later phase made them moot.

### 328. The Phase 2 limits (main runs on the 8 MB OS stack, every frame is 16 bytes bigger, the send/spawn payload walk uses L_stack_top as an interim) are listed as known hazards, and I did not check whether later phases removed them

- [ ] reviewed
- **Document:** compiler/design_documents/Phase2_notes.md, section 3 item 4 (known hazards), about lines 161 to 164
- **Recorded as:** "interim until phases 3/4"
- **Why undecided:** Phases 3 and 4 notes say the payload walk and heap copies were replaced, but I did not confirm in code that L_stack_top use is gone or that main's stack limit changed.

### 329. The update-chain rules (the |_upd= marker, the version argument) of design 4.1 are not built, so every update is treated as unproven

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_notes.md, section 10.8.4 second bullet, about line 708
- **Recorded as:** "no logging updater exists before the stdlib's phase 5, so every update is unproven now"
- **Why undecided:** I did not search the stdlib or compiler for an updater or the |_upd= marker, so I cannot say whether phase 5 added it.

### 330. Undescribed state types (a type parameter, a trait type) still pass the state pointer without a copy, and module_uses_message_copy still counts a spawn as a copy site

- [ ] reviewed
- **Document:** compiler/design_documents/Phase3_notes.md, section 10.4, about lines 485 and 486 (also Phase4_notes.md section 5.3, about line 462)
- **Recorded as:** "still pass the pointer as before: no copy" and "still counts a spawn as a copy site"
- **Why undecided:** Phase 4 notes say undescribed composites keep the promote until Q19 enforcement; I did not read the current emitter to see whether 4e removed this.

### 331. The carriers released() poll trial cannot see its drop after heap_used() was retired and was flagged for a rewrite

- [ ] reviewed
- **Document:** compiler/design_documents/Phase4_notes.md, section 6b, about line 734
- **Recorded as:** "flagged for a rewrite (not done)"
- **Why undecided:** I found no record that the rewrite was done and did not read the carriers_addition trial source.

### 332. The region checker does not distinguish memory spaces when an atomic or device region handle escapes its frame

- [ ] reviewed
- **Document:** compiler/design_documents/Phase6_notes.md, section 4.5 second bullet, about line 371
- **Recorded as:** "the checker does not yet distinguish spaces (still open, 2026-11-14 check)"
- **Why undecided:** I did not read region_checker_core.silica for space handling.

### 333. Iface-cache Phase 5 trial: a dependent type-checks with the dependency AST omitted

- [ ] reviewed
- **Document:** compiler/design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md, Phase 5, about line 396
- **Recorded as:** "Still open: ... dependent type-checked with dependency AST omitted"
- **Why undecided:** The modules_addition and generic_modules_addition trials leave .iface files and dependents use iface stubs, so this may be covered implicitly, but no trial is named for it.

### 334. Correctness checklist: export set matches export name/arity and decl resolution used today

- [ ] reviewed
- **Document:** compiler/design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md, section 11, about line 406
- **Recorded as:** "- [ ] Export set matches export name/arity + decl resolution used today"
- **Why undecided:** Unchecked box; I did not compare the iface export set with the module checker.

### 335. Correctness checklist: source_module on imported symbols is unchanged (shadowing, qualified calls)

- [ ] reviewed
- **Document:** compiler/design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md, section 11, about line 407
- **Recorded as:** "- [ ] source_module on imported symbols unchanged"
- **Why undecided:** Unchecked box; not verified by reading or trial.

### 336. Correctness checklist: a failed type check never leaves a new good iface

- [ ] reviewed
- **Document:** compiler/design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md, section 11, about line 410
- **Recorded as:** "- [ ] Failed TC never leaves a new good iface"
- **Why undecided:** The status table says unpublish_module_iface_at_path runs on each failure path, but no trial was found that checks it.

### 337. Correctness checklist: Kahn cycle detection is unchanged

- [ ] reviewed
- **Document:** compiler/design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md, section 11, about line 411
- **Recorded as:** "- [ ] Kahn cycle detection unchanged"
- **Why undecided:** Unchecked box; I did not look for a cycle trial.

### 338. Correctness checklist: SIR and emit still see the current unit AST

- [ ] reviewed
- **Document:** compiler/design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md, section 11, about line 412
- **Recorded as:** "- [ ] SIR/emit still see current unit AST"
- **Why undecided:** The status table says dependents use stubs while the unit AST is kept, but the box was never ticked and I did not verify it.

### 339. Correctness checklist: dangerous, supervisor and failure-reporter module flags are available from the iface where needed

- [ ] reviewed
- **Document:** compiler/design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md, section 11, about line 413
- **Recorded as:** "- [ ] Dangerous / supervisor / failure-reporter module flags available"
- **Why undecided:** Not checked against module_iface.silica.

### 340. Correctness checklist: seed and selfhost behave the same for the same sources

- [ ] reviewed
- **Document:** compiler/design_documents/module_interface_cache_and_bottom_up_typecheck_plan.md, section 11, about line 414
- **Recorded as:** "- [ ] Seed and selfhost behavior match for the same sources (modulo dialect)"
- **Why undecided:** The separate seed source tree no longer exists (one tree, compiler/src), so the item may be obsolete; Lee should say.

### 341. A trials/self_host_addition suite was not created

- [ ] reviewed
- **Document:** compiler/design_documents/Phase1_TODOs/bootstrap_retirement_and_self_host_plan.md, status table row Step 6.1, about line 40
- **Recorded as:** "trials/self_host_addition/ was not created; make trials-gen1, trials-gen2, trials-both run the whole tree instead"
- **Why undecided:** The directory is still absent from trials/, but the document records this as an accepted substitute; only Lee can say whether the suite is still wanted.

### 342. Parser design section 9.2, sparse matrix output of structure extraction

- [ ] reviewed
- **Document:** compiler/design_documents/parser_design.md, section 9.2, about line 327
- **Recorded as:** "can emit a sparse matrix ... if desired"
- **Why undecided:** The section is an optional future consideration with no status wording, and I did not search the parser for it.

### 343. Parser design section 9.3, disambiguation rules exported by each capability

- [ ] reviewed
- **Document:** compiler/design_documents/parser_design.md, section 9.3, about line 331
- **Recorded as:** "Each capability can export disambiguation rules"
- **Why undecided:** The section is an optional future consideration with no status wording, and I did not search the parser for it.

### 344. E2002 (undefined identifier) is reported as E2005 when the undefined name is the head of a field access, and as E2010 in some binding positions

- [ ] reviewed
- **Document:** compiler/design_documents/HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md, section "Inconsistent or misleading diagnostics", about line 214; compiler_defects_resolution_plan.md, Phase 6 message-text cleanups
- **Recorded as:** "not re-checked and are still open"
- **Why undecided:** Deciding needs a compile of the repro, which this reading audit may not run.

## Roadmap, FFI and the remaining documents (9)

### 345. Ending an actor that is running on the other ESP32-S3 core waits for that actor's next dispatch boundary

- [ ] reviewed
- **Document:** ROADMAP.md, Actor placement in chunk 2 table, Raw (OS-free) row, about line 68
- **Recorded as:** "Open: ending an actor that is running on the other core waits for its next dispatch boundary"
- **Why undecided:** This is a board runtime behaviour in the ESP32-S3 `rt_actors.S`; I could not tell from reading the tree whether it is a limitation to remove or the intended design, and no trial names it.

### 346. Negative trials for unsupported list element shapes and the closing spec audit of lists are not done

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 3, about line 133
- **Recorded as:** "negative trials for unsupported element shapes and the closing spec audit are still open"
- **Why undecided:** `trials/list_addition` holds no obviously named negative trial, but I did not read the error_enforcement trials one by one to rule one out, and the spec audit has no testable closing criterion.

### 347. A device_window keeps one owner, with a check that still needs its own error code

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 4, decisions 15 to 17, about line 134
- **Recorded as:** "`device_window` keeps one owner with a check that still needs its own code (decisions 22 to 24; design §10)"
- **Why undecided:** `type_checker_expressions_device.silica` has E2003 and E2213 checks for windows but I could not tell whether any is the owner check the text means.

### 348. What happens to mailbox buffers still pending when an actor ends was recorded as an open mechanism question

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 4, plan item 3, about line 134
- **Recorded as:** "mailbox buffers pending at actor end are an open mechanism question"
- **Why undecided:** Chunk 15 in the same file records decisions 30 to 33 that such buffers are freed by one walk of the mailbox queue, so the chunk 4 sentence may simply be stale; I did not trace the runtime to confirm the walk is implemented.

### 349. Tooling and proof (formal-verification tooling, IDE and developer-experience surface, tighter emission) has not landed

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 8, about line 138
- **Recorded as:** "Each tool lands with its own trials or diagnostics"
- **Why undecided:** No formal-verification tool or proof checker exists in `compiler/src`; the closing condition is general, so I could not decide which parts count as done. The direct machine-object emitter is only a design (`direct_machine_object_emitter_future.md`).

### 350. Chunk 14 chip features: memory spaces are delivered for the ESP32-S3 and Nucleo, but the remaining spaces and the §21 chip-specific behaviours are not recorded as delivered or not applicable

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 14, about line 143
- **Recorded as:** "Each raw path's port notes list every item as delivered with trials or as not applicable"
- **Why undecided:** Status covers memory spaces only (`b9bdc0d547`, trials `memory_space_*_addition`); I did not look in the port notes for a §21 list.

### 351. Chunk 15 phase 10 on the Mac records a fixed point but no gen3 byte-identical to gen2 (only the two Linux compilers record it)

- [ ] reviewed
- **Document:** ROADMAP.md, chunk 15, about line 144
- **Recorded as:** "the Mac reached a fixed point (`bddbec327c` records no more), and gen3 byte-identical to gen2 is recorded only for the two Linux compilers"
- **Why undecided:** Whether the missing byte-identity record is a gap or only an unrecorded fact needs Lee; I only read the note.

### 352. The use-tree first pass (parse only the declarations up to the first function, then exit 75) is recorded as not implemented

- [ ] reviewed
- **Document:** compiler/design_documents/README.md, entry for Phase2_TODO/use_tree_first_pass.md, about line 266
- **Recorded as:** "design; not implemented as of 2026-10-16"
- **Why undecided:** I read only the document's own status; `main_driver_first.silica` exists but I did not trace whether it stops at the first function, and that file is another agent's.

### 353. Per-space pools, alloc_region space routing and atomic LDAR/STLR access are recorded as not implemented for the AArch64 memory-effects plan

- [ ] reviewed
- **Document:** compiler/design_documents/README.md, entry for memory-effects-aarch64-implementation-plan.md, about line 284
- **Recorded as:** "per-space pools, `alloc_region` space routing and atomic `LDAR`/`STLR` access are not (status table at its top)"
- **Why undecided:** ROADMAP chunk 14 records barriers on the ESP32-S3 and Nucleo only; I did not read the Apple and Linux emitters for LDAR/STLR, and the plan is another agent's.
