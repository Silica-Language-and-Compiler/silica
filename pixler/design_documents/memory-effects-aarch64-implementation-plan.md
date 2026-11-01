# Memory effects — implementation plan (OS-free boards and embedded targets)

This document implements the **memory space** model from `silica-specification.md` (§9.1.1 `mem(Space)`, §12.1.1, §12.1.1.0, §12.1.1.1, and atomic-ref material) for **OS-free** Silica runtimes. **§12.1.1.0** states that **distinct hardware behavior per `Space` is guaranteed on OS-free systems only**; this plan therefore targets **boards**, **bare-metal**, and **RTOS-free firmware** where the Silica runtime controls the memory map—not portable **macOS / Linux / Windows / Solaris** user processes.

**Primary ISA in the language spec:** AArch64 (§12.1.1.1, `MAIR_EL1`, LDAR/STLR). **Additional board class:** **ESP32-S3** (Xtensa LX7; Espressif IDF-style memory and cache control). Other chips follow the same *pattern*: map each Silica `Space` to that architecture’s **cache / MPU / bus / peripheral** rules.

---

## Implementation status (2026-10-16)

This plan is mostly NOT implemented; it remains the design for OS-free per-space hardware behaviour. What exists:

| Plan item | Status |
| --- | --- |
| Static discipline: `mem(Space)` effects, `region(R, Space)`, `ref`, `buf`, `List[T, Space]`; six spaces accepted | implemented (type checker `type_checker_memory_regions.silica`, effect checker `effect_checker_memory_regions.silica`); trials under `trials/memory_region_addition` |
| `alloc_region(Space)` passes the space to the runtime (section 0.2 item 2, 0.4) | NOT done: the emitters still allocate every region from the same arena and ignore the space operand (`emit_alloc_region` in `emitter/apple_silicon_mac/terms/prims/prims_memory.silica`: "X1 = space (unused)") |
| Atomic `ref` loads and stores as `LDAR`/`STLR` | NOT done: ref and buffer accesses are plain loads and stores for every space; `LDAREX`-style instructions appear only in the hand-written actor runtime assembly |
| `alloc_atomic` | not a builtin; atomic cells are made with `alloc_ref` in a `region(R, atomic)` (`trials/memory_region_addition/alloc_atomic_int64.silica`, requires `proc[mem(atomic), atomic]`) |
| Phase 1 AArch64 OS-free pools, `MAIR_EL1` programming | NOT done; no AArch64 bare-metal target exists. The hosted AArch64 targets are Apple Silicon and Linux AArch64 (OS-hosted: discipline only, section 12.1.1.0) |
| Phase 1.2 / 2.2 ESP32-S3 | the ESP32-S3 port is native Xtensa, bare metal, with no IDF: code, data, heap and stacks all live in internal SRAM (about 390 KB), no PSRAM, no `heap_caps` or DMA pools, no `sdkconfig`. Per-space pools and cache modes are NOT implemented; see `ports/esp32s3_port_status.md` and `actor_memory_budget_plan.md` for the memory model that is |
| Phase 3 list allocation on the same space | lists take their space from the type; audit against per-space pools not applicable until pools exist |
| Phase 4 CI matrix `board` x `space` | none; trials run per target (Apple Silicon, Linux AArch64, Linux x86-64, ESP32-S3 board) without per-space attribute checks |

Read the Phase sections below as the design target. References to the IDF, `heap_caps_malloc` and `sdkconfig` in section 1.2 describe an IDF-based port that was not the one built.

---

## Goals

1. **Semantic match on OS-free images:** Each Silica memory space obtains **hardware-consistent** cacheability, shareability, and (for `atomic`) **ordering** behavior—not only type-checking.
2. **Board-first delivery:** Ship runtimes and link scripts for **common bare-metal and embedded boards** (AArch64 SBCs, dev kits, **ESP32-S3** modules, etc.) where the implementation owns **all** RAM visibility policy.
3. **Hosted builds (optional):** If a compiler target links Silica programs as OS-hosted processes, treat **§12.1.1.0** as normative: **no guarantee** of per-space attributes; retain effects for static discipline only unless integrated with driver-specific allocations.

---

## Target classes

| Class | Examples | How `Space` is realized |
|-------|----------|-------------------------|
| **AArch64 bare-metal** | QEMU virt, Raspberry Pi–class boards (when run without a general-purpose OS), custom AArch64 firmware | `MAIR_EL1` + stage-1 PTE attribute indices per §12.1.1.1; optional device maps for `device`. |
| **ESP32-S3 (Xtensa)** | DevKitC-1, WROOM/WROVER modules, custom boards with PSRAM | **Not** MAIR: use **SoC-specific** rules—internal SRAM, **SPIRAM** (PSRAM) cacheability, **DMA-capable** (`DRAM_ATTR`) buffers for non-cacheable/DMA paths, **peripheral** address regions for `device`; Espressif **cache sync** APIs where software must flush/invalidate. |
| **Other MCUs / SoCs** | Future ports | Same *contract*: table `Silica Space → chip manual + vendor HAL` attributes; document per port. |

---

## Phase 0 — Inventory and IR contracts (deliverable)

This section is the **Phase 0 deliverable**: what must be tracked in IR, what hardware behavior each surface requires, and how that differs from effect subeffecting.

### 0.1 Primitive inventory → required hardware behavior

**Convention:** *Space* is always the Silica memory space (`normal`, `normal_writeback`, `normal_writethrough`, `normal_noncacheable`, `atomic`, `device`). On **AArch64 OS-free**, *MAIR index* follows §12.1.1.1 (Attr0–Attr3). On **ESP32-S3**, *mapping* means **linker section + cache mode + DMA capability** per IDF / TRM, not MAIR.

| Surface | Where `Space` comes from | OS-free runtime / mapping | Loads & stores |
|--------|---------------------------|----------------------------|----------------|
| `alloc_region(Space)` | Literal `Space` | **AArch64:** pages with `PTE[MAIR_INDEX] = f(Space)`. **ESP32-S3:** allocate from a **pool** tied to a **memory type** (internal cached, SPIRAM, DMA/“no-cache” buffer heap, etc.). | N/A at prim (header is implementation-defined). |
| `alloc_ref` / `alloc_rec` | `region(R, Space)` | Bump inside region’s pool | **Non-atomic spaces:** plain loads/stores. **`atomic`:** architecture atomics (AArch64: **`LDAR`/`STLR`**; Xtensa / ESP32-S3: **aligned accesses + barriers** and/or **vendor atomic helpers** per port and IDF guidance). |
| `read_ref` / `write_ref` | `ref(R, Space, T)` | Inherits region | Same split: plain vs acquire/release per `Space`. |
| `alloc_buf` / `buf_load` / `buf_store` | `buf(R, Space, T, N)` | Same as region | Indexed plain or atomic access per `Space`. |
| `fresh_lifetime()` | None | N/A | N/A |
| `alloc_atomic` *(spec §22; compiler TBD)* | `ref(R, atomic, T)` | Region pool must be **atomic-capable** (coherent, aligned) | LDAR/STLR (AArch64); Xtensa RMW/ordering per port. |

**List / library surfaces** (`List[T, Space]`): all spine and chunk storage must use the **same** `Space` realization as `alloc_region(Space)` for that list.

### 0.2 IR / SIR contract

1. Every memory prim must carry **`Space`** (or **`mair_idx` / `board_mem_kind`** enum) through to emit and runtime.
2. **`alloc_region`**: Argument must reach **`_silica_rt_region_alloc(space_tag)`** (or board-specific allocator); emitter must **materialize** the tag (currently dropped on AArch64 emit path).
3. **Ref/buf access:** Instruction selection from **static type** of pointer, not from callee effect string alone.
4. **Effects** (`mem(Space)`): static checking + coarse barriers; they do not replace per-access atomic instructions.

### 0.3 Effect subeffecting vs region types

- **Subeffecting** (§9.2.4): lattice on effects.
- **Region types:** `region(R, normal_noncacheable)` is **not** interchangeable with `region(R, normal_writeback)` even when subeffects relate—**different pools / mappings**.

### 0.4 Gaps vs current compiler (baseline)

| Item | Current state |
|------|----------------|
| `alloc_region` space → runtime | Operand unused on AArch64 emit path; **wire for OS-free targets**. |
| Atomic `ref` | Plain `LDR`/`STR` only; **upgrade** on ports that require LDAR/STLR or Xtensa equivalents. |
| `alloc_atomic` | Spec only; **add to SIR** when implemented. |
| Lists | Audit chunk alloc vs `List[T, Space]`. |

---

## Phase 1 — Runtime: per-board memory pools

### 1.1 AArch64 OS-free

- Boot: program `MAIR_EL1` per §12.1.1.1 pseudocode (when execution level permits).
- **`alloc_region(Space)`:** map new pages (or fixed arena subdivisions) with **`PTE` attribute index** for `Space`.
- **Capability flags:** optional self-test that reads back page attributes in a **hypervisor-less** test image.

### 1.2 ESP32-S3 (representative embedded port)

- **No `MAIR`:** Map Silica spaces to **Espressif / TRM** concepts:
  - **`normal` / `normal_writeback`:** Default **cached** internal RAM and (if enabled) **SPIRAM** per project `sdkconfig` (cache for external RAM on S3).
  - **`normal_writethrough`:** If the SoC/HAL lacks true WT, **document deviation** or emulate with **write-through–like discipline** (e.g. selective sync)—prefer **honest capability bit** “WT not hardware-exact.”
  - **`normal_noncacheable` / DMA-visible:** Allocate from **DMA-capable** paths (`heap_caps_malloc`, `MALLOC_CAP_DMA`, aligned buffers) and treat as **non-cacheable or sync-on-handoff** per IDF rules for peripherals.
  - **`device`:** Addresses in **peripheral** regions; accesses must not use CPU cache as normal RAM; often **32-bit aligned** volatile access; match **`register_rwr`** if MMIO is user-mapped.
  - **`atomic`:** Use **word-aligned** locations in **shared internal RAM**; emit **barriers +** appropriate atomic or guarded sequences for cross-core (S3 is dual-core); AArch64 LDAR/STLR **do not apply**—use **Xtensa** port table.
- **Linker script:** Separate **pools** or **symbols** per `Space` if static layout is required; runtime bump pointers within each pool.

**Deliverable:** Board-specific **`silica_rt_memory`** (or equivalent) with **`space_tag → allocator`**, documented per **board pack** (AArch64 link script + ESP32-S3 `sdkconfig` fragment).

---

## Phase 2 — Compiler / emitter

### 2.1 AArch64

- **Non-atomic spaces:** `LDR`/`STR` once backing storage has correct attributes.
- **`atomic`:** `LDAR`/`STLR` (and RMW loops when needed).
- **`device`:** Loads/stores to mapped device regions; pair with **`register_rwr`** barriers where spec requires.

### 2.2 ESP32-S3 (Xtensa)

- Emit **Xtensa** load/store (and atomics/barriers) per calling convention; **no** AArch64 opcodes.
- Maintain a **port table**: `(prim, Space, width) → instruction + required alignment`.

**Deliverable:** Golden assembly / object tests **per target triple** (e.g. `aarch64-none-elf`, `xtensa-esp32s3-elf`).

---

## Phase 3 — Lists, structs, mixed spaces

- List growth must call the **same** `Space` pool as `List[T, Space]`.
- Optional **debug headers** tagging region `Space` for assertions.

---

## Phase 4 — Verification

- **AArch64:** QEMU or hardware: attribute behavior for NC vs WB where observable.
- **ESP32-S3:** On-device tests: **DMA round-trip**, **SPIRAM vs internal**, **dual-core** atomic smoke tests.
- **Litmus:** Publish–sync style tests on **multi-core** boards only.

**Deliverable:** CI matrix: **`board` × `space`** capability flags; OS-hosted builds marked **“discipline only”** per §12.1.1.0.

---

## Phase 5 — Documentation

- Per-board README: **which `Space` values are exact vs emulated**.
- Keep **§12.1.1.0** in sync: OS-free = full support; OS-hosted = no portable guarantee.

---

## Dependency order

1. Board linker + runtime pools (Phase 1) before trusting PTE/cache behavior.
2. IR space operand end-to-end (Phase 0–1).
3. Atomic access lowering per ISA (Phase 2).
4. List allocator audit (Phase 3).

---

## Risks

- **ESP32-S3** WT may be **inexact** vs AArch64 MAIR WT; **capability flags** required.
- **PSRAM** cache coherency with DMA: must follow IDF **sync** rules or use **non-cached** DMA buffers for `normal_noncacheable`.
- **Dual-core** on S3: atomic `Space` needs **cross-core** ordering story distinct from AArch64.

---

## Specification references

- §9.1.1 Built-in effects (`mem(Space)`)
- §12.1.1.0 **OS-free vs OS-hosted guarantees**
- §12.1.1.1 AArch64 MAIR (AArch64 ports)
- §12.1.1.2 Runtime guarantees per space
- §22 Atomic refs (when implemented)

Board bring-up, MMIO map/load/store, and what else is still missing for a raw-metal image: [porting_for_os_free_targets.md](porting_for_os_free_targets.md).
