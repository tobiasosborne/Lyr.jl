using Test
using Lyr
using Lyr: Coord, coord, build_grid, leaves, active_voxel_count, leaf_count,
           i1_nodes, i2_nodes, collect_leaves, foreach_leaf,
           InternalNode1, InternalNode2, LeafNode, count_on

@testset "Node Iteration" begin

    @testset "Multi-region grid" begin
        # Build a grid spanning multiple I2/I1/leaf regions
        # VDB hierarchy: leaf=8^3, I1=16^3 (128 voxels per axis), I2=32^3 (4096 voxels per axis)
        # Stepping by 8 across x=0:8:100, y=0:8:100, z=0:8:16 ensures multiple leaves and I1 nodes
        data = Dict{Coord, Float32}()
        for x in 0:8:100
            for y in 0:8:100
                for z in 0:8:16
                    data[coord(x, y, z)] = Float32(x + y + z)
                end
            end
        end
        grid = build_grid(data, 0.0f0)
        tree = grid.tree

        @testset "i2_nodes returns InternalNode2 with Coord origins" begin
            i2_list = collect(i2_nodes(tree))
            @test length(i2_list) >= 1
            for (node, origin) in i2_list
                @test node isa InternalNode2{Float32}
                @test origin isa Coord
            end
        end

        @testset "i1_nodes returns InternalNode1 instances" begin
            i1_list = collect(i1_nodes(tree))
            i2_list = collect(i2_nodes(tree))
            @test length(i1_list) >= length(i2_list)
            for (node, origin) in i1_list
                @test node isa InternalNode1{Float32}
                @test origin isa Coord
            end
        end

        @testset "collect_leaves matches leaf_count and collect(leaves(tree))" begin
            lvs = collect_leaves(tree)
            @test length(lvs) == leaf_count(tree)
            lvs_iter = collect(leaves(tree))
            @test length(lvs) == length(lvs_iter)
            # Same origins (order may differ due to dict iteration, so compare as sets)
            origins_a = Set(l.origin for l in lvs)
            origins_b = Set(l.origin for l in lvs_iter)
            @test origins_a == origins_b
        end

        @testset "foreach_leaf with atomic counter matches active_voxel_count" begin
            counter = Threads.Atomic{Int}(0)
            foreach_leaf(tree) do leaf
                Threads.atomic_add!(counter, count_on(leaf.value_mask))
            end
            @test counter[] == active_voxel_count(tree)
        end

        @testset "Hierarchy: n_leaves >= n_i1 >= n_i2 >= 1" begin
            n_i2 = length(collect(i2_nodes(tree)))
            n_i1 = length(collect(i1_nodes(tree)))
            n_leaves = leaf_count(tree)
            @test n_leaves >= n_i1
            @test n_i1 >= n_i2
            @test n_i2 >= 1
        end
    end

    @testset "Empty tree" begin
        grid = build_grid(Dict{Coord, Float32}(), 0.0f0)
        tree = grid.tree

        @test isempty(collect(i2_nodes(tree)))
        @test isempty(collect(i1_nodes(tree)))
        @test isempty(collect_leaves(tree))

        # foreach_leaf on empty tree should not error
        counter = Threads.Atomic{Int}(0)
        foreach_leaf(tree) do leaf
            Threads.atomic_add!(counter, 1)
        end
        @test counter[] == 0
    end

    @testset "Single-leaf tree" begin
        data = Dict{Coord, Float32}()
        data[coord(0, 0, 0)] = 1.0f0
        grid = build_grid(data, 0.0f0)
        tree = grid.tree

        @test length(collect(i2_nodes(tree))) == 1
        @test length(collect(i1_nodes(tree))) == 1
        @test length(collect_leaves(tree)) == 1

        # foreach_leaf should visit exactly one leaf
        counter = Threads.Atomic{Int}(0)
        foreach_leaf(tree) do leaf
            Threads.atomic_add!(counter, 1)
        end
        @test counter[] == 1
    end
end
