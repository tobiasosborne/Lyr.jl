# GridDescriptor.jl - VDB grid descriptor parsing

"""
    GridDescriptor

Metadata describing a grid within a VDB file.

# Fields
- `name::String` - Grid name
- `grid_type::String` - Grid type string (e.g., "Tree_float_5_4_3")
- `instance_parent::String` - Parent grid name for instanced grids
- `byte_offset::Int64` - Byte offset to grid data
- `block_offset::Int64` - Block offset within grid
- `end_offset::Int64` - End offset of grid data
"""
struct GridDescriptor
    name::String
    grid_type::String
    instance_parent::String
    byte_offset::Int64
    block_offset::Int64
    end_offset::Int64
end

"""
    read_grid_descriptor(bytes::Vector{UInt8}, pos::Int, has_offsets::Bool) -> Tuple{GridDescriptor, Int}

Parse a grid descriptor.
"""
function read_grid_descriptor(bytes::Vector{UInt8}, pos::Int, has_offsets::Bool)::Tuple{GridDescriptor, Int}
    # Read name
    name, pos = read_string_with_size(bytes, pos)

    # Read grid type
    grid_type, pos = read_string_with_size(bytes, pos)

    # Read instance parent (empty string if not instanced)
    instance_parent, pos = read_string_with_size(bytes, pos)

    # Read offsets if present
    byte_offset = Int64(0)
    block_offset = Int64(0)
    end_offset = Int64(0)

    if has_offsets
        byte_offset, pos = read_i64_le(bytes, pos)
        block_offset, pos = read_i64_le(bytes, pos)
        end_offset, pos = read_i64_le(bytes, pos)
    end

    descriptor = GridDescriptor(name, grid_type, instance_parent, byte_offset, block_offset, end_offset)
    (descriptor, pos)
end

"""
    parse_value_type(grid_type::String) -> DataType

Parse the value type from a grid type string.
"""
function parse_value_type(grid_type::String)::DataType
    if Base.contains(grid_type, "float") || Base.contains(grid_type, "Float")
        Float32
    elseif Base.contains(grid_type, "double") || Base.contains(grid_type, "Double")
        Float64
    elseif Base.contains(grid_type, "int32") || Base.contains(grid_type, "Int32")
        Int32
    elseif Base.contains(grid_type, "int64") || Base.contains(grid_type, "Int64")
        Int64
    elseif Base.contains(grid_type, "Vec3f") || Base.contains(grid_type, "vec3f")
        NTuple{3, Float32}
    elseif Base.contains(grid_type, "Vec3d") || Base.contains(grid_type, "vec3d")
        NTuple{3, Float64}
    elseif Base.contains(grid_type, "bool") || Base.contains(grid_type, "Bool")
        Bool
    else
        Float32  # Default to Float32
    end
end
