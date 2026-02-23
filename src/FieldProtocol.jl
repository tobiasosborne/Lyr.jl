# FieldProtocol.jl - The interface between physics computation and volumetric rendering
#
# Defines abstract field types, domain types, and reference implementations.
# Physics modules produce fields; Lyr renders them. This protocol is the bridge.

# ============================================================================
# Domain types
# ============================================================================

"""
    AbstractDomain

Base type for spatial domains. Subtypes specify where a field is defined.
"""
abstract type AbstractDomain end

"""
    BoxDomain(min, max)
    BoxDomain(min::NTuple{3,Float64}, max::NTuple{3,Float64})

An axis-aligned bounding box in world space (Float64 coordinates).

This is the continuous-space domain type for the Field Protocol. It is distinct
from `BBox` (which uses Int32 `Coord` for VDB tree operations).

# Fields
- `min::SVec3d` — Minimum corner (x, y, z)
- `max::SVec3d` — Maximum corner (x, y, z)

# Example
```julia
dom = BoxDomain((-10.0, -10.0, -10.0), (10.0, 10.0, 10.0))
c = center(dom)   # SVec3d(0, 0, 0)
e = extent(dom)   # SVec3d(20, 20, 20)
```
"""
struct BoxDomain <: AbstractDomain
    min::SVec3d
    max::SVec3d
end

BoxDomain(min::NTuple{3,Float64}, max::NTuple{3,Float64}) =
    BoxDomain(SVec3d(min...), SVec3d(max...))

BoxDomain(min::NTuple{3,<:Real}, max::NTuple{3,<:Real}) =
    BoxDomain(SVec3d(Float64.(min)...), SVec3d(Float64.(max)...))

"""
    center(d::BoxDomain) -> SVec3d

Return the center point of the domain.
"""
center(d::BoxDomain) = (d.min + d.max) * 0.5

"""
    extent(d::BoxDomain) -> SVec3d

Return the size of the domain along each axis.
"""
extent(d::BoxDomain) = d.max - d.min

Base.show(io::IO, d::BoxDomain) =
    print(io, "BoxDomain($(d.min), $(d.max))")

# ============================================================================
# Abstract field hierarchy
# ============================================================================

"""
    AbstractField

Base type for all fields in the Field Protocol.

Subtypes must implement:
- `domain(f)` — return the spatial domain
- `field_eltype(f)` — return the element type of evaluation

See also: [`AbstractContinuousField`](@ref), [`ParticleField`](@ref)
"""
abstract type AbstractField end

"""
    AbstractContinuousField <: AbstractField

A field defined by a continuous function f(x, y, z) → value.

Subtypes must implement:
- `evaluate(f, x::Float64, y::Float64, z::Float64)` — sample the field
- `domain(f)` — return `BoxDomain`
- `field_eltype(f)` — return element type (Float64, SVec3d, ComplexF64, etc.)
- `characteristic_scale(f)` — return the length scale of the field's features
"""
abstract type AbstractContinuousField <: AbstractField end

"""
    AbstractDiscreteField <: AbstractField

A field defined on discrete sites (lattice points, mesh nodes, etc.).

Subtypes must implement:
- `evaluate(f, index)` — sample at a site
- `sites(f)` — iterator over valid indices
- `domain(f)` — return domain
- `field_eltype(f)` — return element type
"""
abstract type AbstractDiscreteField <: AbstractField end

# ============================================================================
# Interface methods (fallback errors for documentation)
# ============================================================================

"""
    domain(f::AbstractField) -> AbstractDomain

Return the spatial domain where the field is defined.
"""
function domain end

"""
    field_eltype(f::AbstractField) -> Type

Return the element type of field evaluation.

Named `field_eltype` (not `fieldtype`) to avoid shadowing `Base.fieldtype`.

# Examples
```julia
field_eltype(ScalarField3D(...))          # Float64
field_eltype(VectorField3D(...))          # SVec3d
field_eltype(ComplexScalarField3D(...))   # ComplexF64
```
"""
function field_eltype end

"""
    characteristic_scale(f::AbstractContinuousField) -> Float64

Return the characteristic length scale of the field's features.

Used by `voxelize()` to automatically choose `voxel_size`.
A field with `characteristic_scale = 2.0` has features ~2 world units wide;
`voxelize` will default to `voxel_size ≈ 0.4` (scale / 5) to resolve them.
"""
function characteristic_scale end

"""
    evaluate(f::AbstractContinuousField, x::Float64, y::Float64, z::Float64)

Sample a continuous field at world-space coordinates (x, y, z).

The return type depends on the field:
- `ScalarField3D` → `Float64`
- `VectorField3D` → `SVec3d`
- `ComplexScalarField3D` → `ComplexF64`

This method coexists with `evaluate(tf::TransferFunction, density)` via
multiple dispatch — different first-argument types, no ambiguity.
"""
function evaluate end

# ============================================================================
# Reference implementations — continuous fields
# ============================================================================

"""
    ScalarField3D(eval_fn, domain, characteristic_scale)

A scalar field f(x, y, z) → Float64 over a bounding box domain.

# Arguments
- `eval_fn` — Function `(x::Float64, y::Float64, z::Float64) -> Float64`
- `domain::BoxDomain` — Spatial extent of the field
- `characteristic_scale::Float64` — Feature size in world units (for auto voxel_size)

# Example
```julia
# A Gaussian blob centered at the origin
field = ScalarField3D(
    (x, y, z) -> exp(-(x^2 + y^2 + z^2) / 2.0),
    BoxDomain((-5.0, -5.0, -5.0), (5.0, 5.0, 5.0)),
    1.0  # features ~1 world unit wide
)
evaluate(field, 0.0, 0.0, 0.0)  # 1.0
```
"""
struct ScalarField3D{F} <: AbstractContinuousField
    eval_fn::F
    domain::BoxDomain
    characteristic_scale::Float64
end

evaluate(f::ScalarField3D, x::Float64, y::Float64, z::Float64) =
    f.eval_fn(x, y, z)::Float64

domain(f::ScalarField3D) = f.domain
field_eltype(::ScalarField3D) = Float64
characteristic_scale(f::ScalarField3D) = f.characteristic_scale

Base.show(io::IO, ::Type{<:ScalarField3D}) = print(io, "ScalarField3D")
Base.show(io::IO, f::ScalarField3D) =
    print(io, "ScalarField3D($(f.domain), scale=$(f.characteristic_scale))")

"""
    VectorField3D(eval_fn, domain, characteristic_scale)

A vector field f(x, y, z) → SVec3d over a bounding box domain.

# Arguments
- `eval_fn` — Function `(x::Float64, y::Float64, z::Float64) -> SVec3d`
- `domain::BoxDomain` — Spatial extent
- `characteristic_scale::Float64` — Feature size

# Example
```julia
# A uniform flow field
field = VectorField3D(
    (x, y, z) -> SVec3d(1.0, 0.0, 0.0),
    BoxDomain((-5.0, -5.0, -5.0), (5.0, 5.0, 5.0)),
    2.0
)
evaluate(field, 0.0, 0.0, 0.0)  # SVec3d(1.0, 0.0, 0.0)
```
"""
struct VectorField3D{F} <: AbstractContinuousField
    eval_fn::F
    domain::BoxDomain
    characteristic_scale::Float64
end

evaluate(f::VectorField3D, x::Float64, y::Float64, z::Float64) =
    f.eval_fn(x, y, z)::SVec3d

domain(f::VectorField3D) = f.domain
field_eltype(::VectorField3D) = SVec3d
characteristic_scale(f::VectorField3D) = f.characteristic_scale

Base.show(io::IO, ::Type{<:VectorField3D}) = print(io, "VectorField3D")
Base.show(io::IO, f::VectorField3D) =
    print(io, "VectorField3D($(f.domain), scale=$(f.characteristic_scale))")

"""
    ComplexScalarField3D(eval_fn, domain, characteristic_scale)

A complex-valued scalar field f(x, y, z) → ComplexF64.

Designed for quantum mechanical wavefunctions. When voxelized,
the probability density |ψ|² = abs2(evaluate(f, x, y, z)) is used.

# Arguments
- `eval_fn` — Function `(x::Float64, y::Float64, z::Float64) -> ComplexF64`
- `domain::BoxDomain` — Spatial extent
- `characteristic_scale::Float64` — Feature size (e.g., Bohr radius)

# Example
```julia
# Hydrogen 1s orbital (simplified)
a0 = 1.0  # Bohr radius
field = ComplexScalarField3D(
    (x, y, z) -> exp(-sqrt(x^2 + y^2 + z^2) / a0) + 0im,
    BoxDomain((-10.0, -10.0, -10.0), (10.0, 10.0, 10.0)),
    a0
)
abs2(evaluate(field, 0.0, 0.0, 0.0))  # probability density at origin
```
"""
struct ComplexScalarField3D{F} <: AbstractContinuousField
    eval_fn::F
    domain::BoxDomain
    characteristic_scale::Float64
end

evaluate(f::ComplexScalarField3D, x::Float64, y::Float64, z::Float64) =
    f.eval_fn(x, y, z)::ComplexF64

domain(f::ComplexScalarField3D) = f.domain
field_eltype(::ComplexScalarField3D) = ComplexF64
characteristic_scale(f::ComplexScalarField3D) = f.characteristic_scale

Base.show(io::IO, ::Type{<:ComplexScalarField3D}) = print(io, "ComplexScalarField3D")
Base.show(io::IO, f::ComplexScalarField3D) =
    print(io, "ComplexScalarField3D($(f.domain), scale=$(f.characteristic_scale))")

# ============================================================================
# Reference implementations — particle data
# ============================================================================

"""
    ParticleField(positions; velocities=nothing, properties=Dict())

A set of particles with positions and optional per-particle properties.

When voxelized, particles are converted to a density grid via Gaussian splatting.

# Arguments
- `positions::Vector{SVec3d}` — Particle positions in world space
- `velocities::Union{Nothing, Vector{SVec3d}}` — Optional velocities
- `properties::Dict{Symbol, Vector}` — Optional per-particle data (`:mass`, `:charge`, etc.)

# Example
```julia
pos = [SVec3d(randn(3)...) for _ in 1:1000]
field = ParticleField(pos)
grid = voxelize(field; voxel_size=0.5, sigma=1.0)
```
"""
struct ParticleField <: AbstractField
    positions::Vector{SVec3d}
    velocities::Union{Nothing, Vector{SVec3d}}
    properties::Dict{Symbol, Vector}
end

ParticleField(positions::Vector{SVec3d};
              velocities::Union{Nothing, Vector{SVec3d}}=nothing,
              properties::Dict{Symbol, Vector}=Dict{Symbol, Vector}()) =
    ParticleField(positions, velocities, properties)

function domain(f::ParticleField)
    isempty(f.positions) && return BoxDomain(SVec3d(0,0,0), SVec3d(1,1,1))
    lo = reduce((a, b) -> SVec3d(min(a[1],b[1]), min(a[2],b[2]), min(a[3],b[3])), f.positions)
    hi = reduce((a, b) -> SVec3d(max(a[1],b[1]), max(a[2],b[2]), max(a[3],b[3])), f.positions)
    pad = max(maximum(hi - lo) * 0.1, 1.0)
    BoxDomain(lo .- pad, hi .+ pad)
end

field_eltype(::ParticleField) = SVec3d

Base.show(io::IO, f::ParticleField) =
    print(io, "ParticleField($(length(f.positions)) particles)")

# ============================================================================
# Time evolution wrapper
# ============================================================================

"""
    TimeEvolution{F}(eval_fn, t_range, dt_hint)

Wraps a time-varying field: at each time `t`, `eval_fn(t)` returns a field of type `F`.

# Arguments
- `eval_fn` — Function `(t::Float64) -> F` where `F <: AbstractField`
- `t_range::Tuple{Float64, Float64}` — (start_time, end_time)
- `dt_hint::Float64` — Suggested time step for animation

# Example
```julia
# Oscillating Gaussian
evolving = TimeEvolution{ScalarField3D}(
    t -> ScalarField3D(
        (x, y, z) -> exp(-(x^2 + y^2 + z^2) / 2.0) * cos(t),
        BoxDomain((-5.0,-5.0,-5.0), (5.0,5.0,5.0)),
        1.0
    ),
    (0.0, 2π),
    0.1
)
field_at_t = evolving.eval_fn(0.0)  # ScalarField3D at t=0
```
"""
struct TimeEvolution{F <: AbstractField, G}
    eval_fn::G
    t_range::Tuple{Float64, Float64}
    dt_hint::Float64
end

TimeEvolution{F}(eval_fn, t_range, dt_hint) where {F <: AbstractField} =
    TimeEvolution{F, typeof(eval_fn)}(eval_fn, t_range, dt_hint)

domain(te::TimeEvolution) = domain(te.eval_fn(te.t_range[1]))
field_eltype(te::TimeEvolution{F}) where F = field_eltype(te.eval_fn(te.t_range[1]))

Base.show(io::IO, te::TimeEvolution{F}) where F =
    print(io, "TimeEvolution{$F}(t=$(te.t_range), dt=$(te.dt_hint))")
