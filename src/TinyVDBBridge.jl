# TinyVDBBridge.jl - Convert TinyVDB parsed data to Lyr tree types
#
# Enables the Lyr raytracer (Accessors, Interpolation, Ray, Render) to operate
# on data parsed by the TinyVDB sequential parser.
#
# Both OpenVDB and Lyr use the same linear index convention:
#   index = x * DIM² + y * DIM + z  (x varies slowest)
# so no transposition is needed during conversion.
#
# Usage:
#   vdb = TinyVDB.parse_tinyvdb("cube.vdb")
#   grid = convert_tinyvdb_grid(first(values(vdb.grids)))
#   pixels = render_image(grid, camera, 512, 512)

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
Both use OpenVDB index convention, so bits are copied directly.
"""
function convert_tinyvdb_mask(m::TinyVDB.NodeMask, ::Type{Mask{N,W}})::Mask{N,W} where {N,W}
    Mask{N,W}(NTuple{W, UInt64}(m.words))
end

"""
    convert_tinyvdb_leaf(leaf::TinyVDB.LeafNodeData, origin::Coord) -> LeafNode{Float32}

Convert a TinyVDB leaf to a Lyr LeafNode.
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

Children are sorted by their linear index so that popcount-based table indexing
works correctly.
"""
function convert_tinyvdb_internal1(node::TinyVDB.InternalNodeData, origin::Coord,
                                   background::Float32)::InternalNode1{Float32}
    child_mask = convert_tinyvdb_mask(node.child_mask, Internal1Mask)
    value_mask = convert_tinyvdb_mask(node.value_mask, Internal1Mask)

    n_children = count_on(child_mask)
    n_tiles = count_on(value_mask)
    table = Vector{Union{LeafNode{Float32}, Tile{Float32}}}(undef, n_children + n_tiles)

    # Sort children by linear index for popcount-based table lookup
    sorted_children = sort(node.children, by=first)

    for (i, (linear_idx, child_data)) in enumerate(sorted_children)
        leaf_origin = child_origin_internal1(origin, Int(linear_idx))
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

    # Sort children by linear index for popcount-based table lookup
    sorted_children = sort(node.children, by=first)

    for (i, (linear_idx, child_data)) in enumerate(sorted_children)
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
    convert_tinyvdb_grid(tg::TinyVDB.TinyGrid) -> Grid{Float32}

Convert a TinyVDB grid to a Lyr Grid, enabling use with Accessors, Interpolation,
Ray, and Render modules. Grid class is derived from the grid's metadata.

# Example
```julia
vdb = TinyVDB.parse_tinyvdb("cube.vdb")
grid = convert_tinyvdb_grid(first(values(vdb.grids)))
bbox = active_bounding_box(grid.tree)
pixels = render_image(grid, camera, 512, 512)
```
"""
function convert_tinyvdb_grid(tg::TinyVDB.TinyGrid)::Grid{Float32}
    tree = convert_tinyvdb_root(tg.root)
    transform = UniformScaleTransform(tg.voxel_size)
    grid_class = parse_grid_class(tg.grid_class)
    Grid{Float32}(tg.name, grid_class, transform, tree)
end

"""
    convert_tinyvdb_file(tf::TinyVDB.TinyVDBFile) -> VDBFile

Convert an entire TinyVDBFile to a Lyr VDBFile, mapping header fields and
converting all grids (sorted by name).
"""
function convert_tinyvdb_file(tf::TinyVDB.TinyVDBFile)::VDBFile
    h = tf.header
    header = VDBHeader(
        h.file_version,
        h.major_version,
        h.minor_version,
        true,              # has_grid_offsets (TinyVDB requires it)
        ZipCodec(),        # compression (TinyVDB supports zip)
        false,             # active_mask_compression (per-grid in v222+)
        h.uuid
    )

    sorted_names = sort(collect(keys(tf.grids)))
    grids = Union{Grid{Float32}, Grid{Float64}, Grid{NTuple{3, Float32}}}[
        convert_tinyvdb_grid(tf.grids[name]) for name in sorted_names
    ]

    VDBFile(header, grids)
end

"""
    is_tinyvdb_compatible(bytes::Vector{UInt8}) -> Bool

Check if a VDB byte stream is compatible with the TinyVDB parser:
v222+, all grids are Tree_float_5_4_3, and no Blosc compression.

Returns false (rather than throwing) for invalid or incompatible data.
"""
function is_tinyvdb_compatible(bytes::Vector{UInt8})::Bool
    try
        header, pos = TinyVDB.read_header(bytes, 1)

        if header.file_version < 222
            return false
        end

        # Skip file-level metadata
        _, pos = TinyVDB.read_metadata(bytes, pos)

        # Read grid descriptors
        descriptors, _ = TinyVDB.read_grid_descriptors(bytes, pos)

        for (_, gd) in descriptors
            if gd.grid_type != "Tree_float_5_4_3"
                return false
            end
        end

        # Check per-grid compression for Blosc
        for (_, gd) in descriptors
            grid_pos = Int(gd.grid_pos) + 1
            flags, _ = TinyVDB.read_grid_compression(bytes, grid_pos, header.file_version)
            if (flags & TinyVDB.COMPRESS_BLOSC) != 0
                return false
            end
        end

        return true
    catch
        return false
    end
end
