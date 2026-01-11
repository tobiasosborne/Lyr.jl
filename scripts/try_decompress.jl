#!/usr/bin/env julia
using Lyr
using CodecZlib

function main()
    path = "test/fixtures/samples/torus.vdb"
    bytes = read(path)

    # Parse header
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

    println("values_start = $values_start")

    # Try decompressing raw bytes from values_start
    println("\n=== Try direct zlib decompression from values_start ===")

    # Try various start offsets
    for offset in [0, 1, 8, 9, 27]
        start_pos = values_start + offset
        println("\n--- Offset $offset (position $start_pos) ---")

        # Take a chunk of bytes
        try
            chunk = bytes[start_pos:min(start_pos+2000, end)]
            decompressed = transcode(ZlibDecompressor, chunk)
            println("Decompressed $(length(decompressed)) bytes")

            # Interpret as Float32
            if length(decompressed) >= 40
                vals = reinterpret(Float32, decompressed[1:40])
                println("First 10 Float32: $vals")
            end
        catch e
            println("Decompression failed: $(typeof(e))")
        end
    end

    # Check the actual data at offset 27
    println("\n\n=== Raw data at offset 27 ===")
    pos = values_start + 27
    println("Position: $pos")
    println("First 40 bytes:")
    for i in 0:39
        print(string(bytes[pos + i], base=16, pad=2), " ")
        (i+1) % 16 == 0 && println()
    end
    println()

    println("\nAs Float32 values:")
    for i in 1:10
        v = reinterpret(Float32, bytes[pos:pos+3])[1]
        println("  $i: $v")
        pos += 4
    end
end
main()
