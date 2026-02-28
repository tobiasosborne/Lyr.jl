# DifferentialOps.jl - Spatial differential operators on VDB grids
#
# All operators iterate active voxels, compute via stencil (or pointwise),
# and return a new grid. Central differences in index space.

# ============================================================================
# Scalar → Vector: gradient
# ============================================================================

"""
    gradient_grid(grid::Grid{T}) -> Grid{NTuple{3, T}}

Compute the gradient at every active voxel via central differences.
Returns a vector grid of ∇f. Operates in index space.
"""
function gradient_grid(grid::Grid{T}) where {T <: AbstractFloat}
    s = GradStencil(grid.tree)
    data = Dict{Coord, NTuple{3, T}}()
    for (c, _) in active_voxels(grid.tree)
        move_to!(s, c)
        data[c] = gradient(s)
    end
    bg = ntuple(_ -> zero(T), Val(3))
    build_grid(data, bg; name=grid.name, grid_class=GRID_FOG_VOLUME,
               voxel_size=_grid_voxel_size(grid))
end

# ============================================================================
# Scalar → Scalar: laplacian
# ============================================================================

"""
    laplacian(grid::Grid{T}) -> Grid{T}

Compute the Laplacian ∇²f at every active voxel (6-point stencil).
"""
function laplacian(grid::Grid{T}) where {T <: AbstractFloat}
    s = GradStencil(grid.tree)
    data = Dict{Coord, T}()
    for (c, _) in active_voxels(grid.tree)
        move_to!(s, c)
        data[c] = laplacian(s)
    end
    build_grid(data, zero(T); name=grid.name, grid_class=GRID_FOG_VOLUME,
               voxel_size=_grid_voxel_size(grid))
end

# ============================================================================
# Vector → Scalar: divergence
# ============================================================================

"""
    divergence(grid::Grid{NTuple{3, T}}) -> Grid{T}

Compute the divergence ∇·F = ∂Fx/∂x + ∂Fy/∂y + ∂Fz/∂z at every active voxel.
"""
function divergence(grid::Grid{NTuple{3, T}}) where {T <: AbstractFloat}
    s = GradStencil(grid.tree)
    data = Dict{Coord, T}()
    half = T(0.5)
    for (c, _) in active_voxels(grid.tree)
        move_to!(s, c)
        v = s.v
        # ∂Fx/∂x + ∂Fy/∂y + ∂Fz/∂z via central differences
        data[c] = (v[2][1] - v[3][1] + v[4][2] - v[5][2] + v[6][3] - v[7][3]) * half
    end
    build_grid(data, zero(T); name=grid.name, grid_class=GRID_FOG_VOLUME,
               voxel_size=_grid_voxel_size(grid))
end

# ============================================================================
# Vector → Vector: curl
# ============================================================================

"""
    curl_grid(grid::Grid{NTuple{3, T}}) -> Grid{NTuple{3, T}}

Compute the curl ∇×F at every active voxel via central differences.
"""
function curl_grid(grid::Grid{NTuple{3, T}}) where {T <: AbstractFloat}
    s = GradStencil(grid.tree)
    data = Dict{Coord, NTuple{3, T}}()
    half = T(0.5)
    for (c, _) in active_voxels(grid.tree)
        move_to!(s, c)
        v = s.v
        # curl_x = ∂Fz/∂y - ∂Fy/∂z
        # curl_y = ∂Fx/∂z - ∂Fz/∂x
        # curl_z = ∂Fy/∂x - ∂Fx/∂y
        cx = (v[4][3] - v[5][3] - v[6][2] + v[7][2]) * half
        cy = (v[6][1] - v[7][1] - v[2][3] + v[3][3]) * half
        cz = (v[2][2] - v[3][2] - v[4][1] + v[5][1]) * half
        data[c] = (cx, cy, cz)
    end
    bg = ntuple(_ -> zero(T), Val(3))
    build_grid(data, bg; name=grid.name, grid_class=GRID_FOG_VOLUME,
               voxel_size=_grid_voxel_size(grid))
end

# ============================================================================
# Vector → Scalar: magnitude
# ============================================================================

"""
    magnitude_grid(grid::Grid{NTuple{3, T}}) -> Grid{T}

Compute the Euclidean norm |v| at every active voxel.
"""
function magnitude_grid(grid::Grid{NTuple{3, T}}) where {T <: AbstractFloat}
    data = Dict{Coord, T}()
    for (c, v) in active_voxels(grid.tree)
        data[c] = T(norm(v))
    end
    build_grid(data, zero(T); name=grid.name, grid_class=GRID_FOG_VOLUME,
               voxel_size=_grid_voxel_size(grid))
end

# ============================================================================
# Vector → Vector: normalize
# ============================================================================

@inline function _vec_normalize(v::NTuple{3, T})::NTuple{3, T} where {T <: AbstractFloat}
    n = T(norm(v))
    n < eps(T) ? (zero(T), zero(T), zero(T)) : (v[1] / n, v[2] / n, v[3] / n)
end

"""
    normalize_grid(grid::Grid{NTuple{3, T}}) -> Grid{NTuple{3, T}}

Normalize every active voxel to unit length. Zero vectors remain zero.
"""
function normalize_grid(grid::Grid{NTuple{3, T}}) where {T <: AbstractFloat}
    data = Dict{Coord, NTuple{3, T}}()
    for (c, v) in active_voxels(grid.tree)
        data[c] = _vec_normalize(v)
    end
    bg = ntuple(_ -> zero(T), Val(3))
    build_grid(data, bg; name=grid.name, grid_class=GRID_FOG_VOLUME,
               voxel_size=_grid_voxel_size(grid))
end
