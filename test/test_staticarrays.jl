@testset "StaticArrays Foundation" begin
    @testset "Type aliases exported with correct types/sizes" begin
        # SVec3f
        v = SVec3f(1.0f0, 2.0f0, 3.0f0)
        @test length(v) == 3
        @test eltype(v) == Float32
        @test v isa SVec3f

        # SVec3d
        w = SVec3d(1.0, 2.0, 3.0)
        @test length(w) == 3
        @test eltype(w) == Float64
        @test w isa SVec3d

        # SMat3d
        m = SMat3d(1,0,0, 0,1,0, 0,0,1)
        @test size(m) == (3, 3)
        @test eltype(m) == Float64
        @test m isa SMat3d
    end

    @testset "LinearTransform stores SMat3d/SVec3d fields" begin
        mat = SMat3d(2.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 4.0)
        trans = SVec3d(10.0, 20.0, 30.0)
        t = LinearTransform(mat, trans)

        @test t.mat isa SMat3d
        @test t.trans isa SVec3d
        @test t.inv_mat isa SMat3d
        @test t.mat == mat
        @test t.trans == trans
        @test t.mat * t.inv_mat ≈ SMat3d(1,0,0, 0,1,0, 0,0,1)
    end

    @testset "LinearTransform NTuple convenience constructor" begin
        t1 = LinearTransform(SMat3d(2.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 2.0), SVec3d(1.0, 2.0, 3.0))
        t2 = LinearTransform((2.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 2.0), (1.0, 2.0, 3.0))

        @test t1.mat == t2.mat
        @test t1.trans == t2.trans
    end

    @testset "index_to_world SVec3d vs NTuple produce identical results" begin
        mat = SMat3d(0.5, 0.0, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0, 0.5)
        trans = SVec3d(1.0, 2.0, 3.0)
        t = LinearTransform(mat, trans)
        c = coord(10, 20, 30)

        ntuple_result = index_to_world(t, c)
        svec_result = index_to_world(t, SVec3d(10.0, 20.0, 30.0))

        @test ntuple_result[1] ≈ svec_result[1]
        @test ntuple_result[2] ≈ svec_result[2]
        @test ntuple_result[3] ≈ svec_result[3]
        @test svec_result isa SVec3d
    end

    @testset "world_to_index_float SVec3d vs NTuple produce identical results" begin
        mat = SMat3d(0.5, 0.0, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0, 0.5)
        trans = SVec3d(1.0, 2.0, 3.0)
        t = LinearTransform(mat, trans)
        xyz = (6.0, 12.0, 18.0)

        ntuple_result = world_to_index_float(t, xyz)
        svec_result = world_to_index_float(t, SVec3d(xyz...))

        @test ntuple_result[1] ≈ svec_result[1]
        @test ntuple_result[2] ≈ svec_result[2]
        @test ntuple_result[3] ≈ svec_result[3]
        @test svec_result isa SVec3d
    end

    @testset "Round-trip index_to_world ↔ world_to_index_float with SVec3d" begin
        transforms = [
            LinearTransform(SMat3d(1,0,0, 0,1,0, 0,0,1), SVec3d(0,0,0)),
            LinearTransform(SMat3d(2,0,0, 0,3,0, 0,0,4), SVec3d(10,20,30)),
            UniformScaleTransform(0.1),
            UniformScaleTransform(5.0),
        ]

        for t in transforms
            for v in [SVec3d(0,0,0), SVec3d(10,20,30), SVec3d(-5,10,-15)]
                w = index_to_world(t, v)
                back = world_to_index_float(t, w)
                @test back ≈ v atol=1e-12
            end
        end
    end

    @testset "UniformScaleTransform SVec3d overloads" begin
        t = UniformScaleTransform(0.5)

        w = index_to_world(t, SVec3d(2.0, 4.0, 6.0))
        @test w isa SVec3d
        @test w ≈ SVec3d(1.0, 2.0, 3.0)

        back = world_to_index_float(t, w)
        @test back isa SVec3d
        @test back ≈ SVec3d(2.0, 4.0, 6.0)
    end

    @testset "world_to_index with SVec3d" begin
        t = UniformScaleTransform(0.5)
        c = world_to_index(t, SVec3d(1.0, 2.0, 3.0))
        @test c == coord(2, 4, 6)
    end

    @testset "Coord, Mask, LeafNode unchanged" begin
        # Coord is still Int32-based
        c = coord(1, 2, 3)
        @test c.x isa Int32
        @test c.y isa Int32
        @test c.z isa Int32

        # Mask is still NTuple{W,UInt64}
        m = Mask{512, 8}(ntuple(_ -> UInt64(0), Val(8)))
        @test m.words isa NTuple{8, UInt64}

        # LeafNode values are still NTuple{512,T}
        vals = ntuple(_ -> Float32(0), Val(512))
        vmask = LeafMask(ntuple(_ -> UInt64(0), Val(8)))
        leaf = LeafNode{Float32}(coord(0,0,0), vmask, vals)
        @test leaf.values isa NTuple{512, Float32}
    end

    @testset "sample_world SVec3d matches NTuple" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "sphere.vdb"))
        grid = vdb.grids[1]
        xyz = (0.5, 0.5, 0.5)

        val_ntuple = sample_world(grid, xyz)
        val_svec = sample_world(grid, SVec3d(xyz...))

        @test val_ntuple == val_svec
    end

    @testset "sample_nearest/sample_trilinear SVec3d" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "sphere.vdb"))
        tree = vdb.grids[1].tree

        ijk = SVec3d(5.0, 5.0, 5.0)
        val_nn = sample_nearest(tree, ijk)
        val_tl = sample_trilinear(tree, ijk)

        # Both should return a Float32 (sphere.vdb is Float32)
        @test val_nn isa Float32
        @test val_tl isa Float32

        # Nearest matches NTuple path
        @test val_nn == sample_nearest(tree, (5.0, 5.0, 5.0))
        @test val_tl == sample_trilinear(tree, (5.0, 5.0, 5.0))
    end
end
