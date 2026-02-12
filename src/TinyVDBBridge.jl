# TinyVDBBridge.jl - Convert TinyVDB parsed data to Lyr tree types
#
# Enables the Lyr raytracer (Accessors, Interpolation, Ray, Render) to operate
# on data parsed by the TinyVDB sequential parser.
#
# Key subtlety: OpenVDB and Lyr use different linear index conventions.
#   OpenVDB: index = x * DIM² + y * DIM + z  (x in high bits)
#   Lyr:     index = x + y * DIM + z * DIM²  (x in low bits)
# The bridge transposes x↔z in masks, values, and child ordering during conversion.
#
# Usage:
#   vdb = TinyVDB.parse_tinyvdb("cube.vdb")
#   grid = convert_tinyvdb_grid(first(values(vdb.grids)))
#   pixels = render_image(grid, camera, 512, 512)

# ============================================================================
# Index convention transposition helpers
# ============================================================================

"""
    _transpose_xz(ovdb_idx::Int, log2dim::Int) -> Int

Transpose x↔z components of a linear index between OpenVDB and Lyr conventions.

OpenVDB: index = x * DIM² + y * DIM + z
Lyr:     index = x + y * DIM + z * DIM²

Given an OpenVDB index, returns the Lyr index for the same (x,y,z) voxel.
The operation is its own inverse (swapping x↔z twice = identity).
"""
function _transpose_xz(ovdb_idx::Int, log2dim::Int)::Int
    dim = 1 << log2dim
    dim2 = dim * dim
    z = ovdb_idx % dim
    y = (ovdb_idx ÷ dim) % dim
    x = ovdb_idx ÷ dim2
    # Lyr convention: x in low bits, z in high bits
    x + y * dim + z * dim2
end

"""
    _transpose_mask(m::TinyVDB.NodeMask, log2dim::Int, ::Type{Mask{N,W}}) -> Mask{N,W}

Convert a TinyVDB NodeMask to a Lyr Mask, transposing x↔z bit positions.
"""
function _transpose_mask(m::TinyVDB.NodeMask, log2dim::Int, ::Type{Mask{N,W}})::Mask{N,W} where {N,W}
    words = zeros(UInt64, W)
    for word_i in 1:length(m.words)
        word = m.words[word_i]
        while word != 0
            # Extract lowest set bit position within this word
            bit = trailing_zeros(word)
            ovdb_idx = (word_i - 1) * 64 + bit
            lyr_idx = _transpose_xz(ovdb_idx, log2dim)
            words[lyr_idx ÷ 64 + 1] |= UInt64(1) << (lyr_idx % 64)
            word &= word - 1  # Clear lowest set bit
        end
    end
    Mask{N,W}(NTuple{W, UInt64}(words))
end

"""
    _transpose_leaf_values(values::Vector{Float32}) -> NTuple{512, Float32}

Rearrange leaf values from OpenVDB index order to Lyr index order (transpose x↔z).
"""
function _transpose_leaf_values(values::Vector{Float32})::NTuple{512, Float32}
    result = Vector{Float32}(undef, 512)
    for ovdb_idx in 0:511
        lyr_idx = _transpose_xz(ovdb_idx, 3)
        result[lyr_idx + 1] = values[ovdb_idx + 1]
    end
    NTuple{512, Float32}(result)
end

# ============================================================================
# Type conversion functions
# ============================================================================

"""
    convert_tinyvdb_coord(c::TinyVDB.Coord) -> Coord

Convert a TinyVDB coordinate to a Lyr coordinate.
"""
function convert_tinyvdb_coord(c::TinyVDB.Coord)::Coord
    Coord(c.x, c.y, c.z)
end

"""
    convert_tinyvdb_mask(m::TinyVDB.NodeMask, ::Type{Mask{N,W}}) -> Mask{N,W}

Convert a TinyVDB NodeMask (mutable, Vector{UInt64}) to a Lyr Mask (immutable, NTuple).
Transposes x↔z bit positions to account for different linear index conventions.
"""
function convert_tinyvdb_mask(m::TinyVDB.NodeMask, ::Type{Mask{N,W}})::Mask{N,W} where {N,W}
    _transpose_mask(m, Int(m.log2dim), Mask{N,W})
end

"""
    convert_tinyvdb_leaf(leaf::TinyVDB.LeafNodeData, origin::Coord) -> LeafNode{Float32}

Convert a TinyVDB leaf to a Lyr LeafNode, transposing mask and values from
OpenVDB index convention to Lyr convention.
"""
function convert_tinyvdb_leaf(leaf::TinyVDB.LeafNodeData, origin::Coord)::LeafNode{Float32}
    value_mask = convert_tinyvdb_mask(leaf.value_mask, LeafMask)
    values = _transpose_leaf_values(leaf.values)
    LeafNode{Float32}(origin, value_mask, values)
end

"""
    convert_tinyvdb_internal1(node::TinyVDB.InternalNodeData, origin::Coord,
                              background::Float32) -> InternalNode1{Float32}

Convert a TinyVDB InternalNodeData (log2dim=4) to a Lyr InternalNode1.

Children are reordered by their transposed (Lyr-convention) bit positions so that
popcount-based table indexing works correctly.
"""
function convert_tinyvdb_internal1(node::TinyVDB.InternalNodeData, origin::Coord,
                                   background::Float32)::InternalNode1{Float32}
    child_mask = convert_tinyvdb_mask(node.child_mask, Internal1Mask)
    value_mask = convert_tinyvdb_mask(node.value_mask, Internal1Mask)

    n_children = count_on(child_mask)
    n_tiles = count_on(value_mask)
    table = Vector{Union{LeafNode{Float32}, Tile{Float32}}}(undef, n_children + n_tiles)

    # Transpose child indices and sort by Lyr-convention bit position
    transposed_children = [(_transpose_xz(Int(linear_idx), 4), child_data)
                           for (linear_idx, child_data) in node.children]
    sort!(transposed_children, by=first)

    for (i, (lyr_idx, child_data)) in enumerate(transposed_children)
        leaf_origin = child_origin_internal1(origin, lyr_idx)
        table[i] = convert_tinyvdb_leaf(child_data::TinyVDB.LeafNodeData, leaf_origin)
    end

    # Tiles after children
    for i in 1:n_tiles
        table[n_children + i] = Tile{Float32}(background, true)
    end

    InternalNode1{Float32}(origin, child_mask, value_mask, table)
end

"""
    convert_tinyvdb_internal2(node::TinyVDB.InternalNodeData, origin::Coord,
                              background::Float32) -> InternalNode2{Float32}

Convert a TinyVDB InternalNodeData (log2dim=5) to a Lyr InternalNode2.
"""
function convert_tinyvdb_internal2(node::TinyVDB.InternalNodeData, origin::Coord,
                                   background::Float32)::InternalNode2{Float32}
    child_mask = convert_tinyvdb_mask(node.child_mask, Internal2Mask)
    value_mask = convert_tinyvdb_mask(node.value_mask, Internal2Mask)

    n_children = count_on(child_mask)
    n_tiles = count_on(value_mask)
    table = Vector{Union{InternalNode1{Float32}, Tile{Float32}}}(undef, n_children + n_tiles)

    # Transpose child indices and sort by Lyr-convention bit position
    transposed_children = [(_transpose_xz(Int(linear_idx), 5), child_data)
                           for (linear_idx, child_data) in node.children]
    sort!(transposed_children, by=first)

    for (i, (lyr_idx, child_data)) in enumerate(transposed_children)
        i1_origin = child_origin_internal2(origin, lyr_idx)
        table[i] = convert_tinyvdb_internal1(child_data::TinyVDB.InternalNodeData, i1_origin, background)
    end

    # Tiles after children
    for i in 1:n_tiles
        table[n_children + i] = Tile{Float32}(background, true)
    end

    InternalNode2{Float32}(origin, child_mask, value_mask, table)
end

"""
    convert_tinyvdb_root(root::TinyVDB.RootNodeData) -> RootNode{Float32}

Convert a TinyVDB RootNodeData to a Lyr RootNode (Tree).
"""
function convert_tinyvdb_root(root::TinyVDB.RootNodeData)::RootNode{Float32}
    background = root.background
    table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}()

    # Root tiles
    for (tc, value, active) in root.tiles
        table[convert_tinyvdb_coord(tc)] = Tile{Float32}(value, active)
    end

    # Root children (I2 nodes)
    for (tc, i2_data) in root.children
        lyr_coord = convert_tinyvdb_coord(tc)
        table[lyr_coord] = convert_tinyvdb_internal2(i2_data, lyr_coord, background)
    end

    RootNode{Float32}(background, table)
end

"""
    convert_tinyvdb_grid(tg::TinyVDB.TinyGrid;
                         grid_class::GridClass=GRID_LEVEL_SET) -> Grid{Float32}

Convert a TinyVDB grid to a Lyr Grid, enabling use with Accessors, Interpolation,
Ray, and Render modules.

# Example
```julia
vdb = TinyVDB.parse_tinyvdb("cube.vdb")
grid = convert_tinyvdb_grid(first(values(vdb.grids)))
bbox = active_bounding_box(grid.tree)
pixels = render_image(grid, camera, 512, 512)
```
"""
function convert_tinyvdb_grid(tg::TinyVDB.TinyGrid;
                              grid_class::GridClass=GRID_LEVEL_SET)::Grid{Float32}
    tree = convert_tinyvdb_root(tg.root)
    transform = UniformScaleTransform(tg.voxel_size)
    Grid{Float32}(tg.name, grid_class, transform, tree)
end
