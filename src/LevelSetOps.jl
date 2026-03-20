# LevelSetOps.jl — Operations on level set (SDF) grids
#
# Level sets store signed distance: negative = inside, zero = surface, positive = outside.
# Background value = half_width * voxel_size (the narrow band boundary).

# ============================================================================
# sdf_to_fog — convert level set to fog volume
# ============================================================================

"""
    sdf_to_fog(grid::Grid{T}; cutoff=T(0)) -> Grid{T}

Convert a level set SDF to a fog volume. Interior (SDF < 0) maps to 1.0,
exterior (SDF > 0) maps to 0.0, and the narrow band gets a smooth linear ramp.
The `cutoff` parameter sets the SDF value at which fog reaches zero (default: 0).
"""
function sdf_to_fog(grid::Grid{T}; cutoff::T=zero(T)) where {T <: AbstractFloat}
    bg = grid.tree.background
    half_width = abs(bg)
    data = Dict{Coord, T}()
    for (c, sdf) in active_voxels(grid.tree)
        if sdf <= -half_width
            data[c] = one(T)
        elseif sdf < cutoff
            # Linear ramp from 1.0 at -half_width to 0.0 at cutoff
            data[c] = (cutoff - sdf) / (cutoff + half_width)
        end
        # sdf >= cutoff → exterior → skip (background 0)
    end
    build_grid(data, zero(T); name=grid.name, grid_class=GRID_FOG_VOLUME,
               voxel_size=_grid_voxel_size(grid))
end

# ============================================================================
# sdf_interior_mask — boolean mask of interior voxels
# ============================================================================

"""
    sdf_interior_mask(grid::Grid{T}) -> Grid{Float32}

Return a mask grid where interior voxels (SDF < 0) have value 1.0 and
all others have value 0.0. Uses Float32 grid (VDB has no native Bool grid).
"""
function sdf_interior_mask(grid::Grid{T}) where {T <: AbstractFloat}
    data = Dict{Coord, Float32}()
    for (c, sdf) in active_voxels(grid.tree)
        sdf < zero(T) && (data[c] = 1.0f0)
    end
    build_grid(data, 0.0f0; name=grid.name * "_interior",
               grid_class=GRID_FOG_VOLUME, voxel_size=_grid_voxel_size(grid))
end

# ============================================================================
# extract_isosurface_mask — voxels straddling a given isovalue
# ============================================================================

"""
    extract_isosurface_mask(grid::Grid{T}; isovalue=zero(T)) -> Grid{Float32}

Return a mask of voxels that straddle the isosurface — where any face neighbor
has a sign change relative to `isovalue`. Produces a thin shell (1-2 voxels thick).
"""
function extract_isosurface_mask(grid::Grid{T}; isovalue::T=zero(T)) where {T <: AbstractFloat}
    acc = ValueAccessor(grid.tree)
    data = Dict{Coord, Float32}()
    for (c, v) in active_voxels(grid.tree)
        centered = v - isovalue
        i, j, k = c.x, c.y, c.z
        # Check 6 face neighbors for sign change
        if _sign_change(centered, get_value(acc, Coord(i+Int32(1),j,k)) - isovalue) ||
           _sign_change(centered, get_value(acc, Coord(i-Int32(1),j,k)) - isovalue) ||
           _sign_change(centered, get_value(acc, Coord(i,j+Int32(1),k)) - isovalue) ||
           _sign_change(centered, get_value(acc, Coord(i,j-Int32(1),k)) - isovalue) ||
           _sign_change(centered, get_value(acc, Coord(i,j,k+Int32(1))) - isovalue) ||
           _sign_change(centered, get_value(acc, Coord(i,j,k-Int32(1))) - isovalue)
            data[c] = 1.0f0
        end
    end
    build_grid(data, 0.0f0; name=grid.name * "_isosurface",
               grid_class=GRID_FOG_VOLUME, voxel_size=_grid_voxel_size(grid))
end

"Return true if `a` and `b` have opposite signs (positive vs non-positive)."
@inline _sign_change(a, b) = (a > 0) != (b > 0)

# ============================================================================
# Level set measurements — area, volume
# ============================================================================

"""
    level_set_area(grid::Grid{T}) -> Float64

Estimate the surface area of a level set by counting isosurface-straddling
voxel faces. Each face contributes voxel_size² to the area.
"""
function level_set_area(grid::Grid{T})::Float64 where {T <: AbstractFloat}
    acc = ValueAccessor(grid.tree)
    vs = _grid_voxel_size(grid)
    face_area = vs * vs
    total = 0.0
    for (c, v) in active_voxels(grid.tree)
        i, j, k = c.x, c.y, c.z
        # Count faces where sign changes (only positive direction to avoid double-counting)
        for (di, dj, dk) in ((Int32(1),Int32(0),Int32(0)),
                              (Int32(0),Int32(1),Int32(0)),
                              (Int32(0),Int32(0),Int32(1)))
            neighbor = get_value(acc, Coord(i+di, j+dj, k+dk))
            if _sign_change(v, neighbor)
                total += face_area
            end
        end
    end
    total
end

"""
    level_set_volume(grid::Grid{T}) -> Float64

Estimate the enclosed volume of a level set by counting interior voxels
(SDF < 0). Each voxel contributes voxel_size³.
"""
function level_set_volume(grid::Grid{T})::Float64 where {T <: AbstractFloat}
    vs = _grid_voxel_size(grid)
    voxel_vol = vs * vs * vs
    count = 0
    for (_, sdf) in active_voxels(grid.tree)
        sdf < zero(T) && (count += 1)
    end
    count * voxel_vol
end

# ============================================================================
# check_level_set — diagnostic validation
# ============================================================================

"""
    LevelSetDiagnostic

Result of `check_level_set`. Fields:
- `valid::Bool` — overall pass/fail
- `issues::Vector{String}` — list of problems found
- `active_count::Int` — number of active voxels
- `interior_count::Int` — voxels with SDF < 0
- `exterior_count::Int` — voxels with SDF > 0
- `surface_count::Int` — voxels with SDF ≈ 0
"""
struct LevelSetDiagnostic
    valid::Bool
    issues::Vector{String}
    active_count::Int
    interior_count::Int
    exterior_count::Int
    surface_count::Int
end

"""
    check_level_set(grid::Grid{T}) -> LevelSetDiagnostic

Validate a level set grid. Checks:
1. Background value is positive (convention: positive = outside)
2. Narrow band is symmetric (has both interior and exterior voxels)
3. No active voxel exceeds background magnitude (narrow band consistency)
4. Grid class is GRID_LEVEL_SET
"""
function check_level_set(grid::Grid{T}) where {T <: AbstractFloat}
    issues = String[]
    bg = grid.tree.background

    # Check 1: background should be positive
    bg <= zero(T) && push!(issues, "Background value ($bg) should be positive")

    # Check 2: grid class
    grid.grid_class != GRID_LEVEL_SET && push!(issues, "Grid class is $(grid.grid_class), expected GRID_LEVEL_SET")

    # Count voxels by category
    n_interior = 0
    n_exterior = 0
    n_surface = 0
    n_exceeds = 0
    abs_bg = abs(bg)
    for (_, sdf) in active_voxels(grid.tree)
        if abs(sdf) < T(0.5)
            n_surface += 1
        elseif sdf < zero(T)
            n_interior += 1
        else
            n_exterior += 1
        end
        abs(sdf) > abs_bg + eps(T) && (n_exceeds += 1)
    end
    n_active = n_interior + n_exterior + n_surface

    # Check 3: symmetric narrow band
    n_active > 0 && n_interior == 0 && push!(issues, "No interior voxels (SDF < 0) — degenerate level set")
    n_active > 0 && n_exterior == 0 && push!(issues, "No exterior voxels (SDF > 0) — degenerate level set")

    # Check 4: narrow band consistency
    n_exceeds > 0 && push!(issues, "$n_exceeds active voxels exceed background magnitude ($abs_bg)")

    LevelSetDiagnostic(isempty(issues), issues, n_active, n_interior, n_exterior, n_surface)
end

# ============================================================================
# fog_to_sdf — convert fog volume to level set SDF
# ============================================================================

"""
    fog_to_sdf(fog::Grid{T}; threshold::T=T(0.5),
               half_width::Float64=3.0) where {T <: AbstractFloat} -> Grid{T}

Convert a fog volume to a level set SDF. Voxels with density > `threshold`
become interior (negative SDF), others become exterior (positive SDF).
Uses the Fast Sweeping Method to compute proper signed distances.

Approximately the inverse of `sdf_to_fog`.
"""
function fog_to_sdf(fog::Grid{T}; threshold::T=T(0.5),
                    half_width::Float64=3.0) where {T <: AbstractFloat}
    vs = _grid_voxel_size(fog)
    bg = T(half_width * vs)

    # Step 1: Create signed field from fog topology
    data = Dict{Coord, T}()
    for (c, density) in active_voxels(fog.tree)
        data[c] = density > threshold ? -bg : bg
    end

    isempty(data) && return build_grid(data, bg; name=fog.name * "_sdf",
                                       grid_class=GRID_LEVEL_SET, voxel_size=vs)

    # Step 2: Dilate to ensure narrow band coverage
    seed = build_grid(data, bg; name=fog.name * "_sdf",
                      grid_class=GRID_LEVEL_SET, voxel_size=vs)
    expanded = dilate(seed; iterations=max(1, ceil(Int, half_width)))

    # Step 3: Reinitialize SDF via Fast Sweeping
    reinitialize_sdf(expanded; iterations=2)
end
