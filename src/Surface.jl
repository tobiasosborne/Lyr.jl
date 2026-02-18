# Surface.jl - Level set surface finding via DDA + zero crossing
#
# Replaces sphere_trace with the correct approach: DDA voxel traversal within
# each leaf, reading SDF values directly from leaf.values (O(1)), detecting
# sign changes, and bisecting for sub-voxel precision.

"""
    SurfaceHit

Result of a ray-surface intersection via DDA zero-crossing detection.

# Fields
- `t::Float64` - Ray parameter (index-space)
- `position::SVec3d` - World-space hit point
- `normal::SVec3d` - World-space surface normal (unit)
"""
struct SurfaceHit
    t::Float64
    position::SVec3d
    normal::SVec3d
end

"""
    _voxel_in_leaf(ijk::Coord, leaf_origin::Coord) -> Bool

Check if voxel coordinate `ijk` lies within the 8x8x8 leaf starting at `leaf_origin`.
"""
function _voxel_in_leaf(ijk::Coord, leaf_origin::Coord)::Bool
    dx = ijk.x - leaf_origin.x
    dy = ijk.y - leaf_origin.y
    dz = ijk.z - leaf_origin.z
    Int32(0) <= dx < Int32(8) &&
    Int32(0) <= dy < Int32(8) &&
    Int32(0) <= dz < Int32(8)
end

"""
    _to_index_ray(transform::AbstractTransform, world_ray::Ray) -> Ray

Transform a world-space ray to index-space. Adds a tiny epsilon offset on axes
perpendicular to the ray direction to avoid landing exactly on node boundaries,
which causes NaN in AABB intersection (0.0 * Inf = NaN).
"""
function _to_index_ray(transform::AbstractTransform, world_ray::Ray)::Ray
    idx_origin = world_to_index_float(transform, world_ray.origin)
    # Transform a second point to get direction in index space
    far_point = world_ray.origin + world_ray.direction
    idx_far = world_to_index_float(transform, far_point)
    idx_dir = idx_far - idx_origin

    # Nudge origin off exact integer boundaries for perpendicular axes
    eps = 1e-6
    nudged = SVec3d(
        abs(idx_dir[1]) < 1e-10 ? idx_origin[1] + eps : idx_origin[1],
        abs(idx_dir[2]) < 1e-10 ? idx_origin[2] + eps : idx_origin[2],
        abs(idx_dir[3]) < 1e-10 ? idx_origin[3] + eps : idx_origin[3]
    )
    Ray(nudged, idx_dir)
end

"""
    _coord_t(ray::Ray, ijk::Coord) -> Float64

Compute the ray parameter t at the center of voxel `ijk`.
Projects the voxel center onto the ray via dot product.
"""
function _coord_t(ray::Ray, ijk::Coord)::Float64
    center = SVec3d(Float64(ijk.x) + 0.5, Float64(ijk.y) + 0.5, Float64(ijk.z) + 0.5)
    delta = center - ray.origin
    delta[1] * ray.direction[1] + delta[2] * ray.direction[2] + delta[3] * ray.direction[3]
end

"""
    _bisect_crossing(ray::Ray, acc::ValueAccessor{T}, t_pos::Float64, t_neg::Float64, bg::T) -> Float64

Binary search between `t_pos` (SDF > 0) and `t_neg` (SDF <= 0) to find the
zero-crossing ray parameter. Uses ValueAccessor for cached lookups.
Returns the t value closest to the surface.
"""
function _bisect_crossing(ray::Ray, acc::ValueAccessor{T}, t_pos::Float64, t_neg::Float64, bg::T)::Float64 where T
    lo = t_pos
    hi = t_neg
    bg_f = Float64(abs(bg))

    for _ in 1:8  # 8 iterations -> ~1/256 voxel precision
        mid = (lo + hi) * 0.5
        p = ray.origin + mid * ray.direction
        c = coord(round(Int32, p[1]), round(Int32, p[2]), round(Int32, p[3]))
        val = Float64(get_value(acc, c))

        # Treat background values as positive (outside)
        if abs(val) >= bg_f - 1e-6
            lo = mid
        elseif val > 0.0
            lo = mid
        else
            hi = mid
        end
    end

    (lo + hi) * 0.5
end

"""
    _surface_normal(acc::ValueAccessor{T}, point::SVec3d, bg::T) -> SVec3d

Compute surface normal at `point` (index-space) via central differences with
band-edge fallback. Returns a unit vector.
"""
function _surface_normal(acc::ValueAccessor{T}, point::SVec3d, bg::T)::SVec3d where T
    c = coord(round(Int32, point[1]), round(Int32, point[2]), round(Int32, point[3]))
    cv = Float64(get_value(acc, c))
    bg_f = Float64(abs(bg)) - 1e-6

    dx = _gradient_axis(acc, c, Int32(1), Int32(0), Int32(0), cv, bg_f)
    dy = _gradient_axis(acc, c, Int32(0), Int32(1), Int32(0), cv, bg_f)
    dz = _gradient_axis(acc, c, Int32(0), Int32(0), Int32(1), cv, bg_f)

    len = sqrt(dx^2 + dy^2 + dz^2)
    if len < 1e-10
        return SVec3d(0.0, 0.0, 1.0)
    end
    SVec3d(dx / len, dy / len, dz / len)
end

"""
    _gradient_axis(acc, c, di, dj, dk, center, bg_threshold) -> Float64

Compute one axis of the gradient with fallback for band-edge voxels.
Uses central differences when both neighbors are in-band, forward/backward
difference when only one is, and 0 when neither is.
"""
function _gradient_axis(acc::ValueAccessor{T}, c::Coord, di::Int32, dj::Int32, dk::Int32,
                         center::Float64, bg_threshold::Float64)::Float64 where T
    vp = Float64(get_value(acc, Coord(c.x + di, c.y + dj, c.z + dk)))
    vm = Float64(get_value(acc, Coord(c.x - di, c.y - dj, c.z - dk)))
    p_ok = abs(vp) < bg_threshold
    m_ok = abs(vm) < bg_threshold
    if p_ok && m_ok
        (vp - vm) * 0.5
    elseif p_ok
        vp - center
    elseif m_ok
        center - vm
    else
        0.0
    end
end

"""
    _transform_normal(transform::AbstractTransform, normal::SVec3d) -> SVec3d

Transform a normal from index space to world space.
For uniform scale this is identity (just the normal itself).
For linear transforms, uses the inverse-transpose.
"""
function _transform_normal(transform::UniformScaleTransform, normal::SVec3d)::SVec3d
    normal  # Uniform scale preserves normal direction
end

function _transform_normal(transform::LinearTransform, normal::SVec3d)::SVec3d
    # Normal transforms by inverse-transpose of the upper 3x3
    # inv_mat is already stored; transpose it
    world_n = transpose(transform.inv_mat) * normal
    len = sqrt(world_n[1]^2 + world_n[2]^2 + world_n[3]^2)
    if len < 1e-10
        return SVec3d(0.0, 0.0, 1.0)
    end
    world_n / len
end

"""
    find_surface(ray::Ray, grid::Grid{T}) -> Union{SurfaceHit, Nothing}

Find the first surface intersection along a ray through a level set grid.

Uses DDA voxel traversal within each leaf, reading SDF values directly from
`leaf.values` (O(1), no tree traversal), detecting sign changes between
adjacent voxels, and bisecting for sub-voxel precision.

Returns a `SurfaceHit` with world-space position and normal, or `nothing` if
no surface is intersected.
"""
function find_surface(ray::Ray, grid::Grid{T})::Union{SurfaceHit, Nothing} where T <: AbstractFloat
    # 1. Transform world ray to index space
    idx_ray = _to_index_ray(grid.transform, ray)

    # 2. Create ValueAccessor for bisection/normal lookups
    acc = ValueAccessor(grid.tree)
    bg = grid.tree.background

    # 3. Track previous SDF for sign change detection across leaves
    prev_sdf = Inf
    prev_t = -Inf

    # 4. Iterate leaves front-to-back via VolumeRayIntersector
    for leaf_hit in VolumeRayIntersector(grid.tree, idx_ray)
        leaf = leaf_hit.leaf

        # Pre-check: sample SDF at leaf entry point to catch crossings
        # that occur right at a leaf boundary (grazing-incidence fix).
        entry_p = idx_ray.origin + leaf_hit.t_enter * idx_ray.direction
        entry_c = coord(round(Int32, entry_p[1]), round(Int32, entry_p[2]), round(Int32, entry_p[3]))
        if _voxel_in_leaf(entry_c, leaf.origin)
            entry_offset = leaf_offset(entry_c)
            entry_active = is_on(leaf.value_mask, entry_offset)
            entry_sdf = entry_active ? Float64(leaf.values[entry_offset + 1]) : Float64(bg)
            entry_t = _coord_t(idx_ray, entry_c)

            if prev_sdf > 0.0 && entry_sdf <= 0.0 && isfinite(prev_sdf)
                t_hit = _bisect_crossing(idx_ray, acc, prev_t, entry_t, bg)
                idx_point = idx_ray.origin + t_hit * idx_ray.direction
                idx_normal = _surface_normal(acc, idx_point, bg)
                world_point = index_to_world(grid.transform, idx_point)
                world_normal = _transform_normal(grid.transform, idx_normal)
                return SurfaceHit(t_hit, world_point, world_normal)
            end

            prev_sdf = entry_sdf
            prev_t = entry_t
        end

        # DDA through this leaf's voxels at stride 1
        dda = dda_init(idx_ray, leaf_hit.t_enter, 1.0)

        while _voxel_in_leaf(dda.ijk, leaf.origin)
            ijk = dda.ijk

            # Read SDF directly from leaf (O(1))
            offset = leaf_offset(ijk)
            active = is_on(leaf.value_mask, offset)
            sdf = active ? Float64(leaf.values[offset + 1]) : Float64(bg)

            t = _coord_t(idx_ray, ijk)

            # Detect sign change: outside -> inside (positive -> non-positive)
            if prev_sdf > 0.0 && sdf <= 0.0 && isfinite(prev_sdf)
                # Bisect for sub-voxel precision
                t_hit = _bisect_crossing(idx_ray, acc, prev_t, t, bg)

                # Compute index-space hit point
                idx_point = idx_ray.origin + t_hit * idx_ray.direction

                # Compute normal in index space
                idx_normal = _surface_normal(acc, idx_point, bg)

                # Transform to world space
                world_point = index_to_world(grid.transform, idx_point)
                world_normal = _transform_normal(grid.transform, idx_normal)

                return SurfaceHit(t_hit, world_point, world_normal)
            end

            prev_sdf = sdf
            prev_t = t

            dda_step!(dda)
        end
    end

    nothing
end
