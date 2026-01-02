# File.jl - Top-level VDB file parsing

"""
VDB file magic number: " BDV" in little-endian (0x56444220)
"""
const VDB_MAGIC = 0x20424456

"""
    VDBHeader

Header information from a VDB file.

# Fields
- `format_version::UInt32` - File format version
- `library_major::UInt32` - Library major version
- `library_minor::UInt32` - Library minor version
- `has_grid_offsets::Bool` - Whether grid offsets are stored
- `compression::Codec` - File-level compression codec
- `uuid::NTuple{16, UInt8}` - Unique file identifier
"""
struct VDBHeader
    format_version::UInt32
    library_major::UInt32
    library_minor::UInt32
    has_grid_offsets::Bool
    compression::Codec
    uuid::NTuple{16, UInt8}
end

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
    VDBFile

A parsed VDB file containing header and grids.

# Fields
- `header::VDBHeader` - File header
- `grids::Vector{Grid}` - Parsed grids (type-erased)
"""
struct VDBFile
    header::VDBHeader
    grids::Vector{Any}  # Vector of Grid{T} for various T
end

"""
    read_header(bytes::Vector{UInt8}, pos::Int) -> Tuple{VDBHeader, Int}

Parse VDB file header.
"""
function read_header(bytes::Vector{UInt8}, pos::Int)::Tuple{VDBHeader, Int}
    # Read and verify magic number
    magic, pos = read_u32_le(bytes, pos)
    if magic != VDB_MAGIC
        error("Invalid VDB magic number: expected 0x$(string(VDB_MAGIC, base=16)), got 0x$(string(magic, base=16))")
    end

    # Read format version
    format_version, pos = read_u32_le(bytes, pos)

    # Read library version
    library_major, pos = read_u32_le(bytes, pos)
    library_minor, pos = read_u32_le(bytes, pos)

    # Read flags
    has_grid_offsets = false
    compression = NoCompression()

    if format_version >= 212
        # Grid offsets flag
        offsets_byte, pos = read_u8(bytes, pos)
        has_grid_offsets = offsets_byte != 0
    end

    if format_version >= 222
        # Compression flag
        compression_byte, pos = read_u8(bytes, pos)
        compression = if compression_byte == 0
            NoCompression()
        elseif compression_byte == 1
            ZipCodec()
        elseif compression_byte == 2
            BloscCodec()
        else
            NoCompression()  # Unknown, assume none
        end
    end

    # Read UUID (16 bytes)
    uuid_bytes, pos = read_bytes(bytes, pos, 16)
    uuid = NTuple{16, UInt8}(uuid_bytes)

    header = VDBHeader(format_version, library_major, library_minor, has_grid_offsets, compression, uuid)
    (header, pos)
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
    if contains(grid_type, "float") || contains(grid_type, "Float")
        Float32
    elseif contains(grid_type, "double") || contains(grid_type, "Double")
        Float64
    elseif contains(grid_type, "int32") || contains(grid_type, "Int32")
        Int32
    elseif contains(grid_type, "int64") || contains(grid_type, "Int64")
        Int64
    elseif contains(grid_type, "Vec3f") || contains(grid_type, "vec3f")
        NTuple{3, Float32}
    elseif contains(grid_type, "Vec3d") || contains(grid_type, "vec3d")
        NTuple{3, Float64}
    elseif contains(grid_type, "bool") || contains(grid_type, "Bool")
        Bool
    else
        Float32  # Default to Float32
    end
end

"""
    parse_vdb(bytes::Vector{UInt8}) -> VDBFile

Parse a complete VDB file from bytes.
"""
function parse_vdb(bytes::Vector{UInt8})::VDBFile
    pos = 1

    # Read header
    header, pos = read_header(bytes, pos)

    # Read metadata (skip for now - just read past it)
    # Metadata is stored as a count followed by key-value pairs
    metadata_count, pos = read_u32_le(bytes, pos)
    for _ in 1:metadata_count
        key, pos = read_string_with_size(bytes, pos)
        type_name, pos = read_string_with_size(bytes, pos)
        # Skip the value based on type
        if type_name == "string"
            _, pos = read_string_with_size(bytes, pos)
        elseif type_name == "int32"
            _, pos = read_i32_le(bytes, pos)
        elseif type_name == "int64"
            _, pos = read_i64_le(bytes, pos)
        elseif type_name == "float"
            _, pos = read_f32_le(bytes, pos)
        elseif type_name == "double"
            _, pos = read_f64_le(bytes, pos)
        elseif type_name == "bool"
            _, pos = read_u8(bytes, pos)
        elseif type_name == "vec3i"
            _, pos = read_i32_le(bytes, pos)
            _, pos = read_i32_le(bytes, pos)
            _, pos = read_i32_le(bytes, pos)
        elseif type_name == "vec3f" || type_name == "vec3s"
            _, pos = read_f32_le(bytes, pos)
            _, pos = read_f32_le(bytes, pos)
            _, pos = read_f32_le(bytes, pos)
        elseif type_name == "vec3d"
            _, pos = read_f64_le(bytes, pos)
            _, pos = read_f64_le(bytes, pos)
            _, pos = read_f64_le(bytes, pos)
        else
            # Unknown type, try to skip
            error("Unknown metadata type: $type_name")
        end
    end

    # Read grid count
    grid_count, pos = read_u32_le(bytes, pos)

    # Read grid descriptors
    descriptors = Vector{GridDescriptor}(undef, grid_count)
    for i in 1:grid_count
        descriptors[i], pos = read_grid_descriptor(bytes, pos, header.has_grid_offsets)
    end

    # Parse each grid
    grids = Vector{Any}(undef, grid_count)
    for i in 1:grid_count
        desc = descriptors[i]

        # Skip instanced grids for now
        if !isempty(desc.instance_parent)
            continue
        end

        # Determine value type
        T = parse_value_type(desc.grid_type)

        # Read grid class from metadata in grid
        grid_class_str, pos = read_string_with_size(bytes, pos)
        grid_class = parse_grid_class(grid_class_str)

        # Parse the grid
        if T == Float32
            grids[i], pos = read_grid(Float32, bytes, pos, header.compression, desc.name, grid_class)
        elseif T == Float64
            grids[i], pos = read_grid(Float64, bytes, pos, header.compression, desc.name, grid_class)
        elseif T == NTuple{3, Float32}
            grids[i], pos = read_grid(NTuple{3, Float32}, bytes, pos, header.compression, desc.name, grid_class)
        else
            # Skip unsupported types
            grids[i] = nothing
        end
    end

    # Filter out nothing entries
    grids = filter(!isnothing, grids)

    VDBFile(header, grids)
end

"""
    parse_vdb(path::String) -> VDBFile

Parse a VDB file from a file path.
"""
function parse_vdb(path::String)::VDBFile
    bytes = read(path)
    parse_vdb(bytes)
end
