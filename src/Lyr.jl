module Lyr

using StaticArrays

# Static array type aliases for 3D math
const SVec3f = SVector{3, Float32}
const SVec3d = SVector{3, Float64}
const SMat3d = SMatrix{3, 3, Float64, 9}

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
include("Ray.jl")
include("DDA.jl")
include("Render.jl")
include("Surface.jl")

# NanoVDB flat-buffer representation (GPU-ready)
include("NanoVDB.jl")

# General Relativistic ray tracing
include("GR/GR.jl")

# TinyVDB parser (test oracle — used by test/test_parser_equivalence.jl)
include("TinyVDB/TinyVDB.jl")

# Grid construction from sparse data
include("GridBuilder.jl")
include("Particles.jl")

# Phase 2: VDB Writer
include("BinaryWrite.jl")
include("FileWrite.jl")

# Phase 2: Volume Rendering Pipeline
include("TransferFunction.jl")
include("PhaseFunction.jl")
include("Scene.jl")
include("VolumeIntegrator.jl")
include("Output.jl")
include("GPU.jl")

# Field Protocol — the interface between physics and visualization
include("FieldProtocol.jl")
include("Voxelize.jl")
include("Visualize.jl")

# ============================================================================
# Public API — only symbols users type in their code are exported.
# All other symbols are accessible via Lyr.symbol_name or import Lyr: symbol_name.
# ============================================================================

# --- Core I/O ---
export parse_vdb, write_vdb

# --- Types users construct ---
export Grid, Coord, coord, SVec3f, SVec3d, Ray, Camera

# --- Query API ---
export get_value, is_active, active_voxels, leaves
export active_voxel_count, leaf_count

# --- Interpolation & gradient ---
export sample_world, sample_trilinear, gradient

# --- Surface finding ---
export find_surface, SurfaceHit

# --- Rendering pipeline ---
export render_volume_image, render_volume_preview
export write_ppm, write_png, write_exr

# --- Scene setup ---
export PointLight, DirectionalLight, VolumeMaterial, VolumeEntry, Scene

# --- Transfer functions ---
export TransferFunction, ControlPoint, evaluate
export tf_blackbody, tf_cool_warm, tf_smoke, tf_viridis

# --- Grid building ---
export build_grid, voxelize

# --- NanoVDB (high-level) ---
export NanoGrid, build_nanogrid

# --- Field Protocol ---
export ScalarField3D, VectorField3D, ComplexScalarField3D
export ParticleField, TimeEvolution
export BoxDomain, domain, field_eltype, characteristic_scale
export visualize

# --- Visualize presets ---
export camera_orbit, camera_front, camera_iso
export material_emission, material_cloud, material_fire
export light_studio, light_natural, light_dramatic

end # module
