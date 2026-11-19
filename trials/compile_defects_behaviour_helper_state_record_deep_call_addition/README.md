# compile_defects_behaviour_helper_state_record_deep_call_addition (INTEGRATE_PENDING)

Open runtime defect on the hosted emitters (found 2026-11-10 while fixing the same convention on
STM32-L476RG_raw, see `../behaviour_case_arm_helper_state_record_addition`). The program compiles; its
output is wrong. Not a compile defect: the directory name follows the `compile_defects_<slug>_addition`
convention only so that no other suite shares it.

Cause (diagnosis, matches the STM32 fix in `emitter_core.silica` `fn_epilogue_adopts`): a behaviour-shaped
function (`(:no_reply, S)` / `(:reply, R, S)`) gets the non-adopting epilogue on the Mac and Linux emitters,
so when a behaviour binds a helper's `(:no_reply, record)` result and then makes any further call, the
record (built in the helper's frame part) lies below the caller's SP and is overwritten. The second
dispatch then prints a state with garbage fields.

- `helper_state_record_prints`: helper builds a 4-word record literal, the behaviour binds the result,
  prints (the prints are the "deeper calls"), returns it. Fails on its own, with no recursion.
- `helper_state_record_deep_recursion`: same with `deep(6)` and `deep(9)` (recursive frames) between the
  bind and the return.
- `helper_state_record_by_name`: the behaviour (`keeper`) tail-calls `settle(state, 1)` with the whole state
  record (an `actor_ref`, a string built by `concat` in `arm`, an `int64`) passed BY NAME; `settle` builds the
  new record in its own frame (after printing and casting to the peer) and returns `(:no_reply, record)`.
  Distilled from the transport_addition `dangerous_link_dial_link_up_text` fault (exit 70, garbage string
  pointer). Expected: `seen=1 expect=key:7` .. `seen=3 expect=key:7`, `done`, `0`.
- `helper_state_nested_record`: nested record state (`in: { x, y }`) with a 8-word-local helper and
  `deep(20)` between the bind and the return.

| today (Mac host, silica-999926, 2026-11-10) | `.scout` (correct behaviour) |
|---|---|
| second dispatch prints `1 2 3 <garbage>` (prints), `1 <garbage> <garbage> <garbage>` (deep recursion, nested) | `0 0 0 0`, `1 2 3 4`, `2 4 6 8`, `DONE`, `0` (a `66` line after each state line in the recursion trial) |

Controls that pass today: the same behaviour with a helper returning the plain record (not
behaviour-shaped) and building `(:no_reply, r)` itself; a helper that builds its record through a `mk` constructor, with two
8-word-local calls between bind and return, also survived (the record is not always reached), so a pass is not proof of absence.
The `.scout` files are hand-derived (state advances by 1, 2, 3, 4 per dispatch; `deep(6) + deep(9) = 66`).
No `.ascomp`: generate the goldens only after the fix, from correct output.

Fix to apply on each hosted emitter: the STM32 change (`fn_epilogue_adopts` true for behaviour-shaped
functions; the actor runtime's dispatch puts SP back itself after the dispatch end places the state).

Status (2026-11-15): the defect was fixed in the hosted `fn_epilogue_adopts` (apple_silicon_mac, linux_aarch64
and linux_x86_64 emitters, matching the boards). Verified on the Mac with the three programs above plus
`helper_state_record_by_name`; still UNVERIFIED on Linux (pix, nix). The move into `actors_addition` and the
deletion of this directory wait for Linux verification.

Run by hand from `trials/` (INTEGRATE_PENDING keeps it out of tree-wide runs):

```
make -C compile_defects_behaviour_helper_state_record_deep_call_addition integrate TRIAL_TARGET=host SILICA_COMPILER=/Volumes/2T/silica/binaries/silica-compiler
```

When it passes on every hosted target, move the four programs into `actors_addition` with goldens and
delete this directory.
