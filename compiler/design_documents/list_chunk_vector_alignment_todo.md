# List chunk sizing and SIMD alignment — Implementation TODO

**Goal:** Move the **living** **`silica-compiler`** list spine from a **fixed 128-bit-ish minimum slab** (see **[list_implementation_design.md §4.5](list_implementation_design.md)**) toward **[§2 — Vector chunks (day 1)](list_implementation_design.md)** and **[§4.1 — Chunks and buffers](list_implementation_design.md)**: chunk **data** sizing and allocation should **track target vector processing width** where packing permits, and **codegen** should be able to use **those** widths without fighting the heap layout.

**Implementation status (2026-10-16):** still open, nothing in the list below has been done. `chunk_data_bytes` is still `max(16, elem_slot_bytes)` in every backend, list codegen is scalar loads and stores, and there is no target feature plumbing. One thing changed since this was written: each chunk now carries a copy-on-write claim word after the `next` pointer, so a chunk allocation is `CDATA + 16` bytes (see [list_implementation_design.md](list_implementation_design.md), implementation status). Any alignment contract in item 2 must account for that layout.

## Related documents

| Document | Purpose |
|----------|---------|
| [list_implementation_design.md](list_implementation_design.md) | Canonical list representation goals; **§4.5** describes current emitter vs doc |
| `emitter/apple_silicon_mac/terms/prims/prims_list.silica` | **`chunk_data_bytes`**, helpers **`L_list_prepend_helper`** / **`L_list_tail_helper`**, scalar emits |
| [silica-compiler-code-organization.md](silica-compiler-code-organization.md) | Where emitter modules live |

## Current gap (short)

| Area | Today | Target direction |
|------|-------|-------------------|
| **`CDATA`** (chunk data bytes) | **`max(16, elem_slot_bytes)`**, **constant `16`** floor | **`max(vector_slab_bytes(target, features), elem_slot_bytes)`** (and document **AArch64 Neon 128**, **wider or SVE-derived** slabs where applicable). |
| **Target selection** | Implicit **Apple Silicon AArch64** only | Plumbed **`mcpu`/triple/feature** set into **`chunk_data_bytes`** (or backend equivalent). |
| **Alignment** | Whatever **`_silica_rt_region_alloc`** guarantees | Explicit **simd-friendly alignment** at least **`CDATA`** (**and** **`next`** layout) consistent with **`LD1`**/`ST1` assumptions. |
| **Codegen** | Scalar **`LDR`/`STR`** for head/tail/patterns | Bounded inner-chunk traversals (**map**/**memcpy**/**compare** kernels) **may** emit **SIMD** when **`T`** and **offsets** permit; obey **§9.5** slot order. |
| **Tests** | Multi-chunk **`uint32`** trial exercises **packed 16-byte** slabs | Extend trials or **scout** hashes when **`CDATA`** becomes **ISA-dependent**. |

---

## TODO items

1. **Wire target vector slab size into codegen** — Replace the literal **`16`** minimum in **`chunk_data_bytes`** (and any duplicated constants in **`emit_list_*_helper`** assembly strings) with a value computed from **`TargetSpec`** (new or existing): at minimum **Neon 128-bit (16)** vs **widened SIMD (32+)** selectable by flags; document the mapping table per OS/CPU tier supported by **`silica-compiler`**.

2. **Allocator alignment contract** — Ensure chunk allocations used for **`List`** spines satisfy **`CDATA`** alignment for the chosen vector width (possibly ** larger than 16 for wide vectors**); document in **`list_implementation_design.md §4.5`** and region/trial headers if rules change user-visible **`mem`** behavior.

3. **SIMD fast paths (optional layering)** — After (1)-(2), add **Neon** (**or ISA-selected**) loads/stores for **hot** paths (**e.g. aggregate copy loops** inside prepend for large **`T`**, or **trial-only** kernels) behind guards that **`elem_slot_bytes` × slots-per-chunk** matches the vector program shape and **§9.5** layout.

4. **Cross-backend consistency** — If non–Apple AArch64 (**SVE**, server parts) gains support, reconcile **predicate / VL-dependent** widths with **`List`**’s **compile-time-fixed** **`CDATA`** (single chosen width per compile unit vs portable constant).

5. **Doc and regression sync** — When **`CDATA`** diverges per target, update **[§8 trials](list_implementation_design.md)** inventory and **`list_implementation_design.md`** document history so **scout**/.**ascomp** expectations stay tied to documented slab sizes.
