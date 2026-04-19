# Test GPUNanoGrid device-side cache struct.
# Bead: path-tracer-mx1u (C1). Part of EPIC path-tracer-ooul.
#
# The struct holds device-resident buffers that gpu_render_volume currently
# re-uploads on every call: nanovdb bytes, TF LUT, lights. Caching them in
# a user-constructed handle amortises H2D transfer across render calls.
#
# C1 defines only the struct. C2 (path-tracer-htby) adds the constructor.
#
# Ref: docs/stocktake/04_gpu_rendering.md §3 (architecture diagram) and
#      docs/stocktake/08_perf_vs_webgl.md §4.2 (the fix this enables).
using Test
using Lyr
using KernelAbstractions

import Lyr: GPUNanoGrid

@testset "GPUNanoGrid struct (C1)" begin
    backend = KernelAbstractions.CPU()
    buf     = UInt8[0x01, 0x02, 0x03]
    tf_lut  = Float32[0.1, 0.2, 0.3, 0.4]
    lights  = Float32[0.0, 0.577, 0.577, 0.577, 1.0, 1.0, 1.0]

    g = GPUNanoGrid(backend, buf, tf_lut, lights)

    @testset "field access" begin
        @test g.backend === backend
        @test g.buffer  === buf
        @test g.tf_lut  === tf_lut
        @test g.lights  === lights
    end

    @testset "parametric over concrete types" begin
        @test g isa GPUNanoGrid{typeof(backend), typeof(buf), typeof(tf_lut), typeof(lights)}
    end

    @testset "immutable" begin
        @test !ismutabletype(GPUNanoGrid)
    end
end
