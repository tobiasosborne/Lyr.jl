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
- `mat::NTuple{9, Float64}` - 3x3 matrix in row-major order
- `trans::NTuple{3, Float64}` - Translation vector
"""
struct LinearTransform <: AbstractTransform
    mat::NTuple{9, Float64}      # 3x3 rotation/scale matrix (row-major)
    trans::NTuple{3, Float64}    # translation
    inv_mat::NTuple{9, Float64}  # precomputed 3x3 inverse matrix (row-major)

    function LinearTransform(mat::NTuple{9, Float64}, trans::NTuple{3, Float64})
        inv_mat = _invert_3x3(mat)
        new(mat, trans, inv_mat)
    end
end

"""Compute the inverse of a 3x3 row-major matrix using Cramer's rule."""
function _invert_3x3(m::NTuple{9, Float64})::NTuple{9, Float64}
    det = m[1] * (m[5] * m[9] - m[6] * m[8]) -
          m[2] * (m[4] * m[9] - m[6] * m[7]) +
          m[3] * (m[4] * m[8] - m[5] * m[7])
    inv_det = 1.0 / det
    (
        (m[5] * m[9] - m[6] * m[8]) * inv_det,
        (m[3] * m[8] - m[2] * m[9]) * inv_det,
        (m[2] * m[6] - m[3] * m[5]) * inv_det,
        (m[6] * m[7] - m[4] * m[9]) * inv_det,
        (m[1] * m[9] - m[3] * m[7]) * inv_det,
        (m[3] * m[4] - m[1] * m[6]) * inv_det,
        (m[4] * m[8] - m[5] * m[7]) * inv_det,
        (m[2] * m[7] - m[1] * m[8]) * inv_det,
        (m[1] * m[5] - m[2] * m[4]) * inv_det,
    )
end

"""
    UniformScaleTransform <: AbstractTransform

A simple uniform scale transform (identity rotation, uniform voxel size).

# Fields
- `scale::Float64` - Uniform scale factor (voxel size)
"""
struct UniformScaleTransform <: AbstractTransform
    scale::Float64
end

"""
    index_to_world(t::LinearTransform, ijk::Coord) -> NTuple{3, Float64}

Transform index coordinates to world coordinates.
"""
function index_to_world(t::LinearTransform, ijk::Coord)::NTuple{3, Float64}
    i, j, k = Float64(ijk.x), Float64(ijk.y), Float64(ijk.z)

    x = t.mat[1] * i + t.mat[2] * j + t.mat[3] * k + t.trans[1]
    y = t.mat[4] * i + t.mat[5] * j + t.mat[6] * k + t.trans[2]
    z = t.mat[7] * i + t.mat[8] * j + t.mat[9] * k + t.trans[3]

    (x, y, z)
end

"""
    index_to_world(t::UniformScaleTransform, ijk::Coord) -> NTuple{3, Float64}

Transform index coordinates to world coordinates using uniform scale.
"""
function index_to_world(t::UniformScaleTransform, ijk::Coord)::NTuple{3, Float64}
    (Float64(ijk.x) * t.scale, Float64(ijk.y) * t.scale, Float64(ijk.z) * t.scale)
end

"""
    world_to_index_float(t::LinearTransform, xyz::NTuple{3, Float64}) -> NTuple{3, Float64}

Transform world coordinates to floating-point index coordinates.
"""
function world_to_index_float(t::LinearTransform, xyz::NTuple{3, Float64})::NTuple{3, Float64}
    x = xyz[1] - t.trans[1]
    y = xyz[2] - t.trans[2]
    z = xyz[3] - t.trans[3]

    m = t.inv_mat
    i = m[1] * x + m[2] * y + m[3] * z
    j = m[4] * x + m[5] * y + m[6] * z
    k = m[7] * x + m[8] * y + m[9] * z

    (i, j, k)
end

"""
    world_to_index_float(t::UniformScaleTransform, xyz::NTuple{3, Float64}) -> NTuple{3, Float64}

Transform world coordinates to floating-point index coordinates using uniform scale.
"""
function world_to_index_float(t::UniformScaleTransform, xyz::NTuple{3, Float64})::NTuple{3, Float64}
    inv_scale = 1.0 / t.scale
    (xyz[1] * inv_scale, xyz[2] * inv_scale, xyz[3] * inv_scale)
end

"""
    world_to_index(t::AbstractTransform, xyz::NTuple{3, Float64}) -> Coord

Transform world coordinates to integer index coordinates (rounded).
"""
function world_to_index(t::AbstractTransform, xyz::NTuple{3, Float64})::Coord
    ijk_float = world_to_index_float(t, xyz)
    coord(round(Int32, ijk_float[1]), round(Int32, ijk_float[2]), round(Int32, ijk_float[3]))
end

"""
    voxel_size(t::LinearTransform) -> NTuple{3, Float64}

Get the voxel size (diagonal of the transform matrix).
"""
function voxel_size(t::LinearTransform)::NTuple{3, Float64}
    # Voxel size is the length of each column of the matrix
    sx = sqrt(t.mat[1]^2 + t.mat[4]^2 + t.mat[7]^2)
    sy = sqrt(t.mat[2]^2 + t.mat[5]^2 + t.mat[8]^2)
    sz = sqrt(t.mat[3]^2 + t.mat[6]^2 + t.mat[9]^2)
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

        mat = (sx, 0.0, 0.0, 0.0, sy, 0.0, 0.0, 0.0, sz)
        return (LinearTransform(mat, (tx, ty, tz)), pos)

    elseif type_str == "ScaleMap"
        # ScaleMap: 5 Vec3d = 15 doubles = 120 bytes (same as UniformScaleMap)
        sx, pos = read_f64_le(bytes, pos)
        sy, pos = read_f64_le(bytes, pos)
        sz, pos = read_f64_le(bytes, pos)

        for _ in 1:12
            _, pos = read_f64_le(bytes, pos)
        end

        mat = (sx, 0.0, 0.0, 0.0, sy, 0.0, 0.0, 0.0, sz)
        return (LinearTransform(mat, (0.0, 0.0, 0.0)), pos)

    else
        throw(ArgumentError("read_transform: unsupported map type '$type_str' — only UniformScaleMap, UniformScaleTranslateMap, ScaleTranslateMap, and ScaleMap are supported"))
    end
end
