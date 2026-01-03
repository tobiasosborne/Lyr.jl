using VDB

function debug_bunny()
    bytes = read("test/fixtures/samples/bunny_cloud.vdb")

    function read_u32_le(b, p)
        reinterpret(UInt32, b[p:p+3])[1], p+4
    end

    function read_u8(b, p)
        b[p], p+1
    end

    function read_i64_le(b, p)
        reinterpret(Int64, b[p:p+7])[1], p+8
    end

    p = 1
    magic, p = read_u32_le(bytes, p)
    padding, p = read_u32_le(bytes, p)
    version, p = read_u32_le(bytes, p)
    major, p = read_u32_le(bytes, p)
    minor, p = read_u32_le(bytes, p)

    println("Version: $version, Library: $major.$minor")

    if version >= 212
        offsets_byte, p = read_u8(bytes, p)
        println("Has offsets: $(offsets_byte != 0)")
    end

    if version >= 220 && version < 222
        hf_byte, p = read_u8(bytes, p)
        println("Half-float flag: $hf_byte")
    end

    uuid = String(bytes[p:p+35])
    p += 36
    println("UUID: $uuid")

    if version >= 222
        comp, p = read_u32_le(bytes, p)
        println("Compression: $comp")
    end

    println("Position after header: $p")

    # File metadata (v220+)
    if version >= 220
        meta_count, p = read_u32_le(bytes, p)
        println("File metadata count: $meta_count, pos=$p")
        
        for i in 1:meta_count
            key_size, p = read_u32_le(bytes, p)
            println("  Entry $i: key_size=$key_size at pos=$p")
            if key_size > 0 && key_size < 1000
                key = String(bytes[p:p+key_size-1])
                p += key_size
                println("    key: $key")
                
                type_size, p = read_u32_le(bytes, p)
                type_str = String(bytes[p:p+type_size-1])
                p += type_size
                println("    type: $type_str")
                
                value_size, p = read_u32_le(bytes, p)
                println("    value_size: $value_size")
                p += value_size
            end
        end
    end

    println("\nAfter file metadata: pos=$p")
    
    # Now comes grid count
    grid_count, p = read_u32_le(bytes, p)
    println("Grid count: $grid_count, pos=$p")
    
    # Grid descriptors start here
    has_offsets = version >= 212  # from earlier
    println("Grid descriptors start at pos=$p, has_offsets=$has_offsets")
    for i in 1:grid_count
        # name (string with size)
        name_size, p = read_u32_le(bytes, p)
        println("  Grid $i: name_size=$name_size at pos=$p")
        if name_size > 0 && name_size < 1000
            name = String(bytes[p:p+name_size-1])
            p += name_size
            println("    name: $name")
            
            # grid type (string with size)
            type_size, p = read_u32_le(bytes, p)
            grid_type = String(bytes[p:p+type_size-1])
            p += type_size
            println("    grid_type: $grid_type")
            
            # instance_parent (string with size)
            parent_size, p = read_u32_le(bytes, p)
            if parent_size > 0
                parent = String(bytes[p:p+parent_size-1])
                p += parent_size
                println("    instance_parent: $parent")
            else
                p += parent_size
            end
            
            # Offsets if has_grid_offsets
            if has_offsets
                byte_offset, p = read_i64_le(bytes, p)
                block_offset, p = read_i64_le(bytes, p)
                end_offset, p = read_i64_le(bytes, p)
                println("    offsets: byte=$byte_offset, block=$block_offset, end=$end_offset")
            end
        end
    end
    
    println("\nPosition after descriptors: $p")
    println("Next bytes (hex): $(bytes[p:min(p+30, end)])")
end

debug_bunny()
