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
# Exports — minimal test oracle interface
# Internal symbols accessible via TinyVDB.symbol_name
# =============================================================================

# Entry point
export parse_tinyvdb, TinyVDBFile, TinyGrid

# Tree data structures (needed by TinyVDBBridge and equivalence tests)
export RootNodeData, InternalNodeData, LeafNodeData
export NodeMask, Coord, VDBHeader, GridDescriptor

end # module TinyVDB
