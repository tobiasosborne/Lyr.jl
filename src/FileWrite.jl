# FileWrite.jl — VDB file writing (v224 format, v222+ leaf values)
#
# Writes complete VDB files that can be round-tripped through parse_vdb.
# Uses NoCompression and COMPRESS_ACTIVE_MASK for simplicity.
#
# Format written:
#   Header → file metadata → grid_count → [grid_descriptor + grid_data]...
#
# Grid data format:
#   per-grid compression flags → grid metadata → transform → buffer_count →
#   background → tile_count + child_count → tiles → [topology] → [values]
#
# Topology (per I2 child):
#   I2 child_mask → I2 value_mask → I2 ReadMaskValues →
#   [I1 child_mask → I1 value_mask → I1 ReadMaskValues → [leaf value_mask]...]...
#
# Values (per leaf in same order):
#   [value_mask (64B)] → [metadata 0x00] → [raw active values]
#
# Reference: tinyvdbio.h, InternalNode.h, LeafNode.h, RootNode.h

# =============================================================================
# Header writing
# =============================================================================

"""
    write_header!(io::IO, header::VDBHeader) -> Nothing

Write a VDB file header (v222+ format).

Header layout:
- Magic (4 bytes LE u32) + padding (4 bytes)
- Format version (4 bytes LE u32)
- Library major (4 bytes LE u32)
- Library minor (4 bytes LE u32)
- Has grid offsets (1 byte) — if format_version >= 212
- UUID (36 bytes ASCII)
"""
function write_header!(io::IO, header::VDBHeader)::Nothing
    # Magic number
    write_u32_le!(io, UInt32(VDB_MAGIC))
    # Padding (4 bytes of zeros)
    write_u32_le!(io, UInt32(0))

    # Format version
    write_u32_le!(io, header.format_version)
    # Library version
    write_u32_le!(io, header.library_major)
    write_u32_le!(io, header.library_minor)

    # Has grid offsets flag (only for version >= 212)
    if header.format_version >= 212
        write_u8!(io, header.has_grid_offsets ? UInt8(0x01) : UInt8(0x00))
    end

    # UUID (36 bytes ASCII, no null terminator)
    uuid_bytes = Vector{UInt8}(header.uuid)
    @assert length(uuid_bytes) == 36 "UUID must be exactly 36 bytes"
    write_bytes!(io, uuid_bytes)

    nothing
end

# =============================================================================
# Metadata writing
# =============================================================================

"""
    write_metadata!(io::IO, metadata::Dict{String,Any}) -> Nothing

Write a metadata section (file-level or per-grid).

Format:
- count (u32)
- For each entry: key (string_with_size), type (string_with_size), value (u32 size + bytes)
"""
function write_metadata!(io::IO, metadata::Dict{String,Any})::Nothing
    write_u32_le!(io, UInt32(length(metadata)))

    for (key, val) in metadata
        write_string_with_size!(io, key)

        if val isa String
            write_string_with_size!(io, "string")
            data = Vector{UInt8}(val)
            write_u32_le!(io, UInt32(length(data)))
            write_bytes!(io, data)
        elseif val isa Int32
            write_string_with_size!(io, "int32")
            write_u32_le!(io, UInt32(4))
            write_i32_le!(io, val)
        elseif val isa Int64
            write_string_with_size!(io, "int64")
            write_u32_le!(io, UInt32(8))
            write_i64_le!(io, val)
        elseif val isa Float32
            write_string_with_size!(io, "float")
            write_u32_le!(io, UInt32(4))
            write_f32_le!(io, val)
        elseif val isa Float64
            write_string_with_size!(io, "double")
            write_u32_le!(io, UInt32(8))
            write_f64_le!(io, val)
        elseif val isa Bool
            write_string_with_size!(io, "bool")
            write_u32_le!(io, UInt32(1))
            write_u8!(io, val ? UInt8(0x01) : UInt8(0x00))
        elseif val isa NTuple{3, Int32}
            write_string_with_size!(io, "vec3i")
            write_u32_le!(io, UInt32(12))
            write_tile_value!(io, val)
        elseif val isa NTuple{3, Float32}
            write_string_with_size!(io, "vec3s")
            write_u32_le!(io, UInt32(12))
            write_tile_value!(io, val)
        elseif val isa NTuple{3, Float64}
            write_string_with_size!(io, "vec3d")
            write_u32_le!(io, UInt32(24))
            write_tile_value!(io, val)
        else
            # Skip unknown types — they were stored as `nothing` during read
        end
    end

    nothing
end

# =============================================================================
# Mask writing
# =============================================================================

"""
    write_mask!(io::IO, mask::Mask{N,W}) -> Nothing

Write a bitmask as consecutive 64-bit words in little-endian format.
"""
function write_mask!(io::IO, mask::Mask{N,W})::Nothing where {N,W}
    for i in 1:W
        write_u64_le!(io, mask.words[i])
    end
    nothing
end

# =============================================================================
# Transform writing
# =============================================================================

"""Write 3 consecutive Float64 values (a Vec3d)."""
@inline function _write_vec3d!(io::IO, x::Float64, y::Float64, z::Float64)
    write_f64_le!(io, x); write_f64_le!(io, y); write_f64_le!(io, z)
end

"""Write the 5 Vec3d fields (15 doubles) for ScaleMap / UniformScaleMap."""
function _write_scale_map_data!(io::IO, sx::Float64, sy::Float64, sz::Float64)
    _write_vec3d!(io, sx, sy, sz)                                          # Scale
    _write_vec3d!(io, 1.0/sx, 1.0/sy, 1.0/sz)                            # InvScale
    _write_vec3d!(io, 1.0/(sx*sx), 1.0/(sy*sy), 1.0/(sz*sz))             # InvScaleSqr
    _write_vec3d!(io, sx, sy, sz)                                          # VoxelSize
    _write_vec3d!(io, sx, sy, sz)                                          # VoxelSize
end

"""Write Translation(3) + 5 Vec3d scale fields (18 doubles) for ScaleTranslateMap."""
function _write_scale_translate_data!(io::IO, tx::Float64, ty::Float64, tz::Float64,
                                       sx::Float64, sy::Float64, sz::Float64)
    _write_vec3d!(io, tx, ty, tz)                                          # Translation
    _write_vec3d!(io, sx, sy, sz)                                          # Scale
    _write_vec3d!(io, 1.0/sx, 1.0/sy, 1.0/sz)                            # InvScale
    _write_vec3d!(io, 1.0/(sx*sx), 1.0/(sy*sy), 1.0/(sz*sz))             # InvScaleSqr
    _write_vec3d!(io, 1.0/(2.0*sx), 1.0/(2.0*sy), 1.0/(2.0*sz))         # InvTwiceScale
    _write_vec3d!(io, sx, sy, sz)                                          # VoxelSize
end

"""
    write_transform!(io::IO, transform::UniformScaleTransform) -> Nothing

Write a uniform scale transform as a UniformScaleMap.
"""
function write_transform!(io::IO, transform::UniformScaleTransform)::Nothing
    write_string_with_size!(io, "UniformScaleMap")
    s = transform.scale
    _write_scale_map_data!(io, s, s, s)
    nothing
end

"""
    write_transform!(io::IO, transform::LinearTransform) -> Nothing

Write a linear transform as a ScaleMap, ScaleTranslateMap, or UniformScaleTranslateMap.
Only diagonal matrices are supported (no rotation).
"""
function write_transform!(io::IO, transform::LinearTransform)::Nothing
    m = transform.mat
    has_translation = any(!iszero, transform.trans)
    is_diagonal = m[1,2] == 0.0 && m[1,3] == 0.0 &&
                  m[2,1] == 0.0 && m[2,3] == 0.0 &&
                  m[3,1] == 0.0 && m[3,2] == 0.0

    is_diagonal || throw(ArgumentError("write_transform!: non-diagonal LinearTransform not yet supported — only scale/translate maps"))

    sx, sy, sz = m[1,1], m[2,2], m[3,3]

    if has_translation
        is_uniform = sx == sy == sz
        write_string_with_size!(io, is_uniform ? "UniformScaleTranslateMap" : "ScaleTranslateMap")
        _write_scale_translate_data!(io, transform.trans[1], transform.trans[2], transform.trans[3], sx, sy, sz)
    else
        write_string_with_size!(io, "ScaleMap")
        _write_scale_map_data!(io, sx, sy, sz)
    end

    nothing
end

# =============================================================================
# Grid type string construction
# =============================================================================

"""Return the VDB grid type string for a given Julia value type."""
grid_type_string(::Type{Float32})            = "Tree_float_5_4_3"
grid_type_string(::Type{Float64})            = "Tree_double_5_4_3"
grid_type_string(::Type{NTuple{3, Float32}}) = "Tree_vec3s_5_4_3"
grid_type_string(::Type{NTuple{3, Float64}}) = "Tree_vec3d_5_4_3"
grid_type_string(::Type{Int32})              = "Tree_int32_5_4_3"
grid_type_string(::Type{Int64})              = "Tree_int64_5_4_3"
grid_type_string(::Type{Bool})               = "Tree_bool_5_4_3"

# 2-arg overloads for half-precision suffix
grid_type_string(::Type{Float32}, half::Bool) = half ? "Tree_float_5_4_3_HalfFloat" : "Tree_float_5_4_3"
grid_type_string(::Type{Float64}, half::Bool) = half ? "Tree_double_5_4_3_HalfFloat" : "Tree_double_5_4_3"

"""
    grid_class_string(gc::GridClass) -> String

Return the metadata class string for a grid class enum.
"""
function grid_class_string(gc::GridClass)::String
    gc == GRID_LEVEL_SET    ? "level set" :
    gc == GRID_FOG_VOLUME   ? "fog volume" :
    gc == GRID_STAGGERED    ? "staggered" :
    "unknown"
end

# =============================================================================
# ReadMaskValues writing (v222+ internal node value format)
# =============================================================================

"""
    write_mask_values!(io::IO, ::Type{T}, values::Vector{T}, mask::Mask{N,W}, background::T) -> Nothing

Write node values in ReadMaskValues format (v222+). This writes the metadata byte,
optional inactive values, optional selection mask, and compressed value data.

Uses the simplest encoding: metadata=0 (NO_MASK_OR_INACTIVE_VALS) and stores
only active values (mask_compressed=true).

For internal nodes, `values` is a dense vector of N values (one per slot).
We write only the active values (those where mask is on).
"""
function write_mask_values!(io::IO, ::Type{T}, values::Vector{T}, mask::Mask{N,W}, background::T; half_precision::Bool=false) where {T,N,W}
    # Metadata byte: 0 = NO_MASK_OR_INACTIVE_VALS
    # This means: inactive values get background, no selection mask needed
    write_u8!(io, UInt8(0x00))

    # Write compressed data: with mask_compressed=true, only active values
    active_count = count_on(mask)
    value_size = sizeof(T)
    expected_size = active_count * value_size

    # Collect active values
    buf = IOBuffer()
    for idx in on_indices(mask)
        if half_precision
            write_tile_value!(buf, Float16(values[idx + 1]))  # 1-indexed array
        else
            write_tile_value!(buf, values[idx + 1])  # 1-indexed array
        end
    end
    data = take!(buf)

    # For NoCompression codec: write raw data (no size prefix)
    write_bytes!(io, data)

    nothing
end

# =============================================================================
# Tree writing (v222+ format: topology then values)
# =============================================================================

"""
    write_tree!(io::IO, tree::RootNode{T}, codec::Codec=NoCompression()) -> Nothing

Write a VDB tree in v222+ format (separate topology and values sections).

Phase 1 (topology): root tiles, then for each root child:
  I2 masks → I2 ReadMaskValues → [I1 masks → I1 ReadMaskValues → [leaf mask]...]...

Phase 2 (values): for each leaf in same order:
  value_mask (64B) → metadata(1B) → active values (optionally compressed)
"""
function write_tree!(io::IO, tree::RootNode{T}, codec::Codec=NoCompression(); half_precision::Bool=false) where T
    # Separate root table into tiles and I2 children (sorted by origin for determinism)
    tiles = Tuple{Coord, Tile{T}}[]
    children = Tuple{Coord, InternalNode2{T}}[]

    for (origin, entry) in tree.table
        if entry isa Tile{T}
            push!(tiles, (origin, entry))
        else
            push!(children, (origin, entry::InternalNode2{T}))
        end
    end

    # Sort for deterministic output
    sort!(tiles; by = t -> (t[1].x, t[1].y, t[1].z))
    sort!(children; by = c -> (c[1].x, c[1].y, c[1].z))

    # Write tile_count and child_count
    write_u32_le!(io, UInt32(length(tiles)))
    write_u32_le!(io, UInt32(length(children)))

    # Write root tiles: origin (3 x Int32) + value + active_byte
    for (origin, tile) in tiles
        write_i32_le!(io, origin.x)
        write_i32_le!(io, origin.y)
        write_i32_le!(io, origin.z)
        # Root tile values always written at full precision (reader expects sizeof(T))
        write_tile_value!(io, tile.value)
        write_u8!(io, tile.active ? UInt8(0x01) : UInt8(0x00))
    end

    # Collect all leaves in order for Phase 2
    all_leaves = LeafNode{T}[]

    # Phase 1: Write topology for each I2 child
    for (origin, i2_node) in children
        # Write I2 origin
        write_i32_le!(io, origin.x)
        write_i32_le!(io, origin.y)
        write_i32_le!(io, origin.z)

        # Write I2 topology (with codec for internal node value compression)
        _write_i2_topology!(io, i2_node, tree.background, all_leaves, codec; half_precision=half_precision)
    end

    # Phase 2: Write leaf values (with optional compression)
    for leaf in all_leaves
        _write_leaf_values!(io, leaf, tree.background, codec; half_precision=half_precision)
    end

    nothing
end

"""Write masks + tile values for an internal node (shared by I2 and I1)."""
function _write_node_masks_and_tiles!(io::IO, node, ::Type{T}, codec::Codec=NoCompression(); half_precision::Bool=false) where T
    write_mask!(io, node.child_mask)
    write_mask!(io, node.value_mask)
    # metadata=0 (NO_MASK_OR_INACTIVE_VALS), then active tile values
    # The tile data goes through compression just like leaf data
    write_u8!(io, UInt8(0x00))

    # Collect tile data into raw bytes
    buf = IOBuffer()
    for tile in node.tiles
        if half_precision
            write_tile_value!(buf, Float16(tile.value))
        else
            write_tile_value!(buf, tile.value)
        end
    end
    raw_data = take!(buf)

    if codec isa NoCompression
        # No compression: write raw data directly (no size prefix)
        write_bytes!(io, raw_data)
    else
        if isempty(raw_data)
            # Empty chunk: size prefix = 0
            write_i64_le!(io, Int64(0))
        else
            compressed_data = compress(codec, raw_data)
            if length(compressed_data) >= length(raw_data)
                # Compression didn't help: negative size prefix + raw data
                write_i64_le!(io, Int64(-length(raw_data)))
                write_bytes!(io, raw_data)
            else
                # Compression succeeded: positive size prefix + compressed data
                write_i64_le!(io, Int64(length(compressed_data)))
                write_bytes!(io, compressed_data)
            end
        end
    end
end

"Write I2 topology: masks, tile values, then recurse into I1 children."
function _write_i2_topology!(io::IO, i2::InternalNode2{T}, background::T, all_leaves::Vector{LeafNode{T}}, codec::Codec=NoCompression(); half_precision::Bool=false) where T
    _write_node_masks_and_tiles!(io, i2, T, codec; half_precision=half_precision)
    for child in i2.children
        _write_i1_topology!(io, child, background, all_leaves, codec; half_precision=half_precision)
    end
    nothing
end

"Write I1 topology: masks, tile values, then leaf value masks."
function _write_i1_topology!(io::IO, i1::InternalNode1{T}, background::T, all_leaves::Vector{LeafNode{T}}, codec::Codec=NoCompression(); half_precision::Bool=false) where T
    _write_node_masks_and_tiles!(io, i1, T, codec; half_precision=half_precision)
    for leaf in i1.children
        write_mask!(io, leaf.value_mask)
        push!(all_leaves, leaf)
    end
    nothing
end

"""
    _write_leaf_values!(io, leaf::LeafNode{T}, background::T, codec::Codec=NoCompression()) -> Nothing

Write leaf values in v222+ format:
1. Value mask (64 bytes) — re-emitted in readBuffers
2. Metadata byte (1 byte) — 0x00 = NO_MASK_OR_INACTIVE_VALS
3. Active values, optionally compressed with codec

For NoCompression: raw active values (no size prefix).
For Zip/Blosc: Int64 size prefix + compressed data. If compressed size >= uncompressed,
writes negative size prefix (-uncompressed_size) + raw data instead.
"""
function _write_leaf_values!(io::IO, leaf::LeafNode{T}, background::T, codec::Codec=NoCompression(); half_precision::Bool=false) where T
    # Re-emit value mask (64 bytes = 8 UInt64 words)
    write_mask!(io, leaf.value_mask)

    # Metadata byte: 0 = NO_MASK_OR_INACTIVE_VALS
    write_u8!(io, UInt8(0x00))

    # Collect active values into a raw byte buffer
    buf = IOBuffer()
    for idx in on_indices(leaf.value_mask)
        if half_precision
            write_tile_value!(buf, Float16(leaf.values[idx + 1]))  # 1-indexed
        else
            write_tile_value!(buf, leaf.values[idx + 1])  # 1-indexed
        end
    end
    raw_data = take!(buf)

    if codec isa NoCompression
        # No compression: write raw data directly (no size prefix)
        write_bytes!(io, raw_data)
    else
        # Compress the raw data
        compressed_data = compress(codec, raw_data)

        if isempty(raw_data)
            # Empty chunk: size prefix = 0
            write_i64_le!(io, Int64(0))
        elseif length(compressed_data) >= length(raw_data)
            # Compression didn't help: write negative size prefix + raw data
            write_i64_le!(io, Int64(-length(raw_data)))
            write_bytes!(io, raw_data)
        else
            # Compression succeeded: write positive size prefix + compressed data
            write_i64_le!(io, Int64(length(compressed_data)))
            write_bytes!(io, compressed_data)
        end
    end

    nothing
end

# =============================================================================
# Grid descriptor writing
# =============================================================================

"""
    write_grid_descriptor!(io::IO, desc::GridDescriptor, has_offsets::Bool) -> Nothing

Write a grid descriptor.
"""
function write_grid_descriptor!(io::IO, desc::GridDescriptor, has_offsets::Bool)::Nothing
    write_string_with_size!(io, desc.name)
    write_string_with_size!(io, desc.grid_type)
    write_string_with_size!(io, desc.instance_parent)

    if has_offsets
        write_i64_le!(io, desc.byte_offset)
        write_i64_le!(io, desc.block_offset)
        write_i64_le!(io, desc.end_offset)
    end

    nothing
end

# =============================================================================
# Entry points
# =============================================================================

"""
    write_vdb(path::String, grid::Grid{T}; codec::Codec=NoCompression(), half_precision::Bool=false) -> Nothing

Write a single grid to a VDB file.

Creates a v224 format file with:
- Specified compression codec (default: NoCompression)
- COMPRESS_ACTIVE_MASK enabled (sparse active value storage)
- Standard grid metadata (class)

When `half_precision=true`, Float32/Float64 values are converted to Float16 during writing.
The grid type string is suffixed with `_HalfFloat` so readers can detect the encoding.
"""
function write_vdb(path::String, grid::Grid{T}; codec::Codec=NoCompression(), half_precision::Bool=false)::Nothing where T
    header = VDBHeader(
        UInt32(224),            # format_version (current)
        UInt32(11),             # library_major
        UInt32(0),              # library_minor
        true,                   # has_grid_offsets
        codec,                  # compression codec
        true,                   # active_mask_compression
        "00000000-0000-0000-0000-000000000000"  # UUID
    )

    vdb = VDBFile(header, [grid])
    write_vdb(path, vdb; half_precision=half_precision)
end

"""
    write_vdb(path::String, vdb::VDBFile; half_precision::Bool=false) -> Nothing

Write a complete VDB file.

Strategy for grid offsets:
1. Write header + file metadata + grid count
2. For each grid: write descriptor with placeholder offsets, then grid data
3. Seek back to patch the offsets in each grid descriptor
"""
function write_vdb(path::String, vdb::VDBFile; half_precision::Bool=false)::Nothing
    open(path, "w") do io
        _write_vdb_to_io(io, vdb; half_precision=half_precision)
    end
    nothing
end

"""
    write_vdb_to_buffer(vdb::VDBFile; half_precision::Bool=false) -> Vector{UInt8}

Write a complete VDB file to an in-memory buffer. Useful for testing.
"""
function write_vdb_to_buffer(vdb::VDBFile; half_precision::Bool=false)::Vector{UInt8}
    io = IOBuffer()
    _write_vdb_to_io(io, vdb; half_precision=half_precision)
    take!(io)
end

"""
    write_vdb_to_buffer(grid::Grid{T}; codec::Codec=NoCompression(), half_precision::Bool=false) -> Vector{UInt8}

Write a single grid to an in-memory buffer.
"""
function write_vdb_to_buffer(grid::Grid{T}; codec::Codec=NoCompression(), half_precision::Bool=false)::Vector{UInt8} where T
    header = VDBHeader(
        UInt32(224),
        UInt32(11),
        UInt32(0),
        true,
        codec,
        true,
        "00000000-0000-0000-0000-000000000000"
    )
    write_vdb_to_buffer(VDBFile(header, [grid]); half_precision=half_precision)
end

"""
    _write_vdb_to_io(io::IO, vdb::VDBFile) -> Nothing

Internal: write a complete VDB file to any IO stream.
"""
function _write_vdb_to_io(io::IO, vdb::VDBFile; half_precision::Bool=false)::Nothing
    # Write header
    write_header!(io, vdb.header)

    # Write empty file-level metadata
    write_metadata!(io, Dict{String,Any}())

    # Write grid count
    write_u32_le!(io, UInt32(length(vdb.grids)))

    # Write each grid
    for grid in vdb.grids
        _write_grid(io, grid, vdb.header; half_precision=half_precision)
    end

    nothing
end

"""
    _write_grid(io::IO, grid::Grid{T}, header::VDBHeader) -> Nothing

Write a single grid: descriptor (with offset patching) + grid data.
"""
function _write_grid(io::IO, grid::Grid{T}, header::VDBHeader; half_precision::Bool=false) where T
    # Build grid descriptor with placeholder offsets
    grid_type = half_precision ? grid_type_string(T, true) : grid_type_string(T)

    # Record position of the descriptor's offset fields for patching
    # First write the name, grid_type, instance_parent strings
    desc_start = position(io)
    write_string_with_size!(io, grid.name)
    write_string_with_size!(io, grid_type)
    write_string_with_size!(io, "")  # instance_parent (empty)

    # Record position where offsets will be written, then write placeholders
    offsets_pos = position(io)
    write_i64_le!(io, Int64(0))  # byte_offset placeholder
    write_i64_le!(io, Int64(0))  # block_offset placeholder
    write_i64_le!(io, Int64(0))  # end_offset placeholder

    # Grid data starts here — record byte_offset (0-indexed file position)
    byte_offset = position(io)

    # For v222+: write per-grid compression flags
    # Flags: 0x2 = COMPRESS_ACTIVE_MASK, 0x1 = ZIP, 0x4 = BLOSC
    if header.format_version >= 222
        compression_flags = VDB_COMPRESS_ACTIVE_MASK  # Always set
        codec = header.compression
        if codec isa ZipCodec
            compression_flags |= VDB_COMPRESS_ZIP
        elseif codec isa BloscCodec
            compression_flags |= VDB_COMPRESS_BLOSC
        end
        write_u32_le!(io, compression_flags)
    end

    # Write per-grid metadata
    grid_meta = Dict{String,Any}(
        "class" => grid_class_string(grid.grid_class)
    )
    write_metadata!(io, grid_meta)

    # Write transform
    write_transform!(io, grid.transform)

    # Write buffer count (always 1 for standard trees)
    write_u32_le!(io, UInt32(1))

    # Write background value (always full precision — reader expects sizeof(T) bytes here)
    write_tile_value!(io, grid.tree.background)

    # block_offset marks start of the tree data (topology + values)
    block_offset = position(io)

    # Write tree (with codec for leaf value compression)
    codec_for_tree = header.format_version >= 222 ? header.compression : NoCompression()
    write_tree!(io, grid.tree, codec_for_tree; half_precision=half_precision)

    # end_offset marks end of grid data (0-indexed)
    end_offset = position(io)

    # Patch offsets: seek back and write actual values
    # Offsets in VDB are 0-indexed file positions
    seek(io, offsets_pos)
    write_i64_le!(io, Int64(byte_offset))
    write_i64_le!(io, Int64(block_offset))
    write_i64_le!(io, Int64(end_offset))

    # Seek back to end for next grid
    seek(io, end_offset)

    nothing
end
