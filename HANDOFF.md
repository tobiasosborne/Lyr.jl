# Lyr.jl Handoff Document

---

## Latest Session (2026-02-14) - Code review + fix 10 bugs + 1 hygiene

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
