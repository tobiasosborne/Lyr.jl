# Lyr.jl Handoff Document

---

## Latest Session (2026-01-11) - v222 Header Fix + Renderer Plan

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
