# Lyr.jl Handoff Document

---

## Latest Session (2026-02-14) - Phase 3 Step 5: Parser equivalence tests

**Status**: 🟢 COMPLETE — 1 issue closed, 2 new bugs filed

### Summary

Added `test/test_parser_equivalence.jl` that parses all 6 TinyVDB-compatible files with BOTH the legacy (Main Lyr) and TinyVDB parsers, then compares tree structure and voxel values. TinyVDB serves as permanent test oracle.

### Findings

| File | Structure | Values | Notes |
|------|-----------|--------|-------|
| cube.vdb | MATCH | BROKEN | 455/500 voxels differ |
| icosahedron.vdb | MATCH | BROKEN | NaN diffs |
| smoke.vdb | BROKEN | BROKEN | Legacy: 0 leaves, all tiles (31M active vs 1M) |
| sphere.vdb | MATCH | BROKEN | Main returns NaN for active voxels |
| torus.vdb | MATCH | BROKEN | Garbage values (1.5e9) |
| utahteapot.vdb | MATCH | BROKEN | max_diff=0.51 |

**Key insight**: The v222+ topology fix worked — structure matches for 5/6 files. But the legacy parser's value reading phase is systematically broken for all files. TinyVDB values are correct.

### Files Modified

| File | Change |
|------|--------|
| `test/test_parser_equivalence.jl` | **NEW** — 54 tests (46 pass, 8 broken) |
| `test/runtests.jl` | Added include for equivalence tests |

### Test Results
```
812 pass, 0 fail, 2 errors (bunny_cloud×2 — pre-existing), 8 broken (new equivalence markers)
```

### Issues

| ID | Title | Status |
|---|---|---|
| `path-tracer-a56` | Parser equivalence tests | ✅ CLOSED |
| `path-tracer-nkg` | Fix legacy parser v222+ value reading (all files) | 🔲 NEW P1 |
| `path-tracer-d42` | Fix legacy parser smoke.vdb structural failure | 🔲 NEW P2 |

### Next Steps

| ID | P | Title | Status |
|---|---|---|---|
| `path-tracer-nkg` | P1 | Fix legacy parser v222+ value reading | Ready |
| `path-tracer-d42` | P2 | Fix legacy parser smoke.vdb structural failure | Ready |
| `path-tracer-0ij` | P2 | Fix v220 tree interleaved reader for bunny_cloud.vdb | Ready |
| `path-tracer-2ul` | P2 | Promote TinyVDB as primary parser (umbrella) | In Progress |

---

## Previous Session (2026-02-14) - Phase 3 Step 3: Replace heuristic metadata parsing

**Status**: 🟢 COMPLETE — 1 issue closed, 1 new bug filed

### Summary

Replaced ~250 lines of heuristic metadata parsing with ~95 lines of spec-driven code. Fixed two bugs:
1. **Phantom `tree_version` field**: `read_grid_metadata` consumed 8 bytes (tree_version + count) but the format only has count (4 bytes). The "tree_version" was actually the metadata count, and the "metadata_count" was the first key's size prefix.
2. **File-level v222+ metadata**: `skip_metadata_value_heuristic` read values without the required u32 size prefix. Replaced with `skip_file_metadata` that reads the size prefix correctly.

### Files Modified

| File | Change |
|------|--------|
| `src/Metadata.jl` | Complete rewrite: removed `is_printable_ascii`, `is_metadata_entry`, `skip_metadata_value_heuristic`, `read_file_metadata_v220`, heuristic key detection, `while true` loop. New: `skip_file_metadata` + clean `read_grid_metadata` |
| `src/File.jl` | Replaced v220/v222+ metadata branching with single `skip_file_metadata` call |
| `src/Exceptions.jl` | Removed unused `UnknownMetadataTypeError`, `MetadataParseError` |
| `src/Lyr.jl` | Removed unused exception exports |

### Test Results
```
766 pass, 0 fail, 2 errors (bunny_cloud×2 — pre-existing v220 tree reader bug)
```

### Issues

| ID | Title | Status |
|---|---|---|
| `path-tracer-9re` | Replace heuristic metadata parsing | ✅ CLOSED |
| `path-tracer-0ij` | Fix v220 tree interleaved reader for bunny_cloud.vdb | 🔲 NEW (the real cause of bunny_cloud errors) |

### Key Finding

bunny_cloud.vdb errors are NOT caused by metadata parsing. The metadata heuristic happened to produce the correct pos for bunny_cloud. The actual bug is in `read_tree_interleaved` / `read_leaf_values` for v220 format — `CompressionBoundsError` at position 83933 with garbage chunk_size, indicating position drift during tree reading.

### Next Steps

| ID | P | Title | Status |
|---|---|---|---|
| `path-tracer-0ij` | P2 | Fix v220 tree interleaved reader for bunny_cloud.vdb | Ready |
| `path-tracer-a56` | P2 | Parser equivalence tests (Main Lyr == TinyVDB) | Ready |
| `path-tracer-2ul` | P2 | Promote TinyVDB as primary parser (umbrella) | Ready |

---

## Previous Session (2026-02-14) - Phase 3: Fix v222+ Parser + Half-Precision + Unsupported Grid Types

**Status**: 🟢 COMPLETE — 3 issues closed, 1 bug fix, pushed

### Summary

Implemented Phase 3 Steps 1, 2, and 4 of the parser unification plan, plus fixed the sphere_points.vdb error.

1. **Root bug fix**: Added `read_dense_values` calls after I2/I1 mask reads in `read_i2_topology_v222` to skip embedded internal node values (ReadMaskValues format). torus.vdb: 1→8 root children.
2. **Removed heuristics**: Deleted `is_valid_i2_origin`, padding detection, `pos=values_start` seek, `values_start`/`block_offset` parameters. ~40 lines deleted.
3. **Half-precision**: Threaded `value_size` kwarg through entire v222+ pipeline. `read_dense_values` reads Float16 and widens to Float32. cube.vdb now parses via legacy parser.
4. **Unsupported grid types**: `parse_value_type` returns `nothing` for unknown types (e.g. PointDataIndex32). File.jl skips these grids. Fixes sphere_points.vdb crash.

### Files Modified

| File | Change |
|------|--------|
| `src/TreeRead.jl` | +2 skip calls, removed heuristics (~40 lines deleted), threaded `value_size` kwarg, fixed missing `mask_compressed` arg in pre-v222 path |
| `src/Grid.jl` | Removed `block_offset`, added `value_size` kwarg |
| `src/File.jl` | Detect `_HalfFloat` suffix, skip unsupported grid types via `end_offset` |
| `src/Values.jl` | `read_dense_values` + `read_leaf_values` accept `value_size` kwarg, new `_read_value` helper for Float16 |
| `src/GridDescriptor.jl` | `parse_value_type` returns `nothing` for unsupported types |
| `test/test_integration.jl` | +2 regression tests (legacy v222+ topology, half-precision), fixed sphere_points expectation |
| `test/test_file.jl` | Updated `parse_value_type("unknown")` test |

### Test Results
```
766 pass, 0 fail, 2 errors (bunny_cloud×2 only — needs heuristic metadata fix)
```

### Issues Closed

| ID | Title |
|---|---|
| `path-tracer-utb` | Add skip_internal_values to v222+ topology pass ✅ |
| `path-tracer-y63` | Remove block_offset seek and heuristic guards ✅ |
| `path-tracer-5ld` | Add half-precision (Float16) support to Main Lyr ✅ |

### Remaining Errors

bunny_cloud.vdb (v220, Zlib) — `CompressionBoundsError: chunk_size=1152921521786716160`. The heuristic metadata parser (`skip_metadata_value_heuristic`) miscounts bytes for v220 format, causing pos misalignment when reading tree data. Fix: `path-tracer-9re` (replace heuristic metadata parsing).

### Next Steps (Phase 3 remaining)

| ID | P | Title | Status |
|---|---|---|---|
| `path-tracer-9re` | P2 | Replace heuristic metadata parsing | Ready — fixes bunny_cloud errors |
| `path-tracer-a56` | P2 | Parser equivalence tests (Main Lyr == TinyVDB) | Ready |
| `path-tracer-2ul` | P2 | Promote TinyVDB as primary parser (umbrella) | Ready |

---

## Previous Session (2026-02-13) - Parser Unification Analysis + Phase 3 Plan

**Status**: 🟡 ANALYSIS COMPLETE — Implementation not started

### Summary

Conducted deep comparative analysis of Main Lyr vs TinyVDB parsers. Identified the exact root cause of Main Lyr's v222+ parsing bugs and designed a surgical fix strategy. Updated PRD.md with Phase 3 plan. Created beads issues for all implementation steps.

### Key Finding: The Bug Is One Missing Function Call

Main Lyr's `read_i2_topology_v222` (TreeRead.jl:90-117) reads I2/I1 masks but does **not** skip the embedded internal node values that follow them in v222+ format. This leaves `pos` wrong after topology, forcing the compensating seek at line 335 (`pos = values_start`). All heuristic guards (origin validation, padding detection) are band-aids for this misalignment.

TinyVDB handles this correctly via `skip_mask_values` calls after each mask read. Porting this single concept into Main Lyr's topology pass fixes the root cause.

### Architecture Decision

**Fix Main Lyr, keep TinyVDB as test oracle.** Rationale:
- Main Lyr's type system (`LeafNode{T}` + `NTuple{512,T}`, `Mask{N,W}` + `NTuple{W,UInt64}`) is superior Julia — immutable, parametric, zero-alloc
- TinyVDB's mutable `Vector`-based types would need complete rewrite to be idiomatic
- Main Lyr already has Float64, Vec3f, Blosc, v220, full feature stack (accessors, rendering)
- The fix is surgical: ~30 lines added, ~40 lines deleted in TreeRead.jl
- Two independent implementations that agree is stronger correctness than one

### Phase 3 Steps (see PRD.md for details)

1. Add `skip_internal_values` to v222+ topology pass (TreeRead.jl)
2. Remove seek to `block_offset` + heuristic guards (TreeRead.jl)
3. Replace heuristic metadata parsing (Metadata.jl)
4. Add half-precision support to Main Lyr
5. Parser equivalence tests (Main Lyr == TinyVDB on all compatible files)
6. Delete TinyVDBBridge, demote TinyVDB to test-only

### Files Modified

| File | Change |
|------|--------|
| `PRD.md` | Complete rewrite — Phase 3 plan with comparative analysis |
| `HANDOFF.md` | This session summary |

### Test Results

No code changes — existing tests unchanged:
```
TinyVDB: 308 pass, 0 fail
Full suite: 756 pass, 0 fail, 3 errors (pre-existing)
```

---

## Previous Session (2026-02-12) - TinyVDB Routing + Transform Support

**Status**: 🟢 COMPLETE - 2 issues closed

### Summary

Completed two issues: (1) `parse_vdb` now routes compatible files (v222+, Float32, no Blosc) through TinyVDB with try-catch fallback to legacy. This revealed that TinyVDB's sequential parser correctly finds 8 root I2 children for torus.vdb (one per octant) vs legacy's 1 — updated reference values accordingly. (2) Added `UniformScaleTranslateMap` support: `TinyGrid` now stores translation, bridge creates `LinearTransform` when translation is non-zero (e.g. smoke.vdb).

### Session Changes

| File | Change |
|------|--------|
| `src/File.jl` | Renamed `parse_vdb(bytes)` → `_parse_vdb_legacy(bytes)`. New `parse_vdb(bytes)` routes through TinyVDB when `is_tinyvdb_compatible`, falls back to legacy. |
| `src/TinyVDB/Parser.jl` | `read_transform` returns `(voxel_size, translation, pos)`. `TinyGrid` gains `translation::NTuple{3,Float64}`. |
| `src/TinyVDBBridge.jl` | `convert_tinyvdb_grid` creates `LinearTransform` for non-zero translations, `UniformScaleTransform` otherwise. |
| `test/test_integration.jl` | Updated torus.vdb: 8 root children, 6044 leaves, 1119158 active voxels |
| `test/test_tinyvdb.jl` | Updated for new `read_transform` signature and `TinyGrid` constructor |
| `test/fixtures/reference_values.json` | Updated torus.vdb reference values |

### Routing Summary

| File | Path | Reason |
|------|------|--------|
| cube, icosahedron, smoke, sphere, torus, utahteapot | TinyVDB | v222+, Float32, no Blosc |
| bunny_cloud | Legacy | v220 |
| sphere_points | Legacy | Non-Float32 grid type |

### Test Results

```
Full Pkg.test(): 756 pass, 0 fail, 3 errors (pre-existing: bunny_cloud×2, sphere_points×1)
```

### Issues Closed

| ID | Title |
|---|---|
| `path-tracer-am0` | Route `parse_vdb` through TinyVDB for compatible files ✅ |
| `path-tracer-90i` | Support non-UniformScaleMap transforms in TinyVDB bridge ✅ |

### Open Issues

| ID | P | Title | Status |
|---|---|---|---|
| `path-tracer-2ul` | P2 | Promote TinyVDB as primary parser (umbrella) | Ready (all deps resolved) |
- 194k of 1M pixels hit the teapot surface

---

## Previous Session (2026-02-12) - TinyVDB → Raytracer Bridge

**Status**: 🟢 COMPLETE - cube.vdb renders to PPM via sphere tracing

### Summary

Created a conversion layer (`src/TinyVDBBridge.jl`) that transforms TinyVDB parsed data into Lyr tree types, enabling the existing raytracer to operate on TinyVDB-parsed files. End-to-end pipeline: parse VDB → convert → sphere trace → PPM image.

### Changes

| File | Change |
|------|--------|
| `src/TinyVDB/Parser.jl` | `TinyGrid` gains `voxel_size::Float64`; `read_transform` returns `(Float64, Int)` |
| `src/TinyVDBBridge.jl` | **NEW** — conversion layer (coord, mask, leaf, internal, root, grid) |
| `src/Lyr.jl` | Includes TinyVDB submodule + bridge, exports `convert_tinyvdb_grid` |
| `src/Render.jl` | `sphere_trace` + `render_image` pre-compute bbox once (was O(voxels) per ray) |
| `test/test_tinyvdb.jl` | Updated for new `TinyGrid` constructor and `read_transform` signature |
| `test/test_tinyvdb_bridge.jl` | **NEW** — 41 tests (unit + cube.vdb integration + render) |
| `test/runtests.jl` | Includes bridge tests |
| `scripts/render_cube.jl` | **NEW** — demo script |

### Key Decisions

- **Conversion approach**: Convert TinyVDB types → Lyr types once after parsing. Raytracer unchanged.
- **Origin reconstruction**: TinyVDB doesn't store node origins. Reconstructed from parent origin + child linear index using existing `child_origin_internal1/2`.
- **Internal tile values**: TinyVDB skips them; bridge uses background value (correct for level-set grids).
- **Performance fix**: `active_bounding_box` was called per-ray in `sphere_trace`. Now pre-computed once in `render_image` and passed via `world_bounds` kwarg.

### Test Results
```
TinyVDB tests:  283 pass (all still pass with Parser.jl changes)
Bridge tests:    41 pass (coord, mask, leaf, I1, grid conversion + cube.vdb + render)
```

### Render Output
- 512x512 sphere-traced cube in 13.5s
- Camera at (12, 8, 12) looking at origin, FOV 50
- Lambertian shading with proper edges and perspective

### Remaining Work
- Full test suite (`Pkg.test()`) not yet run — may have issues with TinyVDB inclusion in Lyr
- `active_bounding_box` is O(active_voxels) — could be computed from tree structure in O(leaves)
- Internal node tile values are lost (only matters for fog volumes, not level sets)
- Only `UniformScaleMap` transform supported

---

## Previous Session (2026-02-12) - Fix cube.vdb BoundsError (Half Precision)

**Status**: 🟢 COMPLETE - cube.vdb parses successfully, all 283 TinyVDB tests pass

### Root Cause

cube.vdb stores values as **Float16 (half precision)** — the grid type is `Tree_float_5_4_3_HalfFloat`. All value-reading code hardcoded `element_size=4` (Float32), consuming twice the bytes per value. This caused accumulated position drift until BoundsError at leaf ~3175 of 6812.

### Fix

Threaded `value_size` parameter (2 for half, 4 for float) through the entire read pipeline:
- `Compression.jl`: Added `read_float_values()` that handles Float16→Float32 conversion
- `Topology.jl`: `skip_mask_values`, `read_internal_topology`, `read_root_topology` accept `value_size`
- `Values.jl`: `read_leaf_values`, `read_internal_values`, `read_tree_values` accept `value_size`
- `Parser.jl`: `read_grid` determines `value_size` from `gd.half_precision`

### Diagnostic Finding

The topology phase (pos after topology = 514618 = block_pos+1, diff=0) was already correct because internal nodes in this level-set grid have ~0 tile values, making element_size irrelevant for them.

### Test Results
```
TinyVDB tests: 283 pass, 0 fail (including cube.vdb end-to-end)
Full suite:    514 pass, 4 errors (all pre-existing in main Lyr, not TinyVDB)
```

---

## Previous Session (2026-02-12) - Full Code Review + Values.jl Fix

**Status**: 🟡 SUPERSEDED by half-precision fix above

### Summary

Conducted full-scale code review with 9 parallel subagents (8 Sonnet + 1 Opus). Created comprehensive PRD at `PRD.md`. Then implemented the critical fix to `read_leaf_values` in `src/TinyVDB/Values.jl`.

### Key Finding

All 9 agents converged on the same diagnosis: **one function** (`read_leaf_values`) was the root cause. It was missing reads for `inactiveVal0`, `inactiveVal1`, and `selection_mask` after `per_node_flag`, and did not reconstruct the full 512-value buffer from compressed active-only data.

The Julia code was mirroring the **buggy** `ReadBuffer` from `reference/tinyvdbio.h` (line 2352). The **correct** algorithm is `ReadMaskValues` (line 2017).

### Changes Made

1. **`src/TinyVDB/Values.jl`** - Complete rewrite:
   - Removed duplicate constant definitions (now only in Topology.jl)
   - Added `background::Float32` parameter to `read_leaf_values` and `read_internal_values`
   - `read_tree_values` extracts background from `root.background`
   - Implemented full ReadMaskValues algorithm:
     - Reads `inactiveVal0` (conditional on flags 2, 4, 5)
     - Reads `inactiveVal1` (conditional on flag 5)
     - Reads `selection_mask` (conditional on flags 3, 4, 5)
     - Reconstructs full 512-value buffer with inactive value fill

2. **`test/test_tinyvdb.jl`** - Added tests:
   - Flag 0: inactive = +background (2 active values, verify inactive fill)
   - Flag 1: inactive = -background
   - Flag 2: one inactive val read from stream
   - Flag 3: selection mask with bg/-bg
   - Flag 5: two inactive vals + selection mask
   - End-to-end: cube.vdb integration test (currently failing)

3. **`PRD.md`** - Created comprehensive Product Requirements Document

### Test Results

```
Unit tests:  266 pass, 0 fail (up from 247)
  - All original tests still pass
  - 5 new mask compression tests pass
  - 1 new end-to-end test added (cube.vdb - still errors)
```

### Remaining Issue: cube.vdb BoundsError

The cube.vdb integration test still crashes with:
```
BoundsError: attempt to access 3862089-element Vector{UInt8} at index [3861793:3863072]
```

The crash happens at `Compression.jl:112` inside `read_leaf_values`. The Values.jl fix is correct (all synthetic unit tests pass), which means the stream position is **already wrong** when entering the last leaf nodes. The bug is likely in one of:

1. **`skip_mask_values` in Topology.jl** - May be skipping wrong number of bytes during internal node topology reading (this is the most likely cause since it mirrors the same ReadMaskValues algorithm)
2. **Some other upstream position error** - Could be in metadata, transform, or grid descriptor reading

### Next Steps (Priority Order)

1. **Debug the stream position drift** - Add position logging to trace where `pos` diverges from expected values during cube.vdb parsing. Compare against a C++ reference parse.
2. **Verify `skip_mask_values` in Topology.jl** - Compare byte-for-byte against the `ReadMaskValues` seek path in tinyvdbio.h (the `seek=true` code path)
3. **Consider dumping reference positions** - Write a small C++ program using tinyvdbio.h that prints stream positions at each node to compare against Julia

### Architecture Decision

**TinyVDB is the path forward.** The main Lyr implementation's offset-seeking approach is fundamentally fragile. Once TinyVDB parses correctly, promote it as the primary parser and layer Accessors/Interpolation/Ray/Render on top.

### Files Modified This Session

| File | Change |
|------|--------|
| `src/TinyVDB/Values.jl` | Complete rewrite with ReadMaskValues algorithm |
| `test/test_tinyvdb.jl` | +5 mask compression tests, +1 cube.vdb integration test |
| `PRD.md` | New - comprehensive project requirements document |

---

## Previous Session (2026-01-11) - TinyVDB Audit Progress

**Status**: 2/10 audits complete, Parser.jl fixed

### Fixes Applied

1. **Parser.jl `read_transform`** - Fixed case and byte count (120B not 12)
2. **Parser.jl `read_metadata`** - Added size prefixes
3. **Parser.jl `read_grid`** - Added buffer_count read

### Audit Issues Status

| Issue ID | File | Status |
|----------|------|--------|
| path-tracer-g73 | Binary.jl | ✅ CLOSED (PASS) |
| path-tracer-o0y | Parser.jl | ✅ CLOSED (4 bugs fixed) |
| path-tracer-2yl | Topology.jl | open (Int32/Int64 mismatch was fixed, but skip_mask_values may have position bugs) |
| path-tracer-31s | Values.jl | ✅ REWRITTEN this session |
| path-tracer-btf | Compression.jl | open (appears correct per review) |
| path-tracer-z0t | GridDescriptor.jl | open (appears correct per review) |
| path-tracer-dwx | Header.jl | open (minor: VDB_MAGIC constant wrong, unused) |
| path-tracer-5vr | Mask.jl | open (appears correct per review) |
| path-tracer-kck | Types.jl | open (appears correct per review) |
| path-tracer-3jb | TinyVDB.jl | open (module wrapper, fine) |
