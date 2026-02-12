# Coordinates.jl - Coordinate types and tree navigation

"""
    Coord

A 3D coordinate with Int32 components. This is a proper struct (not a type alias)
to avoid type piracy when extending methods.

# Fields
- `x::Int32` - X component
- `y::Int32` - Y component
- `z::Int32` - Z component
"""
struct Coord
    x::Int32
    y::Int32
    z::Int32
end

"""
    coord(x, y, z) -> Coord

Construct a coordinate from x, y, z values.
"""
coord(x, y, z)::Coord = Coord(Int32(x), Int32(y), Int32(z))

# Index access for backward compatibility
Base.getindex(c::Coord, i::Int) = i == 1 ? c.x : i == 2 ? c.y : i == 3 ? c.z : throw(BoundsError(c, i))
Base.length(::Coord) = 3
Base.iterate(c::Coord, state=1) = state > 3 ? nothing : (c[state], state + 1)

# Arithmetic operations
Base.:+(a::Coord, b::Coord)::Coord = Coord(a.x + b.x, a.y + b.y, a.z + b.z)
Base.:-(a::Coord, b::Coord)::Coord = Coord(a.x - b.x, a.y - b.y, a.z - b.z)
Base.min(a::Coord, b::Coord)::Coord = Coord(min(a.x, b.x), min(a.y, b.y), min(a.z, b.z))
Base.max(a::Coord, b::Coord)::Coord = Coord(max(a.x, b.x), max(a.y, b.y), max(a.z, b.z))

# VDB tree dimensions
const LEAF_DIM = Int32(8)      # 2^3 = 8
const LEAF_LOG2 = 3
const INTERNAL1_DIM = Int32(16)  # 2^4 = 16
const INTERNAL1_LOG2 = 4
const INTERNAL2_DIM = Int32(32)  # 2^5 = 32
const INTERNAL2_LOG2 = 5

# Total log2 dimensions for each level
const LEAF_TOTAL_LOG2 = LEAF_LOG2                                    # 3
const INTERNAL1_TOTAL_LOG2 = LEAF_LOG2 + INTERNAL1_LOG2              # 7
const INTERNAL2_TOTAL_LOG2 = LEAF_LOG2 + INTERNAL1_LOG2 + INTERNAL2_LOG2  # 12

"""
    leaf_origin(c::Coord) -> Coord

Round coordinate down to the origin of its containing leaf node (aligned to 8).
"""
function leaf_origin(c::Coord)::Coord
    mask = ~Int32(LEAF_DIM - 1)  # ~7 = ...11111000
    Coord(c.x & mask, c.y & mask, c.z & mask)
end

"""
    internal1_origin(c::Coord) -> Coord

Round coordinate down to the origin of its containing Internal1 node (aligned to 128 = 8*16).
"""
function internal1_origin(c::Coord)::Coord
    size = Int32(1) << INTERNAL1_TOTAL_LOG2  # 128
    mask = ~(size - 1)
    Coord(c.x & mask, c.y & mask, c.z & mask)
end

"""
    internal2_origin(c::Coord) -> Coord

Round coordinate down to the origin of its containing Internal2 node (aligned to 4096 = 8*16*32).
"""
function internal2_origin(c::Coord)::Coord
    size = Int32(1) << INTERNAL2_TOTAL_LOG2  # 4096
    mask = ~(size - 1)
    Coord(c.x & mask, c.y & mask, c.z & mask)
end

"""
    leaf_offset(c::Coord) -> Int

Compute the linear offset of a coordinate within its leaf node.

# Returns
- `Int` in range 0-511 (**0-indexed**).

# Indexing Convention
This function returns a **0-based index** for compatibility with bitmask operations
(`is_on`, `on_indices`, etc.) which use 0-indexed bit positions. For Julia array
access, add 1: `values[leaf_offset(c) + 1]`.

# Algorithm
Uses OpenVDB linear indexing: `offset = 64*x + 8*y + z` where x, y, z are the
local coordinates within the leaf (each 0-7). This matches the C++ reference
convention where x varies slowest.

# Example
```julia
c = Coord(5, 10, 3)
offset = leaf_offset(c)  # 0-based index
value = leaf.values[offset + 1]  # Julia 1-based array access
is_active = is_on(leaf.value_mask, offset)  # Mask uses 0-based indexing
```
"""
function leaf_offset(c::Coord)::Int
    # Get local coordinates within the leaf (0-7 each)
    lx = c.x & (LEAF_DIM - 1)
    ly = c.y & (LEAF_DIM - 1)
    lz = c.z & (LEAF_DIM - 1)
    Int(lx) * 64 + Int(ly) * 8 + Int(lz)
end

"""
    internal1_child_index(c::Coord) -> Int

Compute the child index for a coordinate within an Internal1 node.

# Returns
- `Int` in range 0-4095 (**0-indexed**).

# Indexing Convention
Returns a **0-based index** for compatibility with bitmask operations.
For table access, use with `on_indices` iteration pattern (see Accessors.jl).
"""
function internal1_child_index(c::Coord)::Int
    # Get coordinates relative to Internal1 origin, then extract Internal1 part
    shift = LEAF_LOG2  # 3
    mask = INTERNAL1_DIM - 1  # 15

    ix = (c.x >> shift) & mask
    iy = (c.y >> shift) & mask
    iz = (c.z >> shift) & mask

    Int(ix) * 256 + Int(iy) * 16 + Int(iz)
end

"""
    internal2_child_index(c::Coord) -> Int

Compute the child index for a coordinate within an Internal2 node.

# Returns
- `Int` in range 0-32767 (**0-indexed**).

# Indexing Convention
Returns a **0-based index** for compatibility with bitmask operations.
For table access, use with `on_indices` iteration pattern (see Accessors.jl).
"""
function internal2_child_index(c::Coord)::Int
    # Get coordinates relative to Internal2 origin, then extract Internal2 part
    shift = INTERNAL1_TOTAL_LOG2  # 7
    mask = INTERNAL2_DIM - 1  # 31

    ix = (c.x >> shift) & mask
    iy = (c.y >> shift) & mask
    iz = (c.z >> shift) & mask

    Int(ix) * 1024 + Int(iy) * 32 + Int(iz)
end

"""
    BBox

An axis-aligned bounding box defined by min and max coordinates.
"""
struct BBox
    min::Coord
    max::Coord
end

"""
    contains(bb::BBox, c::Coord) -> Bool

Check if the bounding box contains the given coordinate.
"""
function contains(bb::BBox, c::Coord)::Bool
    bb.min.x <= c.x <= bb.max.x &&
    bb.min.y <= c.y <= bb.max.y &&
    bb.min.z <= c.z <= bb.max.z
end

"""
    intersects(a::BBox, b::BBox) -> Bool

Check if two bounding boxes intersect.
"""
function intersects(a::BBox, b::BBox)::Bool
    a.min.x <= b.max.x && a.max.x >= b.min.x &&
    a.min.y <= b.max.y && a.max.y >= b.min.y &&
    a.min.z <= b.max.z && a.max.z >= b.min.z
end

"""
    union(a::BBox, b::BBox) -> BBox

Compute the bounding box that contains both input boxes.
"""
function Base.union(a::BBox, b::BBox)::BBox
    BBox(min(a.min, b.min), max(a.max, b.max))
end

"""
    volume(bb::BBox) -> Int64

Compute the volume of the bounding box.
"""
function volume(bb::BBox)::Int64
    dx = Int64(bb.max.x) - Int64(bb.min.x) + 1
    dy = Int64(bb.max.y) - Int64(bb.min.y) + 1
    dz = Int64(bb.max.z) - Int64(bb.min.z) + 1
    dx * dy * dz
end
