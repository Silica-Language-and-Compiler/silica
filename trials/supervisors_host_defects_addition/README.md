# supervisors_host_defects_addition

Hosted twins of the board defect trials in `supervisors_board_defects_addition`, kept in a suite of their
own so that their atoms do not renumber the assembly goldens of `supervisors_addition`. Each trial's golden
is the output the fixed compiler prints; the suite runs on every hosted target.

| Trial | Defect |
| --- | --- |
| `supervisor_ref_survives_ten_calls` | code generation, fixed 2026-10-09 in all four emitters: a `supervisor_ref` bound in `main` and used in a `call_supervisor` after ten `call_registered` calls reached the prim as garbage (the nested let `call_supervisor` lowers to reused the reference's callee-saved register for the count once all ten were bound; on the Mac the following `:terminate_child` faulted in `os_unfair_lock_lock`, status 70). Every let RHS now keeps the bound callee-saved registers (`_keep_cs`). |

Run: `make -C supervisors_host_defects_addition integrate` (host), or `make integrate TRIAL_SUITES=supervisors_host_defects_addition` from `trials/`.
