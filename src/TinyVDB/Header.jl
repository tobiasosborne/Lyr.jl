# Header.jl - VDB file header parsing for TinyVDB

"""
VDB file magic number: " VDB" (0x20424456) as little-endian Int64.
This is stored in the first 8 bytes of every VDB file.
"""
const VDB_MAGIC = Int64(0x20424456)

"""
    read_header(bytes::Vector{UInt8}, pos::Int) -> Tuple{VDBHeader, Int}

Parse VDB file header starting at position `pos`.

The VDB header layout is:
- [0:7]   magic number (0x20424456 = " VDB" as int64, little-endian)
- [8:11]  file version (uint32)
- [12:15] major version (uint32)
- [16:19] minor version (uint32)
- [20]    has_grid_offsets (byte, 1 = yes)
- [21]    is_compressed (byte, only for version 220-221)
- [36 bytes] uuid (ASCII string)

Returns the header and the position immediately after the header (offset_to_data).
"""
function read_header(bytes::Vector{UInt8}, pos::Int)::Tuple{VDBHeader, Int}
    # Read magic (8 bytes as Int64)
    magic, pos = read_i64(bytes, pos)
    magic != VDB_MAGIC && error("Invalid VDB magic number: expected 0x$(string(VDB_MAGIC, base=16)), got 0x$(string(magic, base=16))")

    # Read file version
    file_version, pos = read_u32(bytes, pos)
    file_version < 220 && error("VDB version $file_version not supported (minimum: 220)")

    # Read library versions
    major_version, pos = read_u32(bytes, pos)
    minor_version, pos = read_u32(bytes, pos)

    # Read has_grid_offsets flag
    has_offsets, pos = read_u8(bytes, pos)
    has_offsets == 0 && error("VDB files without grid offsets are not supported")

    # Read compression flag (only v220-221)
    is_compressed = false
    if file_version >= 220 && file_version < 222
        comp, pos = read_u8(bytes, pos)
        is_compressed = comp != 0
    end

    # Read UUID (36 bytes ASCII)
    @boundscheck checkbounds(bytes, pos:pos+35)
    uuid = GC.@preserve bytes unsafe_string(pointer(bytes, pos), 36)
    pos += 36

    # half_precision is determined from metadata later, default false
    half_precision = false

    header = VDBHeader(file_version, major_version, minor_version,
                       is_compressed, half_precision, uuid, UInt64(pos))
    (header, pos)
end
