# ScalarQED.jl — Tree-level scalar QED scattering via time-dependent Born approximation
#
# Two charged scalar particles scatter via virtual photon exchange, computed from the
# first-order Dyson series. Both electron density and EM energy density emerge as
# quantum expectation values of the perturbatively-evolved state.
#
# All quantities in atomic units (hbar = m_e = e = a_0 = 1).
# Physics references: docs/scattering_physics.md (EQ:TIME-DEP-BORN, EQ:EM-CROSS-ENERGY)

using FFTW

# ============================================================================
# I. Momentum Grid
# ============================================================================

"""
    MomentumGrid(N, L)

3D grid for spectral (FFT-based) computation.
Position space: x in [-L, L]^3 with N points per dimension.
Momentum space: conjugate grid with proper fftfreq ordering.
"""
struct MomentumGrid
    N::Int
    L::Float64
    dx::Float64
    x::Vector{Float64}       # 1D position grid
    k::Vector{Float64}       # 1D frequency grid (fftfreq ordering)
    k2::Array{Float64,3}     # |k|^2 at each 3D grid point
    kx::Array{Float64,3}     # k_x component
    ky::Array{Float64,3}     # k_y component
    kz::Array{Float64,3}     # k_z component
    E_k::Array{Float64,3}    # free-particle energy |k|^2/(2m)
end

function MomentumGrid(N::Int, L::Float64; mass::Float64=1.0)
    dx = 2.0 * L / N
    x = range(-L, stop=L - dx, length=N) |> collect
    k = fftfreq(N, 2π / dx) |> collect

    kx = zeros(N, N, N)
    ky = zeros(N, N, N)
    kz = zeros(N, N, N)
    k2 = zeros(N, N, N)
    E_k = zeros(N, N, N)

    for iz in 1:N, iy in 1:N, ix in 1:N
        kx[ix, iy, iz] = k[ix]
        ky[ix, iy, iz] = k[iy]
        kz[ix, iy, iz] = k[iz]
        ksq = k[ix]^2 + k[iy]^2 + k[iz]^2
        k2[ix, iy, iz] = ksq
        E_k[ix, iy, iz] = ksq / (2.0 * mass)
    end

    MomentumGrid(N, L, dx, x, k, k2, kx, ky, kz, E_k)
end

# ============================================================================
# II. Wavepacket Evaluation on Grid
# ============================================================================

"""
    evaluate_wavepacket_on_grid!(psi, grid, t, p0, r0, d, mass)

Evaluate a Gaussian wavepacket on the position-space grid at time `t`.
Writes results in-place to the 3D array `psi`. Uses the analytic
closed-form time evolution from `gaussian_wavepacket`.
"""
function evaluate_wavepacket_on_grid!(psi::Array{ComplexF64,3},
                                      grid::MomentumGrid,
                                      t::Float64,
                                      p0::NTuple{3,Float64},
                                      r0::NTuple{3,Float64},
                                      d::Float64, mass::Float64)
    N = grid.N
    x = grid.x
    for iz in 1:N, iy in 1:N, ix in 1:N
        psi[ix, iy, iz] = gaussian_wavepacket(x[ix], x[iy], x[iz], t, p0, r0, d, mass)
    end
    psi
end

# ============================================================================
# III. Poisson Solver (FFT-based)
# ============================================================================

"""
    poisson_solve(rho, grid, mu2) -> Array{Float64,3}

Solve the screened Poisson equation in Fourier space:
Phi_hat(k) = 4pi * rho_hat(k) / (|k|^2 + mu^2).

The screening mass `mu2` regularizes the k=0 singularity (infrared cutoff).
Returns the real-space potential Phi(x) via inverse FFT.
"""
function poisson_solve(rho::Array{Float64,3}, grid::MomentumGrid, mu2::Float64)
    # EQ:POISSON-FOURIER
    # Gaussian units: nabla^2 Phi = -4*pi*rho → Phi_hat = 4*pi * rho_hat / |k|^2
    rho_hat = fft(complex.(rho))
    for i in eachindex(rho_hat)
        rho_hat[i] *= 4π / (grid.k2[i] + mu2)
    end
    real.(ifft(rho_hat))
end

"""
    electric_field_from_density(rho, grid, mu2) -> (Ex, Ey, Ez)

Compute the electric field E = -grad(Phi) from a charge density `rho`,
where Phi solves the screened Poisson equation. Computed entirely in Fourier
space: E_hat_j = -i k_j * Phi_hat. Returns three 3D arrays (Ex, Ey, Ez).
"""
function electric_field_from_density(rho::Array{Float64,3}, grid::MomentumGrid, mu2::Float64)
    rho_hat = fft(complex.(rho))
    N = grid.N

    # Precompute Phi_hat (Gaussian units: 4*pi factor)
    Phi_hat = similar(rho_hat)
    for i in eachindex(Phi_hat)
        Phi_hat[i] = 4π * rho_hat[i] / (grid.k2[i] + mu2)
    end

    # E = -grad Phi: E_hat_comp = -i*k_comp * Phi_hat
    E_hat = similar(rho_hat)

    # Ex
    for i in eachindex(E_hat)
        E_hat[i] = -im * grid.kx[i] * Phi_hat[i]
    end
    Ex = real.(ifft(E_hat))

    # Ey
    for i in eachindex(E_hat)
        E_hat[i] = -im * grid.ky[i] * Phi_hat[i]
    end
    Ey = real.(ifft(E_hat))

    # Ez
    for i in eachindex(E_hat)
        E_hat[i] = -im * grid.kz[i] * Phi_hat[i]
    end
    Ez = real.(ifft(E_hat))

    return Ex, Ey, Ez
end

# ============================================================================
# IV. Precomputation of Born Products
# ============================================================================

"""
    ScatteringPrecompute

Precomputed Born products for the first-order Dyson series. Stores
`P_tilde(k, t_j) = FFT[V_other(x,t_j) * psi_free(x,t_j)]` at each time step
for both particles. These are the momentum-space integrands of the time-dependent
Born approximation, enabling O(1) per-frame evaluation via incremental accumulation.
"""
struct ScatteringPrecompute
    grid::MomentumGrid
    P_tilde_1::Vector{Array{ComplexF64,3}}  # electron 1 scattered by 2
    P_tilde_2::Vector{Array{ComplexF64,3}}  # electron 2 scattered by 1
    times::Vector{Float64}
    alpha::Float64
    mass::Float64
    p1::NTuple{3,Float64}
    r1::NTuple{3,Float64}
    d1::Float64
    p2::NTuple{3,Float64}
    r2::NTuple{3,Float64}
    d2::Float64
end

"""
    precompute_born_products(grid, p1, r1, d1, p2, r2, d2, mass, alpha, times)
        -> ScatteringPrecompute

Precompute the Born products for all time steps in the Dyson series. For each
time step `t_j`, computes `P_tilde(k,t_j) = FFT[V_other(x,t_j) * psi_free(x,t_j)]`
for both particles. This is the dominant cost -- O(N^3 log N) per step.

Physics: implements the time-dependent Born approximation (first-order
perturbation theory) for scalar QED scattering via virtual photon exchange.
"""
function precompute_born_products(grid::MomentumGrid,
                                  p1::NTuple{3,Float64}, r1::NTuple{3,Float64}, d1::Float64,
                                  p2::NTuple{3,Float64}, r2::NTuple{3,Float64}, d2::Float64,
                                  mass::Float64, alpha::Float64,
                                  times::Vector{Float64})
    N = grid.N
    mu2 = (0.1 / grid.L)^2

    psi1 = Array{ComplexF64}(undef, N, N, N)
    psi2 = Array{ComplexF64}(undef, N, N, N)
    rho  = Array{Float64}(undef, N, N, N)

    P_tilde_1 = Vector{Array{ComplexF64,3}}(undef, length(times))
    P_tilde_2 = Vector{Array{ComplexF64,3}}(undef, length(times))

    for (n, t) in enumerate(times)
        evaluate_wavepacket_on_grid!(psi1, grid, t, p1, r1, d1, mass)
        evaluate_wavepacket_on_grid!(psi2, grid, t, p2, r2, d2, mass)

        # Electron 1 scattered by electron 2's Coulomb field
        for i in eachindex(rho)
            rho[i] = abs2(psi2[i])
        end
        V2 = poisson_solve(rho, grid, mu2)
        product1 = similar(psi1)
        for i in eachindex(product1)
            product1[i] = V2[i] * psi1[i]
        end
        P_tilde_1[n] = fft(product1)

        # Electron 2 scattered by electron 1's Coulomb field
        for i in eachindex(rho)
            rho[i] = abs2(psi1[i])
        end
        V1 = poisson_solve(rho, grid, mu2)
        product2 = similar(psi2)
        for i in eachindex(product2)
            product2[i] = V1[i] * psi2[i]
        end
        P_tilde_2[n] = fft(product2)
    end

    ScatteringPrecompute(grid, P_tilde_1, P_tilde_2, times, alpha, mass,
                         p1, r1, d1, p2, r2, d2)
end

# ============================================================================
# V. Per-Frame Evaluation
# ============================================================================

"""
    evaluate_frame(precomp, frame_idx; exchange_sign=0)
        -> (electron_density::Array{Float64,3}, em_cross_energy::Array{Float64,3})

Evaluate both observables at time step `frame_idx` from precomputed Born products.

Returns:
- `electron_density`: |psi_1|^2 + |psi_2|^2 + exchange terms
- `em_cross_energy`: E_1 . E_2 (electromagnetic interaction energy density)

The `exchange_sign` controls quantum statistics:
0 = distinguishable particles, +1 = bosons, -1 = fermions (Moller scattering).
"""
function evaluate_frame(precomp::ScatteringPrecompute, frame_idx::Int;
                        exchange_sign::Int=0)
    grid = precomp.grid
    N = grid.N
    alpha = precomp.alpha
    dt = precomp.times[2] - precomp.times[1]
    t = precomp.times[frame_idx]
    mu2 = (0.1 / grid.L)^2

    # --- Incremental Born accumulation ---
    # EQ:BORN-INCREMENTAL
    # S_n(k) = sum_{j=1}^{n} exp(i*E_k*t_j) * P_tilde(k, t_j)
    S1_k = zeros(ComplexF64, N, N, N)
    S2_k = zeros(ComplexF64, N, N, N)
    for j in 1:frame_idx
        tj = precomp.times[j]
        for i in eachindex(S1_k)
            phase = exp(im * grid.E_k[i] * tj)
            S1_k[i] += phase * precomp.P_tilde_1[j][i]
            S2_k[i] += phase * precomp.P_tilde_2[j][i]
        end
    end

    # psi_scat(k, t_n) = -i*alpha*dt * exp(-i*E_k*t_n) * S_n(k)
    psi1_scat_k = similar(S1_k)
    psi2_scat_k = similar(S2_k)
    for i in eachindex(S1_k)
        phase = exp(-im * grid.E_k[i] * t)
        psi1_scat_k[i] = -im * alpha * dt * phase * S1_k[i]
        psi2_scat_k[i] = -im * alpha * dt * phase * S2_k[i]
    end

    # Free wavepackets
    psi1_free = Array{ComplexF64}(undef, N, N, N)
    psi2_free = Array{ComplexF64}(undef, N, N, N)
    evaluate_wavepacket_on_grid!(psi1_free, grid, t, precomp.p1, precomp.r1, precomp.d1, precomp.mass)
    evaluate_wavepacket_on_grid!(psi2_free, grid, t, precomp.p2, precomp.r2, precomp.d2, precomp.mass)

    # Total = free (in k-space) + scattered
    psi1_k = fft(psi1_free)
    psi2_k = fft(psi2_free)
    psi1_k .+= psi1_scat_k
    psi2_k .+= psi2_scat_k

    # IFFT to position space
    psi1_total = ifft(psi1_k)
    psi2_total = ifft(psi2_k)

    # Normalize each wavefunction (Born approximation doesn't conserve unitarity;
    # renormalization preserves the angular distribution of the scattered wave)
    dV = grid.dx^3
    norm1 = sqrt(sum(abs2, psi1_total) * dV)
    norm2 = sqrt(sum(abs2, psi2_total) * dV)
    if norm1 > 0; psi1_total ./= norm1; end
    if norm2 > 0; psi2_total ./= norm2; end

    # --- Electron density ---
    # For identical particles: ρ = |ψ₁|² + |ψ₂|² + exchange_sign * 2Re(ψ₁*ψ₂)
    # exchange_sign = -1 for fermions (Møller), +1 for bosons, 0 for distinguishable
    electron_density = Array{Float64}(undef, N, N, N)
    for i in eachindex(electron_density)
        electron_density[i] = abs2(psi1_total[i]) + abs2(psi2_total[i]) +
            exchange_sign * 2.0 * real(conj(psi1_total[i]) * psi2_total[i])
    end

    # --- EM cross-energy: E_1 . E_2 ---
    rho1 = Array{Float64}(undef, N, N, N)
    rho2 = Array{Float64}(undef, N, N, N)
    for i in eachindex(rho1)
        rho1[i] = abs2(psi1_total[i])
        rho2[i] = abs2(psi2_total[i])
    end

    E1x, E1y, E1z = electric_field_from_density(rho1, grid, mu2)
    E2x, E2y, E2z = electric_field_from_density(rho2, grid, mu2)

    em_cross = Array{Float64}(undef, N, N, N)
    for i in eachindex(em_cross)
        em_cross[i] = E1x[i] * E2x[i] + E1y[i] * E2y[i] + E1z[i] * E2z[i]
    end

    return electron_density, em_cross
end

# ============================================================================
# VI. Field Protocol Wrapper
# ============================================================================

"""
    ScalarQEDScattering(p1, r1, d1, p2, r2, d2; kwargs...)
        → (electron_field::TimeEvolution{ScalarField3D},
           em_field::TimeEvolution{ScalarField3D})

Set up a scalar QED scattering visualization from the tree-level Dyson series.

Returns two TimeEvolution fields:
1. `electron_field`: |psi_1|^2 + |psi_2|^2 (probability density, blue)
2. `em_field`: E_1 . E_2 (EM interaction energy = "virtual photon", orange)

# Keyword Arguments
- `mass=1.0` — particle mass (a.u.)
- `alpha=0.5` — coupling constant (enhanced for visibility; physical = 1/137)
- `N=64` — grid points per dimension
- `L=50.0` — half-width of computation box (a.u.)
- `t_range=auto` — time range (computed from kinematics if not given)
- `nsteps=200` — number of time steps for Dyson integral
- `exchange_sign=0` — 0=distinguishable, +1=bosons, -1=fermions (Møller)
"""
function ScalarQEDScattering(p1::NTuple{3,Float64}, r1::NTuple{3,Float64}, d1::Float64,
                              p2::NTuple{3,Float64}, r2::NTuple{3,Float64}, d2::Float64;
                              mass::Float64=1.0,
                              alpha::Float64=0.5,
                              N::Int=64,
                              L::Float64=50.0,
                              t_range::Union{Nothing, Tuple{Float64,Float64}}=nothing,
                              nsteps::Int=200,
                              exchange_sign::Int=0)
    if t_range === nothing
        sep = sqrt(sum((r1[i] - r2[i])^2 for i in 1:3))
        v_rel = sqrt(sum(((p1[i] - p2[i]) / mass)^2 for i in 1:3))
        t_half = v_rel > 0 ? 1.5 * sep / v_rel : 5000.0
        t_range = (-t_half, t_half)
    end

    grid = MomentumGrid(N, L; mass=mass)
    times = collect(range(t_range[1], stop=t_range[2], length=nsteps))

    println("Precomputing Born products ($nsteps time steps, $(N)^3 grid)...")
    precomp = precompute_born_products(grid, p1, r1, d1, p2, r2, d2, mass, alpha, times)
    println("  done.")

    # Frame cache
    frame_cache = Dict{Int, Tuple{Array{Float64,3}, Array{Float64,3}}}()

    function nearest_frame(t)
        tc = clamp(t, times[1], times[end])
        idx = searchsortedlast(times, tc)
        clamp(idx, 1, length(times))
    end

    function grid_interpolate(data::Array{Float64,3}, x::Float64, y::Float64, z::Float64)
        ix_f = (x - grid.x[1]) / grid.dx + 1.0
        iy_f = (y - grid.x[1]) / grid.dx + 1.0
        iz_f = (z - grid.x[1]) / grid.dx + 1.0

        ix_f = clamp(ix_f, 1.0, Float64(N))
        iy_f = clamp(iy_f, 1.0, Float64(N))
        iz_f = clamp(iz_f, 1.0, Float64(N))

        ix0 = clamp(floor(Int, ix_f), 1, N - 1)
        iy0 = clamp(floor(Int, iy_f), 1, N - 1)
        iz0 = clamp(floor(Int, iz_f), 1, N - 1)
        fx = ix_f - ix0
        fy = iy_f - iy0
        fz = iz_f - iz0

        c000 = data[ix0,   iy0,   iz0]
        c100 = data[ix0+1, iy0,   iz0]
        c010 = data[ix0,   iy0+1, iz0]
        c001 = data[ix0,   iy0,   iz0+1]
        c110 = data[ix0+1, iy0+1, iz0]
        c101 = data[ix0+1, iy0,   iz0+1]
        c011 = data[ix0,   iy0+1, iz0+1]
        c111 = data[ix0+1, iy0+1, iz0+1]

        c00 = c000 * (1 - fx) + c100 * fx
        c01 = c001 * (1 - fx) + c101 * fx
        c10 = c010 * (1 - fx) + c110 * fx
        c11 = c011 * (1 - fx) + c111 * fx

        c0 = c00 * (1 - fy) + c10 * fy
        c1 = c01 * (1 - fy) + c11 * fy

        c0 * (1 - fz) + c1 * fz
    end

    box = BoxDomain((-L, -L, -L), (L, L, L))
    char_scale = max(d1, d2)

    electron_field = TimeEvolution{ScalarField3D}(
        t -> begin
            idx = nearest_frame(t)
            if !haskey(frame_cache, idx)
                frame_cache[idx] = evaluate_frame(precomp, idx; exchange_sign=exchange_sign)
            end
            ed, _ = frame_cache[idx]
            ScalarField3D(
                (x, y, z) -> max(0.0, grid_interpolate(ed, x, y, z)),
                box, char_scale
            )
        end,
        t_range,
        times[2] - times[1]
    )

    em_field = TimeEvolution{ScalarField3D}(
        t -> begin
            idx = nearest_frame(t)
            if !haskey(frame_cache, idx)
                frame_cache[idx] = evaluate_frame(precomp, idx; exchange_sign=exchange_sign)
            end
            _, em = frame_cache[idx]
            ScalarField3D(
                (x, y, z) -> max(0.0, grid_interpolate(em, x, y, z)),
                box, char_scale
            )
        end,
        t_range,
        times[2] - times[1]
    )

    return electron_field, em_field
end
