---
name: new-silica-project
description: Scaffold a new Silica application. Use when the user says they want a new app, project, program, or service in Silica ("I want a new app", "start a new project", "new silica program"). Interviews the user for the root supervisor's name, its children (each supervisor holds either child supervisors or actors, nested to any depth) with their names, modules and functions, and each supervisor's restart rule, then generates the supervision tree and project skeleton. Never writes the bodies of the actors' behavior functions.
---

# New Silica project

Interview first, generate second. Ask in small rounds (use AskUserQuestion where a closed choice exists, plain questions for names). Do not generate files until the answers are confirmed in a summary.

## Hard rule

**Do not write the logic of any spawned function.** The actor modules get the `export` line, the correct signature, and a body that only returns the state unchanged, marked `// TODO(you): behavior goes here`. No prints, casts, arithmetic, or helper functions. If the user asks you to fill one in, that is a separate request after the scaffold exists.

## Interview

### 1. Project
- Project directory name (default: ask; create under the current working directory, not inside the compiler tree).
- Target platform, if it matters: `apple_silicon_mac`, `linux_aarch64`, `linux_x86_64`, `ESP32-S3_raw`. Hosted targets use the same front end; ESP32 apps may use peek/poke and device actors, hosted ones may not. Ask only if the user hints at hardware.

### 2. Root supervisor
- **Registered name** (an atom, e.g. `:app_supervisor`). Used in `spawn_registered_supervisor`.
- **Impl name** (the identifier in `impl X for Supervisor;`, e.g. `AppSupervisor`). Offer a default derived from the registered name. It also names the root supervisor's module and file (`AppSupervisor.silica`).

### 3. The tree (root's children)
The root supervisor's children are commonly other supervisors, so build the tree top-down. For each supervisor, root included, first ask: "Are this supervisor's children supervisors or actors?" The answer is one or the other for all of that supervisor's children. Then for each child ask, **id first**: get the id answered before asking for the module and function, and offer the module and function names as suggestions derived from that id (id `:stupid_batch` → module `stupid_batch`, function `run_batch`), never from a guess made before the id is known. Do not put the id in the same round as questions whose defaults depend on it.
- **Kind:** already decided by the answer above (`agent_type: :supervisor` for supervisors, `:worker` for actors). Do not ask again.
- **Id** (atom, e.g. `:logging_sup` or `:logger`). For actors this is the registered name used by `cast_registered` / `call_registered`, so it must be unique across the whole program, at every level of the tree.
- **Module** (file name without extension → `<module>.silica`) and **function**, referenced as `module@function`.
  - Actor: the spawned behavior function (e.g. `logger@log`).
  - Supervisor: the module holds that supervisor's own `init` and an exported start function of arity 1 (`<Module>_child_start/1`) that returns the same flags-and-children value; the parent references it as `Module@Module_child_start`.
- **Initial state** value.
- **Restart** (`:permanent` | `:transient` | `:temporary`): `:permanent` restarts on any exit, `:transient` only on abnormal exit, `:temporary` never. Supervisor children are usually `:permanent`.
- **Shutdown** (int64; wait for orderly shutdown). Default `0`.
- **Flavor** (`:plain` default; `:dangerous` only for an FFI worker, whose module name must then start with `dangerous_`).
- Actors only: **message, state and reply types.** Default `msg: int64`, `state: int64`, `(:no_reply, int64)`; offer `(:reply, R, S)` if the actor will be `call`ed.

For every child that is a supervisor, recurse: ask question 4 (its restart rule) and then this question for *its* children, to any depth. Keep a running tree view and show it after each supervisor is finished.

**A supervisor's children are all supervisors or all actors; never a mix.** A list mixing the two does not compile (see Verify). If the user describes a supervisor with both, propose the usual fix: put the actors under a new child supervisor of their own and keep the supervisors as siblings, then confirm the revised tree with them.

**Typing:** the children are written as one list whose element type spells out a `behavior` type.
- Actor children of the same supervisor must share `msg`, `state` and reply types, since they share that `behavior` type. If two actors need different types, say so and offer to unify the types or to place one of them under a small child supervisor of its own.
- A supervisor child's `behavior` is `Module@Module_child_start`, of type `fn(initial_state: int64) -> (flags, children)`, as in `trials/supervisors_addition/phase_e_nested_declarative_supervisor_child.silica`. Sibling supervisors share that type, so their own children lists must have the same type as well.


### 4. Restart rule (one per supervisor, root and nested)
- **Strategy:**
  - `:one_for_one`: restart only the failed child.
  - `:one_for_all`: restart every child when any fails.
  - `:rest_for_one`: restart the failed child and all children declared after it. Declaration order matters, so confirm it.
- **allowed_restart_count** (int64) and **restarts_time_frame** (int64, seconds). More restarts than allowed within the time frame makes the supervisor terminate and the failure escalates to its parent (to stderr for the root). Suggest `3` and `5` if the user has no preference. Remind the user that when a child supervisor gives up, its parent applies its own restart policy for that child.

### 5. Trigger
`main` always does exactly three things: spawn the root supervisor, cast one triggering message to an actor, and run `wait_for_exit()`. Ask:
- **Which actor receives the trigger?** Offer the actors from question 3 by id. It must be an actor, not a supervisor.
- **What is the payload?** It must match that actor's message type. The value is the user's to give; if they are unsure, ask what the message should mean rather than inventing one.

### Confirm
Show the tree as an indented outline. For each supervisor: id, strategy, count/time frame. For each child: id, kind, module@function, types (actors), initial state, restart, shutdown, flavor. Wait for approval or edits.

## Generate

**Layout.** Every supervisor, root and nested, goes in `supervisors/`. Every actor goes in `actors/`. Only `main.silica`, the copied `Supervisor.silica`, the build files and the README sit in the project root. The directory is organisation only: a module's name is its file's basename, so `use IoSup;` and `logger@log` are written exactly as if the files were side by side (verified: the Makefile finds files in subdirectories and the project builds and runs). Module names must still be unique across the whole project.

Use `docs/examples/first_program/` as the template and `docs/learn-silica.md` ("Keep `main` small") as the architectural rule.

1. **The root supervisor gets its own module and file, always: `supervisors/<ImplName>.silica`.** Its code never goes in `main.silica`. It holds:
   - `use Supervisor;` and one `use <module>;` per direct child's module.
   - `impl <ImplName> for Supervisor;`
   - `fn init(initial_state: int64) -> (...)` with the long `Supervisor` trait return type, the root's `flags` record, and the `children` list with one record per direct child. The `behavior` type is written in two places inside `init`; keep them identical to each other and to the children's signatures. In the same two places, the record field `initial_state` has the type of the actor's state, not always `int64`: for an actor with `state: int8` it is `initial_state: int8` (verified: a literal `0` then compiles). The supervisor's own `init(initial_state: int64)` parameter stays `int64`, and a child supervisor's entry stays `int64`. For supervisor children that type is the nested `fn(initial_state: int64) -> (flags, children)` form, copied from the trial above.
   - No `export` and no `_child_start` function: `main.silica` reaches it through `use <ImplName>;` and `spawn_registered_supervisor(<ImplName>, ...)`. (Verified: this compiles and runs.)
2. **`main.silica`**, in the project root, holds only `use <ImplName>;` and `main`, no supervisor code:
   - `fn main() -> int64` is a fixed three-step template, in this order, with nothing else in it:
     ```silica
     fn main() -> int64 {
         sequence proc[concurrency, device_io]
             _: supervisor_ref <- spawn_registered_supervisor(<ImplName>, 0, <:root_name>, stack_policy(0, :keep_last_message));
             _: boolean <- cast_registered(<:trigger_actor_id>, <payload> impl ActorMessage {});
             exit_code: int64 <- wait_for_exit()
         produces
             pure exit_code
         end
     }
     ```
     The `sequence proc[...] … produces pure … end` wrapper is mandatory, not style. Effects are declared on a `sequence`, never on the `fn` signature, and `spawn_registered_supervisor`, `cast_registered` (`concurrency`) and `wait_for_exit()` can only be called from inside one. `main` returns whatever `wait_for_exit()` returned: bind it (`exit_code`) and put that binding in `produces pure`; never a literal like `0`.
     Drop `device_io` from the effect list if unused; effects are declared exactly.
3. **One module per child supervisor**, in `supervisors/`: `use Supervisor;`, `export <Module>_child_start/1;`, `impl <Impl> for Supervisor;`, its `init` (its flags and its children), and `<Module>_child_start` returning the same value as `init`. Follow `trials/supervisors_addition/traits/PhaseENestedChildSup.silica`. This is supervision structure, not actor logic, so write it fully. Recurse for grandchildren.
4. **One module per actor**, in `actors/`: `export <function>/2;` and the function with the agreed signature and the do-nothing body from the hard rule. Add no effects the stub does not use.
5. **Build files.** Copy `project_makefiles/` (`Makefile`, `Makefile.subdir`, `silica_compiler.mk`, `silica_link.sh`, `topo_silica_config.sh`, `subdir_stub.mk`, `platform/`) into the project root and copy `compiler/stdlib/Supervisor.silica` into the project tree. The Makefile generates `silica.config` itself, from the `.silica` files under the project in dependency order with `main.silica` last, so do not hand-write it. It only sees files inside the tree, which is why `Supervisor.silica` must be copied in; without it the compiler stops with `E1009 unknown module in use: Supervisor`.
6. **`README.md`**: the supervision tree as an outline (each supervisor's strategy and limits, each child's restart policy), the build command, and the list of TODO functions the user must write.

## Verify
Run `make SILICA_COMPILER=<repo>/binaries/silica-compiler` in the project (without that variable the Makefile looks for `binaries/` above the project and fails). Report the result faithfully.

Findings from a trial scaffold (root supervisor with a child supervisor holding one actor, on macOS Apple silicon, 2026-10-08):
- Compiling and assembling all units succeeded, and the `main` template with `exit_code` compiled.
- The Makefile's link step used to fail with `Undefined symbols: "_main"` because the compiler emits `main`. `project_makefiles/Makefile` now passes the per-host flags the trials use (macOS `-Wl,-e,main`; Linux `-no-pie -rdynamic -lpthread`). `make` builds and links on macOS, and the program ran and returned `0` after `exit` was typed. The Linux flags are copied from the trials' Linux fragment and have not been run.
- A children list that mixes an actor and a supervisor child is rejected: `E2003 type mismatch: IoSup@IoSup_child_start`, both with the actor `behavior` type and with a `|` union of the two function types. This is why the skill never generates one: each supervisor holds supervisors or actors only.

A stub-only program runs and waits for `exit`; it does nothing visible, which is expected. If the stubs fail to compile, fix the scaffold, never by adding actor logic.

## Other help to offer after the scaffold
Offer, but do not do unprompted:
- A suggested tree shape: group actors that fail together under one supervisor (`:one_for_all`), independent ones under `:one_for_one`, and ordered dependencies under `:rest_for_one`.
- A `FailureReporter` actor registered before everything else (`register_failure_reporter`) so crash reports have a destination other than stderr. See `compiler/tutorials_and_howtos/supervisors_and_failure_reporter_tutorial.md`.
- Trial files (`.silica` + golden) so the project is regression-tested, following `trials/` conventions.
- Message protocol sketch: which actors `cast` which, flagging any `call` cycles (deadlock risk) and suggesting cast-and-cast-back.
- Effect audit of the planned actors (`concurrency`, `device_io`, `mem(...)`).
- Device actors (`spawn_device`) and CPU pinning, for ESP32 or multi-core projects.
