# Header.jl - VDB file header parsing for TinyVDB

"""
VDB file magic bytes: " BDV" followed by 4 null bytes.
Stored as raw ASCII bytes at the start of every VDB file.
Note: This spells " BDV" not " VDB" - the format stores it this way.
"""
const VDB_MAGIC_BYTES = UInt8[0x20, 0x42, 0x44, 0x56, 0x00, 0x00, 0x00, 0x00]

"""
VDB file magic number as Int64 for legacy comparisons.
"""
const VDB_MAGIC = Int64(0x20424456)

"""
    read_header(bytes::Vector{UInt8}, pos::Int) -> Tuple{VDBHeader, Int}

Parse VDB file header starting at position `pos`.

The VDB header layout is:
- [0:7]   magic number (8 bytes: " BDV" + 4 null bytes)
- [8:11]  file version (uint32)
- [12:15] major version (uint32)
- [16:19] minor version (uint32)
- [20]    has_grid_offsets (byte, 1 = yes)
- [21]    is_compressed (byte, only for version 220-221)
- [36 bytes] uuid (ASCII string)

Returns the header and the 1-indexed position immediately after the header.
"""
function read_header(bytes::Vector{UInt8}, pos::Int)::Tuple{VDBHeader, Int}
    # Read and verify magic bytes
    @boundscheck checkbounds(bytes, pos:pos+7)
    magic_bytes = bytes[pos:pos+7]
    pos += 8

    if magic_bytes != VDB_MAGIC_BYTES
        throw(FormatError("Invalid VDB magic bytes: expected $(VDB_MAGIC_BYTES), got $(magic_bytes)"))
    end

    # Read file version
    file_version, pos = read_u32(bytes, pos)
    file_version < 220 && throw(UnsupportedVersionError(file_version, UInt32(220)))

    # Read library versions
    major_version, pos = read_u32(bytes, pos)
    minor_version, pos = read_u32(bytes, pos)

    # Read has_grid_offsets flag
    has_offsets, pos = read_u8(bytes, pos)
    has_offsets == 0 && throw(FormatError("VDB files without grid offsets are not supported"))

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
