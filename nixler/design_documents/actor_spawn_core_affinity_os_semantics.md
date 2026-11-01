# Actor spawn on a specified core — OS semantics

## High-level picture

In Silica, **`spawn`** may carry an optional third argument: a **`uint64` logical core id** or **`core_id(n)`** with **`n: uint64`** (see the specification §15.1.1 and §22.10). At runtime, that intent must be lowered to whatever the host OS exposes: thread affinity, processor binding, CPU sets, and so on. **Lists, ranges, `core_set`, `performance_cores`, and `efficiency_cores` are not supported** for this parameter; pick one id (for example from topology helpers) and pass it as `uint64`.

**Important separation:**

1. **Language / runtime intent:** “Prefer or restrict execution so this actor’s work tends to run on logical CPU *n*.”
2. **OS mechanism:** Usually “set **affinity** or **binding** on one or more **kernel-schedulable threads** that carry the actor.”
3. **Strength of guarantee:** From **hard eligibility** (“this thread may run only on these logical processors”) down to **advisory placement** (“scheduler may try to group threads for cache locality”).

No mainstream OS gives user space a perfect, eternal “this **actor** owns core3” invariant when actors are **multiplexed** onto a **pool of pthreads** (or similar): affinity applies to **OS threads**, and lightweight actors ride along with whichever worker runs them.

---

## Implementation status (2026-10-16)

- **Pinning policy.** The normative rule is the Actor Pinning Policy of [silica-specification.md](silica-specification.md) §15.1.2: every actor is pinned from spawn to termination, the runtime never moves an actor on its own, and only `migrate_actor()` changes the core. On OS-hosted targets "pinned" means bound to the carrier thread for the logical core, with the OS affinity request as a best effort (this document's subject); on OS-free targets pinning is exclusive and hard. Sections below that speak of "carrier threads" and "advisory placement" describe the OS-hosted case.
- **macOS (Apple Silicon).** Implemented as described: the runtime calls `thread_policy_set` with `THREAD_AFFINITY_POLICY` (`prims_actors_runtime_asm.silica`, apple_silicon_mac); it is a hint.
- **Linux (aarch64 and x86-64).** The Linux runtimes keep the Darwin-era entry name `silica_rt_thread_policy_set` as a shim in `linux_rt_shims_asm.silica` (both trees): the affinity tag is turned into a `pthread_setaffinity_np` mask (tag 0 clears the restriction to all CPUs). The runtime does not call `sched_setaffinity` directly.
- **ESP32-S3 (OS-free).** Both LX7 cores run actors; an actor pinned to core 1 runs on the APP cpu and nowhere else; `0` is runtime-assigned (round robin); `migrate_actor(ref, 5)` on a two-core chip answers `:invalid_target` (see [ports/esp32s3_port_status.md](ports/esp32s3_port_status.md)).
- **Other OSes (FreeBSD, Solaris/illumos, Windows).** No backend exists; the sections for them are reference material for a future port.

---

## Mental model for implementers

### Carrier threads vs. actors

If the runtime uses **M pthreads** to run **N actors** (N ≫ M), then:

- **Affinity calls affect the pthread** (or the process default that new threads inherit), not each logical actor.
- **Migration of a pthread** implies any actor work running on that pthread **moves with it** until the runtime reassigns work to another worker.

Document user-visible behavior accordingly: “core placement” is **at best** accurate for **scheduler threads**, unless the design is **one OS thread per actor** (unusual for lightweight actors).

### Logical processor vs. physical core

Most APIs bind to **logical processors** (hardware threads): one bit or id per **LP**, not necessarily per **physical core**. Two LPs may share execution units (**SMT / hyper-threading**). “Specified core” in Silica may map to a **logical id** from topology discovery; that id is only as stable and meaningful as the platform’s enumeration (firmware, hotplug, group policies).

### Intersection with other constraints

Effective runnable CPUs are often the **intersection** of:

- User-requested affinity mask / binding
- **Process** affinity (parent job, launcher)
- **cgroup / cpuset** (Linux), **resource groups** (Windows), **jail / cpuset** (FreeBSD), **processor sets** (Solaris family)
- **Dynamic** hotplug, sleep states, and **firmware** quirks

So “spawn on core *k*” can still fail, clamp, or behave differently under container orchestration even when the syscall succeeds.

---

## Platform-by-platform detail

The following sections name the **typical** APIs and **semantic class** (hard mask vs. hint). Exact behavior must be validated per kernel version and vendor documentation when implementing a backend.

### macOS (Darwin / XNU)

**Primary thread-side knob (historical / policy-based):** `thread_policy_set` with **`THREAD_AFFINITY_POLICY`**.

- In Apple’s headers this policy is described as **experimental**. Affinity is framed as a **hint** to the scheduler for **placement**, with tags used so threads that share a tag may be placed to **share an L2 cache when possible**—**not** as “this thread must never leave LP *n*.”
- The scheduler may still **migrate** threads for load balancing, **QoS**, thermal policy, and **P-core / E-core** decisions. Apple’s public guidance emphasizes that threads may run on **both** performance and efficiency cores over time as the system weighs app input, observed workload, and global state.

**Contrast with typical “CPU mask” OSes:** macOS’s tag / affinity **policy** is closer to **placement bias** than to **exclusive CPU ownership**.

**Silica compiler context:** The [cpu_topology_implementation_plan.md](Phase1_TODOs/cpu_topology_implementation_plan.md) documents the **sysctl-backed** topology and **`core_info`** path for **Apple Silicon + macOS** in the current emitter. The mapping of Silica **`core_id`** values to `THREAD_AFFINITY_POLICY` is implemented and is **best-effort affinity**, not strict pinning, unless Apple documents a stronger contract for a specific API in use.

**Practical summary for users:** On macOS, treat **`spawn(..., core)`** as **influencing** where carrier threads run, with **no guarantee** of immovable binding to one LP or one physical core.

### Linux

**Primary APIs:** `sched_setaffinity(2)` / `pthread_setaffinity_np(3)` with a **`cpu_set_t` mask**.

**Semantic class:** The affinity mask defines the set of CPUs on which the thread is **eligible** to run. The kernel’s CFS scheduler **does not** place the thread on CPUs outside that set (subject to further restrictions below). This is **substantially stricter** than macOS’s experimental affinity **policy** wording: it is a **hard restriction** to the allowed set, not merely a cache-locality hint.

**Interactions:**

- **`cpuset` cgroups** and **`taskset`** may further **narrow** the effective set (intersection).
- **NUMA:** Schedulers try to respect memory locality; affinity and **`numa_run_on_node`**-style policies interact.
- **Isolation:** `isolcpus=` and **real-time** setups change who may run where but do not change the basic “mask = eligibility” model.

**Practical summary:** Pinning to a **single** LP is **meaningful and enforceable** at the scheduler level for that thread, modulo cgroup and process masks. It is still **not** “actor ownership” if many actors share one pthread.

### FreeBSD

**Primary mechanisms:** **`cpuset(2)`** family and **`pthread_setaffinity_np(3)`** (sets a **`cpuset_t`** id or mask depending on API usage).

**Semantic class:** Similar to Linux: affinity restricts which CPUs a thread **may** use. Effective placement is again the **intersection** with jail / cpuset / parent restrictions.

**Practical summary:** Comparable to Linux for planning purposes: **mask-style restriction**, not macOS-style “experimental hint” policy text for the primary affinity APIs.

### Solaris and illumos

**Traditional APIs:** **`processor_bind(2)`**, **`pbind(1)`**, and **processor sets** (`psrset` / `PSET_*`).

**Semantic class:** Binding a lightweight process (LWP) or thread to a CPU or processor set is a **hard scheduling constraint** in the usual model: the bound entity runs **only** on processors in the set until the binding is changed.

**Practical summary:** Strong **binding** semantics are the norm; still subject to **permission**, **privilege**, and **administrative** processor-set configuration.

### Windows

Two different concepts should not be conflated:

| API | Role |
|-----|------|
| **`SetThreadAffinityMask`** / **`SetThreadGroupAffinity`** / **CPU sets** (`SetProcessDefaultCpuSets` / `SetThreadSelectedCpuSets`, etc.) | Define which **logical processors** the thread **may** run on. Documentation describes **rescheduling** if the current processor is not in the mask. This is **restriction / eligibility**, not a mere cache hint. |
| **`SetThreadIdealProcessor`** | Expresses a **preferred** processor; the scheduler **may** ignore it under load. This is **closer to a hint**. |

**Processor groups:** On machines with many logical processors, affinity is scoped to **groups**; masks must be consistent with process and group rules (see Microsoft’s “Processor Groups” documentation).

**Practical summary:** Use **affinity mask / CPU set** APIs when Silica needs **hard restriction** to a set of LPs; use **ideal processor** only when a **soft** preference is acceptable. Neither model assigns **per-actor** affinity without **per-thread** carriers.

---

## Comparison table (spawn / carrier thread)

| OS | Typical API class | “Specified core” strength | Migrates off requested LP? |
|----|-------------------|---------------------------|----------------------------|
| **macOS** | `THREAD_AFFINITY_POLICY` (tag / hint) | **Placement bias**, not strict ownership | **Yes**, system may migrate for QoS, thermals, P/E policy |
| **Linux** | `sched_setaffinity` / `pthread_setaffinity_np` | **Hard** eligibility set (intersect cgroup/cpuset) | **Not** to LPs outside mask; **yes** within mask |
| **FreeBSD** | `cpuset` / `pthread_setaffinity_np` | **Hard** eligibility set (intersect jail/cpuset) | Same pattern as Linux |
| **Solaris / illumos** | `processor_bind`, `pbind`, PSET | **Hard** bind to CPU / set | **No** migration outside binding |
| **Windows** | Affinity mask / CPU set vs. ideal processor | **Mask = restriction**; **ideal = hint** | Mask: only among allowed LPs; ideal: may differ |

---

## Implications for Silica runtime design

1. **Document honestly:** User-facing docs should distinguish **“affinity / placement”** from **“dedicated core ownership.”**
2. **One mapping per backend:** Each OS port should document: which syscall wraps the **uint64 core id** passed to **`spawn`**, and failure modes (invalid id, permission).
3. **Topology ids:** **`core_id`** from **`get_cpu_topology()`** must use the **same numbering** as the affinity layer on that OS, or the runtime must **translate** between topology enumeration and OS affinity ids.
4. **Testing:** Assertions like “this thread always runs on LP 3” require **OS-specific** probes (`sched_getcpu`, `GetCurrentProcessorNumberEx`, etc.) and are inherently **racy** without kernel cooperation.

---

## References (internal)

- [silica-specification.md](silica-specification.md) — §4.6 core affinity types, §22 actor builtins, spawn placement
- [cpu_topology_implementation_plan.md](Phase1_TODOs/cpu_topology_implementation_plan.md) — Apple Silicon sysctl topology, runtime contract
- [actor_growable_stack_design.md](actor_growable_stack_design.md) — per-actor stacks and NUMA-oriented behavior
- Trials: [../../trials/cpu_discovery_and_spawn_pinning/README.md](../../trials/cpu_discovery_and_spawn_pinning/README.md)

## References (external — verify at implementation time)

- Apple: `thread_policy.h` / `THREAD_AFFINITY_POLICY`, QoS and performance core documentation
- Linux: `sched_setaffinity(2)`, `cpuset(7)`, `pthread_setaffinity_np(3)`
- FreeBSD: `cpuset(2)`, `pthread_setaffinity_np(3)`
- Oracle Solaris / illumos: `processor_bind(2)` and processor-set manuals
- Microsoft Learn: `SetThreadAffinityMask`, `SetThreadIdealProcessor`, processor groups, CPU sets
