#!/usr/bin/env julia
# hydrogen_precession.jl — Larmor precession + spontaneous emission
#
# Starts in a clean coherent superposition (1/√2)|1s⟩ + (1/√2)|2p_x⟩ and
# evolves under a constant magnetic field. The 2p_x dumbbell precesses
# around z at the Larmor frequency while decaying via spontaneous emission.
#
# Physics: Analytical Lindblad master equation (no ODE needed).
#   - Beat oscillation at ω₁₂ (1 per second)
#   - Larmor precession at 2ω_L (dumbbell rotates around z)
#   - Spontaneous emission at rate γ (2p drains → 1s fills, Tr(ρ)=1)
#
# Usage:
#   julia --project scripts/hydrogen_precession.jl                    # all 1800 frames
#   julia --project scripts/hydrogen_precession.jl 0 59 1920x1080 spp=2

using Lyr
using PNGFiles

# ============================================================================
# Section 1: Mathematical foundations
# ============================================================================

function factorial_int(n::Int)::Float64
    n <= 1 && return 1.0
    result = 1.0
    for i in 2:n
        result *= i
    end
    result
end

function laguerre(p::Int, q::Int, x::Float64)::Float64
    p == 0 && return 1.0
    p == 1 && return 1.0 + q - x
    L_prev = 1.0
    L_curr = 1.0 + q - x
    for k in 1:(p - 1)
        L_next = ((2k + 1 + q - x) * L_curr - (k + q) * L_prev) / (k + 1)
        L_prev = L_curr
        L_curr = L_next
    end
    L_curr
end

function assoc_legendre(l::Int, m::Int, x::Float64)::Float64
    pmm = 1.0
    if m > 0
        somx2 = sqrt((1.0 - x) * (1.0 + x))
        fact = 1.0
        for i in 1:m
            pmm *= -fact * somx2
            fact += 2.0
        end
    end
    l == m && return pmm
    pmmp1 = x * (2m + 1) * pmm
    l == m + 1 && return pmmp1
    pll = 0.0
    for ll in (m + 2):l
        pll = (x * (2ll - 1) * pmmp1 - (ll + m - 1) * pmm) / (ll - m)
        pmm = pmmp1
        pmmp1 = pll
    end
    pll
end

function radial_wavefunction(n::Int, l::Int, r::Float64)::Float64
    ρ = 2.0 * r / n
    exp(-ρ / 2.0) * ρ^l * laguerre(n - l - 1, 2l + 1, ρ)
end

function complex_spherical_harmonic(l::Int, m::Int,
                                     theta::Float64, phi::Float64)::ComplexF64
    am = abs(m)
    norm = sqrt((2l + 1) / (4π) * factorial_int(l - am) / factorial_int(l + am))
    plm = assoc_legendre(l, am, cos(theta))
    if m >= 0
        return norm * plm * exp(im * m * phi)
    else
        return (-1)^am * norm * plm * exp(im * m * phi)
    end
end

# ============================================================================
# Section 2: Physics — analytical Lindblad with constant B-field
# ============================================================================
#
# Basis: 1=|1s⟩, 2=|2p,m=-1⟩, 3=|2p,m=0⟩, 4=|2p,m=+1⟩
#
# Initial state: |Ψ(0)⟩ = (1/√2)|1s⟩ + (1/2)|2p₋₁⟩ - (1/2)|2p₊₁⟩
# This is (1/√2)|1s⟩ + (1/√2)|2p_x⟩ — a dumbbell along x + sphere.
#
# The 2p_x dumbbell PRECESSES around z because m=±1 accumulate Zeeman phase
# at different rates: the coherence ρ[2,4] rotates at 2ω_L.
#
# All density matrix elements have exact analytical solutions:
#   ρ_{1s,1s}(t) = ρ₀_{1s} + (1-e^{-γt})·Σρ₀_{mm}    (1s fills)
#   ρ_{mm}(t)    = ρ₀_{mm}·e^{-γt}                      (2p drains)
#   ρ_{1s,m}(t)  = ρ₀_{1s,m}·e^{iΔE_m·t}·e^{-γt/2}    (1s↔2p coherences)
#   ρ_{m,m'}(t)  = ρ₀_{m,m'}·e^{-i(m-m')ω_L·t}·e^{-γt} (2p↔2p coherences)
#
# Tr(ρ) = 1 exactly for all t.

const OMEGA_12 = 1.0       # 1s-2p transition frequency (beat at 1/sec)
const OMEGA_L  = 0.4       # Larmor frequency (B-field strength)
const GAMMA    = 0.06      # Slower decay → more time to see precession

const N_FRAMES = 1800      # 60s × 30fps
const T_TOTAL  = 120.0 * π # 60 beat periods (1 beat/second)
const DT_FRAME = T_TOTAL / (N_FRAMES - 1)

# Initial pure state: (1/√2)|1s⟩ + (1/2)|2p,-1⟩ - (1/2)|2p,+1⟩
const C_INIT = ComplexF64[1/√2, 1/2, 0, -1/2]
const RHO_0 = C_INIT * C_INIT'

# Energy differences ΔE_m = E_{1s} - E_{2p,m} = -(ω₁₂ + m·ω_L)
const DE = Float64[0.0, -(OMEGA_12 - OMEGA_L), -OMEGA_12, -(OMEGA_12 + OMEGA_L)]

"""Analytical Lindblad solution at time t. Tr(ρ)=1 exactly."""
function density_matrix(t::Float64)
    ρ = Matrix{ComplexF64}(undef, 4, 4)
    e_γt = exp(-GAMMA * t)

    # 2p populations decay, 1s fills
    p2p_0 = real(RHO_0[2,2]) + real(RHO_0[3,3]) + real(RHO_0[4,4])
    ρ[1,1] = real(RHO_0[1,1]) + (1.0 - e_γt) * p2p_0
    ρ[2,2] = RHO_0[2,2] * e_γt
    ρ[3,3] = RHO_0[3,3] * e_γt
    ρ[4,4] = RHO_0[4,4] * e_γt

    # 1s ↔ 2p coherences: beat oscillation + decay at γ/2
    e_γt2 = exp(-GAMMA * t / 2.0)
    for m in 2:4
        phase = exp(im * DE[m] * t)
        ρ[1,m] = RHO_0[1,m] * phase * e_γt2
        ρ[m,1] = conj(ρ[1,m])
    end

    # 2p ↔ 2p coherences: Larmor precession + decay at γ
    # This is where the dumbbell rotation lives!
    # ρ[2,4] = ρ₀[2,4] · e^{-i(-1-(+1))ω_L·t} · e^{-γt}
    #         = ρ₀[2,4] · e^{+2iω_L·t} · e^{-γt}
    m_vals = (-1, 0, 1)
    for a in 2:4, b in (a+1):4
        Δm = m_vals[a-1] - m_vals[b-1]
        phase = exp(-im * Δm * OMEGA_L * t)
        ρ[a,b] = RHO_0[a,b] * phase * e_γt
        ρ[b,a] = conj(ρ[a,b])
    end

    ρ
end

# ============================================================================
# Section 3: Precompute spatial basis wavefunctions
# ============================================================================

struct BasisGrid
    coords::Vector{Coord}
    psi_1s::Vector{ComplexF64}
    psi_2p_m1::Vector{ComplexF64}
    psi_2p_0::Vector{ComplexF64}
    psi_2p_p1::Vector{ComplexF64}
end

function precompute_basis(; voxel_size::Float64=0.3)
    R_max = 16.0
    N_half = ceil(Int, R_max / voxel_size)
    R_max_sq = R_max * R_max
    threshold = 1e-10

    coords = Coord[]
    psi_1s = ComplexF64[]
    psi_2p_m1 = ComplexF64[]
    psi_2p_0 = ComplexF64[]
    psi_2p_p1 = ComplexF64[]

    for ix in -N_half:N_half
        x = ix * voxel_size
        for iy in -N_half:N_half
            y = iy * voxel_size
            x2y2 = x * x + y * y
            for iz in -N_half:N_half
                z = iz * voxel_size
                r2 = x2y2 + z * z
                r2 > R_max_sq && continue

                r = sqrt(r2)
                if r < 1e-12
                    R_10 = radial_wavefunction(1, 0, 1e-12)
                    Y_00 = complex_spherical_harmonic(0, 0, 0.0, 0.0)
                    push!(coords, Coord(Int32(ix), Int32(iy), Int32(iz)))
                    push!(psi_1s, R_10 * Y_00)
                    push!(psi_2p_m1, zero(ComplexF64))
                    push!(psi_2p_0, zero(ComplexF64))
                    push!(psi_2p_p1, zero(ComplexF64))
                    continue
                end

                theta = acos(clamp(z / r, -1.0, 1.0))
                phi = atan(y, x)

                R_10 = radial_wavefunction(1, 0, r)
                R_21 = radial_wavefunction(2, 1, r)

                v_1s   = R_10 * complex_spherical_harmonic(0, 0, theta, phi)
                v_2pm1 = R_21 * complex_spherical_harmonic(1, -1, theta, phi)
                v_2p0  = R_21 * complex_spherical_harmonic(1, 0, theta, phi)
                v_2pp1 = R_21 * complex_spherical_harmonic(1, 1, theta, phi)

                max_mag = max(abs(v_1s), abs(v_2pm1), abs(v_2p0), abs(v_2pp1))
                max_mag < threshold && continue

                push!(coords, Coord(Int32(ix), Int32(iy), Int32(iz)))
                push!(psi_1s, v_1s)
                push!(psi_2p_m1, v_2pm1)
                push!(psi_2p_0, v_2p0)
                push!(psi_2p_p1, v_2pp1)
            end
        end
    end

    BasisGrid(coords, psi_1s, psi_2p_m1, psi_2p_0, psi_2p_p1)
end

# ============================================================================
# Section 4: Per-frame density from density matrix
# ============================================================================

function compute_density(bg::BasisGrid, ρ::Matrix{ComplexF64};
                         threshold::Float64=1e-6)
    N = length(bg.coords)
    data = Dict{Coord, Float32}()
    sizehint!(data, N ÷ 2)
    max_val = 0.0

    ρ_11 = real(ρ[1,1]); ρ_22 = real(ρ[2,2])
    ρ_33 = real(ρ[3,3]); ρ_44 = real(ρ[4,4])
    ρ_12 = ρ[1,2]; ρ_13 = ρ[1,3]; ρ_14 = ρ[1,4]
    ρ_23 = ρ[2,3]; ρ_24 = ρ[2,4]; ρ_34 = ρ[3,4]

    @inbounds for i in 1:N
        v1 = bg.psi_1s[i]
        v2 = bg.psi_2p_m1[i]
        v3 = bg.psi_2p_0[i]
        v4 = bg.psi_2p_p1[i]

        d = ρ_11 * abs2(v1) + ρ_22 * abs2(v2) +
            ρ_33 * abs2(v3) + ρ_44 * abs2(v4)
        d += 2.0 * real(ρ_12 * conj(v1) * v2)
        d += 2.0 * real(ρ_13 * conj(v1) * v3)
        d += 2.0 * real(ρ_14 * conj(v1) * v4)
        d += 2.0 * real(ρ_23 * conj(v2) * v3)
        d += 2.0 * real(ρ_24 * conj(v2) * v4)
        d += 2.0 * real(ρ_34 * conj(v3) * v4)

        if d > 0.0
            data[bg.coords[i]] = Float32(d)
            max_val = max(max_val, d)
        end
    end

    if max_val > 0.0
        inv_max = Float32(1.0 / max_val)
        thresh = Float32(threshold)
        for (k, v) in data
            nv = v * inv_max
            if nv < thresh
                delete!(data, k)
            else
                data[k] = nv
            end
        end
    end

    data
end

# ============================================================================
# Section 5: Transfer function and rendering
# ============================================================================

function tf_orbital()
    TransferFunction([
        ControlPoint(0.00, (0.0,  0.0,  0.0,  0.0)),
        ControlPoint(0.02, (0.05, 0.10, 0.30, 0.08)),
        ControlPoint(0.08, (0.10, 0.25, 0.60, 0.20)),
        ControlPoint(0.20, (0.20, 0.45, 0.80, 0.40)),
        ControlPoint(0.40, (0.35, 0.65, 0.95, 0.60)),
        ControlPoint(0.60, (0.55, 0.80, 1.00, 0.75)),
        ControlPoint(0.80, (0.75, 0.92, 1.00, 0.88)),
        ControlPoint(1.00, (1.00, 1.00, 1.00, 1.00)),
    ])
end

function render_frame(bg::BasisGrid, frame_idx::Int, outdir::String;
                      voxel_size::Float64=0.3, width::Int=1920, height::Int=1080,
                      spp::Int=2)
    t = frame_idx * DT_FRAME

    ρ = density_matrix(t)
    density = compute_density(bg, ρ)
    isempty(density) && return

    grid = build_grid(density, 0.0f0; name="precession",
                      grid_class=GRID_FOG_VOLUME, voxel_size=voxel_size)
    nanogrid = build_nanogrid(grid.tree)

    R_max = 16.0
    N_half = ceil(Int, R_max / voxel_size)
    cam_dist = Float64(N_half) * 3.0
    camera = Camera(
        (cam_dist * 0.7, cam_dist * 0.5, cam_dist * 0.7),
        (0.0, 0.0, 0.0),
        (0.0, 1.0, 0.0),
        35.0
    )

    tf = tf_orbital()
    material = VolumeMaterial(tf; sigma_scale=2.0, emission_scale=6.0,
                              scattering_albedo=0.4)
    volume = VolumeEntry(grid, nanogrid, material)
    light = DirectionalLight((1.0, 1.0, 0.8), (3.0, 3.0, 3.0))
    scene = Scene(camera, light, volume; background=(0.005, 0.005, 0.015))

    pixels = render_volume_image(scene, width, height;
                                 spp=spp, seed=UInt64(42 + frame_idx))
    pixels = tonemap_aces(pixels)

    path = joinpath(outdir, "frame_$(lpad(frame_idx, 4, '0')).png")
    write_png(path, pixels)

    nvox = active_voxel_count(grid.tree)
    p1s = real(ρ[1,1])
    p2p = real(ρ[2,2]) + real(ρ[3,3]) + real(ρ[4,4])
    println("  Frame $frame_idx (t=$(round(t; digits=1))): " *
            "P(1s)=$(round(p1s; digits=3)) P(2p)=$(round(p2p; digits=3)) " *
            "Tr=$(round(p1s+p2p; digits=6)) $nvox vox")
end

# ============================================================================
# Section 6: Main
# ============================================================================

function main()
    outdir = joinpath(@__DIR__, "precession_frames")
    mkpath(outdir)

    frame_start = 0
    frame_end = N_FRAMES - 1
    width, height = 1920, 1080
    spp = 2

    positional = Int[]
    for arg in ARGS
        if occursin("x", arg) && all(c -> isdigit(c) || c == 'x', arg)
            parts = split(arg, "x")
            width = parse(Int, parts[1])
            height = parse(Int, parts[2])
        elseif startswith(arg, "spp=")
            spp = parse(Int, arg[5:end])
        else
            push!(positional, parse(Int, arg))
        end
    end
    if length(positional) >= 2
        frame_start = positional[1]
        frame_end = positional[2]
    elseif length(positional) == 1
        frame_start = positional[1]
        frame_end = positional[1]
    end

    nf = frame_end - frame_start + 1
    println("Hydrogen Precession — frames $frame_start:$frame_end ($nf) @ $(width)x$(height) spp=$spp")
    println("  ω₁₂=$(OMEGA_12) ω_L=$(OMEGA_L) γ=$(GAMMA) T=$(round(T_TOTAL; digits=1))")
    println("  Larmor period: $(round(π/OMEGA_L; digits=1)) ($(round(π/OMEGA_L/(2π); digits=1))s)")

    vs = 0.3
    t0 = time()
    basis = precompute_basis(; voxel_size=vs)
    println("  Basis: $(length(basis.coords)) voxels ($(round(time()-t0; digits=1))s)\n")

    for fidx in frame_start:frame_end
        render_frame(basis, fidx, outdir; voxel_size=vs,
                     width=width, height=height, spp=spp)
    end

    println("\n=== Done: $nf frames in $outdir ===")
end

main()
