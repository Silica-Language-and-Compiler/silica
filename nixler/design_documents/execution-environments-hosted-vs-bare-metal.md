# Execution environments: hosted vs OS-free

Silica is a **systems language**: it is designed to expose strong, explicit control over memory behavior, effects, and concurrency **when the execution environment allows**. For **ordinary applications running as OS-hosted processes**, **some of that control is necessarily held by the operating system**, not by Silica alone.

1. **Memory effects.** On a mainstream OS, the **memory model visible to your process**—virtual addresses, caching, coherency, and what you can request per allocation—is **bounded by what the kernel exposes**. Silica’s distinct **`mem(Space)` / region** hardware guarantees are **fully specified for OS-free** targets; on OS-hosted targets, the same vocabulary often serves **discipline and API clarity** without promising the same per-space hardware behavior everywhere. Normative detail: [silica-specification.md](silica-specification.md) §12.1.1.0 and related hosting notes; implementation context: [memory-effects-aarch64-implementation-plan.md](memory-effects-aarch64-implementation-plan.md).

2. **Actor / core placement.** On an OS, **binding work to cores** goes through **OS schedulers and thread-affinity APIs**. Silica’s **`spawn` with a core id** is lowered to those mechanisms; strength varies by platform (hint vs restricted mask, migration, thermal/QoS policy). See [actor_spawn_core_affinity_os_semantics.md](actor_spawn_core_affinity_os_semantics.md).

3. **Without a general-purpose OS** (bare metal, firmware, or other environments where Silica’s runtime effectively **owns** the platform contract), limits come from **hardware**, the **runtime and libraries you ship**, and **only the third-party code you choose to trust**—not from a kernel’s process-wide memory and scheduling policies.

What must be added to *implement* an OS-free board (MMIO map/load/store, boot, pools, ELF/firmware) is listed in [porting_for_os_free_targets.md](porting_for_os_free_targets.md).

---

This note is a **non-normative** summary and navigation aid; the [language specification](silica-specification.md) remains authoritative where definitions differ.
