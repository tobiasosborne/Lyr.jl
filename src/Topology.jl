# Topology.jl - Child origin computation helpers
#
# IMPORTANT: In the VDB binary format, only root entries store explicit origins.
# Internal2, Internal1, and Leaf nodes do NOT store their origins in the file.
# Origins for child nodes are computed from the parent origin + child index.
#
# Reference: https://jangafx.com/insights/vdb-a-deep-dive

"""
    child_origin_internal2(parent_origin::Coord, child_index::Int) -> Coord

Compute the origin of an Internal1 child within an Internal2 node.
Internal2 is 32³ grid, each Internal1 covers 128³ voxels.
"""
function child_origin_internal2(parent_origin::Coord, child_index::Int)::Coord
    # Internal1 child size: 16 × 8 = 128 voxels per dimension
    child_size = Int32(128)

    # Convert linear index to 3D offset within 32³ grid
    ix = Int32(child_index % 32)
    iy = Int32((child_index ÷ 32) % 32)
    iz = Int32(child_index ÷ 1024)

    Coord(parent_origin.x + ix * child_size,
          parent_origin.y + iy * child_size,
          parent_origin.z + iz * child_size)
end

"""
    child_origin_internal1(parent_origin::Coord, child_index::Int) -> Coord

Compute the origin of a Leaf child within an Internal1 node.
Internal1 is 16³ grid, each Leaf covers 8³ voxels.
"""
function child_origin_internal1(parent_origin::Coord, child_index::Int)::Coord
    # Leaf child size: 8 voxels per dimension
    child_size = Int32(8)

    # Convert linear index to 3D offset within 16³ grid
    ix = Int32(child_index % 16)
    iy = Int32((child_index ÷ 16) % 16)
    iz = Int32(child_index ÷ 256)

    Coord(parent_origin.x + ix * child_size,
          parent_origin.y + iy * child_size,
          parent_origin.z + iz * child_size)
end
