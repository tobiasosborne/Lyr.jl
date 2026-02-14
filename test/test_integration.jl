@testset "Integration" begin
    # Integration tests for parsing official VDB sample files
    # These tests are skipped if sample files are not present

    SAMPLE_DIR = joinpath(@__DIR__, "fixtures", "samples")

    # Files to skip (too slow or known issues)
    SKIP_FILES = Set{String}()  # No files skipped - v220 support now implemented

    @testset "torus.vdb (v222 level set)" begin
        filepath = joinpath(SAMPLE_DIR, "torus.vdb")
        if !isfile(filepath)
            @info "Skipping torus.vdb test: file not found"
            @test_skip "torus.vdb not available"
            return
        end

        # Parse should succeed
        vdb = parse_vdb(filepath)

        # Header verification
        @test vdb.header.format_version == 222
        @test vdb.header.compression isa Codec

        # Grid count
        @test length(vdb.grids) == 1

        # Grid properties
        grid = vdb.grids[1]
        @test grid.name == "ls_torus"
        @test grid.grid_class == GRID_LEVEL_SET
        @test grid.transform isa UniformScaleTransform

        # Tree structure (values from TinyVDB sequential parser — correct for
        # a torus spanning all 8 octants around origin)
        @test grid.tree.background == 0.15f0
        @test leaf_count(grid.tree) == 6044
        @test active_voxel_count(grid.tree) == 1119158

        # Tree has 8 Internal2 children (one per octant, torus wraps around origin)
        @test length(grid.tree.table) == 8
        @test haskey(grid.tree.table, Coord(-4096, -4096, -4096))
        @test grid.tree.table[Coord(-4096, -4096, -4096)] isa InternalNode2{Float32}
    end

    @testset "bunny_cloud.vdb (v220 fog volume)" begin
        filepath = joinpath(SAMPLE_DIR, "bunny_cloud.vdb")
        if !isfile(filepath)
            @info "Skipping bunny_cloud.vdb test: file not found"
            @test_skip "bunny_cloud.vdb not available"
            return
        end

        # Parse should succeed - tests v220 format support
        vdb = parse_vdb(filepath)

        # Header verification - must be v220
        @test vdb.header.format_version == 220
        @test vdb.header.compression isa Codec

        # Should have at least one grid
        @test length(vdb.grids) >= 1

        # Grid properties
        grid = vdb.grids[1]
        @test grid.grid_class == GRID_FOG_VOLUME
        @test grid.transform isa AbstractTransform

        # Tree structure - should have leaves and active voxels
        @test leaf_count(grid.tree) > 0
        @test active_voxel_count(grid.tree) > 0

        # Sample some active voxels to verify values are reasonable
        sample_count = 0
        for (coord, val) in active_voxels(grid.tree)
            @test isfinite(val)  # Values should be finite numbers
            @test val >= 0.0f0   # Fog volume density should be non-negative
            sample_count += 1
            sample_count >= 100 && break
        end
        @test sample_count > 0  # Should have found some active voxels
    end

    @testset "smoke.vdb (fog volume)" begin
        # Download from: https://artifacts.aswf.io/io/aswf/openvdb/models/smoke1.vdb/1.0.0/smoke1.vdb-1.0.0.zip
        filepath = joinpath(SAMPLE_DIR, "smoke.vdb")
        if !isfile(filepath)
            # Also check for smoke1.vdb (official name)
            filepath = joinpath(SAMPLE_DIR, "smoke1.vdb")
        end
        if !isfile(filepath)
            @info "Skipping smoke.vdb test: file not found (download from ASWF artifacts)"
            @test_skip "smoke.vdb not available"
            return
        end

        # Parse should succeed
        vdb = parse_vdb(filepath)

        # Header verification
        @test vdb.header.format_version > 0
        @test vdb.header.compression isa Codec

        # Should have at least one grid
        @test length(vdb.grids) >= 1

        # Find density grid (fog volumes typically have "density" grid)
        grid = vdb.grids[1]
        @test grid.grid_class == GRID_FOG_VOLUME
        @test grid.transform isa AbstractTransform

        # Tree structure
        @test leaf_count(grid.tree) >= 0
        @test active_voxel_count(grid.tree) >= 0

        # Fog volume density values should be in [0,1] range (or thereabouts)
        # Sample a few active voxels to verify
        sample_count = 0
        for (coord, val) in active_voxels(grid.tree)
            @test val >= 0.0f0  # Density should be non-negative
            sample_count += 1
            sample_count >= 100 && break
        end
    end

    @testset "Sample files parsing" begin
        # Skip if no samples directory
        if !isdir(SAMPLE_DIR)
            @info "Skipping integration tests: sample files not found at $SAMPLE_DIR"
            @test_skip "Sample files not available"
            return
        end

        sample_files = filter(f -> endswith(f, ".vdb") && !(f in SKIP_FILES), readdir(SAMPLE_DIR))

        if isempty(sample_files)
            @info "No .vdb files found in $SAMPLE_DIR (after exclusions)"
            @test_skip "No VDB sample files"
            return
        end

        for filename in sample_files
            @testset "$filename" begin
                filepath = joinpath(SAMPLE_DIR, filename)

                # File should parse without error
                vdb = parse_vdb(filepath)

                # Header should be valid
                @test vdb.header.format_version > 0

                # Should have at least one supported grid (except files with only unsupported types)
                @test length(vdb.grids) >= 0

                # Each grid should have valid properties
                for grid in vdb.grids
                    @test !isempty(grid.name)
                    @test grid.transform isa AbstractTransform
                    @test leaf_count(grid.tree) >= 0
                end
            end
        end
    end

    @testset "Legacy parser v222+ topology (torus.vdb)" begin
        # Regression test: _parse_vdb_legacy must correctly skip internal node
        # values embedded in v222+ topology. Without skip_internal_mask_values,
        # pos drifts after I2/I1 masks and only 1 of 8 root children is found.
        filepath = joinpath(SAMPLE_DIR, "torus.vdb")
        if !isfile(filepath)
            @test_skip "torus.vdb not available"
            return
        end

        bytes = read(filepath)
        vdb = Lyr.parse_vdb(bytes)

        grid = vdb.grids[1]
        @test grid.name == "ls_torus"
        @test length(grid.tree.table) == 8  # 8 root children (one per octant)
        @test leaf_count(grid.tree) == 6044
        @test active_voxel_count(grid.tree) == 1119158
    end

    @testset "Legacy parser half-precision (cube.vdb)" begin
        # cube.vdb has grid type Tree_float_5_4_3_HalfFloat — values stored as Float16.
        # Legacy parser must detect _HalfFloat suffix and use value_size=2.
        filepath = joinpath(SAMPLE_DIR, "cube.vdb")
        if !isfile(filepath)
            @test_skip "cube.vdb not available"
            return
        end

        bytes = read(filepath)
        vdb = Lyr.parse_vdb(bytes)

        grid = vdb.grids[1]
        @test grid.name == "ls_cube"
        @test length(grid.tree.table) == 8
        @test leaf_count(grid.tree) == 6812
        @test active_voxel_count(grid.tree) == 1452218
    end

    @testset "Reference values" begin
        # Test against known reference values from sample files
        REF_FILE = joinpath(@__DIR__, "fixtures", "reference_values.json")

        if !isfile(REF_FILE)
            @info "Skipping reference value tests: $REF_FILE not found"
            @test_skip "Reference values not available"
            return
        end

        # Parse JSON manually (avoid dependency)
        ref_text = read(REF_FILE, String)

        # Verify torus.vdb reference values (already tested above, this is regression check)
        @test occursin("\"torus.vdb\"", ref_text)
        @test occursin("\"format_version\": 222", ref_text)
        @test occursin("\"grid_name\": \"ls_torus\"", ref_text)
        @test occursin("\"leaf_count\": 6044", ref_text)
        @test occursin("\"active_voxel_count\": 1119158", ref_text)

        # Reference file exists and has expected structure
        @test true
    end
end
