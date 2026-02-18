# FileWrite.jl - VDB file writing (v224 format, v222+ leaf values)
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
            write_i32_le!(io, val[1])
            write_i32_le!(io, val[2])
            write_i32_le!(io, val[3])
        elseif val isa NTuple{3, Float32}
            write_string_with_size!(io, "vec3s")
            write_u32_le!(io, UInt32(12))
            write_f32_le!(io, val[1])
            write_f32_le!(io, val[2])
            write_f32_le!(io, val[3])
        elseif val isa NTuple{3, Float64}
            write_string_with_size!(io, "vec3d")
            write_u32_le!(io, UInt32(24))
            write_f64_le!(io, val[1])
            write_f64_le!(io, val[2])
            write_f64_le!(io, val[3])
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

"""
    write_transform!(io::IO, transform::AbstractTransform) -> Nothing

Write a transform section. Writes the type string followed by format-specific data.
"""
function write_transform!(io::IO, transform::UniformScaleTransform)::Nothing
    write_string_with_size!(io, "UniformScaleMap")

    s = transform.scale
    inv_s = 1.0 / s
    inv_s2 = inv_s * inv_s

    # UniformScaleMap: 5 Vec3d = 15 doubles
    # scale (3), voxelSize (3), scaleInv (3), scaleInvSqr (3), voxelSize (3)
    for _ in 1:3; write_f64_le!(io, s); end        # scale
    for _ in 1:3; write_f64_le!(io, inv_s); end     # scaleInv
    for _ in 1:3; write_f64_le!(io, inv_s2); end    # scaleInvSqr
    for _ in 1:3; write_f64_le!(io, s); end          # voxelSize (same as scale)
    for _ in 1:3; write_f64_le!(io, s); end          # voxelSize (same as scale)

    nothing
end

function write_transform!(io::IO, transform::LinearTransform)::Nothing
    # Determine if this is a ScaleTranslateMap or a generic map
    m = transform.mat
    has_translation = any(x -> x != 0.0, transform.trans)
    is_diagonal = m[1,2] == 0.0 && m[1,3] == 0.0 &&
                  m[2,1] == 0.0 && m[2,3] == 0.0 &&
                  m[3,1] == 0.0 && m[3,2] == 0.0

    if is_diagonal && m[1,1] == m[2,2] == m[3,3] && has_translation
        # UniformScaleTranslateMap
        write_string_with_size!(io, "UniformScaleTranslateMap")

        tx, ty, tz = transform.trans[1], transform.trans[2], transform.trans[3]
        sx, sy, sz = m[1,1], m[2,2], m[3,3]

        # Translation (3 doubles)
        write_f64_le!(io, tx)
        write_f64_le!(io, ty)
        write_f64_le!(io, tz)
        # Scale (3 doubles)
        write_f64_le!(io, sx)
        write_f64_le!(io, sy)
        write_f64_le!(io, sz)
        # InvScale (3)
        write_f64_le!(io, 1.0 / sx)
        write_f64_le!(io, 1.0 / sy)
        write_f64_le!(io, 1.0 / sz)
        # InvScaleSqr (3)
        write_f64_le!(io, 1.0 / (sx * sx))
        write_f64_le!(io, 1.0 / (sy * sy))
        write_f64_le!(io, 1.0 / (sz * sz))
        # InvTwiceScale (3)
        write_f64_le!(io, 1.0 / (2.0 * sx))
        write_f64_le!(io, 1.0 / (2.0 * sy))
        write_f64_le!(io, 1.0 / (2.0 * sz))
        # VoxelSize (3)
        write_f64_le!(io, sx)
        write_f64_le!(io, sy)
        write_f64_le!(io, sz)
    elseif is_diagonal && has_translation
        # ScaleTranslateMap
        write_string_with_size!(io, "ScaleTranslateMap")

        tx, ty, tz = transform.trans[1], transform.trans[2], transform.trans[3]
        sx, sy, sz = m[1,1], m[2,2], m[3,3]

        # Translation (3)
        write_f64_le!(io, tx)
        write_f64_le!(io, ty)
        write_f64_le!(io, tz)
        # Scale (3)
        write_f64_le!(io, sx)
        write_f64_le!(io, sy)
        write_f64_le!(io, sz)
        # InvScale (3)
        write_f64_le!(io, 1.0 / sx)
        write_f64_le!(io, 1.0 / sy)
        write_f64_le!(io, 1.0 / sz)
        # InvScaleSqr (3)
        write_f64_le!(io, 1.0 / (sx * sx))
        write_f64_le!(io, 1.0 / (sy * sy))
        write_f64_le!(io, 1.0 / (sz * sz))
        # InvTwiceScale (3)
        write_f64_le!(io, 1.0 / (2.0 * sx))
        write_f64_le!(io, 1.0 / (2.0 * sy))
        write_f64_le!(io, 1.0 / (2.0 * sz))
        # VoxelSize (3)
        write_f64_le!(io, sx)
        write_f64_le!(io, sy)
        write_f64_le!(io, sz)
    elseif is_diagonal && !has_translation
        # ScaleMap
        write_string_with_size!(io, "ScaleMap")

        sx, sy, sz = m[1,1], m[2,2], m[3,3]

        # Scale (3)
        write_f64_le!(io, sx)
        write_f64_le!(io, sy)
        write_f64_le!(io, sz)
        # InvScale (3)
        write_f64_le!(io, 1.0 / sx)
        write_f64_le!(io, 1.0 / sy)
        write_f64_le!(io, 1.0 / sz)
        # InvScaleSqr (3)
        write_f64_le!(io, 1.0 / (sx * sx))
        write_f64_le!(io, 1.0 / (sy * sy))
        write_f64_le!(io, 1.0 / (sz * sz))
        # VoxelSize (3)
        write_f64_le!(io, sx)
        write_f64_le!(io, sy)
        write_f64_le!(io, sz)
        # VoxelSize again (3)
        write_f64_le!(io, sx)
        write_f64_le!(io, sy)
        write_f64_le!(io, sz)
    else
        throw(ArgumentError("write_transform!: non-diagonal LinearTransform not yet supported — only scale/translate maps"))
    end

    nothing
end

# =============================================================================
# Grid type string construction
# =============================================================================

"""
    grid_type_string(::Type{T}) -> String

Return the VDB grid type string for a given Julia type.
"""
function grid_type_string(::Type{Float32})::String
    "Tree_float_5_4_3"
end

function grid_type_string(::Type{Float64})::String
    "Tree_double_5_4_3"
end

function grid_type_string(::Type{NTuple{3, Float32}})::String
    "Tree_vec3s_5_4_3"
end

function grid_type_string(::Type{NTuple{3, Float64}})::String
    "Tree_vec3d_5_4_3"
end

function grid_type_string(::Type{Int32})::String
    "Tree_int32_5_4_3"
end

function grid_type_string(::Type{Int64})::String
    "Tree_int64_5_4_3"
end

function grid_type_string(::Type{Bool})::String
    "Tree_bool_5_4_3"
end

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
function write_mask_values!(io::IO, ::Type{T}, values::Vector{T}, mask::Mask{N,W}, background::T) where {T,N,W}
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
        write_tile_value!(buf, values[idx + 1])  # 1-indexed array
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
    write_tree!(io::IO, tree::RootNode{T}) -> Nothing

Write a VDB tree in v222+ format (separate topology and values sections).

Phase 1 (topology): root tiles, then for each root child:
  I2 masks → I2 ReadMaskValues → [I1 masks → I1 ReadMaskValues → [leaf mask]...]...

Phase 2 (values): for each leaf in same order:
  value_mask (64B) → metadata(1B) → raw active values
"""
function write_tree!(io::IO, tree::RootNode{T}) where T
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

        # Write I2 topology
        _write_i2_topology!(io, i2_node, tree.background, all_leaves)
    end

    # Phase 2: Write leaf values
    for leaf in all_leaves
        _write_leaf_values!(io, leaf, tree.background)
    end

    nothing
end

"""
    _write_i2_topology!(io, i2::InternalNode2{T}, background::T, all_leaves) -> Nothing

Write Internal2 node topology: masks, ReadMaskValues for node values, then recurse into I1 children.
"""
function _write_i2_topology!(io::IO, i2::InternalNode2{T}, background::T, all_leaves::Vector{LeafNode{T}}) where T
    # Write I2 masks
    write_mask!(io, i2.child_mask)
    write_mask!(io, i2.value_mask)

    # Write I2 embedded values (ReadMaskValues format)
    # Build dense values vector: children get background, tiles get their value
    i2_values = fill(background, 32768)
    child_count = count_on(i2.child_mask)
    tile_idx = 0
    for bit_idx in on_indices(i2.value_mask)
        tile_idx += 1
        i2_values[bit_idx + 1] = i2.table[child_count + tile_idx].value
    end
    write_mask_values!(io, T, i2_values, i2.value_mask, background)

    # Write I1 children in child_mask order
    child_i = 0
    for _ in on_indices(i2.child_mask)
        child_i += 1
        i1 = i2.table[child_i]::InternalNode1{T}
        _write_i1_topology!(io, i1, background, all_leaves)
    end

    nothing
end

"""
    _write_i1_topology!(io, i1::InternalNode1{T}, background::T, all_leaves) -> Nothing

Write Internal1 node topology: masks, ReadMaskValues for node values, then leaf masks.
"""
function _write_i1_topology!(io::IO, i1::InternalNode1{T}, background::T, all_leaves::Vector{LeafNode{T}}) where T
    # Write I1 masks
    write_mask!(io, i1.child_mask)
    write_mask!(io, i1.value_mask)

    # Write I1 embedded values (ReadMaskValues format)
    i1_values = fill(background, 4096)
    child_count = count_on(i1.child_mask)
    tile_idx = 0
    for bit_idx in on_indices(i1.value_mask)
        tile_idx += 1
        i1_values[bit_idx + 1] = i1.table[child_count + tile_idx].value
    end
    write_mask_values!(io, T, i1_values, i1.value_mask, background)

    # Write leaf value_masks and collect leaves for Phase 2
    child_i = 0
    for _ in on_indices(i1.child_mask)
        child_i += 1
        leaf = i1.table[child_i]::LeafNode{T}
        write_mask!(io, leaf.value_mask)
        push!(all_leaves, leaf)
    end

    nothing
end

"""
    _write_leaf_values!(io, leaf::LeafNode{T}, background::T) -> Nothing

Write leaf values in v222+ format:
1. Value mask (64 bytes) — re-emitted in readBuffers
2. Metadata byte (1 byte) — 0x00 = NO_MASK_OR_INACTIVE_VALS
3. Raw active values (with NoCompression, COMPRESS_ACTIVE_MASK)
"""
function _write_leaf_values!(io::IO, leaf::LeafNode{T}, background::T) where T
    # Re-emit value mask (64 bytes = 8 UInt64 words)
    write_mask!(io, leaf.value_mask)

    # Metadata byte: 0 = NO_MASK_OR_INACTIVE_VALS
    write_u8!(io, UInt8(0x00))

    # Write only active values (mask_compressed path)
    active_count = count_on(leaf.value_mask)
    for idx in on_indices(leaf.value_mask)
        write_tile_value!(io, leaf.values[idx + 1])  # 1-indexed
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
    write_vdb(path::String, grid::Grid{T}) -> Nothing

Write a single grid to a VDB file.

Creates a v224 format file with:
- NoCompression codec
- COMPRESS_ACTIVE_MASK enabled (sparse active value storage)
- Standard grid metadata (class)
"""
function write_vdb(path::String, grid::Grid{T})::Nothing where T
    header = VDBHeader(
        UInt32(224),            # format_version (current)
        UInt32(11),             # library_major
        UInt32(0),              # library_minor
        true,                   # has_grid_offsets
        NoCompression(),        # codec (placeholder for v222+)
        true,                   # active_mask_compression
        "00000000-0000-0000-0000-000000000000"  # UUID
    )

    vdb = VDBFile(header, [grid])
    write_vdb(path, vdb)
end

"""
    write_vdb(path::String, vdb::VDBFile) -> Nothing

Write a complete VDB file.

Strategy for grid offsets:
1. Write header + file metadata + grid count
2. For each grid: write descriptor with placeholder offsets, then grid data
3. Seek back to patch the offsets in each grid descriptor
"""
function write_vdb(path::String, vdb::VDBFile)::Nothing
    open(path, "w") do io
        _write_vdb_to_io(io, vdb)
    end
    nothing
end

"""
    write_vdb_to_buffer(vdb::VDBFile) -> Vector{UInt8}

Write a complete VDB file to an in-memory buffer. Useful for testing.
"""
function write_vdb_to_buffer(vdb::VDBFile)::Vector{UInt8}
    io = IOBuffer()
    _write_vdb_to_io(io, vdb)
    take!(io)
end

"""
    write_vdb_to_buffer(grid::Grid{T}) -> Vector{UInt8}

Write a single grid to an in-memory buffer.
"""
function write_vdb_to_buffer(grid::Grid{T})::Vector{UInt8} where T
    header = VDBHeader(
        UInt32(224),
        UInt32(11),
        UInt32(0),
        true,
        NoCompression(),
        true,
        "00000000-0000-0000-0000-000000000000"
    )
    write_vdb_to_buffer(VDBFile(header, [grid]))
end

"""
    _write_vdb_to_io(io::IO, vdb::VDBFile) -> Nothing

Internal: write a complete VDB file to any IO stream.
"""
function _write_vdb_to_io(io::IO, vdb::VDBFile)::Nothing
    # Write header
    write_header!(io, vdb.header)

    # Write empty file-level metadata
    write_metadata!(io, Dict{String,Any}())

    # Write grid count
    write_u32_le!(io, UInt32(length(vdb.grids)))

    # Write each grid
    for grid in vdb.grids
        _write_grid(io, grid, vdb.header)
    end

    nothing
end

"""
    _write_grid(io::IO, grid::Grid{T}, header::VDBHeader) -> Nothing

Write a single grid: descriptor (with offset patching) + grid data.
"""
function _write_grid(io::IO, grid::Grid{T}, header::VDBHeader) where T
    # Build grid descriptor with placeholder offsets
    grid_type = grid_type_string(T)

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
    # Flags: 0x2 = COMPRESS_ACTIVE_MASK (we use this), 0x0 for no ZIP/Blosc
    if header.format_version >= 222
        compression_flags = UInt32(0x2)  # COMPRESS_ACTIVE_MASK only
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

    # Write background value
    write_tile_value!(io, grid.tree.background)

    # block_offset marks start of the tree data (topology + values)
    block_offset = position(io)

    # Write tree
    write_tree!(io, grid.tree)

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
