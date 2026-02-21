#!/usr/bin/env julia
# hydrogen_orbitals.jl — Hydrogen atom orbital probability density visualization
#
# Computes |ψ_nlm|² for hydrogen wavefunctions using analytical formulas,
# voxelizes into VDB fog volumes, and renders with MC delta tracking.
# The Monte Carlo noise is intentional — it evokes the probabilistic nature
# of quantum mechanics.
#
# Usage:
#   julia --project scripts/hydrogen_orbitals.jl

using Lyr
using PNGFiles

# ============================================================================
# Section 1: Quantum mechanics — hydrogen wavefunctions
# ============================================================================

function factorial_int(n::Int)::Float64
    n <= 1 && return 1.0
    result = 1.0
    for i in 2:n
        result *= i
    end
    result
end

"""
Associated Laguerre polynomial L_p^q(x) via three-term recurrence.
For hydrogen: p = n-l-1, q = 2l+1.
"""
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

"""
Associated Legendre polynomial P_l^m(x) for m >= 0.
Includes Condon-Shortley phase (-1)^m.
"""
function assoc_legendre(l::Int, m::Int, x::Float64)::Float64
    # Starting value P_m^m
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

    # P_{m+1}^m
    pmmp1 = x * (2m + 1) * pmm
    l == m + 1 && return pmmp1

    # Upward recurrence to l
    pll = 0.0
    for ll in (m + 2):l
        pll = (x * (2ll - 1) * pmmp1 - (ll + m - 1) * pmm) / (ll - m)
        pmm = pmmp1
        pmmp1 = pll
    end
    pll
end

"""
Real-valued spherical harmonic Y_l^m(θ, φ).
m > 0 → cos(mφ) component, m < 0 → sin(|m|φ) component, m = 0 → axially symmetric.
"""
function real_spherical_harmonic(l::Int, m::Int, theta::Float64, phi::Float64)::Float64
    am = abs(m)
    norm = sqrt((2l + 1) / (4π) * factorial_int(l - am) / factorial_int(l + am))
    plm = assoc_legendre(l, am, cos(theta))
    if m > 0
        return sqrt(2.0) * norm * plm * cos(m * phi)
    elseif m < 0
        return sqrt(2.0) * norm * plm * sin(am * phi)
    else
        return norm * plm
    end
end

"""
Radial wavefunction R_nl(r) — unnormalized shape function.
We normalize the full density grid afterwards, so the overall constant doesn't matter.
a₀ = 1 (atomic units).
"""
function radial_wavefunction(n::Int, l::Int, r::Float64)::Float64
    ρ = 2.0 * r / n
    exp(-ρ / 2.0) * ρ^l * laguerre(n - l - 1, 2l + 1, ρ)
end

"""
Probability density |ψ_nlm(x,y,z)|² in Cartesian coordinates.
"""
function orbital_density(n::Int, l::Int, m::Int,
                         x::Float64, y::Float64, z::Float64)::Float64
    r = sqrt(x * x + y * y + z * z)
    r < 1e-12 && return 0.0  # origin: safe for all l (l>0 vanishes, l=0 loses one voxel)
    theta = acos(clamp(z / r, -1.0, 1.0))
    phi = atan(y, x)
    R = radial_wavefunction(n, l, r)
    Y = real_spherical_harmonic(l, m, theta, phi)
    (R * Y)^2
end

# ============================================================================
# Section 2: Grid sampling
# ============================================================================

"""
Sample |ψ_nlm|² on a 3D voxel grid. Returns normalized density in [0,1].
"""
function sample_orbital(n::Int, l::Int, m::Int;
                        voxel_size::Float64=0.4,
                        threshold::Float64=1e-6)
    R_max = 4.0 * n^2
    N_half = ceil(Int, R_max / voxel_size)
    R_max_sq = R_max * R_max

    data = Dict{Coord, Float32}()
    max_val = 0.0

    for ix in -N_half:N_half
        x = ix * voxel_size
        for iy in -N_half:N_half
            y = iy * voxel_size
            x2y2 = x * x + y * y
            for iz in -N_half:N_half
                z = iz * voxel_size
                r2 = x2y2 + z * z
                r2 > R_max_sq && continue

                ρ = orbital_density(n, l, m, x, y, z)
                if ρ > 0.0
                    data[Coord(Int32(ix), Int32(iy), Int32(iz))] = Float32(ρ)
                    max_val = max(max_val, ρ)
                end
            end
        end
    end

    # Normalize to [0, 1] and apply threshold
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
# Section 3: Transfer function — quantum glow aesthetic
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

# ============================================================================
# Section 4: Rendering
# ============================================================================

function render_orbital(n::Int, l::Int, m::Int, label::String, outdir::String;
                        voxel_size::Float64=0.4, width::Int=512, height::Int=512,
                        spp::Int=2)
    println("=== Orbital: $label (n=$n, l=$l, m=$m) ===")

    # 1. Sample density
    t0 = time()
    density = sample_orbital(n, l, m; voxel_size=voxel_size)
    println("  Sampled: $(length(density)) active voxels ($(round(time()-t0; digits=1))s)")

    isempty(density) && (println("  SKIP: empty density"); return)

    # 2. Build VDB grid + NanoGrid
    grid = build_grid(density, 0.0f0; name="orbital_$label",
                      grid_class=GRID_FOG_VOLUME, voxel_size=voxel_size)
    nanogrid = build_nanogrid(grid.tree)
    println("  Grid: $(active_voxel_count(grid.tree)) voxels, $(leaf_count(grid.tree)) leaves")

    # 3. Write VDB for external inspection
    write_vdb(joinpath(outdir, "$label.vdb"), grid)

    # 4. Camera: in index space, orbit around origin
    R_max = 4.0 * n^2
    N_half = ceil(Int, R_max / voxel_size)
    cam_dist = Float64(N_half) * 3.0
    camera = Camera(
        (cam_dist * 0.7, cam_dist * 0.5, cam_dist * 0.7),
        (0.0, 0.0, 0.0),
        (0.0, 1.0, 0.0),
        35.0
    )

    # 5. Scene
    tf = tf_orbital()
    material = VolumeMaterial(tf; sigma_scale=2.0, emission_scale=6.0,
                              scattering_albedo=0.4)
    volume = VolumeEntry(grid, nanogrid, material)
    light = DirectionalLight((1.0, 1.0, 0.8), (3.0, 3.0, 3.0))
    scene = Scene(camera, light, volume; background=(0.005, 0.005, 0.015))

    # 6. Monte Carlo render — low spp for intentional noise
    println("  Rendering $(width)x$(height) @ $(spp) spp...")
    t0 = time()
    pixels = render_volume_image(scene, width, height; spp=spp, seed=UInt64(42))
    println("  Render: $(round(time()-t0; digits=1))s")

    # 7. Tonemap and write (no denoising — noise is a feature)
    pixels = tonemap_aces(pixels)
    path = joinpath(outdir, "$label.png")
    write_png(path, pixels)
    println("  Wrote $path")
end

# ============================================================================
# Section 5: Orbital catalog
# ============================================================================

const ORBITALS = [
    (1, 0,  0, "1s"),
    (2, 0,  0, "2s"),
    (2, 1,  0, "2p_z"),
    (2, 1,  1, "2p_x"),
    (2, 1, -1, "2p_y"),
    (3, 0,  0, "3s"),
    (3, 1,  0, "3p_z"),
    (3, 2,  0, "3d_z2"),
    (3, 2,  1, "3d_xz"),
    (3, 2,  2, "3d_x2y2"),
]

function main()
    outdir = joinpath(@__DIR__, "hydrogen_orbitals")
    mkpath(outdir)

    # Parse CLI args: [orbital_label] [width] [height] [spp]
    # No args → render all at 512x512
    selected = nothing
    width, height, spp = 512, 512, 2
    for arg in ARGS
        if occursin("x", arg) && all(c -> isdigit(c) || c == 'x', arg)
            parts = split(arg, "x")
            width = parse(Int, parts[1])
            height = parse(Int, parts[2])
        elseif startswith(arg, "spp=")
            spp = parse(Int, arg[5:end])
        else
            selected = arg
        end
    end

    targets = if selected !== nothing
        filter(o -> o[4] == selected, ORBITALS)
    else
        ORBITALS
    end

    println("Hydrogen Orbital Visualizer — $(length(targets)) orbital(s) @ $(width)x$(height) spp=$(spp)")
    println("Output: $outdir\n")

    for (n, l, m, label) in targets
        vs = n <= 2 ? 0.3 : 0.5
        render_orbital(n, l, m, label, outdir; voxel_size=vs,
                       width=width, height=height, spp=spp)
        println()
    end

    println("=== Done: $(length(targets)) orbital(s) in $outdir ===")
end

main()
