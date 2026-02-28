@testset "LevelSetOps" begin

    # Shared test grids
    sphere10 = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0,
                                        voxel_size=1.0, half_width=3.0)
    sphere5 = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=5.0,
                                       voxel_size=1.0, half_width=3.0)

    # ========================================================================
    # sdf_to_fog
    # ========================================================================

    @testset "sdf_to_fog: basic conversion" begin
        fog = sdf_to_fog(sphere10)
        @test fog isa Grid{Float32}
        @test active_voxel_count(fog.tree) > 0

        # Narrow-band interior (SDF ≈ -2.0): should be high density
        @test get_value(fog.tree, coord(8, 0, 0)) > 0.5f0
        # Far exterior: should be 0.0 (background)
        @test get_value(fog.tree, coord(100, 0, 0)) ≈ 0.0f0
    end

    @testset "sdf_to_fog: smooth ramp" begin
        fog = sdf_to_fog(sphere10)
        # Near-surface interior (SDF ≈ -1): intermediate density
        v_inner = get_value(fog.tree, coord(9, 0, 0))
        @test v_inner > 0.0f0

        # Deeper inside the narrow band: higher density
        v_deep = get_value(fog.tree, coord(8, 0, 0))
        @test v_deep > v_inner
    end

    @testset "sdf_to_fog: all values non-negative" begin
        fog = sdf_to_fog(sphere10)
        for (_, v) in active_voxels(fog.tree)
            @test v >= 0.0f0
            @test v <= 1.0f0
        end
    end

    # ========================================================================
    # sdf_interior_mask
    # ========================================================================

    @testset "sdf_interior_mask: basic" begin
        mask = sdf_interior_mask(sphere10)
        @test mask isa Grid{Float32}

        # Narrow-band interior (SDF < 0) → 1.0
        @test get_value(mask.tree, coord(9, 0, 0)) ≈ 1.0f0
        @test get_value(mask.tree, coord(8, 0, 0)) ≈ 1.0f0
        # Far outside → 0.0
        @test get_value(mask.tree, coord(100, 0, 0)) ≈ 0.0f0
    end

    @testset "sdf_interior_mask: boundary" begin
        mask = sdf_interior_mask(sphere10)
        # Just inside surface
        @test get_value(mask.tree, coord(9, 0, 0)) ≈ 1.0f0
        # At surface (SDF ≈ 0): depends on exact value
        # Just outside surface
        @test get_value(mask.tree, coord(11, 0, 0)) ≈ 0.0f0
    end

    @testset "sdf_interior_mask: binary values" begin
        mask = sdf_interior_mask(sphere10)
        for (_, v) in active_voxels(mask.tree)
            @test v ≈ 1.0f0  # only interior voxels are stored
        end
    end

    # ========================================================================
    # extract_isosurface_mask
    # ========================================================================

    @testset "extract_isosurface_mask: default isovalue" begin
        iso = extract_isosurface_mask(sphere10)
        @test iso isa Grid{Float32}
        n = active_voxel_count(iso.tree)
        @test n > 0

        # Origin is deep interior — no sign change neighbors → not in mask
        @test get_value(iso.tree, coord(0, 0, 0)) ≈ 0.0f0
        # Far outside → not in mask
        @test get_value(iso.tree, coord(100, 0, 0)) ≈ 0.0f0
    end

    @testset "extract_isosurface_mask: thin shell" begin
        iso = extract_isosurface_mask(sphere10)
        # Surface voxels should be in the mask
        @test get_value(iso.tree, coord(10, 0, 0)) ≈ 1.0f0

        # Mask should be much thinner than full narrow band
        full = active_voxel_count(sphere10.tree)
        shell = active_voxel_count(iso.tree)
        @test shell < full
    end

    @testset "extract_isosurface_mask: smaller sphere has fewer surface voxels" begin
        iso10 = extract_isosurface_mask(sphere10)
        iso5 = extract_isosurface_mask(sphere5)
        @test active_voxel_count(iso5.tree) < active_voxel_count(iso10.tree)
    end

    # ========================================================================
    # level_set_area
    # ========================================================================

    @testset "level_set_area: sphere" begin
        # Analytical: 4πr² = 4π(10²) ≈ 1256.6
        # Discrete face-counting overestimates by ~2x (axis-aligned faces vs curved surface)
        area = level_set_area(sphere10)
        @test area > 0.0
        expected = 4π * 10.0^2
        @test area > expected * 0.5
        @test area < expected * 2.5
    end

    @testset "level_set_area: larger sphere has more area" begin
        area10 = level_set_area(sphere10)
        area5 = level_set_area(sphere5)
        @test area10 > area5
    end

    # ========================================================================
    # level_set_volume
    # ========================================================================

    @testset "level_set_volume: sphere" begin
        # Counts only narrow-band interior (SDF < 0) active voxels.
        # For R=10, half_width=3: interior shell radius 7-10
        # Shell volume = 4/3π(10³ - 7³) ≈ 2747
        vol = level_set_volume(sphere10)
        @test vol > 0.0
        expected_shell = (4.0 / 3.0) * π * (10.0^3 - 7.0^3)
        @test vol > expected_shell * 0.8
        @test vol < expected_shell * 1.2
    end

    @testset "level_set_volume: larger sphere has more volume" begin
        vol10 = level_set_volume(sphere10)
        vol5 = level_set_volume(sphere5)
        @test vol10 > vol5
    end

    @testset "level_set_volume: scales with r³" begin
        vol10 = level_set_volume(sphere10)
        vol5 = level_set_volume(sphere5)
        # R=10 vs R=5: volume ratio should be ~(10/5)³ = 8
        ratio = vol10 / vol5
        @test ratio > 6.0
        @test ratio < 10.0
    end

    # ========================================================================
    # check_level_set
    # ========================================================================

    @testset "check_level_set: valid sphere" begin
        diag = check_level_set(sphere10)
        @test diag isa LevelSetDiagnostic
        @test diag.valid == true
        @test isempty(diag.issues)
        @test diag.active_count > 0
        @test diag.interior_count > 0
        @test diag.exterior_count > 0
    end

    @testset "check_level_set: wrong grid class" begin
        # Build a fog grid and check it as level set
        fog = sdf_to_fog(sphere10)
        diag = check_level_set(fog)
        @test diag.valid == false
        @test any(s -> occursin("Grid class", s), diag.issues)
    end

    @testset "check_level_set: negative background" begin
        bad = change_background(sphere10, -3.0f0)
        diag = check_level_set(bad)
        @test diag.valid == false
        @test any(s -> occursin("Background", s), diag.issues)
    end

    @testset "check_level_set: empty grid" begin
        empty_tree = RootNode{Float32}(3.0f0, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
        empty = Grid{Float32}("empty", GRID_LEVEL_SET, UniformScaleTransform(1.0), empty_tree)
        diag = check_level_set(empty)
        @test diag.valid == true  # empty is vacuously valid
        @test diag.active_count == 0
    end

end
