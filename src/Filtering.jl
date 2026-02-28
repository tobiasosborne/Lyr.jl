# Filtering.jl - Spatial smoothing filters on VDB grids
#
# Both filters use the 3×3×3 BoxStencil and support iterative application
# for wider effective kernels (iterated box filter → Gaussian by CLT).

# ============================================================================
# Mean filter (box blur)
# ============================================================================

"""
    filter_mean(grid::Grid{T}; iterations=1) -> Grid{T}

Smooth a grid by replacing each active voxel with the mean of its 3×3×3
neighborhood. Multiple iterations widen the effective kernel
(iterated box filter converges to Gaussian).
"""
function filter_mean(grid::Grid{T}; iterations::Int=1) where {T <: AbstractFloat}
    current = grid
    for _ in 1:iterations
        s = BoxStencil(current.tree)
        data = Dict{Coord, T}()
        for (c, _) in active_voxels(current.tree)
            move_to!(s, c)
            data[c] = mean_value(s)
        end
        current = build_grid(data, current.tree.background; name=current.name,
                             grid_class=current.grid_class,
                             voxel_size=_grid_voxel_size(current))
    end
    current
end

# ============================================================================
# Gaussian filter (weighted blur)
# ============================================================================

"""Precompute normalized Gaussian weights for a 3×3×3 kernel."""
@inline function _gaussian_weights(::Type{T}, sigma::T) where {T <: AbstractFloat}
    inv2s2 = one(T) / (T(2) * sigma * sigma)
    w = ntuple(Val(27)) do idx
        idx0 = idx - 1
        dz = (idx0 % 3) - 1
        dy = ((idx0 ÷ 3) % 3) - 1
        dx = (idx0 ÷ 9) - 1
        exp(-T(dx * dx + dy * dy + dz * dz) * inv2s2)
    end
    total = sum(w)
    ntuple(i -> w[i] / total, Val(27))
end

"""
    filter_gaussian(grid::Grid{T}; sigma=one(T), iterations=1) -> Grid{T}

Smooth a grid with a 3×3×3 Gaussian-weighted kernel. The `sigma` parameter
controls the relative weighting (larger σ → more uniform weights → approaches
mean filter). Multiple iterations widen the effective smoothing.
"""
function filter_gaussian(grid::Grid{T}; sigma::T=one(T), iterations::Int=1) where {T <: AbstractFloat}
    weights = _gaussian_weights(T, sigma)
    current = grid
    for _ in 1:iterations
        s = BoxStencil(current.tree)
        data = Dict{Coord, T}()
        for (c, _) in active_voxels(current.tree)
            move_to!(s, c)
            v = s.v
            val = zero(T)
            for i in 1:27
                val += v[i] * weights[i]
            end
            data[c] = val
        end
        current = build_grid(data, current.tree.background; name=current.name,
                             grid_class=current.grid_class,
                             voxel_size=_grid_voxel_size(current))
    end
    current
end
