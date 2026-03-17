# GR.jl — General Relativistic ray tracing module for Lyr.jl
#
# Implements backward null geodesic integration through Lorentzian metrics
# for physically correct visualisation of gravitational lensing, accretion
# disks, and curved spacetime phenomena.
#
# Architecture: Hamiltonian formulation H = ½ gᵘᵛ pμ pν = 0
# with symplectic Störmer-Verlet integration.

module GR

using StaticArrays
using ForwardDiff
using LinearAlgebra: dot, norm, cross, I, det

# ─────────────────────────────────────────────────────────────────────
# Core types (SVec4d, SMat4d, GeodesicState, GeodesicTrace)
# ─────────────────────────────────────────────────────────────────────
include("types.jl")

# ─────────────────────────────────────────────────────────────────────
# MetricSpace abstract type + interface
# ─────────────────────────────────────────────────────────────────────
include("metric.jl")

# ─────────────────────────────────────────────────────────────────────
# Concrete metrics
# ─────────────────────────────────────────────────────────────────────
include("metrics/minkowski.jl")
include("metrics/schwarzschild.jl")
include("metrics/schwarzschild_ks.jl")
include("metrics/kerr.jl")

# ─────────────────────────────────────────────────────────────────────
# Geodesic integrator
# ─────────────────────────────────────────────────────────────────────
include("integrator.jl")

# ─────────────────────────────────────────────────────────────────────
# Camera and tetrad
# ─────────────────────────────────────────────────────────────────────
include("camera.jl")

# ─────────────────────────────────────────────────────────────────────
# Matter sources
# ─────────────────────────────────────────────────────────────────────
include("matter.jl")

# ─────────────────────────────────────────────────────────────────────
# Frequency shift and color
# ─────────────────────────────────────────────────────────────────────
include("redshift.jl")

# ─────────────────────────────────────────────────────────────────────
# Volumetric matter bridge (ThickDisk, emission-absorption)
# Must be before render.jl (which dispatches on VolumetricMatter)
# ─────────────────────────────────────────────────────────────────────
include("volumetric.jl")

# ─────────────────────────────────────────────────────────────────────
# Rendering pipeline
# ─────────────────────────────────────────────────────────────────────
include("render.jl")

# ─────────────────────────────────────────────────────────────────────
# Phase 2 stubs (interface only)
# ─────────────────────────────────────────────────────────────────────
include("stubs/weak_field.jl")

# ═════════════════════════════════════════════════════════════════════
# Exports
# ═════════════════════════════════════════════════════════════════════

# Types
export SVec4d, SMat4d
export GeodesicState, GeodesicTrace, TerminationReason
export ESCAPED, HORIZON, SINGULARITY, MAX_STEPS, HAMILTONIAN_DRIFT, DISK_HIT

# Metric interface
export MetricSpace, metric, metric_inverse, is_singular, coordinate_bounds
export metric_inverse_partials, hamiltonian, hamiltonian_rhs

# Metrics
export Minkowski
export Schwarzschild, SchwarzschildCoordinates, EddingtonFinkelstein
export SchwarzschildKS, ks_to_sky_angles
export Kerr, BoyerLindquist, KerrSchild, ergosphere_radius, isco_prograde, isco_retrograde, inner_horizon_radius
export WeakField
export VolumetricMatter, ThickDisk, evaluate_density, emission_absorption, disk_temperature
export horizon_radius, photon_sphere_radius, isco_radius

# Integrator
export AbstractStepper, RK4, Verlet
export IntegratorConfig, integrate_geodesic, rk4_step, verlet_step, adaptive_step, renormalize_null

# Camera
export GRCamera, static_observer_tetrad, static_camera, pixel_to_momentum

# Matter
export MatterSource, ThinDisk, CelestialSphere
export disk_emissivity, keplerian_four_velocity, check_disk_crossing
export sphere_lookup, checkerboard_sphere
export novikov_thorne_flux, disk_temperature_nt

# Redshift
export redshift_factor, temperature_shift, blackbody_color, doppler_color, volumetric_redshift
export planck_to_rgb, planck_to_rgb_fast, planck_to_xyz, xyz_to_srgb, srgb_gamma, scale_rgb

# Render
export GRRenderConfig, gr_render_image

end # module GR
