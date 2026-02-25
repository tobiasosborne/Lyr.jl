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

function Base.show(io::IO, g::Grid{T}) where T
    lc = leaf_count(g.tree)
    ac = active_voxel_count(g.tree)
    vs = voxel_size(g.transform)
    print(io, "Grid{", T, "}(\"", g.name, "\", ", g.grid_class, ", ", lc, " leaves, ", ac, " active, voxel=", round(vs[1]; sigdigits=4), ")")
end

"""
    getindex(grid::Grid{T}, x, y, z) -> T

Access voxel value at integer coordinates: `grid[x, y, z]`.
"""
Base.getindex(g::Grid{T}, x::Integer, y::Integer, z::Integer) where T =
    get_value(g.tree, Coord(Int32(x), Int32(y), Int32(z)))

"""
    read_grid(::Type{T}, bytes, pos, codec, mask_compressed, name, grid_class, version; value_size) -> Tuple{Grid{T}, Int}

Parse a complete grid from bytes. Sequential reading — no seeking to offsets.
`value_size` is the on-disk element size (2 for half-precision Float16, otherwise sizeof(T)).
"""
function read_grid(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask_compressed::Bool, name::String, grid_class::GridClass, version::UInt32; value_size::Int=sizeof(T))::Tuple{Grid{T}, Int} where T
    # Read transform
    transform, pos = read_transform(bytes, pos)

    # Read buffer count (TreeBase header — always 1 for standard trees)
    _, pos = read_u32_le(bytes, pos)

    # Read background value
    background, pos = read_tile_value(T, bytes, pos)

    # Read tree
    tree, pos = read_tree(T, bytes, pos, codec, mask_compressed, background, grid_class, version; value_size)

    grid = Grid{T}(name, grid_class, transform, tree)
    (grid, pos)
end
