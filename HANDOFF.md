# Lyr.jl Handoff Document

---

## Latest Session (2026-02-18) — API cleanup & code hygiene

**Status**: 🟢 COMPLETE — 14 issues closed, 9183 tests pass (23 new)

### What Was Done

Systematic cleanup pass across the codebase: export reduction, dead code removal, naming fixes, algorithm improvements, and REPL experience.

| # | ID | P | Type | What |
|---|-----|---|------|------|
| 1 | `ydgg` | P2 | task | Reduce public API from 195 → 129 exports. Binary r/w primitives, parser internals, DDA primitives, compression functions, coordinate internals, exception detail types, render/volume/GPU internals removed from export. Tests import explicitly via `runtests.jl`. |
| 2 | `hwz9` | P3 | task | Move `TinyVDBBridge.jl` from `src/` to `test/` — test infrastructure, not production code |
| 3 | `mphw` | P3 | task | Dead code `_estimate_normal_safe` — already removed in prior session |
| 4 | `9ikg` | P3 | task | Dead code `_bisect_surface` — already removed in prior session |
| 5 | `hgtb` | P3 | task | TinyVDB `read_grid_descriptors`: `read_i32` → `read_u32` for grid count |
| 6 | `z986` | P3 | task | TinyVDB `read_root_topology`: `read_i32` → `read_u32` for tile/child counts |
| 7 | `rep3` | P3 | task | TinyVDB `read_grid`: `read_i32` → `read_u32` for buffer_count |
| 8 | `ne2` | P3 | bug | Half-precision: replaced heap-allocating `bytes[pos:pos+1]` + `reinterpret` with zero-alloc `read_f16_le` |
| 9 | `05ih` | P3 | task | Renamed `inactive_val1/val2` → `inactive_val0/val1` to match C++ `inactiveVal0/inactiveVal1` |
| 10 | `9u3` | P3 | task | Added `ROOT_TILE_VOXELS = 4096^3` named constant, documented all tile region sizes |
| 11 | `n9aw` | P3 | task | Renamed misleading `offset_to_data` → `data_pos` in TinyVDB header |
| 12 | `thac` | P3 | task | Renamed `src/Topology.jl` → `src/ChildOrigins.jl` (was confusing with TinyVDB/Topology.jl) |
| 13 | `9ezy` | P3 | task | Reduced TinyVDB exports from 45+ → 9 symbols (test oracle API only) |
| 14 | `40mo` | P3 | task | Fixed `off_indices` iterator: O(N) linear scan → O(count_off) CTZ-based |
| 15 | `qgdu` | P3 | feature | Added `Base.show` methods for Mask, LeafNode, Tile, InternalNode1/2, Tree, Grid, VDBFile |
| 16 | `x0u3` | P3 | feature | Covered by `qgdu` — Base.show methods for REPL experience |

Also removed dead `_safe_sample_nearest` from Render.jl.

### Files Modified/Created

| File | Change |
|------|--------|
| `src/Lyr.jl` | Export reduction (195→129), include rename |
| `src/Masks.jl` | `Base.show` for Mask, CTZ-based `off_indices` |
| `src/TreeTypes.jl` | `Base.show` for LeafNode, Tile, InternalNode1/2, RootNode |
| `src/Grid.jl` | `Base.show` for Grid |
| `src/File.jl` | `Base.show` for VDBFile |
| `src/Render.jl` | Removed dead `_safe_sample_nearest` |
| `src/Values.jl` | Zero-alloc half-precision read, `inactive_val0/1` rename |
| `src/Accessors.jl` | `ROOT_TILE_VOXELS` constant |
| `src/ChildOrigins.jl` | Renamed from `src/Topology.jl` |
| `src/TinyVDB/TinyVDB.jl` | Reduced exports (45+ → 9) |
| `src/TinyVDB/GridDescriptor.jl` | `read_i32` → `read_u32` |
| `src/TinyVDB/Topology.jl` | `read_i32` → `read_u32` |
| `src/TinyVDB/Parser.jl` | `read_i32` → `read_u32` |
| `src/TinyVDB/Types.jl` | Renamed `offset_to_data` → `data_pos` |
| `src/TinyVDB/Header.jl` | Updated docstring |
| `test/runtests.jl` | Explicit `import Lyr:` for internal test symbols |
| `test/test_show.jl` | **NEW** — 23 tests for Base.show methods |
| `test/test_tinyvdb.jl` | Explicit imports for reduced TinyVDB exports |
| `test/test_values.jl` | `inactive_val0/1` rename |
| `test/TinyVDBBridge.jl` | Moved from `src/` |
| `test/test_parser_equivalence.jl` | Updated include path |

### Test Results

```
9183 pass, 0 fail, 0 errors (was 9160)
23 new tests (Base.show methods)
```

### Project Status Summary

**~9,200 LOC source, ~8,700 LOC tests, 41 files, 281 issues closed, 32 open**

| Phase | Status | Key Components |
|-------|--------|----------------|
| Phase 1: Foundation | **COMPLETE** | VDB read/write, DDA traversal, NanoVDB flat layout |
| Phase 2: Volume Renderer | **COMPLETE (basic)** | Delta/ratio tracking, transfer functions, scene, PNG output |
| Phase 3: GPU Acceleration | **Scaffolded** | GPUNanoGrid + CPU reference kernels, needs KA.jl wiring |
| Phase 4: Creation Tools | Not started | Mesh-to-SDF, procedural, CSG |
| Phase 5: Ecosystem | Not started | Makie, animation, multi-scatter, differentiable rendering |

### Next Priority

1. **GPU kernels** — Wire KernelAbstractions.jl to existing NanoVDB buffer + CPU reference kernels
2. **Makie recipe** (`9gqg`) — Interactive volume preview
3. **Render quality** — Grazing DDA (`1s6w`), AA (`8lcs`), crease normals (`ikrs`)

---

## Previous Session (2026-02-18) — NanoVDB flat-buffer implementation

**Status**: 🟢 COMPLETE — 8 issues closed, 7664 tests pass (6274 new)

### What Was Done

Implemented the complete NanoVDB flat-buffer representation — serializes the pointer-based VDB tree (`Root→I2→I1→Leaf`) into a single contiguous `Vector{UInt8}` buffer with byte-offset references. This is the critical path to GPU rendering via KernelAbstractions.jl.

| # | ID | P | Type | What |
|---|-----|---|------|------|
| 1 | `i70d` | P1 | design | NanoVDB buffer layout: Header, Root Table (sorted, binary-searchable), I2/I1 (variable-size with mask+prefix+child offsets+tile values), Leaf (fixed-size) |
| 2 | `g4eh` | P1 | feature | `NanoLeafView{T}` — zero-copy view into leaf node (origin, value_mask, values) |
| 3 | `jy23` | P1 | feature | `NanoI1View{T}`, `NanoI2View{T}` — views with child_mask/value_mask + prefix sums, child offset lookup, tile value lookup |
| 4 | `61ij` | P1 | feature | `NanoRootView` — sorted Coord entries with `_nano_root_find` binary search |
| 5 | `icfa` | P1 | feature | `build_nanogrid(tree::Tree{T})::NanoGrid{T}` — two-pass inventory→write converter |
| 6 | `9og6` | P1 | feature | `get_value(grid::NanoGrid{T}, c)` + `NanoValueAccessor{T}` with leaf/I1/I2 byte-offset cache |
| 7 | `tzd5` | P1 | feature | `NanoVolumeRayIntersector{T}` — lazy DDA iterator through flat buffer, yields `NanoLeafHit{T}` |
| 8 | `61fz` | P1 | test | Full equivalence test suite: 6274 assertions across 9 test sets |

### Phase 1.3 Status: NanoVDB Flat Layout — COMPLETE

```
✅ i70d  Design NanoVDB layout
  ✅ g4eh  NanoLeaf flat view
    ✅ jy23  NanoI1/NanoI2 flat views
      ✅ 61ij  NanoRoot sorted table
        ✅ icfa  NanoGrid build from Tree
          ✅ 9og6  Value accessor on NanoGrid
            ✅ tzd5  DDA on NanoGrid
              ✅ 61fz  Equivalence tests
```

### Files Created/Modified

| File | Change |
|------|--------|
| `src/NanoVDB.jl` | **NEW** (~570 LOC) — buffer primitives, view types, builder, accessors, DDA |
| `src/Lyr.jl` | Include NanoVDB.jl + 9 export lines |
| `test/test_nanovdb.jl` | **NEW** (~200 LOC) — 9 test sets, 6274 assertions |
| `test/runtests.jl` | Include test_nanovdb.jl |

### Buffer Layout

```
┌──────────────────────────────────────────────────────┐
│ Header (68+sizeof(T) bytes)                          │
├──────────────────────────────────────────────────────┤
│ Root Table (sorted entries, binary-searchable)       │
├──────────────────────────────────────────────────────┤
│ I2 Nodes (variable size, mask+prefix+offsets+tiles)  │
├──────────────────────────────────────────────────────┤
│ I1 Nodes (variable size, same structure)             │
├──────────────────────────────────────────────────────┤
│ Leaf Nodes (fixed: 76+512×sizeof(T) bytes each)     │
└──────────────────────────────────────────────────────┘
```

### Test Results

```
7664 pass, 0 fail, 0 errors (was 1390)
NanoVDB tests: 6274 new (buffer ops, views, build, get_value, accessor, DDA, multi-grid)
```

### Next Priority

1. **`1s6w`** — Fix grazing DDA missed zero-crossings (P2 bug)
2. **`8lcs`** — Multi-sample anti-aliasing (P2)
3. **GPU kernels** — KernelAbstractions.jl integration using NanoGrid buffer

---

## Previous Session (2026-02-17) — DDA renderer complete + beads housekeeping

**Status**: 🟢 COMPLETE — 9 issues closed, 4 new issues created, 1390 tests pass

### What Was Done

| # | ID | P | Type | What |
|---|-----|---|------|------|
| 1 | `ay5g` | P1 | task | Replace `intersect_leaves` (brute-force O(all_leaves)) with `collect(VolumeRayIntersector(...))` (DDA O(leaves_hit)). Make `sphere_trace` delegate to `find_surface`. Update `render_image` to call `find_surface` directly, removing stale world-bounds pre-computation. −100 LOC. |
| 2 | `9ysk` | P1 | feature | Closed stale — `VolumeRayIntersector` already implemented in commit `15c9d90`. |
| 3 | `tzw5` | P1 | feature | Closed stale — `find_surface` already implemented in commit `476e6c4` (`src/Surface.jl`). |
| 4 | `ck6p` | P3 | feature | Closed stale — superseded by `gduf`/`9ysk`. |
| 5 | `ydx` | P3 | feature | Closed stale — duplicate. |
| 6 | `m647` | P3 | task | Closed stale — already tested in `test_volume_ray_intersector.jl`. |
| 7 | `tyk7` | P3 | task | Closed stale — handled in `File.jl`. |
| 8 | `gim` | P3 | task | Closed stale — `.claude/` is hook-managed. |
| 9 | NaN guard | fix | test | Fixed pre-existing `NaN == NaN` bug in `test_properties.jl` "Empty tree returns background". |

**New issues created** (render quality findings from test renders):

| ID | Title | P | Blocks |
|----|-------|---|--------|
| `1s6w` | Fix missed zero-crossings at near-grazing voxel incidence | P2 | — |
| `ikrs` | Feature-preserving normals at sharp geometric creases | P2 | blocked by `czn` |
| `8lcs` | Multi-sample anti-aliasing (jittered supersampling) | P2 | — |
| `ga40` | Gamma correction and exposure control in render_image | P3 | blocked by `8lcs` |

### Files Modified

| File | Change |
|------|--------|
| `src/Ray.jl` | `intersect_leaves` → 1-line `collect(VolumeRayIntersector(...))`. Deleted `_intersect_internal2!`, `_intersect_internal1!`, `_intersect_leaf!` |
| `src/Render.jl` | `sphere_trace` delegates to `find_surface`. `render_image` calls `find_surface` directly |
| `test/test_render.jl` | +3 testsets: `sphere_trace` hits sphere.vdb, miss, max_steps-is-ignored |
| `test/test_ray.jl` | +1 testset: `intersect_leaves` equivalence vs `intersect_leaves_dda` on cube.vdb |
| `test/test_properties.jl` | `isnan(bg)` guard in "Empty tree returns background" property test |

### Phase 1.2 Status: DDA Ray Traversal — COMPLETE

```
✅ avxb  New Ray type with SVector
  ✅ bcba  AABB-ray slab intersection
    ✅ lmzm  3D-DDA stepper (Amanatides-Woo)
      ✅ p7md  Node-level DDA
        ✅ gduf  Hierarchical DDA (Root→I2→I1→Leaf)
          ✅ 9ysk  VolumeRayIntersector iterator
            ✅ tzw5  Level set surface finding
              ✅ ay5g  Replace sphere_trace    ← this session
```

### Beads Housekeeping

- Purged 72 stale `ly-*` closed issues from DB + JSONL (were causing `bd sync` prefix-mismatch loop)
- Removed erroneous `sync.branch = master` config (caused sync to loop on local JSONL)
- Workflow: commit `.beads/` directly to master — do NOT use `bd sync`
- Database now clean: **235 issues, all `path-tracer-*`**

### Render Quality — Known Artifacts & Roadmap

Test renders of `bunny.vdb` and `icosahedron.vdb` confirm the DDA renderer is geometrically correct (no node-boundary block artifacts). Remaining visual issues and their issues:

| Artifact | Root Cause | Issue |
|----------|-----------|-------|
| Horizontal banding (bunny) | 1 sample/pixel voxel aliasing | `8lcs` AA |
| Dark speckles at face edges (icosahedron) | Central-diff gradient straddles crease | `czn` → `ikrs` |
| Diagonal scan lines on flat faces | DDA misses sign-change at grazing incidence | `1s6w` |
| Washed-out midtones | Linear output, no gamma | `ga40` |

### Next Priority

1. **`1s6w`** — Fix grazing DDA missed zero-crossings (standalone P2 bug, fast win)
2. **`8lcs`** — Multi-sample AA (standalone P2, eliminates banding)
3. **`i70d`** — Design NanoVDB flat layout (Phase 1.3 entry point)

---

## Previous Session (2026-02-16) — Hierarchical DDA + DDA foundation

**Status**: 🟢 COMPLETE — 4 issues closed, 1285 tests pass

### What Was Done

| # | ID | P | Type | What |
|---|-----|---|------|------|
| 1 | `gduf` | P1 | feature | Hierarchical DDA: `intersect_leaves_dda` — Root → I2 → I1 → Leaf traversal. 88 new tests. |
| 2 | `bcba` | P1 | task | AABB struct (SVec3d min/max), refactored `intersect_bbox` to AABB primary + BBox overload. 12 new tests. |
| 3 | `lmzm` | P1 | feature | Amanatides-Woo 3D-DDA in `src/DDA.jl`: `DDAState`, `dda_init`, `dda_step!`. 112 new tests. |
| 4 | `p7md` | P1 | feature | Node-level DDA: `NodeDDA`, `node_dda_init`, `node_dda_child_index`, `node_dda_inside`, `node_dda_voxel_origin`. 57 new tests. |

### Files Modified/Created

| File | Change |
|------|--------|
| `src/Ray.jl` | Added `AABB` struct + `BBox` converter; refactored `intersect_bbox` to use AABB |
| `src/DDA.jl` | **NEW** — DDA stepper + NodeDDA + hierarchical traversal |
| `src/Lyr.jl` | Include DDA.jl; export AABB + DDA symbols |
| `test/test_ray.jl` | +12 AABB tests |
| `test/test_dda.jl` | **NEW** — 112 DDA tests |
| `test/test_node_dda.jl` | **NEW** — 57 NodeDDA tests |
| `test/test_hierarchical_dda.jl` | **NEW** — 88 hierarchical DDA tests |
| `test/runtests.jl` | Include new test files |

---

## Previous Session (2026-02-15) — Tests, hygiene, features, Phase 1 roadmap

**Status**: 🟢 COMPLETE — 8 issues closed, 996 tests pass, Phase 1 roadmap created (21 issues)

### What Was Done

**Part 1: Close top-of-queue issues (8 closed)**

| # | ID | P | Type | What |
|---|-----|---|------|------|
| 1 | `90su` | P1 | test | 10 unit tests for `read_dense_values` — all 7 metadata flags + half-precision + edge cases |
| 2 | `i4u4` | P1 | test | 40 unit tests for `TreeRead.jl` — `_decode_values`, `align_to_16`, `read_internal_tiles`, minimal tree integration |
| 3 | `3ox` | P2 | hygiene | Removed `Manifest.toml` from git tracking (already in .gitignore) |
| 4 | `py5` | P2 | hygiene | Deleted ~65MB image artifacts (40 PNG/PPM) from project root |
| 5 | `tla` | P2 | hygiene | Deleted `renders/` directory (~46MB, 36 files) |
| 6 | `nzn` | P2 | hygiene | Deleted 45 debug scripts (kept `render_vdb.jl`, `test_and_render_all.jl`) |
| 7 | `2zo` | P2 | feature | Boundary-aware trilinear interpolation — falls back to nearest at ±background |
| 8 | `al6m` | P2 | perf | Precomputed matrix inverse in `LinearTransform` (inv_mat field, ~2x for world_to_index) |

**Part 2: Phase 1 roadmap — pivot from parser polish to rendering pipeline**

Decision: parser is done (996 tests, all files parse). Remaining 51 old issues are diminishing-returns polish. Downgraded all old P1/P2 to P3. Created 21 new P1 issues across three phases:

**Phase 1.1: StaticArrays Foundation (5 issues, chain)**
```
ovkr  Add StaticArrays.jl + type aliases (SVec3d, SMat3d)  ← ENTRY POINT
  → e0v8  Refactor LinearTransform to SMatrix/SVector
    → 0yey  Refactor world_to_index/index_to_world
      → 717b  Refactor Interpolation.jl to SVec3d
        → uapd  StaticArrays foundation tests
```

**Phase 1.2: DDA Ray Traversal (8 issues, chain)**
```
ovkr  (shared root)
  → avxb  New Ray type with SVector origin/direction/inv_dir
    → bcba  AABB-ray slab intersection
      → lmzm  3D-DDA stepper (Amanatides-Woo)
        → p7md  Node-level DDA (per internal node)
          → gduf  Hierarchical DDA (Root→I2→I1→Leaf)
            → 9ysk  VolumeRayIntersector iterator
              → tzw5  Level set surface finding (DDA + bisection)
                → ay5g  Replace sphere_trace
```

**Phase 1.3: NanoVDB Flat Layout (8 issues, chain)**
```
i70d  Design NanoVDB layout  ← ENTRY POINT (parallel with 1.1)
  → g4eh  NanoLeaf flat view
    → jy23  NanoI1/NanoI2 flat views
      → 61ij  NanoRoot sorted table
        → icfa  NanoGrid build from Tree
          → 9og6  Value accessor on NanoGrid
            → tzd5  DDA on NanoGrid (also depends on 9ysk)
              → 61fz  Equivalence tests
```

### Files Modified

| File | Change |
|------|--------|
| `test/test_values.jl` | +10 read_dense_values unit tests (flags 0-6, half-prec, position) |
| `test/test_tree_read.jl` | **NEW** — 40 tests for TreeRead.jl utility + integration |
| `test/runtests.jl` | Include test_tree_read.jl |
| `src/Interpolation.jl` | Boundary-aware trilinear: `_is_background` check, nearest fallback |
| `test/test_interpolation.jl` | +2 boundary fallback tests |
| `src/Transforms.jl` | `inv_mat` field + `_invert_3x3`; simplified `world_to_index_float` |
| `Manifest.toml` | Removed from tracking |
| `teapot.png` | Removed from tracking |
| `scripts/` | 28 tracked debug scripts removed (kept render_vdb.jl, test_and_render_all.jl) |

### Next Priority

1. **`ovkr`** — Add StaticArrays.jl (gates Phase 1.1 + 1.2)
2. **`i70d`** — Design NanoVDB layout (gates Phase 1.3, parallelizable with 1.1)

---

## Previous Session (2026-02-15) - Fix 9 issues: perf + bugs

**Status**: 🟢 COMPLETE — 9 issues closed, 920 tests pass

### What Was Done

Worked through `bd ready` queue top-to-bottom, fixing bugs and implementing perf features.

| # | ID | Priority | Type | Fix |
|---|-----|----------|------|-----|
| 1 | `46r` | P1 | bug | TinyVDB `read_grid_compression` — propagate `header.is_compressed` for v220 files (was returning COMPRESS_NONE) |
| 2 | `50y1` | P1 | perf | `Mask{N,W}` prefix-sum — added `NTuple{W,UInt32}` for O(1) `count_on_before` (was O(W) loop over 512 words for I2) |
| 3 | `clws` | P1 | perf | `ValueAccessor{T}` — mutable cache for leaf/I1/I2 nodes; 5-8x speedup for trilinear (7/8 lookups hit same leaf) |
| 4 | `60i` | P2 | bug | TinyVDB `read_compressed_data` — added `abs(chunk_size)` cross-validation against `total_bytes` |
| 5 | `u1k` | P2 | bug | TinyVDB `read_metadata` — size prefixes from `read_i32` → `read_u32` (VDB spec uses unsigned) |
| 6 | `b93` | P2 | bug | `Binary.jl` — replaced `unsafe_load(Ptr{T}(...))` with `memcpy`-based `_unaligned_load` for ARM portability |
| 7 | `ql1` | P2 | bug | `volume(BBox)` — return `Int128` instead of `Int64` to avoid overflow for large bounding boxes |
| 8 | `fls` | P2 | bug | `File.jl` — `@warn` for unsupported grid value types instead of silent skip |
| 9 | `d9i` | P2 | bug | TinyVDB `read_transform` — accept `ScaleMap` and `ScaleTranslateMap` (same binary layout as Uniform variants) |
| 10 | `1xd` | P2 | bug | `sample_trilinear` — use `Int64` arithmetic to avoid `Int32` overflow on `coord+1` near typemax |

### Learnings

- **Mask prefix-sum**: Adding a `prefix::NTuple{W,UInt32}` field to the existing `Mask{N,W}` struct required updating all constructors. The inner constructor trick (`Mask{N,W}(words::NTuple{W,UInt64})`) that auto-computes prefix sums keeps call sites unchanged. One test used `(0b10110001,)` (Tuple{UInt8}) which the old implicit struct constructor auto-promoted but the new explicit constructor rejects — needed `UInt64(...)` cast.

- **`_unaligned_load` pattern**: Julia's `unsafe_load(Ptr{T}(...))` requires alignment on ARM. The portable fix is `ccall(:memcpy, ...)` into a `Ref{T}`. This is zero-cost on x86 (compiler elides the memcpy) and correct everywhere.

- **`ValueAccessor` design**: Mutable struct with `const tree` field (Julia 1.8+). Cache check is just `leaf_origin(c) == acc.leaf_origin` — a single `Coord` equality (3 Int32 compares). Falls through I1/I2 cache levels before full root traversal.

- **Beads sync prefix conflict**: `bd sync` fails with "prefix mismatch" when JSONL contains issues from multiple projects. Workaround: commit `.beads/` separately with `git add .beads/ && git commit`.

### Next Priority (from `bd ready`)

1. `90su` — Unit tests for `read_dense_values` (all 7 metadata flags)
2. `i4u4` — Unit tests for `TreeRead.jl` (518 LOC, zero tests)
3. `2zo` — Boundary-aware trilinear interpolation
4. `py5` — Delete ~65MB untracked image artifacts
5. `al6m` — Precompute matrix inverse in LinearTransform

---

## Previous Session (2026-02-14) - Code review + fix 10 bugs + 1 hygiene

**Status**: 🟢 COMPLETE — comprehensive code review, 77 issues created, 11 issues closed

### What Was Done

1. **Comprehensive 6-specialist code review** spawned in parallel:
   - Hygiene inspector (138 junk files found)
   - Julia idiomaticity expert (grade B overall, type instability issues, ~315 LOC duplication)
   - Test coverage reviewer (critical gap: Values.jl/TreeRead.jl have zero unit tests)
   - Line-by-line bug hunter (2 CRITICAL, 8 HIGH, 7 MEDIUM, 13 LOW bugs found)
   - Architecture reviewer (clean deps, over-exported API, path to 1.0)
   - Knuth algorithm analyst (count_on_before is O(512) should be O(1), ValueAccessor needed)

2. **Created 77 beads issues** with 23 dependency edges across 6 categories

3. **Fixed 7 bugs** (top of the priority queue):

| # | ID | Priority | Fix |
|---|-----|----------|-----|
| 1 | `yx7` | P0 CRITICAL | `read_tile_value` — added Int32/Int64/Bool specializations; generic now errors instead of calling `ltoh` on unsupported types |
| 2 | `k0a` | P0 CRITICAL | TinyVDB `read_compressed_data` — split `==0` (empty chunk, return zeros) from `<0` (uncompressed, read abs bytes) |
| 3 | `8mu` | P1 HIGH | Selection mask ternary inverted vs C++ — swapped to match `isOn→inactiveVal1` |
| 4 | `vgu` | P1 HIGH | v222+ tile values discarded — made I1TopoData/I2TopoData parametric on T, store `node_values` from topology pass |
| 5 | `339` | P1 HIGH | v220 header compression — use actually-read byte instead of hardcoding ZIP |
| 6 | `avn` | P1 HIGH | `read_mask` — throw BoundsError on truncated data instead of zero-padding |
| 7 | `ykk` | P1 HIGH | `read_active_values` — removed try/catch that swallowed BoundsError with `zero(T)` |
| 8 | `3ej` | P1 HIGH | Transforms.jl — replaced wrong 23-byte skip AffineMap fallback with clear error |
| 9 | `3di` | P1 HIGH | `read_bytes` — replaced `unsafe_wrap` aliased memory with safe byte slice copy |
| 10 | `2j4` | P1 TASK | Project.toml — moved Debugger/Infiltrator to extras, replaced placeholder UUID |

4. **Updated .gitignore** (`oq8`) — Manifest.toml, renders, debug scripts, IDE dirs (unblocks 5 hygiene issues)

### Test Results

```
920 pass, 0 fail, 0 errors (was 911)
```

### Files Modified

| File | Change |
|------|--------|
| `src/Values.jl` | Int32/Int64/Bool read_tile_value specializations; generic errors; selection mask ternary fix; removed BoundsError swallowing |
| `src/TreeRead.jl` | I1TopoData{T}/I2TopoData{T} parametric with node_values; tile construction uses actual values |
| `src/TinyVDB/Compression.jl` | Split empty chunk (==0) from uncompressed (<0) in read_compressed_data |
| `src/Masks.jl` | read_mask throws BoundsError on truncated data |
| `src/Header.jl` | v220 compression from actual byte, not hardcoded ZIP |
| `src/Transforms.jl` | Replaced wrong AffineMap fallback with clear ArgumentError |
| `src/Binary.jl` | Safe byte slice copy instead of unsafe_wrap |
| `Project.toml` | Debugger/Infiltrator to extras, proper UUID |
| `test/test_values.jl` | Tests for Int32/Int64/Bool read_tile_value + unsupported type error |
| `.gitignore` | Comprehensive patterns for Manifest.toml, renders, scripts, IDE |

### Next Priority (from `bd ready`)

1. `46r` — TinyVDB read_grid_compression returns COMPRESS_NONE for v220
2. `50y1` — Prefix-sum popcount (O(1) count_on_before)
3. `90su` — Unit tests for read_dense_values (all 7 metadata flags)
4. `i4u4` — Unit tests for TreeRead.jl
5. `60i` — TinyVDB read_compressed_data lacks abs(chunk_size) validation

---

## Previous Session (2026-02-14) - Fix level set rendering artifacts

**Status**: 🟡 PARTIAL — sphere tracer improved (step clamping, utility helpers added) but node boundary artifacts remain

### What Was Done

1. **Diagnosed the root cause thoroughly**: The level set renderer's artifacts come from trilinear interpolation corrupting SDF values at VDB tree node boundaries (8³ leaf, 16³ I1, 32³ I2). When `sample_trilinear` straddles a node boundary, some of the 8 corners return the background value (~0.15 for sphere.vdb) while others return real SDF values. The blended result is wrong, causing the tracer to take wrong-sized steps.

2. **Key finding: SDF values are in WORLD units** (not voxel units). For sphere.vdb: background=0.15, voxel_size=0.05, so narrow band is 3 voxels wide. The step distance `abs(dist)` is already in world units — no conversion needed.

3. **Added step clamping** to `sphere_trace`: `step = min(abs(dist), vs * 2.0)` prevents overshooting. The original code had no clamp and jumped by full `background` (0.15 = 3 voxels) when outside the band.

4. **Added utility functions** for future use:
   - `_safe_sample_nearest` — NN sampling (immune to trilinear boundary corruption)
   - `_bisect_surface` — binary search between two t values to find exact zero-crossing
   - `_estimate_normal_safe` — index-space gradient with one-sided difference fallback
   - `_gradient_axis_safe` — per-axis gradient that handles band-edge samples

5. **Explored multiple approaches** (documented in detail below for next session)

### Approaches Tried (for next session's reference)

| Approach | Result | Issue |
|----------|--------|-------|
| NN stepping + threshold | 0 bg, scattered holes | NN quantization: some rays step past threshold |
| NN + sign-change detection + bisection | 0 bg, correct shape | False crossings at node boundaries (SDF jumps +band to -background) |
| NN sign-change + false-crossing rejection | 884 bg, most rejected | Too aggressive filter, misses real crossings too |
| Hybrid (trilinear step + NN sign-change backup) | 0 bg | Grid artifacts remain from trilinear normal corruption |
| Trilinear + step clamp (committed) | 0 bg, reduced artifacts | Thin dark lines at node boundaries remain |

### Remaining Problem: Node Boundary Artifacts

**The fundamental issue**: Trilinear interpolation is structurally broken at node boundaries because `get_value` returns `tree.background` for coordinates outside the tree. When trilinear's 8-corner samples straddle a boundary between a populated leaf and empty space, the result is garbage.

**What would fix this properly** (future work):
1. **DDA tree traversal** — walk the ray through the tree structure leaf-by-leaf (like OpenVDB's `VolumeRayIntersector`), only sampling within populated nodes. This is the correct approach used by production renderers.
2. **Boundary-aware interpolation** — modify `sample_trilinear` to detect when any of the 8 corners returns background and fall back to nearest-neighbor for that sample.
3. **Active-voxel-aware gradient** — for normals, only use neighbors that are active voxels in the tree (not background fill).

### Files Modified

| File | Change |
|------|--------|
| `src/Render.jl` | Step clamping in `sphere_trace`; added `_safe_sample_nearest`, `_bisect_surface`, `_estimate_normal_safe`, `_gradient_axis_safe` utilities |

### Test Results

```
911 pass, 0 fail, 0 errors (unchanged)
```

---

## Previous Session (2026-02-14) - Fix multi-grid + render all VDBs

**Status**: 🟡 PARTIAL — multi-grid parsing fixed (12/12 VDBs), renders generated but level set renderer has artifacts

### What Was Done

1. **Fixed multi-grid VDB parsing** (3 bugs):
   - Grid descriptors interleaved with data → merged descriptor+grid loop with end_offset seeking
   - `parse_value_type` false-matched `_HalfFloat` suffix → regex-based token extraction + `vec3s` support
   - Half-precision `value_size` for vec3 was 2 instead of 6 → threaded `value_size` through v220 reader

2. **Fixed NaN property test** — added `isnan` guard (NaN == NaN is false in IEEE 754)

3. **Rendered all 20 VDB files** to PNG at 512x512 → `renders/` directory

### Results

```
911 pass, 0 fail, 0 errors
20/20 VDB files parse, 18/20 rendered to PNG
```

### Next Task: Fix Level Set Rendering Artifacts

**Problem**: Level set renders (sphere, armadillo, bunny, ISS, etc.) show grid-like scaffolding, missing pixels, and dark lines at node boundaries. The sphere is worst — clearly shows internal 8³/16³/32³ block structure. Fog volumes (explosion, fire, smoke, bunny_cloud) render fine.

**Root Cause Analysis** (investigation done, fix NOT implemented):

The sphere tracer in `src/Render.jl` has these issues:

1. **Trilinear interpolation corrupts SDF at narrow-band edges** (`Interpolation.jl:18-41`):
   When `sample_trilinear` straddles a node boundary, some of the 8 corners return the background value (typically 3.0) while others return actual SDF values. The interpolated result is a meaningless number between the true SDF and background. This causes the tracer to take wrong-sized steps and either overshoot or miss the surface.

2. **Background step is too aggressive** (`Render.jl:125-128`):
   When `abs(dist - background) < 1e-6`, the tracer steps by the full background value (~3.0 voxels). This overshoots thin features and surface details near node edges.

3. **No distinction between "outside narrow band" and "near band edge"**:
   A trilinear sample near a band boundary might return 2.5 (just below background=3.0) — this looks like a valid SDF distance but is actually garbage from interpolating with background values.

**Suggested Fix Strategy**:

1. **Use nearest-neighbor for sphere trace stepping** — `sample_world(grid, point; method=:nearest)` avoids trilinear artifacts at band edges. Only matters for the step distance, not final shading.

2. **Clamp max step size** — `step = min(abs(dist), narrow_band_width * 0.8)` prevents overshooting. The narrow band width is typically `background` (3 voxels × voxel_size).

3. **Conservative fallback stepping** — when the sample returns background or near-background, use a fixed small step (e.g., `vs * 1.0`) to walk through the gap rather than jumping by `background`.

4. **Use trilinear only for normals** — once a hit is found (we're guaranteed to be well within the band), trilinear gives smooth normals.

**Key files**:
- `src/Render.jl:76-136` — `sphere_trace` function (the main thing to fix)
- `src/Render.jl:168-181` — `_safe_sample` (wraps `sample_world`)
- `src/Render.jl:188-197` — `_estimate_normal_safe` (normal estimation)
- `src/Interpolation.jl:18-41` — `sample_trilinear` (the 8-corner trilinear sampler)
- `src/Accessors.jl:14-66` — `get_value` (returns background when coordinate not in tree)

**Quick test**: render just the sphere to iterate fast:
```julia
julia --project -e '
using Lyr
vdb = parse_vdb("test/fixtures/samples/sphere.vdb")
grid = vdb.grids[1]
cam = Camera((3.0, 2.0, 3.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 40.0)
pixels = render_image(grid, cam, 256, 256; max_steps=500)
write_ppm("sphere_test.ppm", pixels)
'
convert sphere_test.ppm sphere_test.png
```

### Files Modified This Session

| File | Change |
|------|--------|
| `src/File.jl` | Merged descriptor+grid loops; seek to end_offset; vec3 half-precision value_size |
| `src/GridDescriptor.jl` | Regex-based value type parsing; vec3s support |
| `src/TreeRead.jl` | `_decode_values` helper; threaded `value_size` through v220 |
| `src/Values.jl` | Half-precision conversion in v220 leaf values path |
| `test/test_integration.jl` | Added multi-grid tests (explosion, fire, smoke2) |
| `test/test_properties.jl` | NaN guard in tile property test |
| `renders/*.png` | 18 rendered images (not committed — in .gitignore) |

---

## Previous Session (2026-02-14) - Fix multi-grid VDB parsing

**Status**: 🟢 COMPLETE — 12/12 OpenVDB test files parse, 911 tests pass

### Summary

Fixed 3 bugs preventing multi-grid VDB files (explosion, fire, smoke2) from parsing:

1. **Grid descriptor interleaving**: Descriptors are interleaved with grid data in VDB files, not stored contiguously. `File.jl` now reads each descriptor then seeks to `end_offset` for the next.

2. **`parse_value_type` false matching**: Loose `contains("Float")` matched the `_HalfFloat` suffix, misidentifying `Tree_vec3s_5_4_3_HalfFloat` as `Float32`. Now extracts value type token via regex. Also added `vec3s` support (= `Vec3f` = `NTuple{3, Float32}`).

3. **Half-precision vec3 `value_size`**: Was `2` (scalar Float16) instead of `6` (3 × Float16). Threaded `value_size` through entire v220 tree reader chain and added `_decode_values` helper for Float16→T conversion.

Also fixed property test NaN bug (`NaN == NaN` is `false`).

### Results

```
911 pass, 0 fail, 0 errors (was 890 pass, 0 fail, 1 error)
20/20 VDB files parse: 12 OpenVDB test suite + 8 original fixtures
```

### Files Modified

| File | Change |
|------|--------|
| `src/File.jl` | Merged descriptor+grid loops; seek to end_offset between grids; vec3 half-precision value_size |
| `src/GridDescriptor.jl` | Regex-based value type parsing; vec3s support |
| `src/TreeRead.jl` | `_decode_values` helper; threaded `value_size` through v220 functions |
| `src/Values.jl` | Half-precision conversion in v220 leaf values path |
| `test/test_integration.jl` | Added multi-grid tests (explosion, fire, smoke2) |
| `test/test_properties.jl` | NaN guard in tile property test |

---

## Previous Session (2026-02-14) - Download OpenVDB test suite + render scripts

**Status**: 🟢 COMPLETE — 12 VDB files downloaded, test/render script created

### Summary

1. **Rendered bunny_cloud.vdb** at 1024x1024 using volumetric ray marching (fog volume, not level set). Iterated through cloud renderer → isosurface renderer → smoothed isosurface with blurred density sampling. Cloud data is inherently turbulent so surface is rough.

2. **Downloaded official OpenVDB test suite** from artifacts.aswf.io into `test/fixtures/openvdb/`. 12 files (~1GB total) covering level sets and fog volumes at various scales.

3. **Created `scripts/test_and_render_all.jl`** — parses every VDB file and raytraces each one (sphere trace for level sets, volume march for fog volumes). Auto camera placement. Outputs to `renders/`.

### Parse Results

| File | Size | Version | Status | Type |
|------|------|---------|--------|------|
| armadillo.vdb | 61M | v222 | OK | Level set, 121k leaves |
| buddha.vdb | 38M | v222 | OK | Level set, 74k leaves |
| bunny.vdb | 15M | v222 | OK | Level set, 29k leaves |
| crawler.vdb | 444M | v222 | OK | Level set, 760k leaves |
| dragon.vdb | 63M | v222 | OK | Level set, 124k leaves |
| iss.vdb | 212M | v222 | OK | Level set, 367k leaves |
| torus_knot_helix.vdb | 25M | v222 | OK | Level set, 65k leaves |
| venusstatue.vdb | 27M | v222 | OK | Level set, 29k leaves |
| smoke1.vdb | 2.4M | v222 | OK | Fog volume, 3k leaves |
| explosion.vdb | 75M | v220 | FAIL | Multi-grid descriptor bug |
| fire.vdb | 28M | v222 | FAIL | Multi-grid descriptor bug |
| smoke2.vdb | 30M | v220 | FAIL | Multi-grid descriptor bug |

9/12 parse successfully. 3 failures are multi-grid files — second grid descriptor reads garbage string length. Pre-existing bug in `read_grid_descriptor` when parsing files with >1 grid.

### Files Created/Modified

| File | Change |
|------|--------|
| `test/fixtures/openvdb/` | **NEW** — 12 VDB files from official OpenVDB samples |
| `scripts/render_bunny.jl` | **NEW** — volumetric/isosurface renderer for bunny_cloud.vdb |
| `scripts/test_and_render_all.jl` | **NEW** — parse + render all VDBs, summary table |
| `.gitignore` | Added `test/fixtures/openvdb/` (large binaries, not committed) |

### Known Bugs Found

1. **Multi-grid descriptor parsing**: Files with >1 grid (explosion, fire, smoke2) fail when reading the 2nd grid descriptor — garbage string length in `read_string_with_size`. Likely the grid descriptor loop doesn't account for some v220/multi-grid format difference.

### Next Steps

- Fix multi-grid descriptor parsing (3 files)
- Run `scripts/test_and_render_all.jl` to render all files
- The smooth `bunny.vdb` (level set) can be rendered beautifully with the existing sphere tracer

---

## Previous Session (2026-02-14) - Fix v220 tree reader for bunny_cloud.vdb

**Status**: 🟢 COMPLETE — 2 issues closed, 0 errors remaining

### Summary

Fixed the v220 (pre-v222) tree reader so bunny_cloud.vdb parses correctly. Three bugs:

1. **Internal node values format**: v220 stores non-child values as a compressed block (`childMask.countOff()` values, no metadata byte), not as (value, active_byte) pairs. See tinyvdbio.h:2266.

2. **Two-phase structure**: v220 `readTopology` reads ALL topology for ALL root children first, then `readBuffers` reads ALL leaf values. Our code was interleaving per-subtree. Split into `read_i2_topology_v220` + `materialize_i2_values_v220` (mirrors v222+ architecture).

3. **Leaf buffer format**: v220 `readBuffers` re-emits value_mask (64 bytes) before origin+numBuffers+data, and stores ALL 512 values compressed (not just active values).

### Results

```
891 pass, 0 fail, 0 errors (was 678 pass, 0 fail, 2 errors)
```

All 8 test VDB files now parse successfully through Main Lyr.

### Files Modified

| File | Change |
|------|--------|
| `src/TreeRead.jl` | Replaced `read_internal2_subtree_interleaved` with `I2TopoDataV220`, `read_i2_topology_v220`, `materialize_i2_values_v220`. Restructured `read_tree_interleaved` into two-phase. |
| `src/Values.jl` | Fixed v220 leaf path: added 64-byte value_mask skip, changed expected_size to 512*sizeof(T) |

### Issues Closed

| ID | Title |
|---|---|
| `path-tracer-0ij` | Fix v220 tree interleaved reader for bunny_cloud.vdb |
| `path-tracer-2ul` | Promote TinyVDB as primary parser (Phase 3 umbrella) |

---

## Previous Session (2026-02-14) - Fix smoke.vdb + rearch (delete TinyVDB routing)

**Status**: 🟢 COMPLETE — 2 issues closed

### Summary

1. **smoke.vdb fix (d42)**: Root cause was three bugs in Main Lyr's transform/tree reading:
   - `Transforms.jl`: Bogus `pos += 4` after UniformScaleMap and `pos += 23` after UniformScaleTranslateMap. Removed both.
   - `Grid.jl`: Missing `buffer_count` read between transform and background. Added it.
   - `TreeRead.jl`: Spurious `background_active` byte read for fog volumes. Removed it.

2. **Rearch / TinyVDB demotion (ac4)**: Main Lyr is now the sole production parser. TinyVDB is test-only.

### Issues Closed

| ID | Title |
|---|---|
| `path-tracer-d42` | Fix legacy parser smoke.vdb structural failure |
| `path-tracer-ac4` | Delete TinyVDBBridge, demote TinyVDB to test-only |
