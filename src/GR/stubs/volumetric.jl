# volumetric.jl — Volumetric matter bridge to VDB (Phase 2 stub)
#
# VolumetricMatter wraps a Lyr.jl Grid{T} and provides density/emission
# queries at each geodesic integration step. Spatial coordinates are
# extracted from the geodesic state x^μ and mapped to grid coordinates
# via a coordinate_map function.
#
# Bridge point: will call Lyr.sample_world(grid, spatial_coords).

"""
    VolumetricMatter{M<:MetricSpace} <: MatterSource

Volumetric matter distribution stored in a VDB tree.
Phase 2 implementation.
"""
struct VolumetricMatter{M<:MetricSpace} <: MatterSource
    # Phase 2: will hold metric, grid, nanogrid, material, coordinate_map
end
