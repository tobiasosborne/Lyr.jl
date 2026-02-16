using Test
using Lyr
using InteractiveUtils
using JET
using Cthulhu

@testset "Lyr.jl" begin
    include("test_binary.jl")
    include("test_masks.jl")
    include("test_coordinates.jl")
    include("test_compression.jl")
    include("test_tree_types.jl")
    include("test_topology.jl")
    include("test_values.jl")
    include("test_tree_read.jl")
    include("test_transforms.jl")
    include("test_staticarrays.jl")
    include("test_grid.jl")
    include("test_file.jl")
    include("test_accessors.jl")
    include("test_interpolation.jl")
    include("test_ray.jl")
    include("test_dda.jl")
    include("test_node_dda.jl")
    include("test_render.jl")
    include("test_integration.jl")
    include("test_parser_equivalence.jl")
    include("test_properties.jl")
    include("test_type_stability.jl")
    include("test_jet.jl")
    include("test_cthulhu.jl")
end
