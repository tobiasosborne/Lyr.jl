# Ray.jl — Ray types, AABB intersection, and leaf-ray intersection for volume rendering

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
    len = norm(direction)
    dir = direction / len
    Ray(origin, dir, _safe_inv_dir(dir))
end

"""Construct a Ray from origin and ALREADY-NORMALIZED direction (skips norm/div)."""
@inline Ray_prenorm(origin::SVec3d, dir::SVec3d) = Ray(origin, dir, _safe_inv_dir(dir))

# Convenience: construct from NTuples
Ray(origin::NTuple{3, Float64}, direction::NTuple{3, Float64}) =
    Ray(SVec3d(origin...), SVec3d(direction...))

"""
    intersect_bbox(ray::Ray, aabb::AABB) -> Union{Tuple{Float64, Float64}, Nothing}

Compute ray-box intersection using the slab method.
Returns (t_enter, t_exit) or `nothing` if no intersection.
"""
@inline function intersect_bbox(ray::Ray, aabb::AABB)::Union{Tuple{Float64, Float64}, Nothing}
    # Scalar slab test — no intermediate SVector allocations.
    # NaN-safe min/max: if a is NaN, return b (conservative bound)
    @inline _nmin(a, b) = a < b ? a : b
    @inline _nmax(a, b) = a > b ? a : b

    ox, oy, oz = ray.origin[1], ray.origin[2], ray.origin[3]
    idx, idy, idz = ray.inv_dir[1], ray.inv_dir[2], ray.inv_dir[3]
    bmin_x, bmin_y, bmin_z = aabb.min[1], aabb.min[2], aabb.min[3]
    bmax_x, bmax_y, bmax_z = aabb.max[1], aabb.max[2], aabb.max[3]

    t1x = (bmin_x - ox) * idx
    t2x = (bmax_x - ox) * idx
    tmin = _nmin(t1x, t2x)
    tmax = _nmax(t1x, t2x)

    t1y = (bmin_y - oy) * idy
    t2y = (bmax_y - oy) * idy
    tmin = _nmax(tmin, _nmin(t1y, t2y))
    tmax = _nmin(tmax, _nmax(t1y, t2y))

    t1z = (bmin_z - oz) * idz
    t2z = (bmax_z - oz) * idz
    tmin = _nmax(tmin, _nmin(t1z, t2z))
    tmax = _nmin(tmax, _nmax(t1z, t2z))

    # Handle NaN from 0*Inf: _nmin/_nmax return the non-NaN operand,
    # so NaN slabs are effectively ignored (infinite extent on that axis).
    # Final check: if tmin or tmax are NaN here, the >= comparison returns false.
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
