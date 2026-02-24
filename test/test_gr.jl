# test_gr.jl — Standalone GR module test runner
#
# Usage: julia --project test/test_gr.jl

using Test
using Lyr
using Lyr.GR

@testset "GR Module" begin
    include("test_gr_types.jl")
    include("test_gr_metric.jl")
    include("test_gr_schwarzschild.jl")
    include("test_gr_integrator.jl")
    include("test_gr_camera.jl")
    include("test_gr_matter.jl")
    include("test_gr_redshift.jl")
    include("test_gr_render.jl")
    include("test_gr_volumetric.jl")
    include("test_gr_validation.jl")
end
