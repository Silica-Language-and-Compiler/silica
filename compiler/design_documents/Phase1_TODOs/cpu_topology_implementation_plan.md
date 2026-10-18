# CPU Topology Implementation Plan

**Audience / scope:** Treat this file as the **Apple Silicon + macOS** implementation record for sysctl-backed **`_silica_rt_*` topology and `core_capabilities`** in the emitter (`prims_actors_runtime_asm.silica`). **Phases A–C** (ABI freeze, lexer, parser) describe **shared** compiler work and are not CPU-specific; **Phase G “complete” status, §Runtime contract, and all sysctl / NUMA / cache specifics apply only to Apple Silicon.** Portable or non-Apple targets are **not** covered here—use a separate plan or backend when adding them.

**Date**: April 9, 2026 (implementation status added 2026-10-16)  
**Status**: Phases A–C complete; **Phase G (emitter) complete on Apple Silicon + macOS** for `_silica_rt_get_cpu_topology` and `_silica_rt_get_core_capabilities` (see §Runtime contract). Phases D–F and H remain (typing/SIR/effects parity and verification). Non–Apple-Silicon targets are **not** implemented in this path (ignored for now; no Makefile churn).  
**References**:

- [silica-specification.md](../silica-specification.md) — §4.6 core affinity types, §22 actor builtins, CPU affinity appendix (`cpu_topology`, `core_info`, `get_cpu_topology`, `get_efficiency_cores`, `get_performance_cores`, `get_core_capabilities`)
- [silica-compiler-code-organization.md](../silica-compiler-code-organization.md) — where lexer/parser/checkers/SIR/emitter modules live

> **Implementation status (2026-10-16).** The Apple Silicon + macOS path described below is unchanged. Since this plan was written the same
> surface exists on the other targets, each in its own runtime:
>
> - **linux_aarch64 and linux_x86_64:** `silica_rt_get_cpu_topology` and `silica_rt_get_core_capabilities` use the same heap layout as the Apple path and read their numbers through a `silica_rt_sysctlbyname` shim in `linux_rt_shims_asm.silica` (answers from `sysconf`/`getauxval(AT_HWCAP)` on aarch64 and `sysconf`/`cpuid` leaves 1 and 7 on x86-64; unknown keys return -1). The Apple-specific wording below (sysctl, `hw.optional.*`) describes the keys the code asks for, not a macOS requirement.
> - **ESP32-S3_raw:** `rt_actors.S` builds `core_info` records and the `cpu_topology` record for the two LX7 cores: both `:performance`, no efficiency cores, empty NUMA list, empty cache hierarchy, `frequency_mhz` 0; an id at or above the core count (or negative) gives the `id: -1` sentinel. `get_performance_cores()` lists every running core and `get_efficiency_cores()` is empty.
> - **Phase H:** unchanged in substance. `trials/cpu_discovery_and_spawn_pinning` is still `INTEGRATE_PENDING` on every target. The two spawn trials (`cpu_spawn_third_arg_affinity`, `cpu_spawn_third_nonliteral_affinity`) have .ascomp goldens per host; `cpu_topology_runtime_queries` and `cpu_topology_phase_h_verify` were reported in `ports/esp32s3_port_status.md` (2026-09-28) as not compiling on any target (E2015, the pre-`mem(normal)` list syntax). The blocker stated in Phase H (emitter stubbing `main` for `sequence proc[concurrency]` bodies) is not re-verified. `phase_h_static.sh` still checks only the Apple runtime source.
> - **Spawn core argument:** the third argument is a `uint64` or `core_id(n)`; the pinning rule is the Actor Pinning Policy of the specification §15.1.2 (see [actor_spawn_core_affinity_os_semantics.md](../actor_spawn_core_affinity_os_semantics.md)).

---

## Objective

Deliver **end-to-end compiler and runtime support** for **structured CPU topology discovery** so user code can call `get_cpu_topology()` and obtain a real `cpu_topology` value (not a stub), use `get_core_capabilities(core_id)` per spec, and pass a chosen **`uint64`** core id as `spawn`'s optional third argument. The list helpers `get_efficiency_cores()` / `get_performance_cores()` are already implemented in the AArch64 runtime; this plan focuses on closing the **`cpu_topology` / `core_info`** path and any remaining **placement / typing** gaps.

---

## Current State (snapshot)

| Area | Status |
|------|--------|
| Lexer | Keywords and token kinds exist for `get_cpu_topology`, `get_efficiency_cores`, `get_performance_cores`, `get_core_capabilities`. |
| Parser | Actor capability surface includes these names; spawn affinity parsing follows existing placement rules. |
| Type checker | Nullary topology helpers typed; `get_cpu_topology` → `cpu_topology`. |
| Effect checker | Topology helpers allowed under the same concurrency / actor rules as other runtime helpers. |
| SIR generator | Lowers `get_cpu_topology` / `get_*_cores` to actor-runtime prims. |
| Emitter | **Apple Silicon**: `_silica_rt_get_cpu_topology` builds a heap **`cpu_topology`** (cores, NUMA, cache hierarchy) per Phase A layout; `_silica_rt_get_core_capabilities` returns **`core_info`** or a **failure sentinel** (see below). Success-path **`capabilities`** come from sysctl **`hw.optional.*`** (see §Runtime contract); **`frequency_mhz`** is **0** (not reported via sysctl). Still emits `_silica_rt_get_efficiency_cores` / `_silica_rt_get_performance_cores` as before. |

**Remaining gaps**: Phases **D–F** may still need alignment passes (spawn typing, SIR, effects) independent of the Apple emitter. **`core_info.frequency_mhz`** from a **non-sysctl** source (e.g. IOKit) is not implemented. **Phase H** (trials, goldens, bootstrap parity) not done. Other AArch64 targets without the Apple sysctl path are unchanged until separately implemented.

---

## Phase A — ABI and type layout freeze

**Status**: **Complete** — `silica-specification.md` §22.10 and the implementation contract in this document are frozen for the Apple Silicon + macOS path.

**Goal**: Fix the **canonical layout** of `cpu_topology`, `core_info`, `core_type`, and any nested lists so later phases do not churn.

**Tasks**

1. Reconcile [silica-specification.md](../silica-specification.md) appendix structs with the **actual** Silica representations used in the type checker (`cpu_topology` as a named type with field accessors or tuple decomposition).
2. Document **field order**, **list representation** (`List[...]`), and **integer width** for core ids and frequencies.
3. Decide whether `get_cpu_topology` is **pure** at the language level vs. requires effects; align effect checker and spec in one pass.

**Primary artifact**: Spec sections + the Runtime contract section in this plan.

**AALang tool**: Use the phase-planning and specification-driven workflow; no single codegen tool owns this—**human + spec**.

---

## Runtime contract (Apple Silicon + macOS, emitter)

The following is implemented in `src/emitter/apple_silicon_mac/terms/prims/prims_actors_runtime_asm.silica` and related atom table code. It is the reference for user code and later spec text.

**Scope.** Only **Apple Silicon** hosts running **macOS** use this sysctl-based path. Other CPUs or OSes are **out of scope** for the current implementation (no behavioral guarantee; not a build matrix expansion).

**`core_type` atoms.** The runtime uses exactly **`:efficiency`** and **`:performance`** (pre-seeded at fixed atom indices in `atom_table.silica`); arbitrary tags are not used for these two cases.

**`get_core_capabilities` failure.** On sysctl failure, invalid `core_id`, allocation failure on the normal path, or negative core id, the runtime returns a **heap-allocated sentinel** `core_info`: **`id == -1`**, **`core_type == 0`** (same representation as `:efficiency`’s index—callers must use **`id < 0`** to detect failure), empty capabilities, **`frequency_mhz == 0`**. **`NULL` is returned only if allocating the sentinel block fails** (OOM).

**Success-path `frequency_mhz` and `capabilities` (macOS sysctl).**

- **`frequency_mhz`:** Public **`sysctl`** on Apple Silicon does **not** expose per-core or per-cluster **CPU clock rate** in MHz (keys such as **`hw.cpufrequency`** are absent on typical arm64 macOS builds; **`hw.tbfrequency`** is the **timebase**, not core GHz). The reference emitter therefore sets **`frequency_mhz = 0` on success** to mean **“not reported via this interface.”** It is **not** a failure indicator when **`id >= 0`**. A future implementation may fill this from **IOKit** / AppleARMIODevice or another stable API without changing the **`id < 0`** failure rule.
- **`capabilities`:** A **cons list** of null-terminated **C string** pointers (Silica `string` interop) for each **`hw.optional.*`** feature that reads as **1**. Each element’s text is the sysctl name with the **`hw.`** prefix removed (e.g. **`hw.optional.neon`** → **`optional.neon`**). Keys are queried in **lexicographic order** of the full sysctl string; the list is built so **head-first** order matches that sort (**`optional.AdvSIMD`** before **`optional.arm.FEAT_AES`**, …). The exact key set is fixed in **`_silica_rt_apple_hw_optional_caps_list`** (subset of **`hw.optional.*`** / **`hw.optional.arm.FEAT_*`** on Apple Silicon). **`get_cpu_topology().cores[*]`** shares the **same** capabilities list pointer for every core (machine-wide flags). Missing or zero-valued keys are omitted.

**`cpu_topology` caches.** Cache levels are built from **`sysctlbyname`**: when **`hw.nperflevels` ≥ 2**, per-cluster sizes use **`hw.perflevel0.*` / `hw.perflevel1.*`**; otherwise aggregate **`hw.l1dcachesize`**, **`hw.l2cachesize`**, **`hw.l3cachesize`**, plus **`hw.cachelinesize`**. **System-level cache (SLC) / unified last-level cache** is **not** exposed as a reliable separate sysctl “L3”; associativity is not available from these keys (stored as **0** where applicable).

**NUMA / `memory_range`.** A **single** NUMA node is reported. **`size`** is **`hw.memsize`** (bytes). **`start`** is **0** as the **domain origin** in this layout—macOS sysctl does **not** expose a per-node physical DRAM base. **`latency`** is **0** meaning **local self-distance** (ACPI SLIT-style **relative** units for same-node access), **not** an OS-reported picosecond latency.

---

## Phase B — Lexer

**Goal**: Ensure **all tokens** needed for topology and spawn placement exist and stay consistent.

**Tasks**

1. Audit `lexer_keywords.silica` and `lexer_token_kind.silica` for `core_id`, `core_set`, `performance_cores`, `efficiency_cores`, and affinity builtins; add token kinds **only** if spec introduces new spellings or constructors.
2. Keep numeric **token kind IDs** stable or document migration if values must change.

**Files (typical)**: `src/lexer/lexer_keywords.silica`, `src/lexer/lexer_token_kind.silica`

**AALang tool**: [`../../compiler-building-tools/silica-lexer-code-generator.jsonld`](../../compiler-building-tools/silica-lexer-code-generator.jsonld)

---

## Phase C — Parser (capabilities)

**Goal**: Parse **spawn’s optional third argument** and **call sites** of topology builtins without ambiguity.

**Tasks**

1. Extend or verify `parser/capabilities/capability_actors.silica` (and related expression parsers) for `core_id(...)`, `core_set([...])`, and grouping atoms.
2. Ensure `get_core_capabilities(expr)` arity and argument types match the AST shape the type checker expects.

**Files (typical)**: `src/parser/capabilities/capability_actors.silica`, constraint extractors if placement forms carry attributes

**AALang tool**: [`../../compiler-building-tools/silica-parser-code-generator.jsonld`](../../compiler-building-tools/silica-parser-code-generator.jsonld)

---

## Phase D — Type checker

**Goal**: **Sound typing** for topology types and spawn affinity **together** (no drift between third-argument forms and `cpu_topology` fields).

**Tasks**

1. `type_checker_expressions.silica` (and helpers): validate `get_core_capabilities(core_id: int)` → `core_info` (or spec-equivalent type string).
2. Tuple decomposition / field access for `cpu_topology` and `core_info` if users bind or pattern-match results (`type_checker_tuple_decompose_helpers.silica`).
3. Spawn third-argument typing: **`uint64`** (or `core_id(uint64)` only); reject lists, `core_set`, and grouping atoms.

**Files (typical)**: `src/type_checker/expressions/type_checker_expressions.silica`, `type_checker_tuple_decompose_helpers.silica`, `type_checker_expressions_actors.silica`

**AALang tool**: [`../../compiler-building-tools/silica-typechecker-code-generator.jsonld`](../../compiler-building-tools/silica-typechecker-code-generator.jsonld)

---

## Phase E — Effect checker

**Goal**: Correct **effect signatures** for topology discovery vs. actor operations.

**Tasks**

1. Confirm whether `get_cpu_topology` / `get_core_capabilities` are **pure** runtime functions per spec appendix; align `effect_checker_core.silica` and `effect_checker_capabilities.silica` with the chosen rule.
2. Keep error messages pointing at spec sections when `proc[concurrency]` is required for mixed blocks.

**Files (typical)**: `src/effect_checker/effect_checker_core.silica`, `src/effect_checker/effect_checker_capabilities.silica`

**AALang tool**: [`../../compiler-building-tools/silica-effect-code-generator.jsonld`](../../compiler-building-tools/silica-effect-code-generator.jsonld)

---

## Phase F — SIR generator

**Goal**: Lower topology calls to **SIR prims** that carry enough information for the emitter to allocate and fill **structured** results.

**Tasks**

1. `sir_generator/terms/actor_calls.silica` and `terms.silica`: if `get_cpu_topology` returns a **structured** type, ensure the prim or sequence of prims matches emitter expectations (may differ from simple nullary runtime call).
2. Add or reuse **SIR terms** for constructing `cpu_topology` from runtime buffers if the ABI uses a two-step (query + fill) pattern.

**Files (typical)**: `src/sir_generator/terms/actor_calls.silica`, `src/sir_generator/terms/terms.silica`

**AALang tool**: [`../../compiler-building-tools/silica-sir_generator_builder.jsonld`](../../compiler-building-tools/silica-sir_generator_builder.jsonld)

---

## Phase G — Emitter

**Status**: **Complete (Apple Silicon + macOS)** — `_silica_rt_get_cpu_topology` and `_silica_rt_get_core_capabilities` build structured values per Phase A; see **Runtime contract** above. Other emitter backends / non-Apple paths are unchanged.

**Goal**: **Correct AArch64** for `_silica_rt_get_cpu_topology` and **`get_core_capabilities`**, including list and struct construction helpers.

**Tasks**

1. ~~Replace the stub in `prims_actors_runtime_asm.silica` that returns **0** with logic that builds `cpu_topology` per Phase A ABI~~ **Done** (Apple path: sysctl for core counts, `hw.memsize`, cache levels helper, cons-backed lists).
2. ~~Implement or complete `_silica_rt_get_core_capabilities`~~ **Done** (sysctl for P/E split; **sentinel** `core_info` on failure per Runtime contract).
3. **`prims_actors.silica`**: structured returns use **pointer in x0** (AAPCS); documented in source comments.

**Follow-up (not Phase G)**: Fill **`frequency_mhz`** from **IOKit** (or similar) if desired while keeping sysctl **`capabilities`**; add non-Apple emitters if needed without changing Makefiles ad hoc.

**Files (typical)**: `src/emitter/apple_silicon_mac/terms/prims/prims_actors_runtime_asm.silica`, `prims_actors.silica`, `src/emitter/apple_silicon_mac/atoms/atom_table.silica`

**AALang tool**: [`../../compiler-building-tools/silica-emitter_builder.jsonld`](../../compiler-building-tools/silica-emitter_builder.jsonld)

---

## Phase H — Verification

**Status**: **Complete (static)** — runtime **assembly** is checked in; **binary** golden trials for `get_cpu_topology` / `get_core_capabilities` remain **blocked** until the emitter lowers **`sequence proc[concurrency, …]`** bodies for `main` (today’s `.sams` stubs `main` to a constant atom return, so integrate `.scout` lines like `print_int64` never run).

**Goal**: Guard the Apple Silicon topology implementation and document what full trials need.

**Tasks**

1. **Static verification** — `trials/cpu_discovery_and_spawn_pinning/phase_h_static.sh` greps `prims_actors_runtime_asm.silica` for `_silica_rt_get_cpu_topology`, `_silica_rt_get_core_capabilities`, `_silica_rt_apple_hw_optional_caps_list`, cache builder, **`L_cap_emit_sentinel`**, and representative sysctl strings. Run: `make -C trials/cpu_discovery_and_spawn_pinning phase-h` (from `compiler`).
2. **Trials source** — `cpu_topology_runtime_queries.silica` and spawn affinity trials remain guarded by **`INTEGRATE_PENDING`** until the project intentionally treats these host-specific runtime values as normal golden output (see `trials/cpu_discovery_and_spawn_pinning/README.md`).
3. **Bootstrap parity** — deferred: compare against `silica-bootstrap-compiler` topology when both pipelines emit real `main` for actor topology calls.

---

## Dependency order

```text
A (ABI freeze) → D/F/G (type + SIR + emitter depend on layout)
B → C → D → E → F → G
H last (uses stable surface)
```

---

## Related AALang tooling (index)

| Compiler area | Tool JSON-LD |
|---------------|----------------|
| Lexer | `compiler-building-tools/silica-lexer-code-generator.jsonld` |
| Parser | `compiler-building-tools/silica-parser-code-generator.jsonld` |
| Type checker | `compiler-building-tools/silica-typechecker-code-generator.jsonld` |
| Effect checker | `compiler-building-tools/silica-effect-code-generator.jsonld` |
| SIR generator | `compiler-building-tools/silica-sir_generator_builder.jsonld` |
| Emitter | `compiler-building-tools/silica-emitter_builder.jsonld` |
| Cross-phase planning | `compiler-building-tools/silica-compiler-phase-planning-tool.jsonld` |
