@testset "Transforms" begin
    @testset "UniformScaleTransform" begin
        t = UniformScaleTransform(0.5)

        @test voxel_size(t) == (0.5, 0.5, 0.5)

        # Index to world
        world = index_to_world(t, coord(2, 4, 6))
        @test world == (1.0, 2.0, 3.0)

        # World to index
        idx = world_to_index(t, (1.0, 2.0, 3.0))
        @test idx == coord(2, 4, 6)

        # Round-trip
        c = coord(10, 20, 30)
        world = index_to_world(t, c)
        back = world_to_index(t, world)
        @test back == c
    end

    @testset "LinearTransform identity" begin
        # Identity matrix
        mat = (1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
        trans = (0.0, 0.0, 0.0)
        t = LinearTransform(mat, trans)

        @test voxel_size(t) == (1.0, 1.0, 1.0)

        c = coord(5, 10, 15)
        world = index_to_world(t, c)
        @test world == (5.0, 10.0, 15.0)

        back = world_to_index(t, world)
        @test back == c
    end

    @testset "LinearTransform with scale" begin
        # Scale by 2
        mat = (2.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 2.0)
        trans = (0.0, 0.0, 0.0)
        t = LinearTransform(mat, trans)

        @test voxel_size(t) == (2.0, 2.0, 2.0)

        world = index_to_world(t, coord(1, 2, 3))
        @test world == (2.0, 4.0, 6.0)
    end

    @testset "LinearTransform with translation" begin
        mat = (1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
        trans = (10.0, 20.0, 30.0)
        t = LinearTransform(mat, trans)

        world = index_to_world(t, coord(0, 0, 0))
        @test world == (10.0, 20.0, 30.0)

        world = index_to_world(t, coord(1, 1, 1))
        @test world == (11.0, 21.0, 31.0)
    end

    @testset "world_to_index_float" begin
        t = UniformScaleTransform(0.1)

        # Floating point result
        ijk = world_to_index_float(t, (0.55, 1.25, 2.75))
        @test ijk[1] ≈ 5.5
        @test ijk[2] ≈ 12.5
        @test ijk[3] ≈ 27.5
    end

    @testset "Round-trip consistency" begin
        # Various transforms
        transforms = [
            UniformScaleTransform(1.0),
            UniformScaleTransform(0.1),
            UniformScaleTransform(10.0),
            LinearTransform((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0), (5.0, 5.0, 5.0)),
        ]

        for t in transforms
            for c in [coord(0, 0, 0), coord(10, 20, 30), coord(-5, 10, -15)]
                world = index_to_world(t, c)
                back = world_to_index(t, world)
                @test back == c
            end
        end
    end
end
