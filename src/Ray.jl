# Ray.jl - Ray utilities for volume rendering

"""
    Ray

A ray defined by origin and direction.

# Fields
- `origin::SVec3d` - Ray origin
- `direction::SVec3d` - Ray direction (normalized)
- `inv_dir::SVec3d` - Precomputed inverse direction
"""
struct Ray
    origin::SVec3d
    direction::SVec3d
    inv_dir::SVec3d
end

"""
    _safe_inv_dir(dir::SVec3d) -> SVec3d

Compute inverse direction with copysign(Inf) for zero components.
"""
function _safe_inv_dir(dir::SVec3d)::SVec3d
    SVec3d(
        dir[1] == 0.0 ? copysign(Inf, dir[1]) : 1.0 / dir[1],
        dir[2] == 0.0 ? copysign(Inf, dir[2]) : 1.0 / dir[2],
        dir[3] == 0.0 ? copysign(Inf, dir[3]) : 1.0 / dir[3]
    )
end

"""
    Ray(origin::SVec3d, direction::SVec3d) -> Ray

Construct a ray from origin and direction. Direction is normalized.
"""
function Ray(origin::SVec3d, direction::SVec3d)
    len = sqrt(direction[1]^2 + direction[2]^2 + direction[3]^2)
    dir = direction / len
    Ray(origin, dir, _safe_inv_dir(dir))
end

# Convenience: construct from NTuples
Ray(origin::NTuple{3, Float64}, direction::NTuple{3, Float64}) =
    Ray(SVec3d(origin...), SVec3d(direction...))

"""
    intersect_bbox(ray::Ray, bbox::BBox) -> Union{Tuple{Float64, Float64}, Nothing}

Compute ray-box intersection using the slab method.
Returns (t_enter, t_exit) or `nothing` if no intersection.
"""
function intersect_bbox(ray::Ray, bbox::BBox)::Union{Tuple{Float64, Float64}, Nothing}
    bmin = SVec3d(Float64(bbox.min[1]), Float64(bbox.min[2]), Float64(bbox.min[3]))
    bmax = SVec3d(Float64(bbox.max[1]), Float64(bbox.max[2]), Float64(bbox.max[3]))

    t1 = (bmin - ray.origin) .* ray.inv_dir
    t2 = (bmax - ray.origin) .* ray.inv_dir

    tmin_v = min.(t1, t2)
    tmax_v = max.(t1, t2)

    tmin = maximum(tmin_v)
    tmax = minimum(tmax_v)

    if tmax >= max(tmin, 0.0)
        return (max(tmin, 0.0), tmax)
    end

    nothing
end

"""
    LeafIntersection{T}

Result of a ray-leaf intersection.

# Fields
- `t_enter::Float64` - Entry parameter
- `t_exit::Float64` - Exit parameter
- `leaf::LeafNode{T}` - The intersected leaf
"""
struct LeafIntersection{T}
    t_enter::Float64
    t_exit::Float64
    leaf::LeafNode{T}
end

"""
    intersect_leaves(ray::Ray, tree::Tree{T}) -> Vector{LeafIntersection{T}}

Return all leaves the ray passes through, sorted by entry time.
Each `LeafIntersection{T}` contains `t_enter`, `t_exit`, and `leaf` fields.
"""
function intersect_leaves(ray::Ray, tree::Tree{T}) where T
    # Collect all leaf intersections
    intersections = LeafIntersection{T}[]

    for (_, entry) in tree.table
        if entry isa InternalNode2{T}
            _intersect_internal2!(intersections, ray, entry)
        end
    end

    # Sort by entry time
    sort!(intersections, by=x -> x.t_enter)

    intersections
end

function _intersect_internal2!(intersections::Vector{LeafIntersection{T}}, ray::Ray, node::InternalNode2{T}) where T
    # Check if ray intersects this node's bounding box
    node_size = Int32(4096)  # 8 * 16 * 32
    bbox = BBox(node.origin, Coord(node.origin[1] + node_size - Int32(1),
                                    node.origin[2] + node_size - Int32(1),
                                    node.origin[3] + node_size - Int32(1)))

    if intersect_bbox(ray, bbox) === nothing
        return
    end

    # Check children
    for (i, _) in enumerate(on_indices(node.child_mask))
        child = node.table[i]::InternalNode1{T}
        _intersect_internal1!(intersections, ray, child)
    end
end

function _intersect_internal1!(intersections::Vector{LeafIntersection{T}}, ray::Ray, node::InternalNode1{T}) where T
    # Check if ray intersects this node's bounding box
    node_size = Int32(128)  # 8 * 16
    bbox = BBox(node.origin, Coord(node.origin[1] + node_size - Int32(1),
                                    node.origin[2] + node_size - Int32(1),
                                    node.origin[3] + node_size - Int32(1)))

    if intersect_bbox(ray, bbox) === nothing
        return
    end

    # Check leaves
    for (i, _) in enumerate(on_indices(node.child_mask))
        leaf = node.table[i]::LeafNode{T}
        _intersect_leaf!(intersections, ray, leaf)
    end
end

function _intersect_leaf!(intersections::Vector{LeafIntersection{T}}, ray::Ray, leaf::LeafNode{T}) where T
    leaf_size = Int32(8)
    bbox = BBox(leaf.origin, Coord(leaf.origin[1] + leaf_size - Int32(1),
                                    leaf.origin[2] + leaf_size - Int32(1),
                                    leaf.origin[3] + leaf_size - Int32(1)))

    result = intersect_bbox(ray, bbox)
    if result !== nothing
        t_enter, t_exit = result
        push!(intersections, LeafIntersection{T}(t_enter, t_exit, leaf))
    end
end
