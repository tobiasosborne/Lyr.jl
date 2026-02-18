# Test transfer function evaluation and presets
using Test
using Lyr

# Include source into Lyr module until Lyr.jl adds the include/exports
Base.include(Lyr, joinpath(@__DIR__, "..", "src", "TransferFunction.jl"))
using .Lyr: ControlPoint, TransferFunction, evaluate
using .Lyr: tf_blackbody, tf_cool_warm, tf_smoke, tf_viridis

@testset "TransferFunction" begin
    @testset "ControlPoint construction" begin
        cp = ControlPoint(0.5, (1.0, 0.0, 0.0, 1.0))
        @test cp.density == 0.5
        @test cp.color == (1.0, 0.0, 0.0, 1.0)
    end

    @testset "TransferFunction sorts control points" begin
        # Provide points out of order
        pts = [
            ControlPoint(0.8, (0.0, 0.0, 1.0, 1.0)),
            ControlPoint(0.2, (1.0, 0.0, 0.0, 1.0)),
            ControlPoint(0.5, (0.0, 1.0, 0.0, 1.0)),
        ]
        tf = TransferFunction(pts)

        @test tf.points[1].density == 0.2
        @test tf.points[2].density == 0.5
        @test tf.points[3].density == 0.8
    end

    @testset "TransferFunction rejects empty points" begin
        @test_throws ArgumentError TransferFunction(ControlPoint[])
    end

    @testset "Evaluate at exact control point densities" begin
        pts = [
            ControlPoint(0.0, (0.0, 0.0, 0.0, 0.0)),
            ControlPoint(0.5, (0.5, 0.3, 0.1, 0.8)),
            ControlPoint(1.0, (1.0, 1.0, 1.0, 1.0)),
        ]
        tf = TransferFunction(pts)

        # At first point
        c = evaluate(tf, 0.0)
        @test c == (0.0, 0.0, 0.0, 0.0)

        # At middle point
        c = evaluate(tf, 0.5)
        @test c == (0.5, 0.3, 0.1, 0.8)

        # At last point
        c = evaluate(tf, 1.0)
        @test c == (1.0, 1.0, 1.0, 1.0)
    end

    @testset "Evaluate between control points (interpolation)" begin
        pts = [
            ControlPoint(0.0, (0.0, 0.0, 0.0, 0.0)),
            ControlPoint(1.0, (1.0, 1.0, 1.0, 1.0)),
        ]
        tf = TransferFunction(pts)

        # Midpoint should be 0.5 for all channels
        c = evaluate(tf, 0.5)
        @test c[1] ≈ 0.5 atol=1e-10
        @test c[2] ≈ 0.5 atol=1e-10
        @test c[3] ≈ 0.5 atol=1e-10
        @test c[4] ≈ 0.5 atol=1e-10

        # Quarter point
        c = evaluate(tf, 0.25)
        @test c[1] ≈ 0.25 atol=1e-10
        @test c[2] ≈ 0.25 atol=1e-10

        # Three-quarter point
        c = evaluate(tf, 0.75)
        @test c[1] ≈ 0.75 atol=1e-10
        @test c[4] ≈ 0.75 atol=1e-10
    end

    @testset "Evaluate with three control points — correct interval" begin
        pts = [
            ControlPoint(0.0, (0.0, 0.0, 0.0, 1.0)),
            ControlPoint(0.5, (1.0, 0.0, 0.0, 1.0)),
            ControlPoint(1.0, (1.0, 1.0, 1.0, 1.0)),
        ]
        tf = TransferFunction(pts)

        # Interpolate in first interval [0.0, 0.5] at t=0.5 -> density=0.25
        c = evaluate(tf, 0.25)
        @test c[1] ≈ 0.5 atol=1e-10   # R: 0 -> 1, midpoint = 0.5
        @test c[2] ≈ 0.0 atol=1e-10   # G: 0 -> 0, stays 0
        @test c[3] ≈ 0.0 atol=1e-10   # B: 0 -> 0, stays 0

        # Interpolate in second interval [0.5, 1.0] at t=0.5 -> density=0.75
        c = evaluate(tf, 0.75)
        @test c[1] ≈ 1.0 atol=1e-10   # R: 1 -> 1, stays 1
        @test c[2] ≈ 0.5 atol=1e-10   # G: 0 -> 1, midpoint = 0.5
        @test c[3] ≈ 0.5 atol=1e-10   # B: 0 -> 1, midpoint = 0.5
    end

    @testset "Evaluate below range (clamping)" begin
        pts = [
            ControlPoint(0.5, (0.5, 0.5, 0.5, 0.5)),
            ControlPoint(1.0, (1.0, 1.0, 1.0, 1.0)),
        ]
        tf = TransferFunction(pts)

        # Below first point: return first color
        c = evaluate(tf, 0.0)
        @test c == (0.5, 0.5, 0.5, 0.5)

        c = evaluate(tf, -100.0)
        @test c == (0.5, 0.5, 0.5, 0.5)
    end

    @testset "Evaluate above range (clamping)" begin
        pts = [
            ControlPoint(0.0, (0.0, 0.0, 0.0, 0.0)),
            ControlPoint(0.5, (0.5, 0.5, 0.5, 0.5)),
        ]
        tf = TransferFunction(pts)

        # Above last point: return last color
        c = evaluate(tf, 1.0)
        @test c == (0.5, 0.5, 0.5, 0.5)

        c = evaluate(tf, 100.0)
        @test c == (0.5, 0.5, 0.5, 0.5)
    end

    @testset "Single control point" begin
        tf = TransferFunction([ControlPoint(0.5, (0.3, 0.6, 0.9, 1.0))])

        # Every density returns the single color
        @test evaluate(tf, 0.0) == (0.3, 0.6, 0.9, 1.0)
        @test evaluate(tf, 0.5) == (0.3, 0.6, 0.9, 1.0)
        @test evaluate(tf, 1.0) == (0.3, 0.6, 0.9, 1.0)
    end

    @testset "Preset: tf_blackbody" begin
        tf = tf_blackbody()

        @test length(tf.points) >= 3
        @test tf.points[1].density < tf.points[end].density

        # All colors in valid range
        for pt in tf.points
            r, g, b, a = pt.color
            @test 0.0 <= r <= 1.0
            @test 0.0 <= g <= 1.0
            @test 0.0 <= b <= 1.0
            @test 0.0 <= a <= 1.0
        end

        # First point should be dark/transparent, last should be bright/opaque
        @test tf.points[1].color[4] < 0.5  # low alpha at low density
        @test tf.points[end].color[1] > 0.5  # bright at high density

        # Evaluate at several densities — all valid RGBA
        for d in 0.0:0.1:1.0
            c = evaluate(tf, d)
            @test all(x -> 0.0 <= x <= 1.0, c)
        end
    end

    @testset "Preset: tf_cool_warm" begin
        tf = tf_cool_warm()

        @test length(tf.points) >= 3

        for pt in tf.points
            r, g, b, a = pt.color
            @test 0.0 <= r <= 1.0
            @test 0.0 <= g <= 1.0
            @test 0.0 <= b <= 1.0
            @test 0.0 <= a <= 1.0
        end

        # Low density should be bluish
        c_low = evaluate(tf, 0.0)
        @test c_low[3] > c_low[1]  # B > R

        # High density should be reddish
        c_high = evaluate(tf, 1.0)
        @test c_high[1] > c_high[3]  # R > B

        # Middle should be whitish
        c_mid = evaluate(tf, 0.5)
        @test c_mid[1] > 0.8
        @test c_mid[2] > 0.8
        @test c_mid[3] > 0.8
    end

    @testset "Preset: tf_smoke" begin
        tf = tf_smoke()

        @test length(tf.points) >= 3

        for pt in tf.points
            r, g, b, a = pt.color
            @test 0.0 <= r <= 1.0
            @test 0.0 <= g <= 1.0
            @test 0.0 <= b <= 1.0
            @test 0.0 <= a <= 1.0
        end

        # Low density should be transparent
        c_low = evaluate(tf, 0.0)
        @test c_low[4] < 0.1  # nearly transparent

        # High density should be opaque and dark
        c_high = evaluate(tf, 1.0)
        @test c_high[4] > 0.9  # opaque
        @test c_high[1] < 0.1  # dark

        # Evaluate sweep — all valid
        for d in 0.0:0.1:1.0
            c = evaluate(tf, d)
            @test all(x -> 0.0 <= x <= 1.0, c)
        end
    end

    @testset "Preset: tf_viridis" begin
        tf = tf_viridis()

        @test length(tf.points) >= 4

        for pt in tf.points
            r, g, b, a = pt.color
            @test 0.0 <= r <= 1.0
            @test 0.0 <= g <= 1.0
            @test 0.0 <= b <= 1.0
            @test 0.0 <= a <= 1.0
        end

        # Evaluate sweep — all valid
        for d in 0.0:0.05:1.0
            c = evaluate(tf, d)
            @test all(x -> 0.0 <= x <= 1.0, c)
        end

        # Low density: darkish purple (R low, B moderate)
        c_low = evaluate(tf, 0.0)
        @test c_low[1] < 0.4
        @test c_low[3] > 0.2

        # High density: yellowish (R high, G high, B low)
        c_high = evaluate(tf, 1.0)
        @test c_high[1] > 0.8
        @test c_high[2] > 0.8
        @test c_high[3] < 0.3
    end

    @testset "Custom TF with many control points" begin
        # Build a custom 5-point ramp
        pts = [ControlPoint(Float64(i) / 4.0, (Float64(i) / 4.0, 0.0, 1.0 - Float64(i) / 4.0, 1.0))
               for i in 0:4]
        tf = TransferFunction(pts)

        @test length(tf.points) == 5

        # Verify interpolation is monotonic in R channel
        prev_r = -1.0
        for d in 0.0:0.01:1.0
            c = evaluate(tf, d)
            @test c[1] >= prev_r - 1e-10
            prev_r = c[1]
        end
    end
end
