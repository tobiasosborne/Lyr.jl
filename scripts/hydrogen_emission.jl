#!/usr/bin/env julia
# hydrogen_emission.jl — Driven excitation and spontaneous emission of hydrogen
#
# A hydrogen atom in a magnetic field is excited by laser pulses and decays
# via spontaneous emission. Full Lindblad master equation, probability conserved.
#
# Physics:
#   Hilbert space: {|1s⟩, |2p,m=-1⟩, |2p,m=0⟩, |2p,m=+1⟩}
#   Hamiltonian: H₀ (energy levels) + H_Zeeman (B-field) + H_drive(t) (laser)
#   Dissipation: Lindblad with L_m = |1s⟩⟨2p_m| (spontaneous emission)
#   ODE: dρ/dt = -i[H(t),ρ] + γΣ(LρL† - ½{L†L,ρ}), solved with RK4
#
# Usage:
#   julia --project scripts/hydrogen_emission.jl                    # all 1800 frames
#   julia --project scripts/hydrogen_emission.jl 0 59               # frames 0-59
#   julia --project scripts/hydrogen_emission.jl 0 59 1920x1080 spp=2

using Lyr
using PNGFiles

# ============================================================================
# Section 1: Mathematical foundations (reused from hydrogen_orbitals.jl)
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
# Section 2: Physics — Lindblad in the rotating frame (RWA)
# ============================================================================
#
# Basis: 1=|1s⟩, 2=|2p,m=-1⟩, 3=|2p,m=0⟩, 4=|2p,m=+1⟩
#
# We work in the INTERACTION PICTURE rotating at ω₁₂. This removes the
# fast 1s-2p oscillation from the ODE, leaving only slow dynamics:
# Rabi flopping, Larmor precession, and spontaneous decay.
#
# The beat frequency (1 per second) reappears when we transform back
# to the lab frame for rendering: ρ_lab[1,m] = ρ̃[1,m]·e^{-iω₁₂t}
#
# Rotating-frame Hamiltonian:
#   H̃ = diag(0, -ω_L, 0, +ω_L) + (Ω(t)/2)·V   (no cosine carrier!)
#
# Movie: 60s @ 30fps = 1800 frames, 1 beat/second → ω₁₂ = 1 → T = 120π

const OMEGA_12 = 1.0       # 1s-2p transition frequency (for beat in lab frame)
const OMEGA_L  = 0.4       # Larmor frequency (Zeeman splitting)
const GAMMA    = 0.12      # Spontaneous emission rate

const N_FRAMES = 1800      # 60s × 30fps
const T_TOTAL  = 120.0 * π # 60 beat periods
const DT_FRAME = T_TOTAL / (N_FRAMES - 1)

# Rotating-frame static Hamiltonian: just the Zeeman shifts
const H_ZEEMAN = ComplexF64[
    0  0       0  0
    0 -OMEGA_L 0  0
    0  0       0  0
    0  0       0  OMEGA_L
]

# Dipole couplings (same as before, but NO cosine carrier — RWA baked in)
# x-polarization: drives 1s ↔ 2p_x = (|2p,-1⟩ - |2p,+1⟩)/√2
const V_X = let V = zeros(ComplexF64, 4, 4)
    V[1,2] =  1/√2; V[2,1] =  1/√2
    V[1,4] = -1/√2; V[4,1] = -1/√2
    V
end

# z-polarization: drives 1s ↔ 2p₀ (perfectly resonant in rotating frame)
const V_Z = let V = zeros(ComplexF64, 4, 4)
    V[1,3] = 1.0; V[3,1] = 1.0
    V
end

# ── Drive pulses ──
# Gaussian envelope: Ω(t) = Ω_peak · exp(-(t-t₀)²/(2σ²))
# In rotating frame, effective coupling is Ω_peak/2 · V (the /2 is already RWA).
# π-pulse condition: (Ω_peak/2) · |V_ij| · σ · √(2π) = π
#
# For z-pol (|V_ij|=1, zero detuning): Ω_peak = 2√(2π)/σ
# For x-pol (|V_ij|=1/√2, detuned by ω_L): need stronger pulse
#
# Narrative:
#   Pulse 1 (x-pol): t₀ = 11π (~5.5s), σ = 3π → excite to 2p_x (precesses)
#   Pulse 2 (z-pol): t₀ = 75π (~37.5s), σ = 3π → excite to 2p₀ (oscillates along z)

struct Pulse
    t_center::Float64
    sigma::Float64
    omega_peak::Float64
    coupling::Matrix{ComplexF64}
end

const SIGMA_PULSE = 3.0 * π

# z-pol π-pulse: resonant, |V|=1 → Ω_peak = 2√(2π)/σ
const OMEGA_PI_Z = 2.0 * sqrt(2π) / SIGMA_PULSE  # ≈ 0.533

# x-pol: off-resonant by ±ω_L, |V|=1/√2 → need ~3× stronger to overcome detuning
const OMEGA_PI_X = OMEGA_PI_Z * 3.0               # ≈ 1.6

const PULSES = [
    Pulse(11.0π,  SIGMA_PULSE, OMEGA_PI_X,  V_X),  # x-pol (strong, overcomes Zeeman)
    Pulse(75.0π,  SIGMA_PULSE, OMEGA_PI_Z,  V_Z),  # z-pol (resonant, clean π-pulse)
]

"""
Rotating-frame Hamiltonian: H̃(t) = H_Zeeman + Σ (Ω(t)/2)·V
No cosine carrier — the RWA has been applied analytically.
"""
function hamiltonian!(H::Matrix{ComplexF64}, t::Float64)
    copyto!(H, H_ZEEMAN)
    @inbounds for p in PULSES
        Δt = t - p.t_center
        envelope = p.omega_peak * exp(-Δt * Δt / (2.0 * p.sigma * p.sigma))
        if envelope > 1e-15
            half_env = envelope / 2.0
            for j in 1:4, i in 1:4
                H[i,j] += half_env * p.coupling[i,j]
            end
        end
    end
    nothing
end

"""
Transform rotating-frame ρ̃ to lab-frame ρ for spatial density computation.
Only the 1s↔2p coherences pick up a phase: ρ_lab[1,m] = ρ̃[1,m]·e^{-iω₁₂t}
"""
function to_lab_frame!(ρ_lab::Matrix{ComplexF64}, ρ_rot::Matrix{ComplexF64},
                       t::Float64)
    copyto!(ρ_lab, ρ_rot)
    phase = exp(-im * OMEGA_12 * t)
    phase_conj = conj(phase)
    @inbounds for m in 2:4
        ρ_lab[1,m] *= phase
        ρ_lab[m,1] *= phase_conj
    end
    nothing
end

"""
Lindblad RHS in rotating frame (identical dissipator — jump operators commute
with the rotating-frame transformation since L_m maps between subspaces).
"""
function lindblad_rhs!(dρ::Matrix{ComplexF64}, ρ::Matrix{ComplexF64},
                       H::Matrix{ComplexF64})
    # Commutator: -i[H̃, ρ̃]
    @inbounds for j in 1:4, i in 1:4
        s = zero(ComplexF64)
        for k in 1:4
            s += H[i,k] * ρ[k,j] - ρ[i,k] * H[k,j]
        end
        dρ[i,j] = -im * s
    end

    # Lindblad dissipator (same as lab frame)
    @inbounds begin
        p2p = GAMMA * (real(ρ[2,2]) + real(ρ[3,3]) + real(ρ[4,4]))
        dρ[1,1] += p2p
        for j in 2:4
            dρ[1,j] -= (GAMMA / 2) * ρ[1,j]
            dρ[j,1] -= (GAMMA / 2) * ρ[j,1]
        end
        for i in 2:4, j in 2:4
            dρ[i,j] -= GAMMA * ρ[i,j]
        end
    end
    nothing
end

# ============================================================================
# Section 3: RK4 integrator for density matrix
# ============================================================================

"""Integrate Lindblad master equation in rotating frame, return lab-frame ρ(t)."""
function integrate_lindblad(frame_start::Int, frame_end::Int)
    dt = 0.05  # ODE step (no fast carrier in rotating frame → can be larger)

    # Allocate work arrays — start in |1s⟩ ground state
    ρ  = zeros(ComplexF64, 4, 4); ρ[1,1] = 1.0
    k1 = similar(ρ); k2 = similar(ρ); k3 = similar(ρ); k4 = similar(ρ)
    ρ_tmp = similar(ρ); H = similar(ρ); ρ_lab = similar(ρ)

    t = 0.0
    results = Dict{Int, Matrix{ComplexF64}}()

    for fidx in 0:frame_end
        t_target = fidx * DT_FRAME

        # Integrate to t_target
        while t < t_target - dt/2
            # RK4 step
            hamiltonian!(H, t)
            lindblad_rhs!(k1, ρ, H)

            @. ρ_tmp = ρ + (dt/2) * k1
            hamiltonian!(H, t + dt/2)
            lindblad_rhs!(k2, ρ_tmp, H)

            @. ρ_tmp = ρ + (dt/2) * k2
            lindblad_rhs!(k3, ρ_tmp, H)

            @. ρ_tmp = ρ + dt * k3
            hamiltonian!(H, t + dt)
            lindblad_rhs!(k4, ρ_tmp, H)

            @. ρ = ρ + (dt/6) * (k1 + 2*k2 + 2*k3 + k4)
            t += dt
        end

        if fidx >= frame_start
            # Transform rotating-frame ρ̃ to lab-frame ρ for rendering
            to_lab_frame!(ρ_lab, ρ, t_target)
            results[fidx] = copy(ρ_lab)
        end
    end

    results
end

# ============================================================================
# Section 4: Precompute spatial basis wavefunctions
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
# Section 5: Per-frame density from density matrix ρ(t)
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
# Section 6: Transfer function and rendering
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

function render_frame(bg::BasisGrid, frame_idx::Int, ρ::Matrix{ComplexF64},
                      outdir::String;
                      voxel_size::Float64=0.3, width::Int=1920, height::Int=1080,
                      spp::Int=2)
    t = frame_idx * DT_FRAME

    density = compute_density(bg, ρ)
    isempty(density) && return

    grid = build_grid(density, 0.0f0; name="emission",
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
# Section 7: Main — CLI parsing and execution
# ============================================================================

function main()
    outdir = joinpath(@__DIR__, "emission_frames")
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
    println("Hydrogen Emission — frames $frame_start:$frame_end ($nf) @ $(width)x$(height) spp=$spp")
    println("  ω₁₂=$(OMEGA_12) ω_L=$(OMEGA_L) γ=$(GAMMA) T=$(round(T_TOTAL; digits=1))")
    println("  Pulses: x-pol@t=$(round(PULSES[1].t_center; digits=1)) " *
            "z-pol@t=$(round(PULSES[2].t_center; digits=1))")

    # 1. Precompute spatial basis
    vs = 0.3
    t0 = time()
    basis = precompute_basis(; voxel_size=vs)
    println("  Basis: $(length(basis.coords)) voxels ($(round(time()-t0; digits=1))s)")

    # 2. Integrate Lindblad master equation (fast: ~1s for all 1800 frames)
    t0 = time()
    rho_frames = integrate_lindblad(frame_start, frame_end)
    println("  ODE: $(length(rho_frames)) density matrices ($(round(time()-t0; digits=1))s)\n")

    # 3. Render
    for fidx in frame_start:frame_end
        render_frame(basis, fidx, rho_frames[fidx], outdir;
                     voxel_size=vs, width=width, height=height, spp=spp)
    end

    println("\n=== Done: $nf frames in $outdir ===")
end

main()
