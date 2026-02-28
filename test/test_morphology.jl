@testset "Morphology" begin

    sphere = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0,
                                      voxel_size=1.0, half_width=3.0)
    n_original = active_voxel_count(sphere.tree)

    # ========================================================================
    # dilate
    # ========================================================================

    @testset "dilate: increases voxel count" begin
        d = dilate(sphere)
        @test active_voxel_count(d.tree) > n_original
    end

    @testset "dilate: more iterations → more voxels" begin
        d1 = dilate(sphere; iterations=1)
        d2 = dilate(sphere; iterations=2)
        @test active_voxel_count(d2.tree) > active_voxel_count(d1.tree)
    end

    @testset "dilate: preserves existing values" begin
        d = dilate(sphere)
        # Original active voxels should keep their values
        for c in [coord(10, 0, 0), coord(9, 0, 0), coord(8, 0, 0)]
            @test get_value(d.tree, c) == get_value(sphere.tree, c)
        end
    end

    @testset "dilate: activates new voxels" begin
        d = dilate(sphere)
        n_dilated = active_voxel_count(d.tree)
        n_new = n_dilated - n_original
        # At least some new voxels were activated
        @test n_new > 0
    end

    # ========================================================================
    # erode
    # ========================================================================

    @testset "erode: decreases voxel count" begin
        e = erode(sphere)
        @test active_voxel_count(e.tree) < n_original
    end

    @testset "erode: more iterations → fewer voxels" begin
        e1 = erode(sphere; iterations=1)
        e2 = erode(sphere; iterations=2)
        @test active_voxel_count(e2.tree) < active_voxel_count(e1.tree)
    end

    @testset "erode: preserves interior values" begin
        e = erode(sphere)
        # Deep narrow-band voxels should keep their values
        c = coord(10, 0, 0)  # center of narrow band
        if is_active(e.tree, c)
            @test get_value(e.tree, c) == get_value(sphere.tree, c)
        end
    end

    # ========================================================================
    # Composition
    # ========================================================================

    @testset "dilate then erode ≈ original count" begin
        d = dilate(sphere; iterations=1)
        de = erode(d; iterations=1)
        # Should be close to original (not exact due to topology)
        n_de = active_voxel_count(de.tree)
        @test n_de > n_original * 0.8
        @test n_de < n_original * 1.2
    end

    @testset "erode then dilate ≈ original count" begin
        e = erode(sphere; iterations=1)
        ed = dilate(e; iterations=1)
        n_ed = active_voxel_count(ed.tree)
        @test n_ed > n_original * 0.8
        @test n_ed < n_original * 1.2
    end

    # ========================================================================
    # Edge cases
    # ========================================================================

    @testset "empty grid" begin
        empty = build_grid(Dict{Coord, Float32}(), 0.0f0; name="empty")
        @test active_voxel_count(dilate(empty).tree) == 0
        @test active_voxel_count(erode(empty).tree) == 0
    end

    @testset "single voxel dilate" begin
        data = Dict(coord(0, 0, 0) => 1.0f0)
        grid = build_grid(data, 0.0f0; name="single")
        d = dilate(grid)
        # 1 center + 6 face neighbors = 7
        @test active_voxel_count(d.tree) == 7
    end

    @testset "single voxel erode" begin
        data = Dict(coord(0, 0, 0) => 1.0f0)
        grid = build_grid(data, 0.0f0; name="single")
        e = erode(grid)
        # Single voxel has no interior → all eroded
        @test active_voxel_count(e.tree) == 0
    end

end
