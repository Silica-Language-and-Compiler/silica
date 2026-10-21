# cpu_discovery trials

Silica sources covering **CPU topology / affinity** from `cpu_topology_implementation_plan` (parser Phase C onward): optional third `spawn` argument, nullary topology list helpers, `get_cpu_topology`, unary `get_core_capabilities`.

**Design index:** [compiler/design_documents/README.md](../../design_documents/README.md) — working specs and plans (including [actor_spawn_core_affinity_os_semantics.md](../../design_documents/actor_spawn_core_affinity_os_semantics.md) for OS affinity semantics). Where those documents disagree with each other or with the code, treat it as documentation catching up unless a doc explicitly claims to be normative for that area.

| File | Intent |
|------|--------|
| `cpu_spawn_third_arg_affinity.silica` | `spawn(..., ..., uint64)` third argument (two spawns with literal core ids). |
| `cpu_spawn_third_nonliteral_affinity.silica` | Third argument is a non-literal `uint64` expression (`2 + 3`). |
| `cpu_topology_runtime_queries.silica` | `get_efficiency_cores`, `get_performance_cores`, `get_cpu_topology`, `get_core_capabilities`; walks and prints core id lists. |
| `cpu_topology_phase_h_verify.silica` | Phase H **fixture**: five `print_int64` lines (checks a–e) plus process exit. |
| `cpu_topology_runtime_queries_portable.silica` | The two core-id lists checked without naming a core count (one `.scout` for every host). |
| `cpu_topology_walk_lists.silica` | Walks every list `get_cpu_topology()` answers (cores, capabilities, numa_nodes, memory_ranges, cache levels, shared_cores) with `head`/`remove_head`; 1/0 outcomes only. |
| `cpu_topology_x28_live_across_capabilities.silica` | Ten live bindings (X19..X28) summed across `get_core_capabilities`: the runtime must save X28. |

## Note (golden `.scout` files)

`make integrate` records **`{ ./<binary> 2>&1; echo $?; }`** into `<name>.scout`. Those goldens are **not portable**:

- **`cpu_topology_runtime_queries`**: printed lengths and core ids depend on this machine’s topology (sysctl / runtime lists).
- **`cpu_topology_phase_h_verify`**: lines **c** and **e** are `1` only when `get_cpu_topology()` reports non-empty cores and NUMA metadata; otherwise they may be `0` while other checks still pass.
- **`cpu_spawn_*`**: stdout and exit code depend on **actor runtime** actually executing the `sequence` body; refresh `.scout` after spawn/runtime or emitter changes.

After intentional source or environment changes, regenerate from this directory, for example:

```bash
{ ./cpu_topology_runtime_queries 2>&1; echo $?; } > cpu_topology_runtime_queries.scout
# repeat for each binary, or rely on manual `make integrate` iteration```

## Phase H (verification)

**Static checks** (no binary): from `compiler`, run:

```bash
make -C trials/cpu_discovery_and_spawn_pinning phase-h
```

This runs `phase_h_static.sh`, which asserts that `compiler/src/emitter/apple_silicon_mac/terms/prims/prims_actors_runtime_asm.silica` still defines the sysctl-backed topology/capability symbols and the **`get_core_capabilities`** failure sentinel.

## Build

From this directory (with `binaries/silica-compiler` installed):

```bash
make
# or
make integrate   # diffs .sams vs .ascomp when present; runs and checks .scout
```

## Top-level `trials/Makefile integrate`

While **`INTEGRATE_PENDING`** is present in this directory, the parent integrate target **skips** this folder so missing assembly goldens do not fail the tree. After you add `.ascomp` files for each trial (copy from generated `.sams` when codegen is stable) and confirm `.scout` files, **delete `INTEGRATE_PENDING`** so this directory participates in the full integrate run.
