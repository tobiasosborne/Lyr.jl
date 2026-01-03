# File.jl - Top-level VDB file parsing

"""
VDB file magic number: bytes [0x20, 0x42, 0x44, 0x56] (" BDV") read as little-endian u32.
"""
const VDB_MAGIC = 0x56444220

"""
    VDBHeader

Header information from a VDB file.

# Fields
- `format_version::UInt32` - File format version
- `library_major::UInt32` - Library major version
- `library_minor::UInt32` - Library minor version
- `has_grid_offsets::Bool` - Whether grid offsets are stored
- `compression::Codec` - File-level compression codec
- `uuid::String` - Unique file identifier (36-char ASCII UUID string)
"""
struct VDBHeader
    format_version::UInt32
    library_major::UInt32
    library_minor::UInt32
    has_grid_offsets::Bool
    compression::Codec
    uuid::String
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

Parse VDB file header. Format (verified against OpenVDB samples):
- Magic (4 bytes) + padding (4 bytes) = 8 bytes total
- Format version (4 bytes u32 LE)
- Library major (4 bytes u32 LE)
- Library minor (4 bytes u32 LE)
- Has grid offsets (1 byte) if version >= 212
- UUID (36 bytes ASCII string, e.g., "a2313abf-7b19-4669-a9ea-f4a83e6bf20d")
- Compression (4 bytes u32 LE) if version >= 222: 0=none, 1=zlib, 2=blosc
"""
function read_header(bytes::Vector{UInt8}, pos::Int)::Tuple{VDBHeader, Int}
    # Read and verify magic number (4 bytes)
    magic, pos = read_u32_le(bytes, pos)
    if magic != VDB_MAGIC
        error("Invalid VDB magic number: expected 0x$(string(VDB_MAGIC, base=16)), got 0x$(string(magic, base=16))")
    end

    # Skip 4 bytes of padding after magic
    _, pos = read_u32_le(bytes, pos)

    # Read format version
    format_version, pos = read_u32_le(bytes, pos)

    # Read library version
    library_major, pos = read_u32_le(bytes, pos)
    library_minor, pos = read_u32_le(bytes, pos)

    # Read has_grid_offsets flag (1 byte) if version >= 212
    has_grid_offsets = false
    if format_version >= 212
        offsets_byte, pos = read_u8(bytes, pos)
        has_grid_offsets = offsets_byte != 0
    end

    # Version 220-221 has a half_float flag (1 byte) before UUID
    # This was removed in version 222+ (moved to per-grid metadata)
    if format_version >= 220 && format_version < 222
        _, pos = read_u8(bytes, pos)  # half_float flag (skip)
    end

    # Read UUID (36 bytes ASCII string)
    uuid_bytes, pos = read_bytes(bytes, pos, 36)
    uuid = String(uuid_bytes)

    # Read compression (4 bytes u32 LE) if version >= 222
    compression = NoCompression()
    if format_version >= 222
        compression_u32, pos = read_u32_le(bytes, pos)
        compression = if compression_u32 == 0
            NoCompression()
        elseif compression_u32 == 1
            ZipCodec()
        elseif compression_u32 == 2
            BloscCodec()
        else
            NoCompression()  # Unknown, assume none
        end
    end

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

"""
    is_printable_ascii(bytes::Vector{UInt8}, start::Int, len::Int) -> Bool

Check if bytes in range [start, start+len-1] are all printable ASCII (0x20-0x7e).
"""
function is_printable_ascii(bytes::Vector{UInt8}, start::Int, len::Int)::Bool
    for i in start:(start + len - 1)
        b = bytes[i]
        if b < 0x20 || b > 0x7e
            return false
        end
    end
    return true
end

"""
    is_metadata_entry(bytes::Vector{UInt8}, pos::Int) -> Bool

Heuristic to detect if current position is at a metadata entry (vs grid count).
VDB metadata has no count prefix; entries are sequential until grid count.
Returns true if this looks like a metadata key (small size + printable ASCII).
"""
function is_metadata_entry(bytes::Vector{UInt8}, pos::Int)::Bool
    # Peek at potential key size without advancing
    if pos + 3 > length(bytes)
        return false
    end
    key_size = ltoh(reinterpret(UInt32, @view bytes[pos:pos+3])[1])

    # Key sizes > 256 are unreasonably large for metadata keys
    if key_size == 0 || key_size > 256
        return false
    end

    # Check if we have enough bytes and they're printable ASCII
    key_start = pos + 4
    if key_start + Int(key_size) - 1 > length(bytes)
        return false
    end

    return is_printable_ascii(bytes, key_start, Int(key_size))
end

"""
    skip_metadata_value(bytes::Vector{UInt8}, pos::Int, type_name::String) -> Int

Skip a metadata value based on its type, returning the new position.
"""
function skip_metadata_value(bytes::Vector{UInt8}, pos::Int, type_name::String)::Int
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
        error("Unknown metadata type: $type_name")
    end
    return pos
end

"""
    parse_vdb(bytes::Vector{UInt8}) -> VDBFile

Parse a complete VDB file from bytes.
"""
function parse_vdb(bytes::Vector{UInt8})::VDBFile
    pos = 1

    # Read header
    header, pos = read_header(bytes, pos)

    # Read metadata entries (no count prefix - read until we hit grid count)
    # Each entry is: key_size, key, type_size, type, value
    while is_metadata_entry(bytes, pos)
        _, pos = read_string_with_size(bytes, pos)  # key
        type_name, pos = read_string_with_size(bytes, pos)  # type
        pos = skip_metadata_value(bytes, pos, type_name)  # value
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
            grids[i] = nothing
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
