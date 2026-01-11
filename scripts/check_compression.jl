#!/usr/bin/env julia
using Lyr

function main()
    path = "test/fixtures/samples/torus.vdb"
    bytes = read(path)

    # Parse header manually to see the raw compression value
    pos = 1

    # Magic (4 bytes) + padding (4 bytes)
    magic, pos = Lyr.read_u32_le(bytes, pos)
    println("Magic: 0x$(string(magic, base=16))")
    _, pos = Lyr.read_u32_le(bytes, pos)

    # Format version
    format_version, pos = Lyr.read_u32_le(bytes, pos)
    println("Format version: $format_version")

    # Library version
    lib_major, pos = Lyr.read_u32_le(bytes, pos)
    lib_minor, pos = Lyr.read_u32_le(bytes, pos)
    println("Library: $lib_major.$lib_minor")

    # Has grid offsets (1 byte)
    if format_version >= 212
        has_offsets, pos = Lyr.read_u8(bytes, pos)
        println("Has grid offsets: $(has_offsets != 0)")
    end

    # UUID (36 bytes)
    uuid_bytes, pos = Lyr.read_bytes(bytes, pos, 36)
    println("UUID: $(String(uuid_bytes))")

    # Compression flags (4 bytes) for v222+
    if format_version >= 222
        compression_flags, pos = Lyr.read_u32_le(bytes, pos)
        println("\nCompression flags: $compression_flags (0x$(string(compression_flags, base=16)))")
        println("  COMPRESS_NONE (0x0): $(compression_flags == 0)")
        println("  COMPRESS_ZIP (0x1): $((compression_flags & 0x1) != 0)")
        println("  COMPRESS_ACTIVE_MASK (0x2): $((compression_flags & 0x2) != 0)")
        println("  COMPRESS_BLOSC (0x4): $((compression_flags & 0x4) != 0)")
    end
end
main()
