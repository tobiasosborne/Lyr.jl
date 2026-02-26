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
# Public API — only user-facing symbols are exported.
# Internal symbols (binary readers, parser functions, DDA primitives, etc.)
# are accessible via Lyr.symbol_name or import Lyr: symbol_name.
# ============================================================================

# Masks
export Mask, LeafMask, Internal1Mask, Internal2Mask
export is_on, is_off, is_empty, is_full
export count_on, count_off, count_on_before
export on_indices, off_indices

# Coordinates
export Coord, coord
export BBox, contains, intersects, volume

# Compression (types only — functions are internal)
export NoCompression, BloscCodec, ZipCodec

# Tree types
export AbstractNode, LeafNode, Tile
export InternalNode1, InternalNode2, RootNode, Tree
export GridClass, GRID_LEVEL_SET, GRID_FOG_VOLUME, GRID_STAGGERED, GRID_UNKNOWN

# Transforms
export AbstractTransform, LinearTransform, UniformScaleTransform
export index_to_world, world_to_index, world_to_index_float, voxel_size

# Grid
export Grid

# File
export VDBHeader, GridDescriptor, VDBFile
export parse_vdb

# Accessors
export ValueAccessor
export get_value, is_active, active_voxel_count, leaf_count, active_bounding_box
export active_voxels, leaves

# Interpolation
export InterpolationMethod, NearestInterpolation, TrilinearInterpolation
export sample_nearest, sample_trilinear, sample_world
export gradient

# Ray & DDA (high-level only)
export AABB, Ray, intersect_bbox, intersect_leaves
export intersect_leaves_dda, VolumeRayIntersector

# Exceptions (base types only — detail types are internal)
export LyrError, ParseError, CompressionError

# NanoVDB
export NanoGrid, NanoLeafView, NanoI1View, NanoI2View
export NanoValueAccessor, NanoLeafHit, NanoVolumeRayIntersector
export build_nanogrid
export nano_origin, nano_is_active, nano_get_value
export nano_child_count, nano_tile_count, nano_has_child, nano_has_tile
export nano_child_offset, nano_tile_value
export nano_background, nano_bbox, nano_root_count, nano_i2_count, nano_i1_count, nano_leaf_count

# Static Arrays
export SVec3f, SVec3d, SMat3d

# Render
export Camera, write_ppm

# Surface
export SurfaceHit, find_surface

# Grid Builder
export build_grid, gaussian_splat

# VDB Writer (high-level only)
export write_vdb, write_vdb_to_buffer

# Transfer Functions
export ControlPoint, TransferFunction, evaluate
export tf_blackbody, tf_cool_warm, tf_smoke, tf_viridis

# Phase Functions
export PhaseFunction, IsotropicPhase, HenyeyGreensteinPhase
export sample_phase

# Scene
export PointLight, DirectionalLight
export VolumeMaterial, VolumeEntry, Scene

# Volume Integrator (high-level only)
export render_volume_image, render_volume_preview

# Output
export tonemap_reinhard, tonemap_aces, tonemap_exposure, auto_exposure
export denoise_nlm, denoise_bilateral
export write_exr, write_png

# GPU
export GPUNanoGrid, adapt_nanogrid
export gpu_render_volume
export ProgressiveAccumulator, accumulate!, resolve

# Field Protocol
export AbstractDomain, BoxDomain, center, extent
export AbstractField, AbstractContinuousField, AbstractDiscreteField
export ScalarField3D, VectorField3D, ComplexScalarField3D
export ParticleField, TimeEvolution
export field_eltype, domain, characteristic_scale
# Note: evaluate is already exported from TransferFunction.jl

# Voxelize
export voxelize

# Visualize
export visualize
export camera_orbit, camera_front, camera_iso
export material_emission, material_cloud, material_fire
export light_studio, light_natural, light_dramatic

end # module
