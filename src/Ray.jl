# Ray.jl - Ray utilities for volume rendering

"""
    AABB

A floating-point axis-aligned bounding box for ray intersection tests.

# Fields
- `min::SVec3d` - Minimum corner
- `max::SVec3d` - Maximum corner
"""
struct AABB
    min::SVec3d
    max::SVec3d
end

"""
    AABB(bbox::BBox) -> AABB

Convert an integer `BBox` to a floating-point `AABB`.
"""
AABB(bbox::BBox) = AABB(
    SVec3d(Float64(bbox.min[1]), Float64(bbox.min[2]), Float64(bbox.min[3])),
    SVec3d(Float64(bbox.max[1]), Float64(bbox.max[2]), Float64(bbox.max[3]))
)

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
    intersect_bbox(ray::Ray, aabb::AABB) -> Union{Tuple{Float64, Float64}, Nothing}

Compute ray-box intersection using the slab method.
Returns (t_enter, t_exit) or `nothing` if no intersection.
"""
function intersect_bbox(ray::Ray, aabb::AABB)::Union{Tuple{Float64, Float64}, Nothing}
    t1 = (aabb.min - ray.origin) .* ray.inv_dir
    t2 = (aabb.max - ray.origin) .* ray.inv_dir

    # Replace NaN with appropriate bounds (NaN arises from 0*Inf when ray is
    # axis-aligned and origin sits exactly on a slab boundary)
    tmin_v = min.(t1, t2)
    tmax_v = max.(t1, t2)
    tmin_v = ifelse.(isnan.(tmin_v), -Inf, tmin_v)
    tmax_v = ifelse.(isnan.(tmax_v),  Inf, tmax_v)

    tmin = maximum(tmin_v)
    tmax = minimum(tmax_v)

    if tmax >= max(tmin, 0.0)
        return (max(tmin, 0.0), tmax)
    end

    nothing
end

"""
    intersect_bbox(ray::Ray, bbox::BBox) -> Union{Tuple{Float64, Float64}, Nothing}

Convenience overload that converts integer `BBox` to `AABB`.
"""
intersect_bbox(ray::Ray, bbox::BBox) = intersect_bbox(ray, AABB(bbox))

"""
    intersect_bbox(ray::Ray, bmin::SVec3d, bmax::SVec3d) -> Union{Tuple{Float64, Float64}, Nothing}

Convenience overload that constructs an `AABB` from min/max corners.
"""
intersect_bbox(ray::Ray, bmin::SVec3d, bmax::SVec3d) = intersect_bbox(ray, AABB(bmin, bmax))

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

Implemented via `VolumeRayIntersector` (hierarchical DDA). Results are
equivalent to the old brute-force implementation but O(leaves_hit) instead
of O(all_leaves).
"""
function intersect_leaves(ray::Ray, tree::Tree{T}) where T
    collect(VolumeRayIntersector(tree, ray))
end
