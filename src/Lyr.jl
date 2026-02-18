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
include("Topology.jl")
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

# TinyVDB parser (test oracle — used by test/test_parser_equivalence.jl)
include("TinyVDB/TinyVDB.jl")

# Exports - Binary
export read_u8, read_u32_le, read_u64_le
export read_i32_le, read_i64_le
export read_f32_le, read_f64_le
export read_bytes, read_cstring, read_string_with_size

# Exports - Masks
export Mask, LeafMask, Internal1Mask, Internal2Mask
export is_on, is_off, is_empty, is_full
export count_on, count_off, count_on_before
export on_indices, off_indices
export read_mask

# Exports - Coordinates
export Coord, coord
export leaf_origin, internal1_origin, internal2_origin
export leaf_offset, internal1_child_index, internal2_child_index
export BBox, contains, intersects, volume

# Exports - Compression
export Codec, NoCompression, BloscCodec, ZipCodec
export decompress, read_compressed_bytes

# Exports - Tree Types
export AbstractNode, LeafNode, Tile
export InternalNode1, InternalNode2, RootNode, Tree
export GridClass, GRID_LEVEL_SET, GRID_FOG_VOLUME, GRID_STAGGERED, GRID_UNKNOWN

# Exports - Topology (child origin computation)
export child_origin_internal2, child_origin_internal1

# Exports - Values
export read_leaf_values, read_tile_value

# Exports - Transforms
export AbstractTransform, LinearTransform, UniformScaleTransform
export index_to_world, world_to_index, world_to_index_float, voxel_size
export read_transform

# Exports - Grid
export parse_grid_class
export Grid, read_grid

# Exports - File
export VDBHeader, GridDescriptor, VDBFile
export VDB_MAGIC
export parse_value_type
export read_header, read_grid_descriptor, parse_vdb

# Exports - Accessors
export ValueAccessor
export get_value, is_active, active_voxel_count, leaf_count, active_bounding_box
export active_voxels, leaves

# Exports - Interpolation
export sample_nearest, sample_trilinear, sample_world
export gradient

# Exports - Ray
export AABB, Ray, LeafIntersection, intersect_bbox, intersect_leaves

# Exports - DDA
export DDAState, dda_init, dda_step!
export NodeDDA, node_dda_init, node_dda_child_index, node_dda_inside, node_dda_voxel_origin
export intersect_leaves_dda
export VolumeRayIntersector

# Exports - Exceptions
export LyrError, ParseError, CompressionError
export InvalidMagicError
export ChunkSizeMismatchError, CompressionBoundsError, DecompressionSizeError
export ValueCountError

# Exports - NanoVDB
export NanoGrid, NanoLeafView, NanoI1View, NanoI2View
export NanoValueAccessor, NanoLeafHit, NanoVolumeRayIntersector
export build_nanogrid
export nano_origin, nano_is_active, nano_get_value
export nano_child_count, nano_tile_count, nano_has_child, nano_has_tile
export nano_child_offset, nano_tile_value
export nano_background, nano_bbox, nano_root_count, nano_i2_count, nano_i1_count, nano_leaf_count

# Exports - Static Arrays
export SVec3f, SVec3d, SMat3d

# Exports - Render
export Camera, camera_ray
export sphere_trace, shade
export render_image, write_ppm

# Exports - Surface
export SurfaceHit, find_surface

end # module
