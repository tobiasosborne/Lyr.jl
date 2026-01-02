# Coordinates.jl - Coordinate types and tree navigation

"""
    Coord

A 3D coordinate represented as a tuple of Int32 values.
"""
const Coord = NTuple{3, Int32}

"""
    coord(x, y, z) -> Coord

Construct a coordinate from x, y, z values.
"""
coord(x, y, z)::Coord = (Int32(x), Int32(y), Int32(z))

# Arithmetic operations
Base.:+(a::Coord, b::Coord)::Coord = (a[1] + b[1], a[2] + b[2], a[3] + b[3])
Base.:-(a::Coord, b::Coord)::Coord = (a[1] - b[1], a[2] - b[2], a[3] - b[3])
Base.min(a::Coord, b::Coord)::Coord = (min(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3]))
Base.max(a::Coord, b::Coord)::Coord = (max(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))

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
    (c[1] & mask, c[2] & mask, c[3] & mask)
end

"""
    internal1_origin(c::Coord) -> Coord

Round coordinate down to the origin of its containing Internal1 node (aligned to 128 = 8*16).
"""
function internal1_origin(c::Coord)::Coord
    size = Int32(1) << INTERNAL1_TOTAL_LOG2  # 128
    mask = ~(size - 1)
    (c[1] & mask, c[2] & mask, c[3] & mask)
end

"""
    internal2_origin(c::Coord) -> Coord

Round coordinate down to the origin of its containing Internal2 node (aligned to 4096 = 8*16*32).
"""
function internal2_origin(c::Coord)::Coord
    size = Int32(1) << INTERNAL2_TOTAL_LOG2  # 4096
    mask = ~(size - 1)
    (c[1] & mask, c[2] & mask, c[3] & mask)
end

"""
    leaf_offset(c::Coord) -> Int

Compute the linear offset (0-511) of a coordinate within its leaf node.
Uses Morton/Z-order: offset = x + 8*y + 64*z (for coordinates within leaf).
"""
function leaf_offset(c::Coord)::Int
    # Get local coordinates within the leaf (0-7 each)
    lx = c[1] & (LEAF_DIM - 1)
    ly = c[2] & (LEAF_DIM - 1)
    lz = c[3] & (LEAF_DIM - 1)
    Int(lx) + Int(ly) * 8 + Int(lz) * 64
end

"""
    internal1_child_index(c::Coord) -> Int

Compute the child index (0-4095) for a coordinate within an Internal1 node.
"""
function internal1_child_index(c::Coord)::Int
    # Get coordinates relative to Internal1 origin, then extract Internal1 part
    shift = LEAF_LOG2  # 3
    mask = INTERNAL1_DIM - 1  # 15

    ix = (c[1] >> shift) & mask
    iy = (c[2] >> shift) & mask
    iz = (c[3] >> shift) & mask

    Int(ix) + Int(iy) * 16 + Int(iz) * 256
end

"""
    internal2_child_index(c::Coord) -> Int

Compute the child index (0-32767) for a coordinate within an Internal2 node.
"""
function internal2_child_index(c::Coord)::Int
    # Get coordinates relative to Internal2 origin, then extract Internal2 part
    shift = INTERNAL1_TOTAL_LOG2  # 7
    mask = INTERNAL2_DIM - 1  # 31

    ix = (c[1] >> shift) & mask
    iy = (c[2] >> shift) & mask
    iz = (c[3] >> shift) & mask

    Int(ix) + Int(iy) * 32 + Int(iz) * 1024
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
    bb.min[1] <= c[1] <= bb.max[1] &&
    bb.min[2] <= c[2] <= bb.max[2] &&
    bb.min[3] <= c[3] <= bb.max[3]
end

"""
    intersects(a::BBox, b::BBox) -> Bool

Check if two bounding boxes intersect.
"""
function intersects(a::BBox, b::BBox)::Bool
    a.min[1] <= b.max[1] && a.max[1] >= b.min[1] &&
    a.min[2] <= b.max[2] && a.max[2] >= b.min[2] &&
    a.min[3] <= b.max[3] && a.max[3] >= b.min[3]
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
    dx = Int64(bb.max[1]) - Int64(bb.min[1]) + 1
    dy = Int64(bb.max[2]) - Int64(bb.min[2]) + 1
    dz = Int64(bb.max[3]) - Int64(bb.min[3]) + 1
    dx * dy * dz
end
