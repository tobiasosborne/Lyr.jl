# Grid.jl - Grid wrapper combining tree, transform, and metadata
# Note: GridClass enum is defined in TreeTypes.jl for use in Topology.jl

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
    read_grid(::Type{T}, bytes, pos, codec, mask_compressed, name, grid_class, version) -> Tuple{Grid{T}, Int}

Parse a complete grid from bytes. Sequential reading — no seeking to offsets.
"""
function read_grid(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask_compressed::Bool, name::String, grid_class::GridClass, version::UInt32)::Tuple{Grid{T}, Int} where T
    # Read transform
    transform, pos = read_transform(bytes, pos)

    # Read background value
    background, pos = read_tile_value(T, bytes, pos)

    # Read tree
    tree, pos = read_tree(T, bytes, pos, codec, mask_compressed, background, grid_class, version)

    grid = Grid{T}(name, grid_class, transform, tree)
    (grid, pos)
end
