# test_elegance_sprint.jl — Closes 5 test coverage issues in one elegant file
#
# Issues covered:
#   path-tracer-51qa  Float16 half-precision value reading
#   path-tracer-6bjk  active_voxels / leaves iterator edge cases
#   path-tracer-ch41  gradient for Vec3f grids
#   path-tracer-yynz  sphere_trace with actual surface hit
#   path-tracer-htbz  robustness tests for truncated/corrupted VDB files

# ============================================================================
# Helpers
# ============================================================================

"""Build a minimal Float32 tree with one leaf containing specific voxels."""
function _make_single_leaf_tree(::Type{T}, origin::Coord, active_bits::Vector{Int},
                                 values::NTuple{512, T}, background::T) where T
    # Build leaf mask from active bit indices
    words = ntuple(_ -> UInt64(0), 8)
    for bit in active_bits
        word_idx = (bit >> 6) + 1
        bit_in_word = bit & 63
        words = Base.setindex(words, words[word_idx] | (UInt64(1) << bit_in_word), word_idx)
    end
    leaf_mask = LeafMask(words)
    leaf = LeafNode{T}(origin, leaf_mask, values)

    # Wrap in I1 → I2 → Root
    i1_child_mask = Internal1Mask((UInt64(1), ntuple(_ -> UInt64(0), 63)...))
    i1_value_mask = Internal1Mask()
    i1 = InternalNode1{T}(origin, i1_child_mask, i1_value_mask, [leaf], Tile{T}[])

    i2_child_mask = Internal2Mask((UInt64(1), ntuple(_ -> UInt64(0), 511)...))
    i2_value_mask = Internal2Mask()
    i2 = InternalNode2{T}(origin, i2_child_mask, i2_value_mask, [i1], Tile{T}[])

    table = Dict{Coord, Union{InternalNode2{T}, Tile{T}}}(origin => i2)
    RootNode{T}(background, table)
end

"""Build a Float32 tree with one active voxel at the given local offset."""
function _make_single_voxel_tree(::Type{T}, c::Coord, val::T, background::T) where T
    origin = coord(c.x & ~Int32(7), c.y & ~Int32(7), c.z & ~Int32(7))
    # Compute leaf offset: x*64 + y*8 + z (local coords)
    lx = c.x - origin.x
    ly = c.y - origin.y
    lz = c.z - origin.z
    offset = Int(lx) * 64 + Int(ly) * 8 + Int(lz)

    values = ntuple(i -> i == offset + 1 ? val : background, 512)
    _make_single_leaf_tree(T, origin, [offset], values, background)
end

"""Convenience: little-endian bytes for a primitive type."""
le_bytes(x::T) where T = collect(reinterpret(UInt8, [x]))

# ============================================================================
# 1. Float16 half-precision value reading  (issue: path-tracer-51qa)
# ============================================================================

@testset "Float16 half-precision values" begin
    @testset "read_f16_le roundtrip" begin
        @testset for (val, label) in [
            (Float16(1.0), "1.0"), (Float16(0.5), "0.5"),
            (Float16(-1.0), "-1.0"), (Float16(0.0), "0.0"),
            (Float16(42.0), "42.0"), (Float16(0.001), "0.001"),
        ]
            buf = le_bytes(val)
            result, pos = read_f16_le(buf, 1)
            @test result === val
            @test pos == 3
        end
    end

    @testset "read_f16_le special values" begin
        for val in [Float16(Inf), Float16(-Inf)]
            buf = le_bytes(val)
            result, _ = read_f16_le(buf, 1)
            @test result === val
        end

        buf = le_bytes(Float16(NaN))
        result, _ = read_f16_le(buf, 1)
        @test isnan(result)
    end

    @testset "_read_value with is_half=true widens Float16 to Float32" begin
        buf = le_bytes(Float16(2.5))
        val, pos = Lyr._read_value(Float32, buf, 1, true)
        @test val isa Float32
        @test val == Float32(Float16(2.5))
        @test pos == 3  # consumed 2 bytes (Float16)
    end

    @testset "_read_value with is_half=false reads full Float32" begin
        buf = le_bytes(1.5f0)
        val, pos = Lyr._read_value(Float32, buf, 1, false)
        @test val === 1.5f0
        @test pos == 5  # consumed 4 bytes (Float32)
    end

    @testset "_read_value half-precision preserves representable values" begin
        @testset for x in [0.0f0, 1.0f0, -1.0f0, 0.5f0, 100.0f0]
            h = Float16(x)
            buf = le_bytes(h)
            val, _ = Lyr._read_value(Float32, buf, 1, true)
            @test val == Float32(h)
        end
    end

    @testset "read_f16_le at offset > 1" begin
        # Pad with 3 garbage bytes then a Float16
        buf = UInt8[0xff, 0xfe, 0xfd, le_bytes(Float16(3.14))...]
        val, pos = read_f16_le(buf, 4)
        @test val === Float16(3.14)
        @test pos == 6
    end
end

# ============================================================================
# 2. Iterator edge cases  (issue: path-tracer-6bjk)
# ============================================================================

@testset "Iterator edge cases" begin
    @testset "active_voxels on empty tree" begin
        tree = RootNode{Float32}(0.0f0, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
        result = collect(active_voxels(tree))
        @test isempty(result)
    end

    @testset "leaves on empty tree" begin
        tree = RootNode{Float32}(0.0f0, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
        result = collect(leaves(tree))
        @test isempty(result)
    end

    @testset "active_voxels on root-tile-only tree" begin
        tile = Tile{Float32}(1.0f0, true)
        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(coord(0,0,0) => tile)
        tree = RootNode{Float32}(0.0f0, table)
        # Tiles at root level are skipped (documented behavior)
        result = collect(active_voxels(tree))
        @test isempty(result)
    end

    @testset "leaves on root-tile-only tree" begin
        tile = Tile{Float32}(1.0f0, true)
        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(coord(0,0,0) => tile)
        tree = RootNode{Float32}(0.0f0, table)
        result = collect(leaves(tree))
        @test isempty(result)
    end

    @testset "single-voxel tree" begin
        c = coord(0, 0, 0)
        tree = _make_single_voxel_tree(Float32, c, 42.0f0, 0.0f0)

        voxels = collect(active_voxels(tree))
        @test length(voxels) == 1
        @test voxels[1][1] == c
        @test voxels[1][2] == 42.0f0

        lvs = collect(leaves(tree))
        @test length(lvs) == 1
        @test lvs[1].origin == coord(0, 0, 0)
    end

    @testset "multi-voxel tree preserves all coords" begin
        # Place voxels at (0,0,0), (1,0,0), (0,1,0), (0,0,1)
        # Offsets: 0, 64, 8, 1
        origin = coord(0, 0, 0)
        vals = ntuple(i -> begin
            i == 1 ? 10.0f0 :  # offset 0: (0,0,0)
            i == 2 ? 20.0f0 :  # offset 1: (0,0,1)
            i == 9 ? 30.0f0 :  # offset 8: (0,1,0)
            i == 65 ? 40.0f0 : # offset 64: (1,0,0)
            0.0f0
        end, 512)
        tree = _make_single_leaf_tree(Float32, origin, [0, 1, 8, 64], vals, 0.0f0)

        voxels = collect(active_voxels(tree))
        @test length(voxels) == 4

        coords = Set(v[1] for v in voxels)
        @test coord(0,0,0) in coords
        @test coord(0,0,1) in coords
        @test coord(0,1,0) in coords
        @test coord(1,0,0) in coords

        values = Dict(v[1] => v[2] for v in voxels)
        @test values[coord(0,0,0)] == 10.0f0
        @test values[coord(0,0,1)] == 20.0f0
        @test values[coord(0,1,0)] == 30.0f0
        @test values[coord(1,0,0)] == 40.0f0
    end

    @testset "iterator protocol: IteratorSize and eltype" begin
        tree = RootNode{Float32}(0.0f0, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())

        @test Base.IteratorSize(typeof(active_voxels(tree))) == Base.SizeUnknown()
        @test eltype(typeof(active_voxels(tree))) == Tuple{Coord, Float32}

        @test Base.IteratorSize(typeof(leaves(tree))) == Base.SizeUnknown()
        @test eltype(typeof(leaves(tree))) == LeafNode{Float32}
    end

    @testset "iterator can be reused (non-destructive)" begin
        tree = _make_single_voxel_tree(Float32, coord(0,0,0), 1.0f0, 0.0f0)
        it = active_voxels(tree)

        pass1 = collect(it)
        pass2 = collect(it)
        @test length(pass1) == length(pass2) == 1
        @test pass1[1] == pass2[1]
    end

    @testset "leaves iterator on tree with all-inactive leaf" begin
        # Leaf exists but has no active voxels (all-zero mask)
        origin = coord(0, 0, 0)
        values = ntuple(_ -> 0.0f0, 512)
        tree = _make_single_leaf_tree(Float32, origin, Int[], values, 0.0f0)

        # Leaf still exists in tree structure
        lvs = collect(leaves(tree))
        @test length(lvs) == 1

        # But no active voxels
        voxels = collect(active_voxels(tree))
        @test isempty(voxels)
    end

    @testset "Float64 tree iterators" begin
        tree = _make_single_voxel_tree(Float64, coord(3, 5, 7), 99.0, 0.0)
        voxels = collect(active_voxels(tree))
        @test length(voxels) == 1
        @test voxels[1][1] == coord(3, 5, 7)
        @test voxels[1][2] == 99.0
    end
end

# ============================================================================
# 3. Gradient for Vec3f grids  (issue: path-tracer-ch41)
# ============================================================================

@testset "Gradient for Vec3f grids" begin
    # Helper: build a Vec3f tree with a 4x4x4 patch of known values
    function _make_vec3f_tree(values_fn)
        origin = coord(0, 0, 0)
        bg = (0.0f0, 0.0f0, 0.0f0)

        # Fill a 4x4x4 region in a leaf with values_fn(x, y, z)
        vals = ntuple(512) do i
            idx = i - 1
            z = idx & 7
            y = (idx >> 3) & 7
            x = (idx >> 6) & 7
            if x < 4 && y < 4 && z < 4
                values_fn(x, y, z)
            else
                bg
            end
        end

        # Mark the 4x4x4 region as active
        active_bits = Int[]
        for x in 0:3, y in 0:3, z in 0:3
            push!(active_bits, x * 64 + y * 8 + z)
        end

        _make_single_leaf_tree(NTuple{3, Float32}, origin, active_bits, vals, bg)
    end

    @testset "gradient returns NTuple{3, NTuple{3, Float32}}" begin
        tree = _make_vec3f_tree((x, y, z) -> (Float32(x), Float32(y), Float32(z)))
        grad = gradient(tree, coord(2, 2, 2))
        @test grad isa NTuple{3, NTuple{3, Float32}}
    end

    @testset "uniform Vec3f field has zero gradient" begin
        tree = _make_vec3f_tree((x, y, z) -> (1.0f0, 2.0f0, 3.0f0))
        grad = gradient(tree, coord(2, 2, 2))
        for axis in 1:3
            for comp in 1:3
                @test grad[axis][comp] ≈ 0.0f0 atol=1e-6
            end
        end
    end

    @testset "linear x-gradient for Vec3f" begin
        # v(x,y,z) = (x, 0, 0) → dv/dx = (1,0,0), dv/dy = (0,0,0), dv/dz = (0,0,0)
        tree = _make_vec3f_tree((x, y, z) -> (Float32(x), 0.0f0, 0.0f0))
        grad = gradient(tree, coord(2, 2, 2))
        # Central difference: (v(3)-v(1))/2 = (3-1)/2 = 1
        @test grad[1][1] ≈ 1.0f0 atol=1e-6  # dx component 1
        @test grad[1][2] ≈ 0.0f0 atol=1e-6  # dx component 2
        @test grad[1][3] ≈ 0.0f0 atol=1e-6  # dx component 3
        @test grad[2] == (0.0f0, 0.0f0, 0.0f0)  # dy
        @test grad[3] == (0.0f0, 0.0f0, 0.0f0)  # dz
    end

    @testset "each Vec3f component independent" begin
        # v(x,y,z) = (0, y, z)
        tree = _make_vec3f_tree((x, y, z) -> (0.0f0, Float32(y), Float32(z)))
        grad = gradient(tree, coord(2, 2, 2))

        # dx: all zero (no x dependence)
        @test all(c -> abs(c) < 1e-6, grad[1])

        # dy: (0, 1, 0) — component 2 varies linearly in y
        @test grad[2][2] ≈ 1.0f0 atol=1e-6

        # dz: (0, 0, 1) — component 3 varies linearly in z
        @test grad[3][3] ≈ 1.0f0 atol=1e-6
    end

    @testset "gradient at background boundary" begin
        # Query outside the active region — neighbors return background (0,0,0)
        tree = _make_vec3f_tree((x, y, z) -> (1.0f0, 1.0f0, 1.0f0))
        # Coord (0,0,0) has neighbor at (-1,0,0) which is background
        grad = gradient(tree, coord(0, 2, 2))
        # d/dx: (v(1,2,2) - v(-1,2,2))/2 = (1 - 0)/2 = 0.5 for each component
        @test grad[1][1] ≈ 0.5f0 atol=1e-6
        @test grad[1][2] ≈ 0.5f0 atol=1e-6
    end
end

# ============================================================================
# 4. sphere_trace surface hit  (issue: path-tracer-yynz)
# ============================================================================

@testset "sphere_trace surface hit" begin
    sphere_path = joinpath(@__DIR__, "fixtures", "samples", "sphere.vdb")
    if !isfile(sphere_path)
        @test_skip "fixture not found: $sphere_path"
        return
    end

    vdb = parse_vdb(sphere_path)
    grid = vdb.grids[1]
    vs = voxel_size(grid.transform)[1]

    @testset "sphere_trace hit from +X" begin
        ray = Ray(SVec3d(-50.0, 0.0, 0.0), SVec3d(1.0, 0.0, 0.0))
        result = sphere_trace(ray, grid, 100)
        @test result !== nothing
        if result !== nothing
            pos, normal = result
            @test pos isa NTuple{3, Float64}
            @test normal isa NTuple{3, Float64}
            @test pos[1] < 0.0  # hit near side
            @test normal[1] < -0.5  # normal points -X
        end
    end

    @testset "sphere_trace hit from -X" begin
        ray = Ray(SVec3d(50.0, 0.0, 0.0), SVec3d(-1.0, 0.0, 0.0))
        result = sphere_trace(ray, grid, 100)
        @test result !== nothing
        if result !== nothing
            pos, normal = result
            @test pos[1] > 0.0  # hit far side
            @test normal[1] > 0.5  # normal points +X
        end
    end

    @testset "sphere_trace hit from +Y" begin
        ray = Ray(SVec3d(0.0, -50.0, 0.0), SVec3d(0.0, 1.0, 0.0))
        result = sphere_trace(ray, grid, 100)
        @test result !== nothing
        if result !== nothing
            pos, normal = result
            @test pos[2] < 0.0
            @test normal[2] < -0.5
        end
    end

    @testset "sphere_trace hit from -Y" begin
        ray = Ray(SVec3d(0.0, 50.0, 0.0), SVec3d(0.0, -1.0, 0.0))
        result = sphere_trace(ray, grid, 100)
        @test result !== nothing
    end

    @testset "sphere_trace hit from +Z" begin
        ray = Ray(SVec3d(0.0, 0.0, -50.0), SVec3d(0.0, 0.0, 1.0))
        result = sphere_trace(ray, grid, 100)
        @test result !== nothing
        if result !== nothing
            pos, normal = result
            @test pos[3] < 0.0
            @test normal[3] < -0.5
        end
    end

    @testset "sphere_trace hit from -Z" begin
        ray = Ray(SVec3d(0.0, 0.0, 50.0), SVec3d(0.0, 0.0, -1.0))
        result = sphere_trace(ray, grid, 100)
        @test result !== nothing
    end

    @testset "sphere_trace diagonal hit" begin
        dir = SVec3d(1.0, 1.0, 1.0) / sqrt(3.0)
        ray = Ray(SVec3d(-50.0, -50.0, -50.0), dir)
        result = sphere_trace(ray, grid, 100)
        @test result !== nothing
        if result !== nothing
            pos, normal = result
            # Normal should point roughly opposite to ray direction
            dot = sum(normal[i] * dir[i] for i in 1:3)
            @test dot < 0.0  # anti-parallel
        end
    end

    @testset "sphere_trace normal is unit length" begin
        ray = Ray(SVec3d(-50.0, 0.0, 0.0), SVec3d(1.0, 0.0, 0.0))
        result = sphere_trace(ray, grid, 100)
        @test result !== nothing
        if result !== nothing
            _, normal = result
            len = sqrt(sum(n^2 for n in normal))
            @test len ≈ 1.0 atol=1e-4
        end
    end

    @testset "sphere_trace miss still returns nothing" begin
        ray = Ray(SVec3d(-50.0, 200.0, 0.0), SVec3d(1.0, 0.0, 0.0))
        @test sphere_trace(ray, grid, 100) === nothing
    end

    @testset "sphere_trace accepts world_bounds keyword" begin
        ray = Ray(SVec3d(-50.0, 0.0, 0.0), SVec3d(1.0, 0.0, 0.0))
        result1 = sphere_trace(ray, grid, 100)
        result2 = sphere_trace(ray, grid, 100; world_bounds=(-100.0, 100.0))
        @test result1 == result2
    end
end

# ============================================================================
# 5. Robustness: truncated and corrupted VDB files  (issue: path-tracer-htbz)
# ============================================================================

@testset "Robustness: truncated and corrupted VDB" begin
    @testset "empty byte vector" begin
        @test_throws Exception parse_vdb(UInt8[])
    end

    @testset "wrong magic bytes" begin
        buf = zeros(UInt8, 200)
        @test_throws InvalidMagicError parse_vdb(buf)
    end

    @testset "magic bytes off by one" begin
        # Correct magic is 0x56444220 = VDB_MAGIC
        bad = reinterpret(UInt8, [VDB_MAGIC + UInt32(1)])
        buf = vcat(collect(bad), zeros(UInt8, 200))
        @test_throws InvalidMagicError parse_vdb(buf)
    end

    @testset "correct magic but truncated immediately after" begin
        magic_bytes = collect(reinterpret(UInt8, [VDB_MAGIC]))
        @test_throws Exception parse_vdb(magic_bytes)
    end

    @testset "correct magic + padding but truncated before version" begin
        buf = collect(reinterpret(UInt8, [VDB_MAGIC, UInt32(0)]))
        @test_throws Exception parse_vdb(buf)
    end

    @testset "correct header prefix but truncated before UUID" begin
        # magic (4) + padding (4) + version (4) + lib_major (4) + lib_minor (4) + has_offsets (1) = 21 bytes
        buf = zeros(UInt8, 21)
        copyto!(buf, 1, collect(reinterpret(UInt8, [VDB_MAGIC])), 1, 4)
        # version = 222
        copyto!(buf, 9, collect(reinterpret(UInt8, [UInt32(222)])), 1, 4)
        # lib_major, lib_minor = 0
        buf[17] = 0x01  # has_grid_offsets = true
        @test_throws Exception parse_vdb(buf)
    end

    @testset "truncated real file at various fractions" begin
        sphere_path = joinpath(@__DIR__, "fixtures", "samples", "sphere.vdb")
        if !isfile(sphere_path)
            @test_skip "fixture not found: $sphere_path"
            return
        end

        full = read(sphere_path)

        @testset for frac in [0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.99]
            n = max(1, Int(floor(length(full) * frac)))
            truncated = full[1:n]
            @test_throws Exception parse_vdb(truncated)
        end
    end

    @testset "single byte" begin
        @test_throws Exception parse_vdb(UInt8[0x42])
    end

    @testset "valid header with zero grids parses successfully" begin
        # Build a minimal valid v222 file: magic + pad + version + lib_maj + lib_min + has_offsets + uuid + metadata_count + grid_count
        buf = UInt8[]

        # Magic (4 bytes) + padding (4 bytes)
        append!(buf, reinterpret(UInt8, [VDB_MAGIC]))
        append!(buf, reinterpret(UInt8, [UInt32(0)]))

        # Version = 222
        append!(buf, reinterpret(UInt8, [UInt32(222)]))

        # Library major, minor
        append!(buf, reinterpret(UInt8, [UInt32(10)]))
        append!(buf, reinterpret(UInt8, [UInt32(0)]))

        # has_grid_offsets (1 byte)
        push!(buf, 0x01)

        # UUID (36 bytes)
        uuid_str = "00000000-0000-0000-0000-000000000000"
        append!(buf, codeunits(uuid_str))

        # File metadata: count = 0 (4 bytes LE)
        append!(buf, reinterpret(UInt8, [UInt32(0)]))

        # Grid count = 0 (4 bytes LE)
        append!(buf, reinterpret(UInt8, [UInt32(0)]))

        vdb = parse_vdb(buf)
        @test vdb isa VDBFile
        @test isempty(vdb.grids)
        @test vdb.header.format_version == 222
    end
end
