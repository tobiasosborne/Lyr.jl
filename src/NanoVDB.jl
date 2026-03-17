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

# Header layout: each field derived from previous — single source of truth.
# Positions are 1-indexed byte offsets into the buffer.
#   [1] magic(4) [5] version(4) [9] value_size(4) [13] background(sizeof(T))
#   bbox_min(12) bbox_max(12) root_count(4) i2_count(4) i1_count(4) leaf_count(4)
#   root_pos(4) i2_pos(4) i1_pos(4) leaf_pos(4)
@inline _header_background_pos(::Type{T}) where T = 13
@inline _header_bbox_min_pos(::Type{T})   where T = _header_background_pos(T) + sizeof(T)
@inline _header_bbox_max_pos(::Type{T})   where T = _header_bbox_min_pos(T) + 12
@inline _header_root_count_pos(::Type{T}) where T = _header_bbox_max_pos(T) + 12
@inline _header_i2_count_pos(::Type{T})   where T = _header_root_count_pos(T) + 4
@inline _header_i1_count_pos(::Type{T})   where T = _header_i2_count_pos(T) + 4
@inline _header_leaf_count_pos(::Type{T}) where T = _header_i1_count_pos(T) + 4
@inline _header_root_pos_pos(::Type{T})   where T = _header_leaf_count_pos(T) + 4
@inline _header_i2_pos_pos(::Type{T})     where T = _header_root_pos_pos(T) + 4
@inline _header_i1_pos_pos(::Type{T})     where T = _header_i2_pos_pos(T) + 4
@inline _header_leaf_pos_pos(::Type{T})   where T = _header_i1_pos_pos(T) + 4
@inline _header_size(::Type{T})           where T = _header_leaf_pos_pos(T) + 3  # last byte of leaf_pos UInt32

# ──────────────────────────────────────────────────────────────────────────────
# Header accessors
# ──────────────────────────────────────────────────────────────────────────────

function nano_background(grid::NanoGrid{T})::T where T
    _buf_load(T, grid.buffer, _header_background_pos(T))
end

function nano_bbox(grid::NanoGrid{T})::BBox where T
    bmin = _buf_load_coord(grid.buffer, _header_bbox_min_pos(T))
    bmax = _buf_load_coord(grid.buffer, _header_bbox_max_pos(T))
    BBox(bmin, bmax)
end

function nano_root_count(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, _header_root_count_pos(T)))
end

function nano_i2_count(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, _header_i2_count_pos(T)))
end

function nano_i1_count(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, _header_i1_count_pos(T)))
end

function nano_leaf_count(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, _header_leaf_count_pos(T)))
end

function _nano_root_pos(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, _header_root_pos_pos(T)))
end

function _nano_i2_pos(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, _header_i2_pos_pos(T)))
end

function _nano_i1_pos(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, _header_i1_pos_pos(T)))
end

function _nano_leaf_pos(grid::NanoGrid{T})::Int where T
    Int(_buf_load(UInt32, grid.buffer, _header_leaf_pos_pos(T)))
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

# ── Node level types for parameterized internal views ──
abstract type NodeLevel end
struct Level1 <: NodeLevel end  # I1: 16³, 64-word masks
struct Level2 <: NodeLevel end  # I2: 32³, 512-word masks

"""
    NanoInternalView{T, L<:NodeLevel}

Parameterized view into an internal node (I1 or I2) in the NanoGrid buffer.
Level1 = 64-word masks (I1), Level2 = 512-word masks (I2).
"""
struct NanoInternalView{T, L<:NodeLevel}
    buf::Vector{UInt8}
    offset::Int
end

const NanoI1View{T} = NanoInternalView{T, Level1}
const NanoI2View{T} = NanoInternalView{T, Level2}

# ── I1 offset constants (64-word masks) ──
const _I1_CMASK_OFF = 12
const _I1_CPREFIX_OFF = 12 + 64 * 8         # 524
const _I1_VMASK_OFF = 12 + 64 * 8 + 64 * 4  # 780
const _I1_VPREFIX_OFF = _I1_VMASK_OFF + 64 * 8  # 1292
const _I1_CHILDCOUNT_OFF = _I1_VPREFIX_OFF + 64 * 4  # 1548
const _I1_TILECOUNT_OFF = _I1_CHILDCOUNT_OFF + 4  # 1552
const _I1_DATA_OFF = _I1_TILECOUNT_OFF + 4  # 1556

# ── I2 offset constants (512-word masks) ──
const _I2_CMASK_OFF = 12
const _I2_CPREFIX_OFF = 12 + 512 * 8          # 4108
const _I2_VMASK_OFF = 12 + 512 * 8 + 512 * 4  # 6156
const _I2_VPREFIX_OFF = _I2_VMASK_OFF + 512 * 8  # 10252
const _I2_CHILDCOUNT_OFF = _I2_VPREFIX_OFF + 512 * 4  # 12300
const _I2_TILECOUNT_OFF = _I2_CHILDCOUNT_OFF + 4  # 12304
const _I2_DATA_OFF = _I2_TILECOUNT_OFF + 4  # 12308

# ── Level-dispatched offset accessors ──
@inline _cmask_off(::Type{Level1}) = _I1_CMASK_OFF
@inline _cmask_off(::Type{Level2}) = _I2_CMASK_OFF
@inline _cprefix_off(::Type{Level1}) = _I1_CPREFIX_OFF
@inline _cprefix_off(::Type{Level2}) = _I2_CPREFIX_OFF
@inline _vmask_off(::Type{Level1}) = _I1_VMASK_OFF
@inline _vmask_off(::Type{Level2}) = _I2_VMASK_OFF
@inline _vprefix_off(::Type{Level1}) = _I1_VPREFIX_OFF
@inline _vprefix_off(::Type{Level2}) = _I2_VPREFIX_OFF
@inline _childcount_off(::Type{Level1}) = _I1_CHILDCOUNT_OFF
@inline _childcount_off(::Type{Level2}) = _I2_CHILDCOUNT_OFF
@inline _tilecount_off(::Type{Level1}) = _I1_TILECOUNT_OFF
@inline _tilecount_off(::Type{Level2}) = _I2_TILECOUNT_OFF
@inline _data_off(::Type{Level1}) = _I1_DATA_OFF
@inline _data_off(::Type{Level2}) = _I2_DATA_OFF

# ── Unified methods for NanoInternalView{T, L} ──
@inline function nano_origin(v::NanoInternalView)::Coord
    _buf_load_coord(v.buf, v.offset)
end

@inline function nano_child_count(v::NanoInternalView{T, L})::Int where {T, L}
    Int(_buf_load(UInt32, v.buf, v.offset + _childcount_off(L)))
end

@inline function nano_tile_count(v::NanoInternalView{T, L})::Int where {T, L}
    Int(_buf_load(UInt32, v.buf, v.offset + _tilecount_off(L)))
end

@inline function nano_has_child(v::NanoInternalView{T, L}, idx::Int)::Bool where {T, L}
    _buf_mask_is_on(v.buf, v.offset + _cmask_off(L), idx)
end

@inline function nano_has_tile(v::NanoInternalView{T, L}, idx::Int)::Bool where {T, L}
    !nano_has_child(v, idx) &&
    _buf_mask_is_on(v.buf, v.offset + _vmask_off(L), idx)
end

@inline function nano_child_offset(v::NanoInternalView{T, L}, idx::Int)::Int where {T, L}
    table_idx = _buf_count_on_before(v.buf, v.offset + _cmask_off(L),
                                     v.offset + _cprefix_off(L), idx)
    Int(_buf_load(UInt32, v.buf, v.offset + _data_off(L) + table_idx * 4))
end

@inline function nano_tile_value(v::NanoInternalView{T, L}, idx::Int)::T where {T, L}
    cc = nano_child_count(v)
    tile_idx = _buf_count_on_before(v.buf, v.offset + _vmask_off(L),
                                    v.offset + _vprefix_off(L), idx)
    tile_data_pos = v.offset + _data_off(L) + cc * 4
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

            for node1 in node2.children
                push!(i1_nodes, node1)
                i1_index[objectid(node1)] = length(i1_nodes)

                for leaf in node1.children
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
    _buf_store!(buf, _header_background_pos(T), tree.background)

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
    _buf_store_coord!(buf, _header_bbox_min_pos(T), bmin)
    _buf_store_coord!(buf, _header_bbox_max_pos(T), bmax)

    _buf_store!(buf, _header_root_count_pos(T), UInt32(root_count))
    _buf_store!(buf, _header_i2_count_pos(T),   UInt32(i2_count))
    _buf_store!(buf, _header_i1_count_pos(T),   UInt32(i1_count))
    _buf_store!(buf, _header_leaf_count_pos(T),  UInt32(lf_count))
    _buf_store!(buf, _header_root_pos_pos(T),   UInt32(root_section_pos))
    _buf_store!(buf, _header_i2_pos_pos(T),     UInt32(i2_section_pos))
    _buf_store!(buf, _header_i1_pos_pos(T),     UInt32(i1_section_pos))
    _buf_store!(buf, _header_leaf_pos_pos(T),   UInt32(leaf_section_pos))

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
        for node1 in node2.children
            idx = i1_index[objectid(node1)]
            _buf_store!(buf, p, UInt32(i1_offsets[idx]))
            p += 4
        end

        # Tile values
        for tile in node2.tiles
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
        for leaf in node1.children
            idx = leaf_index[objectid(leaf)]
            leaf_off = leaf_section_pos + (idx - 1) * leaf_sz
            _buf_store!(buf, p, UInt32(leaf_off))
            p += 4
        end

        # Tile values
        for tile in node1.tiles
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

"""Reset the accessor cache so it can be reused for a new ray/query."""
@inline function reset!(acc::NanoValueAccessor)
    acc.leaf_offset = 0
    acc.i1_offset = 0
    acc.i2_offset = 0
    nothing
end

@inline function get_value(acc::NanoValueAccessor{T}, c::Coord)::T where T
    buf = acc.grid.buffer

    # Level 0: cached leaf
    @inbounds if acc.leaf_offset != 0 && leaf_origin(c) == acc.leaf_origin
        offset = leaf_offset(c)
        return _buf_load(T, buf, acc.leaf_offset + _LEAF_VALUES_OFF + offset * sizeof(T))
    end

    # Level 1: cached I1
    @inbounds if acc.i1_offset != 0 && internal1_origin(c) == acc.i1_origin
        return _nano_get_from_i1(acc, acc.i1_offset, c)
    end

    # Level 2: cached I2
    @inbounds if acc.i2_offset != 0 && internal2_origin(c) == acc.i2_origin
        return _nano_get_from_i2(acc, acc.i2_offset, c)
    end

    # Full traversal
    return _nano_get_from_root(acc, c)
end

"""
    get_value_trilinear(acc::NanoValueAccessor{T}, pos::SVec3d) -> Float64

Trilinear interpolation through a NanoGrid. Samples the 8 surrounding
voxels and lerps based on fractional position.
"""
@inline function get_value_trilinear(acc::NanoValueAccessor{T}, pos::SVec3d)::Float64 where T
    x0 = floor(Int32, pos[1])
    y0 = floor(Int32, pos[2])
    z0 = floor(Int32, pos[3])

    u = pos[1] - Float64(x0)
    v = pos[2] - Float64(y0)
    w = pos[3] - Float64(z0)

    # Fast path: all 8 corners in same leaf (true ~70-85% of samples)
    # A leaf is 8x8x8 voxels. If none of x0,y0,z0 are at position 7 within
    # their leaf, then (x0+1,y0+1,z0+1) is still in the same leaf.
    if (x0 & Int32(7)) != Int32(7) && (y0 & Int32(7)) != Int32(7) && (z0 & Int32(7)) != Int32(7)
        # Ensure leaf is cached
        c0 = Coord(x0, y0, z0)
        lo = leaf_origin(c0)
        if acc.leaf_offset == 0 || lo != acc.leaf_origin
            get_value(acc, c0)  # populates leaf cache
        end

        leaf_off = acc.leaf_offset
        if leaf_off != 0
            buf = acc.grid.buffer
            # leaf_offset layout: offset = 64*lx + 8*ly + lz (0-based)
            base = leaf_offset(c0)
            vbase = leaf_off + _LEAF_VALUES_OFF
            szT = sizeof(T)
            @inbounds begin
                c000 = Float64(_buf_load(T, buf, vbase + base * szT))
                c100 = Float64(_buf_load(T, buf, vbase + (base + 64) * szT))
                c010 = Float64(_buf_load(T, buf, vbase + (base + 8) * szT))
                c110 = Float64(_buf_load(T, buf, vbase + (base + 72) * szT))
                c001 = Float64(_buf_load(T, buf, vbase + (base + 1) * szT))
                c101 = Float64(_buf_load(T, buf, vbase + (base + 65) * szT))
                c011 = Float64(_buf_load(T, buf, vbase + (base + 9) * szT))
                c111 = Float64(_buf_load(T, buf, vbase + (base + 73) * szT))
            end

            c00 = c000 + u * (c100 - c000)
            c10 = c010 + u * (c110 - c010)
            c01 = c001 + u * (c101 - c001)
            c11 = c011 + u * (c111 - c011)
            c0_ = c00 + v * (c10 - c00)
            c1_ = c01 + v * (c11 - c01)
            return c0_ + w * (c1_ - c0_)
        end
    end

    # Slow path: crosses leaf boundary — go through accessor cache for each corner
    c000 = Float64(get_value(acc, coord(x0,     y0,     z0)))
    c100 = Float64(get_value(acc, coord(x0 + 1, y0,     z0)))
    c010 = Float64(get_value(acc, coord(x0,     y0 + 1, z0)))
    c110 = Float64(get_value(acc, coord(x0 + 1, y0 + 1, z0)))
    c001 = Float64(get_value(acc, coord(x0,     y0,     z0 + 1)))
    c101 = Float64(get_value(acc, coord(x0 + 1, y0,     z0 + 1)))
    c011 = Float64(get_value(acc, coord(x0,     y0 + 1, z0 + 1)))
    c111 = Float64(get_value(acc, coord(x0 + 1, y0 + 1, z0 + 1)))

    c00 = c000 + u * (c100 - c000)
    c10 = c010 + u * (c110 - c010)
    c01 = c001 + u * (c101 - c001)
    c11 = c011 + u * (c111 - c011)
    c0_ = c00 + v * (c10 - c00)
    c1_ = c01 + v * (c11 - c01)
    c0_ + w * (c1_ - c0_)
end

@inline function _nano_get_from_root(acc::NanoValueAccessor{T}, c::Coord)::T where T
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

@inline function _nano_get_from_i2(acc::NanoValueAccessor{T}, i2_off::Int, c::Coord)::T where T
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

@inline function _nano_get_from_i1(acc::NanoValueAccessor{T}, i1_off::Int, c::Coord)::T where T
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
