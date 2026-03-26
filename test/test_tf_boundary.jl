# Transfer function NaN/boundary tests
using Test, Lyr

@testset "TransferFunction boundary inputs" begin
    tf = tf_smoke()

    @testset "NaN and Inf inputs don't crash" begin
        # NaN propagates through (documented behavior)
        r, g, b, a = evaluate(tf, NaN)
        @test isa(r, Float64)

        # Inf clamps to last control point
        r, g, b, a = evaluate(tf, Inf)
        @test all(isfinite, (r, g, b, a))

        r, g, b, a = evaluate(tf, -Inf)
        @test all(isfinite, (r, g, b, a))
    end

    @testset "Negative density" begin
        r, g, b, a = evaluate(tf, -1.0)
        @test all(isfinite, (r, g, b, a))
    end

    @testset "Zero density" begin
        r, g, b, a = evaluate(tf, 0.0)
        @test all(isfinite, (r, g, b, a))
        @test a ≈ 0.0 atol=0.01  # smoke TF: zero density → transparent
    end

    @testset "Very large density" begin
        r, g, b, a = evaluate(tf, 1e10)
        @test all(isfinite, (r, g, b, a))
    end

    @testset "All TF presets produce valid output" begin
        for tf_fn in [tf_smoke, tf_blackbody]
            tf = tf_fn()
            for d in [0.0, 0.25, 0.5, 0.75, 1.0]
                r, g, b, a = evaluate(tf, d)
                @test 0.0 <= r <= 1.0
                @test 0.0 <= g <= 1.0
                @test 0.0 <= b <= 1.0
                @test 0.0 <= a <= 1.0
            end
        end
    end
end
