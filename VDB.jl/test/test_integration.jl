@testset "Integration" begin
    # Integration tests for parsing official VDB sample files
    # These tests are skipped if sample files are not present

    SAMPLE_DIR = joinpath(@__DIR__, "fixtures", "samples")

    @testset "Sample files parsing" begin
        # Skip if no samples directory
        if !isdir(SAMPLE_DIR)
            @info "Skipping integration tests: sample files not found at $SAMPLE_DIR"
            @test_skip "Sample files not available"
            return
        end

        sample_files = filter(f -> endswith(f, ".vdb"), readdir(SAMPLE_DIR))

        if isempty(sample_files)
            @info "No .vdb files found in $SAMPLE_DIR"
            @test_skip "No VDB sample files"
            return
        end

        for filename in sample_files
            @testset "$filename" begin
                filepath = joinpath(SAMPLE_DIR, filename)

                # Test 1: File should parse without error
                vdb = @test_nowarn parse_vdb(filepath)

                # Test 2: Should have at least one grid
                @test length(vdb.grids) >= 1

                # Test 3: Header should be valid
                @test vdb.header.format_version > 0

                # Test 4: Each grid should have valid properties
                for grid in vdb.grids
                    @test !isempty(grid.name)
                    @test grid.transform isa AbstractTransform
                end
            end
        end
    end

    @testset "Reference values" begin
        # Test against known reference values from sample files
        # These would be pre-computed and stored in fixtures

        REF_FILE = joinpath(@__DIR__, "fixtures", "reference_values.json")

        if !isfile(REF_FILE)
            @info "Skipping reference value tests: $REF_FILE not found"
            @test_skip "Reference values not available"
            return
        end

        # Load reference values and compare
        # This is a placeholder for the actual implementation
        @test true
    end

    @testset "Sample downloads" begin
        # URLs for official OpenVDB sample files
        # These can be downloaded for testing:
        # - https://artifacts.aswf.io/io/aswf/openvdb/models/bunny_cloud.vdb/1.0.0/bunny_cloud.vdb-1.0.0.zip
        # - https://artifacts.aswf.io/io/aswf/openvdb/models/smoke1.vdb/1.0.0/smoke1.vdb-1.0.0.zip
        # - https://artifacts.aswf.io/io/aswf/openvdb/models/torus.vdb/1.0.0/torus.vdb-1.0.0.zip

        @test true  # Placeholder
    end
end
