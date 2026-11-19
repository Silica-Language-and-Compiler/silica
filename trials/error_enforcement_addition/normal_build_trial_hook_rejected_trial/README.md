# normal_build_trial_hook_rejected_trial

The trial hook `supervision_ingress_enqueue` is built only into trial compilers
(`make build TRIAL_BUILD=1`). Every other trial in the tree is compiled by the trial compiler
(`binaries/TRIAL_BUILD_silica-compiler`). The two trials here are compiled by the NORMAL compiler
(`SILICA_NORMAL_COMPILER`, defined in `trials/silica_compiler.mk`: the unpublished
`compiler/build/<target>/silica-compiler` when it exists, else the published `binaries/silica-compiler`).
The parent Makefile passes it to each child as `SILICA_COMPILER`.

| directory | what it checks | golden |
|---|---|---|
| `hook_call_rejected/` | a behaviour that calls `supervision_ingress_enqueue` does not compile in a normal build: E2007 `unknown function: supervision_ingress_enqueue` (spec:sect6) | `hook_call_rejected.golden_fail` (from a real compile) |
| `own_function_same_name/` | a program that defines its own `fn supervision_ingress_enqueue` and calls it compiles and runs: the name is an ordinary function in a normal build | `own_function_same_name.scout` (`42`) |

The two are separate directories so a rejected unit cannot take the run trial down with it.
`own_function_same_name` compares program output only (no `.ascomp`).
Hosted targets only; the board runs do not compile these trials.
