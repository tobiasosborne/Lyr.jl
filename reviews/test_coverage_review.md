# Test Coverage Review

**Date**: 2026-03-12
**Scope**: Full test suite at `/home/tobiasosborne/Projects/Lyr.jl/test/`
**Stats**: 17,832 test lines across 80 test files covering 17,099 source lines across ~75 source files

## Summary

The Lyr.jl test suite is **strong overall** -- well-organized, thorough on the core parsing and data structure layers, and includes valuable integration, ground truth, and type stability tests. Test-to-source ratio is ~1:1 which is healthy. However, there are meaningful coverage gaps in several high-risk areas:

1. **No dedicated tests for exception types** (139 lines of Exceptions.jl untested)
2. **ImageCompare.jl is only tested indirectly** through benchmark renders (not in CI path)
3. **WeakField stub is completely untested** (will silently error at runtime)
4. **SchwarzschildKS metric has no dedicated test file** (only tested indirectly via camera tests)
5. **33 tests gated behind `isfile` checks** -- if fixtures are missing, tests silently pass
6. **No negative/adversarial input testing** for the Field Protocol, Voxelize, or Visualize pipelines
7. **VolumeIntegrator (780 lines) has no unit tests** -- only integration-level coverage through renderers

The GR module has excellent physics validation tests (Hamiltonian conservation, photon sphere stability, shadow radius). The VDB parser has comprehensive equivalence tests against TinyVDB oracle. Grid operations and CSG tests are well-designed with edge cases.

## Coverage Map

| Source Module | Lines | Test File(s) | Coverage Assessment |
|---|---|---|---|
| `Binary.jl` | 184 | `test_binary.jl` | Good: round-trip, edge values, endianness |
| `BinaryWrite.jl` | 160 | `test_writer.jl` | Good: round-trip for all write primitives |
| `Masks.jl` | 299 | `test_masks.jl` | Good: creation, queries, edge cases |
| `Coordinates.jl` | 217 | `test_coordinates.jl` | Good: BBox, origin, offset arithmetic |
| `Compression.jl` | 165 | `test_compression.jl`, `test_compression_write.jl` | Good: round-trip, error handling |
| `TreeTypes.jl` | 144 | `test_tree_types.jl` | Good: construction, type hierarchy |
| `ChildOrigins.jl` | 47 | (indirect via `test_tree_read.jl`) | Adequate: exercised through tree parsing |
| `Values.jl` | 203 | `test_values.jl` | Good: leaf values, tile values, compressed |
| `Transforms.jl` | 197 | `test_transforms.jl` | Good: index-to-world, world-to-index |
| `TreeRead.jl` | 431 | `test_tree_read.jl` | Good: topology, values, multi-grid |
| `Grid.jl` | ~100 | `test_grid.jl` | Good: construction, metadata |
| `Header.jl` | 107 | `test_parsing_infrastructure.jl` | Good: magic validation, version checks |
| `Metadata.jl` | 96 | (indirect via `test_file.jl`) | Adequate: exercised through file parsing |
| `GridDescriptor.jl` | 85 | `test_parsing_infrastructure.jl` | Good |
| `File.jl` | ~100 | `test_file.jl`, `test_integration.jl` | Good: real VDB files, error cases |
| `FileWrite.jl` | 653 | `test_writer.jl`, `test_compression_write.jl` | Good: full round-trip write-parse |
| `Accessors.jl` | 718 | `test_accessors.jl` | Good: cache hits, random coords |
| `Interpolation.jl` | 278 | `test_interpolation.jl` | Good: nearest, trilinear, quadratic |
| `Stencils.jl` | 169 | `test_stencils.jl` | Good: gradient, laplacian, box stencil |
| `DifferentialOps.jl` | 198 | `test_differential_ops.jl` | Good: gradient, divergence, curl, curvature |
| `Ray.jl` | ~100 | `test_ray.jl` | Good: construction, AABB intersection |
| `DDA.jl` | 460 | `test_dda.jl`, `test_node_dda.jl`, `test_hierarchical_dda.jl` | Good: step, traverse, hierarchical |
| `Render.jl` | 279 | `test_render.jl` | Good: camera, sphere trace, shade |
| `Surface.jl` | 262 | `test_surface.jl` | Good: surface finding, SDF tracing |
| `NanoVDB.jl` | 1094 | `test_nanovdb.jl` | Good: build, get_value, DDA equivalence |
| `VolumeHDDA.jl` | 355 | `test_volume_hdda.jl` | Good: spans, merging, ordering |
| `GridBuilder.jl` | 109 | `test_grid_builder.jl` | Adequate: basic build, Gaussian splat |
| `GridOps.jl` | 325 | `test_gridops.jl` | Good: all comp ops, clip, empty, negatives |
| `Pruning.jl` | ~80 | `test_pruning.jl` | Adequate |
| `LevelSetPrimitives.jl` | 139 | `test_level_set_primitives.jl` | Good: sphere, box, SDF accuracy |
| `CSG.jl` | ~100 | `test_csg.jl` | Good: union, intersection, difference, commutativity |
| `LevelSetOps.jl` | 237 | `test_level_set_ops.jl` | Good: sdf_to_fog, fog_to_sdf, area, volume |
| `Filtering.jl` | ~100 | `test_filtering.jl` | Adequate |
| `Morphology.jl` | ~100 | `test_morphology.jl` | Adequate |
| `FastSweeping.jl` | 192 | `test_fast_sweeping.jl` | Good: reinitialize identity, gradient stats |
| `Particles.jl` | 244 | `test_particles_to_sdf.jl`, `test_particle_trails.jl` | Good |
| `MeshToVolume.jl` | 267 | `test_mesh_to_level_set.jl` | Good: cube, sphere, watertight |
| `Segmentation.jl` | ~80 | `test_segmentation.jl` | Good: connectivity, empty, many components |
| `Meshing.jl` | 526 | `test_meshing.jl` | Adequate: marching cubes output |
| `TransferFunction.jl` | 155 | `test_transfer_function.jl` | Good: interpolation, presets, edge values |
| `PhaseFunction.jl` | 163 | `test_phase_function.jl` | Good: sample_phase, normalization, HG |
| `Scene.jl` | 175 | `test_scene.jl` | Adequate: construction, no deep behavior tests |
| `IntegrationMethods.jl` | 56 | (indirect via renderers) | Adequate: types used in render tests |
| `VolumeIntegrator.jl` | 780 | `test_volume_renderer.jl`, `test_multiscatter.jl` | **Weak**: no unit tests for delta/ratio tracking internals |
| `Output.jl` | 307 | `test_output.jl` | Good: tonemap, denoise, fallback paths |
| `ImageCompare.jl` | 205 | `test_benchmark_renders.jl` (indirect, not in CI) | **Weak**: RMSE/PSNR/SSIM untested in main suite |
| `GPU.jl` | 927 | `test_gpu.jl` | Good: get_value, trilinear, ray-box, render |
| `FieldProtocol.jl` | 384 | `test_field_protocol.jl` | Good: all field types, domain, evaluate |
| `Voxelize.jl` | 331 | `test_voxelize.jl` | Good: all field types, adaptive, round-trip |
| `Visualize.jl` | 407 | `test_visualize.jl` | Good: presets, camera, file output |
| `PointAdvection.jl` | 53 | `test_point_advection.jl` | Excellent: Euler, RK4, circular orbit, error |
| `Exceptions.jl` | 139 | (none) | **Missing**: no tests for exception types |
| `VDBConstants.jl` | 14 | (indirect) | Adequate: constants used in parsing |
| `GR/types.jl` | ~50 | `test_gr_types.jl` | Good |
| `GR/metric.jl` | ~80 | `test_gr_metric.jl` | Good: Minkowski, Hamiltonian, partials |
| `GR/metrics/schwarzschild.jl` | ~150 | `test_gr_schwarzschild.jl` | Excellent: metric values, inverse, determinant |
| `GR/metrics/schwarzschild_ks.jl` | 257 | (indirect via `test_gr_camera.jl`) | **Weak**: no dedicated tests |
| `GR/metrics/kerr.jl` | ~200 | `test_gr_kerr.jl` | Excellent: limits, horizons, ISCO, geodesics |
| `GR/metrics/minkowski.jl` | 27 | `test_gr_metric.jl` | Good |
| `GR/integrator.jl` | 287 | `test_gr_integrator.jl` | Good: Minkowski straight line, photon orbit |
| `GR/camera.jl` | 173 | `test_gr_camera.jl` | Good: tetrad, null condition, pixel momentum |
| `GR/matter.jl` | 220 | `test_gr_matter.jl` | Good: emissivity, 4-velocity, disk crossing |
| `GR/redshift.jl` | 233 | `test_gr_redshift.jl` | Good: gravitational redshift, Planck, sRGB |
| `GR/volumetric.jl` | ~100 | `test_gr_volumetric.jl` | Good: ThickDisk, emission-absorption |
| `GR/render.jl` | 373 | `test_gr_render.jl` | Adequate: dimensions, NaN-free, shadow |
| `GR/stubs/weak_field.jl` | 23 | (none) | **Missing**: stub errors untested |

## Findings

### [SEVERITY: critical] ImageCompare.jl has no unit tests in the main test suite

- **Location**: `src/ImageCompare.jl` (205 lines) -- `image_rmse`, `image_psnr`, `image_ssim`, `image_max_diff`, `read_ppm`, `read_float32_image`
- **What's Missing**: These functions are only exercised by `test_benchmark_renders.jl` and `test_cross_renderer.jl`, which depend on reference render fixtures. If those fixtures don't exist, the functions are never tested. There are zero dedicated unit tests for the comparison metrics.
- **Risk**: A bug in `image_ssim` or `image_psnr` would silently corrupt all golden-image regression testing. The SSIM implementation is a simplified global version -- any numerical issue (division by zero for constant images, negative variance from floating-point error) would propagate undetected.
- **Recommendation**: Add `test_image_compare.jl` with:
  - `image_rmse` of identical images returns 0.0
  - `image_rmse` of images differing by known amount returns expected value
  - `image_psnr` of identical images returns `Inf`
  - `image_ssim` of identical images returns 1.0
  - `image_ssim` of uncorrelated images returns value near 0
  - `image_max_diff` on known diff
  - `DimensionMismatch` for mismatched image sizes
  - `read_ppm` round-trip with `write_ppm`
  - `read_ppm` with comments in header
  - `read_float32_image` with known binary data

### [SEVERITY: critical] VolumeIntegrator.jl has no unit-level tests (780 lines)

- **Location**: `src/VolumeIntegrator.jl` -- the core production renderer
- **What's Missing**: `delta_tracking_step` and `ratio_tracking` are tested only through high-level render calls (`test_volume_renderer.jl`, `test_multiscatter.jl`). There are no tests that exercise the internal HDDA-inlined delta tracking logic, the root sorting, the span traversal, or the precomputed volume struct directly. The test in `test_volume_renderer.jl` for `delta_tracking_step` uses a simplified 5-argument signature, not the full 8-argument production signature with `NanoValueAccessor`.
- **Risk**: Subtle bugs in the inline HDDA state machine (e.g., off-by-one in root sorting, wrong span merging, incorrect t_exit handling) would only manifest as slightly wrong render output that passes the loose `atol` checks. The multi-volume regression test is excellent but only covers one specific failure mode.
- **Recommendation**: Add `test_volume_integrator.jl` with:
  - `_precompute_volume` produces correct bounds and constants
  - `delta_tracking_step` with the full 8-arg signature against a known-density grid
  - `ratio_tracking` transmittance against Beer-Lambert for uniform density
  - Verify `_volume_bounds` returns correct AABB for multi-leaf grids
  - Test root sorting with multiple I2 nodes
  - Test that zero-density regions yield `:escaped` consistently

### [SEVERITY: major] 33 tests silently pass when fixture files are missing

- **Location**: `test_volume_renderer.jl` (6 tests), `test_gpu.jl` (8 tests), `test_writer.jl` (3 tests), `test_nanovdb.jl` (1 test), `test_scene.jl` (3 tests), `test_render.jl` (5 tests), and others
- **What's Missing**: Tests wrapped in `if isfile(path) ... end` silently pass without running any assertions when fixture files (`smoke.vdb`, `cube.vdb`, `sphere.vdb`) are absent. There is no `@test_skip` or `@warn` to indicate skipped coverage.
- **Risk**: In a CI environment or fresh clone without fixture files, the volume renderer, GPU kernel, NanoVDB, and writer tests would report as passing with zero assertions executed. This could mask regressions.
- **Recommendation**: Replace `if isfile(path) ... end` with:
  ```julia
  if !isfile(path)
      @test_skip "fixture not found: $path"
      return
  end
  ```
  Or better, add a shared fixture check at the top of `runtests.jl` that warns about missing fixtures. Consider storing small synthetic VDB files in the repo or generating them programmatically in tests.

### [SEVERITY: major] Exceptions.jl has no tests (139 lines)

- **Location**: `src/Exceptions.jl` -- 7 exception types with custom `showerror` methods
- **What's Missing**: No tests verify that exception types can be constructed, that `showerror` produces expected output, or that the exception hierarchy (`LyrError > ParseError > InvalidMagicError`, etc.) is correct.
- **Risk**: A typo in `showerror` (e.g., accessing wrong field) would only be caught when the error actually fires in production. The type hierarchy relationships are untested.
- **Recommendation**: Add `test_exceptions.jl`:
  - Each exception type can be constructed with expected field values
  - `sprint(showerror, e)` produces a string containing expected substrings
  - `InvalidMagicError <: ParseError <: LyrError <: Exception`
  - `ChunkSizeMismatchError <: CompressionError <: LyrError`
  - `FormatError("msg")` stores and displays the message

### [SEVERITY: major] SchwarzschildKS metric has no dedicated test file (257 lines)

- **Location**: `src/GR/metrics/schwarzschild_ks.jl`
- **What's Missing**: The Kerr-Schild coordinate metric is only tested indirectly through `test_gr_camera.jl` (tetrad orthonormality). There are no tests for:
  - `metric` values at specific coordinates
  - `metric_inverse` correctness
  - `g * g^{-1} = I` identity
  - `det(g)` consistency
  - `is_singular` behavior near horizon
  - `ks_to_sky_angles` function
  - Comparison with Schwarzschild BL at the same physical point
- **Risk**: The KS metric is used for horizon-penetrating geodesics. A sign error or factor-of-2 bug in the metric would produce geodesics that look plausible but are physically wrong. The existing Kerr test does compare `a=0` Kerr to Schwarzschild, but not KS.
- **Recommendation**: Create `test_gr_schwarzschild_ks.jl`:
  - Metric values at known coordinates against analytic formula
  - `g * g^{-1} = I` at multiple points
  - `det(g)` matches expected value
  - `is_singular` true at/below r=2M, false above
  - `ks_to_sky_angles` round-trip consistency
  - Geodesic in KS agrees with BL Schwarzschild at same physical point (far from horizon)

### [SEVERITY: major] WeakField stub throws on use but is exported and untested

- **Location**: `src/GR/stubs/weak_field.jl` (23 lines)
- **What's Missing**: `WeakField` is exported from `GR` module. Calling `metric(WeakField(), x)` throws a plain `error()`. No test verifies this behavior, and no test documents that the stub is intentionally unimplemented.
- **Risk**: A user discovering `WeakField` in the API would get an unhelpful error message. If someone accidentally references it in rendering code, it fails at runtime rather than at construction.
- **Recommendation**: Either:
  1. Add a test that `@test_throws ErrorException metric(WeakField(), SVec4d(0,0,0,0))` to document the stub status
  2. Or remove the export until implemented

### [SEVERITY: major] No error path tests for Field Protocol -> Voxelize -> Visualize pipeline

- **Location**: `src/FieldProtocol.jl`, `src/Voxelize.jl`, `src/Visualize.jl`
- **What's Missing**: No tests for:
  - Field returning `NaN` or `Inf` values
  - Field with very large or very small characteristic_scale
  - Domain with negative extent (min > max)
  - Voxelize with voxel_size = 0 or negative
  - Visualize with width/height = 0
  - ParticleField with duplicate positions
  - TimeEvolution with t_range where start > end
- **Risk**: Users passing invalid inputs get Julia runtime errors (BoundsError, DivisionError) rather than helpful error messages. NaN propagation through the voxelize -> render pipeline could produce corrupt output silently.
- **Recommendation**: Add edge case tests:
  ```julia
  @test_throws ArgumentError voxelize(field; voxel_size=0.0)
  @test_throws ArgumentError voxelize(field; voxel_size=-1.0)
  # Or if no validation exists, add validation + tests
  ```

### [SEVERITY: minor] Transfer function missing NaN/boundary input tests

- **Location**: `test_transfer_function.jl`, `src/TransferFunction.jl`
- **What's Missing**: `evaluate(tf, NaN)`, `evaluate(tf, -Inf)`, `evaluate(tf, Inf)` are not tested. These arise in practice when volume density lookup returns edge values.
- **Risk**: NaN density values from voxel interpolation at grid boundaries could produce NaN colors that propagate through the entire rendering pipeline.
- **Recommendation**: Add tests:
  - `evaluate(tf, NaN)` -- should return something reasonable (zero or clamped)
  - `evaluate(tf, -1.0)` -- below all control points
  - `evaluate(tf, 100.0)` -- above all control points
  - Verify no NaN/Inf in output regardless of input

### [SEVERITY: minor] Scene.jl lacks behavior tests for multi-light, multi-volume scenarios

- **Location**: `test_scene.jl` (99 lines) vs `src/Scene.jl` (175 lines)
- **What's Missing**: Tests only verify construction and field access. No tests for:
  - Scene with zero lights
  - Scene with zero volumes
  - Scene with multiple different light types mixed
  - ConstantEnvironmentLight construction and behavior
- **Risk**: Edge cases in scene setup silently propagate to rendering errors.
- **Recommendation**: Add:
  - Empty scene construction (zero volumes, zero lights)
  - `ConstantEnvironmentLight` construction and field access
  - Scene with 5+ volumes, 3+ lights

### [SEVERITY: minor] GR integrator missing adaptive step and renormalize_null tests

- **Location**: `src/GR/integrator.jl` exports `rk4_step`, `verlet_step`, `adaptive_step`, `renormalize_null`
- **What's Missing**: Individual stepper functions are not tested in isolation. `adaptive_step` and `renormalize_null` have no direct tests. Only `integrate_geodesic` (which uses them internally) is tested.
- **Risk**: A bug in `adaptive_step` could be masked by the `h_tolerance` safety net in `integrate_geodesic`. `renormalize_null` off-by-epsilon errors accumulate over long integrations.
- **Recommendation**: Add unit tests for:
  - `rk4_step` on Minkowski: single step matches analytic straight line
  - `verlet_step` on Minkowski: same verification
  - `adaptive_step` reduces step near horizon, increases step in flat space
  - `renormalize_null` preserves H = 0 to machine precision

### [SEVERITY: minor] No tests for `read_float32_image` (binary image reader)

- **Location**: `src/ImageCompare.jl`, function `read_float32_image`
- **What's Missing**: This function reads a custom binary format (12-byte header + float32 pixels). No tests verify correct parsing, error handling for truncated files, or wrong channel count.
- **Risk**: Silent data corruption when reading Mitsuba reference renders -- wrong pixel values would make regression tests unreliable.
- **Recommendation**: Create a small known binary image in-memory and verify round-trip.

### [SEVERITY: minor] Meshing.jl (526 lines) has proportionally few tests

- **Location**: `src/Meshing.jl` (526 lines) vs `test_meshing.jl` (~100 lines)
- **What's Missing**: The marching cubes implementation is complex (526 lines) but tests only verify output format (vertices, faces exist) and basic topology. Missing:
  - Watertight mesh from a known SDF (no gaps between triangles)
  - Vertex positions lie on the isosurface within tolerance
  - Normal orientation consistency
  - Degenerate cases: flat SDF (no surface), single-voxel SDF
- **Risk**: Marching cubes can produce non-manifold meshes, duplicate vertices, or incorrect triangle orientations. These bugs only surface when the mesh is used downstream.
- **Recommendation**: Add tests that verify mesh quality metrics for `volume_to_mesh` on a known sphere SDF.

### [SEVERITY: minor] GPU kernel tests only run on CPU backend

- **Location**: `test_gpu.jl` (267 lines)
- **What's Missing**: All GPU tests use the KernelAbstractions CPU backend. There is no CI gate for actual GPU testing. If the kernel has GPU-specific bugs (memory alignment, atomic operations), they are invisible.
- **Risk**: Low in practice since KA provides a good CPU simulation, but GPU-specific issues (shared memory, warp divergence) could exist.
- **Recommendation**: Document that GPU testing is CPU-backend-only. Consider adding a CI flag for optional GPU testing.

### [SEVERITY: minor] No test for `resample_to_match` (exported API)

- **Location**: `src/Interpolation.jl` exports `resample_to_match`
- **What's Missing**: This function is exported but has no test verifying its behavior.
- **Risk**: Untested public API function may have incorrect behavior that users encounter.
- **Recommendation**: Add test cases for resampling one grid to match another's resolution.

### [SEVERITY: nit] `test_gr.jl` is a standalone runner that duplicates `runtests.jl` GR includes

- **Location**: `test/test_gr.jl`
- **What's Missing**: `test_gr.jl` includes the same GR test files as `runtests.jl`. This is intentional (for standalone running), but the duplicate include could become stale if new GR test files are added to `runtests.jl` but not `test_gr.jl`.
- **Risk**: Low -- only affects standalone running.
- **Recommendation**: Add a comment in `test_gr.jl` noting it should mirror the GR section of `runtests.jl`, or auto-generate it.

### [SEVERITY: nit] `test_cross_renderer.jl` excluded from CI with no automated gate

- **Location**: `test/runtests.jl` line 178 -- commented out with a note
- **What's Missing**: The cross-renderer test (13 min) is excluded from CI. No mechanism ensures it runs periodically.
- **Risk**: The cross-renderer regression could break silently over many commits.
- **Recommendation**: Consider a nightly CI job that runs `test_cross_renderer.jl`, or mark it with `@testset` and `ENV`-based skip.

### [SEVERITY: nit] Type stability tests could cover more of the hot path

- **Location**: `test_type_stability.jl`, `test_jet.jl`
- **What's Missing**: These test type stability for core functions but not for the volume rendering hot path (`_trace_multiscatter`, `delta_tracking_step` with full signature, HDDA span iteration).
- **Risk**: Type instability in the rendering inner loop causes 10-100x performance regressions that won't be caught by correctness tests.
- **Recommendation**: Add `@inferred` or JET tests for `delta_tracking_step`, `ratio_tracking`, and `_trace_multiscatter` with concrete type arguments.

### [SEVERITY: nit] GR render test tolerance is coarse ("BH shadow subtends correct angle")

- **Location**: `test_gr_validation.jl` lines 98-125
- **What's Missing**: The shadow radius test accepts "within factor of 2" tolerance. This is so loose that a 50% error in the metric would still pass.
- **Risk**: Low -- the other physics tests (photon orbit, Hamiltonian conservation) are tighter. But the shadow test is the most user-visible validation.
- **Recommendation**: Tighten the shadow test by increasing resolution from 64 pixels to 128+ and narrowing the acceptance window to factor of 1.5.
