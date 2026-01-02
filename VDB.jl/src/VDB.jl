module VDB

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
include("Grid.jl")
include("File.jl")

# Queries and utilities
include("Accessors.jl")
include("Interpolation.jl")
include("Ray.jl")

# Exports - Binary
export read_u8, read_u32_le, read_u64_le
export read_i32_le, read_i64_le
export read_f32_le, read_f64_le
export read_bytes, read_cstring, read_string_with_size

# Exports - Masks
export Mask, LeafMask, Internal1Mask, Internal2Mask
export is_on, is_off, is_empty, is_full
export count_on, count_off
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

# Exports - Topology
export LeafTopology, Internal1Topology, Internal2Topology, RootTopology
export read_leaf_topology, read_internal1_topology, read_internal2_topology, read_root_topology

# Exports - Values
export read_leaf_values, read_tile_value
export materialize_leaf, materialize_internal1, materialize_internal2, materialize_tree

# Exports - Transforms
export AbstractTransform, LinearTransform, UniformScaleTransform
export index_to_world, world_to_index, world_to_index_float, voxel_size
export read_transform

# Exports - Grid
export GridClass, GRID_LEVEL_SET, GRID_FOG_VOLUME, GRID_STAGGERED, GRID_UNKNOWN
export Grid, read_grid

# Exports - File
export VDBHeader, GridDescriptor, VDBFile
export VDB_MAGIC
export read_header, read_grid_descriptor, parse_vdb

# Exports - Accessors
export get_value, is_active, active_voxel_count, leaf_count, active_bounding_box
export active_voxels, leaves

# Exports - Interpolation
export sample_nearest, sample_trilinear, sample_world
export gradient

# Exports - Ray
export Ray, intersect_bbox, intersect_leaves

end # module
