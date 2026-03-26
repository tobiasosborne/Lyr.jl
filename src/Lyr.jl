module Lyr

using StaticArrays
using LinearAlgebra: norm, normalize, dot, cross

# Static array type aliases for 3D math
const SVec3f = SVector{3, Float32}
const SVec3d = SVector{3, Float64}
const SMat3d = SMatrix{3, 3, Float64, 9}

# Shared format constants (used by both Lyr and TinyVDB)
include("VDBConstants.jl")

# Exceptions (must be first for other modules to use)
include("Exceptions.jl")

# Binary primitives
include("Binary.jl")

# Core types
include("Masks.jl")
include("Coordinates.jl")
include("Compression.jl")
include("TreeTypes.jl")

# Parsing
include("ChildOrigins.jl")
include("Values.jl")
include("Transforms.jl")
include("TreeRead.jl")
include("Grid.jl")

# File parsing (modular)
include("Header.jl")
include("Metadata.jl")
include("GridDescriptor.jl")
include("File.jl")

# Queries and utilities
include("Accessors.jl")
include("Interpolation.jl")
include("Stencils.jl")
include("DifferentialOps.jl")
include("Ray.jl")
include("DDA.jl")
include("Render.jl")
include("Surface.jl")

# NanoVDB flat-buffer representation (GPU-ready)
include("NanoVDB.jl")

# Volume HDDA — span-merging hierarchical DDA for volume rendering
include("VolumeHDDA.jl")

# General Relativistic ray tracing
include("GR/GR.jl")

# TinyVDB parser (test oracle — used by test/test_parser_equivalence.jl)
include("TinyVDB/TinyVDB.jl")

# Grid construction from sparse data
include("GridBuilder.jl")
include("GridOps.jl")
include("Pruning.jl")
include("LevelSetPrimitives.jl")
include("CSG.jl")
include("LevelSetOps.jl")
include("Filtering.jl")
include("Morphology.jl")
include("FastSweeping.jl")
include("Particles.jl")
include("MeshToVolume.jl")
include("Segmentation.jl")
include("Meshing.jl")

# Phase 2: VDB Writer
include("BinaryWrite.jl")
include("FileWrite.jl")

# Phase 2: Volume Rendering Pipeline
include("TransferFunction.jl")
include("PhaseFunction.jl")
include("Scene.jl")
include("IntegrationMethods.jl")
include("VolumeIntegrator.jl")
include("Output.jl")
include("ImageCompare.jl")
include("GPU.jl")

# Field Protocol — the interface between physics and visualization
include("FieldProtocol.jl")
include("Voxelize.jl")
include("Visualize.jl")

# Point advection (depends on FieldProtocol)
include("PointAdvection.jl")

# Hydrogen atom eigenstates and molecular orbitals (depends on FieldProtocol)
include("HydrogenAtom.jl")

# Wavepackets, potential surfaces, and nuclear dynamics (depends on FieldProtocol, HydrogenAtom)
include("Wavepackets.jl")

# Scalar QED tree-level scattering (depends on FieldProtocol, Wavepackets, FFTW)
include("ScalarQED.jl")

# GPU-accelerated scalar QED (depends on ScalarQED, KernelAbstractions, Adapt)
include("ScalarQEDGPU.jl")

# Animation pipeline (depends on everything above)
include("Animation.jl")

# ============================================================================
# Public API — only symbols users type in their code are exported.
# All other symbols are accessible via Lyr.symbol_name or import Lyr: symbol_name.
# ============================================================================

# --- Core I/O ---
export parse_vdb, write_vdb

# --- Types users construct ---
export Grid, Coord, coord, SVec3f, SVec3d, Ray, Camera

# --- Query API ---
export get_value, is_active, active_voxels, inactive_voxels, all_voxels, leaves
export active_voxel_count, leaf_count
export i1_nodes, i2_nodes, collect_leaves, foreach_leaf

# --- Interpolation & gradient ---
export sample_world, sample_trilinear, sample_quadratic, gradient
export QuadraticInterpolation, resample_to_match

# --- Stencils ---
export GradStencil, BoxStencil, move_to!, center_value, laplacian, value_at, mean_value

# --- Differential operators ---
export gradient_grid, divergence, curl_grid, mean_curvature, magnitude_grid, normalize_grid

# --- Filtering ---
export filter_mean, filter_gaussian

# --- Morphology ---
export dilate, erode
export reinitialize_sdf
export advect_points
export segment_active_voxels
export volume_to_mesh

# --- Surface finding ---
export find_surface, SurfaceHit

# --- Rendering pipeline ---
export render_volume_image, render_volume_preview, render_volume

# --- Integration methods ---
export ReferencePathTracer, SingleScatterTracer, EmissionAbsorption
export write_ppm, write_png, write_exr
export read_ppm, image_rmse, image_psnr, image_ssim, image_max_diff
export save_reference_render, load_reference_render, read_float32_image

# --- Scene setup ---
export AbstractLight, PointLight, DirectionalLight, ConstantEnvironmentLight, VolumeMaterial, VolumeEntry, Scene

# --- Phase functions ---
export IsotropicPhase, HenyeyGreensteinPhase

# --- Transfer functions ---
export TransferFunction, ControlPoint, evaluate
export tf_blackbody, tf_cool_warm, tf_smoke, tf_viridis

# --- Grid building ---
export build_grid, voxelize, particles_to_sdf, particle_trails_to_sdf, mesh_to_level_set
export create_level_set_sphere, create_level_set_box

# --- Grid operations ---
export change_background, activate, deactivate
export copy_to_dense, copy_from_dense
export comp_max, comp_min, comp_sum, comp_mul, comp_replace
export clip
export prune
export csg_union, csg_intersection, csg_difference

# --- Level set operations ---
export sdf_to_fog, fog_to_sdf, sdf_interior_mask, extract_isosurface_mask
export level_set_area, level_set_volume
export check_level_set, LevelSetDiagnostic

# --- NanoVDB (high-level) ---
export NanoGrid, build_nanogrid
export gpu_available, gpu_info, gpu_render_volume, gpu_render_multi_volume, gpu_gr_render

# --- Field Protocol ---
export ScalarField3D, VectorField3D, ComplexScalarField3D
export ParticleField, TimeEvolution
export BoxDomain, domain, field_eltype, characteristic_scale
export visualize

# --- Hydrogen atom ---
export hydrogen_psi, HydrogenOrbitalField, MolecularOrbitalField
export h2_bonding, h2_antibonding

# --- Wavepackets ---
export gaussian_wavepacket, GaussianWavepacketField
export MorsePotential, H2_MORSE, morse_potential, morse_force
export kw_potential, kw_force
export nuclear_trajectory, ScatteringField

# --- Scalar QED ---
export ScalarQEDScattering, MomentumGrid
export ScalarQEDScatteringGPU, GPUMomentumGrid

# --- Animation ---
export render_animation, stitch_to_mp4
export FixedCamera, OrbitCamera, FollowCamera, FunctionCamera, CameraMode
export tf_electron, tf_photon, tf_excited

# --- Visualize presets ---
export camera_orbit, camera_front, camera_iso
export material_emission, material_cloud, material_fire
export light_studio, light_natural, light_dramatic

end # module
