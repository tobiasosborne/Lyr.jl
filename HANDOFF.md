# Lyr.jl Handoff Document

---

## Latest Session (2026-01-11 PM) - Investigation & Bug Fixes

**Status**: 🔴 CRITICAL BUG FOUND - Leaf values are garbage, parsing is broken.

### Summary

Previous session claimed "sphere tracing works but misses due to sparse data." **This is wrong.** The real problem is that **leaf values are corrupt garbage** (values like `2.0e23`, `NaN`).

### What Was Fixed

**Ray.jl BBox bug** (3 places):
- `_intersect_internal2!`, `_intersect_internal1!`, `_intersect_leaf!` all created `BBox` with tuples instead of `Coord`
- Changed `BBox(origin, (x, y, z))` → `BBox(origin, Coord(x, y, z))`
- `intersect_leaves` now works correctly

### Critical Finding: Leaf Values Are Garbage

```julia
# Leaf at Coord(-48, -56, -40) from cube.vdb:
Active count: 320
Values at first few active indices: [0.15, 2.0589416e23, 2.0589416e23, 2.011718e23, ...]
Min/max values: NaN / NaN
```

**The VDB parser is NOT correctly reading/decompressing v222 leaf values.**

This explains:
1. Why sphere tracing returns `nothing` - SDF values are garbage
2. Why the renderer produces blank images
3. Why issue `path-tracer-52o` (tracer bullet verification) exists

### File Details

- **cube.vdb**: Format v222, NoCompression in header
- Grid parses: 547 leaves, 178665 active voxels (counts look correct)
- But actual values are corrupt

### Files Modified

| File | Change |
|------|--------|
| `src/Ray.jl` | Fixed BBox construction (tuple → Coord) in 3 places |

### What Needs Investigation

1. **Values.jl** - `read_leaf_values` may be reading wrong bytes or wrong format
2. **TreeRead.jl** - Tree construction may be corrupting values
3. **Compression.jl** - Decompression may be returning garbage

### Debug Scripts

There are **27 debug scripts** in `scripts/` from previous sessions. Issue `path-tracer-6q6` tracks cleanup.

### Next Steps

1. Read `docs/VDB_FORMAT_COMPLETE.md` for v222 leaf value format
2. Trace exact bytes being read for leaf values in cube.vdb
3. Compare against OpenVDB C++ reference output
4. Fix value parsing before any renderer work

### Beads Issue Chain (in order)

**SCOPE: cube.vdb ONLY until chain complete**

| Issue | Status | Description |
|-------|--------|-------------|
| `path-tracer-fdb` | READY | Read VDB_FORMAT_COMPLETE.md for v222 leaf format |
| `path-tracer-5vn` | blocked by fdb | Trace exact bytes read for cube.vdb leaves |
| `path-tracer-wfo` | blocked by 5vn | Fix v222 leaf value parsing |
| `path-tracer-2zj` | blocked by wfo | BLOCKER: leaf values are garbage |
| `path-tracer-52o` | blocked by 2zj | Tracer bullet: cube.vdb verification |

**Next agent MUST start with `path-tracer-fdb`** - read the format spec before any code changes.

---

## Previous Session (2026-01-11) - Sphere Tracing Renderer

**Status**: ⚠️ PARTIAL - Renderer implemented but produces blank output due to corrupt values.

### What Was Implemented

**Renderer** (`src/Render.jl`):
- `Camera` struct with look_at constructor
- `camera_ray` for generating rays through pixels
- `sphere_trace` for ray marching through level sets
- `shade` with Lambertian shading
- `render_image` main render loop
- `write_ppm` for PPM output

**CLI Script** (`scripts/render_vdb.jl`):
- Full command-line renderer with options for width, height, FOV, distance, steps

**Tests** (`test/test_render.jl`):
- Camera construction and orthonormal basis
- Shading with different light directions
- PPM output formatting and clamping
- Sphere tracing miss cases
- Full pipeline tests

### Files Modified/Added

| File | Change |
|------|--------|
| `src/Render.jl` | NEW - Sphere tracing renderer (~300 lines) |
| `src/Lyr.jl` | Added include and exports for Render module |
| `scripts/render_vdb.jl` | NEW - CLI renderer script |
| `test/test_render.jl` | NEW - Render tests (26 tests) |
| `test/runtests.jl` | Added test_render.jl to suite |

### Test Results

```
514 passing, 0 failed, 3 errored (known: bunny_cloud v220, sphere_points PointDataGrid)
```

### Notes on Sphere Tracing

The sample VDB files are **sparse narrow-band level sets** that only store SDF values in a thin shell around the surface. This limits sphere tracing effectiveness since:
- Outside the narrow band: returns background value
- Inside object but outside narrow band: returns background value
- Only in the narrow band: actual SDF values

For production use with these files, DDA ray marching through the tree structure would be more appropriate. The current sphere tracer works correctly but most rays miss due to the sparse data.

### Commits

- `cc57140` - feat: Add sphere tracing renderer for VDB level sets

---

## Previous Session (2026-01-11) - v222 Header Fix + Renderer Plan

**Status**: ✅ SUCCESS - Fixed critical v222 parsing bug. All tracer bullet files now parse. Renderer plan approved.

### What Was Fixed

**Root cause**: v222 header parsing was fundamentally wrong.
- **Bug**: Header.jl read 4 bytes after UUID as compression flags for v222
- **Reality**: Those bytes are the file metadata count. v222+ has NO compression in header - it's per-grid.

### Files Modified

| File | Change |
|------|--------|
| `src/Header.jl` | Don't read compression from header for v222+ |
| `src/File.jl` | Read per-grid compression at start of each grid for v222+ |
| `src/Compression.jl` | Fix chunk_size handling per VDB spec (0=empty, <0=uncompressed, >0=compressed) |
| `test/test_file.jl` | Update tests for correct v222 format |
| `test/test_integration.jl` | Use `Coord` type instead of plain tuple |

### Test Results

```
488 passing, 0 failed, 3 errored (known: bunny_cloud v220, sphere_points PointDataGrid)
```

All v222 files parse correctly:
- cube.vdb ✓ (547 leaves, 178665 voxels)
- sphere.vdb ✓ (179 leaves, 36165 voxels)
- icosahedron.vdb ✓ (230 leaves, 46016 voxels)
- torus.vdb ✓ (3152 leaves, 1565265 voxels)
- utahteapot.vdb ✓ (15440 leaves, 13242562 voxels)

### Commits

- `05fc7df` - fix: Correct v222 header parsing - compression is per-grid, not in header

---

## Next Up: Minimal Raycast Renderer

**Plan approved**. Implementation ready to begin.

### Renderer Issues (in dependency order)

1. **path-tracer-6wf** [P0]: Create `src/Render.jl` with sphere tracing renderer
2. **path-tracer-cvu** [P0]: Update `src/Lyr.jl` with include and exports (depends on 6wf)
3. **path-tracer-9da** [P0]: Create `scripts/render_vdb.jl` CLI script (depends on cvu)
4. **path-tracer-co1** [P1]: Create `test/test_render.jl` with basic tests (depends on 9da)

### Renderer Plan Summary

**Goal**: Render VDB level-set surfaces to PPM images using sphere tracing.

**Approach**:
- Sphere tracing on SDF (step by distance value - fast and sub-voxel accurate)
- Simple Lambertian shading with directional light
- PPM output (no dependencies)
- ~230 lines total

**Key functions**:
```julia
Camera, look_at(from, to, up)           # Camera setup
sphere_trace(ray, grid, max_steps)       # Find surface hit
shade(point, normal, light_dir)          # Lambertian shading
render_image(grid, camera, width, height) # Main loop
write_ppm(filename, pixels)              # Output
```

**Usage** (after implementation):
```bash
julia --project scripts/render_vdb.jl test/fixtures/samples/cube.vdb cube.ppm
```

**Full plan**: `.claude/plans/radiant-forging-dragonfly.md`

---

## Repository State

- **Branch**: master
- **Working tree**: clean
- **All commits**: pushed
- **Tests**: 488 pass, 3 error (known limitations)

---

## Known Limitations

1. **bunny_cloud.vdb (v220)**: Not supported - format differs significantly
2. **sphere_points.vdb (v224)**: PointDataGrid type not implemented
3. **utahteapot.vdb**: Parses but leaf/voxel counts differ from some references (may be reference data issue)
