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
    mat::NTuple{9, Float64}    # 3x3 rotation/scale matrix (row-major)
    trans::NTuple{3, Float64}  # translation
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
    # Subtract translation
    x = xyz[1] - t.trans[1]
    y = xyz[2] - t.trans[2]
    z = xyz[3] - t.trans[3]

    # Compute inverse transform (assuming orthogonal matrix for now)
    # For a general matrix, we'd need the actual inverse
    det = t.mat[1] * (t.mat[5] * t.mat[9] - t.mat[6] * t.mat[8]) -
          t.mat[2] * (t.mat[4] * t.mat[9] - t.mat[6] * t.mat[7]) +
          t.mat[3] * (t.mat[4] * t.mat[8] - t.mat[5] * t.mat[7])

    inv_det = 1.0 / det

    # Adjugate matrix elements
    a11 = (t.mat[5] * t.mat[9] - t.mat[6] * t.mat[8]) * inv_det
    a12 = (t.mat[3] * t.mat[8] - t.mat[2] * t.mat[9]) * inv_det
    a13 = (t.mat[2] * t.mat[6] - t.mat[3] * t.mat[5]) * inv_det
    a21 = (t.mat[6] * t.mat[7] - t.mat[4] * t.mat[9]) * inv_det
    a22 = (t.mat[1] * t.mat[9] - t.mat[3] * t.mat[7]) * inv_det
    a23 = (t.mat[3] * t.mat[4] - t.mat[1] * t.mat[6]) * inv_det
    a31 = (t.mat[4] * t.mat[8] - t.mat[5] * t.mat[7]) * inv_det
    a32 = (t.mat[2] * t.mat[7] - t.mat[1] * t.mat[8]) * inv_det
    a33 = (t.mat[1] * t.mat[5] - t.mat[2] * t.mat[4]) * inv_det

    i = a11 * x + a12 * y + a13 * z
    j = a21 * x + a22 * y + a23 * z
    k = a31 * x + a32 * y + a33 * z

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
        # General affine transform (AffineMap, etc.)
        # Read 4x4 matrix (row-major), extract 3x3 and translation
        mat_vals = Vector{Float64}(undef, 16)
        for i in 1:16
            mat_vals[i], pos = read_f64_le(bytes, pos)
        end

        # Skip extras (6 Float64s for voxel sizes) + 23 bytes
        for _ in 1:6
            _, pos = read_f64_le(bytes, pos)
        end
        pos += 23

        mat = (mat_vals[1], mat_vals[2], mat_vals[3],
               mat_vals[5], mat_vals[6], mat_vals[7],
               mat_vals[9], mat_vals[10], mat_vals[11])
        trans = (mat_vals[4], mat_vals[8], mat_vals[12])

        return (LinearTransform(mat, trans), pos)
    end
end
