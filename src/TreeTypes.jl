# TreeTypes.jl — Immutable algebraic data types for the VDB tree hierarchy

"""
    GridClass

Enumeration of grid classification types.
Defined here (before Topology.jl) so read_root_topology can use it.
"""
@enum GridClass begin
    GRID_LEVEL_SET
    GRID_FOG_VOLUME
    GRID_STAGGERED
    GRID_UNKNOWN
end

"""
    AbstractNode{T}

Abstract type for all VDB tree nodes parameterized by value type T.
"""
abstract type AbstractNode{T} end

"""
    LeafNode{T} <: AbstractNode{T}

A leaf node containing 8x8x8 = 512 voxels.

# Fields
- `origin::Coord` - Origin coordinate of this leaf (aligned to 8)
- `value_mask::LeafMask` - Bitmask indicating which voxels are active
- `values::NTuple{512, T}` - Voxel values
"""
struct LeafNode{T} <: AbstractNode{T}
    origin::Coord
    value_mask::LeafMask
    values::NTuple{512, T}
end

"""
    Tile{T}

A constant-value tile representing a region filled with a single value.

# Fields
- `value::T` - The tile value
- `active::Bool` - Whether the tile is active
"""
struct Tile{T}
    value::T
    active::Bool
end

"""
    InternalNode1{T} <: AbstractNode{T}

Internal node at level 1 (above leaves), containing 16x16x16 = 4096 children.
Children (LeafNodes) and active tiles are stored in separate type-stable vectors,
indexed via popcount on the respective bitmask.

# Fields
- `origin::Coord` - Origin coordinate of this node (aligned to 128)
- `child_mask::Internal1Mask` - Bitmask indicating which entries are child nodes
- `value_mask::Internal1Mask` - Bitmask indicating which entries are active tiles
- `children::Vector{LeafNode{T}}` - Child leaf nodes (sparse, indexed by child_mask popcount)
- `tiles::Vector{Tile{T}}` - Active tiles (sparse, indexed by value_mask popcount)
"""
struct InternalNode1{T} <: AbstractNode{T}
    origin::Coord
    child_mask::Internal1Mask
    value_mask::Internal1Mask
    children::Vector{LeafNode{T}}
    tiles::Vector{Tile{T}}
end

"""
    InternalNode2{T} <: AbstractNode{T}

Internal node at level 2 (above InternalNode1), containing 32x32x32 = 32768 children.
Children (InternalNode1s) and active tiles are stored in separate type-stable vectors,
indexed via popcount on the respective bitmask.

# Fields
- `origin::Coord` - Origin coordinate of this node (aligned to 4096)
- `child_mask::Internal2Mask` - Bitmask indicating which entries are child nodes
- `value_mask::Internal2Mask` - Bitmask indicating which entries are active tiles
- `children::Vector{InternalNode1{T}}` - Child I1 nodes (sparse, indexed by child_mask popcount)
- `tiles::Vector{Tile{T}}` - Active tiles (sparse, indexed by value_mask popcount)
"""
struct InternalNode2{T} <: AbstractNode{T}
    origin::Coord
    child_mask::Internal2Mask
    value_mask::Internal2Mask
    children::Vector{InternalNode1{T}}
    tiles::Vector{Tile{T}}
end

"""
    RootNode{T} <: AbstractNode{T}

The root node of a VDB tree. Uses separate hash maps for children and tiles,
eliminating Union-typed dispatch on every access.

# Fields
- `background::T` - Background value for empty space
- `children::Dict{Coord, InternalNode2{T}}` - Internal node children indexed by origin
- `tiles::Dict{Coord, Tile{T}}` - Active tiles indexed by origin
"""
struct RootNode{T} <: AbstractNode{T}
    background::T
    children::Dict{Coord, InternalNode2{T}}
    tiles::Dict{Coord, Tile{T}}
end

"""Construct RootNode by splitting a Union-typed table into children and tiles."""
function RootNode{T}(background::T, table::Dict{Coord, Union{InternalNode2{T}, Tile{T}}}) where T
    children = Dict{Coord, InternalNode2{T}}()
    tiles = Dict{Coord, Tile{T}}()
    for (k, v) in table
        if v isa InternalNode2{T}
            children[k] = v
        else
            tiles[k] = v::Tile{T}
        end
    end
    RootNode{T}(background, children, tiles)
end

"""Construct empty RootNode with given background."""
RootNode{T}(background::T) where T = RootNode{T}(background,
    Dict{Coord, InternalNode2{T}}(), Dict{Coord, Tile{T}}())

"""
    Tree{T}

Type alias for the root of a VDB tree.
"""
const Tree{T} = RootNode{T}

# --- Base.show methods ---

function Base.show(io::IO, leaf::LeafNode{T}) where T
    n = count_on(leaf.value_mask)
    print(io, "LeafNode{", T, "}(origin=(", leaf.origin.x, ", ", leaf.origin.y, ", ", leaf.origin.z, "), ", n, "/512 active)")
end

function Base.show(io::IO, t::Tile{T}) where T
    print(io, "Tile{", T, "}(", t.value, ", ", t.active ? "active" : "inactive", ")")
end

function Base.show(io::IO, node::InternalNode1{T}) where T
    nc = count_on(node.child_mask)
    nt = count_on(node.value_mask)
    print(io, "InternalNode1{", T, "}(origin=(", node.origin.x, ", ", node.origin.y, ", ", node.origin.z, "), ", nc, " children, ", nt, " tiles)")
end

function Base.show(io::IO, node::InternalNode2{T}) where T
    nc = count_on(node.child_mask)
    nt = count_on(node.value_mask)
    print(io, "InternalNode2{", T, "}(origin=(", node.origin.x, ", ", node.origin.y, ", ", node.origin.z, "), ", nc, " children, ", nt, " tiles)")
end

function Base.show(io::IO, tree::RootNode{T}) where T
    n = length(tree.children) + length(tree.tiles)
    print(io, "Tree{", T, "}(background=", tree.background, ", ", n, " root entr", n == 1 ? "y" : "ies", ")")
end
