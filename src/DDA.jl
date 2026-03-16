# DDA.jl - Amanatides-Woo 3D Digital Differential Analyzer

"""
    _safe_floor_int32(x::Float64) -> Int32

Floor `x` and convert to Int32, clamping to Int32 range for non-finite or out-of-range values.
Prevents `InexactError: Int32(Inf)` on edge-case rays (e.g., axis-parallel rays at volume boundaries).
"""
@inline function _safe_floor_int32(x::Float64)::Int32
    y = floor(x)
    isfinite(y) || return y != y ? Int32(0) : (y > 0.0 ? typemax(Int32) : typemin(Int32))
    y > 2.147483647e9 && return typemax(Int32)
    y < -2.147483648e9 && return typemin(Int32)
    Int32(y)
end

"""
    DDAState

State for the Amanatides-Woo 3D-DDA traversal.

# Fields
- `ijk::Coord` - Current voxel coordinate
- `step::SVector{3, Int32}` - Step direction per axis (+1 or -1)
- `tmax::SVec3d` - Next crossing time per axis (ray parameter)
- `tdelta::SVec3d` - Time between crossings per axis
"""
mutable struct DDAState
    ijk::Coord
    const step::SVector{3, Int32}
    tmax::SVec3d
    const tdelta::SVec3d
end

"""
    dda_init(ray::Ray, tmin::Float64, voxel_size::Float64=1.0) -> DDAState

Initialize DDA state from a ray, starting at parameter `tmin`.

Computes the initial voxel, step direction, tmax (ray parameter at next voxel
boundary per axis), and tdelta (ray parameter delta between voxel boundaries).
"""
function dda_init(ray::Ray, tmin::Float64, voxel_size::Float64=1.0)::DDAState
    inv_vs = 1.0 / voxel_size

    # Nudge tmin slightly inward to avoid landing exactly on a voxel boundary,
    # which causes floor() to place us in the wrong cell for negative directions.
    p = ray.origin + (tmin + 1e-9) * ray.direction

    # Current voxel (floor to grid)
    # Use _safe_floor_int32 to handle edge-case rays where position overflows Int32
    ijk = Coord(
        _safe_floor_int32(p[1] * inv_vs),
        _safe_floor_int32(p[2] * inv_vs),
        _safe_floor_int32(p[3] * inv_vs)
    )

    # Step direction per axis
    step = SVector{3, Int32}(
        ray.direction[1] >= 0.0 ? Int32(1) : Int32(-1),
        ray.direction[2] >= 0.0 ? Int32(1) : Int32(-1),
        ray.direction[3] >= 0.0 ? Int32(1) : Int32(-1)
    )

    # Time between voxel boundaries: voxel_size / |direction[i]|
    tdelta = SVec3d(
        voxel_size * abs(ray.inv_dir[1]),
        voxel_size * abs(ray.inv_dir[2]),
        voxel_size * abs(ray.inv_dir[3])
    )

    # Time to next voxel boundary per axis
    # boundary = (ijk[i] + (step[i]>0 ? 1 : 0)) * voxel_size
    # tmax[i] = (boundary - ray.origin[i]) * inv_dir[i]
    tmax = SVec3d(
        _initial_tmax(ray.origin[1], ray.inv_dir[1], ijk[1], step[1], voxel_size),
        _initial_tmax(ray.origin[2], ray.inv_dir[2], ijk[2], step[2], voxel_size),
        _initial_tmax(ray.origin[3], ray.inv_dir[3], ijk[3], step[3], voxel_size)
    )

    DDAState(ijk, step, tmax, tdelta)
end

function _initial_tmax(origin_i::Float64, inv_dir_i::Float64,
                       ijk_i::Int32, step_i::Int32, vs::Float64)::Float64
    if isinf(inv_dir_i)
        return Inf  # Ray parallel to this axis
    end
    boundary = Float64(step_i > 0 ? ijk_i + Int32(1) : ijk_i) * vs
    (boundary - origin_i) * inv_dir_i
end

"""
    dda_step!(state::DDAState) -> Int

Advance the DDA by one voxel. Returns the axis crossed (1, 2, or 3).
"""
@inline function dda_step!(state::DDAState)::Int
    tmax = state.tmax

    # Find axis with smallest tmax
    if tmax[1] < tmax[2]
        axis = tmax[1] < tmax[3] ? 1 : 3
    else
        axis = tmax[2] < tmax[3] ? 2 : 3
    end

    # Advance ijk and tmax along chosen axis — single indexed update
    ijk = state.ijk
    new_val = ijk[axis] + state.step[axis]
    state.ijk = axis == 1 ? Coord(new_val, ijk.y, ijk.z) :
                axis == 2 ? Coord(ijk.x, new_val, ijk.z) :
                            Coord(ijk.x, ijk.y, new_val)
    state.tmax = Base.setindex(tmax, tmax[axis] + state.tdelta[axis], axis)

    axis
end

# --- Node-level DDA ---

"""
    NodeDDA

DDA state scoped to a single VDB internal node. Steps through child slots
at `child_size` granularity and bounds-checks against the node's grid.

# Fields
- `state::DDAState` - Underlying DDA (voxel_size = child_size)
- `origin::Coord` - Node origin in index space
- `dim::Int32` - Node dimension (children per axis: 8, 16, or 32)
- `child_size::Int32` - Child coverage in voxels (1, 8, or 128)
- `log2cs::Int` - log2(child_size) for bit-shift index computation
"""
struct NodeDDA
    state::DDAState
    origin::Coord
    dim::Int32
    child_size::Int32
    log2cs::Int
end

"""
    node_dda_init(ray::Ray, tmin::Float64, origin::Coord, dim::Int32, child_size::Int32) -> NodeDDA

Initialize a node-level DDA. The DDA steps through child slots at `child_size` granularity.
`origin` is the node origin in index space, `dim` is children per axis (8, 16, or 32),
and `child_size` is the size of each child in voxels (1, 8, or 128).
"""
function node_dda_init(ray::Ray, tmin::Float64, origin::Coord,
                       dim::Int32, child_size::Int32)::NodeDDA
    state = dda_init(ray, tmin, Float64(child_size))
    log2cs = Int(trailing_zeros(child_size))
    NodeDDA(state, origin, dim, child_size, log2cs)
end

"""
    node_dda_query(ndda::NodeDDA) -> Tuple{Bool, Int}

Combined bounds check + child index computation. Returns `(inside, child_index)`.
Computes local coordinates once instead of duplicating across two functions.
"""
@inline function node_dda_query(ndda::NodeDDA)::Tuple{Bool, Int}
    cs = ndda.child_size
    lx = ndda.state.ijk[1] - ndda.origin[1] ÷ cs
    ly = ndda.state.ijk[2] - ndda.origin[2] ÷ cs
    lz = ndda.state.ijk[3] - ndda.origin[3] ÷ cs
    dim = ndda.dim
    inside = Int32(0) <= lx < dim && Int32(0) <= ly < dim && Int32(0) <= lz < dim
    idx = Int(lx) * Int(dim) * Int(dim) + Int(ly) * Int(dim) + Int(lz)
    (inside, idx)
end

# Convenience wrappers (kept for backward compatibility with VolumeHDDA/VRI)
@inline function node_dda_child_index(ndda::NodeDDA)::Int
    _, idx = node_dda_query(ndda)
    idx
end

@inline function node_dda_inside(ndda::NodeDDA)::Bool
    inside, _ = node_dda_query(ndda)
    inside
end

"""
    node_dda_voxel_origin(ndda::NodeDDA) -> Coord

Return the index-space origin of the current child voxel.
"""
function node_dda_voxel_origin(ndda::NodeDDA)::Coord
    cs = ndda.child_size
    Coord(ndda.state.ijk[1] * cs, ndda.state.ijk[2] * cs, ndda.state.ijk[3] * cs)
end

"""
    node_dda_cell_time(ndda::NodeDDA) -> Float64

Ray parameter at the next boundary crossing of the current cell.
This is the exit time of the current cell / entry time of the next.
"""
@inline node_dda_cell_time(ndda::NodeDDA)::Float64 = minimum(ndda.state.tmax)

# --- Hierarchical DDA ---

"""
    intersect_leaves_dda(ray::Ray, tree::Tree{T}) -> Vector{LeafIntersection{T}}

Hierarchical DDA traversal of a VDB tree. Returns leaf intersections in
front-to-back order. Uses DDA at each tree level to skip non-intersected nodes.

This replaces the brute-force `intersect_leaves` which tests every leaf.
"""
function intersect_leaves_dda(ray::Ray, tree::Tree{T}) where T
    results = LeafIntersection{T}[]

    for (root_key, entry) in tree.table
        if entry isa InternalNode2{T}
            _dda_internal2!(results, ray, entry)
        end
    end

    sort!(results, by=x -> x.t_enter)
    results
end

function _dda_internal2!(results::Vector{LeafIntersection{T}}, ray::Ray,
                         node::InternalNode2{T}) where T
    # AABB for this I2 node: origin to origin + 4096
    o = node.origin
    aabb = AABB(
        SVec3d(Float64(o[1]), Float64(o[2]), Float64(o[3])),
        SVec3d(Float64(o[1]) + 4096.0, Float64(o[2]) + 4096.0, Float64(o[3]) + 4096.0)
    )

    hit = intersect_bbox(ray, aabb)
    hit === nothing && return

    tmin, tmax = hit

    # DDA through 32³ child grid at stride 128
    ndda = node_dda_init(ray, tmin, o, Int32(32), Int32(128))

    while true
        inside, child_idx = node_dda_query(ndda)
        !inside && break

        if is_on(node.child_mask, child_idx)
            idx = count_on_before(node.child_mask, child_idx) + 1
            _dda_internal1!(results, ray, node.children[idx])
        end

        dda_step!(ndda.state)
    end
end

function _dda_internal1!(results::Vector{LeafIntersection{T}}, ray::Ray,
                         node::InternalNode1{T}) where T
    o = node.origin
    aabb = AABB(
        SVec3d(Float64(o[1]), Float64(o[2]), Float64(o[3])),
        SVec3d(Float64(o[1]) + 128.0, Float64(o[2]) + 128.0, Float64(o[3]) + 128.0)
    )

    hit = intersect_bbox(ray, aabb)
    hit === nothing && return

    tmin, tmax = hit

    # DDA through 16³ child grid at stride 8
    ndda = node_dda_init(ray, tmin, o, Int32(16), Int32(8))

    while true
        inside, child_idx = node_dda_query(ndda)
        !inside && break

        if is_on(node.child_mask, child_idx)
            idx = count_on_before(node.child_mask, child_idx) + 1
            _dda_leaf!(results, ray, node.children[idx])
        end

        dda_step!(ndda.state)
    end
end

function _dda_leaf!(results::Vector{LeafIntersection{T}}, ray::Ray,
                    leaf::LeafNode{T}) where T
    o = leaf.origin
    s = Int32(8)
    bbox = BBox(o, Coord(o[1] + s - Int32(1), o[2] + s - Int32(1), o[3] + s - Int32(1)))

    hit = intersect_bbox(ray, bbox)
    if hit !== nothing
        t_enter, t_exit = hit
        push!(results, LeafIntersection{T}(t_enter, t_exit, leaf))
    end
end

# --- VolumeRayIntersector: Lazy front-to-back leaf iteration ---

"""
    VolumeRayIntersector{T}

Lazy iterator yielding `LeafIntersection{T}` in front-to-back order via
hierarchical DDA traversal. Implements `Base.iterate` for use in for-loops
and with `first`, `collect`, etc.

Unlike `intersect_leaves_dda` which eagerly collects all hits, this iterator
yields one hit at a time, enabling early termination without allocating the
full result set.

# Example
```julia
for hit in VolumeRayIntersector(tree, ray)
    # process hit.leaf, hit.t_enter, hit.t_exit
end
```
"""
struct VolumeRayIntersector{T}
    tree::Tree{T}
    ray::Ray
end

Base.IteratorSize(::Type{<:VolumeRayIntersector}) = Base.SizeUnknown()
Base.eltype(::Type{VolumeRayIntersector{T}}) where T = LeafIntersection{T}

"""
    VRIState{T}

Mutable state for the `VolumeRayIntersector` state machine.
Tracks position at root, I2 (NodeDDA over 32³ grid), and I1 (NodeDDA over 16³ grid)
levels of the hierarchical DDA traversal.
"""
mutable struct VRIState{T}
    roots::Vector{Tuple{Float64, InternalNode2{T}}}
    root_idx::Int
    i2_ndda::Union{NodeDDA, Nothing}
    i2_node::Union{InternalNode2{T}, Nothing}
    i1_ndda::Union{NodeDDA, Nothing}
    i1_node::Union{InternalNode1{T}, Nothing}
end

function Base.iterate(vri::VolumeRayIntersector{T}) where T
    ray = vri.ray
    roots = Tuple{Float64, InternalNode2{T}}[]

    for (_, entry) in vri.tree.table
        if entry isa InternalNode2{T}
            o = entry.origin
            aabb = AABB(
                SVec3d(Float64(o[1]), Float64(o[2]), Float64(o[3])),
                SVec3d(Float64(o[1]) + 4096.0, Float64(o[2]) + 4096.0, Float64(o[3]) + 4096.0)
            )
            hit = intersect_bbox(ray, aabb)
            if hit !== nothing
                push!(roots, (hit[1], entry))
            end
        end
    end

    sort!(roots, by=first)
    isempty(roots) && return nothing

    state = VRIState{T}(roots, 0, nothing, nothing, nothing, nothing)
    _vri_advance(ray, state)
end

function Base.iterate(vri::VolumeRayIntersector{T}, state::VRIState{T}) where T
    _vri_advance(vri.ray, state)
end

"""
    _vri_advance(ray::Ray, state::VRIState{T}) -> Union{Tuple{LeafIntersection{T}, VRIState{T}}, Nothing}

Advance the VRI state machine to the next leaf intersection.

State machine phases:
1. Drain current I1 DDA for leaf hits
2. Step I2 DDA to find next I1 child with AABB hit
3. Advance to next pre-sorted root entry
"""
function _vri_advance(ray::Ray, state::VRIState{T})::Union{Tuple{LeafIntersection{T}, VRIState{T}}, Nothing} where T
    while true
        # Phase 1: Drain current I1 DDA for leaf hits
        while state.i1_ndda !== nothing
            ndda = state.i1_ndda
            inside, child_idx = node_dda_query(ndda)
            !inside && break

            if is_on(state.i1_node.child_mask, child_idx)
                idx = count_on_before(state.i1_node.child_mask, child_idx) + 1
                leaf = state.i1_node.children[idx]

                o = leaf.origin
                s = Int32(8)
                bbox = BBox(o, Coord(o[1] + s - Int32(1), o[2] + s - Int32(1), o[3] + s - Int32(1)))
                hit = intersect_bbox(ray, bbox)

                if hit !== nothing
                    t_enter, t_exit = hit
                    dda_step!(ndda.state)
                    return (LeafIntersection{T}(t_enter, t_exit, leaf), state)
                end
            end

            dda_step!(ndda.state)
        end
        state.i1_ndda = nothing
        state.i1_node = nothing

        # Phase 2: Step I2 DDA to find next I1 child with AABB hit
        found_i1 = false
        while state.i2_ndda !== nothing
            ndda = state.i2_ndda
            inside, child_idx = node_dda_query(ndda)
            !inside && break

            if is_on(state.i2_node.child_mask, child_idx)
                idx = count_on_before(state.i2_node.child_mask, child_idx) + 1
                i1_node = state.i2_node.children[idx]

                o = i1_node.origin
                aabb = AABB(
                    SVec3d(Float64(o[1]), Float64(o[2]), Float64(o[3])),
                    SVec3d(Float64(o[1]) + 128.0, Float64(o[2]) + 128.0, Float64(o[3]) + 128.0)
                )
                hit = intersect_bbox(ray, aabb)

                if hit !== nothing
                    tmin, _ = hit
                    state.i1_ndda = node_dda_init(ray, tmin, o, Int32(16), Int32(8))
                    state.i1_node = i1_node
                    dda_step!(ndda.state)
                    found_i1 = true
                    break
                end
            end

            dda_step!(ndda.state)
        end

        if found_i1
            continue  # Back to Phase 1
        end

        state.i2_ndda = nothing
        state.i2_node = nothing

        # Phase 3: Advance to next pre-sorted root entry
        state.root_idx += 1
        state.root_idx > length(state.roots) && return nothing

        tmin, i2_node = state.roots[state.root_idx]
        o = i2_node.origin
        state.i2_ndda = node_dda_init(ray, tmin, o, Int32(32), Int32(128))
        state.i2_node = i2_node
    end
end
