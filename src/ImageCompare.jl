# ImageCompare.jl — PPM reader and image comparison metrics
#
# Provides read_ppm for round-tripping PPM files, plus RMSE, PSNR, SSIM,
# and max-diff for golden image regression testing.

"""
    read_ppm(path::String) -> Matrix{NTuple{3, Float64}}

Read an ASCII P3 PPM file (as written by `write_ppm`).
Returns a `height × width` matrix of `(R, G, B)` tuples with channels in [0, 1].
"""
function read_ppm(path::String)::Matrix{NTuple{3, Float64}}
    lines = readlines(path)
    idx = 1

    # Skip comments, find magic
    while idx <= length(lines) && (isempty(strip(lines[idx])) || startswith(strip(lines[idx]), "#"))
        idx += 1
    end
    magic = strip(lines[idx])
    magic == "P3" || throw(ArgumentError("Expected P3 PPM, got: $magic"))
    idx += 1

    # Skip comments, find dimensions
    while idx <= length(lines) && (isempty(strip(lines[idx])) || startswith(strip(lines[idx]), "#"))
        idx += 1
    end
    dims = split(strip(lines[idx]))
    width = parse(Int, dims[1])
    height = parse(Int, dims[2])
    idx += 1

    # Skip comments, find maxval
    while idx <= length(lines) && (isempty(strip(lines[idx])) || startswith(strip(lines[idx]), "#"))
        idx += 1
    end
    maxval = parse(Float64, strip(lines[idx]))
    idx += 1

    # Collect all remaining tokens
    tokens = String[]
    while idx <= length(lines)
        line = strip(lines[idx])
        if !isempty(line) && !startswith(line, "#")
            append!(tokens, split(line))
        end
        idx += 1
    end

    expected = width * height * 3
    length(tokens) >= expected || throw(ArgumentError(
        "PPM has $(length(tokens)) color values, expected $expected"))

    inv_maxval = 1.0 / maxval
    pixels = Matrix{NTuple{3, Float64}}(undef, height, width)
    ti = 1
    for y in 1:height
        for x in 1:width
            r = parse(Int, tokens[ti]) * inv_maxval
            g = parse(Int, tokens[ti + 1]) * inv_maxval
            b = parse(Int, tokens[ti + 2]) * inv_maxval
            pixels[y, x] = (r, g, b)
            ti += 3
        end
    end

    pixels
end

"""
    image_rmse(a, b) -> Float64

Root mean square error across all channels:
`sqrt(sum((ra-rb)² + (ga-gb)² + (ba-bb)²) / (3 * num_pixels))`
"""
function image_rmse(a::Matrix{NTuple{3, Float64}}, b::Matrix{NTuple{3, Float64}})::Float64
    size(a) == size(b) || throw(DimensionMismatch("Image sizes differ: $(size(a)) vs $(size(b))"))
    n = length(a)
    n == 0 && return 0.0
    sum_sq = 0.0
    for i in eachindex(a)
        ra, ga, ba = a[i]
        rb, gb, bb = b[i]
        sum_sq += (ra - rb)^2 + (ga - gb)^2 + (ba - bb)^2
    end
    sqrt(sum_sq / (3.0 * n))
end

"""
    image_psnr(a, b) -> Float64

Peak signal-to-noise ratio: `20 * log10(1.0 / rmse)`. Returns `Inf` for identical images.
"""
function image_psnr(a::Matrix{NTuple{3, Float64}}, b::Matrix{NTuple{3, Float64}})::Float64
    rmse = image_rmse(a, b)
    rmse == 0.0 && return Inf
    20.0 * log10(1.0 / rmse)
end

"""
    image_ssim(a, b) -> Float64

Simplified global SSIM on luminance (L = 0.2126R + 0.7152G + 0.0722B).
Returns 1.0 for identical images, lower for different images.
"""
function image_ssim(a::Matrix{NTuple{3, Float64}}, b::Matrix{NTuple{3, Float64}})::Float64
    size(a) == size(b) || throw(DimensionMismatch("Image sizes differ: $(size(a)) vs $(size(b))"))
    n = length(a)
    n == 0 && return 1.0

    # Compute luminance arrays
    sum_a = 0.0
    sum_b = 0.0
    sum_a2 = 0.0
    sum_b2 = 0.0
    sum_ab = 0.0

    for i in eachindex(a)
        ra, ga, ba = a[i]
        rb, gb, bb = b[i]
        la = 0.2126 * ra + 0.7152 * ga + 0.0722 * ba
        lb = 0.2126 * rb + 0.7152 * gb + 0.0722 * bb
        sum_a += la
        sum_b += lb
        sum_a2 += la * la
        sum_b2 += lb * lb
        sum_ab += la * lb
    end

    mu_a = sum_a / n
    mu_b = sum_b / n
    var_a = sum_a2 / n - mu_a * mu_a
    var_b = sum_b2 / n - mu_b * mu_b
    cov_ab = sum_ab / n - mu_a * mu_b

    c1 = 0.01^2
    c2 = 0.03^2

    (2.0 * mu_a * mu_b + c1) * (2.0 * cov_ab + c2) /
        ((mu_a^2 + mu_b^2 + c1) * (var_a + var_b + c2))
end

"""
    image_max_diff(a, b) -> Float64

Maximum absolute per-channel difference across all pixels.
"""
function image_max_diff(a::Matrix{NTuple{3, Float64}}, b::Matrix{NTuple{3, Float64}})::Float64
    size(a) == size(b) || throw(DimensionMismatch("Image sizes differ: $(size(a)) vs $(size(b))"))
    n = length(a)
    n == 0 && return 0.0
    maxd = 0.0
    for i in eachindex(a)
        ra, ga, ba = a[i]
        rb, gb, bb = b[i]
        maxd = max(maxd, abs(ra - rb), abs(ga - gb), abs(ba - bb))
    end
    maxd
end

"""
    save_reference_render(pixels, path)

Write a reference render PPM, creating parent directories as needed.
"""
function save_reference_render(pixels::Matrix{NTuple{3, T}}, path::String) where T <: AbstractFloat
    mkpath(dirname(path))
    write_ppm(path, pixels)
end

"""
    load_reference_render(path) -> Matrix{NTuple{3, Float64}}

Load a reference render PPM. Thin wrapper around `read_ppm`.
"""
function load_reference_render(path::String)::Matrix{NTuple{3, Float64}}
    read_ppm(path)
end

"""
    read_float32_image(path) -> Matrix{NTuple{3, Float64}}

Read a raw float32 image written by Mitsuba reference scripts.
Format: 12-byte header (H, W, C as UInt32 LE) followed by H×W×C Float32 values
in row-major order (C-contiguous: [y, x, channel]).
"""
function read_float32_image(path::String)::Matrix{NTuple{3, Float64}}
    data = read(path)
    length(data) >= 12 || throw(ArgumentError("File too small for header: $(length(data)) bytes"))
    h = reinterpret(UInt32, data[1:4])[1]
    w = reinterpret(UInt32, data[5:8])[1]
    c = reinterpret(UInt32, data[9:12])[1]
    c == 3 || throw(ArgumentError("Expected 3 channels, got $c"))
    expected = 12 + h * w * 3 * 4
    length(data) == expected || throw(ArgumentError(
        "Expected $expected bytes, got $(length(data))"))
    floats = reinterpret(Float32, @view data[13:end])
    pixels = Matrix{NTuple{3, Float64}}(undef, Int(h), Int(w))
    idx = 1
    for y in 1:Int(h), x in 1:Int(w)
        pixels[y, x] = (Float64(floats[idx]), Float64(floats[idx+1]), Float64(floats[idx+2]))
        idx += 3
    end
    pixels
end
