@testset "NanoVDB" begin
    # Load cube.vdb for testing
    cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
    cube_file = parse_vdb(read(cube_path))
    cube_grid = cube_file.grids[1]
    cube_tree = cube_grid.tree

    @testset "Buffer mask operations" begin
        # Create a small buffer with a known mask
        buf = zeros(UInt8, 128)
        # Write a single UInt64 word with bits 0, 3, 7 set
        word = UInt64(1) | (UInt64(1) << 3) | (UInt64(1) << 7)
        Lyr._buf_store!(buf, 1, word)
        # Write prefix (cumulative popcount)
        Lyr._buf_store!(buf, 9, UInt32(3))  # 3 bits on in word 1

        @test Lyr._buf_mask_is_on(buf, 1, 0) == true
        @test Lyr._buf_mask_is_on(buf, 1, 1) == false
        @test Lyr._buf_mask_is_on(buf, 1, 3) == true
        @test Lyr._buf_mask_is_on(buf, 1, 7) == true
        @test Lyr._buf_mask_is_on(buf, 1, 6) == false

        @test Lyr._buf_count_on_before(buf, 1, 9, 0) == 0
        @test Lyr._buf_count_on_before(buf, 1, 9, 1) == 1   # bit 0 before
        @test Lyr._buf_count_on_before(buf, 1, 9, 3) == 1   # bit 0 before bit 3
        @test Lyr._buf_count_on_before(buf, 1, 9, 4) == 2   # bits 0,3 before bit 4
        @test Lyr._buf_count_on_before(buf, 1, 9, 8) == 3   # bits 0,3,7 before bit 8
    end

    @testset "Buffer load/store roundtrip" begin
        buf = zeros(UInt8, 64)

        Lyr._buf_store!(buf, 1, UInt32(42))
        @test Lyr._buf_load(UInt32, buf, 1) == UInt32(42)

        Lyr._buf_store!(buf, 5, Float32(3.14))
        @test Lyr._buf_load(Float32, buf, 5) == Float32(3.14)

        Lyr._buf_store!(buf, 9, Float64(-2.718))
        @test Lyr._buf_load(Float64, buf, 9) == Float64(-2.718)

        c = Coord(Int32(10), Int32(-20), Int32(30))
        Lyr._buf_store_coord!(buf, 17, c)
        @test Lyr._buf_load_coord(buf, 17) == c
    end

    @testset "build_nanogrid" begin
        nanogrid = build_nanogrid(cube_tree)

        @test nano_background(nanogrid) == cube_tree.background
        @test nano_root_count(nanogrid) > 0
        @test nano_leaf_count(nanogrid) == leaf_count(cube_tree)
        @test nano_i2_count(nanogrid) > 0
        @test nano_i1_count(nanogrid) > 0

        # Verify magic and version
        @test Lyr._buf_load(UInt32, nanogrid.buffer, 1) == Lyr.NANO_MAGIC
        @test Lyr._buf_load(UInt32, nanogrid.buffer, 5) == Lyr.NANO_VERSION

        # Verify bbox is reasonable
        bbox = nano_bbox(nanogrid)
        tree_bbox = active_bounding_box(cube_tree)
        @test tree_bbox !== nothing
        @test Lyr.contains(bbox, tree_bbox.min)
        @test Lyr.contains(bbox, tree_bbox.max)
    end

    @testset "NanoLeaf view" begin
        nanogrid = build_nanogrid(cube_tree)
        leaf_pos = Lyr._nano_leaf_pos(nanogrid)
        leaf_sz = Lyr._leaf_node_size(Float32)

        # Check first leaf
        view = NanoLeafView{Float32}(nanogrid.buffer, leaf_pos)
        origin = nano_origin(view)

        # The origin should be leaf-aligned (multiple of 8)
        @test origin.x % 8 == 0
        @test origin.y % 8 == 0
        @test origin.z % 8 == 0

        # Find the same leaf in the tree
        first_leaf = first(leaves(cube_tree))
        first_view = NanoLeafView{Float32}(nanogrid.buffer, leaf_pos)
        first_origin = nano_origin(first_view)

        # Values should match for all 512 voxels in this leaf
        tree_leaf = nothing
        for leaf in leaves(cube_tree)
            if leaf.origin == first_origin
                tree_leaf = leaf
                break
            end
        end
        if tree_leaf !== nothing
            for i in 0:511
                @test nano_get_value(first_view, i) == tree_leaf.values[i + 1]
                @test nano_is_active(first_view, i) == is_on(tree_leaf.value_mask, i)
            end
        end
    end

    @testset "get_value equivalence" begin
        nanogrid = build_nanogrid(cube_tree)

        # Test all active voxels
        n_tested = 0
        for (c, v) in active_voxels(cube_tree)
            nano_v = get_value(nanogrid, c)
            @test nano_v == v
            n_tested += 1
            n_tested >= 2000 && break  # cap for speed
        end
        @test n_tested > 0
    end

    @testset "Random coord equivalence" begin
        nanogrid = build_nanogrid(cube_tree)

        # Get bbox for random coordinate generation
        bbox = active_bounding_box(cube_tree)
        @test bbox !== nothing

        # Expand bbox slightly to test inactive regions too
        margin = Coord(Int32(16), Int32(16), Int32(16))
        test_min = bbox.min - margin
        test_max = bbox.max + margin

        rng = 42  # deterministic seed via simple counter
        n_match = 0
        for i in 1:1000
            # Simple deterministic pseudo-random coords
            x = Int32(test_min.x + mod(i * 7919, Int(test_max.x - test_min.x + 1)))
            y = Int32(test_min.y + mod(i * 6271, Int(test_max.y - test_min.y + 1)))
            z = Int32(test_min.z + mod(i * 4973, Int(test_max.z - test_min.z + 1)))
            c = Coord(x, y, z)

            tree_val = get_value(cube_tree, c)
            nano_val = get_value(nanogrid, c)
            @test nano_val == tree_val
            n_match += 1
        end
        @test n_match == 1000
    end

    @testset "NanoValueAccessor" begin
        nanogrid = build_nanogrid(cube_tree)
        acc = NanoValueAccessor(nanogrid)

        # Test that cached accessor matches uncached for all active voxels
        n_tested = 0
        for (c, v) in active_voxels(cube_tree)
            acc_v = get_value(acc, c)
            @test acc_v == v
            n_tested += 1
            n_tested >= 2000 && break
        end
        @test n_tested > 0

        # Test cache hits: access same leaf region repeatedly
        first_leaf = first(leaves(cube_tree))
        o = first_leaf.origin
        for dx in Int32(0):Int32(7), dy in Int32(0):Int32(7)
            c = Coord(o.x + dx, o.y + dy, o.z)
            @test get_value(acc, c) == get_value(cube_tree, c)
        end
    end

    @testset "active_voxel_count" begin
        nanogrid = build_nanogrid(cube_tree)
        @test active_voxel_count(nanogrid) == active_voxel_count(cube_tree)
    end

    @testset "DDA equivalence" begin
        nanogrid = build_nanogrid(cube_tree)

        bbox = active_bounding_box(cube_tree)
        @test bbox !== nothing
        center = SVec3d(
            (Float64(bbox.min.x) + Float64(bbox.max.x)) / 2,
            (Float64(bbox.min.y) + Float64(bbox.max.y)) / 2,
            (Float64(bbox.min.z) + Float64(bbox.max.z)) / 2
        )

        n_matching = 0
        for i in 1:50
            # Generate rays from outside pointing toward center
            angle1 = Float64(i) * 0.1256
            angle2 = Float64(i) * 0.0731
            r = 200.0
            origin = SVec3d(
                center[1] + r * cos(angle1) * cos(angle2),
                center[2] + r * sin(angle1),
                center[3] + r * cos(angle1) * sin(angle2)
            )
            direction = center - origin
            ray = Ray(origin, direction)

            # Collect leaf origins from tree-based VRI
            tree_origins = Coord[]
            for hit in VolumeRayIntersector(cube_tree, ray)
                push!(tree_origins, hit.leaf.origin)
            end

            # Collect leaf origins from NanoVRI
            nano_origins = Coord[]
            for hit in NanoVolumeRayIntersector(nanogrid, ray)
                origin = Lyr._buf_load_coord(nanogrid.buffer, hit.leaf_offset)
                push!(nano_origins, origin)
            end

            @test tree_origins == nano_origins
            if !isempty(tree_origins)
                n_matching += 1
            end
        end
        @test n_matching > 10  # At least some rays should hit leaves
    end

    @testset "Multiple grid types" begin
        # Test with sphere.vdb (level set, likely Float32)
        sphere_path = joinpath(@__DIR__, "fixtures", "samples", "sphere.vdb")
        if !isfile(sphere_path)
            @test_skip "fixture not found: $sphere_path"
            return
        end
        sphere_file = parse_vdb(read(sphere_path))
        for grid in sphere_file.grids
            T = eltype(grid.tree.table).types[1] isa DataType ? Float32 : Float32
            nanogrid = build_nanogrid(grid.tree)

            @test nano_leaf_count(nanogrid) == leaf_count(grid.tree)
            @test active_voxel_count(nanogrid) == active_voxel_count(grid.tree)

            # Spot-check a few active voxels
            n = 0
            for (c, v) in active_voxels(grid.tree)
                @test get_value(nanogrid, c) == v
                n += 1
                n >= 100 && break
            end
        end
    end
end
