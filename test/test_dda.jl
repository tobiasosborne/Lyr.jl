@testset "DDA" begin
    @testset "dda_init axis-aligned +X" begin
        ray = Ray((-0.5, 0.5, 0.5), (1.0, 0.0, 0.0))
        state = dda_init(ray, 0.0)

        # At t=0, ray is at (-0.5, 0.5, 0.5) → voxel (-1, 0, 0)
        @test state.ijk == coord(-1, 0, 0)
        @test state.step == Lyr.SVector{3, Int32}(1, 1, 1)
        @test state.tdelta[1] ≈ 1.0
        @test isinf(state.tdelta[2])
        @test isinf(state.tdelta[3])
    end

    @testset "dda_init axis-aligned -X" begin
        ray = Ray((2.5, 0.5, 0.5), (-1.0, 0.0, 0.0))
        state = dda_init(ray, 0.0)

        @test state.ijk == coord(2, 0, 0)
        @test state.step[1] == Int32(-1)
    end

    @testset "dda_step! along +X" begin
        ray = Ray((-0.5, 0.5, 0.5), (1.0, 0.0, 0.0))
        state = dda_init(ray, 0.0)

        @test state.ijk == coord(-1, 0, 0)

        axis = dda_step!(state)
        @test axis == 1
        @test state.ijk == coord(0, 0, 0)

        axis = dda_step!(state)
        @test axis == 1
        @test state.ijk == coord(1, 0, 0)

        axis = dda_step!(state)
        @test axis == 1
        @test state.ijk == coord(2, 0, 0)
    end

    @testset "dda_step! along +Y" begin
        ray = Ray((0.5, -0.5, 0.5), (0.0, 1.0, 0.0))
        state = dda_init(ray, 0.0)

        @test state.ijk == coord(0, -1, 0)

        axis = dda_step!(state)
        @test axis == 2
        @test state.ijk == coord(0, 0, 0)

        axis = dda_step!(state)
        @test axis == 2
        @test state.ijk == coord(0, 1, 0)
    end

    @testset "dda_step! along +Z" begin
        ray = Ray((0.5, 0.5, -0.5), (0.0, 0.0, 1.0))
        state = dda_init(ray, 0.0)

        @test state.ijk == coord(0, 0, -1)

        axis = dda_step!(state)
        @test axis == 3
        @test state.ijk == coord(0, 0, 0)

        axis = dda_step!(state)
        @test axis == 3
        @test state.ijk == coord(0, 0, 1)
    end

    @testset "dda_step! diagonal (1,1,1)" begin
        # Diagonal ray from origin of voxel (0,0,0)
        ray = Ray((0.0, 0.0, 0.0), (1.0, 1.0, 1.0))
        state = dda_init(ray, 0.0)

        @test state.ijk == coord(0, 0, 0)

        # Diagonal ray: all tmax values equal, all tdelta equal
        # Should visit all three axes in some consistent order
        visited = Coord[]
        push!(visited, state.ijk)
        for _ in 1:6
            dda_step!(state)
            push!(visited, state.ijk)
        end

        # After 6 steps on a diagonal, should have moved ~2 in each axis
        final = visited[end]
        @test final[1] + final[2] + final[3] == 6  # Total manhattan distance
    end

    @testset "dda_step! negative direction" begin
        ray = Ray((2.5, 0.5, 0.5), (-1.0, 0.0, 0.0))
        state = dda_init(ray, 0.0)

        @test state.ijk == coord(2, 0, 0)

        axis = dda_step!(state)
        @test axis == 1
        @test state.ijk == coord(1, 0, 0)

        axis = dda_step!(state)
        @test axis == 1
        @test state.ijk == coord(0, 0, 0)

        axis = dda_step!(state)
        @test axis == 1
        @test state.ijk == coord(-1, 0, 0)
    end

    @testset "dda_init with tmin offset" begin
        # Ray starts at (-10, 0.5, 0.5), hits box at x=0 (tmin=10)
        ray = Ray((-10.0, 0.5, 0.5), (1.0, 0.0, 0.0))
        state = dda_init(ray, 10.0)

        # At t=10, ray is at (0, 0.5, 0.5) → voxel (0, 0, 0)
        @test state.ijk == coord(0, 0, 0)
    end

    @testset "dda_init with voxel_size" begin
        ray = Ray((-0.5, 0.25, 0.25), (1.0, 0.0, 0.0))
        state = dda_init(ray, 0.0, 0.5)

        # At origin (-0.5, 0.25, 0.25) with vs=0.5: voxel = floor(-0.5/0.5) = floor(-1) = -1
        @test state.ijk == coord(-1, 0, 0)
        # tdelta = 0.5 / |1.0| = 0.5
        @test state.tdelta[1] ≈ 0.5
    end

    @testset "dda 2D diagonal (XY plane)" begin
        # 45-degree ray in XY plane
        ray = Ray((0.5, 0.5, 0.5), (1.0, 1.0, 0.0))
        state = dda_init(ray, 0.0)

        @test state.ijk == coord(0, 0, 0)

        # Collect 8 steps
        axes_hit = Int[]
        for _ in 1:8
            axis = dda_step!(state)
            push!(axes_hit, axis)
        end

        # Should only cross axes 1 and 2, never 3 (parallel to Z)
        @test all(a -> a in (1, 2), axes_hit)
        @test !(3 in axes_hit)

        # Should have moved ~4 in each of X and Y
        @test state.ijk[1] ≈ 4 atol=1
        @test state.ijk[2] ≈ 4 atol=1
        @test state.ijk[3] == 0
    end

    @testset "dda_step! tmax monotonically increases" begin
        ray = Ray((0.1, 0.2, 0.3), (0.6, 0.8, 0.1))
        state = dda_init(ray, 0.0)

        prev_min_tmax = 0.0
        for _ in 1:20
            min_tmax = minimum(state.tmax)
            @test min_tmax >= prev_min_tmax - 1e-10
            prev_min_tmax = min_tmax
            dda_step!(state)
        end
    end

    @testset "dda_step! visits unique voxels" begin
        ray = Ray((0.1, 0.2, 0.3), (0.5, 0.7, 0.3))
        state = dda_init(ray, 0.0)

        visited = Set{Tuple{Int32,Int32,Int32}}()
        push!(visited, (state.ijk[1], state.ijk[2], state.ijk[3]))
        for _ in 1:30
            dda_step!(state)
            voxel = (state.ijk[1], state.ijk[2], state.ijk[3])
            @test voxel ∉ visited  # Never revisit a voxel
            push!(visited, voxel)
        end
    end

    @testset "dda adjacent voxels differ by exactly 1 in one axis" begin
        ray = Ray((0.1, 0.2, 0.3), (0.5, 0.7, 0.3))
        state = dda_init(ray, 0.0)

        prev = state.ijk
        for _ in 1:20
            dda_step!(state)
            curr = state.ijk
            # Exactly one axis changed by exactly 1
            dx = abs(Int(curr[1]) - Int(prev[1]))
            dy = abs(Int(curr[2]) - Int(prev[2]))
            dz = abs(Int(curr[3]) - Int(prev[3]))
            @test dx + dy + dz == 1
            prev = curr
        end
    end
end
