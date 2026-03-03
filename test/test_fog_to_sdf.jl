using Test
using Lyr: Coord, coord, get_value, active_voxels, active_voxel_count,
           create_level_set_sphere, sdf_to_fog, fog_to_sdf, check_level_set,
           GRID_LEVEL_SET, GRID_FOG_VOLUME, build_grid,
           GradStencil, move_to!, gradient, ValueAccessor, is_active

@testset "fog_to_sdf" begin

    # ---------------------------------------------------------------
    # Test 1: Roundtrip — sphere SDF → fog → SDF → valid level set
    # ---------------------------------------------------------------
    @testset "roundtrip sphere" begin
        sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=8.0,
                                      voxel_size=1.0, half_width=3.0)
        fog = sdf_to_fog(sdf)
        @test fog.grid_class == GRID_FOG_VOLUME

        recovered = fog_to_sdf(fog; half_width=3.0)
        @test recovered.grid_class == GRID_LEVEL_SET

        diag = check_level_set(recovered)
        @test diag.valid
        @test diag.interior_count > 0
        @test diag.exterior_count > 0

        # Sign check: voxel near surface interior should be negative
        # (center is deep interior — outside narrow band, returns bg)
        # With radius=8, half_width=3: surface at 8, band from 5 to 11
        @test get_value(recovered.tree, coord(6, 0, 0)) < 0.0f0

        # Exterior voxel just outside surface should be positive
        @test get_value(recovered.tree, coord(10, 0, 0)) > 0.0f0
    end

    # ---------------------------------------------------------------
    # Test 2: Gradient magnitude ≈ 1.0 (SDF property: |∇φ| = 1)
    # ---------------------------------------------------------------
    @testset "gradient magnitude" begin
        sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0,
                                      voxel_size=1.0, half_width=3.0)
        fog = sdf_to_fog(sdf)
        recovered = fog_to_sdf(fog; half_width=3.0)

        stencil = GradStencil(recovered.tree)
        acc = ValueAccessor(recovered.tree)

        grad_mags = Float64[]
        n_sampled = 0
        for (c, v) in active_voxels(recovered.tree)
            # Only check voxels well inside the narrow band (not at boundary)
            abs(v) > 2.5 && continue
            move_to!(stencil, c)
            g = gradient(stencil)
            mag = sqrt(g[1]^2 + g[2]^2 + g[3]^2)
            push!(grad_mags, mag)
            n_sampled += 1
            n_sampled >= 200 && break
        end

        if !isempty(grad_mags)
            mean_mag = sum(grad_mags) / length(grad_mags)
            @test mean_mag > 0.7   # |∇φ| ≈ 1 with some tolerance
            @test mean_mag < 1.3
        end
    end

    # ---------------------------------------------------------------
    # Test 3: Empty fog → empty result
    # ---------------------------------------------------------------
    @testset "empty fog" begin
        empty_fog = build_grid(Dict{Coord, Float32}(), 0.0f0;
                               name="empty", grid_class=GRID_FOG_VOLUME,
                               voxel_size=1.0)
        result = fog_to_sdf(empty_fog)
        @test active_voxel_count(result.tree) == 0
        @test result.grid_class == GRID_LEVEL_SET
    end

    # ---------------------------------------------------------------
    # Test 4: Custom threshold — higher threshold = smaller interior
    # ---------------------------------------------------------------
    @testset "custom threshold" begin
        sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=8.0,
                                      voxel_size=1.0, half_width=3.0)
        fog = sdf_to_fog(sdf)

        low  = fog_to_sdf(fog; threshold=0.2f0, half_width=3.0)
        high = fog_to_sdf(fog; threshold=0.8f0, half_width=3.0)

        # Count interior voxels for each
        n_interior_low = 0
        for (_, v) in active_voxels(low.tree)
            v < 0 && (n_interior_low += 1)
        end

        n_interior_high = 0
        for (_, v) in active_voxels(high.tree)
            v < 0 && (n_interior_high += 1)
        end

        # Higher threshold means fewer voxels pass density > threshold,
        # so fewer interior voxels
        @test n_interior_low > n_interior_high
    end

end
