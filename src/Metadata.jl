# Metadata.jl - VDB metadata parsing
#
# Format (same for file-level and per-grid metadata):
#   count (u32) — number of entries
#   For each entry:
#     key:   u32 size + bytes (ReadString)
#     type:  u32 size + bytes (ReadString)
#     value: type-dependent:
#       "string" → u32 size + bytes (ReadString)
#       all others → u32 size prefix + value bytes
#
# Reference: tinyvdbio.h ReadMeta (line 2520), ReadMetaBool/Float/Vec3i/Vec3d/Int64

"""
    skip_file_metadata(bytes::Vector{UInt8}, pos::Int) -> Int

Skip file-level metadata. Reads count + entries, advancing past all bytes.
Works for all VDB format versions (v220+).
"""
function skip_file_metadata(bytes::Vector{UInt8}, pos::Int)::Int
    meta_count, pos = read_u32_le(bytes, pos)

    for _ in 1:meta_count
        _, pos = read_string_with_size(bytes, pos)  # key
        _, pos = read_string_with_size(bytes, pos)  # type
        # All metadata values have a size prefix (including string, whose
        # ReadString format is u32 size + bytes — same as size prefix + data)
        value_size, pos = read_u32_le(bytes, pos)
        pos += value_size
    end

    return pos
end

"""
    read_grid_metadata(bytes::Vector{UInt8}, pos::Int) -> Tuple{Dict{String,Any}, Int}

Read per-grid metadata section. Same format as file-level metadata:
- metadata_count (u32)
- For each entry: key (u32+bytes), type (u32+bytes), value (u32 size + bytes)
"""
function read_grid_metadata(bytes::Vector{UInt8}, pos::Int)::Tuple{Dict{String,Any}, Int}
    metadata_count, pos = read_u32_le(bytes, pos)

    metadata = Dict{String,Any}()

    for _ in 1:metadata_count
        key, pos = read_string_with_size(bytes, pos)
        type_name, pos = read_string_with_size(bytes, pos)
        value_size, pos = read_u32_le(bytes, pos)

        if type_name == "string"
            GC.@preserve bytes begin
                metadata[key] = unsafe_string(pointer(bytes, pos), value_size)
            end
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
            # Unknown type — skip by value_size
            pos += value_size
            metadata[key] = nothing
        end
    end

    (metadata, pos)
end
