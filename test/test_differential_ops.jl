@testset "DifferentialOps" begin

    # ========================================================================
    # Test grid builders — analytical functions on a coordinate cube
    # ========================================================================

    _CUBE = [coord(x, y, z) for x in -5:5, y in -5:5, z in -5:5] |> vec
    _INTERIOR = [coord(x, y, z) for x in -4:4, y in -4:4, z in -4:4] |> vec

    function _scalar_grid(f)
        data = Dict{Coord, Float32}()
        for c in _CUBE
            data[c] = Float32(f(c.x, c.y, c.z))
        end
        build_grid(data, 0.0f0; name="test")
    end

    function _vector_grid(f)
        data = Dict{Coord, NTuple{3, Float32}}()
        for c in _CUBE
            v = f(c.x, c.y, c.z)
            data[c] = (Float32(v[1]), Float32(v[2]), Float32(v[3]))
        end
        build_grid(data, (0.0f0, 0.0f0, 0.0f0); name="test")
    end

    # ========================================================================
    # gradient_grid
    # ========================================================================

    @testset "gradient_grid: linear field" begin
        # f(x,y,z) = 2x + 3y - z → ∇f = (2, 3, -1) everywhere
        grid = _scalar_grid((x, y, z) -> 2x + 3y - z)
        grad = gradient_grid(grid)

        @test grad isa Grid{NTuple{3, Float32}}
        for c in _INTERIOR
            v = get_value(grad.tree, c)
            @test v[1] ≈ 2.0f0
            @test v[2] ≈ 3.0f0
            @test v[3] ≈ -1.0f0
        end
    end

    @testset "gradient_grid: constant field" begin
        # f = 5 → ∇f = (0, 0, 0) everywhere
        grid = _scalar_grid((x, y, z) -> 5)
        grad = gradient_grid(grid)
        for c in _INTERIOR
            v = get_value(grad.tree, c)
            @test all(x -> abs(x) < 1f-6, v)
        end
    end

    @testset "gradient_grid: sphere SDF radial direction" begin
        sphere = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0,
                                         voxel_size=1.0, half_width=3.0)
        grad = gradient_grid(sphere)
        # At (10, 0, 0): gradient should point in +x direction
        g = get_value(grad.tree, coord(10, 0, 0))
        @test g[1] > 0.5f0   # dominant x component
        @test abs(g[2]) < 0.1f0
        @test abs(g[3]) < 0.1f0
    end

    # ========================================================================
    # laplacian (grid method)
    # ========================================================================

    @testset "laplacian: quadratic field" begin
        # f(x,y,z) = x² + y² + z² → ∇²f = 2 + 2 + 2 = 6
        grid = _scalar_grid((x, y, z) -> x^2 + y^2 + z^2)
        lap = laplacian(grid)

        @test lap isa Grid{Float32}
        for c in _INTERIOR
            @test get_value(lap.tree, c) ≈ 6.0f0
        end
    end

    @testset "laplacian: harmonic field" begin
        # f(x,y,z) = x² - y² → ∇²f = 2 - 2 = 0
        grid = _scalar_grid((x, y, z) -> x^2 - y^2)
        lap = laplacian(grid)
        for c in _INTERIOR
            @test abs(get_value(lap.tree, c)) < 1f-5
        end
    end

    @testset "laplacian: linear field" begin
        # f = 3x + 2y + z → ∇²f = 0
        grid = _scalar_grid((x, y, z) -> 3x + 2y + z)
        lap = laplacian(grid)
        for c in _INTERIOR
            @test abs(get_value(lap.tree, c)) < 1f-5
        end
    end

    # ========================================================================
    # divergence
    # ========================================================================

    @testset "divergence: uniform field" begin
        # F = (3, -2, 7) → ∇·F = 0
        grid = _vector_grid((x, y, z) -> (3, -2, 7))
        div = divergence(grid)

        @test div isa Grid{Float32}
        for c in _INTERIOR
            @test abs(get_value(div.tree, c)) < 1f-5
        end
    end

    @testset "divergence: radial field" begin
        # F = (x, y, z) → ∇·F = 1 + 1 + 1 = 3
        grid = _vector_grid((x, y, z) -> (x, y, z))
        div = divergence(grid)
        for c in _INTERIOR
            @test get_value(div.tree, c) ≈ 3.0f0
        end
    end

    @testset "divergence: single-component" begin
        # F = (x², 0, 0) → ∇·F = 2x
        grid = _vector_grid((x, y, z) -> (x^2, 0, 0))
        div = divergence(grid)
        for c in _INTERIOR
            @test get_value(div.tree, c) ≈ Float32(2 * c.x)
        end
    end

    # ========================================================================
    # curl_grid
    # ========================================================================

    @testset "curl_grid: irrotational field" begin
        # F = (x, y, z) → ∇×F = (0, 0, 0)
        grid = _vector_grid((x, y, z) -> (x, y, z))
        c_grid = curl_grid(grid)

        @test c_grid isa Grid{NTuple{3, Float32}}
        for c in _INTERIOR
            v = get_value(c_grid.tree, c)
            @test all(x -> abs(x) < 1f-5, v)
        end
    end

    @testset "curl_grid: vortex field" begin
        # F = (-y, x, 0) → ∇×F = (0, 0, 2)
        grid = _vector_grid((x, y, z) -> (-y, x, 0))
        c_grid = curl_grid(grid)
        for c in _INTERIOR
            v = get_value(c_grid.tree, c)
            @test abs(v[1]) < 1f-5
            @test abs(v[2]) < 1f-5
            @test v[3] ≈ 2.0f0
        end
    end

    @testset "curl_grid: gradient is curl-free" begin
        # ∇×(∇f) = 0 for any scalar field
        grid = _scalar_grid((x, y, z) -> x^2 * y + y * z^2)
        grad = gradient_grid(grid)
        c_grid = curl_grid(grad)
        # Interior of interior: need 2 voxels of margin for double-stencil
        inner = [coord(x, y, z) for x in -3:3, y in -3:3, z in -3:3] |> vec
        for c in inner
            v = get_value(c_grid.tree, c)
            @test all(x -> abs(x) < 1f-4, v)
        end
    end

    # ========================================================================
    # magnitude_grid
    # ========================================================================

    @testset "magnitude_grid" begin
        grid = _vector_grid((x, y, z) -> (3, 4, 0))
        mag = magnitude_grid(grid)

        @test mag isa Grid{Float32}
        for c in _CUBE
            @test get_value(mag.tree, c) ≈ 5.0f0
        end
    end

    @testset "magnitude_grid: varying vectors" begin
        grid = _vector_grid((x, y, z) -> (Float64(x), 0, 0))
        mag = magnitude_grid(grid)
        for c in _CUBE
            @test get_value(mag.tree, c) ≈ Float32(abs(c.x))
        end
    end

    # ========================================================================
    # normalize_grid
    # ========================================================================

    @testset "normalize_grid" begin
        grid = _vector_grid((x, y, z) -> (3, 4, 0))
        nrm = normalize_grid(grid)

        @test nrm isa Grid{NTuple{3, Float32}}
        for c in _CUBE
            v = get_value(nrm.tree, c)
            @test v[1] ≈ 0.6f0
            @test v[2] ≈ 0.8f0
            @test abs(v[3]) < 1f-6
        end
    end

    @testset "normalize_grid: unit length" begin
        grid = _vector_grid((x, y, z) -> (Float64(x + 1), Float64(y + 1), Float64(z + 1)))
        nrm = normalize_grid(grid)
        for c in _CUBE
            v = get_value(nrm.tree, c)
            n = sqrt(v[1]^2 + v[2]^2 + v[3]^2)
            # Either unit length or zero (for zero input)
            x, y, z = Float32(c.x + 1), Float32(c.y + 1), Float32(c.z + 1)
            if sqrt(x^2 + y^2 + z^2) > 1f-6
                @test n ≈ 1.0f0 atol=1f-5
            end
        end
    end

    @testset "normalize_grid: zero vector stays zero" begin
        grid = _vector_grid((x, y, z) -> (0, 0, 0))
        nrm = normalize_grid(grid)
        for c in _CUBE
            v = get_value(nrm.tree, c)
            @test all(x -> abs(x) < 1f-6, v)
        end
    end

    # ========================================================================
    # mean_curvature
    # ========================================================================

    @testset "mean_curvature: sphere" begin
        # Sphere SDF radius=10: κ = div(∇f/|∇f|) = 2/R = 0.2
        sphere = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0,
                                          voxel_size=1.0, half_width=3.0)
        mc = mean_curvature(sphere)

        @test mc isa Grid{Float32}
        # Test at surface along each axis
        for c in [coord(10, 0, 0), coord(0, 10, 0), coord(0, 0, 10),
                  coord(-10, 0, 0), coord(0, -10, 0), coord(0, 0, -10)]
            κ = get_value(mc.tree, c)
            @test κ ≈ 0.2f0 atol=0.05f0  # 2/R with discrete error tolerance
        end
    end

    @testset "mean_curvature: planar field" begin
        # f = x → flat level sets → zero curvature
        grid = _scalar_grid((x, y, z) -> x)
        mc = mean_curvature(grid)
        for c in _INTERIOR
            @test abs(get_value(mc.tree, c)) < 1f-5
        end
    end

    @testset "mean_curvature: larger sphere has less curvature" begin
        small = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=5.0,
                                         voxel_size=1.0, half_width=3.0)
        large = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=15.0,
                                         voxel_size=1.0, half_width=3.0)
        mc_small = mean_curvature(small)
        mc_large = mean_curvature(large)
        κ_small = abs(get_value(mc_small.tree, coord(5, 0, 0)))
        κ_large = abs(get_value(mc_large.tree, coord(15, 0, 0)))
        # κ = 2/R → smaller sphere has larger curvature
        @test κ_small > κ_large
    end

    # ========================================================================
    # Edge cases
    # ========================================================================

    @testset "empty grid" begin
        empty = build_grid(Dict{Coord, Float32}(), 0.0f0; name="empty")
        @test active_voxel_count(gradient_grid(empty).tree) == 0
        @test active_voxel_count(laplacian(empty).tree) == 0
    end

    @testset "single voxel" begin
        data = Dict(coord(0, 0, 0) => 1.0f0)
        grid = build_grid(data, 0.0f0; name="single")
        grad = gradient_grid(grid)
        # Gradient at single voxel uses background neighbors
        v = get_value(grad.tree, coord(0, 0, 0))
        @test v isa NTuple{3, Float32}
    end

end
