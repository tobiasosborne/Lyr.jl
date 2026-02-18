# GridDescriptor.jl - Grid descriptor parsing for TinyVDB
#
# A GridDescriptor contains metadata about a grid in the VDB file:
# - unique_name: grid name with optional suffix for disambiguation
# - grid_name: the base name (unique_name with suffix stripped)
# - grid_type: the tree type string (e.g., "Tree_float_5_4_3")
# - half_precision: whether float values are stored as half precision
# - instance_parent: for instanced grids, the parent grid name
# - grid_pos: absolute file offset where grid data starts
# - block_pos: absolute file offset where values section starts
# - end_pos: absolute file offset where grid data ends

# =============================================================================
# Constants
# =============================================================================

"""Separator character used in grid names for disambiguation."""
const SEP = Char(0x1e)  # ASCII record separator

"""Suffix indicating half-precision float storage."""
const HALF_FLOAT_SUFFIX = "_HalfFloat"

# =============================================================================
# Data Structures
# =============================================================================

"""
    GridDescriptor

Describes a single grid in a VDB file, including its name, type, and byte offsets.

# Fields
- `grid_name::String`: Base grid name (with suffix stripped)
- `unique_name::String`: Full unique name including any suffix
- `grid_type::String`: Tree type string (e.g., "Tree_float_5_4_3")
- `half_precision::Bool`: Whether values are stored as half floats
- `instance_parent::String`: Parent grid name for instanced grids (usually empty)
- `grid_pos::Int64`: Absolute file offset to grid data start
- `block_pos::Int64`: Absolute file offset to values section start
- `end_pos::Int64`: Absolute file offset to grid data end
"""
struct GridDescriptor
    grid_name::String
    unique_name::String
    grid_type::String
    half_precision::Bool
    instance_parent::String
    grid_pos::Int64
    block_pos::Int64
    end_pos::Int64
end

# =============================================================================
# Helper Functions
# =============================================================================

"""
    strip_suffix(name::String) -> String

Strip the disambiguation suffix from a grid name.
The suffix starts with SEP (0x1e) followed by a number.

# Examples
```julia
strip_suffix("density")              # "density"
strip_suffix("density\\x1e0")        # "density"
```
"""
function strip_suffix(name::String)::String
    idx = findfirst(SEP, name)
    if idx === nothing
        return name
    else
        return name[1:prevind(name, idx)]
    end
end

"""
    strip_half_float_suffix(grid_type::String) -> Tuple{String, Bool}

Check if grid_type ends with "_HalfFloat" suffix.
Returns (stripped_type, is_half_precision).

# Examples
```julia
strip_half_float_suffix("Tree_float_5_4_3")           # ("Tree_float_5_4_3", false)
strip_half_float_suffix("Tree_float_5_4_3_HalfFloat") # ("Tree_float_5_4_3", true)
```
"""
function strip_half_float_suffix(grid_type::String)::Tuple{String, Bool}
    if endswith(grid_type, HALF_FLOAT_SUFFIX)
        stripped = grid_type[1:end-length(HALF_FLOAT_SUFFIX)]
        return (stripped, true)
    else
        return (grid_type, false)
    end
end

# =============================================================================
# Parsing Functions
# =============================================================================

"""
    read_grid_descriptor(bytes::Vector{UInt8}, pos::Int) -> Tuple{GridDescriptor, Int}

Read a single GridDescriptor from bytes at the given position.

Format:
- unique_name: string (u32 length + chars)
- grid_type: string (u32 length + chars)
- instance_parent: string (u32 length + chars)
- grid_pos: i64
- block_pos: i64
- end_pos: i64

Returns the descriptor and the new position after reading.
"""
function read_grid_descriptor(bytes::Vector{UInt8}, pos::Int)::Tuple{GridDescriptor, Int}
    # Read unique_name
    unique_name, pos = read_string(bytes, pos)
    grid_name = strip_suffix(unique_name)

    # Read grid_type and check for half precision
    raw_grid_type, pos = read_string(bytes, pos)
    grid_type, half_precision = strip_half_float_suffix(raw_grid_type)

    # Read instance_parent
    instance_parent, pos = read_string(bytes, pos)

    # Read offsets
    grid_pos, pos = read_i64(bytes, pos)
    block_pos, pos = read_i64(bytes, pos)
    end_pos, pos = read_i64(bytes, pos)

    gd = GridDescriptor(
        grid_name,
        unique_name,
        grid_type,
        half_precision,
        instance_parent,
        grid_pos,
        block_pos,
        end_pos
    )

    return (gd, pos)
end

"""
    read_grid_descriptors(bytes::Vector{UInt8}, pos::Int) -> Tuple{Dict{String, GridDescriptor}, Int}

Read all grid descriptors from bytes at the given position.

Format:
- count: i32 (number of descriptors)
- descriptors: count × GridDescriptor

Returns a dictionary mapping grid names to descriptors, and the new position.
"""
function read_grid_descriptors(bytes::Vector{UInt8}, pos::Int)::Tuple{Dict{String, GridDescriptor}, Int}
    # Read count
    count, pos = read_u32(bytes, pos)

    if count > 10000
        error("Invalid grid descriptor count: $count")
    end

    descriptors = Dict{String, GridDescriptor}()

    for _ in 1:count
        gd, pos = read_grid_descriptor(bytes, pos)
        descriptors[gd.grid_name] = gd
    end

    return (descriptors, pos)
end
