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
- `grids::Vector` - Parsed grids (Grid{Float32}, Grid{Float64}, or Grid{NTuple{3, Float32}})
"""
struct VDBFile
    header::VDBHeader
    grids::Vector{Union{Grid{Float32}, Grid{Float64}, Grid{NTuple{3, Float32}}}}
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
    # For older versions, default to ZipCodec (standard OpenVDB behavior)
    compression = if format_version >= 222
        compression_u32, pos = read_u32_le(bytes, pos)
        if compression_u32 == 0
            NoCompression()
        elseif compression_u32 == 1
            ZipCodec()
        elseif compression_u32 == 2
            BloscCodec()
        else
            NoCompression()  # Unknown, assume none
        end
    else
        ZipCodec()
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
        error("Unknown metadata type: $type_name")
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
                error("Could not parse grid metadata key at position $key_start")
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

"""
    parse_vdb(bytes::Vector{UInt8}) -> VDBFile

Parse a complete VDB file from bytes.
"""
function parse_vdb(bytes::Vector{UInt8})::VDBFile
    pos = 1

    # Read header
    header, pos = read_header(bytes, pos)

    # Read file-level metadata
    if header.format_version >= 222
        # Version 222+: No count prefix, use heuristic detection
        while is_metadata_entry(bytes, pos)
            _, pos = read_string_with_size(bytes, pos)  # key
            type_name, pos = read_string_with_size(bytes, pos)  # type
            pos = skip_metadata_value_heuristic(bytes, pos, type_name)  # value
        end
    else
        # Version 220-221: Has count prefix and size-prefixed values
        pos = read_file_metadata_v220(bytes, pos)
    end

    # Read grid count
    grid_count, pos = read_u32_le(bytes, pos)

    # Read grid descriptors
    descriptors = Vector{GridDescriptor}(undef, grid_count)
    for i in 1:grid_count
        descriptors[i], pos = read_grid_descriptor(bytes, pos, header.has_grid_offsets)
    end

    # Parse each grid - collect into temporary vector then filter
    grids_temp = Union{Grid{Float32}, Grid{Float64}, Grid{NTuple{3, Float32}}}[]
    
    for i in 1:grid_count
        desc = descriptors[i]

        # Skip instanced grids for now
        if !isempty(desc.instance_parent)
            continue
        end

        # Seek to grid data if byte offsets are present
        if header.has_grid_offsets && desc.byte_offset > 0
            pos = Int(desc.byte_offset) + 1  # byte_offset is 0-indexed, pos is 1-indexed
        end

        # Determine value type
        T = parse_value_type(desc.grid_type)

        # Read per-grid metadata (includes "class" entry)
        grid_metadata, pos = read_grid_metadata(bytes, pos)

        # Extract grid class from metadata
        grid_class_str = get(grid_metadata, "class", "unknown")
        grid_class = parse_grid_class(grid_class_str)

        # Grid start position (1-indexed) for calculating values section
        grid_start_pos = if header.has_grid_offsets && desc.byte_offset > 0
            Int(desc.byte_offset) + 1
        else
            pos  # Use current position if no offsets
        end

        # Parse the grid
        if T == Float32
            grid, pos = read_grid(Float32, bytes, pos, header.compression, desc.name, grid_class, header.format_version, grid_start_pos, desc.block_offset)
            push!(grids_temp, grid)
        elseif T == Float64
            grid, pos = read_grid(Float64, bytes, pos, header.compression, desc.name, grid_class, header.format_version, grid_start_pos, desc.block_offset)
            push!(grids_temp, grid)
        elseif T == NTuple{3, Float32}
            grid, pos = read_grid(NTuple{3, Float32}, bytes, pos, header.compression, desc.name, grid_class, header.format_version, grid_start_pos, desc.block_offset)
            push!(grids_temp, grid)
        end
    end

    VDBFile(header, grids_temp)
end

"""
    parse_vdb(path::String) -> VDBFile

Parse a VDB file from a file path.
"""
function parse_vdb(path::String)::VDBFile
    bytes = read(path)
    parse_vdb(bytes)
end
