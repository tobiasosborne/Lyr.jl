@testset "Parser Equivalence" begin
    # Both Main Lyr (legacy, offset-seeking) and TinyVDB (sequential) parsers
    # must produce identical trees for all compatible files. This makes TinyVDB
    # a permanent test oracle for the production parser.
    #
    # Current status:
    #   - Topology + values: MATCH for 5/6 files
    #   - smoke.vdb: BROKEN topology (0 leaves, all tiles) — separate bug path-tracer-d42

    SAMPLE_DIR = joinpath(@__DIR__, "fixtures", "samples")

    # Files compatible with both parsers:
    # v222+, Tree_float_5_4_3 (including _HalfFloat), no Blosc
    COMPATIBLE_FILES = [
        "cube.vdb",
        "icosahedron.vdb",
        "smoke.vdb",
        "sphere.vdb",
        "torus.vdb",
        "utahteapot.vdb",
    ]

    for filename in COMPATIBLE_FILES
        @testset "$filename" begin
            filepath = joinpath(SAMPLE_DIR, filename)
            if !isfile(filepath)
                @test_skip "$filename not available"
                return
            end

            bytes = read(filepath)

            # Parse with Main Lyr (legacy offset-seeking parser)
            main_vdb = Lyr._parse_vdb_legacy(bytes)

            # Parse with TinyVDB (sequential parser) + bridge conversion
            tiny_raw = Lyr.TinyVDB.parse_tinyvdb(bytes)
            tiny_vdb = Lyr.convert_tinyvdb_file(tiny_raw)

            # Grid counts must match
            @test length(main_vdb.grids) == length(tiny_vdb.grids)

            # Sort both by name (Main Lyr preserves file order, TinyVDB sorts alphabetically)
            main_grids = sort(main_vdb.grids, by=g -> g.name)
            tiny_grids = sort(tiny_vdb.grids, by=g -> g.name)

            for (mg, tg) in zip(main_grids, tiny_grids)
                @testset "Grid: $(mg.name)" begin
                    # Identity
                    @test mg.name == tg.name
                    @test mg.grid_class == tg.grid_class

                    # Background value
                    @test mg.tree.background == tg.tree.background

                    # Root child origins
                    @test Set(keys(mg.tree.table)) == Set(keys(tg.tree.table))

                    # Tree structure — topology fix verified these match for most files.
                    # smoke.vdb still broken: legacy parser gets 0 leaves + all tiles.
                    if filename == "smoke.vdb"
                        @test_broken leaf_count(mg.tree) == leaf_count(tg.tree)
                        @test_broken active_voxel_count(mg.tree) == active_voxel_count(tg.tree)
                    else
                        @test leaf_count(mg.tree) == leaf_count(tg.tree)
                        @test active_voxel_count(mg.tree) == active_voxel_count(tg.tree)
                    end

                    # Value equivalence: iterate TinyVDB active voxels, look up in Main Lyr.
                    local n_checked = 0
                    local max_diff = 0.0f0
                    for (coord, val_tiny) in active_voxels(tg.tree)
                        val_main = get_value(mg.tree, coord)
                        d = val_main - val_tiny
                        if !isnan(d)
                            max_diff = max(max_diff, abs(d))
                        else
                            max_diff = NaN32
                        end
                        n_checked += 1
                        n_checked >= 200 && break
                    end
                    @test n_checked > 0
                    if filename == "smoke.vdb"
                        @test_broken max_diff == 0.0f0  # topology broken → values wrong
                    else
                        @test max_diff == 0.0f0
                    end
                end
            end
        end
    end
end
