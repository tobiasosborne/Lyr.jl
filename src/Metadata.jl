# Metadata.jl - VDB metadata parsing

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
    skip_metadata_value_heuristic(bytes::Vector{UInt8}, pos::Int, type_name::String) -> Int

Skip a metadata value based on its type (file-level metadata without size prefix).
"""
function skip_metadata_value_heuristic(bytes::Vector{UInt8}, pos::Int, type_name::String)::Int
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
        throw(UnknownMetadataTypeError(type_name))
    end
    return pos
end

"""
    read_grid_metadata(bytes::Vector{UInt8}, pos::Int) -> Tuple{Dict{String,Any}, Int}

Read per-grid metadata section. Format:
- tree_version (u32)
- metadata_count (u32)
- For each entry: key_size, key, type_size, type, value_size, value_bytes
"""
function read_grid_metadata(bytes::Vector{UInt8}, pos::Int)::Tuple{Dict{String,Any}, Int}
    # Read tree version and metadata count
    tree_version, pos = read_u32_le(bytes, pos)
    metadata_count, pos = read_u32_le(bytes, pos)

    metadata = Dict{String,Any}()
    metadata["_tree_version"] = tree_version

    # Read metadata entries
    # Note: In some VDB versions (e.g. 220), the metadata count might exclude
    # certain entries (like "class") or be off. We continue reading as long
    # as we see valid metadata entries.
        entries_read = 0
        while entries_read < metadata_count || true
            # Stop if we've read enough AND the next bytes don't look like metadata
            if entries_read >= metadata_count
                # check heuristic
                looks_like_metadata = false
                                        peek_pos = pos
                                        # println("DEBUG: Checking extra metadata at $peek_pos")

                                        # Check for size-prefixed key
                                        if peek_pos + 4 <= length(bytes)
                                             k_size = ltoh(reinterpret(UInt32, @view bytes[peek_pos:peek_pos+3])[1])
                                             # println("DEBUG: Potential k_size=$k_size")
                                             if k_size > 0 && k_size < 256 && peek_pos + 4 + k_size + 4 <= length(bytes)
                                                 # Check key ascii
                                                 if is_printable_ascii(bytes, peek_pos + 4, Int(k_size))
                                                     # Check type size
                                                     t_pos = peek_pos + 4 + Int(k_size)
                                                     t_size = ltoh(reinterpret(UInt32, @view bytes[t_pos:t_pos+3])[1])
                                                     # println("DEBUG: Potential t_size=$t_size at $t_pos")
                                                     if t_size > 0 && t_size < 32 && t_pos + 4 + t_size <= length(bytes)
                                                         if is_printable_ascii(bytes, t_pos + 4, Int(t_size))
                                                             looks_like_metadata = true
                                                             # println("DEBUG: Size-prefixed metadata detected")
                                                         end
                                                     end
                                                 end
                                             end
                                        end

                                        # Check for non-size-prefixed key (heuristic search)
                                        if !looks_like_metadata
                                            # Try to find a key/type pattern
                                            for k_len in 1:min(32, length(bytes) - peek_pos)
                                                # Key must be ascii
                                                if !is_printable_ascii(bytes, peek_pos, k_len)
                                                    continue
                                                end

                                                # Check type size
                                                t_pos = peek_pos + k_len
                                                if t_pos + 4 <= length(bytes)
                                                    t_size = ltoh(reinterpret(UInt32, @view bytes[t_pos:t_pos+3])[1])
                                                    if t_size > 0 && t_size < 32 && t_pos + 4 + t_size <= length(bytes)
                                                         if is_printable_ascii(bytes, t_pos + 4, Int(t_size))
                                                             looks_like_metadata = true
                                                             # println("DEBUG: Non-size-prefixed metadata detected, k_len=$k_len")
                                                             break
                                                         end
                                                    end
                                                end
                                            end
                                        end

                                        if !looks_like_metadata
                                            # println("DEBUG: Stopping metadata read at $pos")
                                            break
                                        end            end

            entries_read += 1
        key_start = pos
        key = ""

        # Hybrid approach:
        # 1. Check if we have a standard size-prefixed key
        # 2. If not, use heuristic for non-prefixed key (e.g. "class" in v220)

        is_size_prefixed = false
        if pos + 4 <= length(bytes)
            potential_size = ltoh(reinterpret(UInt32, @view bytes[pos:pos+3])[1])

            # Check if size is reasonable (< 256) and positive
            if potential_size > 0 && potential_size < 256 && pos + 4 + potential_size <= length(bytes)
                # Check if the potential key bytes are all printable ASCII
                is_ascii = true
                for j in 0:potential_size-1
                    b = bytes[pos + 4 + j]
                    if !(b >= 32 && b <= 126)
                        is_ascii = false
                        break
                    end
                end

                if is_ascii
                    is_size_prefixed = true
                    key = String(bytes[pos+4:pos+4+potential_size-1])
                    pos += 4 + potential_size
                end
            end
        end

        if !is_size_prefixed
            # Fallback: heuristic for non-size-prefixed keys
            # Search for the pattern: {ascii_bytes} [type_size_u32] {type_name}
            best_key_len = 0
            for key_len in 1:min(32, length(bytes) - pos)
                test_pos = key_start + key_len

                # All key bytes must be printable ASCII
                all_ascii = true
                for j in 0:key_len-1
                    b = bytes[key_start + j]
                    if !(b >= 32 && b <= 126) || b in (0x00,)  # Exclude null, must be printable
                        all_ascii = false
                        break
                    end
                end

                if !all_ascii
                    continue
                end

                # Check if next 4 bytes form a reasonable type_size
                if test_pos + 3 <= length(bytes)
                    type_size, _ = read_u32_le(bytes, test_pos)

                    # Type size should match known type string lengths (3-25 bytes)
                    # AND the type bytes should all be ASCII
                    if type_size >= 3 && type_size <= 25 && test_pos + 4 + type_size <= length(bytes)
                        valid_type = true
                        for j in 0:type_size-1
                            b = bytes[test_pos + 4 + j]
                            if !(b >= 32 && b <= 126) || b in (0x00,)
                                valid_type = false
                                break
                            end
                        end

                        if valid_type
                            best_key_len = key_len
                            break  # Found it!
                        end
                    end
                end
            end

            if best_key_len == 0
                throw(MetadataParseError("Could not parse grid metadata key", key_start))
            end

            key = String(bytes[key_start:key_start+best_key_len-1])
            pos = key_start + best_key_len
        end

        # Read type
        type_name, pos = read_string_with_size(bytes, pos)

        # Read value size (per-grid metadata has size prefix for ALL types)
        value_size, pos = read_u32_le(bytes, pos)

        # Read value based on type
        if type_name == "string"
            metadata[key] = String(bytes[pos:pos+value_size-1])
            pos += value_size
        elseif type_name == "int32" && value_size == 4
            val, pos = read_i32_le(bytes, pos)
            metadata[key] = val
        elseif type_name == "int64" && value_size == 8
            val, pos = read_i64_le(bytes, pos)
            metadata[key] = val
        elseif type_name == "float" && value_size == 4
            val, pos = read_f32_le(bytes, pos)
            metadata[key] = val
        elseif type_name == "double" && value_size == 8
            val, pos = read_f64_le(bytes, pos)
            metadata[key] = val
        elseif type_name == "bool" && value_size == 1
            val = bytes[pos] != 0
            pos += 1
            metadata[key] = val
        elseif type_name == "vec3i" && value_size == 12
            x, pos = read_i32_le(bytes, pos)
            y, pos = read_i32_le(bytes, pos)
            z, pos = read_i32_le(bytes, pos)
            metadata[key] = (x, y, z)
        elseif type_name in ("vec3f", "vec3s") && value_size == 12
            x, pos = read_f32_le(bytes, pos)
            y, pos = read_f32_le(bytes, pos)
            z, pos = read_f32_le(bytes, pos)
            metadata[key] = (x, y, z)
        elseif type_name == "vec3d" && value_size == 24
            x, pos = read_f64_le(bytes, pos)
            y, pos = read_f64_le(bytes, pos)
            z, pos = read_f64_le(bytes, pos)
            metadata[key] = (x, y, z)
        else
            # Unknown type, skip by value_size
            pos += value_size
            metadata[key] = nothing
        end
    end

    (metadata, pos)
end

"""
    read_file_metadata_v220(bytes::Vector{UInt8}, pos::Int) -> Int

Read file-level metadata for VDB format version 220-221.
These versions have a count prefix and size-prefixed values.
"""
function read_file_metadata_v220(bytes::Vector{UInt8}, pos::Int)::Int
    # Read metadata count
    meta_count, pos = read_u32_le(bytes, pos)

    for _ in 1:meta_count
        # Read key
        _, pos = read_string_with_size(bytes, pos)
        # Read type
        type_name, pos = read_string_with_size(bytes, pos)
        # Read value (with size prefix for all types)
        value_size, pos = read_u32_le(bytes, pos)
        pos += value_size
    end

    return pos
end
