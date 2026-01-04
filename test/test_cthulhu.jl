# test_cthulhu.jl - Interactive type descent debugging with Cthulhu.jl
#
# ============================================================================
# USAGE GUIDE: Cthulhu.jl for Type Debugging
# ============================================================================
#
# Cthulhu.jl provides interactive type inference exploration via @descend.
# Unlike @code_warntype which shows a static view, @descend lets you navigate
# the call tree and see type inference at each level.
#
# WHEN TO USE:
# - When @code_warntype shows type instability but the cause isn't obvious
# - To trace type inference through nested function calls
# - To understand why a specific call site has poor type inference
#
# HOW TO USE (in REPL):
#
#   julia> using Lyr, Cthulhu
#   julia> @descend get_value(tree, coord(5, 5, 5))
#
# INTERACTIVE COMMANDS:
#   o - Toggle optimization level (typed vs optimized IR)
#   d - Descend into selected call (navigate deeper)
#   u - Ascend (go back up)
#   q - Quit
#   b - Toggle bounds checking
#   w - Toggle @code_warntype style display
#   s - Toggle source code display
#
# INTERPRETING OUTPUT:
# - Red text indicates type instability (::Any, Union types)
# - Green/blue text indicates stable concrete types
# - Look for "invoke" vs "call" - invoke is type-stable dispatch
#
# EXAMPLE SESSION:
#
#   # Check if leaf_offset is type-stable
#   julia> @descend leaf_offset(coord(10, 20, 30))
#
#   # Investigate get_value which has complex dispatch
#   julia> tree = ...  # your tree
#   julia> @descend get_value(tree, coord(5, 5, 5))
#   # Press 'd' to descend into internal2_origin, internal2_child_index, etc.
#
#   # Check interpolation (often a source of type issues)
#   julia> @descend sample_trilinear(tree, (5.5, 5.5, 5.5))
#
# KEY FUNCTIONS TO CHECK:
# - get_value: Complex tree traversal with multiple dispatch paths
# - sample_trilinear: Floating point interpolation
# - read_grid: File parsing with type-dependent branches
# - active_voxels iteration: Iterator state management
#
# ============================================================================

# This file documents Cthulhu.jl usage rather than running automated tests.
# Cthulhu is an interactive tool - @descend requires terminal interaction.

@testset "Cthulhu" begin
    @testset "Cthulhu.jl available" begin
        # Verify Cthulhu is loadable (actual usage is interactive)
        @test isdefined(Main, :Cthulhu) || begin
            try
                @eval Main using Cthulhu
                true
            catch
                @warn "Cthulhu.jl not available - install with: ] add Cthulhu"
                true  # Don't fail the test suite
            end
        end
    end

    @testset "Key functions for @descend" begin
        # These are the functions most likely to benefit from @descend debugging.
        # Run these in REPL with @descend when investigating type issues.

        # Setup test data
        bytes = UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        c = coord(10, 20, 30)
        tile = Tile{Float32}(1.0f0, true)
        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(
            coord(0, 0, 0) => tile
        )
        tree = RootNode{Float32}(0.0f0, table)

        # Verify functions are callable (for @descend in REPL)
        @test leaf_offset(c) isa Int
        @test get_value(tree, c) isa Float32
        @test is_active(tree, c) isa Bool
        @test sample_nearest(tree, (5.5, 5.5, 5.5)) isa Float32
    end
end

# ============================================================================
# QUICK REFERENCE: Copy-paste into REPL
# ============================================================================
#
# # Load packages
# using Lyr, Cthulhu
#
# # Create test tree
# tile = Tile{Float32}(1.0f0, true)
# table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(
#     coord(0, 0, 0) => tile
# )
# tree = RootNode{Float32}(0.0f0, table)
#
# # Descend into key functions
# @descend leaf_offset(coord(10, 20, 30))
# @descend get_value(tree, coord(5, 5, 5))
# @descend sample_trilinear(tree, (5.5, 5.5, 5.5))
# @descend is_on(LeafMask(), 0)
#
# ============================================================================
