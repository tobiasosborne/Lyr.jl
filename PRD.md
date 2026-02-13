# Lyr.jl — Product Requirements Document

## Status: Phase 3 — Unify Parsers

**Date:** 2026-02-13
**Scope:** Bring TinyVDB's correct sequential reading into Main Lyr's idiomatic type system

---

## 1. Executive Summary

Lyr.jl is a pure Julia OpenVDB file format parser with two implementations:

| Implementation | LOC | Tests | Status |
|---|---|---|---|
| **Main Lyr (src/*.jl)** | ~3,850 | 756 total (3 errors) | Rich types, buggy v222+ parser |
| **TinyVDB (src/TinyVDB/*.jl)** | ~1,540 | 308 (all pass) | Correct parser, flat types |

**Previous strategy** (Phases 1-2): Fix TinyVDB, bridge to Lyr types, route compatible files through TinyVDB. This is complete — 196/197 beads issues closed.

**New strategy** (Phase 3): Port TinyVDB's sequential reading into Main Lyr's parser. Main Lyr's type system (`LeafNode{T}`, `Mask{N,W}`, `NTuple{512,T}`) is superior Julia. TinyVDB's sequential reading is correct. Combine them. TinyVDB becomes a test oracle.

---

## 2. Comparative Analysis

### 2.1 What Main Lyr Does Well

- **Parametric immutable types**: `LeafNode{T}` with `NTuple{512,T}` — stack-friendly, zero-alloc
- **Immutable bitmasks**: `Mask{N,W}` with `NTuple{W,UInt64}` — compiler-optimizable
- **Full type hierarchy**: `AbstractNode{T}` with proper dispatch
- **Multi-type support**: Float32, Float64, NTuple{3,Float32}
- **Full feature set**: Accessors, Interpolation, Ray tracing, Rendering
- **v220 support**: Pre-v222 interleaved format (bunny_cloud.vdb)
- **Blosc compression**: Production VDB files
- **Rich transforms**: 5 transform types including general affine

### 2.2 What TinyVDB Does Well

- **Sequential reading**: Never seeks to `block_offset`, matches C++ reference exactly
- **Spec-driven metadata**: Clean type-dispatched approach, no heuristics
- **Half-precision**: Detects `_HalfFloat`, threads `value_size` through pipeline
- **No heuristic guards**: Trusts file-declared counts, no origin validation hacks
- **Line-for-line C++ correspondence**: Every function maps to tinyvdbio.h

### 2.3 What TinyVDB Lacks (Un-Julian Design)

- **Mutable types**: `mutable struct LeafNodeData` with `Vector{Float32}` — heap-allocated
- **Type erasure**: `children::Vector{Tuple{Int32, Any}}` — loses compile-time dispatch
- **Hardcoded Float32**: No parametric types
- **No feature stack**: Relies on TinyVDBBridge for accessors, rendering, etc.

---

## 3. The Root Bug in Main Lyr

### 3.1 Diagnosis

Main Lyr's v222+ parser (`read_tree_v222` in TreeRead.jl) has a two-phase design that is sound in principle. The bug is that the topology pass doesn't skip embedded internal node values.

**TinyVDB topology pass** (correct):
```
read I2 masks → skip_mask_values(I2) → read I1 masks → skip_mask_values(I1) → read leaf masks
```

**Main Lyr topology pass** (buggy):
```
read I2 masks → [MISSING: skip I2 values] → read I1 masks → [MISSING: skip I1 values] → read leaf masks
```

Because `pos` is wrong after topology, Main Lyr compensates with:
- `pos = values_start` (seek to `block_offset`) — TreeRead.jl:335
- Origin validation `abs(x) <= 100000` — TreeRead.jl:243-244
- Padding detection (peek 128 bytes for zeros) — TreeRead.jl:308-321
- Early exit `pos >= values_start` — TreeRead.jl:287-288

These are all band-aids. The fix is to make the topology pass correctly advance `pos`.

### 3.2 Why the Pre-v222 Path Works

`read_tree_interleaved` reads topology and values together per-subtree, never seeking. It's already correct. The bug is ONLY in the v222+ separated-topology path.

---

## 4. Implementation Plan — Phase 3

### Step 1: Add `skip_internal_values` to v222+ Topology Pass

**Files:** `TreeRead.jl`
**Effort:** ~30 lines

Add a function (or inline logic) equivalent to TinyVDB's `skip_mask_values` that advances `pos` past embedded internal node values during the v222+ topology pass. Call it after reading I2 masks and after reading I1 masks in `read_i2_topology_v222`.

Main Lyr already has `read_dense_values` in Values.jl which handles the same metadata-byte + inactive-vals + selection-mask + compressed-data format. A skip variant just advances `pos` without constructing values.

**Precondition:** Read TinyVDB's `skip_mask_values` (Topology.jl:132-177) and Main Lyr's `read_dense_values` (Values.jl:13-98) for the format.

### Step 2: Remove Seek and Heuristic Guards

**Files:** `TreeRead.jl`
**Effort:** Delete ~40 lines

- Delete `pos = values_start` (line 335)
- Delete `is_valid_i2_origin` function and its call (lines 237-245, 299)
- Delete padding detection block (lines 303-321)
- Delete `pos >= values_start` early exit (lines 287-289)
- Remove `values_start` parameter from `read_tree_v222` and `read_tree` signatures
- Remove `block_offset` from `read_grid` in Grid.jl

After Step 1, `pos` flows correctly through topology → values. No seeking needed.

### Step 3: Replace Heuristic Metadata Parsing

**Files:** `Metadata.jl`
**Effort:** Replace ~150 lines with ~40 lines

Replace `read_grid_metadata` with a clean spec-following implementation:
- Read `tree_version` (u32) + `metadata_count` (u32)
- For each entry: size-prefixed key, size-prefixed type, size-prefixed value
- No ASCII scanning heuristics, no nested loops

Also fix `File.jl` line 37: v222+ file-level metadata values need 4-byte size prefix before value bytes (currently calls `skip_metadata_value_heuristic` which reads values directly).

**Reference:** TinyVDB `read_metadata` in Parser.jl for the correct format.

### Step 4: Add Half-Precision Support

**Files:** `GridDescriptor.jl`, `Grid.jl`, `TreeRead.jl`, `Values.jl`
**Effort:** ~20 lines of threading

- Detect `_HalfFloat` suffix in grid type string → set `half_precision` flag
- Compute `value_size = half_precision ? 2 : 4`
- Thread `value_size` through: `read_grid` → `read_tree_v222` → `skip_internal_values` → `read_dense_values`
- In `read_dense_values`: read Float16 values and convert to Float32 when `value_size == 2`

**Reference:** TinyVDB threads `value_size` through Compression.jl, Topology.jl, Values.jl, Parser.jl.

### Step 5: Add Parser Equivalence Tests

**Files:** `test/test_parser_equivalence.jl` (new)
**Effort:** ~60 lines

For every compatible test file (v222+, Float32, no Blosc), parse with both Main Lyr and TinyVDB (via bridge), assert identical:
- Tree structure (root children count, I2/I1/leaf counts)
- Active voxel counts per leaf
- Value arrays (within floating-point tolerance)
- Background values

TinyVDB becomes a permanent test oracle.

### Step 6: Demote TinyVDB, Remove Bridge

**Files:** `File.jl`, `TinyVDBBridge.jl`
**Effort:** ~20 lines changed, ~230 lines deleted

- Remove routing logic in `parse_vdb` (TinyVDB try-catch path)
- `parse_vdb` calls `_parse_vdb_legacy` directly (now fixed, rename back to `parse_vdb`)
- Delete `TinyVDBBridge.jl` (no longer needed — Main Lyr parses correctly)
- TinyVDB stays in `src/TinyVDB/` as reference implementation, only used by tests

---

## 5. What Stays Unchanged

| Component | Files | Why |
|---|---|---|
| Type system | `TreeTypes.jl`, `Masks.jl` | Already excellent |
| Value reading | `Values.jl` (v222+ `read_dense_values`) | Already handles full ReadMaskValues algorithm |
| Pre-v222 parsing | `TreeRead.jl` (`read_tree_interleaved`) | Already correct (sequential) |
| Binary primitives | `Binary.jl` | Solid |
| Compression | `Compression.jl` | Solid |
| Accessors | `Accessors.jl` | Untouched |
| Interpolation | `Interpolation.jl` | Untouched |
| Ray tracing | `Ray.jl` | Untouched |
| Rendering | `Render.jl` | Untouched |
| Coordinates | `Coordinates.jl` | Untouched |
| Transforms | `Transforms.jl` | Untouched |
| TinyVDB | `src/TinyVDB/*` | Stays as test oracle |

---

## 6. Success Criteria

1. `julia --project -e 'using Pkg; Pkg.test()'` — 0 errors (currently 3)
2. All test VDB files parsed by Main Lyr directly (no TinyVDB routing)
3. Parser equivalence tests pass: Main Lyr == TinyVDB for all compatible files
4. Half-precision cube.vdb parsed correctly by Main Lyr
5. No heuristic guards in TreeRead.jl
6. No heuristic metadata parsing in Metadata.jl
7. TinyVDBBridge.jl deleted

---

## 7. Design Decision: Why Not Just Promote TinyVDB?

The previous PRD recommended promoting TinyVDB as the sole parser. After analysis, **fixing Main Lyr is better** because:

1. **Type system**: Main Lyr's `LeafNode{T}` with `NTuple{512,T}` and `Mask{N,W}` with `NTuple{W,UInt64}` are zero-alloc, immutable, and parametric. TinyVDB's mutable `Vector`-based types would need a complete rewrite to match.

2. **Generality**: Main Lyr handles Float64, Vec3f, Blosc, v220, general transforms. Extending TinyVDB to match would effectively recreate Main Lyr.

3. **Feature stack**: Accessors, interpolation, ray tracing all operate on Main Lyr's types. Keeping them avoids a rewrite.

4. **The fix is surgical**: The bug is ~1 missing function call in the topology pass. Everything else in Main Lyr is sound.

5. **TinyVDB as oracle**: A line-for-line C++ port is more valuable as a correctness reference than as production code. Two independent implementations that agree is stronger than one.
