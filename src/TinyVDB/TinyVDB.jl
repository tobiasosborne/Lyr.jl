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

end # module TinyVDB
