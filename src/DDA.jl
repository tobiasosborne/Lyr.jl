# DDA.jl - Amanatides-Woo 3D Digital Differential Analyzer

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

    # Entry point in world space
    p = ray.origin + tmin * ray.direction

    # Current voxel (floor to grid)
    ijk = Coord(
        Int32(floor(p[1] * inv_vs)),
        Int32(floor(p[2] * inv_vs)),
        Int32(floor(p[3] * inv_vs))
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
function dda_step!(state::DDAState)::Int
    tmax = state.tmax

    # Find axis with smallest tmax
    if tmax[1] < tmax[2]
        axis = tmax[1] < tmax[3] ? 1 : 3
    else
        axis = tmax[2] < tmax[3] ? 2 : 3
    end

    # Advance ijk and tmax along chosen axis
    ijk = state.ijk
    state.ijk = Coord(
        axis == 1 ? ijk[1] + state.step[1] : ijk[1],
        axis == 2 ? ijk[2] + state.step[2] : ijk[2],
        axis == 3 ? ijk[3] + state.step[3] : ijk[3]
    )
    state.tmax = SVec3d(
        axis == 1 ? tmax[1] + state.tdelta[1] : tmax[1],
        axis == 2 ? tmax[2] + state.tdelta[2] : tmax[2],
        axis == 3 ? tmax[3] + state.tdelta[3] : tmax[3]
    )

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
    node_dda_child_index(ndda::NodeDDA) -> Int

Compute the linear child index (0-based) for the current DDA position within the node.
Uses bit-shift logic matching `internal1_child_index`/`internal2_child_index`.
"""
function node_dda_child_index(ndda::NodeDDA)::Int
    # DDA ijk is in child-grid coordinates (index_space / child_size).
    # Convert to local child coordinates within this node.
    cs = ndda.child_size
    lx = ndda.state.ijk[1] - ndda.origin[1] ÷ cs
    ly = ndda.state.ijk[2] - ndda.origin[2] ÷ cs
    lz = ndda.state.ijk[3] - ndda.origin[3] ÷ cs
    dim = Int(ndda.dim)
    Int(lx) * dim * dim + Int(ly) * dim + Int(lz)
end

"""
    node_dda_inside(ndda::NodeDDA) -> Bool

Check if the DDA is still within the node's child grid.
"""
function node_dda_inside(ndda::NodeDDA)::Bool
    cs = ndda.child_size
    lx = ndda.state.ijk[1] - ndda.origin[1] ÷ cs
    ly = ndda.state.ijk[2] - ndda.origin[2] ÷ cs
    lz = ndda.state.ijk[3] - ndda.origin[3] ÷ cs
    dim = ndda.dim
    Int32(0) <= lx < dim && Int32(0) <= ly < dim && Int32(0) <= lz < dim
end

"""
    node_dda_voxel_origin(ndda::NodeDDA) -> Coord

Return the index-space origin of the current child voxel.
"""
function node_dda_voxel_origin(ndda::NodeDDA)::Coord
    cs = ndda.child_size
    Coord(ndda.state.ijk[1] * cs, ndda.state.ijk[2] * cs, ndda.state.ijk[3] * cs)
end
