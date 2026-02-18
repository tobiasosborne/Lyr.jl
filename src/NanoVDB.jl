# NanoVDB.jl - Flat-buffer VDB representation for GPU-ready data
#
# Serializes the pointer-based VDB tree (Root→I2→I1→Leaf) into a single
# contiguous Vector{UInt8} buffer with byte-offset references. This is the
# critical path to GPU rendering via KernelAbstractions.jl.
#
# Buffer layout (1-indexed positions):
#   Header | Root Table | I2 Nodes | I1 Nodes | Leaf Nodes
#
# All inter-node references are UInt32 byte offsets from buffer position 1.

# ──────────────────────────────────────────────────────────────────────────────
# Buffer Primitives
# ──────────────────────────────────────────────────────────────────────────────

"""Load a value of type T from buffer at 1-indexed position `pos`."""
@inline function _buf_load(::Type{T}, buf::Vector{UInt8}, pos::Int) where T
    @boundscheck checkbounds(buf, pos:pos + sizeof(T) - 1)
    GC.@preserve buf begin
        @inbounds _unaligned_load(T, pointer(buf, pos))
    end
end

"""Store a value of type T into buffer at 1-indexed position `pos`."""
@inline function _buf_store!(buf::Vector{UInt8}, pos::Int, val::T) where T
    @boundscheck checkbounds(buf, pos:pos + sizeof(T) - 1)
    GC.@preserve buf begin
        @inbounds ptr = pointer(buf, pos)
        ref = Ref(val)
        GC.@preserve ref begin
            src = Base.unsafe_convert(Ptr{T}, ref)
            ccall(:memcpy, Ptr{Cvoid}, (Ptr{UInt8}, Ptr{T}, Csize_t), ptr, src, sizeof(T))
        end
    end
    nothing
end

"""Read a Coord (3×Int32) from buffer at position `pos`."""
@inline function _buf_load_coord(buf::Vector{UInt8}, pos::Int)::Coord
    x = _buf_load(Int32, buf, pos)
    y = _buf_load(Int32, buf, pos + 4)
    z = _buf_load(Int32, buf, pos + 8)
    Coord(x, y, z)
end

"""Write a Coord (3×Int32) to buffer at position `pos`."""
@inline function _buf_store_coord!(buf::Vector{UInt8}, pos::Int, c::Coord)
    _buf_store!(buf, pos, c.x)
    _buf_store!(buf, pos + 4, c.y)
    _buf_store!(buf, pos + 8, c.z)
end

# ──────────────────────────────────────────────────────────────────────────────
# Buffer-native mask operations
# ──────────────────────────────────────────────────────────────────────────────

"""Test if bit `bit_idx` (0-based) is on in a mask stored at `mask_pos` in buffer."""
@inline function _buf_mask_is_on(buf::Vector{UInt8}, mask_pos::Int, bit_idx::Int)::Bool
    word_idx = (bit_idx >> 6)       # 0-based word index
    bit_in_word = bit_idx & 63
    word_pos = mask_pos + word_idx * 8
    word = _buf_load(UInt64, buf, word_pos)
    (word >> bit_in_word) & 1 == 1
end

"""
Count on-bits before `bit_idx` (0-based, exclusive) using prefix sums stored at `prefix_pos`.
`mask_pos` is the start of the mask words, `prefix_pos` is the start of the UInt32 prefix array.
"""
@inline function _buf_count_on_before(buf::Vector{UInt8}, mask_pos::Int, prefix_pos::Int, bit_idx::Int)::Int
    bit_idx == 0 && return 0
    word_idx = bit_idx >> 6        # 0-based
    bit_in_word = bit_idx & 63

    # Prefix sum for complete words before word_idx
    count = word_idx > 0 ? Int(_buf_load(UInt32, buf, prefix_pos + (word_idx - 1) * 4)) : 0

    # Partial word
    if bit_in_word > 0
        word = _buf_load(UInt64, buf, mask_pos + word_idx * 8)
        mask = (UInt64(1) << bit_in_word) - 1
        count += count_ones(word & mask)
    end

    count
end

"""Total on-bits in a mask: read last prefix entry."""
@inline function _buf_count_on(buf::Vector{UInt8}, prefix_pos::Int, W::Int)::Int
    Int(_buf_load(UInt32, buf, prefix_pos + (W - 1) * 4))
end

"""
Write mask words + prefix sums to buffer starting at `pos`.
Returns the number of bytes written (W*8 + W*4 = W*12).
"""
function _buf_write_mask!(buf::Vector{UInt8}, pos::Int, m::Mask{N,W})::Int where {N,W}
    # Write words
    for i in 1:W
        _buf_store!(buf, pos + (i - 1) * 8, m.words[i])
    end
    prefix_pos = pos + W * 8
    # Write prefix sums
    for i in 1:W
        _buf_store!(buf, prefix_pos + (i - 1) * 4, m.prefix[i])
    end
    W * 12  # 8 bytes per word + 4 bytes per prefix
end

# ──────────────────────────────────────────────────────────────────────────────
# Types
# ──────────────────────────────────────────────────────────────────────────────

"""
    NanoGrid{T}

A VDB tree serialized into a single contiguous byte buffer.
All node references are UInt32 byte offsets from position 1.
GPU-transferable: just copy `buffer` to device memory.
"""
struct NanoGrid{T}
    buffer::Vector{UInt8}
end

# Magic number for NanoGrid buffers
const NANO_MAGIC = UInt32(0x4E564442)  # "NVDB"
const NANO_VERSION = UInt32(1)

# Header layout (all offsets are byte positions, 1-indexed):
#   1:   magic        UInt32   (4B)
#   5:   version      UInt32   (4B)
#   9:   value_size   UInt32   (4B)
#   13:  background   T        (sizeof(T) B)
#   13+sizeof(T): bbox_min  Coord (12B)
#   25+sizeof(T): bbox_max  Coord (12B)
#   37+sizeof(T): root_count   UInt32 (4B)
#   41+sizeof(T): i2_count     UInt32 (4B)
#   45+sizeof(T): i1_count     UInt32 (4B)
#   49+sizeof(T): leaf_count   UInt32 (4B)
#   53+sizeof(T): root_pos     UInt32 (4B)
#   57+sizeof(T): i2_pos       UInt32 (4B)
#   61+sizeof(T): i1_pos       UInt32 (4B)
#   65+sizeof(T): leaf_pos     UInt32 (4B)
# Total header: 68 + sizeof(T) bytes

@inline _header_size(::Type{T}) where T = 68 + sizeof(T)

@inline function _header_background_pos(::Type{T}) where T
    13  # background starts at byte 13
end

@inline function _header_bbox_min_pos(::Type{T}) where T
    13 + sizeof(T)
end

# ──────────────────────────────────────────────────────────────────────────────
# Header accessors
# ──────────────────────────────────────────────────────────────────────────────

function nano_background(grid::NanoGrid{T})::T where T
    _buf_load(T, grid.buffer, 13)
end

function nano_bbox(grid::NanoGrid{T})::BBox where T
    base = 13 + sizeof(T)
    bmin = _buf_load_coord(grid.buffer, base)
    bmax = _buf_load_coord(grid.buffer, base + 12)
    BBox(bmin, bmax)
end

function nano_root_count(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, 37 + sizeof(T)))
end

function nano_i2_count(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, 41 + sizeof(T)))
end

function nano_i1_count(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, 45 + sizeof(T)))
end

function nano_leaf_count(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, 49 + sizeof(T)))
end

function _nano_root_pos(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, 53 + sizeof(T)))
end

function _nano_i2_pos(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, 57 + sizeof(T)))
end

function _nano_i1_pos(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, 61 + sizeof(T)))
end

function _nano_leaf_pos(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, 65 + sizeof(T)))
end

# ──────────────────────────────────────────────────────────────────────────────
# View Types
# ──────────────────────────────────────────────────────────────────────────────

"""
    NanoLeafView{T}

A zero-copy view into a leaf node stored in a NanoGrid buffer.

Layout at `offset`:
  +0:  origin      Coord  (12B)
  +12: value_mask  8×UInt64 (64B)
  +76: values      512×T
"""
struct NanoLeafView{T}
    buf::Vector{UInt8}
    offset::Int   # 1-indexed byte position of this leaf in buffer
end

const _LEAF_VMASK_OFF = 12
const _LEAF_VALUES_OFF = 76
@inline _leaf_node_size(::Type{T}) where T = 76 + 512 * sizeof(T)

@inline function nano_origin(v::NanoLeafView)::Coord
    _buf_load_coord(v.buf, v.offset)
end

@inline function nano_is_active(v::NanoLeafView, idx::Int)::Bool
    _buf_mask_is_on(v.buf, v.offset + _LEAF_VMASK_OFF, idx)
end

@inline function nano_get_value(v::NanoLeafView{T}, idx::Int)::T where T
    _buf_load(T, v.buf, v.offset + _LEAF_VALUES_OFF + idx * sizeof(T))
end

@inline function nano_get_value(v::NanoLeafView{T}, c::Coord)::T where T
    nano_get_value(v, leaf_offset(c))
end

"""
    NanoI1View{T}

View into an Internal1 node in the NanoGrid buffer.

Layout at `offset`:
  +0:    origin         Coord    (12B)
  +12:   child_mask     64×UInt64 (512B)
  +524:  child_prefix   64×UInt32 (256B)
  +780:  value_mask     64×UInt64 (512B)
  +1292: value_prefix   64×UInt32 (256B)
  +1548: child_count    UInt32   (4B)
  +1552: tile_count     UInt32   (4B)
  +1556: child_offsets  child_count×UInt32
  +1556+child_count*4: tile_values  tile_count×T
"""
struct NanoI1View{T}
    buf::Vector{UInt8}
    offset::Int
end

const _I1_CMASK_OFF = 12
const _I1_CPREFIX_OFF = 12 + 64 * 8         # 524
const _I1_VMASK_OFF = 12 + 64 * 8 + 64 * 4  # 780
const _I1_VPREFIX_OFF = _I1_VMASK_OFF + 64 * 8  # 1292
const _I1_CHILDCOUNT_OFF = _I1_VPREFIX_OFF + 64 * 4  # 1548
const _I1_TILECOUNT_OFF = _I1_CHILDCOUNT_OFF + 4  # 1552
const _I1_DATA_OFF = _I1_TILECOUNT_OFF + 4  # 1556

@inline function nano_origin(v::NanoI1View)::Coord
    _buf_load_coord(v.buf, v.offset)
end

@inline function nano_child_count(v::NanoI1View)::Int
    Int(_buf_load(UInt32, v.buf, v.offset + _I1_CHILDCOUNT_OFF))
end

@inline function nano_tile_count(v::NanoI1View)::Int
    Int(_buf_load(UInt32, v.buf, v.offset + _I1_TILECOUNT_OFF))
end

@inline function nano_has_child(v::NanoI1View, idx::Int)::Bool
    _buf_mask_is_on(v.buf, v.offset + _I1_CMASK_OFF, idx)
end

@inline function nano_has_tile(v::NanoI1View, idx::Int)::Bool
    !nano_has_child(v, idx) &&
    _buf_mask_is_on(v.buf, v.offset + _I1_VMASK_OFF, idx)
end

@inline function nano_child_offset(v::NanoI1View, idx::Int)::Int
    table_idx = _buf_count_on_before(v.buf, v.offset + _I1_CMASK_OFF,
                                     v.offset + _I1_CPREFIX_OFF, idx)
    Int(_buf_load(UInt32, v.buf, v.offset + _I1_DATA_OFF + table_idx * 4))
end

@inline function nano_tile_value(v::NanoI1View{T}, idx::Int)::T where T
    cc = nano_child_count(v)
    tile_idx = _buf_count_on_before(v.buf, v.offset + _I1_VMASK_OFF,
                                    v.offset + _I1_VPREFIX_OFF, idx)
    tile_data_pos = v.offset + _I1_DATA_OFF + cc * 4
    _buf_load(T, v.buf, tile_data_pos + tile_idx * sizeof(T))
end

"""
    NanoI2View{T}

View into an Internal2 node in the NanoGrid buffer.

Layout at `offset`:
  +0:    origin          Coord     (12B)
  +12:   child_mask      512×UInt64 (4096B)
  +4108: child_prefix    512×UInt32 (2048B)
  +6156: value_mask      512×UInt64 (4096B)
  +10252: value_prefix   512×UInt32 (2048B)
  +12300: child_count    UInt32    (4B)
  +12304: tile_count     UInt32    (4B)
  +12308: child_offsets  child_count×UInt32
  +12308+child_count*4: tile_values  tile_count×T
"""
struct NanoI2View{T}
    buf::Vector{UInt8}
    offset::Int
end

const _I2_CMASK_OFF = 12
const _I2_CPREFIX_OFF = 12 + 512 * 8          # 4108
const _I2_VMASK_OFF = 12 + 512 * 8 + 512 * 4  # 6156
const _I2_VPREFIX_OFF = _I2_VMASK_OFF + 512 * 8  # 10252
const _I2_CHILDCOUNT_OFF = _I2_VPREFIX_OFF + 512 * 4  # 12300
const _I2_TILECOUNT_OFF = _I2_CHILDCOUNT_OFF + 4  # 12304
const _I2_DATA_OFF = _I2_TILECOUNT_OFF + 4  # 12308

@inline function nano_origin(v::NanoI2View)::Coord
    _buf_load_coord(v.buf, v.offset)
end

@inline function nano_child_count(v::NanoI2View)::Int
    Int(_buf_load(UInt32, v.buf, v.offset + _I2_CHILDCOUNT_OFF))
end

@inline function nano_tile_count(v::NanoI2View)::Int
    Int(_buf_load(UInt32, v.buf, v.offset + _I2_TILECOUNT_OFF))
end

@inline function nano_has_child(v::NanoI2View, idx::Int)::Bool
    _buf_mask_is_on(v.buf, v.offset + _I2_CMASK_OFF, idx)
end

@inline function nano_has_tile(v::NanoI2View, idx::Int)::Bool
    !nano_has_child(v, idx) &&
    _buf_mask_is_on(v.buf, v.offset + _I2_VMASK_OFF, idx)
end

@inline function nano_child_offset(v::NanoI2View, idx::Int)::Int
    table_idx = _buf_count_on_before(v.buf, v.offset + _I2_CMASK_OFF,
                                     v.offset + _I2_CPREFIX_OFF, idx)
    Int(_buf_load(UInt32, v.buf, v.offset + _I2_DATA_OFF + table_idx * 4))
end

@inline function nano_tile_value(v::NanoI2View{T}, idx::Int)::T where T
    cc = nano_child_count(v)
    tile_idx = _buf_count_on_before(v.buf, v.offset + _I2_VMASK_OFF,
                                    v.offset + _I2_VPREFIX_OFF, idx)
    tile_data_pos = v.offset + _I2_DATA_OFF + cc * 4
    _buf_load(T, v.buf, tile_data_pos + tile_idx * sizeof(T))
end

# ──────────────────────────────────────────────────────────────────────────────
# Root View + Binary Search
# ──────────────────────────────────────────────────────────────────────────────

# Root entry layout (per entry):
#   +0:  origin    Coord  (12B)
#   +12: is_child  UInt8  (1B)
#   +13: payload   T      (sizeof(T) B)
# Total per entry: 13 + sizeof(T) bytes

@inline _root_entry_size(::Type{T}) where T = 13 + sizeof(T)

"""Lexicographic comparison of Coord for binary search (x, then y, then z)."""
@inline function _coord_less(a::Coord, b::Coord)::Bool
    a.x < b.x && return true
    a.x > b.x && return false
    a.y < b.y && return true
    a.y > b.y && return false
    a.z < b.z
end

"""
Binary search root table for entry matching `origin`.
Returns (entry_pos, found::Bool).
"""
function _nano_root_find(buf::Vector{UInt8}, root_pos::Int, count::Int,
                         entry_size::Int, origin::Coord)::Tuple{Int, Bool}
    lo, hi = 1, count
    while lo <= hi
        mid = (lo + hi) >> 1
        mid_pos = root_pos + (mid - 1) * entry_size
        mid_origin = _buf_load_coord(buf, mid_pos)
        if mid_origin == origin
            return (mid_pos, true)
        elseif _coord_less(mid_origin, origin)
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return (0, false)
end

# ──────────────────────────────────────────────────────────────────────────────
# build_nanogrid: Tree{T} → NanoGrid{T}
# ──────────────────────────────────────────────────────────────────────────────

"""
    build_nanogrid(tree::Tree{T}) -> NanoGrid{T}

Convert a pointer-based VDB tree to a flat-buffer NanoGrid.

Two-pass algorithm:
1. Inventory pass — collect all nodes, compute sizes and offsets
2. Write pass — serialize into contiguous buffer
"""
function build_nanogrid(tree::Tree{T})::NanoGrid{T} where T
    # ── Pass 1: Inventory ──

    # Collect root entries sorted by Coord (lexicographic)
    root_entries = Tuple{Coord, Bool, Union{InternalNode2{T}, Tile{T}}}[]
    for (origin, entry) in tree.table
        is_child = entry isa InternalNode2{T}
        push!(root_entries, (origin, is_child, entry))
    end
    sort!(root_entries, by=e -> (e[1].x, e[1].y, e[1].z))

    # Collect all I2, I1, Leaf nodes in traversal order
    i2_nodes = InternalNode2{T}[]
    i1_nodes = InternalNode1{T}[]
    leaf_nodes = LeafNode{T}[]

    # Map from node identity to index (1-based) for offset computation
    i2_index = Dict{UInt, Int}()   # objectid → index
    i1_index = Dict{UInt, Int}()
    leaf_index = Dict{UInt, Int}()

    for (_, is_child, entry) in root_entries
        if is_child
            node2 = entry::InternalNode2{T}
            push!(i2_nodes, node2)
            i2_index[objectid(node2)] = length(i2_nodes)

            for (i, _) in enumerate(on_indices(node2.child_mask))
                node1 = node2.table[i]::InternalNode1{T}
                push!(i1_nodes, node1)
                i1_index[objectid(node1)] = length(i1_nodes)

                for (j, _) in enumerate(on_indices(node1.child_mask))
                    leaf = node1.table[j]::LeafNode{T}
                    push!(leaf_nodes, leaf)
                    leaf_index[objectid(leaf)] = length(leaf_nodes)
                end
            end
        end
    end

    root_count = length(root_entries)
    i2_count = length(i2_nodes)
    i1_count = length(i1_nodes)
    lf_count = length(leaf_nodes)

    # ── Compute section positions ──

    header_sz = _header_size(T)
    entry_sz = _root_entry_size(T)
    root_section_pos = header_sz + 1
    root_section_sz = root_count * entry_sz

    # I2 sizes are variable: fixed part + child_count*4 + tile_count*sizeof(T)
    i2_section_pos = root_section_pos + root_section_sz
    i2_sizes = Int[]
    i2_offsets = Int[]  # absolute buffer position for each I2 node
    pos = i2_section_pos
    for node2 in i2_nodes
        cc = count_on(node2.child_mask)
        tc = count_on(node2.value_mask)
        sz = _I2_DATA_OFF + cc * 4 + tc * sizeof(T)
        push!(i2_sizes, sz)
        push!(i2_offsets, pos)
        pos += sz
    end

    # I1 section
    i1_section_pos = pos
    i1_sizes = Int[]
    i1_offsets = Int[]
    for node1 in i1_nodes
        cc = count_on(node1.child_mask)
        tc = count_on(node1.value_mask)
        sz = _I1_DATA_OFF + cc * 4 + tc * sizeof(T)
        push!(i1_sizes, sz)
        push!(i1_offsets, pos)
        pos += sz
    end

    # Leaf section
    leaf_section_pos = pos
    leaf_sz = _leaf_node_size(T)
    total_size = leaf_section_pos + lf_count * leaf_sz - 1

    # ── Pass 2: Write ──

    buf = Vector{UInt8}(undef, total_size)

    # -- Header --
    _buf_store!(buf, 1, NANO_MAGIC)
    _buf_store!(buf, 5, NANO_VERSION)
    _buf_store!(buf, 9, UInt32(sizeof(T)))
    _buf_store!(buf, 13, tree.background)

    # BBox — compute from leaf origins
    if !isempty(leaf_nodes)
        bmin = leaf_nodes[1].origin
        bmax = leaf_nodes[1].origin + Coord(Int32(7), Int32(7), Int32(7))
        for leaf in leaf_nodes
            bmin = min(bmin, leaf.origin)
            bmax = max(bmax, leaf.origin + Coord(Int32(7), Int32(7), Int32(7)))
        end
    else
        bmin = Coord(Int32(0), Int32(0), Int32(0))
        bmax = Coord(Int32(0), Int32(0), Int32(0))
    end
    _buf_store_coord!(buf, 13 + sizeof(T), bmin)
    _buf_store_coord!(buf, 25 + sizeof(T), bmax)

    _buf_store!(buf, 37 + sizeof(T), UInt32(root_count))
    _buf_store!(buf, 41 + sizeof(T), UInt32(i2_count))
    _buf_store!(buf, 45 + sizeof(T), UInt32(i1_count))
    _buf_store!(buf, 49 + sizeof(T), UInt32(lf_count))
    _buf_store!(buf, 53 + sizeof(T), UInt32(root_section_pos))
    _buf_store!(buf, 57 + sizeof(T), UInt32(i2_section_pos))
    _buf_store!(buf, 61 + sizeof(T), UInt32(i1_section_pos))
    _buf_store!(buf, 65 + sizeof(T), UInt32(leaf_section_pos))

    # -- Root table --
    wpos = root_section_pos
    for (origin, is_child, entry) in root_entries
        _buf_store_coord!(buf, wpos, origin)
        _buf_store!(buf, wpos + 12, is_child ? UInt8(1) : UInt8(0))
        if is_child
            node2 = entry::InternalNode2{T}
            idx = i2_index[objectid(node2)]
            # Store I2 offset as UInt32 in the first 4 bytes of payload
            _buf_store!(buf, wpos + 13, UInt32(i2_offsets[idx]))
            # Zero remaining payload bytes if sizeof(T) > 4
            for b in (wpos + 13 + 4):(wpos + 13 + sizeof(T) - 1)
                buf[b] = 0x00
            end
        else
            tile = entry::Tile{T}
            _buf_store!(buf, wpos + 13, tile.value)
        end
        wpos += entry_sz
    end

    # -- I2 nodes --
    for (ni, node2) in enumerate(i2_nodes)
        base = i2_offsets[ni]
        _buf_store_coord!(buf, base, node2.origin)
        p = base + 12
        p += _buf_write_mask!(buf, p, node2.child_mask)
        p += _buf_write_mask!(buf, p, node2.value_mask)

        cc = count_on(node2.child_mask)
        tc = count_on(node2.value_mask)
        _buf_store!(buf, p, UInt32(cc))
        _buf_store!(buf, p + 4, UInt32(tc))
        p += 8

        # Child offsets → I1 byte positions
        for (i, _) in enumerate(on_indices(node2.child_mask))
            node1 = node2.table[i]::InternalNode1{T}
            idx = i1_index[objectid(node1)]
            _buf_store!(buf, p, UInt32(i1_offsets[idx]))
            p += 4
        end

        # Tile values
        tile_offset = cc
        for (i, _) in enumerate(on_indices(node2.value_mask))
            tile = node2.table[tile_offset + i]::Tile{T}
            _buf_store!(buf, p, tile.value)
            p += sizeof(T)
        end
    end

    # -- I1 nodes --
    for (ni, node1) in enumerate(i1_nodes)
        base = i1_offsets[ni]
        _buf_store_coord!(buf, base, node1.origin)
        p = base + 12
        p += _buf_write_mask!(buf, p, node1.child_mask)
        p += _buf_write_mask!(buf, p, node1.value_mask)

        cc = count_on(node1.child_mask)
        tc = count_on(node1.value_mask)
        _buf_store!(buf, p, UInt32(cc))
        _buf_store!(buf, p + 4, UInt32(tc))
        p += 8

        # Child offsets → Leaf byte positions
        for (i, _) in enumerate(on_indices(node1.child_mask))
            leaf = node1.table[i]::LeafNode{T}
            idx = leaf_index[objectid(leaf)]
            leaf_off = leaf_section_pos + (idx - 1) * leaf_sz
            _buf_store!(buf, p, UInt32(leaf_off))
            p += 4
        end

        # Tile values
        tile_offset = cc
        for (i, _) in enumerate(on_indices(node1.value_mask))
            tile = node1.table[tile_offset + i]::Tile{T}
            _buf_store!(buf, p, tile.value)
            p += sizeof(T)
        end
    end

    # -- Leaf nodes --
    for (li, leaf) in enumerate(leaf_nodes)
        base = leaf_section_pos + (li - 1) * leaf_sz
        _buf_store_coord!(buf, base, leaf.origin)

        # Write value_mask (8 words, no prefix needed — just 64B raw)
        for i in 1:8
            _buf_store!(buf, base + 12 + (i - 1) * 8, leaf.value_mask.words[i])
        end

        # Write values
        vpos = base + _LEAF_VALUES_OFF
        for i in 1:512
            _buf_store!(buf, vpos + (i - 1) * sizeof(T), leaf.values[i])
        end
    end

    NanoGrid{T}(buf)
end

# ──────────────────────────────────────────────────────────────────────────────
# get_value: Hierarchical lookup through flat buffer
# ──────────────────────────────────────────────────────────────────────────────

"""
    get_value(grid::NanoGrid{T}, c::Coord) -> T

Look up the value at coordinate `c` in the flat-buffer NanoGrid.
Traverses Root → I2 → I1 → Leaf using byte offsets.
"""
function get_value(grid::NanoGrid{T}, c::Coord)::T where T
    buf = grid.buffer
    bg = nano_background(grid)
    root_pos = _nano_root_pos(grid)
    root_count = nano_root_count(grid)
    entry_sz = _root_entry_size(T)

    # 1. Binary search root for I2 origin
    i2_origin = internal2_origin(c)
    entry_pos, found = _nano_root_find(buf, root_pos, root_count, entry_sz, i2_origin)
    found || return bg

    # 2. Check if child or tile
    is_child = _buf_load(UInt8, buf, entry_pos + 12)
    if is_child == 0x00
        return _buf_load(T, buf, entry_pos + 13)
    end

    # 3. Follow I2 offset
    i2_off = Int(_buf_load(UInt32, buf, entry_pos + 13))
    i2_idx = internal2_child_index(c)

    # 4. Check I2 child_mask
    if !_buf_mask_is_on(buf, i2_off + _I2_CMASK_OFF, i2_idx)
        # Check tile
        if _buf_mask_is_on(buf, i2_off + _I2_VMASK_OFF, i2_idx)
            cc = Int(_buf_load(UInt32, buf, i2_off + _I2_CHILDCOUNT_OFF))
            tile_idx = _buf_count_on_before(buf, i2_off + _I2_VMASK_OFF,
                                            i2_off + _I2_VPREFIX_OFF, i2_idx)
            tile_pos = i2_off + _I2_DATA_OFF + cc * 4 + tile_idx * sizeof(T)
            return _buf_load(T, buf, tile_pos)
        end
        return bg
    end

    # 5. Follow to I1
    table_idx = _buf_count_on_before(buf, i2_off + _I2_CMASK_OFF,
                                     i2_off + _I2_CPREFIX_OFF, i2_idx)
    i1_off = Int(_buf_load(UInt32, buf, i2_off + _I2_DATA_OFF + table_idx * 4))

    i1_idx = internal1_child_index(c)

    # 6. Check I1 child_mask
    if !_buf_mask_is_on(buf, i1_off + _I1_CMASK_OFF, i1_idx)
        # Check tile
        if _buf_mask_is_on(buf, i1_off + _I1_VMASK_OFF, i1_idx)
            cc = Int(_buf_load(UInt32, buf, i1_off + _I1_CHILDCOUNT_OFF))
            tile_idx = _buf_count_on_before(buf, i1_off + _I1_VMASK_OFF,
                                            i1_off + _I1_VPREFIX_OFF, i1_idx)
            tile_pos = i1_off + _I1_DATA_OFF + cc * 4 + tile_idx * sizeof(T)
            return _buf_load(T, buf, tile_pos)
        end
        return bg
    end

    # 7. Follow to Leaf
    table_idx = _buf_count_on_before(buf, i1_off + _I1_CMASK_OFF,
                                     i1_off + _I1_CPREFIX_OFF, i1_idx)
    leaf_off = Int(_buf_load(UInt32, buf, i1_off + _I1_DATA_OFF + table_idx * 4))

    # 8. Read value from leaf
    offset = leaf_offset(c)
    _buf_load(T, buf, leaf_off + _LEAF_VALUES_OFF + offset * sizeof(T))
end

# ──────────────────────────────────────────────────────────────────────────────
# NanoValueAccessor: Cached lookup
# ──────────────────────────────────────────────────────────────────────────────

"""
    NanoValueAccessor{T}

Cached accessor for NanoGrid lookups. Caches byte offsets of recently accessed
leaf, I1, and I2 nodes for O(1) repeated lookups in the same region.
"""
mutable struct NanoValueAccessor{T}
    const grid::NanoGrid{T}
    leaf_offset::Int      # byte offset of cached leaf (0 = none)
    leaf_origin::Coord
    i1_offset::Int
    i1_origin::Coord
    i2_offset::Int
    i2_origin::Coord
end

function NanoValueAccessor(grid::NanoGrid{T}) where T
    z = Coord(Int32(0), Int32(0), Int32(0))
    NanoValueAccessor{T}(grid, 0, z, 0, z, 0, z)
end

function get_value(acc::NanoValueAccessor{T}, c::Coord)::T where T
    buf = acc.grid.buffer

    # Level 0: cached leaf
    if acc.leaf_offset != 0 && leaf_origin(c) == acc.leaf_origin
        offset = leaf_offset(c)
        return _buf_load(T, buf, acc.leaf_offset + _LEAF_VALUES_OFF + offset * sizeof(T))
    end

    # Level 1: cached I1
    if acc.i1_offset != 0 && internal1_origin(c) == acc.i1_origin
        return _nano_get_from_i1(acc, acc.i1_offset, c)
    end

    # Level 2: cached I2
    if acc.i2_offset != 0 && internal2_origin(c) == acc.i2_origin
        return _nano_get_from_i2(acc, acc.i2_offset, c)
    end

    # Full traversal
    return _nano_get_from_root(acc, c)
end

function _nano_get_from_root(acc::NanoValueAccessor{T}, c::Coord)::T where T
    buf = acc.grid.buffer
    bg = nano_background(acc.grid)
    root_pos = _nano_root_pos(acc.grid)
    root_count = nano_root_count(acc.grid)
    entry_sz = _root_entry_size(T)

    i2_origin = internal2_origin(c)
    entry_pos, found = _nano_root_find(buf, root_pos, root_count, entry_sz, i2_origin)
    found || return bg

    is_child = _buf_load(UInt8, buf, entry_pos + 12)
    if is_child == 0x00
        return _buf_load(T, buf, entry_pos + 13)
    end

    i2_off = Int(_buf_load(UInt32, buf, entry_pos + 13))
    acc.i2_offset = i2_off
    acc.i2_origin = i2_origin
    return _nano_get_from_i2(acc, i2_off, c)
end

function _nano_get_from_i2(acc::NanoValueAccessor{T}, i2_off::Int, c::Coord)::T where T
    buf = acc.grid.buffer
    bg = nano_background(acc.grid)
    i2_idx = internal2_child_index(c)

    if !_buf_mask_is_on(buf, i2_off + _I2_CMASK_OFF, i2_idx)
        if _buf_mask_is_on(buf, i2_off + _I2_VMASK_OFF, i2_idx)
            cc = Int(_buf_load(UInt32, buf, i2_off + _I2_CHILDCOUNT_OFF))
            tile_idx = _buf_count_on_before(buf, i2_off + _I2_VMASK_OFF,
                                            i2_off + _I2_VPREFIX_OFF, i2_idx)
            return _buf_load(T, buf, i2_off + _I2_DATA_OFF + cc * 4 + tile_idx * sizeof(T))
        end
        return bg
    end

    table_idx = _buf_count_on_before(buf, i2_off + _I2_CMASK_OFF,
                                     i2_off + _I2_CPREFIX_OFF, i2_idx)
    i1_off = Int(_buf_load(UInt32, buf, i2_off + _I2_DATA_OFF + table_idx * 4))
    acc.i1_offset = i1_off
    acc.i1_origin = internal1_origin(c)
    return _nano_get_from_i1(acc, i1_off, c)
end

function _nano_get_from_i1(acc::NanoValueAccessor{T}, i1_off::Int, c::Coord)::T where T
    buf = acc.grid.buffer
    bg = nano_background(acc.grid)
    i1_idx = internal1_child_index(c)

    if !_buf_mask_is_on(buf, i1_off + _I1_CMASK_OFF, i1_idx)
        if _buf_mask_is_on(buf, i1_off + _I1_VMASK_OFF, i1_idx)
            cc = Int(_buf_load(UInt32, buf, i1_off + _I1_CHILDCOUNT_OFF))
            tile_idx = _buf_count_on_before(buf, i1_off + _I1_VMASK_OFF,
                                            i1_off + _I1_VPREFIX_OFF, i1_idx)
            return _buf_load(T, buf, i1_off + _I1_DATA_OFF + cc * 4 + tile_idx * sizeof(T))
        end
        return bg
    end

    table_idx = _buf_count_on_before(buf, i1_off + _I1_CMASK_OFF,
                                     i1_off + _I1_CPREFIX_OFF, i1_idx)
    leaf_off = Int(_buf_load(UInt32, buf, i1_off + _I1_DATA_OFF + table_idx * 4))
    acc.leaf_offset = leaf_off
    acc.leaf_origin = leaf_origin(c)
    offset = leaf_offset(c)
    return _buf_load(T, buf, leaf_off + _LEAF_VALUES_OFF + offset * sizeof(T))
end

# ──────────────────────────────────────────────────────────────────────────────
# active_voxel_count for NanoGrid
# ──────────────────────────────────────────────────────────────────────────────

"""
    active_voxel_count(grid::NanoGrid{T}) -> Int

Count active voxels by summing value_mask popcounts across all leaves.
"""
function active_voxel_count(grid::NanoGrid{T})::Int where T
    buf = grid.buffer
    lf_count = nano_leaf_count(grid)
    leaf_pos = _nano_leaf_pos(grid)
    leaf_sz = _leaf_node_size(T)

    count = 0
    for i in 0:(lf_count - 1)
        base = leaf_pos + i * leaf_sz
        # Sum popcount of all 8 value_mask words
        for w in 0:7
            word = _buf_load(UInt64, buf, base + _LEAF_VMASK_OFF + w * 8)
            count += count_ones(word)
        end
    end
    count
end

# ──────────────────────────────────────────────────────────────────────────────
# NanoVolumeRayIntersector: DDA through flat buffer
# ──────────────────────────────────────────────────────────────────────────────

"""
    NanoLeafHit{T}

Result of a ray-leaf intersection in a NanoGrid.

# Fields
- `t_enter::Float64` - Entry ray parameter
- `t_exit::Float64` - Exit ray parameter
- `leaf_offset::Int` - Byte offset of leaf in NanoGrid buffer
"""
struct NanoLeafHit{T}
    t_enter::Float64
    t_exit::Float64
    leaf_offset::Int
end

"""
    NanoVolumeRayIntersector{T}

Lazy iterator yielding `NanoLeafHit{T}` in front-to-back order via
hierarchical DDA through a NanoGrid flat buffer.
"""
struct NanoVolumeRayIntersector{T}
    grid::NanoGrid{T}
    ray::Ray
end

Base.IteratorSize(::Type{<:NanoVolumeRayIntersector}) = Base.SizeUnknown()
Base.eltype(::Type{NanoVolumeRayIntersector{T}}) where T = NanoLeafHit{T}

mutable struct NanoVRIState{T}
    roots::Vector{Tuple{Float64, Int}}  # (tmin, i2_byte_offset)
    root_idx::Int
    i2_ndda::Union{NodeDDA, Nothing}
    i2_off::Int                         # current I2 byte offset
    i1_ndda::Union{NodeDDA, Nothing}
    i1_off::Int                         # current I1 byte offset
end

function Base.iterate(vri::NanoVolumeRayIntersector{T}) where T
    ray = vri.ray
    buf = vri.grid.buffer
    root_pos = _nano_root_pos(vri.grid)
    root_count = nano_root_count(vri.grid)
    entry_sz = _root_entry_size(T)

    roots = Tuple{Float64, Int}[]

    for i in 0:(root_count - 1)
        ep = root_pos + i * entry_sz
        is_child = _buf_load(UInt8, buf, ep + 12)
        is_child == 0x01 || continue
        i2_off = Int(_buf_load(UInt32, buf, ep + 13))
        origin = _buf_load_coord(buf, i2_off)
        aabb = AABB(
            SVec3d(Float64(origin.x), Float64(origin.y), Float64(origin.z)),
            SVec3d(Float64(origin.x) + 4096.0, Float64(origin.y) + 4096.0, Float64(origin.z) + 4096.0)
        )
        hit = intersect_bbox(ray, aabb)
        if hit !== nothing
            push!(roots, (hit[1], i2_off))
        end
    end

    sort!(roots, by=first)
    isempty(roots) && return nothing

    state = NanoVRIState{T}(roots, 0, nothing, 0, nothing, 0)
    _nano_vri_advance(buf, ray, state)
end

function Base.iterate(vri::NanoVolumeRayIntersector{T}, state::NanoVRIState{T}) where T
    _nano_vri_advance(vri.grid.buffer, vri.ray, state)
end

function _nano_vri_advance(buf::Vector{UInt8}, ray::Ray, state::NanoVRIState{T})::Union{Tuple{NanoLeafHit{T}, NanoVRIState{T}}, Nothing} where T
    while true
        # Phase 1: Drain current I1 DDA for leaf hits
        while state.i1_ndda !== nothing && node_dda_inside(state.i1_ndda)
            ndda = state.i1_ndda
            child_idx = node_dda_child_index(ndda)

            if _buf_mask_is_on(buf, state.i1_off + _I1_CMASK_OFF, child_idx)
                table_idx = _buf_count_on_before(buf, state.i1_off + _I1_CMASK_OFF,
                                                 state.i1_off + _I1_CPREFIX_OFF, child_idx)
                leaf_off = Int(_buf_load(UInt32, buf, state.i1_off + _I1_DATA_OFF + table_idx * 4))

                origin = _buf_load_coord(buf, leaf_off)
                s = Int32(8)
                bbox = BBox(origin, Coord(origin.x + s - Int32(1), origin.y + s - Int32(1), origin.z + s - Int32(1)))
                hit = intersect_bbox(ray, bbox)

                if hit !== nothing
                    t_enter, t_exit = hit
                    dda_step!(ndda.state)
                    return (NanoLeafHit{T}(t_enter, t_exit, leaf_off), state)
                end
            end

            dda_step!(ndda.state)
        end
        state.i1_ndda = nothing

        # Phase 2: Step I2 DDA to find next I1 child
        found_i1 = false
        while state.i2_ndda !== nothing && node_dda_inside(state.i2_ndda)
            ndda = state.i2_ndda
            child_idx = node_dda_child_index(ndda)

            if _buf_mask_is_on(buf, state.i2_off + _I2_CMASK_OFF, child_idx)
                table_idx = _buf_count_on_before(buf, state.i2_off + _I2_CMASK_OFF,
                                                 state.i2_off + _I2_CPREFIX_OFF, child_idx)
                i1_off = Int(_buf_load(UInt32, buf, state.i2_off + _I2_DATA_OFF + table_idx * 4))

                origin = _buf_load_coord(buf, i1_off)
                aabb = AABB(
                    SVec3d(Float64(origin.x), Float64(origin.y), Float64(origin.z)),
                    SVec3d(Float64(origin.x) + 128.0, Float64(origin.y) + 128.0, Float64(origin.z) + 128.0)
                )
                hit = intersect_bbox(ray, aabb)

                if hit !== nothing
                    tmin, _ = hit
                    state.i1_ndda = node_dda_init(ray, tmin, origin, Int32(16), Int32(8))
                    state.i1_off = i1_off
                    dda_step!(ndda.state)
                    found_i1 = true
                    break
                end
            end

            dda_step!(ndda.state)
        end

        if found_i1
            continue
        end

        state.i2_ndda = nothing

        # Phase 3: Advance to next root entry
        state.root_idx += 1
        state.root_idx > length(state.roots) && return nothing

        tmin, i2_off = state.roots[state.root_idx]
        origin = _buf_load_coord(buf, i2_off)
        state.i2_ndda = node_dda_init(ray, tmin, origin, Int32(32), Int32(128))
        state.i2_off = i2_off
    end
end
