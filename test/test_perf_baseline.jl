# Test bench/perf_baseline.jl — structure only, not timing values.
# Bead: path-tracer-78us (A2) of EPIC path-tracer-ooul.
#
# Runs the baseline at tiny resolution (32×32 spp=1) to validate the script
# wires up end-to-end and emits the required JSON shape. Timings are not
# asserted — the bench lives on a shared machine and numbers drift.
#
# Acceptance criterion (from bead): "Script runs clean, emits JSON with all
# 3 scenes × 4 phases." — tested literally below.
using Test
using Lyr

const _BENCH_SCRIPT = joinpath(@__DIR__, "..", "bench", "perf_baseline.jl")

@testset "bench/perf_baseline.jl (A2)" begin
    @test isfile(_BENCH_SCRIPT)

    # Include rather than shell out: avoids a nested Julia startup, keeps the
    # test fast, and the script's `abspath(PROGRAM_FILE)==@__FILE__` guard
    # prevents main() from auto-running on include.
    mod = Module(:PerfBaselineTest)
    Base.include(mod, _BENCH_SCRIPT)

    tmp = tempname() * ".json"
    records, outpath = Base.invokelatest(mod.run_baseline;
                                         width=32, height=32,
                                         spp=1, warmup_res=8,
                                         output_path=tmp)

    @test outpath == tmp
    @test isfile(outpath)

    @testset "3 canonical scenes all rendered" begin
        # All three fixtures are present in this repo (smoke.vdb,
        # bunny_cloud.vdb) or synthetic (level_set_sphere) — no skips expected.
        @test length(records) == 3
    end

    @testset "each record has all four A1 phases + total" begin
        for rec in records
            for field in (:upload_ms, :kernel_ms, :accum_ms, :readback_ms, :total_ms)
                @test hasproperty(rec, field)
                @test getproperty(rec, field) isa Real
                @test getproperty(rec, field) >= 0
            end
            @test hasproperty(rec, :name)
            @test hasproperty(rec, :active_vox)
            @test hasproperty(rec, :buffer_kb)
        end
    end

    @testset "JSON payload is well-formed and contains expected keys" begin
        json = read(outpath, String)
        @test startswith(json, "{")
        @test endswith(json, "}")
        # Loose structure check — the payload NamedTuple keys must appear.
        for key in ("generated_at", "backend", "gpu_info", "julia",
                    "config", "scenes", "skipped")
            @test occursin("\"$key\":", json)
        end
        # 4 A1 phases must appear at least once per rendered scene.
        for phase in ("upload_ms", "kernel_ms", "accum_ms", "readback_ms", "total_ms")
            @test count(==(phase), split(json, "\""; keepempty=false)) >= length(records)
        end
    end
end
