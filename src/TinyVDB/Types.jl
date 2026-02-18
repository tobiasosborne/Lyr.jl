# Types.jl - Core data structures for TinyVDB

"""
    Coord

A 3D integer coordinate, matching OpenVDB's Coord (int[3] origin).
"""
struct Coord
    x::Int32
    y::Int32
    z::Int32
end

"""
    VDBHeader

VDB file header information.
"""
struct VDBHeader
    file_version::UInt32
    major_version::UInt32
    minor_version::UInt32
    is_compressed::Bool
    half_precision::Bool
    uuid::String
    data_pos::UInt64  # 1-indexed position after header (redundant with read_header return pos)
end

"""
    NodeType

Type of node in the VDB tree hierarchy.
"""
@enum NodeType begin
    NODE_ROOT
    NODE_INTERNAL
    NODE_LEAF
end
