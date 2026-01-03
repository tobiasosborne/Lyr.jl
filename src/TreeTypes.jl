# TreeTypes.jl - Immutable algebraic data types for VDB tree structure

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
Each child is either a LeafNode or a Tile.

# Fields
- `origin::Coord` - Origin coordinate of this node (aligned to 128)
- `child_mask::Internal1Mask` - Bitmask indicating which entries are child nodes
- `value_mask::Internal1Mask` - Bitmask indicating which entries are active tiles
- `table::Vector{Union{LeafNode{T}, Tile{T}}}` - Child nodes and tiles (sparse)
"""
struct InternalNode1{T} <: AbstractNode{T}
    origin::Coord
    child_mask::Internal1Mask
    value_mask::Internal1Mask
    table::Vector{Union{LeafNode{T}, Tile{T}}}
end

"""
    InternalNode2{T} <: AbstractNode{T}

Internal node at level 2 (above InternalNode1), containing 32x32x32 = 32768 children.
Each child is either an InternalNode1 or a Tile.

# Fields
- `origin::Coord` - Origin coordinate of this node (aligned to 4096)
- `child_mask::Internal2Mask` - Bitmask indicating which entries are child nodes
- `value_mask::Internal2Mask` - Bitmask indicating which entries are active tiles
- `table::Vector{Union{InternalNode1{T}, Tile{T}}}` - Child nodes and tiles (sparse)
"""
struct InternalNode2{T} <: AbstractNode{T}
    origin::Coord
    child_mask::Internal2Mask
    value_mask::Internal2Mask
    table::Vector{Union{InternalNode1{T}, Tile{T}}}
end

"""
    RootNode{T} <: AbstractNode{T}

The root node of a VDB tree. Uses a hash map for sparse storage of top-level children.

# Fields
- `background::T` - Background value for empty space
- `table::Dict{Coord, Union{InternalNode2{T}, Tile{T}}}` - Children indexed by origin
"""
struct RootNode{T} <: AbstractNode{T}
    background::T
    table::Dict{Coord, Union{InternalNode2{T}, Tile{T}}}
end

"""
    Tree{T}

Type alias for the root of a VDB tree.
"""
const Tree{T} = RootNode{T}
