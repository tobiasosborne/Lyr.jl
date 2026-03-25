# ScalarQEDGPU.jl — GPU-accelerated scalar QED scattering
#
# Recompute strategy: no P_tilde storage. Each frame recomputes Born products
# on GPU, with incremental accumulation across frames (frame f+1 = frame f + 1 step).
# This eliminates the 107 GB storage problem and the PCIe transfer bottleneck.
#
# Requires: CUDA.jl loaded before Lyr (`using CUDA; using Lyr`)

using KernelAbstractions
using Adapt

# ============================================================================
# I. KA Kernel: Wavepacket Evaluation
# ============================================================================

@kernel function wavepacket_kernel!(psi, @Const(x_vec), N::Int32,
                                     t::Float64,
                                     p0x::Float64, p0y::Float64, p0z::Float64,
                                     r0x::Float64, r0y::Float64, r0z::Float64,
                                     d::Float64, mass::Float64)
    i = @index(Global, Linear)
    # Column-major (ix, iy, iz) from linear index
    ix = Int32(((i - 1) % N) + 1)
    iy = Int32((((i - 1) ÷ N) % N) + 1)
    iz = Int32(((i - 1) ÷ (N * N)) + 1)

    @inbounds psi[i] = gaussian_wavepacket(
        x_vec[ix], x_vec[iy], x_vec[iz], t,
        (p0x, p0y, p0z), (r0x, r0y, r0z), d, mass)
end

"""
Evaluate wavepacket on grid using KA kernel (works on CPU and GPU).
"""
function evaluate_wavepacket_ka!(psi, x_dev, N::Int, backend,
                                  t::Float64, p0, r0, d::Float64, mass::Float64)
    ndrange = N^3
    wavepacket_kernel!(backend)(psi, x_dev, Int32(N), t,
        p0[1], p0[2], p0[3], r0[1], r0[2], r0[3], d, mass;
        ndrange=ndrange)
    KernelAbstractions.synchronize(backend)
    psi
end

# ============================================================================
# II. GPU Momentum Grid (arrays on device)
# ============================================================================

"""
    GPUMomentumGrid{A}

3D momentum grid with arrays on a KernelAbstractions backend (CPU or GPU).
Stores position, momentum, and energy grids plus pre-planned FFTs for the
target array type. All heavy arrays live on-device for zero-copy computation.
"""
struct GPUMomentumGrid{A<:AbstractArray}
    N::Int
    L::Float64
    dx::Float64
    x_dev::A                  # 1D position vector ON DEVICE (for wavepacket kernel)
    k2::A                     # |k|^2, 3D, on device
    kx::A
    ky::A
    kz::A
    E_k::A                    # free-particle energy, 3D, on device
    fft_plan::Any             # pre-planned FFT (FFTW or CUFFT)
    ifft_plan::Any            # pre-planned IFFT
end

"""
    GPUMomentumGrid(N, L; mass=1.0, backend=KernelAbstractions.CPU())

Build a momentum grid with arrays on the specified backend.
FFT plans are created for the target array type.
"""
function GPUMomentumGrid(N::Int, L::Float64; mass::Float64=1.0, backend=KernelAbstractions.CPU())
    dx = 2.0 * L / N
    x_cpu = collect(range(-L, stop=L - dx, length=N))
    k_cpu = collect(FFTW.fftfreq(N, 2π / dx))

    # Build 3D arrays on CPU
    k2_cpu = zeros(N, N, N)
    kx_cpu = zeros(N, N, N)
    ky_cpu = zeros(N, N, N)
    kz_cpu = zeros(N, N, N)
    E_k_cpu = zeros(N, N, N)

    for iz in 1:N, iy in 1:N, ix in 1:N
        kx_cpu[ix, iy, iz] = k_cpu[ix]
        ky_cpu[ix, iy, iz] = k_cpu[iy]
        kz_cpu[ix, iy, iz] = k_cpu[iz]
        ksq = k_cpu[ix]^2 + k_cpu[iy]^2 + k_cpu[iz]^2
        k2_cpu[ix, iy, iz] = ksq
        E_k_cpu[ix, iy, iz] = ksq / (2.0 * mass)
    end

    # Transfer to device
    x_dev = Adapt.adapt(backend, x_cpu)
    k2 = Adapt.adapt(backend, k2_cpu)
    kx = Adapt.adapt(backend, kx_cpu)
    ky = Adapt.adapt(backend, ky_cpu)
    kz = Adapt.adapt(backend, kz_cpu)
    E_k = Adapt.adapt(backend, E_k_cpu)

    # Create FFT plans on the target array type
    plan_arr = Adapt.adapt(backend, zeros(ComplexF64, N, N, N))
    fwd = plan_fft(plan_arr)
    inv = plan_ifft(plan_arr)

    GPUMomentumGrid{typeof(k2)}(N, L, dx, x_dev, k2, kx, ky, kz, E_k, fwd, inv)
end

# ============================================================================
# III. GPU Frame Evaluator (recompute + incremental accumulation)
# ============================================================================

"""
    GPUFrameState

Mutable state for incremental Born accumulation across frames.
Carries forward S1_k and S2_k accumulators.
"""
mutable struct GPUFrameState{A<:AbstractArray}
    grid::GPUMomentumGrid{<:AbstractArray}
    S1_k::A     # Born accumulator for electron 1 (ComplexF64, on device)
    S2_k::A     # Born accumulator for electron 2
    last_step::Int  # last accumulated time step index
    # Physics params
    p1::NTuple{3,Float64}; r1::NTuple{3,Float64}; d1::Float64
    p2::NTuple{3,Float64}; r2::NTuple{3,Float64}; d2::Float64
    mass::Float64; alpha::Float64
    times::Vector{Float64}
    mu2::Float64
    backend::Any
end

"""
    accumulate_one_step!(state, j)

Recompute one Born product at time step `j` on GPU and accumulate into the
running sums S1_k and S2_k. No P_tilde storage -- everything is computed and
consumed immediately, eliminating the O(N^3 * nsteps) memory bottleneck.
"""
function accumulate_one_step!(state::GPUFrameState, j::Int)
    grid = state.grid
    N = grid.N
    backend = state.backend
    tj = state.times[j]

    # Work arrays (allocated once, could be cached but allocations are fast on GPU)
    psi1 = similar(state.S1_k)
    psi2 = similar(state.S1_k)

    # Evaluate free wavepackets at time t_j
    evaluate_wavepacket_ka!(psi1, grid.x_dev, N, backend, tj,
                             state.p1, state.r1, state.d1, state.mass)
    evaluate_wavepacket_ka!(psi2, grid.x_dev, N, backend, tj,
                             state.p2, state.r2, state.d2, state.mass)

    # --- P_tilde_1: electron 1 scattered by electron 2 ---
    rho = real.(psi2 .* conj.(psi2))  # abs2
    rho_hat = grid.fft_plan * complex.(rho)
    rho_hat .*= 4π ./ (grid.k2 .+ state.mu2)  # Poisson
    V = real.(grid.ifft_plan * rho_hat)
    product = V .* psi1
    P_tilde_1_j = grid.fft_plan * product

    # Accumulate: S1_k += exp(i*E_k*t_j) * P_tilde_1_j
    phase = exp.(im .* grid.E_k .* tj)
    state.S1_k .+= phase .* P_tilde_1_j

    # --- P_tilde_2: electron 2 scattered by electron 1 ---
    rho .= real.(psi1 .* conj.(psi1))
    rho_hat = grid.fft_plan * complex.(rho)
    rho_hat .*= 4π ./ (grid.k2 .+ state.mu2)
    V = real.(grid.ifft_plan * rho_hat)
    product = V .* psi2
    P_tilde_2_j = grid.fft_plan * product

    phase = exp.(im .* grid.E_k .* tj)
    state.S2_k .+= phase .* P_tilde_2_j

    state.last_step = j
end

"""
    evaluate_frame_gpu(state, frame_idx; exchange_sign=0) → (density_cpu, em_cpu)

Incrementally accumulate Born correction up to frame_idx, then compute
electron density and EM cross-energy. Results returned as CPU Arrays.
"""
function evaluate_frame_gpu(state::GPUFrameState, frame_idx::Int;
                             exchange_sign::Int=0)
    grid = state.grid
    N = grid.N
    backend = state.backend
    alpha = state.alpha
    dt = state.times[2] - state.times[1]
    t = state.times[frame_idx]

    # Incremental accumulation: only compute steps not yet accumulated
    for j in (state.last_step + 1):frame_idx
        accumulate_one_step!(state, j)
    end

    # Scattered waves: psi_scat_k = -i*alpha*dt * exp(-i*E_k*t) * S_k
    phase_out = exp.((-im) .* grid.E_k .* t)
    psi1_scat_k = (-im * alpha * dt) .* phase_out .* state.S1_k
    psi2_scat_k = (-im * alpha * dt) .* phase_out .* state.S2_k

    # Free wavepackets
    psi1_free = similar(state.S1_k)
    psi2_free = similar(state.S1_k)
    evaluate_wavepacket_ka!(psi1_free, grid.x_dev, N, backend, t,
                             state.p1, state.r1, state.d1, state.mass)
    evaluate_wavepacket_ka!(psi2_free, grid.x_dev, N, backend, t,
                             state.p2, state.r2, state.d2, state.mass)

    # Total = free (k-space) + scattered
    psi1_k = grid.fft_plan * psi1_free
    psi2_k = grid.fft_plan * psi2_free
    psi1_k .+= psi1_scat_k
    psi2_k .+= psi2_scat_k

    # IFFT to position space
    psi1_total = grid.ifft_plan * psi1_k
    psi2_total = grid.ifft_plan * psi2_k

    # Normalize
    dV = grid.dx^3
    norm1 = sqrt(sum(abs2, psi1_total) * dV)
    norm2 = sqrt(sum(abs2, psi2_total) * dV)
    if norm1 > 0; psi1_total ./= norm1; end
    if norm2 > 0; psi2_total ./= norm2; end

    # Electron density (with exchange)
    electron_density = abs2.(psi1_total) .+ abs2.(psi2_total) .+
        exchange_sign .* 2.0 .* real.(conj.(psi1_total) .* psi2_total)

    # EM cross-energy
    rho1 = real.(abs2.(psi1_total))
    rho2 = real.(abs2.(psi2_total))

    # E-field from each charge distribution
    function efield_components(rho_in)
        rho_hat = grid.fft_plan * complex.(rho_in)
        Phi_hat = 4π .* rho_hat ./ (grid.k2 .+ state.mu2)
        Ex = real.(grid.ifft_plan * ((-im) .* grid.kx .* Phi_hat))
        Ey = real.(grid.ifft_plan * ((-im) .* grid.ky .* Phi_hat))
        Ez = real.(grid.ifft_plan * ((-im) .* grid.kz .* Phi_hat))
        return Ex, Ey, Ez
    end

    E1x, E1y, E1z = efield_components(rho1)
    E2x, E2y, E2z = efield_components(rho2)
    em_cross = E1x .* E2x .+ E1y .* E2y .+ E1z .* E2z

    # Transfer to CPU for rendering pipeline
    return Array(electron_density), Array(em_cross)
end

# ============================================================================
# IV. Field Protocol Wrapper (GPU path)
# ============================================================================

"""
    ScalarQEDScatteringGPU(p1, r1, d1, p2, r2, d2; kwargs...)

GPU-accelerated version of ScalarQEDScattering.
Uses recompute + incremental accumulation (no P_tilde storage).

Requires `using CUDA` before calling.
"""
function ScalarQEDScatteringGPU(p1::NTuple{3,Float64}, r1::NTuple{3,Float64}, d1::Float64,
                                 p2::NTuple{3,Float64}, r2::NTuple{3,Float64}, d2::Float64;
                                 mass::Float64=1.0,
                                 alpha::Float64=0.5,
                                 N::Int=256,
                                 L::Float64=120.0,
                                 t_range::Union{Nothing, Tuple{Float64,Float64}}=nothing,
                                 nsteps::Int=200,
                                 exchange_sign::Int=0,
                                 backend=nothing)
    if t_range === nothing
        sep = sqrt(sum((r1[i] - r2[i])^2 for i in 1:3))
        v_rel = sqrt(sum(((p1[i] - p2[i]) / mass)^2 for i in 1:3))
        t_half = v_rel > 0 ? 1.5 * sep / v_rel : 5000.0
        t_range = (-t_half, t_half)
    end

    # Auto-detect backend
    if backend === nothing
        backend = _default_gpu_backend()
    end

    println("Building GPU momentum grid ($(N)^3, backend=$(typeof(backend)))...")
    grid = GPUMomentumGrid(N, L; mass=mass, backend=backend)
    times = collect(range(t_range[1], stop=t_range[2], length=nsteps))
    mu2 = (0.1 / L)^2

    # Initialize accumulators on device
    S1_k = Adapt.adapt(backend, zeros(ComplexF64, N, N, N))
    S2_k = Adapt.adapt(backend, zeros(ComplexF64, N, N, N))

    state = GPUFrameState{typeof(S1_k)}(
        grid, S1_k, S2_k, 0,
        p1, r1, d1, p2, r2, d2, mass, alpha, times, mu2, backend)

    println("  GPU ready. Incremental accumulation — no P_tilde storage.")

    # Frame cache (CPU arrays)
    frame_cache = Dict{Int, Tuple{Array{Float64,3}, Array{Float64,3}}}()

    function nearest_frame(t)
        tc = clamp(t, times[1], times[end])
        idx = searchsortedlast(times, tc)
        clamp(idx, 1, length(times))
    end

    # Same trilinear interpolation as CPU path
    x_cpu = collect(range(-L, stop=L - 2L/N, length=N))
    dx = 2.0 * L / N

    function grid_interpolate(data::Array{Float64,3}, x::Float64, y::Float64, z::Float64)
        ix_f = (x - x_cpu[1]) / dx + 1.0
        iy_f = (y - x_cpu[1]) / dx + 1.0
        iz_f = (z - x_cpu[1]) / dx + 1.0
        ix_f = clamp(ix_f, 1.0, Float64(N))
        iy_f = clamp(iy_f, 1.0, Float64(N))
        iz_f = clamp(iz_f, 1.0, Float64(N))
        ix0 = clamp(floor(Int, ix_f), 1, N - 1)
        iy0 = clamp(floor(Int, iy_f), 1, N - 1)
        iz0 = clamp(floor(Int, iz_f), 1, N - 1)
        fx = ix_f - ix0; fy = iy_f - iy0; fz = iz_f - iz0

        c000 = data[ix0, iy0, iz0]; c100 = data[ix0+1, iy0, iz0]
        c010 = data[ix0, iy0+1, iz0]; c001 = data[ix0, iy0, iz0+1]
        c110 = data[ix0+1, iy0+1, iz0]; c101 = data[ix0+1, iy0, iz0+1]
        c011 = data[ix0, iy0+1, iz0+1]; c111 = data[ix0+1, iy0+1, iz0+1]

        c00 = c000*(1-fx) + c100*fx; c01 = c001*(1-fx) + c101*fx
        c10 = c010*(1-fx) + c110*fx; c11 = c011*(1-fx) + c111*fx
        c0 = c00*(1-fy) + c10*fy; c1 = c01*(1-fy) + c11*fy
        c0*(1-fz) + c1*fz
    end

    box = BoxDomain((-L, -L, -L), (L, L, L))
    char_scale = max(d1, d2)

    electron_field = TimeEvolution{ScalarField3D}(
        t -> begin
            idx = nearest_frame(t)
            if !haskey(frame_cache, idx)
                frame_cache[idx] = evaluate_frame_gpu(state, idx; exchange_sign=exchange_sign)
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
                frame_cache[idx] = evaluate_frame_gpu(state, idx; exchange_sign=exchange_sign)
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

# GPU backend infrastructure (_GPU_BACKEND, _default_gpu_backend, gpu_available,
# gpu_info) is defined in GPU.jl which is included before this file.
