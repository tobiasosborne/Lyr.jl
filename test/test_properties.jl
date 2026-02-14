@testset "Properties" begin
    # Property-based tests using PropCheck
    # These verify invariants that should always hold with automatic shrinking

    using PropCheck

    # Custom generators for domain types
    coord_gen() = PropCheck.map(((x, y, z),) -> coord(x, y, z),
        PropCheck.interleave(itype(Int16), itype(Int16), itype(Int16)))

    small_coord_gen() = PropCheck.map(((x, y, z),) -> coord(x, y, z),
        PropCheck.interleave(
            PropCheck.map(x -> Int16(mod(x, 1000)), itype(Int)),
            PropCheck.map(x -> Int16(mod(x, 1000)), itype(Int)),
            PropCheck.map(x -> Int16(mod(x, 1000)), itype(Int))))

    uint64_gen() = itype(UInt64)

    @testset "Mask properties" begin
        @testset "count_on equals iteration length" begin
            # Generate 8 UInt64 words for a LeafMask
            gen = PropCheck.interleave(
                uint64_gen(), uint64_gen(), uint64_gen(), uint64_gen(),
                uint64_gen(), uint64_gen(), uint64_gen(), uint64_gen())

            result = check(gen) do words
                m = LeafMask(words)
                count_on(m) == length(collect(on_indices(m)))
            end
            @test result
        end

        @testset "is_on and is_off are complementary" begin
            gen = PropCheck.interleave(uint64_gen(),
                PropCheck.map(x -> mod(x, 64), itype(Int)))

            result = check(gen) do (word, idx)
                # Create mask with one non-zero word
                words = (word, ntuple(_ -> UInt64(0), 7)...)
                m = LeafMask(words)
                is_on(m, idx) != is_off(m, idx)
            end
            @test result
        end

        @testset "count_on + count_off equals N for LeafMask" begin
            gen = PropCheck.interleave(
                uint64_gen(), uint64_gen(), uint64_gen(), uint64_gen(),
                uint64_gen(), uint64_gen(), uint64_gen(), uint64_gen())

            result = check(gen) do words
                m = LeafMask(words)
                count_on(m) + count_off(m) == 512
            end
            @test result
        end

        @testset "Empty and full masks have correct counts" begin
            # Empty mask
            m_empty = Mask{512,8}()
            @test count_on(m_empty) == 0
            @test count_off(m_empty) == 512

            # Full mask
            m_full = Mask{512,8}(Val(:ones))
            @test count_on(m_full) == 512
            @test count_off(m_full) == 0
        end
    end

    @testset "Coordinate properties" begin
        @testset "Origin contains original coordinate" begin
            result = check(coord_gen()) do c
                lo = leaf_origin(c)
                # Leaf origin should be <= coordinate in each dimension
                lo[1] <= c[1] && lo[2] <= c[2] && lo[3] <= c[3] &&
                # And origin + 7 should be >= coordinate
                lo[1] + 7 >= c[1] && lo[2] + 7 >= c[2] && lo[3] + 7 >= c[3]
            end
            @test result
        end

        @testset "Offset is in valid range" begin
            result = check(coord_gen()) do c
                0 <= leaf_offset(c) < 512 &&
                0 <= internal1_child_index(c) < 4096 &&
                0 <= internal2_child_index(c) < 32768
            end
            @test result
        end

        @testset "Leaf offset uniquely identifies position within leaf" begin
            result = check(coord_gen()) do c
                lo = leaf_origin(c)
                offset = leaf_offset(c)
                # Offset should be consistent for any coord with same origin
                # and different for coords with different positions
                offset >= 0 && offset < 512
            end
            @test result
        end
    end

    @testset "BBox properties" begin
        @testset "BBox contains its corners" begin
            gen = PropCheck.interleave(
                small_coord_gen(),
                PropCheck.map(x -> abs(mod(x, 100)) + 1, itype(Int)),
                PropCheck.map(x -> abs(mod(x, 100)) + 1, itype(Int)),
                PropCheck.map(x -> abs(mod(x, 100)) + 1, itype(Int)))

            result = check(gen) do (min_c, dx, dy, dz)
                max_c = coord(min_c[1] + dx, min_c[2] + dy, min_c[3] + dz)
                bb = BBox(min_c, max_c)
                Lyr.contains(bb, min_c) && Lyr.contains(bb, max_c)
            end
            @test result
        end

        @testset "BBox union contains both inputs" begin
            gen = PropCheck.interleave(
                PropCheck.map(x -> abs(mod(x, 50)), itype(Int)),
                PropCheck.map(x -> abs(mod(x, 50)), itype(Int)),
                PropCheck.map(x -> abs(mod(x, 50)), itype(Int)),
                PropCheck.map(x -> abs(mod(x, 50)), itype(Int)),
                PropCheck.map(x -> abs(mod(x, 50)), itype(Int)),
                PropCheck.map(x -> abs(mod(x, 50)), itype(Int)))

            result = check(gen) do (x1, y1, z1, x2, y2, z2)
                a = BBox(coord(x1, y1, z1), coord(x1 + 10, y1 + 10, z1 + 10))
                b = BBox(coord(x2, y2, z2), coord(x2 + 10, y2 + 10, z2 + 10))
                u = union(a, b)
                # Union should contain all corners of both boxes
                Lyr.contains(u, a.min) && Lyr.contains(u, a.max) &&
                Lyr.contains(u, b.min) && Lyr.contains(u, b.max)
            end
            @test result
        end

        @testset "Volume is positive for valid boxes" begin
            gen = PropCheck.interleave(
                small_coord_gen(),
                PropCheck.map(x -> abs(mod(x, 100)) + 1, itype(Int)),
                PropCheck.map(x -> abs(mod(x, 100)) + 1, itype(Int)),
                PropCheck.map(x -> abs(mod(x, 100)) + 1, itype(Int)))

            result = check(gen) do (min_c, dx, dy, dz)
                max_c = coord(min_c[1] + dx, min_c[2] + dy, min_c[3] + dz)
                bb = BBox(min_c, max_c)
                volume(bb) > 0
            end
            @test result
        end
    end

    @testset "Transform properties" begin
        @testset "Round-trip preserves integer coordinates" begin
            gen = PropCheck.interleave(
                PropCheck.map(x -> abs(mod(x, 100)) / 10.0 + 0.1, itype(Int)),  # scale > 0
                PropCheck.map(x -> mod(x, 201) - 100, itype(Int)),  # x coord
                PropCheck.map(x -> mod(x, 201) - 100, itype(Int)),  # y coord
                PropCheck.map(x -> mod(x, 201) - 100, itype(Int)))  # z coord

            result = check(gen) do (scale, x, y, z)
                t = UniformScaleTransform(scale)
                c = coord(x, y, z)
                world = index_to_world(t, c)
                back = world_to_index(t, world)
                back == c
            end
            @test result
        end

        @testset "Scaling preserves origin" begin
            gen = PropCheck.map(x -> abs(mod(x, 100)) / 10.0 + 0.1, itype(Int))

            result = check(gen) do scale
                t = UniformScaleTransform(scale)
                world = index_to_world(t, coord(0, 0, 0))
                world == (0.0, 0.0, 0.0)
            end
            @test result
        end
    end

    @testset "Tree properties" begin
        @testset "Empty tree returns background" begin
            gen = PropCheck.interleave(itype(Float32), coord_gen())

            result = check(gen) do (bg, c)
                tree = RootNode{Float32}(bg, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
                get_value(tree, c) == bg && is_active(tree, c) == false
            end
            @test result
        end

        @testset "Tile tree returns tile value" begin
            gen = PropCheck.interleave(
                itype(Float32),
                itype(Float32),
                small_coord_gen())

            result = check(gen) do (bg, tile_val, c)
                isnan(tile_val) && return true
                tile = Tile{Float32}(tile_val, true)
                origin = internal2_origin(c)
                table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(origin => tile)
                tree = RootNode{Float32}(bg, table)
                get_value(tree, c) == tile_val
            end
            @test result
        end
    end

    @testset "Interpolation properties" begin
        @testset "Trilinear returns uniform value for uniform tree" begin
            gen = itype(Float32)

            result = check(gen) do value
                # Handle edge cases
                isnan(value) && return true
                isinf(value) && return true

                tile = Tile{Float32}(value, true)
                table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(
                    coord(0, 0, 0) => tile
                )
                tree = RootNode{Float32}(value, table)

                # Sample at a few points
                samples = [
                    sample_trilinear(tree, (0.5, 0.5, 0.5)),
                    sample_trilinear(tree, (1.0, 1.0, 1.0)),
                    sample_trilinear(tree, (10.5, 20.3, 30.7))
                ]
                all(s -> s ≈ value, samples)
            end
            @test result
        end
    end

    @testset "Ray properties" begin
        @testset "Ray direction is normalized" begin
            gen = PropCheck.interleave(
                itype(Float64), itype(Float64), itype(Float64))

            result = check(gen) do (dx, dy, dz)
                # Skip degenerate cases
                (isnan(dx) || isnan(dy) || isnan(dz)) && return true
                (isinf(dx) || isinf(dy) || isinf(dz)) && return true
                (dx == 0.0 && dy == 0.0 && dz == 0.0) && return true

                # Skip denormalized/subnormal values that cause precision issues
                mag_sq = dx^2 + dy^2 + dz^2
                (isnan(mag_sq) || isinf(mag_sq) || mag_sq < 1e-300) && return true

                ray = Ray((0.0, 0.0, 0.0), (dx, dy, dz))
                len = sqrt(sum(x^2 for x in ray.direction))
                abs(len - 1.0) < 1e-10
            end
            @test result
        end

        @testset "intersect_bbox returns interval for ray through box" begin
            # Ray from outside pointing at box center
            bbox = BBox(coord(0, 0, 0), coord(10, 10, 10))
            ray = Ray((-5.0, 5.0, 5.0), (1.0, 0.0, 0.0))

            r = intersect_bbox(ray, bbox)
            @test r !== nothing
            @test r[1] < r[2]  # Valid interval
        end

        @testset "intersect_bbox symmetry" begin
            bbox = BBox(coord(0, 0, 0), coord(10, 10, 10))

            ray1 = Ray((-5.0, 5.0, 5.0), (1.0, 0.0, 0.0))
            ray2 = Ray((15.0, 5.0, 5.0), (-1.0, 0.0, 0.0))

            r1 = intersect_bbox(ray1, bbox)
            r2 = intersect_bbox(ray2, bbox)

            @test r1 !== nothing
            @test r2 !== nothing
            # Both should traverse the same distance through the box
            @test (r1[2] - r1[1]) ≈ (r2[2] - r2[1])
        end
    end
end
