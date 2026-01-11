#!/usr/bin/env julia
using Lyr

function main()
    path = "test/fixtures/samples/torus.vdb"
    bytes = read(path)

    header, pos = Lyr.read_header(bytes, 1)
    while Lyr.is_metadata_entry(bytes, pos)
        _, pos = Lyr.read_string_with_size(bytes, pos)
        type_name, pos = Lyr.read_string_with_size(bytes, pos)
        pos = Lyr.skip_metadata_value_heuristic(bytes, pos, type_name)
    end
    _, pos = Lyr.read_u32_le(bytes, pos)
    desc, pos = Lyr.read_grid_descriptor(bytes, pos, header.has_grid_offsets)

    grid_data_pos = Int(desc.byte_offset) + 1
    values_start = grid_data_pos + Int(desc.block_offset)

    println("Hexdump of first 64 bytes from values_start ($values_start):")
    println()

    for row in 0:3
        start = values_start + row * 16
        # Print offset
        print("$(lpad(row * 16, 4, ' ')): ")

        # Print hex bytes
        for col in 0:15
            print(string(bytes[start + col], base=16, pad=2), " ")
        end

        # Print ASCII
        print(" |")
        for col in 0:15
            b = bytes[start + col]
            if 32 <= b <= 126
                print(Char(b))
            else
                print(".")
            end
        end
        println("|")
    end

    println()
    println("=== Interpretation ===")
    println()

    pos = values_start
    println("Bytes 0-3: $(bytes[pos:pos+3]) as Float32 = $(reinterpret(Float32, bytes[pos:pos+3])[1])")
    println("Bytes 4-7: $(bytes[pos+4:pos+7]) as Float32 = $(reinterpret(Float32, bytes[pos+4:pos+7])[1])")
    println("Bytes 8-11: $(bytes[pos+8:pos+11]) as Float32 = $(reinterpret(Float32, bytes[pos+8:pos+11])[1])")
    println("Bytes 12-15: $(bytes[pos+12:pos+15]) as Float32 = $(reinterpret(Float32, bytes[pos+12:pos+15])[1])")
    println("Bytes 16-19: $(bytes[pos+16:pos+19]) as Float32 = $(reinterpret(Float32, bytes[pos+16:pos+19])[1])")

    # Maybe it's selection mask data?
    println()
    println("Bytes 0-17 as bit pattern (possible selection mask):")
    for i in 0:17
        print(lpad(string(bytes[pos + i], base=2, pad=8), 9, ' '))
        if (i + 1) % 4 == 0
            println()
        end
    end

    # Look for a potential compressed data marker
    println()
    println("Looking for zlib magic (78 9c or 78 01 or 78 da):")
    for offset in 0:100
        if bytes[pos + offset] == 0x78 &&
           (bytes[pos + offset + 1] == 0x9c ||
            bytes[pos + offset + 1] == 0x01 ||
            bytes[pos + offset + 1] == 0xda)
            println("  Found zlib header at offset $offset (position $(pos + offset))")
        end
    end

    # Check positions 27-30 more carefully
    println()
    println("Position 490252 (offset 27) onwards as Float32:")
    target = values_start + 27
    for i in 1:10
        v = reinterpret(Float32, bytes[target + (i-1)*4:target + (i-1)*4 + 3])[1]
        println("  Value $i: $v")
    end

    # Also check what offset 23 contains
    println()
    println("Bytes 20-31:")
    for i in 20:31
        print(string(bytes[pos + i], base=16, pad=2), " ")
    end
    println()
end
main()
