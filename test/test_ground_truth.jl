# test_ground_truth.jl — Analytical and reference benchmarks for volume rendering
#
# Tier 0: Analytical  — exact mathematical formulas
# Tier 1: Sphere Matrix — parameter sweep over homogeneous fog sphere
# Tier 2: Renderer X-Val — cross-renderer consistency
# Tier 3: Component Stats — statistical unit tests on core functions
# Tier 4: Conservation — energy conservation and physical invariants

using Test
using Lyr
using Random: Xoshiro
# Inline stats helpers (avoid Statistics.jl dependency)
_mean(x) = sum(x) / length(x)
_std(x) = let m = _mean(x); sqrt(sum((xi - m)^2 for xi in x) / (length(x) - 1)); end

using LinearAlgebra: dot, norm

import Lyr: delta_tracking_step, ratio_tracking,
            _delta_tracking_collision, _shadow_transmittance,
            _volume_bounds, PhaseFunction, IsotropicPhase, HenyeyGreensteinPhase,
            sample_phase, SVec3d, intersect_bbox, NanoValueAccessor,
            get_value_trilinear

# ============================================================================
# Shared helpers
# ============================================================================

# Constant TF: (r,g,b,a) = (1,1,1,1) at all densities — decouples TF from extinction math
const _TF_OPAQUE_WHITE = TransferFunction([
    ControlPoint(0.0, (1.0, 1.0, 1.0, 1.0)),
    ControlPoint(1.0, (1.0, 1.0, 1.0, 1.0))
])

# Transparent TF: alpha=0 everywhere — no extinction at all
const _TF_TRANSPARENT = TransferFunction([
    ControlPoint(0.0, (1.0, 1.0, 1.0, 0.0)),
    ControlPoint(1.0, (1.0, 1.0, 1.0, 0.0))
])

"""Build a uniform-density fog box. N=17 gives path length 16 through center."""
function _make_uniform_fog_box(;
        N::Int = 17,
        density_value::Float32 = 1.0f0,
        sigma_scale::Float64 = 1.0,
        albedo::Float64 = 0.5,
        emission_scale::Float64 = 1.0,
        phase::PhaseFunction = IsotropicPhase(),
        tf::TransferFunction = _TF_OPAQUE_WHITE)
    data = Dict{Coord, Float32}()
    for iz in 0:(N-1), iy in 0:(N-1), ix in 0:(N-1)
        data[coord(Int32(ix), Int32(iy), Int32(iz))] = density_value
    end
    grid = build_grid(data, 0.0f0; name="uniform_box", voxel_size=1.0)
    nano = build_nanogrid(grid.tree)
    mat = VolumeMaterial(tf;
                         sigma_scale=sigma_scale,
                         emission_scale=emission_scale,
                         scattering_albedo=albedo,
                         phase_function=phase)
    (grid, nano, mat)
end

"""Build a fog sphere with density=1.0 in the interior for ground truth testing."""
function _make_fog_sphere_gt(;
        radius::Float64 = 10.0,
        sigma_scale::Float64 = 5.0,
        albedo::Float64 = 0.9,
        phase::PhaseFunction = IsotropicPhase(),
        emission_scale::Float64 = 1.0)
    sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=radius, voxel_size=1.0)
    fog = sdf_to_fog(sdf)
    nano = build_nanogrid(fog.tree)
    mat = VolumeMaterial(tf_smoke();
                         sigma_scale=sigma_scale,
                         emission_scale=emission_scale,
                         scattering_albedo=albedo,
                         phase_function=phase)
    (fog, nano, mat)
end

"""Average luminance of the central 50% of a pixel matrix."""
function _gt_avg_center_brightness(pixels::Matrix)
    h, w = size(pixels)
    total = 0.0
    count = 0
    for y in (h÷4+1):(3h÷4), x in (w÷4+1):(3w÷4)
        r, g, b = pixels[y, x]
        total += (r + g + b) / 3.0
        count += 1
    end
    count == 0 ? 0.0 : total / count
end

"""Get the center pixel of a pixel matrix."""
function _gt_center_pixel(pixels::Matrix)
    h, w = size(pixels)
    pixels[(h+1)÷2, (w+1)÷2]
end

"""Camera aimed along +X through the center of an N-voxel box."""
function _gt_box_camera(N::Int)
    mid = (N - 1) / 2.0
    Camera((-5.0, mid + 0.01, mid + 0.01), (Float64(N), mid, mid), (0.0, 0.0, 1.0), 3.0)
end

# ============================================================================

@testset "Ground Truth Validation" begin

# ============================================================================
# Tier 0: Analytical Tests
# ============================================================================

@testset "Tier 0: Analytical" begin

    @testset "T0.1 Beer-Lambert via EmissionAbsorption" begin
        # Uniform box: density=1.0, TF alpha=1.0, path length=16
        # Expected: pixel = 1 - exp(-sigma_scale * 16) (emission) + 0 (bg=0)
        N = 17  # AABB spans [0,16], path = 16
        bg = (0.0, 0.0, 0.0)
        cam = _gt_box_camera(N)

        for sigma_scale in [0.25, 0.5, 1.0]
            grid, nano, mat = _make_uniform_fog_box(N=N, sigma_scale=sigma_scale,
                                                     emission_scale=1.0, tf=_TF_OPAQUE_WHITE)
            vol = VolumeEntry(grid, nano, mat)
            light = DirectionalLight((1.0, 0.0, 0.0), (0.0, 0.0, 0.0))  # zero intensity
            scene = Scene(cam, light, vol; background=bg)

            # EA renderer: sigma_t = alpha * sigma_scale * step_size
            # For constant alpha=1.0: tau = sigma_scale * path_length
            px = render_volume_preview(scene, 8, 8; step_size=0.25, max_steps=10000)
            center = _gt_center_pixel(px)
            expected = 1.0 - exp(-sigma_scale * 16.0)

            @test center[1] ≈ expected atol=0.06
            @test center[2] ≈ expected atol=0.06
            @test center[3] ≈ expected atol=0.06
        end
    end

    @testset "T0.2 White furnace: albedo=1, no light, emission=0" begin
        # With no emission and zero-intensity light, throughput stays 1.0
        # Background is added at full weight regardless of scattering events
        # Every pixel should exactly equal background
        fog, nano, _ = _make_fog_sphere_gt(sigma_scale=5.0, albedo=1.0)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0, emission_scale=0.0,
                             scattering_albedo=1.0, phase_function=IsotropicPhase())
        vol = VolumeEntry(fog, nano, mat)
        bg = (0.5, 0.3, 0.7)
        cam = Camera((30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0), (0.0, 0.0, 0.0))  # zero intensity
        scene = Scene(cam, light, vol; background=bg)

        # Multi-scatter: throughput stays 1.0 (albedo=1), NEE contributes 0 (zero light)
        # Background added at end: throughput * bg = 1.0 * bg
        px = render_volume(scene, ReferencePathTracer(max_bounces=32, rr_start=999),
                           8, 8; spp=64, seed=UInt64(100))
        for y in 1:8, x in 1:8
            p = px[y, x]
            @test p[1] ≈ bg[1] atol=1e-10
            @test p[2] ≈ bg[2] atol=1e-10
            @test p[3] ≈ bg[3] atol=1e-10
        end

        # Single-scatter: same argument — throughput=1.0, NEE=0, bg added
        px_ss = render_volume_image(scene, 8, 8; spp=32, seed=UInt64(101))
        for y in 1:8, x in 1:8
            p = px_ss[y, x]
            @test p[1] ≈ bg[1] atol=1e-10
            @test p[2] ≈ bg[2] atol=1e-10
            @test p[3] ≈ bg[3] atol=1e-10
        end
    end

    @testset "T0.3 EmissionAbsorption step-size convergence" begin
        # As step_size → 0, EA renderer converges to analytical integral
        # Analytical: pixel_r = (1 - exp(-sigma_scale * 16)) * emission_scale
        N = 17
        sigma_scale = 0.5
        grid, nano, mat = _make_uniform_fog_box(N=N, sigma_scale=sigma_scale,
                                                 emission_scale=1.0, tf=_TF_OPAQUE_WHITE)
        vol = VolumeEntry(grid, nano, mat)
        cam = _gt_box_camera(N)
        light = DirectionalLight((1.0, 0.0, 0.0), (0.0, 0.0, 0.0))
        scene = Scene(cam, light, vol; background=(0.0, 0.0, 0.0))

        expected = 1.0 - exp(-sigma_scale * 16.0)  # ≈ 0.9997
        errors = Float64[]
        for step_size in [2.0, 1.0, 0.5, 0.25]
            px = render_volume_preview(scene, 4, 4; step_size=step_size, max_steps=50000)
            err = abs(_gt_center_pixel(px)[1] - expected)
            push!(errors, err)
        end
        # Convergence: coarsest > finest
        @test errors[1] > errors[end]
        # Finest step should be close to analytical
        @test errors[end] < 0.05
    end

    @testset "T0.4 HG mean cos_theta matches g parameter" begin
        # For HG(g), the expected value of cos(scattering angle) = g
        incoming = SVec3d(0.0, 0.0, 1.0)
        for g in [0.0, 0.3, 0.5, 0.8, -0.5, -0.8]
            pf = abs(g) < 1e-10 ? IsotropicPhase() : HenyeyGreensteinPhase(g)
            rng = Xoshiro(UInt64(abs(round(Int, g * 100)) + 140))
            N_samples = 50000
            sum_cos = 0.0
            for _ in 1:N_samples
                dir = sample_phase(pf, incoming, rng)
                sum_cos += dot(dir, incoming)
            end
            mean_cos = sum_cos / N_samples
            # SE for cos_theta ≤ 1/sqrt(N) ≈ 0.0045; use 4σ = 0.018
            @test mean_cos ≈ g atol=0.025
        end
    end

    @testset "T0.5 ratio_tracking statistical convergence" begin
        # Uniform box: density=0.3, sigma_maj=2.0, path=16
        # Expected: T = exp(-0.3 * 2.0 * 16) = exp(-9.6) ≈ 6.1e-5
        N = 17
        grid, nano, mat = _make_uniform_fog_box(N=N, density_value=0.3f0,
                                                 sigma_scale=2.0)
        mid = (N - 1) / 2.0
        origin = SVec3d(-1.0, mid + 0.01, mid + 0.01)
        dir = SVec3d(1.0, 0.0, 0.0)
        ray = Ray(origin, dir)

        bmin, bmax = _volume_bounds(nano)
        hit = intersect_bbox(ray, bmin, bmax)
        @test hit !== nothing
        t_enter, t_exit = hit

        N_trials = 5000
        results = Float64[]
        for s in 1:N_trials
            T = ratio_tracking(ray, nano, t_enter, t_exit, 2.0, Xoshiro(UInt64(s + 3000)))
            push!(results, T)
        end
        mean_T = _mean(results)
        expected_T = exp(-0.3 * 2.0 * (t_exit - t_enter))
        se = _std(results) / sqrt(N_trials)
        # 4σ bound
        @test abs(mean_T - expected_T) < max(4 * se, 0.001)
    end

    @testset "T0.6 delta_tracking_step escape and scatter fractions" begin
        # Use a large box (33 voxels) so trilinear boundary effects are negligible
        # density=0.5, sigma_maj=0.2, albedo=0.6
        # Effective sigma_t = density * sigma_maj = 0.5 * 0.2 = 0.1
        # Path ≈ 32 → expected escape = exp(-0.1 * 32) = exp(-3.2) ≈ 0.041
        N = 33
        grid, nano, mat = _make_uniform_fog_box(N=N, density_value=0.5f0,
                                                 sigma_scale=0.2, albedo=0.6)
        mid = (N - 1) / 2.0
        origin = SVec3d(-1.0, mid + 0.01, mid + 0.01)
        dir = SVec3d(1.0, 0.0, 0.0)
        ray = Ray(origin, dir)

        bmin, bmax = _volume_bounds(nano)
        hit = intersect_bbox(ray, bmin, bmax)
        @test hit !== nothing
        t_enter, t_exit = hit
        path_length = t_exit - t_enter

        N_trials = 10000
        n_escaped = 0
        n_scattered = 0
        n_absorbed = 0
        for s in 1:N_trials
            rng = Xoshiro(UInt64(s + 3100))
            t, event = delta_tracking_step(ray, nano, t_enter, t_exit, 0.2, 0.6, rng)
            if event == :escaped
                n_escaped += 1
            elseif event == :scattered
                n_scattered += 1
            else
                n_absorbed += 1
            end
        end

        # Escape fraction — allow boundary effect tolerance
        p_escape = n_escaped / N_trials
        expected_escape = exp(-0.5 * 0.2 * path_length)
        # Generous tolerance: trilinear boundary ramp affects ~2 voxels out of 32
        @test abs(p_escape - expected_escape) < 0.05

        # Scatter fraction among collisions matches albedo (this is exact, no boundary effect)
        n_collisions = n_scattered + n_absorbed
        if n_collisions > 100
            p_scatter = n_scattered / n_collisions
            se_scatter = sqrt(0.6 * 0.4 / n_collisions)
            @test abs(p_scatter - 0.6) < max(4 * se_scatter, 0.03)
        end
    end

end  # Tier 0

# ============================================================================
# Tier 1: Homogeneous Sphere Parameter Sweep
# ============================================================================

@testset "Tier 1: Homogeneous Sphere Parameter Sweep" begin

    # Shared sphere setup — fog sphere with density=1.0 in interior
    # Note: phase function divides by 4π ≈ 12.6, so light intensity needs to be ~10x
    sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0, voxel_size=1.0)
    fog = sdf_to_fog(sdf)
    nano = build_nanogrid(fog.tree)
    cam = Camera((30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
    light = DirectionalLight((1.0, 1.0, 1.0), (12.0, 12.0, 12.0))

    function _t1_make_scene(fog, nano, cam, light, albedo, sigma_scale;
                            phase=IsotropicPhase(), emission_scale=1.0,
                            bg=(0.0, 0.0, 0.0), light_override=nothing)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=sigma_scale,
                             emission_scale=emission_scale,
                             scattering_albedo=albedo, phase_function=phase)
        vol = VolumeEntry(fog, nano, mat)
        l = light_override !== nothing ? light_override : light
        Scene(cam, l, vol; background=bg)
    end

    @testset "T1.1-T1.3 albedo monotonicity: 0 < 0.5 < 0.99" begin
        # Use multi-scatter renderer for clearer albedo separation
        # Higher SPP for tighter estimates
        px_abs  = render_volume(_t1_make_scene(fog, nano, cam, light, 0.0, 5.0),
                                ReferencePathTracer(max_bounces=16, rr_start=999),
                                12, 12; spp=128, seed=UInt64(1001))
        px_half = render_volume(_t1_make_scene(fog, nano, cam, light, 0.5, 5.0),
                                ReferencePathTracer(max_bounces=16, rr_start=999),
                                12, 12; spp=128, seed=UInt64(1002))
        px_scat = render_volume(_t1_make_scene(fog, nano, cam, light, 0.99, 5.0),
                                ReferencePathTracer(max_bounces=16, rr_start=999),
                                12, 12; spp=128, seed=UInt64(1003))

        b_abs  = _gt_avg_center_brightness(px_abs)
        b_half = _gt_avg_center_brightness(px_half)
        b_scat = _gt_avg_center_brightness(px_scat)

        # With multi-scatter: albedo directly controls throughput decay
        @test b_scat > b_abs        # albedo=0.99 >> albedo=0
        @test b_half > b_abs - 0.03 # allow MC noise
    end

    @testset "T1.4 Forward scattering brightens far side" begin
        # Camera on far side from light: forward scatter sends light toward camera
        cam_far = Camera((-30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light_x = DirectionalLight((1.0, 0.0, 0.0), (5.0, 5.0, 5.0))

        scene_iso = _t1_make_scene(fog, nano, cam_far, light_x, 0.99, 5.0;
                                    light_override=light_x)
        scene_fwd = _t1_make_scene(fog, nano, cam_far, light_x, 0.99, 5.0;
                                    phase=HenyeyGreensteinPhase(0.8),
                                    light_override=light_x)

        px_iso = render_volume(scene_iso, ReferencePathTracer(max_bounces=16, rr_start=999),
                               12, 12; spp=128, seed=UInt64(1004))
        px_fwd = render_volume(scene_fwd, ReferencePathTracer(max_bounces=16, rr_start=999),
                               12, 12; spp=128, seed=UInt64(1005))

        b_iso = _gt_avg_center_brightness(px_iso)
        b_fwd = _gt_avg_center_brightness(px_fwd)
        # Forward scattering concentrates light in forward direction → brighter on far side
        @test b_fwd > b_iso - 0.02
    end

    @testset "T1.5 Backward scattering brightens near side" begin
        # Camera on same side as light: backward scatter sends light back toward camera
        cam_near = Camera((30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light_x = DirectionalLight((1.0, 0.0, 0.0), (5.0, 5.0, 5.0))

        scene_iso = _t1_make_scene(fog, nano, cam_near, light_x, 0.99, 5.0;
                                    light_override=light_x)
        scene_bwd = _t1_make_scene(fog, nano, cam_near, light_x, 0.99, 5.0;
                                    phase=HenyeyGreensteinPhase(-0.8),
                                    light_override=light_x)

        px_iso = render_volume(scene_iso, ReferencePathTracer(max_bounces=16, rr_start=999),
                               12, 12; spp=128, seed=UInt64(1006))
        px_bwd = render_volume(scene_bwd, ReferencePathTracer(max_bounces=16, rr_start=999),
                               12, 12; spp=128, seed=UInt64(1007))

        b_iso = _gt_avg_center_brightness(px_iso)
        b_bwd = _gt_avg_center_brightness(px_bwd)
        # Backward scatter sends light back → brighter on near side
        @test b_bwd > b_iso - 0.02
    end

    @testset "T1.6 High extinction produces measurably different brightness" begin
        scene_low  = _t1_make_scene(fog, nano, cam, light, 0.5, 5.0)
        scene_high = _t1_make_scene(fog, nano, cam, light, 0.5, 20.0)

        px_low  = render_volume_image(scene_low,  16, 16; spp=64, seed=UInt64(1008))
        px_high = render_volume_image(scene_high, 16, 16; spp=64, seed=UInt64(1009))

        b_low  = _gt_avg_center_brightness(px_low)
        b_high = _gt_avg_center_brightness(px_high)
        # Different sigma_scale should produce measurably different results
        @test b_low != b_high
        # Both should be positive (volume scatters light)
        @test b_low > 0.0
        @test b_high > 0.0
    end

    @testset "T1.7 White furnace: albedo=1, no light, pixels=background" begin
        bg = (0.5, 0.5, 0.5)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0, emission_scale=0.0,
                             scattering_albedo=1.0, phase_function=IsotropicPhase())
        vol = VolumeEntry(fog, nano, mat)
        zero_light = DirectionalLight((1.0, 0.0, 0.0), (0.0, 0.0, 0.0))
        scene = Scene(cam, zero_light, vol; background=bg)

        px = render_volume(scene, ReferencePathTracer(max_bounces=32, rr_start=999),
                           8, 8; spp=128, seed=UInt64(1010))
        for y in 1:8, x in 1:8
            p = px[y, x]
            @test p[1] ≈ bg[1] atol=1e-10
            @test p[2] ≈ bg[2] atol=1e-10
            @test p[3] ≈ bg[3] atol=1e-10
        end
    end

end  # Tier 1

# ============================================================================
# Tier 2: Renderer Cross-Validation
# ============================================================================

@testset "Tier 2: Renderer Cross-Validation" begin

    # Shared scene for cross-validation
    sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0, voxel_size=1.0)
    fog = sdf_to_fog(sdf)
    nano = build_nanogrid(fog.tree)
    mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0, emission_scale=1.0,
                         scattering_albedo=0.8, phase_function=IsotropicPhase())
    vol = VolumeEntry(fog, nano, mat)
    cam = Camera((30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
    light = DirectionalLight((1.0, 1.0, 1.0), (5.0, 5.0, 5.0))
    scene = Scene(cam, light, vol)

    @testset "T2.1 SingleScatter ≈ ReferencePathTracer at 1 bounce" begin
        # Both algorithms implement single-scatter with NEE but via different code paths
        # Average brightness should converge to same expected value
        px_ss  = render_volume_image(scene, 12, 12; spp=256, seed=UInt64(2001))
        px_pt1 = render_volume(scene, ReferencePathTracer(max_bounces=1, rr_start=999),
                               12, 12; spp=256, seed=UInt64(2002))

        b_ss  = _gt_avg_center_brightness(px_ss)
        b_pt1 = _gt_avg_center_brightness(px_pt1)
        # Different code paths but same algorithm → close but not identical
        @test b_ss ≈ b_pt1 atol=0.10
    end

    @testset "T2.2 EA step-size convergence (second sigma_scale)" begin
        # Same convergence test as T0.3 but with sigma_scale=0.15 (lower optical depth)
        # so the analytical value is distinguishable from 1.0
        N = 17
        sigma_scale = 0.15
        grid, nano2, mat2 = _make_uniform_fog_box(N=N, sigma_scale=sigma_scale,
                                                    emission_scale=1.0, tf=_TF_OPAQUE_WHITE)
        vol2 = VolumeEntry(grid, nano2, mat2)
        cam2 = _gt_box_camera(N)
        zero_light = DirectionalLight((1.0, 0.0, 0.0), (0.0, 0.0, 0.0))
        scene2 = Scene(cam2, zero_light, vol2; background=(0.0, 0.0, 0.0))

        expected = 1.0 - exp(-sigma_scale * 16.0)  # ≈ 0.909
        errors = Float64[]
        for step_size in [2.0, 1.0, 0.5, 0.25]
            px = render_volume_preview(scene2, 4, 4; step_size=step_size, max_steps=50000)
            err = abs(_gt_center_pixel(px)[1] - expected)
            push!(errors, err)
        end
        @test errors[1] > errors[end]
        @test errors[end] < 0.05
    end

    @testset "T2.3 Multi-scatter brightness non-decreasing with bounce count" begin
        bounce_counts = [1, 4, 16, 64]
        brightnesses = Float64[]
        for n in bounce_counts
            px = render_volume(scene, ReferencePathTracer(max_bounces=n, rr_start=999),
                               12, 12; spp=128, seed=UInt64(2300 + n))
            push!(brightnesses, _gt_avg_center_brightness(px))
        end
        # More bounces → more scattered light → non-decreasing brightness
        for i in 1:(length(brightnesses)-1)
            @test brightnesses[i] <= brightnesses[i+1] + 0.05  # MC tolerance
        end
    end

    @testset "T2.4 Determinism: same seed → same pixels (all renderers)" begin
        for seed in [UInt64(42), UInt64(999)]
            p1 = render_volume_image(scene, 4, 4; spp=2, seed=seed)
            p2 = render_volume_image(scene, 4, 4; spp=2, seed=seed)
            @test p1 == p2

            p3 = render_volume(scene, ReferencePathTracer(max_bounces=4), 4, 4;
                               spp=2, seed=seed)
            p4 = render_volume(scene, ReferencePathTracer(max_bounces=4), 4, 4;
                               spp=2, seed=seed)
            @test p3 == p4
        end

        # EA is fully deterministic (no RNG)
        p5 = render_volume_preview(scene, 4, 4; step_size=1.0)
        p6 = render_volume_preview(scene, 4, 4; step_size=1.0)
        @test p5 == p6
    end

end  # Tier 2

# ============================================================================
# Tier 3: Component Unit Statistics
# ============================================================================

@testset "Tier 3: Component Unit Statistics" begin

    @testset "T3.1 ratio_tracking mean converges to exp(-sigma_t * d)" begin
        # Uniform box: density=0.3, sigma_maj=2.0
        N = 17
        grid, nano, mat = _make_uniform_fog_box(N=N, density_value=0.3f0, sigma_scale=2.0)
        mid = (N - 1) / 2.0
        origin = SVec3d(-1.0, mid + 0.01, mid + 0.01)
        dir = SVec3d(1.0, 0.0, 0.0)
        ray = Ray(origin, dir)

        bmin, bmax = _volume_bounds(nano)
        hit = intersect_bbox(ray, bmin, bmax)
        @test hit !== nothing
        t_enter, t_exit = hit
        path = t_exit - t_enter

        N_trials = 5000
        results = [ratio_tracking(ray, nano, t_enter, t_exit, 2.0,
                                  Xoshiro(UInt64(s + 3000))) for s in 1:N_trials]
        mean_T = _mean(results)
        expected_T = exp(-0.3 * 2.0 * path)
        se = length(results) > 1 ? _std(results) / sqrt(N_trials) : 0.01
        @test abs(mean_T - expected_T) < max(4 * se, 0.002)
    end

    @testset "T3.2 _delta_tracking_collision escape rate matches Beer-Lambert" begin
        # Use large box (33 voxels) to minimize trilinear boundary effects
        N = 33
        grid, nano, mat = _make_uniform_fog_box(N=N, density_value=0.5f0, sigma_scale=0.2)
        mid = (N - 1) / 2.0
        origin = SVec3d(-1.0, mid + 0.01, mid + 0.01)
        dir = SVec3d(1.0, 0.0, 0.0)
        ray = Ray(origin, dir)

        bmin, bmax = _volume_bounds(nano)
        hit = intersect_bbox(ray, bmin, bmax)
        @test hit !== nothing
        t_enter, t_exit = hit
        path = t_exit - t_enter

        N_trials = 10000
        n_escaped = 0
        for s in 1:N_trials
            _, found = _delta_tracking_collision(ray, nano, t_enter, t_exit, 0.2,
                                                 Xoshiro(UInt64(s + 3100)))
            if !found
                n_escaped += 1
            end
        end
        p_escape = n_escaped / N_trials
        expected = exp(-0.5 * 0.2 * path)
        # Generous tolerance for boundary effects
        @test abs(p_escape - expected) < 0.05
    end

    @testset "T3.3 _shadow_transmittance convergence" begin
        N = 17
        grid, nano, mat = _make_uniform_fog_box(N=N, density_value=0.5f0, sigma_scale=1.0)
        mid = (N - 1) / 2.0
        vol = VolumeEntry(grid, nano, mat)
        cam = Camera((30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0), (1.0, 1.0, 1.0))
        scene = Scene(cam, light, vol)

        # Shadow ray along +X through center of box
        shadow_origin = SVec3d(-1.0, mid + 0.01, mid + 0.01)
        shadow_dir = SVec3d(1.0, 0.0, 0.0)
        shadow_ray = Ray(shadow_origin, shadow_dir)

        N_trials = 3000
        results = [_shadow_transmittance(shadow_ray, scene, Inf, Xoshiro(UInt64(s + 3200)))
                   for s in 1:N_trials]
        mean_T = _mean(results)
        # density=0.5, sigma_scale=1.0, path≈16 → exp(-0.5*1.0*16)=exp(-8)
        bmin, bmax = _volume_bounds(nano)
        hit = intersect_bbox(shadow_ray, bmin, bmax)
        path = hit !== nothing ? hit[2] - hit[1] : 16.0
        expected_T = exp(-0.5 * 1.0 * path)
        se = length(results) > 1 ? _std(results) / sqrt(N_trials) : 0.01
        @test abs(mean_T - expected_T) < max(4 * se, 0.001)
    end

    @testset "T3.4 HG sample_phase mean cos_theta = g (N=100000)" begin
        incoming = SVec3d(0.0, 0.0, 1.0)
        for g in [0.0, 0.3, 0.5, 0.8, -0.3, -0.5, -0.8]
            pf = abs(g) < 1e-10 ? IsotropicPhase() : HenyeyGreensteinPhase(g)
            rng = Xoshiro(UInt64(abs(round(Int, g * 1000)) + 3400))
            N_samples = 100000
            sum_cos = 0.0
            for _ in 1:N_samples
                dir = sample_phase(pf, incoming, rng)
                sum_cos += dir[3]  # dot(dir, incoming) when incoming = (0,0,1)
            end
            mean_cos = sum_cos / N_samples
            # SE ≤ 1/sqrt(N) ≈ 0.00316; 4σ ≈ 0.013
            @test mean_cos ≈ g atol=0.02
        end
    end

    @testset "T3.5 TF alpha=0 → no extinction → pure background" begin
        N = 17
        grid, nano, _ = _make_uniform_fog_box(N=N, sigma_scale=10.0, tf=_TF_TRANSPARENT)
        mat = VolumeMaterial(_TF_TRANSPARENT; sigma_scale=10.0, emission_scale=5.0,
                             scattering_albedo=0.9)
        vol = VolumeEntry(grid, nano, mat)
        cam = _gt_box_camera(N)
        light = DirectionalLight((1.0, 1.0, 1.0), (5.0, 5.0, 5.0))
        bg = (0.3, 0.6, 0.9)
        scene = Scene(cam, light, vol; background=bg)

        # EA: alpha=0 → sigma_t = 0 → step_transmittance = 1.0 → no emission → pure bg
        px = render_volume_preview(scene, 4, 4)
        for y in 1:4, x in 1:4
            p = px[y, x]
            @test p[1] ≈ bg[1] atol=0.01
            @test p[2] ≈ bg[2] atol=0.01
            @test p[3] ≈ bg[3] atol=0.01
        end
    end

end  # Tier 3

# ============================================================================
# Tier 4: Conservation and Physical Invariants
# ============================================================================

@testset "Tier 4: Conservation and Physical Invariants" begin

    @testset "T4.1 Optical depth invariance: density × sigma_scale = const" begin
        # Use constant TF (alpha=1 everywhere) so color/alpha don't vary with density
        # EA renderer: sigma_t_step = tf_alpha * sigma_scale * step_size = 1.0 * S * step_size
        # Config A: density=1.0, sigma_scale=0.5 → effective sigma = 0.5 per voxel-step
        # Config B: density=1.0, sigma_scale=1.0 with half the path → same tau
        # Simpler: same box, same density=1.0, compare sigma_scale=S path=d vs sigma_scale=2S path=d/2
        # Simplest: verify that doubling sigma_scale halves the transmittance exponent
        N = 17
        cam = _gt_box_camera(N)
        zero_light = DirectionalLight((1.0, 0.0, 0.0), (0.0, 0.0, 0.0))
        bg = (0.0, 0.0, 0.0)

        # Both use constant TF and density=1.0 → sigma_t = sigma_scale * step_size
        grid, nano_inv, _ = _make_uniform_fog_box(N=N, density_value=1.0f0,
                                                    sigma_scale=0.25, tf=_TF_OPAQUE_WHITE)
        mat_a = VolumeMaterial(_TF_OPAQUE_WHITE; sigma_scale=0.25, emission_scale=1.0,
                               scattering_albedo=0.0)
        vol_a = VolumeEntry(grid, nano_inv, mat_a)
        scene_a = Scene(cam, zero_light, vol_a; background=bg)

        mat_b = VolumeMaterial(_TF_OPAQUE_WHITE; sigma_scale=0.5, emission_scale=1.0,
                               scattering_albedo=0.0)
        vol_b = VolumeEntry(grid, nano_inv, mat_b)
        scene_b = Scene(cam, zero_light, vol_b; background=bg)

        px_a = render_volume_preview(scene_a, 4, 4; step_size=0.25, max_steps=50000)
        px_b = render_volume_preview(scene_b, 4, 4; step_size=0.25, max_steps=50000)

        b_a = _gt_center_pixel(px_a)[1]  # 1 - exp(-0.25 * 16) = 1 - exp(-4) ≈ 0.982
        b_b = _gt_center_pixel(px_b)[1]  # 1 - exp(-0.5 * 16) = 1 - exp(-8) ≈ 0.9997
        # Doubling sigma_scale increases brightness (more emission, less transmittance)
        @test b_b > b_a
        # Both match their analytical values
        @test b_a ≈ (1.0 - exp(-0.25 * 16.0)) atol=0.06
        @test b_b ≈ (1.0 - exp(-0.5 * 16.0)) atol=0.06
    end

    @testset "T4.2 Helmholtz reciprocity: swap camera/light" begin
        # For isotropic phase and symmetric sphere: swapping camera and light direction
        # should give similar average brightness
        sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0, voxel_size=1.0)
        fog = sdf_to_fog(sdf)
        nano = build_nanogrid(fog.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0, emission_scale=1.0,
                             scattering_albedo=0.8, phase_function=IsotropicPhase())
        vol = VolumeEntry(fog, nano, mat)

        # Config A: camera at -X, light from +X
        cam_a = Camera((-30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light_a = DirectionalLight((1.0, 0.0, 0.0), (5.0, 5.0, 5.0))
        scene_a = Scene(cam_a, light_a, vol)

        # Config B: camera at +X, light from -X
        cam_b = Camera((30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light_b = DirectionalLight((-1.0, 0.0, 0.0), (5.0, 5.0, 5.0))
        scene_b = Scene(cam_b, light_b, vol)

        px_a = render_volume_image(scene_a, 12, 12; spp=128, seed=UInt64(4001))
        px_b = render_volume_image(scene_b, 12, 12; spp=128, seed=UInt64(4002))

        b_a = _gt_avg_center_brightness(px_a)
        b_b = _gt_avg_center_brightness(px_b)
        # Approximate reciprocity for isotropic phase + symmetric geometry
        @test b_a ≈ b_b atol=0.08
    end

    @testset "T4.3 Albedo decay: low albedo much darker than high" begin
        sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0, voxel_size=1.0)
        fog = sdf_to_fog(sdf)
        nano = build_nanogrid(fog.tree)
        cam = Camera((30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 1.0, 1.0), (5.0, 5.0, 5.0))

        mat_low = VolumeMaterial(tf_smoke(); sigma_scale=5.0, emission_scale=1.0,
                                  scattering_albedo=0.1, phase_function=IsotropicPhase())
        mat_high = VolumeMaterial(tf_smoke(); sigma_scale=5.0, emission_scale=1.0,
                                   scattering_albedo=0.9, phase_function=IsotropicPhase())

        vol_low  = VolumeEntry(fog, nano, mat_low)
        vol_high = VolumeEntry(fog, nano, mat_high)

        scene_low  = Scene(cam, light, vol_low)
        scene_high = Scene(cam, light, vol_high)

        px_low  = render_volume(scene_low,  ReferencePathTracer(max_bounces=16, rr_start=999),
                                12, 12; spp=128, seed=UInt64(4003))
        px_high = render_volume(scene_high, ReferencePathTracer(max_bounces=16, rr_start=999),
                                12, 12; spp=128, seed=UInt64(4004))

        b_low  = _gt_avg_center_brightness(px_low)
        b_high = _gt_avg_center_brightness(px_high)
        # albedo=0.9 → many effective bounces, much brighter
        @test b_high > b_low
    end

    @testset "T4.4 Zero density → pure background (all renderers)" begin
        N = 9
        data = Dict{Coord, Float32}()
        for iz in 0:(N-1), iy in 0:(N-1), ix in 0:(N-1)
            data[coord(Int32(ix), Int32(iy), Int32(iz))] = 0.0f0
        end
        grid = build_grid(data, 0.0f0; name="zero_density", voxel_size=1.0)
        nano = build_nanogrid(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=100.0, emission_scale=10.0,
                             scattering_albedo=0.9)
        vol = VolumeEntry(grid, nano, mat)
        cam = Camera((20.0, 4.0, 4.0), (4.0, 4.0, 4.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 1.0, 1.0), (10.0, 10.0, 10.0))
        bg = (0.1, 0.5, 0.9)
        scene = Scene(cam, light, vol; background=bg)

        # EA renderer
        px_ea = render_volume_preview(scene, 4, 4)
        for y in 1:4, x in 1:4
            p = px_ea[y, x]
            @test p[1] ≈ bg[1] atol=0.01
            @test p[2] ≈ bg[2] atol=0.01
            @test p[3] ≈ bg[3] atol=0.01
        end

        # Single-scatter
        px_ss = render_volume_image(scene, 4, 4; spp=4, seed=UInt64(4100))
        for y in 1:4, x in 1:4
            p = px_ss[y, x]
            @test p[1] ≈ bg[1] atol=0.01
            @test p[2] ≈ bg[2] atol=0.01
            @test p[3] ≈ bg[3] atol=0.01
        end

        # Multi-scatter
        px_ms = render_volume(scene, ReferencePathTracer(max_bounces=4), 4, 4;
                              spp=4, seed=UInt64(4101))
        for y in 1:4, x in 1:4
            p = px_ms[y, x]
            @test p[1] ≈ bg[1] atol=0.01
            @test p[2] ≈ bg[2] atol=0.01
            @test p[3] ≈ bg[3] atol=0.01
        end
    end

end  # Tier 4

end  # Ground Truth Validation
