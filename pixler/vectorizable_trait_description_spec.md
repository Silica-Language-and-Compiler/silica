Vectorizable trait spec

# SIMD Map Specification for Silica
# Target: AArch64 (NEON and/or SVE)
# Language: Silica (functional systems programming, recursion-only, AArch64-native)
# Reference: silica-compiler&language-specification.jsonld, silica-specification.md
#
# Assumptions (aligned with Silica design principles):
# - No garbage collection (region-based memory)
# - Memory-safe buffers via buf(R, Space, T, N)
# - Users explicitly opt-in by declaring types/functions vectorizable
# - Source language expresses iteration via recursion (no user-visible loops)
# - Compiler is allowed to lower recursion into loop-shaped machine code

================================================================================
1. Terminology and Concepts
================================================================================

1.1 Scalar Element
- A value of type T as defined by Silica semantics (e.g., int8, int16, int32,
  int64, float16, float32, float64, boolean, char, string, atom, struct, or tuple).

1.2 Vector Representation (Repr)
- A low-level representation of multiple scalar T values processed in parallel.
- Repr is NOT required to be a single vector register.
- Repr MAY be:
  - a single vector register (e.g., VecInt32, Vec128Int32)
  - a bundle/tuple of vector registers (e.g., (VecInt64, VecInt64, VecInt32))
  - a pointer vector (e.g., VecInt64 holding addresses) possibly accompanied by
    gathered field vectors

Silica vector types (from Section 4.7, arch.sve):
- NEON: Vec128Int8, Vec128Int16, Vec128Int32, Vec128Int64, Vec128Float32, Vec128Boolean
- SVE: VecInt8, VecInt16, VecInt32, VecInt64, VecFloat16, VecFloat32, VecFloat64, VecBoolean

1.3 Predicate / Mask
- A per-lane enable mask used to prevent out-of-bounds memory access and to
  implement partial-vector (tail) handling.
- For SVE: predicate type Pred (arch.sve); predicate registers p0..p15, typed
  by lane granularity b/h/s/d.
- For NEON: no native predicate registers; tail handled by scalar recursion or
  masked stores implemented by scalar cleanup (implementation-defined).

1.4 ReprKind
- Inline: scalar data is stored directly in vector lanes (or bundles of lanes).
- ByRef: vector lanes contain ref(R, Space, T) pointers to region objects; fields
  loaded via gather.
- Packed: temporary packed layout (AoSoA/SoA) created in a region buffer to
  enable contiguous loads/stores. (Optional phase; MAY be omitted in initial release.)

================================================================================
2. Buffer and Memory Model (Silica)
================================================================================

2.1 Region and Byte-Level Storage
- Silica uses region(R, Space) for memory allocation. Regions provide:
  - base pointer (opaque to user unless unsafe operations are explicitly allowed)
  - length in bytes
  - alignment guarantee (at least 1; higher optional)
  - bounds-checked access through typed views (buf, ref)

2.2 buf(R, Space, T, N)
- Silica buffer type: contiguous array of N elements of type T in region R.
- Buffers are mutable; elements may be read and written via read_buf and write_buf.
- Provides:
  - base pointer (via region)
  - element count N (fixed at allocation)
  - stride in bytes (default stride == sizeof(T_layout))
  - alignment (>= align_of(T_layout))
- Operations: read_buf(buffer, index) -> T, write_buf(buffer, index, value) -> atom
- Memory safety (Section 12.3): All reads/writes bounds-checked.
- Compiler-generated vector operations must preserve these bounds guarantees.

Example:
```silica
buf: buf(R, normal, int64, 1024) <- alloc_buf(region, 1024)
x: int64 <- read_buf(buf, 5)
```

2.3 ref(R, Space, T)
- Silica reference type: stable pointer to an object of type T in region R.
- Since no GC exists, ref stability requires only that the program not free/
  invalidate the object during the relevant operation.

2.4 buf(R, Space, ref(R, Space, T), N)
- A contiguous array of references used for ByRef processing.

================================================================================
3. Target Feature Model
================================================================================

3.1 Targets
- NEON: fixed 128-bit vectors, no general gather/scatter.
- SVE: scalable vectors, predication, gather/scatter.

3.2 Feature Query
The compiler/runtime MUST provide (per Section 21, arch.sve):
- has_neon() -> boolean  (true on AArch64 unless explicitly disabled)
- has_sve() -> boolean
- sve_vl_bytes() -> int64  (valid iff has_sve)

3.3 Multiversioning (Not Supported)
- the user MUST select the backend explicitly.

================================================================================
4. Traits (Silica)
================================================================================

Silica uses trait-based polymorphism (Section 8, 30). No generics; concrete types
and trait impls per type.

4.1 Trait: Vectorizable
User-declared; required for SIMD map. Implemented per element type.
Silica traits have only function declarations; no properties.

Implementation contract (each impl must satisfy; not part of the trait):
- Repr: The vector-loop representation (e.g., VecInt32 for int32). MUST be composed
  of Silica vector types (VecInt8..VecFloat64, Vec128Int8..) or predicate-capable
  types supported by the backend IR (single vectors or bundles).
- KIND: Inline | ByRef | Packed
- ELEM_BYTES: Number of bytes per logical element. Inline: 1/2/4/8 or agreed chunk
  size. ByRef: 8 (pointer width) for AArch64.
- PRED_GRAN: One of {B8, H16, S32, D64}. Lane granularity for predicates and stepping.

Required functions (per impl):
- impl Vectorizable for int32:
  - fn step(target: Target) -> int64
  - fn load(pg: Pred, base: *int32, i: int64) -> VecInt32
  - fn store(pg: Pred, base: *int32, i: int64, value: VecInt32) -> atom

- step(target) -> int64
  - Returns number of logical elements processed per iteration.
  - SVE: MUST return sve_vl_bytes() / ELEM_BYTES (rounded down). MUST be >= 1.
  - NEON: MUST return 16 / ELEM_BYTES (rounded down). MUST be >= 1.

- load(pg: Pred, base: *T, i: int64) -> Repr
  - Loads a Repr representing elements starting at logical index i.
  - Must respect pg: lanes disabled in pg MUST NOT read out-of-bounds memory.
  - base points to the start of the buf(R, Space, T, N) storage (or pointer array).
  - For bundles, all component loads share the same pg and index.

- store(pg: Pred, base: *T, i: int64, value: Repr) -> atom
  - Stores Repr starting at logical index i.
  - Must respect pg: lanes disabled in pg MUST NOT write out-of-bounds memory.

Safety and correctness obligations (user responsibility when declaring Vectorizable):
- The Repr and its load/store must correspond to the user-declared layout contract
  for T.
- For Inline kinds, field/chunk mapping must be consistent across load/store.
- For ByRef kinds, base must address an array of 64-bit refs.

Optional functions (MAY be added later):
- prefetch(base, i)
- gather_field(pg, ptrs_repr, byte_offset, field_kind) -> VecField
- scatter_field(pg, ptrs_repr, byte_offset, field_vec) -> atom

4.2 Trait: VectorMap
User-declared vector kernel; required for SIMD map. Implemented per (F, A, B) triple.
Traits have only function declarations.

Constraints:
- requires Vectorizable for A, Vectorizable for B

Required function (per impl):
- fn apply(pg: Pred, a: A::Repr) -> B::Repr

4.1.1 Full Trait Definition (Silica)

Each vectorizable element type has its own trait; the int32 definition follows.
Traits contain only function declarations. The impl contract (Repr, KIND, etc.)
is documented per impl, not as trait properties.

```silica
trait VectorizableInt32 {
  fn step(target: Target) -> int64;
  fn load(pg: Pred, buf: buf(R, Space, int32, N), i: int64) -> VecInt32 proc[mem(Space)];
  fn store(pg: Pred, buf: buf(R, Space, int32, N), i: int64, value: VecInt32) -> atom proc[mem(Space)];
}
```

4.1.2 Concrete Implementation for int32

```silica
impl VectorizableInt32 for int32 {
  // Repr = VecInt32
  // KIND = Inline
  // ELEM_BYTES = 4
  // PRED_GRAN = S32

  fn step(target: Target) -> int64 {
    case target.has_sve() of {
      true: boolean -> arch.sve.sve_vl_bytes() / 4;
      false: boolean -> 4;
    }
  }

  fn load(pg: Pred, buf: buf(R, Space, int32, N), i: int64) -> VecInt32 proc[mem(Space)] {
    ptr: *int32 <- buf_ptr(buf, i);
    arch.sve.load_vector_int32(ptr, Some(pg))
  }

  fn store(pg: Pred, buf: buf(R, Space, int32, N), i: int64, value: VecInt32) -> atom proc[mem(Space)] {
    ptr: *int32 <- buf_ptr(buf, i);
    arch.sve.store_vector_int32(ptr, value, Some(pg))
  }
}
```

Note: `buf_ptr(buf, i)` is a compiler/runtime primitive that returns a pointer to
the element at index i. `Target` is a record describing the backend (has_sve,
has_neon, sve_vl_bytes). NEON step is 16/4 = 4 lanes per iteration.

4.1.3 VectorMap Example

```silica
trait VectorMapInt32 {
  fn apply(pg: Pred, a: VecInt32) -> VecInt32;
}
impl VectorMapInt32 for DoubleInt32 {
  fn apply(pg: Pred, a: VecInt32) -> VecInt32 {
    arch.sve.add_vectors_int32(a, a)
  }
}
```

Semantics:
- apply MUST be lane-wise: each active lane of output depends only on the
  corresponding active lane of input.
- apply MUST be valid under partial masks (pg), and MUST NOT assume all lanes active.
- apply MUST have no effects; only pure computation is permitted.
  Minimum permitted set:
    - pure arithmetic/logic
    - comparisons
    - select/blend
    - optional: bounded table lookups with guaranteed in-bounds masking
  Forbidden:
    - dynamic allocation inside apply
    - any code that produces side effects (device_io, network_io, etc.)
    - calling arbitrary non-vector-safe functions
    - unbounded loops or recursion

================================================================================
5. API Surface
================================================================================

5.1 Scalar map (baseline; recursion-based)
map : (A -> B) -> buf(R, Space, A, N) -> buf(R, Space, B, N)
- Always correct; MAY call scalar recursion internally (Silica: recursion only).
- Not required to vectorize.

Example (recursive map over list; conceptually similar for buf):
```silica
fn map_int64(xs: List[int64], f: (int64 -> int64)) -> List[int64] {
  case xs of {
    []: List[int64] -> empty[int64]();
    [h: int64, t: List[int64]]: List[int64] -> prepend[int64](f(h), map_int64(t, f));
  }
}
```

5.2 SIMD map (explicit opt-in)
map_simd : F -> buf(R, Space, A, N) -> buf(R, Space, B, N)
  where Vectorizable for A, Vectorizable for B, VectorMap for F

- map_simd allocates a new output buf(R, Space, B, N) of length N (same as input)
  and returns it. The input buffer is not modified; a fresh buffer is always created.

5.3 Pointer-array SIMD map (ByRef)
map_simd_ptr : F -> buf(R, Space, ref(R, Space, A), N) -> buf(R, Space, B, N)
  where A is region object type and Vectorizable for A or Vectorizable for ref(R, Space, A)
  describes ByRef.

Note:
- For NEON-only targets, ByRef SIMD map is NOT REQUIRED to be supported.
- If not supported, map_simd_ptr MUST either:
  - reject at compile time, or
  - require explicit packing (Section 8).

================================================================================
6. Recursion Form Requirements (Lowerable Recursion)
================================================================================

Silica expresses iteration via recursion only (Section 1.2 / 1.3: LLM-Friendly / One Way at the Language Level / No Loops).

6.1 Canonical SIMD Recursion Scheme
To be SIMD-lowerable, the user MUST express SIMD map through one of:
- map_simd primitive (allocates new buffer, returns result), OR
- a canonical tail-recursive scheme recognized by the compiler (optional).

6.2 Required properties of recognized tail recursion (if compiler supports recognition)
A function go(i, ...) is recognized as SIMD-loopable iff:
- i is a monotonic induction variable of integer type (e.g., int64)
- base case checks i >= n (or equivalent)
- recursive call is in tail position
- recursive call advances i by exactly step(target)
- no work occurs after the recursive call
- control flow does not depend on per-lane data in a way that prevents predication

Example (canonical tail recursion; if compiler recognizes it). The output buffer is
freshly allocated by map_simd before calling go; the user writes only to the output.
```silica
fn go(i: int64, n: int64, inp: buf(R, normal, int32, N), out: buf(R, normal, int32, N), step: int64) -> atom proc[mem(normal)] {
  case i >= n of {
    true: boolean -> ();
    false: boolean -> do
      pg: Pred <- sve.whilelt(i, n);
      a: VecInt32 <- VectorizableInt32.load(pg, inp, i);
      b: VecInt32 <- DoubleInt32.apply(pg, a);
      VectorizableInt32.store(pg, out, i, b);
      go(i + step, n, inp, out, step)
    end;
  }
}
```

If recognition is not implemented, users MUST call map_simd primitives directly.

6.3 Lowering of recursion
Even though Silica is recursion-only, the compiler MAY lower recognized
tail recursion into internal loop IR and then into machine code.

================================================================================
7. Lowering Semantics for map_simd
================================================================================

map_simd allocates a new output buffer and fills it; the input buffer is not modified.
Let:
- input buf(R, Space, A, N) with length n
- output buf(R, Space, B, N) with length n (freshly allocated by map_simd)
- step = Vectorizable for A :: step(target)
- PRED_GRAN = A::PRED_GRAN
- ELEM_BYTES = A::ELEM_BYTES

7.1 SVE Lowering (if has_sve())
Pseudo-semantics:
- i := 0
- while i < n:
    pg := whilelt(i, n) at PRED_GRAN
    a  := A::load(pg, input.base, i)
    b  := F::apply(pg, a)
    B::store(pg, output.base, i, b)
    i := i + step

Requirements:
- whilelt MUST produce a predicate that disables lanes whose indices >= n.
- A::load and B::store MUST not access out-of-bounds for disabled lanes.

7.2 NEON Lowering (if has_neon() and not has_sve(), or user selects NEON)
Pseudo-semantics:
- step := 16 / ELEM_BYTES
- i := 0
- while i + step <= n:
    pg_all := all lanes active (logical)
    a := A::load(pg_all, input.base, i)   (pg_all is conceptual; implemented as full load)
    b := F::apply(pg_all, a)
    B::store(pg_all, output.base, i, b)
    i := i + step
- scalar tail:
  process remaining indices [i..n) with scalar map or scalar kernel

NEON requirements:
- Either:
    - provide scalar fallback for tail, OR
    - implement masked tail stores/loads in a safe manner.
  Scalar tail is REQUIRED in initial implementation.

================================================================================
8. Optional Packed Strategy (Explicit User Tooling)
================================================================================

8.1 Motivation
For buf(R, Space, ref(R, Space, A), N) with poor locality, gather/scatter may underperform.

8.2 Explicit Packing API
pack_aosoa : buf(R, Space, ref(R, Space, A), N) -> buf(R, Space, uint8, M) -> PackPlan[A] -> block_elems:int64 -> PackedView
unpack_aosoa : PackedView -> buf(R, Space, ref(R, Space, A), N) -> UnpackPlan[A] -> atom

8.3 PackedView
A typed view describing SoA/AoSoA arranged fields suitable for Inline SIMD loads.

8.4 Packed SIMD Map
Users MAY:
- pack refs into PackedView
- run map_simd on PackedView using Inline Vectorizable instances (returns new buffer)
- unpack results if needed

The compiler is NOT REQUIRED to auto-insert packing in this explicit model.

================================================================================
9. Safety, Aliasing, and Mutability Rules
================================================================================

9.1 No-GC Stability
- Pointers remain stable unless freed/invalidated by the program.
- SIMD operations assume the program maintains validity for duration of map_simd.

9.2 Aliasing
- map_simd always allocates and returns a new buffer; input and output are
  distinct by construction. No overlap is possible.

9.3 ByRef Scatter Aliasing
If scatter stores are used (ByRef in-place update), user must choose one:
- NoAlias: compiler may assume all pointers in a vector chunk are distinct; otherwise UB.
- Relaxed: if pointers alias, final value is implementation-defined (e.g., last lane wins).
Default: NoAlias unless explicitly declared.

================================================================================
10. Diagnostics and Verification (Required)
================================================================================

10.1 Compile-time errors
- Missing Vectorizable or VectorMap impl for map_simd use.
- KIND == ByRef requested on NEON-only target (has_neon() and not has_sve()) without packing.
- step(target) computed as 0.
- Incompatible PRED_GRAN between input and output (unless explicitly allowed and converted).

10.2 Optional static checks (recommended even for sophisticated users)
- Validate ELEM_BYTES matches PRED_GRAN (B=1, H=2, S=4, D=8) for Inline kinds,
  unless user opts into custom chunk semantics.
- Validate Repr bundle component lane counts are consistent.

10.3 Debug mode runtime assertions (optional)
- buf alignment and bounds invariants for vector loads/stores.

================================================================================
11. Backend Implementation Requirements
================================================================================

11.1 IR must support:
- Vector registers and operations for B/H/S/D lanes
- Bundle/tuple values
- Predicate values for SVE
- SVE predicate generation (whilelt, ptrue)
- Predicated loads/stores (SVE)
- Gather/scatter (SVE) if ByRef is supported

11.2 Codegen must:
- Respect calling conventions for Repr bundles (register passing)
- Preserve memory safety by honoring predicates and/or scalar tails
- Avoid OOB vector accesses for all input lengths n >= 0

================================================================================
12. Conformance Summary
================================================================================

A Silica program conforms to this SIMD map specification if:
- All uses of map_simd satisfy trait requirements (Vectorizable, VectorMap impls)
- Vectorizable impls fulfill their load/store semantics under masking
- VectorMap kernels are lane-wise and mask-safe
- Compiler lowering preserves scalar semantics for map_simd (for all n and all data)
- Generated code does not perform out-of-bounds memory access

Cross-references:
- silica-compiler&language-specification.jsonld (Silica language spec)
- silica-specification.md Section 4.7 (SIMD Vector Types), Section 12.3 (Buffer Semantics)
- silica-specification.md Section 21 (SVE, arch.sve module)