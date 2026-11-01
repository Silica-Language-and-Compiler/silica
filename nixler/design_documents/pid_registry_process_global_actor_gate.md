# PID registry: process-global reference, actor-gated table

## Goals

- **Process-global:** one logical registry per OS process. The runtime holds a single word (`_silica_pid_registry_ref` in BSS) naming the registry **actor**.
- **Actor-gated access:** the dense table, overflow list, and regions live **only** in that actor’s behavior state. Application code must use **`get_pid_registry()`** and send **`registry_beh`** messages (`:insert`, `:lookup`, `:delete`). There is no supported Silica module that exports direct `pid_reg_*` entry points alongside user trials.

## Implementation shape

1. **(Original design; the module was removed 2026-10-16.)** `pid_registry_actor.silica` exported only **`registry_beh`**, **`init_pid_registry_get_ref`**, and **`get_pid_registry`**. Table helpers are file-private (`fn` without `export`).
2. **`_silica_pid_registry_init`** (emitter-injected `main` prologue) calls **`init_pid_registry_get_ref`**, spawns the actor with empty table state, and stores the returned **`actor_ref`** in **`_silica_pid_registry_ref`** (see `prims_actors_runtime_asm.silica`).
3. **`get_registry_actor()`** / **`get_pid_registry()`** reads that global slot. Mutations happen only inside **`registry_beh`**, which calls the private helpers.

## Implementation status (2026-10-16)

The goals above hold; the shape differs from the "Implementation shape" section in these points:

- **Three registries, not one.** The runtime spawns an ordinary registry (`_silica_pid_registry_ref`), a dangerous (FFI worker) registry (`_silica_dangerous_pid_registry_ref`) and a device-worker registry (`_silica_device_pid_registry_ref`), so a keyed cast can never reach a worker of another kind. The `main` prologue calls `_silica_pid_registry_init`, `_silica_dangerous_pid_registry_init` and `_silica_device_pid_registry_init` (`emitter_core.silica`, all four targets).
- **The behaviour is runtime assembly.** Each registry actor runs `_silica_rt_pid_registry_beh`, defined in the runtime assembly of each target (`prims_actors_runtime_asm*.silica`, `rt_actors.S` on the ESP32-S3), not a Silica module. The former `runtime_modules/pid_registry_actor.silica` and `pid_register_runtime.silica` (240-slot table plus overflow list, `registry_beh`, `empty_reg`) were never linked by any emitter and were removed from the tree on 2026-10-16. Their table shape is superseded by the one in `atom_actor_registry_direct_index_design.md`.
- **State is one calloc block** of `_silica_registry_slots * 16` bytes (occupancy words, then actor identity words), one slot per atom of the build. The keyed forms (`cast_registered`, `call_registered`, `spawn_registered`'s registration, `register`) read and write that block directly; the actor itself answers `{ op, name, pid }` messages with a `(status, actor_ref)` pair. Status atoms: `:ok`, `:name_taken`, `:already_registered`, `:actor_not_found` (specification §20.3.1).
- **Slots hold identities** (specification §15.1.4); liveness is the identity table's, and a name whose holder has ended is free. The exit path forgets names (`_silica_rt_registry_forget_actor`).
- **`get_pid_registry()`** and `get_registry_actor()` remain builtins; both lower to `_silica_rt_get_registry_actor`.
- **Name of the generic path.** `_silica_rt_register_actor` is still present; `spawn_registered` and `register` use `_silica_rt_register_actor_named` (and the `_dangerous_` / `_device_` variants for the other registries).

## Security / discipline note

Silica does not enforce “no direct memory” at the language level. **Actor gating** is enforced by **not exporting** table primitives from any user-linkable unit and by documenting that the registry actor (`_silica_rt_pid_registry_beh`, reached through `get_pid_registry()`) is the only intended surface. A determined program could still reimplement a table; this design is about **supported** API and clear ownership of global state.

## Related

- **Effects:** only `sequence proc[...] ... produces ... end` carries `proc`; not the function’s `->` return type (see §9.3.1 / E3009).

- `atom_actor_registry_direct_index_design.md` — direct-index + overflow representation.
- Runtime: `_silica_rt_register_actor` also targets `_silica_pid_registry_ref` for the generic “name registry” path; **`_silica_pid_registry_init`** remains the PID-specific bootstrap used by programs that use the PID registry actor.
