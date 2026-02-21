# Test output formats and tone mapping
using Test
using Lyr
using Random

@testset "Output" begin
    @testset "tonemap_reinhard" begin
        pixels = [(0.5, 0.5, 0.5) (2.0, 3.0, 4.0)]
        result = tonemap_reinhard(pixels)

        # 0.5 / (1 + 0.5) = 1/3
        @test result[1, 1][1] ≈ 1/3 atol=1e-10
        @test result[1, 1][2] ≈ 1/3 atol=1e-10

        # HDR values: no output > 1.0
        @test all(c -> all(x -> 0.0 <= x <= 1.0, c), result)

        # 2.0 / (1 + 2.0) = 2/3
        @test result[1, 2][1] ≈ 2/3 atol=1e-10
    end

    @testset "tonemap_aces" begin
        pixels = [(0.0, 0.5, 1.0) (2.0, 5.0, 10.0)]
        result = tonemap_aces(pixels)

        # All outputs in [0, 1]
        @test all(c -> all(x -> 0.0 <= x <= 1.0, c), result)

        # Black stays black
        @test result[1, 1][1] ≈ 0.0 atol=0.01

        # ACES reference curve at x=1: (1*(2.51+0.03))/(1*(2.43+0.59)+0.14) = 2.54/3.16 ≈ 0.804
        @test result[1, 1][3] ≈ 0.804 atol=0.01
    end

    @testset "tonemap_exposure" begin
        pixels = [(1.0, 2.0, 0.0);;]
        result = tonemap_exposure(pixels, 1.0)

        # 1 - exp(-1) ≈ 0.632
        @test result[1, 1][1] ≈ 1.0 - exp(-1.0) atol=1e-10

        # 0 stays 0
        @test result[1, 1][3] ≈ 0.0 atol=1e-10

        # Higher exposure = brighter
        result2 = tonemap_exposure(pixels, 2.0)
        @test result2[1, 1][1] > result[1, 1][1]
    end

    @testset "auto_exposure" begin
        # Mid-gray image
        pixels = fill((0.18, 0.18, 0.18), 4, 4)
        exposure = auto_exposure(pixels)
        @test exposure > 0.0
        @test isfinite(exposure)

        # Very dark image should get higher exposure
        dark = fill((0.01, 0.01, 0.01), 4, 4)
        e_dark = auto_exposure(dark)

        bright = fill((1.0, 1.0, 1.0), 4, 4)
        e_bright = auto_exposure(bright)

        @test e_dark > e_bright
    end

    @testset "write_exr fallback" begin
        # Without OpenEXR.jl loaded, should fall back to PPM with warning
        pixels = fill((0.5, 0.5, 0.5), 4, 4)
        tmpfile = tempname() * ".exr"

        @test_logs (:warn, r"OpenEXR") write_exr(tmpfile, pixels)

        # Should have created a .ppm fallback
        ppm_path = replace(tmpfile, ".exr" => ".ppm")
        @test isfile(ppm_path)
        rm(ppm_path)
    end

    @testset "write_png fallback" begin
        # Without PNGFiles.jl loaded, should fall back to PPM with warning
        pixels = fill((0.5, 0.5, 0.5), 4, 4)
        tmpfile = tempname() * ".png"

        @test_logs (:warn, r"PNGFiles") write_png(tmpfile, pixels)

        # Should have created a .ppm fallback
        ppm_path = replace(tmpfile, ".png" => ".ppm")
        @test isfile(ppm_path)
        rm(ppm_path)
    end

    @testset "denoise_nlm" begin
        @testset "uniform image unchanged" begin
            pixels = fill((0.5, 0.5, 0.5), 8, 8)
            result = denoise_nlm(pixels)
            for i in eachindex(result)
                @test result[i][1] ≈ 0.5 atol=1e-10
                @test result[i][2] ≈ 0.5 atol=1e-10
                @test result[i][3] ≈ 0.5 atol=1e-10
            end
        end

        @testset "reduces noise variance" begin
            rng = MersenneTwister(42)
            base = 0.5
            pixels = Matrix{NTuple{3, Float64}}(undef, 16, 16)
            for i in eachindex(pixels)
                noise = (rand(rng) - 0.5) * 0.2
                v = base + noise
                pixels[i] = (v, v, v)
            end
            result = denoise_nlm(pixels; h=0.1)
            # Compute variance of red channel
            vals_in = [p[1] for p in pixels]
            vals_out = [p[1] for p in result]
            var_in = sum((v - base)^2 for v in vals_in) / length(vals_in)
            var_out = sum((v - base)^2 for v in vals_out) / length(vals_out)
            @test var_out < var_in
        end

        @testset "Float32 input" begin
            pixels = fill((0.5f0, 0.3f0, 0.7f0), 8, 8)
            result = denoise_nlm(pixels; h=0.1f0)
            @test eltype(result) == NTuple{3, Float32}
            @test result[1, 1][1] ≈ 0.5f0 atol=1e-5
        end

        @testset "1x1 image" begin
            pixels = [(0.3, 0.4, 0.5);;]
            result = denoise_nlm(pixels)
            @test result[1, 1] == (0.3, 0.4, 0.5)
        end

        @testset "output finite and non-negative" begin
            rng = MersenneTwister(123)
            pixels = Matrix{NTuple{3, Float64}}(undef, 8, 8)
            for i in eachindex(pixels)
                v = rand(rng) * 2.0
                pixels[i] = (v, v * 0.5, v * 0.3)
            end
            result = denoise_nlm(pixels)
            for i in eachindex(result)
                r, g, b = result[i]
                @test isfinite(r) && isfinite(g) && isfinite(b)
            end
        end
    end

    @testset "denoise_bilateral" begin
        @testset "uniform image unchanged" begin
            pixels = fill((0.5, 0.5, 0.5), 8, 8)
            result = denoise_bilateral(pixels)
            for i in eachindex(result)
                @test result[i][1] ≈ 0.5 atol=1e-10
                @test result[i][2] ≈ 0.5 atol=1e-10
                @test result[i][3] ≈ 0.5 atol=1e-10
            end
        end

        @testset "reduces noise variance" begin
            rng = MersenneTwister(99)
            base = 0.5
            pixels = Matrix{NTuple{3, Float64}}(undef, 16, 16)
            for i in eachindex(pixels)
                noise = (rand(rng) - 0.5) * 0.2
                v = base + noise
                pixels[i] = (v, v, v)
            end
            result = denoise_bilateral(pixels; range_sigma=0.1)
            vals_in = [p[1] for p in pixels]
            vals_out = [p[1] for p in result]
            var_in = sum((v - base)^2 for v in vals_in) / length(vals_in)
            var_out = sum((v - base)^2 for v in vals_out) / length(vals_out)
            @test var_out < var_in
        end

        @testset "edge preservation" begin
            # Black left half, white right half
            pixels = Matrix{NTuple{3, Float64}}(undef, 8, 16)
            for j in 1:16, i in 1:8
                v = j <= 8 ? 0.0 : 1.0
                pixels[i, j] = (v, v, v)
            end
            result = denoise_bilateral(pixels; spatial_sigma=2.0, range_sigma=0.05)
            # Far-left column should remain near black
            @test result[4, 1][1] < 0.05
            # Far-right column should remain near white
            @test result[4, 16][1] > 0.95
        end

        @testset "Float32 input" begin
            pixels = fill((0.5f0, 0.3f0, 0.7f0), 8, 8)
            result = denoise_bilateral(pixels; spatial_sigma=2.0f0, range_sigma=0.1f0)
            @test eltype(result) == NTuple{3, Float32}
            @test result[1, 1][1] ≈ 0.5f0 atol=1e-5
        end

        @testset "1x1 image" begin
            pixels = [(0.3, 0.4, 0.5);;]
            result = denoise_bilateral(pixels)
            @test result[1, 1] == (0.3, 0.4, 0.5)
        end
    end
end
