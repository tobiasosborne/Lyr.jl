#!/usr/bin/env julia
# Debug script to examine raw bytes at values section

using Lyr

function main()

path = "test/fixtures/samples/sphere.vdb"
bytes = read(path)

# Parse file to get grid info
pos = 1

# Skip header (8 magic + 4 version + 8 library + 1 has_offsets + 36 uuid = 57)
pos = 58

# Count file metadata
meta_count, pos = Lyr.read_u32_le(bytes, pos)
println("File metadata count: $meta_count")

# Skip file metadata (simplified - just find creator string)
for _ in 1:meta_count
    name_len, pos = Lyr.read_u32_le(bytes, pos)
    name = String(copy(bytes[pos:pos+name_len-1]))
    pos += name_len
    type_len, pos = Lyr.read_u32_le(bytes, pos)
    type_str = String(copy(bytes[pos:pos+type_len-1]))
    pos += type_len

    # Skip value based on type
    if type_str == "string"
        val_len, pos = Lyr.read_u32_le(bytes, pos)
        val_str = String(copy(bytes[pos:pos+val_len-1]))
        pos += val_len
        println("  $name ($type_str): $val_str")
    elseif type_str == "vec3i"
        x, pos = Lyr.read_i32_le(bytes, pos)
        y, pos = Lyr.read_i32_le(bytes, pos)
        z, pos = Lyr.read_i32_le(bytes, pos)
        println("  $name ($type_str): ($x, $y, $z)")
    else
        println("  $name ($type_str): (skipped)")
        # Skip based on type
        if type_str == "int32"
            pos += 4
        elseif type_str == "int64"
            pos += 8
        elseif type_str == "float"
            pos += 4
        elseif type_str == "bool"
            pos += 1
        end
    end
end

# Grid count
grid_count, pos = Lyr.read_u32_le(bytes, pos)
println("\nGrid count: $grid_count")

# Grid descriptor
name_len, pos = Lyr.read_u32_le(bytes, pos)
grid_name = String(copy(bytes[pos:pos+name_len-1]))
pos += name_len
println("Grid name: $grid_name")

type_len, pos = Lyr.read_u32_le(bytes, pos)
grid_type = String(copy(bytes[pos:pos+type_len-1]))
pos += type_len
println("Grid type: $grid_type")

# Instance parent
inst_len, pos = Lyr.read_u32_le(bytes, pos)
pos += inst_len

# Offsets
grid_offset, pos = Lyr.read_i64_le(bytes, pos)
block_offset, pos = Lyr.read_i64_le(bytes, pos)
eof_offset, pos = Lyr.read_i64_le(bytes, pos)
println("Grid byte offset: $grid_offset")
println("Block offset: $block_offset")
println("EOF offset: $eof_offset")

# Compression
compression, pos = Lyr.read_u32_le(bytes, pos)
println("Compression: $compression")

# Skip grid metadata
grid_meta_count, pos = Lyr.read_u32_le(bytes, pos)
for _ in 1:grid_meta_count
    k_len, pos = Lyr.read_u32_le(bytes, pos)
    pos += k_len
    t_len, pos = Lyr.read_u32_le(bytes, pos)
    type_str = String(copy(bytes[pos:pos+t_len-1]))
    pos += t_len
    if type_str == "string"
        v_len, pos = Lyr.read_u32_le(bytes, pos)
        pos += v_len
    elseif type_str == "int32" || type_str == "float"
        pos += 4
    elseif type_str == "int64"
        pos += 8
    elseif type_str == "bool"
        pos += 1
    elseif type_str == "vec3i" || type_str == "vec3s"
        pos += 12
    end
end

grid_start_pos = pos
values_start = grid_start_pos + Int(block_offset)
println("\nGrid data starts at: $grid_start_pos")
println("Values section starts at: $values_start")
println("File size: $(length(bytes))")

println("\n=== First 100 bytes at values section ===")
for i in 0:99
    if values_start + i <= length(bytes)
        print(string(bytes[values_start + i], base=16, pad=2), " ")
        if (i + 1) % 16 == 0
            println()
        end
    end
end
println()

# Interpret first byte as metadata
meta = bytes[values_start]
println("\nFirst byte (metadata?): $meta")

# If metadata is 0-6, this is the standard compressed format
if meta <= 6
    println("This looks like standard compressed format with metadata code $meta")

    # Check what follows based on metadata
    p = values_start + 1

    if meta == 2
        # One inactive value
        inact_val, p = Lyr.read_f32_le(bytes, p)
        println("Inactive value: $inact_val")
    elseif meta == 3 || meta == 4 || meta == 5
        if meta == 4
            inact_val, p = Lyr.read_f32_le(bytes, p)
            println("Inactive value: $inact_val")
        elseif meta == 5
            inact_val1, p = Lyr.read_f32_le(bytes, p)
            inact_val2, p = Lyr.read_f32_le(bytes, p)
            println("Inactive values: $inact_val1, $inact_val2")
        end
        # Selection mask (64 bytes for LeafMask)
        println("Selection mask would be at position $p")
    end

    if meta != 6
        # Chunk size (i64) should be next (after any inactive vals and selection mask)
        if meta in [3, 4, 5]
            p += 64  # skip selection mask
        end
        chunk_size, _ = Lyr.read_i64_le(bytes, p)
        println("Chunk size at pos $p: $chunk_size")
    end
else
    println("First byte $meta doesn't look like metadata (0-6)")
    println("Maybe this is raw selection mask format?")
end

end  # function main

main()
