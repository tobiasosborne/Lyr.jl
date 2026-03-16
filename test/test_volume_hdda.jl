# Test VolumeHDDA — span-merging hierarchical DDA for volume rendering

@testset "VolumeHDDA" begin
    @testset "Empty grid yields no spans" begin
        grid = build_grid(Dict{Coord, Float32}(), 0.0f0)
        nano = build_nanogrid(grid.tree)
        ray = Ray(SVec3d(0.0, 0.0, -10.0), SVec3d(0.0, 0.0, 1.0))
        spans = collect(Lyr.NanoVolumeHDDA(nano, ray))
        @test isempty(spans)
    end

    @testset "Single leaf yields one span" begin
        data = Dict{Coord, Float32}()
        for iz in 0:7, iy in 0:7, ix in 0:7
            data[coord(Int32(ix), Int32(iy), Int32(iz))] = 1.0f0
        end
        grid = build_grid(data, 0.0f0)
        nano = build_nanogrid(grid.tree)

        # Ray along +Z through center of leaf
        ray = Ray(SVec3d(4.0, 4.0, -5.0), SVec3d(0.0, 0.0, 1.0))
        spans = collect(Lyr.NanoVolumeHDDA(nano, ray))
        @test length(spans) == 1
        @test spans[1].t0 ≈ 5.0 atol=0.1   # enters at z=0
        @test spans[1].t1 ≈ 13.0 atol=0.1  # exits at z=8
    end

    @testset "Adjacent leaves merge into one span" begin
        # Fill 3 leaves along Z axis (z=0..23)
        data = Dict{Coord, Float32}()
        for iz in 0:23, iy in 0:7, ix in 0:7
            data[coord(Int32(ix), Int32(iy), Int32(iz))] = 1.0f0
        end
        grid = build_grid(data, 0.0f0)
        nano = build_nanogrid(grid.tree)

        ray = Ray(SVec3d(4.0, 4.0, -5.0), SVec3d(0.0, 0.0, 1.0))
        spans = collect(Lyr.NanoVolumeHDDA(nano, ray))
        @test length(spans) == 1
        @test spans[1].t0 ≈ 5.0 atol=0.1   # enters at z=0
        @test spans[1].t1 ≈ 29.0 atol=0.1  # exits at z=24
    end

    @testset "Gap between leaf groups yields two spans" begin
        data = Dict{Coord, Float32}()
        # Group 1: z=0..7 (1 leaf)
        for iz in 0:7, iy in 0:7, ix in 0:7
            data[coord(Int32(ix), Int32(iy), Int32(iz))] = 1.0f0
        end
        # Gap: z=8..15 (empty)
        # Group 2: z=16..23 (1 leaf)
        for iz in 16:23, iy in 0:7, ix in 0:7
            data[coord(Int32(ix), Int32(iy), Int32(iz))] = 1.0f0
        end
        grid = build_grid(data, 0.0f0)
        nano = build_nanogrid(grid.tree)

        ray = Ray(SVec3d(4.0, 4.0, -5.0), SVec3d(0.0, 0.0, 1.0))
        spans = collect(Lyr.NanoVolumeHDDA(nano, ray))
        @test length(spans) == 2
        # First span: z=0..8
        @test spans[1].t0 ≈ 5.0 atol=0.1
        @test spans[1].t1 ≈ 13.0 atol=0.1
        # Second span: z=16..24
        @test spans[2].t0 ≈ 21.0 atol=0.1
        @test spans[2].t1 ≈ 29.0 atol=0.1
    end

    @testset "Miss ray yields no spans" begin
        data = Dict{Coord, Float32}()
        for iz in 0:7, iy in 0:7, ix in 0:7
            data[coord(Int32(ix), Int32(iy), Int32(iz))] = 1.0f0
        end
        grid = build_grid(data, 0.0f0)
        nano = build_nanogrid(grid.tree)

        # Ray that misses entirely
        ray = Ray(SVec3d(100.0, 100.0, -5.0), SVec3d(0.0, 0.0, 1.0))
        spans = collect(Lyr.NanoVolumeHDDA(nano, ray))
        @test isempty(spans)
    end

    @testset "Coverage matches NanoVolumeRayIntersector leaf hits" begin
        # Use real VDB file for thorough coverage test
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(smoke_path)
            @test_skip "fixture not found: $smoke_path"
            return
        end
        vdb = parse_vdb(smoke_path)
        grid = vdb.grids[1]
        nano = build_nanogrid(grid.tree)

        test_rays = [
            Ray(SVec3d(50.0, 50.0, -100.0), SVec3d(0.0, 0.0, 1.0)),   # +Z
            Ray(SVec3d(-100.0, 50.0, 50.0), SVec3d(1.0, 0.0, 0.0)),   # +X
            Ray(SVec3d(50.0, -100.0, 50.0), SVec3d(0.0, 1.0, 0.0)),   # +Y
            Ray(SVec3d(50.0, 50.0, 50.0), SVec3d(1.0, 1.0, 1.0)),     # diagonal
        ]

        for ray in test_rays
            leaf_hits = collect(Lyr.NanoVolumeRayIntersector(nano, ray))
            spans = collect(Lyr.NanoVolumeHDDA(nano, ray))

            # Every leaf hit must be contained within some span
            for lh in leaf_hits
                covered = any(s -> s.t0 <= lh.t_enter + 1e-6 &&
                                   lh.t_exit <= s.t1 + 1e-6, spans)
                @test covered
            end

            # Every span must overlap at least one leaf hit
            for s in spans
                overlaps = any(lh -> lh.t_enter < s.t1 + 1e-6 &&
                                     lh.t_exit > s.t0 - 1e-6, leaf_hits)
                @test overlaps
            end

            # Spans should be fewer or equal to leaf hits (merging)
            @test length(spans) <= length(leaf_hits)
        end
    end

    @testset "Spans are front-to-back ordered" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(smoke_path)
            @test_skip "fixture not found: $smoke_path"
            return
        end
        vdb = parse_vdb(smoke_path)
        grid = vdb.grids[1]
        nano = build_nanogrid(grid.tree)

        ray = Ray(SVec3d(50.0, 50.0, -100.0), SVec3d(0.0, 0.0, 1.0))
        spans = collect(Lyr.NanoVolumeHDDA(nano, ray))

        for i in 2:length(spans)
            @test spans[i].t0 >= spans[i-1].t1 - 1e-6
        end
    end

    @testset "Diagonal ray through built grid" begin
        data = Dict{Coord, Float32}()
        for iz in 0:7, iy in 0:7, ix in 0:7
            data[coord(Int32(ix), Int32(iy), Int32(iz))] = 1.0f0
        end
        grid = build_grid(data, 0.0f0)
        nano = build_nanogrid(grid.tree)

        ray = Ray(SVec3d(-5.0, -5.0, -5.0), SVec3d(1.0, 1.0, 1.0))
        spans = collect(Lyr.NanoVolumeHDDA(nano, ray))
        @test length(spans) >= 1
        @test all(s -> s.t1 > s.t0, spans)
    end

    @testset "Iterator traits" begin
        data = Dict{Coord, Float32}()
        data[coord(Int32(0), Int32(0), Int32(0))] = 1.0f0
        grid = build_grid(data, 0.0f0)
        nano = build_nanogrid(grid.tree)
        ray = Ray(SVec3d(0.5, 0.5, -5.0), SVec3d(0.0, 0.0, 1.0))

        hdda = Lyr.NanoVolumeHDDA(nano, ray)
        @test Base.IteratorSize(typeof(hdda)) == Base.SizeUnknown()
        @test eltype(typeof(hdda)) == Lyr.TimeSpan
    end
end
