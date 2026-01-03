# Ray.jl - Ray utilities for volume rendering

"""
    Ray

A ray defined by origin and direction.

# Fields
- `origin::NTuple{3, Float64}` - Ray origin
- `direction::NTuple{3, Float64}` - Ray direction (normalized)
- `inv_dir::NTuple{3, Float64}` - Precomputed inverse direction
"""
struct Ray
    origin::NTuple{3, Float64}
    direction::NTuple{3, Float64}
    inv_dir::NTuple{3, Float64}
end

"""
    Ray(origin::NTuple{3, Float64}, direction::NTuple{3, Float64}) -> Ray

Construct a ray from origin and direction. Direction is normalized.
"""
function Ray(origin::NTuple{3, Float64}, direction::NTuple{3, Float64})
    # Normalize direction
    len = sqrt(direction[1]^2 + direction[2]^2 + direction[3]^2)
    dir = (direction[1] / len, direction[2] / len, direction[3] / len)

    # Compute inverse direction (handle zeros carefully)
    inv_dir = (
        dir[1] == 0.0 ? copysign(Inf, dir[1]) : 1.0 / dir[1],
        dir[2] == 0.0 ? copysign(Inf, dir[2]) : 1.0 / dir[2],
        dir[3] == 0.0 ? copysign(Inf, dir[3]) : 1.0 / dir[3]
    )

    Ray(origin, dir, inv_dir)
end

"""
    intersect_bbox(ray::Ray, bbox::BBox) -> Union{Tuple{Float64, Float64}, Nothing}

Compute ray-box intersection using the slab method.
Returns (t_enter, t_exit) or `nothing` if no intersection.
"""
function intersect_bbox(ray::Ray, bbox::BBox)::Union{Tuple{Float64, Float64}, Nothing}
    # Convert bbox coords to Float64
    bmin = (Float64(bbox.min[1]), Float64(bbox.min[2]), Float64(bbox.min[3]))
    bmax = (Float64(bbox.max[1]), Float64(bbox.max[2]), Float64(bbox.max[3]))

    # Compute intersections with each slab
    t1 = (bmin[1] - ray.origin[1]) * ray.inv_dir[1]
    t2 = (bmax[1] - ray.origin[1]) * ray.inv_dir[1]
    tmin = min(t1, t2)
    tmax = max(t1, t2)

    t1 = (bmin[2] - ray.origin[2]) * ray.inv_dir[2]
    t2 = (bmax[2] - ray.origin[2]) * ray.inv_dir[2]
    tmin = max(tmin, min(t1, t2))
    tmax = min(tmax, max(t1, t2))

    t1 = (bmin[3] - ray.origin[3]) * ray.inv_dir[3]
    t2 = (bmax[3] - ray.origin[3]) * ray.inv_dir[3]
    tmin = max(tmin, min(t1, t2))
    tmax = min(tmax, max(t1, t2))

    # Check if valid intersection
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
    intersect_leaves(ray::Ray, tree::Tree{T})

Return an iterator over all leaves the ray passes through.
Yields (t_enter, t_exit, leaf) for each intersection, sorted by t_enter.
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
    bbox = BBox(node.origin, (node.origin[1] + node_size - Int32(1),
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
    bbox = BBox(node.origin, (node.origin[1] + node_size - Int32(1),
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
    bbox = BBox(leaf.origin, (leaf.origin[1] + leaf_size - Int32(1),
                               leaf.origin[2] + leaf_size - Int32(1),
                               leaf.origin[3] + leaf_size - Int32(1)))

    result = intersect_bbox(ray, bbox)
    if result !== nothing
        t_enter, t_exit = result
        push!(intersections, LeafIntersection{T}(t_enter, t_exit, leaf))
    end
end
