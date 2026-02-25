# GridBuilder.jl - Build VDB grids from sparse voxel data

"""
    _build_mask(::Type{Mask{N,W}}, indices) -> Mask{N,W}

Build a mask with the specified 0-indexed bit positions set.
"""
function _build_mask(::Type{Mask{N,W}}, indices) where {N,W}
    words = zeros(UInt64, W)
    for idx in indices
        word_i = idx ÷ 64 + 1
        bit_i = idx % 64
        words[word_i] |= UInt64(1) << bit_i
    end
    Mask{N,W}(NTuple{W,UInt64}(words))
end

"""
    build_grid(data::Dict{Coord, T}, background::T;
               name::String="density",
               grid_class::GridClass=GRID_FOG_VOLUME,
               voxel_size::Float64=1.0) where T -> Grid{T}

Build a complete VDB Grid from a sparse dictionary of voxel coordinates to values.

The tree is constructed bottom-up:
1. Group voxels by leaf origin → build LeafNodes
2. Group leaves by Internal1 origin → build InternalNode1s
3. Group I1s by Internal2 origin → build InternalNode2s
4. Wrap I2s in a RootNode → Grid

# Arguments
- `data`: sparse voxel data mapping coordinates to values
- `background`: background value for the grid (value of unset voxels)
- `name`: grid name (default "density")
- `grid_class`: VDB grid class (default GRID_FOG_VOLUME)
- `voxel_size`: uniform voxel size for the transform (default 1.0)
"""
function build_grid(data::Dict{Coord, T}, background::T;
                    name::String="density",
                    grid_class::GridClass=GRID_FOG_VOLUME,
                    voxel_size::Float64=1.0) where T
    isempty(data) && return Grid{T}(name, grid_class,
        UniformScaleTransform(voxel_size),
        RootNode{T}(background, Dict{Coord, Union{InternalNode2{T}, Tile{T}}}()))

    # Step 1: Group voxels by leaf origin, build LeafNodes
    leaf_groups = Dict{Coord, Vector{Pair{Int, T}}}()  # origin → [(offset, value)]
    for (c, v) in data
        lo = leaf_origin(c)
        off = leaf_offset(c)
        push!(get!(Vector{Pair{Int,T}}, leaf_groups, lo), off => v)
    end

    leaf_nodes = Dict{Coord, LeafNode{T}}()
    for (origin, entries) in leaf_groups
        # Build values array (background-filled, then overwrite active)
        vals = fill(background, 512)
        bit_indices = Int[]
        for (off, v) in entries
            vals[off + 1] = v  # 0-indexed offset → 1-indexed array
            push!(bit_indices, off)
        end
        vmask = _build_mask(LeafMask, bit_indices)
        leaf_nodes[origin] = LeafNode{T}(origin, vmask, NTuple{512,T}(vals))
    end

    # Step 2: Group leaves by Internal1 origin, build InternalNode1s
    i1_groups = Dict{Coord, Vector{Pair{Int, LeafNode{T}}}}()  # i1_origin → [(child_idx, leaf)]
    for (lo, leaf) in leaf_nodes
        i1o = internal1_origin(lo)
        ci = internal1_child_index(lo)
        push!(get!(Vector{Pair{Int, LeafNode{T}}}, i1_groups, i1o), ci => leaf)
    end

    i1_nodes = Dict{Coord, InternalNode1{T}}()
    for (origin, entries) in i1_groups
        # Sort by child index so table order matches on_indices order
        sort!(entries; by=first)
        child_indices = [e.first for e in entries]
        cmask = _build_mask(Internal1Mask, child_indices)
        vmask = Internal1Mask()  # no tile values
        table = Union{LeafNode{T}, Tile{T}}[e.second for e in entries]
        i1_nodes[origin] = InternalNode1{T}(origin, cmask, vmask, table)
    end

    # Step 3: Group I1s by Internal2 origin, build InternalNode2s
    i2_groups = Dict{Coord, Vector{Pair{Int, InternalNode1{T}}}}()
    for (i1o, i1) in i1_nodes
        i2o = internal2_origin(i1o)
        ci = internal2_child_index(i1o)
        push!(get!(Vector{Pair{Int, InternalNode1{T}}}, i2_groups, i2o), ci => i1)
    end

    root_table = Dict{Coord, Union{InternalNode2{T}, Tile{T}}}()
    for (origin, entries) in i2_groups
        sort!(entries; by=first)
        child_indices = [e.first for e in entries]
        cmask = _build_mask(Internal2Mask, child_indices)
        vmask = Internal2Mask()  # no tile values
        table = Union{InternalNode1{T}, Tile{T}}[e.second for e in entries]
        root_table[origin] = InternalNode2{T}(origin, cmask, vmask, table)
    end

    # Step 4: Wrap in RootNode and Grid
    tree = RootNode{T}(background, root_table)
    transform = UniformScaleTransform(voxel_size)
    Grid{T}(name, grid_class, transform, tree)
end
