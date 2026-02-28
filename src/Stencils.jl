# Stencils.jl - Cached neighborhood accessors for finite-difference operators
#
# GradStencil: 7 values (center + 6 face neighbors) for gradient/laplacian
# BoxStencil: 27 values (3×3×3 cube) for filtering and tricubic interpolation
#
# Usage:
#   s = GradStencil(tree)
#   move_to!(s, coord(10, 20, 30))
#   g = gradient(s)       # NTuple{3, T} — zero allocations
#   L = laplacian(s)      # T — zero allocations

# ============================================================================
# GradStencil — 7-point (center + 6 face neighbors)
# ============================================================================

"""
    GradStencil{T}

Cached 7-point stencil for gradient and laplacian computation.
Wraps a `ValueAccessor` for cache reuse across sequential `move_to!` calls.

# Layout
- `v[1]` = center (0,0,0)
- `v[2]` = +x, `v[3]` = -x
- `v[4]` = +y, `v[5]` = -y
- `v[6]` = +z, `v[7]` = -z

# Example
```julia
s = GradStencil(grid.tree)
for (c, _) in active_voxels(grid.tree)
    move_to!(s, c)
    g = gradient(s)
    L = laplacian(s)
end
```
"""
mutable struct GradStencil{T}
    const acc::ValueAccessor{T}
    v::NTuple{7, T}
    center_coord::Coord
end

"""
    GradStencil(tree::Tree{T}) -> GradStencil{T}

Create a GradStencil backed by a fresh ValueAccessor.
"""
function GradStencil(tree::Tree{T}) where T
    z = zero(T)
    GradStencil{T}(ValueAccessor(tree), ntuple(_ -> z, Val(7)), Coord(Int32(0), Int32(0), Int32(0)))
end

"""
    move_to!(s::GradStencil, c::Coord)

Populate the stencil cache at coordinate `c`. All 7 lookups go through
the shared ValueAccessor, so spatially coherent moves get cache hits.
"""
@inline function move_to!(s::GradStencil{T}, c::Coord)::Nothing where T
    acc = s.acc
    i, j, k = c.x, c.y, c.z
    s.v = (
        get_value(acc, c),
        get_value(acc, Coord(i + Int32(1), j, k)),
        get_value(acc, Coord(i - Int32(1), j, k)),
        get_value(acc, Coord(i, j + Int32(1), k)),
        get_value(acc, Coord(i, j - Int32(1), k)),
        get_value(acc, Coord(i, j, k + Int32(1))),
        get_value(acc, Coord(i, j, k - Int32(1)))
    )
    s.center_coord = c
    nothing
end

"""Return the cached center value."""
@inline center_value(s::GradStencil) = s.v[1]

"""
    gradient(s::GradStencil{T}) -> NTuple{3, T}

Central-difference gradient from cached stencil values. Zero allocations.
"""
@inline function gradient(s::GradStencil{T})::NTuple{3, T} where {T <: AbstractFloat}
    v = s.v
    half = T(0.5)
    ((v[2] - v[3]) * half,
     (v[4] - v[5]) * half,
     (v[6] - v[7]) * half)
end

"""
    laplacian(s::GradStencil{T}) -> T

Second-order central-difference Laplacian: ∇²f = Σᵢ(f(x+eᵢ) + f(x-eᵢ)) - 6f(x).
"""
@inline function laplacian(s::GradStencil{T})::T where {T <: AbstractFloat}
    v = s.v
    v[2] + v[3] + v[4] + v[5] + v[6] + v[7] - T(6) * v[1]
end

# ============================================================================
# BoxStencil — 27-point (full 3×3×3 cube)
# ============================================================================

"""
    BoxStencil{T}

Cached 27-point stencil (full 3×3×3 neighborhood) for filtering and interpolation.

# Indexing
`v[(dx+1)*9 + (dy+1)*3 + (dz+1) + 1]` for dx, dy, dz ∈ {-1, 0, 1}.
Center is at index 14.
"""
mutable struct BoxStencil{T}
    const acc::ValueAccessor{T}
    v::NTuple{27, T}
    center_coord::Coord
end

"""
    BoxStencil(tree::Tree{T}) -> BoxStencil{T}

Create a BoxStencil backed by a fresh ValueAccessor.
"""
function BoxStencil(tree::Tree{T}) where T
    z = zero(T)
    BoxStencil{T}(ValueAccessor(tree), ntuple(_ -> z, Val(27)), Coord(Int32(0), Int32(0), Int32(0)))
end

"""
    move_to!(s::BoxStencil, c::Coord)

Populate the 3×3×3 stencil cache at coordinate `c`.
"""
@inline function move_to!(s::BoxStencil{T}, c::Coord)::Nothing where T
    acc = s.acc
    i, j, k = c.x, c.y, c.z
    s.v = ntuple(Val(27)) do idx
        idx0 = idx - 1
        dz = Int32((idx0 % 3) - 1)
        dy = Int32(((idx0 ÷ 3) % 3) - 1)
        dx = Int32((idx0 ÷ 9) - 1)
        get_value(acc, Coord(i + dx, j + dy, k + dz))
    end
    s.center_coord = c
    nothing
end

"""Return the cached center value."""
@inline center_value(s::BoxStencil) = s.v[14]

"""
    value_at(s::BoxStencil{T}, dx::Int, dy::Int, dz::Int) -> T

Access a cached value at offset (dx, dy, dz) from center. Each in {-1, 0, 1}.
"""
@inline function value_at(s::BoxStencil{T}, dx::Int, dy::Int, dz::Int)::T where T
    s.v[(dx + 1) * 9 + (dy + 1) * 3 + (dz + 1) + 1]
end

"""
    mean_value(s::BoxStencil{T}) -> T

Arithmetic mean of all 27 cached values.
"""
@inline function mean_value(s::BoxStencil{T})::T where {T <: AbstractFloat}
    sum(s.v) / T(27)
end
