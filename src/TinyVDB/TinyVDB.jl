# TinyVDB.jl - Minimal VDB parser based on tinyvdbio.h
#
# A fresh, minimal VDB parser that reads sequentially like the C++ reference.
# Scope: v222 format, Float32 values, Zlib + NoCompression only.
#
# Module structure:
#   Binary.jl  - Binary reading primitives
#   Types.jl   - Core data structures
#   Mask.jl    - NodeMask implementation
#   Header.jl  - VDB header parsing
#
# All read functions have signature: (bytes::Vector{UInt8}, pos::Int) -> (result, new_pos::Int)
# Positions are 1-indexed (Julia convention)
# All multi-byte types are little-endian

module TinyVDB

# =============================================================================
# Includes (order matters - dependencies first)
# =============================================================================

include("Binary.jl")
include("Types.jl")
include("Mask.jl")
include("Header.jl")
include("GridDescriptor.jl")
include("Compression.jl")
include("Topology.jl")
include("Values.jl")
include("Parser.jl")

# =============================================================================
# Exports
# =============================================================================

# Binary primitives
export read_u8, read_i32, read_u32, read_i64, read_u64, read_f32, read_f64, read_string

# Data structures
export Coord, VDBHeader, NodeType, NODE_ROOT, NODE_INTERNAL, NODE_LEAF

# Mask
export NodeMask, is_on, set_on!, count_on, read_mask

# Header
export read_header, VDB_MAGIC

# Grid Descriptor
export GridDescriptor, strip_suffix, read_grid_descriptor, read_grid_descriptors

# Compression
export COMPRESS_NONE, COMPRESS_ZIP, COMPRESS_ACTIVE_MASK, COMPRESS_BLOSC
export read_grid_compression, read_compressed_data, read_f32_values

# Topology
export LeafNodeData, InternalNodeData, RootNodeData
export LOG2DIM_LEAF, LOG2DIM_I1, LOG2DIM_I2
export read_leaf_topology, read_internal_topology, read_root_topology

# Values
export NO_MASK_OR_INACTIVE_VALS, NO_MASK_AND_ONE_INACTIVE_VAL, NO_MASK_AND_ALL_VALS
export read_leaf_values, read_internal_values, read_tree_values

# Parser
export TinyGrid, TinyVDBFile
export read_metadata, read_transform, read_grid, parse_tinyvdb

end # module TinyVDB
