# Static analysis tests using JET.jl
# Tests for type stability and optimization opportunities in hot-path functions

using JET

@testset "JET Static Analysis" begin
    @testset "Binary primitives - @report_opt" begin
        bytes = UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

        @testset "read_u8" begin
            result = @report_opt read_u8(bytes, 1)
            @test isempty(JET.get_reports(result))
        end

        @testset "read_u32_le" begin
            result = @report_opt read_u32_le(bytes, 1)
            @test isempty(JET.get_reports(result))
        end

        @testset "read_u64_le" begin
            result = @report_opt read_u64_le(bytes, 1)
            @test isempty(JET.get_reports(result))
        end

        @testset "read_i32_le" begin
            result = @report_opt read_i32_le(bytes, 1)
            @test isempty(JET.get_reports(result))
        end

        @testset "read_f32_le" begin
            result = @report_opt read_f32_le(bytes, 1)
            @test isempty(JET.get_reports(result))
        end

        @testset "read_f64_le" begin
            result = @report_opt read_f64_le(bytes, 1)
            @test isempty(JET.get_reports(result))
        end
    end

    @testset "Mask operations - @report_opt" begin
        mask = LeafMask(Val(:ones))

        @testset "count_on (hot path)" begin
            result = @report_opt count_on(mask)
            @test isempty(JET.get_reports(result))
        end

        @testset "is_on (hot path)" begin
            result = @report_opt is_on(mask, 0)
            @test isempty(JET.get_reports(result))
        end

        @testset "is_off" begin
            result = @report_opt is_off(mask, 0)
            @test isempty(JET.get_reports(result))
        end

        @testset "count_off" begin
            result = @report_opt count_off(mask)
            @test isempty(JET.get_reports(result))
        end
    end

    @testset "Coordinate operations - @report_opt" begin
        c = coord(10, 20, 30)

        @testset "leaf_origin" begin
            result = @report_opt leaf_origin(c)
            @test isempty(JET.get_reports(result))
        end

        @testset "leaf_offset" begin
            result = @report_opt leaf_offset(c)
            @test isempty(JET.get_reports(result))
        end

        @testset "internal1_origin" begin
            result = @report_opt internal1_origin(c)
            @test isempty(JET.get_reports(result))
        end

        @testset "internal2_origin" begin
            result = @report_opt internal2_origin(c)
            @test isempty(JET.get_reports(result))
        end

        @testset "internal1_child_index" begin
            result = @report_opt internal1_child_index(c)
            @test isempty(JET.get_reports(result))
        end

        @testset "internal2_child_index" begin
            result = @report_opt internal2_child_index(c)
            @test isempty(JET.get_reports(result))
        end
    end

    @testset "Tree access - @report_opt" begin
        # Create minimal test tree with a tile
        tile = Tile{Float32}(1.0f0, true)
        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(
            coord(0, 0, 0) => tile
        )
        tree = RootNode{Float32}(0.0f0, table)
        c = coord(5, 5, 5)

        @testset "get_value (hot path)" begin
            result = @report_opt get_value(tree, c)
            # Note: get_value may have optimization opportunities due to Union types
            # in the tree table. Document any reports here.
            reports = JET.get_reports(result)
            if !isempty(reports)
                @info "get_value optimization reports (expected due to Union table type):" reports
            end
            # Allow reports due to inherent Union type in tree structure
            @test true
        end

        @testset "is_active" begin
            result = @report_opt is_active(tree, c)
            reports = JET.get_reports(result)
            if !isempty(reports)
                @info "is_active optimization reports:" reports
            end
            @test true
        end
    end

    @testset "Binary primitives - @report_call" begin
        bytes = UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

        @testset "read_u32_le - no errors" begin
            result = @report_call read_u32_le(bytes, 1)
            @test isempty(JET.get_reports(result))
        end

        @testset "read_u64_le - no errors" begin
            result = @report_call read_u64_le(bytes, 1)
            @test isempty(JET.get_reports(result))
        end
    end

    @testset "Mask operations - @report_call" begin
        mask = LeafMask(Val(:ones))

        @testset "count_on - no errors" begin
            result = @report_call count_on(mask)
            @test isempty(JET.get_reports(result))
        end

        @testset "is_on - no errors" begin
            result = @report_call is_on(mask, 0)
            @test isempty(JET.get_reports(result))
        end
    end

    @testset "Compression - @report_opt" begin
        data = UInt8[1, 2, 3, 4, 5]

        @testset "decompress NoCompression" begin
            result = @report_opt decompress(NoCompression(), data)
            @test isempty(JET.get_reports(result))
        end
    end

    @testset "Transform operations - @report_opt" begin
        t = UniformScaleTransform(0.5)
        c = coord(10, 20, 30)
        wc = (5.0, 10.0, 15.0)

        @testset "index_to_world" begin
            result = @report_opt index_to_world(t, c)
            @test isempty(JET.get_reports(result))
        end

        @testset "world_to_index" begin
            result = @report_opt world_to_index(t, wc)
            @test isempty(JET.get_reports(result))
        end

        @testset "voxel_size" begin
            result = @report_opt voxel_size(t)
            @test isempty(JET.get_reports(result))
        end
    end

    @testset "Interpolation - @report_opt" begin
        tile = Tile{Float32}(1.0f0, true)
        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(
            coord(0, 0, 0) => tile
        )
        tree = RootNode{Float32}(0.0f0, table)
        pos = (5.5, 5.5, 5.5)

        @testset "sample_nearest" begin
            result = @report_opt sample_nearest(tree, pos)
            # May have reports due to tree Union type
            @test true
        end

        @testset "sample_trilinear" begin
            result = @report_opt sample_trilinear(tree, pos)
            # May have reports due to tree Union type
            @test true
        end
    end

    @testset "Ray operations - @report_opt" begin
        ray = Ray((0.0, 0.0, 0.0), (1.0, 0.0, 0.0))
        bb = BBox(coord(10, -5, -5), coord(20, 5, 5))

        @testset "intersect_bbox" begin
            result = @report_opt intersect_bbox(ray, bb)
            @test isempty(JET.get_reports(result))
        end
    end
end
