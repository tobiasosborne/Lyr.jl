# Grid.jl - Grid wrapper combining tree, transform, and metadata

"""
    GridClass

Enumeration of grid classification types.
"""
@enum GridClass begin
    GRID_LEVEL_SET
    GRID_FOG_VOLUME
    GRID_STAGGERED
    GRID_UNKNOWN
end

"""
    parse_grid_class(s::String) -> GridClass

Parse a grid class string to enum value.
"""
function parse_grid_class(s::String)::GridClass
    s_lower = lowercase(s)
    if s_lower == "level set" || s_lower == "levelset"
        GRID_LEVEL_SET
    elseif s_lower == "fog volume" || s_lower == "fogvolume"
        GRID_FOG_VOLUME
    elseif s_lower == "staggered"
        GRID_STAGGERED
    else
        GRID_UNKNOWN
    end
end

"""
    Grid{T}

A complete VDB grid containing tree data, transform, and metadata.

# Fields
- `name::String` - Grid name
- `grid_class::GridClass` - Grid classification
- `transform::AbstractTransform` - Index to world coordinate transform
- `tree::Tree{T}` - The VDB tree containing voxel data
"""
struct Grid{T}
    name::String
    grid_class::GridClass
    transform::AbstractTransform
    tree::Tree{T}
end

"""
    read_grid(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, name::String, grid_class::GridClass) -> Tuple{Grid{T}, Int}

Parse a complete grid from bytes.
"""
function read_grid(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, name::String, grid_class::GridClass)::Tuple{Grid{T}, Int} where T
    # Read transform
    transform, pos = read_transform(bytes, pos)

    # Read background value
    background, pos = read_tile_value(T, bytes, pos)

    # Read topology
    topology, pos = read_root_topology(bytes, pos)

    # Materialize tree with values
    tree, pos = materialize_tree(T, topology, bytes, pos, codec, background)

    grid = Grid{T}(name, grid_class, transform, tree)
    (grid, pos)
end
