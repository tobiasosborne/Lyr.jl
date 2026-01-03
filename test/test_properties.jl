@testset "Properties" begin
    # Property-based tests using random inputs
    # These verify invariants that should always hold

    using Random
    Random.seed!(42)

    @testset "Mask properties" begin
        @testset "count_on equals iteration length" begin
            for _ in 1:10
                # Random mask
                words = ntuple(_ -> rand(UInt64), 8)
                m = LeafMask(words)

                @test count_on(m) == length(collect(on_indices(m)))
            end
        end

        @testset "is_on and is_off are complementary" begin
            words = (rand(UInt64), ntuple(_ -> UInt64(0), 7)...)
            m = LeafMask(words)

            for i in 0:63
                @test is_on(m, i) != is_off(m, i)
            end
        end

        @testset "count_on + count_off equals N" begin
            # (N, W) pairs where W = cld(N, 64)
            for (N, W) in [(64, 1), (128, 2), (512, 8)]
                m = Mask{N,W}()
                @test count_on(m) + count_off(m) == N

                m = Mask{N,W}(Val(:ones))
                @test count_on(m) + count_off(m) == N
            end
        end
    end

    @testset "Coordinate properties" begin
        @testset "Origin contains original coordinate" begin
            for _ in 1:100
                c = coord(rand(Int16), rand(Int16), rand(Int16))

                # Leaf origin should be <= coordinate in each dimension
                lo = leaf_origin(c)
                @test lo[1] <= c[1]
                @test lo[2] <= c[2]
                @test lo[3] <= c[3]

                # And origin + 7 should be >= coordinate
                @test lo[1] + 7 >= c[1]
                @test lo[2] + 7 >= c[2]
                @test lo[3] + 7 >= c[3]
            end
        end

        @testset "Offset is in valid range" begin
            for _ in 1:100
                c = coord(rand(Int16), rand(Int16), rand(Int16))

                @test 0 <= leaf_offset(c) < 512
                @test 0 <= internal1_child_index(c) < 4096
                @test 0 <= internal2_child_index(c) < 32768
            end
        end
    end

    @testset "BBox properties" begin
        @testset "BBox contains its corners" begin
            for _ in 1:10
                min_c = coord(rand(Int16), rand(Int16), rand(Int16))
                max_c = (min_c[1] + abs(rand(Int16)), min_c[2] + abs(rand(Int16)), min_c[3] + abs(rand(Int16)))
                bb = BBox(min_c, max_c)

                @test Lyr.contains(bb, min_c)
                @test Lyr.contains(bb, max_c)
            end
        end

        @testset "BBox union contains both inputs" begin
            for _ in 1:10
                # Use smaller range to avoid issues
                x1, y1, z1 = rand(0:50), rand(0:50), rand(0:50)
                x2, y2, z2 = rand(0:50), rand(0:50), rand(0:50)
                a = BBox(coord(x1, y1, z1), coord(x1 + 10, y1 + 10, z1 + 10))
                b = BBox(coord(x2, y2, z2), coord(x2 + 10, y2 + 10, z2 + 10))

                u = union(a, b)

                # Union should contain all corners of both boxes
                @test Lyr.contains(u, a.min)
                @test Lyr.contains(u, a.max)
                @test Lyr.contains(u, b.min)
                @test Lyr.contains(u, b.max)
            end
        end

        @testset "Volume is positive" begin
            bb = BBox(coord(0, 0, 0), coord(10, 10, 10))
            @test volume(bb) > 0
        end
    end

    @testset "Transform properties" begin
        @testset "Round-trip preserves integer coordinates" begin
            transforms = [
                UniformScaleTransform(1.0),
                UniformScaleTransform(0.5),
                UniformScaleTransform(2.0),
            ]

            for t in transforms
                for _ in 1:10
                    c = coord(rand(-100:100), rand(-100:100), rand(-100:100))
                    world = index_to_world(t, c)
                    back = world_to_index(t, world)
                    @test back == c
                end
            end
        end
    end

    @testset "Tree properties" begin
        @testset "Empty tree returns background" begin
            for bg in [0.0f0, 1.0f0, -999.0f0]
                tree = RootNode{Float32}(bg, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())

                for _ in 1:10
                    c = coord(rand(Int16), rand(Int16), rand(Int16))
                    @test get_value(tree, c) == bg
                    @test is_active(tree, c) == false
                end
            end
        end
    end

    @testset "Interpolation properties" begin
        # Create a uniform tree for testing
        function make_uniform_tree(value::Float32)
            tile = Tile{Float32}(value, true)
            table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(
                coord(0, 0, 0) => tile
            )
            RootNode{Float32}(value, table)
        end

        @testset "Trilinear at integer coords approximates voxel value" begin
            tree = make_uniform_tree(42.0f0)

            for _ in 1:10
                c = (Float64(rand(0:100)), Float64(rand(0:100)), Float64(rand(0:100)))
                # For a uniform tree, trilinear should return the uniform value
                @test sample_trilinear(tree, c) ≈ 42.0f0
            end
        end
    end

    @testset "Ray properties" begin
        @testset "Ray direction is normalized" begin
            for _ in 1:10
                dir = (randn(), randn(), randn())
                ray = Ray((0.0, 0.0, 0.0), dir)

                len = sqrt(sum(x^2 for x in ray.direction))
                @test len ≈ 1.0
            end
        end

        @testset "intersect_bbox symmetry" begin
            # Ray from outside should have same intersection interval as
            # parallel ray from opposite side (with appropriate t offset)
            bbox = BBox(coord(0, 0, 0), coord(10, 10, 10))

            ray1 = Ray((−5.0, 5.0, 5.0), (1.0, 0.0, 0.0))
            ray2 = Ray((15.0, 5.0, 5.0), (−1.0, 0.0, 0.0))

            r1 = intersect_bbox(ray1, bbox)
            r2 = intersect_bbox(ray2, bbox)

            @test r1 !== nothing
            @test r2 !== nothing

            # Both should traverse the same distance through the box
            @test (r1[2] - r1[1]) ≈ (r2[2] - r2[1])
        end
    end
end
