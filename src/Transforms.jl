# Transforms.jl - Coordinate transforms between index and world space

"""
    AbstractTransform

Abstract type for coordinate transforms.
"""
abstract type AbstractTransform end

"""
    LinearTransform <: AbstractTransform

A general linear transform with rotation/scale and translation.

# Fields
- `mat::SMat3d` - 3x3 matrix (column-major, standard Julia convention)
- `trans::SVec3d` - Translation vector
- `inv_mat::SMat3d` - Precomputed inverse of `mat`
"""
struct LinearTransform <: AbstractTransform
    mat::SMat3d       # 3x3 rotation/scale matrix
    trans::SVec3d     # translation
    inv_mat::SMat3d   # precomputed inverse

    function LinearTransform(mat::SMat3d, trans::SVec3d)
        new(mat, trans, inv(mat))
    end
end

# Convenience: construct from NTuples (column-major element order, matching SMatrix)
LinearTransform(mat::NTuple{9,Float64}, trans::NTuple{3,Float64}) =
    LinearTransform(SMat3d(mat...), SVec3d(trans...))

"""
    UniformScaleTransform <: AbstractTransform

A simple uniform scale transform (identity rotation, uniform voxel size).

# Fields
- `scale::Float64` - Uniform scale factor (voxel size)
"""
struct UniformScaleTransform <: AbstractTransform
    scale::Float64
end

# --- SVec3d primary methods (zero-copy, no tuple conversion) ---

"""
    index_to_world(t::LinearTransform, v::SVec3d) -> SVec3d

Transform index coordinates to world coordinates.
"""
index_to_world(t::LinearTransform, v::SVec3d)::SVec3d = t.mat * v + t.trans

"""
    index_to_world(t::UniformScaleTransform, v::SVec3d) -> SVec3d

Transform index coordinates to world coordinates using uniform scale.
"""
index_to_world(t::UniformScaleTransform, v::SVec3d)::SVec3d = v * t.scale

"""
    world_to_index_float(t::LinearTransform, xyz::SVec3d) -> SVec3d

Transform world coordinates to floating-point index coordinates.
"""
world_to_index_float(t::LinearTransform, xyz::SVec3d)::SVec3d = t.inv_mat * (xyz - t.trans)

"""
    world_to_index_float(t::UniformScaleTransform, xyz::SVec3d) -> SVec3d

Transform world coordinates to floating-point index coordinates using uniform scale.
"""
world_to_index_float(t::UniformScaleTransform, xyz::SVec3d)::SVec3d = xyz * (1.0 / t.scale)

"""
    world_to_index(t::AbstractTransform, xyz::SVec3d) -> Coord

Transform world coordinates to integer index coordinates (rounded).
"""
function world_to_index(t::AbstractTransform, xyz::SVec3d)::Coord
    v = world_to_index_float(t, xyz)
    coord(round(Int32, v[1]), round(Int32, v[2]), round(Int32, v[3]))
end

# --- NTuple/Coord wrappers (dispatch through AbstractTransform → concrete SVec3d method) ---

index_to_world(t::AbstractTransform, ijk::Coord)::NTuple{3, Float64} =
    Tuple(index_to_world(t, SVec3d(Float64(ijk.x), Float64(ijk.y), Float64(ijk.z))))

world_to_index_float(t::AbstractTransform, xyz::NTuple{3, Float64})::NTuple{3, Float64} =
    Tuple(world_to_index_float(t, SVec3d(xyz...)))

world_to_index(t::AbstractTransform, xyz::NTuple{3, Float64})::Coord =
    world_to_index(t, SVec3d(xyz...))

"""
    voxel_size(t::LinearTransform) -> NTuple{3, Float64}

Get the voxel size (column norms of the transform matrix).
"""
function voxel_size(t::LinearTransform)::NTuple{3, Float64}
    m = t.mat
    sx = sqrt(m[1,1]^2 + m[2,1]^2 + m[3,1]^2)
    sy = sqrt(m[1,2]^2 + m[2,2]^2 + m[3,2]^2)
    sz = sqrt(m[1,3]^2 + m[2,3]^2 + m[3,3]^2)
    (sx, sy, sz)
end

"""
    voxel_size(t::UniformScaleTransform) -> NTuple{3, Float64}

Get the voxel size for uniform scale transform.
"""
function voxel_size(t::UniformScaleTransform)::NTuple{3, Float64}
    (t.scale, t.scale, t.scale)
end

"""
    read_transform(bytes::Vector{UInt8}, pos::Int) -> Tuple{AbstractTransform, Int}

Parse a transform from bytes.

OpenVDB MapBase format stores the full affine map data:
- Translation (3 Float64)
- Scale/voxel sizes (3 Float64, repeated several times)
- Additional inverse data

For UniformScaleTranslateMap: 18 Float64 values + 23 bytes of flags/padding.
"""
function read_transform(bytes::Vector{UInt8}, pos::Int)::Tuple{AbstractTransform, Int}
    # Read transform type string
    type_str, pos = read_string_with_size(bytes, pos)

    if type_str == "UniformScaleMap"
        # UniformScaleMap format:
        # - 6 scale values (3 for scale, 3 for voxel size)
        # - 3 inverse scales
        # - 3 inverse squared scales
        # - 3 voxel sizes
        # Total: 15 Float64 values + 4 bytes flags

        scale_x, pos = read_f64_le(bytes, pos)
        _, pos = read_f64_le(bytes, pos)  # scale_y (same)
        _, pos = read_f64_le(bytes, pos)  # scale_z (same)

        # Skip remaining 12 Float64 values
        for _ in 1:12
            _, pos = read_f64_le(bytes, pos)
        end

        return (UniformScaleTransform(scale_x), pos)

    elseif type_str == "UniformScaleTranslateMap" || type_str == "ScaleTranslateMap"
        # UniformScaleTranslateMap format (18 Float64 values):
        # - Translation (3 Float64)
        # - Scale (3 Float64) - repeated
        # - Inverse scale (3 Float64)
        # - Inverse squared scale (3 Float64)
        # - Voxel size (3 Float64)
        # Total: 18 Float64 values + 23 bytes padding/flags

        # Read translation
        tx, pos = read_f64_le(bytes, pos)
        ty, pos = read_f64_le(bytes, pos)
        tz, pos = read_f64_le(bytes, pos)

        # Read scale (first occurrence)
        sx, pos = read_f64_le(bytes, pos)
        sy, pos = read_f64_le(bytes, pos)
        sz, pos = read_f64_le(bytes, pos)

        # Skip remaining 12 Float64 values
        for _ in 1:12
            _, pos = read_f64_le(bytes, pos)
        end

        mat = SMat3d(sx, 0.0, 0.0, 0.0, sy, 0.0, 0.0, 0.0, sz)
        return (LinearTransform(mat, SVec3d(tx, ty, tz)), pos)

    elseif type_str == "ScaleMap"
        # ScaleMap: 5 Vec3d = 15 doubles = 120 bytes (same as UniformScaleMap)
        sx, pos = read_f64_le(bytes, pos)
        sy, pos = read_f64_le(bytes, pos)
        sz, pos = read_f64_le(bytes, pos)

        for _ in 1:12
            _, pos = read_f64_le(bytes, pos)
        end

        mat = SMat3d(sx, 0.0, 0.0, 0.0, sy, 0.0, 0.0, 0.0, sz)
        return (LinearTransform(mat, SVec3d(0.0, 0.0, 0.0)), pos)

    else
        throw(ArgumentError("read_transform: unsupported map type '$type_str' — only UniformScaleMap, UniformScaleTranslateMap, ScaleTranslateMap, and ScaleMap are supported"))
    end
end
