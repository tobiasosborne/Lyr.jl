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
# Exception types (self-contained for standalone testing)
# =============================================================================

"""Generic parse/format error for VDB data."""
struct FormatError <: Exception
    message::String
end
Base.showerror(io::IO, e::FormatError) = print(io, "FormatError: ", e.message)

"""Thrown when VDB file version is not supported."""
struct UnsupportedVersionError <: Exception
    version::UInt32
    min_version::UInt32
end
Base.showerror(io::IO, e::UnsupportedVersionError) = print(io, "UnsupportedVersionError: version $(e.version) not supported (minimum: $(e.min_version))")

# =============================================================================
# Shared format constants (from parent Lyr module)
# =============================================================================

include(joinpath(@__DIR__, "..", "VDBConstants.jl"))

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
