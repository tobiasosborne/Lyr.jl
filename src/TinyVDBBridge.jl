# TinyVDBBridge.jl - Convert TinyVDB parsed data to Lyr tree types
#
# Enables the Lyr raytracer (Accessors, Interpolation, Ray, Render) to operate
# on data parsed by the TinyVDB sequential parser.
#
# Usage:
#   vdb = TinyVDB.parse_tinyvdb("cube.vdb")
#   grid = convert_tinyvdb_grid(first(values(vdb.grids)))
#   pixels = render_image(grid, camera, 512, 512)

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
"""
function convert_tinyvdb_mask(m::TinyVDB.NodeMask, ::Type{Mask{N,W}})::Mask{N,W} where {N,W}
    Mask{N,W}(NTuple{W, UInt64}(m.words))
end

"""
    convert_tinyvdb_leaf(leaf::TinyVDB.LeafNodeData, origin::Coord) -> LeafNode{Float32}

Convert a TinyVDB leaf to a Lyr LeafNode, attaching the computed origin.
"""
function convert_tinyvdb_leaf(leaf::TinyVDB.LeafNodeData, origin::Coord)::LeafNode{Float32}
    value_mask = convert_tinyvdb_mask(leaf.value_mask, LeafMask)
    values = NTuple{512, Float32}(leaf.values)
    LeafNode{Float32}(origin, value_mask, values)
end

"""
    convert_tinyvdb_internal1(node::TinyVDB.InternalNodeData, origin::Coord,
                              background::Float32) -> InternalNode1{Float32}

Convert a TinyVDB InternalNodeData (log2dim=4) to a Lyr InternalNode1.

Table layout matches Lyr convention: children first (by ascending bit position),
then tiles (by ascending bit position in value_mask).
"""
function convert_tinyvdb_internal1(node::TinyVDB.InternalNodeData, origin::Coord,
                                   background::Float32)::InternalNode1{Float32}
    child_mask = convert_tinyvdb_mask(node.child_mask, Internal1Mask)
    value_mask = convert_tinyvdb_mask(node.value_mask, Internal1Mask)

    n_children = count_on(child_mask)
    n_tiles = count_on(value_mask)
    table = Vector{Union{LeafNode{Float32}, Tile{Float32}}}(undef, n_children + n_tiles)

    # Children first (already in ascending bit order from TinyVDB sequential parse)
    for (i, (linear_idx, child_data)) in enumerate(node.children)
        leaf_origin = child_origin_internal1(origin, Int(linear_idx))
        table[i] = convert_tinyvdb_leaf(child_data::TinyVDB.LeafNodeData, leaf_origin)
    end

    # Tiles after children (tile values not preserved by TinyVDB; use background)
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

    # Children first
    for (i, (linear_idx, child_data)) in enumerate(node.children)
        i1_origin = child_origin_internal2(origin, Int(linear_idx))
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
