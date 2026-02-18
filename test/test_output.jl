# Test output formats and tone mapping
using Test
using Lyr

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
end
