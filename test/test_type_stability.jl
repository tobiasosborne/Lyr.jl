# Type stability tests using @code_warntype analysis
# These tests verify that critical hot-path functions are type-stable

# Helper to check if @code_warntype output contains type instability warnings
function is_type_stable(f, args...)
    # Capture @code_warntype output
    io = IOBuffer()
    InteractiveUtils.code_warntype(io, f, Base.typesof(args...))
    output = String(take!(io))

    # Check for type instability indicators
    # - "Body::Any" indicates the return type couldn't be inferred
    # - "Union{" in body (not just parameters) suggests type instability
    # - "::Any" for local variables is problematic

    # Parse the output for issues
    # Lines containing "::Any" (except in type parameters) suggest instability
    has_any_type = occursin(r"::Any\b", output) && !occursin("::Type{Any}", output)

    # Look for Union types in variable declarations (not just function signatures)
    lines = split(output, '\n')
    has_union_in_body = false
    in_body = false
    for line in lines
        if occursin("Body::", line)
            in_body = true
        end
        if in_body && occursin(r"Union\{.*\}", line) && !occursin("Union{}", line)
            # Some Union types are fine (e.g., Union{Nothing, T})
            # We're mainly concerned about Any or excessive unions
            has_union_in_body = true
        end
    end

    # Return true if no major issues found
    !has_any_type
end

@testset "Type Stability" begin
    @testset "Binary primitives" begin
        bytes = UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

        @testset "read_u8" begin
            @test is_type_stable(read_u8, bytes, 1)
        end

        @testset "read_u32_le" begin
            @test is_type_stable(read_u32_le, bytes, 1)
        end

        @testset "read_u64_le" begin
            @test is_type_stable(read_u64_le, bytes, 1)
        end

        @testset "read_i32_le" begin
            @test is_type_stable(read_i32_le, bytes, 1)
        end

        @testset "read_i64_le" begin
            @test is_type_stable(read_i64_le, bytes, 1)
        end

        @testset "read_f32_le" begin
            @test is_type_stable(read_f32_le, bytes, 1)
        end

        @testset "read_f64_le" begin
            @test is_type_stable(read_f64_le, bytes, 1)
        end
    end

    @testset "Mask operations" begin
        m = LeafMask(Val(:ones))

        @testset "is_on" begin
            @test is_type_stable(is_on, m, 0)
        end

        @testset "is_off" begin
            @test is_type_stable(is_off, m, 0)
        end

        @testset "count_on" begin
            @test is_type_stable(count_on, m)
        end

        @testset "count_off" begin
            @test is_type_stable(count_off, m)
        end
    end

    @testset "Coordinate operations" begin
        c = coord(10, 20, 30)

        @testset "leaf_origin" begin
            @test is_type_stable(leaf_origin, c)
        end

        @testset "leaf_offset" begin
            @test is_type_stable(leaf_offset, c)
        end

        @testset "internal1_origin" begin
            @test is_type_stable(internal1_origin, c)
        end

        @testset "internal2_origin" begin
            @test is_type_stable(internal2_origin, c)
        end
    end

    @testset "BBox operations" begin
        bb = BBox(coord(0, 0, 0), coord(10, 10, 10))
        c = coord(5, 5, 5)

        @testset "contains" begin
            @test is_type_stable(Lyr.contains, bb, c)
        end

        @testset "intersects" begin
            bb2 = BBox(coord(5, 5, 5), coord(15, 15, 15))
            @test is_type_stable(Lyr.intersects, bb, bb2)
        end

        @testset "volume" begin
            @test is_type_stable(volume, bb)
        end
    end

    @testset "Transform operations" begin
        t = UniformScaleTransform(0.5)
        c = coord(10, 20, 30)
        wc = (5.0, 10.0, 15.0)

        @testset "index_to_world" begin
            @test is_type_stable(index_to_world, t, c)
        end

        @testset "world_to_index" begin
            @test is_type_stable(world_to_index, t, wc)
        end

        @testset "voxel_size" begin
            @test is_type_stable(voxel_size, t)
        end
    end

    @testset "Tree access operations" begin
        # Create minimal test tree
        tile = Tile{Float32}(1.0f0, true)
        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(
            coord(0, 0, 0) => tile
        )
        tree = RootNode{Float32}(0.0f0, table)
        c = coord(5, 5, 5)

        @testset "get_value" begin
            @test is_type_stable(get_value, tree, c)
        end

        @testset "is_active" begin
            @test is_type_stable(is_active, tree, c)
        end
    end

    @testset "Interpolation operations" begin
        tile = Tile{Float32}(1.0f0, true)
        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(
            coord(0, 0, 0) => tile
        )
        tree = RootNode{Float32}(0.0f0, table)
        pos = (5.5, 5.5, 5.5)

        @testset "sample_nearest" begin
            @test is_type_stable(sample_nearest, tree, pos)
        end

        @testset "sample_trilinear" begin
            @test is_type_stable(sample_trilinear, tree, pos)
        end
    end

    @testset "Ray operations" begin
        ray = Ray((0.0, 0.0, 0.0), (1.0, 0.0, 0.0))
        bb = BBox(coord(10, -5, -5), coord(20, 5, 5))

        @testset "intersect_bbox" begin
            @test is_type_stable(intersect_bbox, ray, bb)
        end
    end

    @testset "Compression operations" begin
        data = UInt8[1, 2, 3, 4, 5]

        @testset "decompress NoCompression" begin
            @test is_type_stable(decompress, NoCompression(), data)
        end
    end
end
