#!/usr/bin/env julia
# ============================================================================
# Lyr.jl Feature Showcase
# Comprehensive stills and movies demonstrating every visual feature
# Usage: julia --project -t auto scripts/showcase.jl
# ============================================================================

using Lyr
using Lyr.GR
using Random

const OUTDIR = joinpath(@__DIR__, "..", "showcase")
mkpath(OUTDIR)
const W, H = 512, 512

println("Julia threads: $(Threads.nthreads()) (maxid=$(Threads.maxthreadid()))")
if Threads.nthreads() < 4
    @error "Running with only $(Threads.nthreads()) thread(s)! This will be extremely slow.\n  Fix: julia --project -t auto scripts/showcase.jl\n  Or:  JULIA_NUM_THREADS=auto julia --project scripts/showcase.jl"
    exit(1)
end

function timed(f, label)
    print("  $label ... ")
    flush(stdout)
    t0 = time()
    result = f()
    dt = round(time() - t0, digits=1)
    println("done ($(dt)s)")
    result
end

# ============================================================================
# HYDROGEN WAVEFUNCTIONS (shared)
# ============================================================================

const a0 = 1.0

function laguerre(n::Int, alpha::Float64, x::Float64)
    n == 0 && return 1.0
    n == 1 && return 1.0 + alpha - x
    L0, L1 = 1.0, 1.0 + alpha - x
    for k in 2:n
        L0, L1 = L1, ((2k - 1 + alpha - x) * L1 - (k - 1 + alpha) * L0) / k
    end
    L1
end

function assoc_legendre(l::Int, m::Int, x::Float64)
    am = abs(m)
    pmm = 1.0
    if am > 0
        somx2 = sqrt(max(0.0, 1.0 - x^2))
        fact = 1.0
        for i in 1:am; pmm *= -fact * somx2; fact += 2.0; end
    end
    am == l && return pmm
    pmm1 = x * (2am + 1) * pmm
    (am + 1) == l && return pmm1
    for ll in (am+2):l
        pll = (x * (2ll - 1) * pmm1 - (ll + am - 1) * pmm) / (ll - am)
        pmm, pmm1 = pmm1, pll
    end
    pmm1
end

function real_Ylm(l::Int, m::Int, theta::Float64, phi::Float64)
    am = abs(m)
    norm = sqrt((2l + 1) / (4pi) * factorial(l - am) / factorial(l + am))
    P = assoc_legendre(l, am, cos(theta))
    m > 0 ? norm * P * sqrt(2.0) * cos(m * phi) :
    m < 0 ? norm * P * sqrt(2.0) * sin(am * phi) : norm * P
end

function radial_R(n::Int, l::Int, r::Float64)
    rho = 2.0 * r / (n * a0)
    norm = sqrt((2.0 / (n * a0))^3 * factorial(n - l - 1) / (2n * factorial(n + l)))
    norm * exp(-rho / 2) * rho^l * laguerre(n - l - 1, 2l + 1.0, rho)
end

function psi_nlm(n::Int, l::Int, m::Int, x::Float64, y::Float64, z::Float64)
    r = sqrt(x^2 + y^2 + z^2)
    r < 1e-10 && return (l == 0 ? radial_R(n, 0, 0.0) : 0.0) + 0.0im
    theta = acos(clamp(z / r, -1.0, 1.0))
    phi = atan(y, x)
    (radial_R(n, l, r) * real_Ylm(l, m, theta, phi)) + 0.0im
end

function hydrogen_field(n, l, m; scale=2.5)
    R_max = n^2 * a0 * scale
    ComplexScalarField3D(
        (x, y, z) -> psi_nlm(n, l, m, x, y, z),
        BoxDomain((-R_max, -R_max, -R_max), (R_max, R_max, R_max)),
        n * a0 * 0.5  # finer voxels: half the characteristic scale
    )
end

# ============================================================================
# ISING MODEL (shared)
# ============================================================================

function ising_mc!(spins, beta, n_sweeps, rng)
    L = size(spins, 1)
    for _ in 1:n_sweeps, k in 1:L, j in 1:L, i in 1:L
        nn = spins[mod1(i+1,L),j,k] + spins[mod1(i-1,L),j,k] +
             spins[i,mod1(j+1,L),k] + spins[i,mod1(j-1,L),k] +
             spins[i,j,mod1(k+1,L)] + spins[i,j,mod1(k-1,L)]
        dE = 2 * spins[i,j,k] * nn
        if dE <= 0 || rand(rng) < exp(-beta * dE)
            spins[i,j,k] = -spins[i,j,k]
        end
    end
end

function ising_field(spins)
    L = size(spins, 1)
    ScalarField3D(
        (x, y, z) -> begin
            i = clamp(round(Int, x) + 1, 1, L)
            j = clamp(round(Int, y) + 1, 1, L)
            k = clamp(round(Int, z) + 1, 1, L)
            spins[i,j,k] > 0 ? 1.0 : 0.0
        end,
        BoxDomain((0.0, 0.0, 0.0), (Float64(L-1), Float64(L-1), Float64(L-1))),
        1.0
    )
end

# ============================================================================
# BATCHED PARALLEL FRAME RENDERER
# ============================================================================

function render_frames_parallel(render_fn, N::Int, framedir::String; batch_size::Int=0)
    mkpath(framedir)
    bs = batch_size > 0 ? batch_size : max(1, Threads.nthreads())
    t0 = time()
    done = Threads.Atomic{Int}(0)

    for batch_start in 0:bs:(N-1)
        batch_end = min(batch_start + bs - 1, N - 1)
        @sync for frame in batch_start:batch_end
            Threads.@spawn begin
                render_fn(frame)
                n = Threads.atomic_add!(done, 1) + 1
                elapsed = time() - t0
                eta = elapsed / n * (N - n)
                n % max(1, N >> 3) == 0 &&
                    println("    frame $n/$N  (ETA $(round(Int, eta))s)")
            end
        end
    end
    elapsed = round(time() - t0, digits=1)
    println("  $N frames in $(elapsed)s → $framedir/")
end

# ============================================================================
# STILLS
# ============================================================================

println("=" ^ 60)
println("Lyr.jl Feature Showcase")
println("=" ^ 60)
t_start = time()

# --- 1. Hydrogen 1s ---
println("\n[1/17] Hydrogen 1s ground state")
timed("render") do
    visualize(hydrogen_field(1, 0, 0);
        transfer_function=tf_viridis(), sigma_scale=5.0, emission_scale=10.0,
        voxel_size=0.15,  # fine grid for smooth spherical cloud
        width=W, height=H, spp=8,
        camera=camera_orbit((0.0,0.0,0.0), 20.0; azimuth=30.0, elevation=20.0, fov=50.0),
        background=(0.003, 0.003, 0.01),
        output=joinpath(OUTDIR, "01_hydrogen_1s.ppm"))
end

# --- 2. Hydrogen 3d_z2 ---
println("\n[2/17] Hydrogen 3d_{z^2} orbital")
timed("render") do
    visualize(hydrogen_field(3, 2, 0);
        transfer_function=tf_viridis(), sigma_scale=3.0, emission_scale=6.0,
        width=W, height=H, spp=8,
        camera=camera_orbit((0.0,0.0,0.0), 120.0; azimuth=30.0, elevation=20.0, fov=45.0),
        background=(0.005, 0.005, 0.015),
        output=joinpath(OUTDIR, "02_hydrogen_3dz2.ppm"))
end

# --- 3. Hydrogen 4f ---
println("\n[3/17] Hydrogen 4f orbital (n=4 l=3 m=2)")
timed("render") do
    visualize(hydrogen_field(4, 3, 2);
        transfer_function=tf_blackbody(), sigma_scale=2.5, emission_scale=5.0,
        width=W, height=H, spp=8,
        camera=camera_orbit((0.0,0.0,0.0), 200.0; azimuth=45.0, elevation=25.0, fov=45.0),
        background=(0.002, 0.002, 0.008),
        output=joinpath(OUTDIR, "03_hydrogen_4f.ppm"))
end

# --- 4. Electric dipole ---
println("\n[4/17] Electric dipole field |E|")
timed("render") do
    d_sep = 2.0
    field = ScalarField3D(
        (x, y, z) -> begin
            rp = sqrt(x^2 + y^2 + (z - d_sep/2)^2)
            rm = sqrt(x^2 + y^2 + (z + d_sep/2)^2)
            (rp < 0.3 || rm < 0.3) && return 0.0
            Ex = x/rp^3 - x/rm^3
            Ey = y/rp^3 - y/rm^3
            Ez = (z - d_sep/2)/rp^3 - (z + d_sep/2)/rm^3
            sqrt(Ex^2 + Ey^2 + Ez^2)
        end,
        BoxDomain((-5.0,-5.0,-5.0), (5.0,5.0,5.0)), 0.5)  # finer characteristic scale
    visualize(field;
        transfer_function=tf_cool_warm(), sigma_scale=3.0, emission_scale=4.0,
        width=W, height=H, spp=8, denoise=true,
        output=joinpath(OUTDIR, "04_dipole_field.ppm"))
end

# --- 5. Magnetic bottle ---
println("\n[5/17] Magnetic bottle (two current loops)")
timed("render") do
    function biot_savart_loop(x, y, z, z0, R, I, N)
        Bx, By, Bz = 0.0, 0.0, 0.0
        for i in 0:N-1
            phi = 2pi * i / N
            dlx, dly = -sin(phi), cos(phi)
            rx, ry, rz = x - R*cos(phi), y - R*sin(phi), z - z0
            r3 = (rx^2 + ry^2 + rz^2 + 0.01)^1.5
            Bx += I * (dly * rz) / r3
            By += I * (-dlx * rz) / r3
            Bz += I * (dlx * ry - dly * rx) / r3
        end
        (Bx, By, Bz) ./ N
    end
    field = ScalarField3D(
        (x, y, z) -> begin
            b1 = biot_savart_loop(x, y, z, -2.0, 3.0, 1.0, 64)
            b2 = biot_savart_loop(x, y, z,  2.0, 3.0, 1.0, 64)
            sqrt((b1[1]+b2[1])^2 + (b1[2]+b2[2])^2 + (b1[3]+b2[3])^2)
        end,
        BoxDomain((-6.0,-6.0,-6.0), (6.0,6.0,6.0)), 0.8)
    visualize(field;
        transfer_function=tf_blackbody(), sigma_scale=2.0, emission_scale=5.0,
        width=W, height=H, spp=8,
        background=(0.005, 0.002, 0.01),
        output=joinpath(OUTDIR, "05_magnetic_bottle.ppm"))
end

# --- 6, 7, 8. Ising model ---
let L = 28, rng = Xoshiro(42)
    println("\n[6/17] Ising model (ordered, beta=0.35)")
    spins = rand(rng, (-1, 1), L, L, L)
    timed("MC + render") do
        ising_mc!(spins, 0.35, 400, rng)
        visualize(ising_field(spins);
            voxel_size=1.0, transfer_function=tf_cool_warm(),
            sigma_scale=1.5, emission_scale=3.0,
            width=W, height=H, spp=16, denoise=true,
            output=joinpath(OUTDIR, "06_ising_ordered.ppm"))
    end

    println("\n[7/17] Ising model (critical, beta=0.2216)")
    spins = rand(rng, (-1, 1), L, L, L)
    timed("MC + render") do
        ising_mc!(spins, 0.2216, 400, rng)
        visualize(ising_field(spins);
            voxel_size=1.0, transfer_function=tf_cool_warm(),
            sigma_scale=1.5, emission_scale=3.0,
            width=W, height=H, spp=16, denoise=true,
            output=joinpath(OUTDIR, "07_ising_critical.ppm"))
    end

    println("\n[8/17] Ising model (disordered, beta=0.10)")
    spins = rand(rng, (-1, 1), L, L, L)
    timed("MC + render") do
        ising_mc!(spins, 0.10, 100, rng)
        visualize(ising_field(spins);
            voxel_size=1.0, transfer_function=tf_cool_warm(),
            sigma_scale=1.5, emission_scale=3.0,
            width=W, height=H, spp=16, denoise=true,
            output=joinpath(OUTDIR, "08_ising_disordered.ppm"))
    end
end

# --- 9. FCC crystal ---
println("\n[9/17] Particle field: FCC crystal lattice")
timed("render") do
    positions = SVec3d[]
    for i in 0:5, j in 0:5, k in 0:5
        a = 2.0
        push!(positions, SVec3d(i*a, j*a, k*a))
        push!(positions, SVec3d(i*a + a/2, j*a + a/2, k*a))
        push!(positions, SVec3d(i*a + a/2, j*a, k*a + a/2))
        push!(positions, SVec3d(i*a, j*a + a/2, k*a + a/2))
    end
    field = ParticleField(positions)
    visualize(field;
        sigma=0.35, cutoff_sigma=3.0, voxel_size=0.15,
        transfer_function=tf_viridis(), sigma_scale=2.0, emission_scale=4.0,
        width=W, height=H, spp=8,
        output=joinpath(OUTDIR, "09_particles_crystal.ppm"))
end

# --- 10. Spiral galaxy ---
println("\n[10/17] Particle field: spiral galaxy")
timed("render") do
    rng = Xoshiro(123)
    positions = SVec3d[]
    for _ in 1:800  # Bulge
        r = 0.5 * abs(randn(rng))
        theta, phi = acos(2rand(rng)-1), 2pi*rand(rng)
        push!(positions, SVec3d(r*sin(theta)*cos(phi), r*cos(theta)*0.5, r*sin(theta)*sin(phi)))
    end
    for arm in 0:1  # Spiral arms
        offset = arm * pi
        for _ in 1:2500
            t = 3.5 * rand(rng)
            angle = t * 1.3 + offset
            r = 0.5 + t
            spread = 0.12 * (1 + t*0.25)
            x = r * cos(angle) + spread * randn(rng)
            z = r * sin(angle) + spread * randn(rng)
            y = 0.04 * randn(rng) * (1 + t*0.15)
            push!(positions, SVec3d(x, y, z))
        end
    end
    field = ParticleField(positions)
    visualize(field;
        sigma=0.12, cutoff_sigma=3.0, voxel_size=0.06,
        transfer_function=tf_blackbody(), sigma_scale=3.0, emission_scale=8.0,
        width=W, height=H, spp=8,
        camera=camera_orbit((0.0,0.0,0.0), 25.0; azimuth=30.0, elevation=55.0, fov=50.0),
        background=(0.001, 0.001, 0.003),
        output=joinpath(OUTDIR, "10_particles_galaxy.ppm"))
end

# --- 11. Schwarzschild volumetric thick disk ---
println("\n[11/17] Schwarzschild KS + volumetric thick disk")
timed("render") do
    M = 1.0
    m = SchwarzschildKS(M)
    cam = static_camera(m, 25.0, pi/2 - 0.25, 0.0, 55.0, (W, H))
    config = GRRenderConfig(
        integrator=IntegratorConfig(step_size=-0.05, max_steps=15000, r_max=100.0, stepper=:rk4),
        use_redshift=true, use_threads=true, samples_per_pixel=1)
    thick = ThickDisk(4.0, 18.0, 0.15, 2.0)
    vol = VolumetricMatter(m, thick, 4.0, 18.0)
    pixels = gr_render_image(cam, config; volume=vol)
    write_ppm(joinpath(OUTDIR, "11_schwarzschild_volumetric.ppm"), pixels)
end

# --- 12. Schwarzschild volumetric from above ---
println("\n[12/17] Schwarzschild KS volumetric (face-on)")
timed("render") do
    M = 1.0
    m = SchwarzschildKS(M)
    cam = static_camera(m, 35.0, 0.4, 0.0, 50.0, (W, H))
    config = GRRenderConfig(
        integrator=IntegratorConfig(step_size=-0.05, max_steps=15000, r_max=100.0, stepper=:rk4),
        use_redshift=true, use_threads=true, samples_per_pixel=1)
    thick = ThickDisk(4.0, 18.0, 0.15, 2.0)
    vol = VolumetricMatter(m, thick, 4.0, 18.0)
    pixels = gr_render_image(cam, config; volume=vol)
    write_ppm(joinpath(OUTDIR, "12_schwarzschild_faceon.ppm"), pixels)
end

# --- 13. Standing wave ---
println("\n[13/17] 3D standing wave (phonon mode)")
timed("render") do
    k = 2.5
    field = ScalarField3D(
        (x, y, z) -> (sin(k*x) * sin(k*y) * sin(k*z))^2,
        BoxDomain((-pi/k, -pi/k, -pi/k), (pi/k, pi/k, pi/k)),
        0.3)  # very fine voxels
    visualize(field;
        transfer_function=tf_cool_warm(), sigma_scale=2.0, emission_scale=4.0,
        width=W, height=H, spp=8,
        output=joinpath(OUTDIR, "13_standing_wave.ppm"))
end

# --- 14. Gaussian wavepacket ---
println("\n[14/17] Gaussian wavepacket with momentum")
timed("render") do
    sigma = 1.5
    kx = 3.0
    field = ComplexScalarField3D(
        (x, y, z) -> exp(-(x^2 + y^2 + z^2) / (2*sigma^2)) * exp(im * kx * x) *
                     (1 / (sigma * sqrt(2pi)))^1.5,
        BoxDomain((-6.0,-6.0,-6.0), (6.0,6.0,6.0)),
        sigma * 0.4)  # finer grid
    visualize(field;
        transfer_function=tf_viridis(), sigma_scale=3.0, emission_scale=6.0,
        width=W, height=H, spp=8,
        background=(0.003, 0.003, 0.01),
        output=joinpath(OUTDIR, "14_gaussian_wavepacket.ppm"))
end

# --- 15. Transfer function comparison ---
println("\n[15/17] Transfer function comparison (4 TFs)")
timed("render") do
    blob = ScalarField3D(
        (x, y, z) -> exp(-(x^2 + y^2 + z^2) / 2.0),
        BoxDomain((-4.0,-4.0,-4.0), (4.0,4.0,4.0)), 0.4)
    cam = camera_orbit((0.0,0.0,0.0), 40.0; azimuth=30.0, elevation=25.0, fov=45.0)
    tfs = [tf_viridis(), tf_blackbody(), tf_cool_warm(), tf_smoke()]
    hw = W >> 1
    hh = H >> 1
    combined = Matrix{NTuple{3, Float64}}(undef, H, W)
    for (idx, tf) in enumerate(tfs)
        p = visualize(blob;
            transfer_function=tf, sigma_scale=2.5, emission_scale=5.0,
            width=hw, height=hh, spp=4, camera=cam)
        row = idx <= 2 ? (1:hh) : (hh+1:H)
        col = isodd(idx) ? (1:hw) : (hw+1:W)
        combined[row, col] .= p
    end
    write_ppm(joinpath(OUTDIR, "15_transfer_functions.ppm"), combined)
end

# --- 16. Denoising comparison ---
println("\n[16/17] Denoising comparison (noisy vs denoised)")
timed("render") do
    field = ScalarField3D(
        (x, y, z) -> exp(-(x^2 + y^2 + z^2) / 3.0) * (1 + 0.3*sin(3*x)*sin(3*y)),
        BoxDomain((-5.0,-5.0,-5.0), (5.0,5.0,5.0)), 0.5)
    grid = voxelize(field; threshold=0.01)
    nanogrid = build_nanogrid(grid.tree)
    cam = camera_orbit((0.0,0.0,0.0), 50.0; azimuth=30.0, elevation=25.0, fov=45.0)
    tf = tf_viridis()
    mat = VolumeMaterial(tf; sigma_scale=2.5, emission_scale=5.0, scattering_albedo=0.4)
    light = DirectionalLight((0.5, 0.8, 1.0), (2.0, 2.0, 2.0))
    vol = VolumeEntry(grid, nanogrid, mat)
    scene = Scene(cam, light, vol; background=(0.01, 0.01, 0.02))

    hw = W >> 1
    noisy = render_volume_image(scene, hw, H; spp=1, seed=UInt64(42))
    noisy = tonemap_aces(noisy)
    denoised = denoise_bilateral(noisy)

    combined = Matrix{NTuple{3, Float64}}(undef, H, W)
    combined[:, 1:hw] .= noisy
    combined[:, hw+1:W] .= denoised
    write_ppm(joinpath(OUTDIR, "16_denoising_comparison.ppm"), combined)
end

# --- 17. Schwarzschild volumetric edge-on (dramatic) ---
println("\n[17/17] Schwarzschild KS volumetric (edge-on, dramatic)")
timed("render") do
    M = 1.0
    m = SchwarzschildKS(M)
    cam = static_camera(m, 22.0, pi/2 - 0.08, 0.0, 65.0, (W, H))
    config = GRRenderConfig(
        integrator=IntegratorConfig(step_size=-0.04, max_steps=18000, r_max=100.0, stepper=:rk4),
        use_redshift=true, use_threads=true, samples_per_pixel=1)
    thick = ThickDisk(3.5, 20.0, 0.12, 2.5)
    vol = VolumetricMatter(m, thick, 3.5, 20.0)
    pixels = gr_render_image(cam, config; volume=vol)
    write_ppm(joinpath(OUTDIR, "17_schwarzschild_edgeon.ppm"), pixels)
end

# ============================================================================
# MOVIES — parallel frame rendering
# ============================================================================

# --- Movie 1: Orbital rotation ---
println("\n[Movie 1/4] Orbiting hydrogen 3d_{z^2} (100 frames)")
let field = hydrogen_field(3, 2, 0), framedir = joinpath(OUTDIR, "mov1_orbital")
    grid = timed("voxelize") do
        voxelize(field; threshold=0.005)
    end
    nanogrid = build_nanogrid(grid.tree)
    tf = tf_viridis()
    mat = VolumeMaterial(tf; sigma_scale=3.0, emission_scale=6.0, scattering_albedo=0.4)
    light = DirectionalLight((0.5, 0.8, 1.0), (2.5, 2.5, 2.5))

    render_frames_parallel(100, framedir) do frame
        az = 360.0 * frame / 100
        cam = camera_orbit((0.0,0.0,0.0), 120.0; azimuth=az, elevation=20.0, fov=45.0)
        vol = VolumeEntry(grid, nanogrid, mat)
        scene = Scene(cam, light, vol; background=(0.005, 0.005, 0.015))
        pixels = render_volume_image(scene, W, H; spp=4, seed=UInt64(frame*1000+42))
        pixels = tonemap_aces(pixels)
        write_ppm(joinpath(framedir, "frame_$(lpad(frame, 4, '0')).ppm"), pixels)
    end
end

# --- Movie 2: Wavefunction evolution ---
println("\n[Movie 2/4] Wavefunction evolution (1s+2p, 100 frames)")
let framedir = joinpath(OUTDIR, "mov2_wavefunction")
    E1, E2 = -0.5, -0.125
    omega = E2 - E1
    R_max = 12.0

    render_frames_parallel(100, framedir) do frame
        t = 2pi * frame / (100 * omega)
        field = ComplexScalarField3D(
            (x, y, z) -> begin
                psi1 = psi_nlm(1, 0, 0, x, y, z) * exp(-im * E1 * t)
                psi2 = psi_nlm(2, 1, 0, x, y, z) * exp(-im * E2 * t)
                (psi1 + psi2) / sqrt(2.0)
            end,
            BoxDomain((-R_max,-R_max,-R_max), (R_max,R_max,R_max)),
            1.0)
        pixels = visualize(field;
            transfer_function=tf_viridis(), sigma_scale=5.0, emission_scale=10.0,
            voxel_size=0.3,
            width=W, height=H, spp=4,
            camera=camera_orbit((0.0,0.0,0.0), 80.0; azimuth=30.0, elevation=20.0, fov=45.0),
            background=(0.003, 0.003, 0.01))
        write_ppm(joinpath(framedir, "frame_$(lpad(frame, 4, '0')).ppm"), pixels)
    end
end

# --- Movie 3: Ising cooling ---
println("\n[Movie 3/4] Ising model cooling quench (80 frames)")
let N = 80, L = 24, framedir = joinpath(OUTDIR, "mov3_ising")
    mkpath(framedir)
    rng = Xoshiro(99)
    spins = rand(rng, (-1, 1), L, L, L)
    ising_mc!(spins, 0.08, 50, rng)

    # Sequential because Ising state is shared/correlated
    for frame in 0:N-1
        beta = 0.08 + (0.40 - 0.08) * frame / (N - 1)
        ising_mc!(spins, beta, 20, rng)
        pixels = visualize(ising_field(spins);
            voxel_size=1.0, transfer_function=tf_cool_warm(),
            sigma_scale=1.5, emission_scale=3.0,
            width=W, height=H, spp=8, denoise=true,
            camera=camera_orbit((Float64(L-1)/2, Float64(L-1)/2, Float64(L-1)/2),
                               Float64(L)*3.5; azimuth=30.0, elevation=25.0, fov=45.0))
        write_ppm(joinpath(framedir, "frame_$(lpad(frame, 4, '0')).ppm"), pixels)
        frame % 10 == 0 && println("    frame $frame/$N (beta=$(round(beta, digits=3)))")
    end
    println("  $N frames → $framedir/")
end

# --- Movie 4: Black hole flyby (volumetric!) ---
println("\n[Movie 4/4] Black hole volumetric flyby (100 frames) — PARALLEL")
let N = 100, framedir = joinpath(OUTDIR, "mov4_blackhole")
    M = 1.0
    m = SchwarzschildKS(M)
    thick = ThickDisk(4.0, 18.0, 0.15, 2.0)
    vol = VolumetricMatter(m, thick, 4.0, 18.0)

    render_frames_parallel(N, framedir) do frame
        phi = 2pi * frame / N
        theta = pi/2 - 0.2 + 0.15 * sin(2pi * frame / N)  # slight wobble
        r_cam = 25.0 + 5.0 * sin(4pi * frame / N)  # gentle zoom
        cam = static_camera(m, r_cam, theta, phi, 55.0, (W, H))
        config = GRRenderConfig(
            integrator=IntegratorConfig(step_size=-0.05, max_steps=15000, r_max=100.0, stepper=:rk4),
            use_redshift=true, use_threads=false, samples_per_pixel=1)
        pixels = gr_render_image(cam, config; volume=vol)
        write_ppm(joinpath(framedir, "frame_$(lpad(frame, 4, '0')).ppm"), pixels)
    end
end

# --- Summary ---
elapsed = round(time() - t_start, digits=0)
println("\n" * "=" ^ 60)
println("Showcase complete! Total time: $(elapsed)s")
println("Threads used: $(Threads.nthreads())")
println("=" ^ 60)
println("\nStills: $OUTDIR/*.ppm (17 images)")
println("\nTo convert stills to PNG:")
println("  cd $OUTDIR && for f in *.ppm; do convert \"\$f\" \"\${f%.ppm}.png\"; done")
println("\nTo make movies:")
for (dir, name) in [("mov1_orbital", "orbital_rotation"),
                     ("mov2_wavefunction", "wavefunction_evolution"),
                     ("mov3_ising", "ising_cooling"),
                     ("mov4_blackhole", "black_hole_flyby")]
    println("  ffmpeg -framerate 25 -i $OUTDIR/$dir/frame_%04d.ppm -c:v libx264 -pix_fmt yuv420p $OUTDIR/$name.mp4")
end
