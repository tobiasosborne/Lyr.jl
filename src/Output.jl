# Output.jl - Image output formats and tone mapping
#
# Supports EXR (via OpenEXR.jl), PNG (via PNGFiles.jl), and PPM.
# Tone mapping operators: Reinhard, ACES, exposure.

# ============================================================================
# Tone mapping operators
# ============================================================================

"""
    tonemap_reinhard(pixels::Matrix{NTuple{3, Float64}}) -> Matrix{NTuple{3, Float64}}

Reinhard tone mapping: `x / (1 + x)`. Maps HDR values to [0, 1].
"""
function tonemap_reinhard(pixels::Matrix{NTuple{3, Float64}})
    result = similar(pixels)
    for i in eachindex(pixels)
        r, g, b = pixels[i]
        result[i] = (r / (1.0 + r), g / (1.0 + g), b / (1.0 + b))
    end
    result
end

"""
    tonemap_aces(pixels::Matrix{NTuple{3, Float64}}) -> Matrix{NTuple{3, Float64}}

ACES filmic tone mapping curve (Krzysztof Narkowicz approximation).
`f(x) = (x*(2.51x + 0.03)) / (x*(2.43x + 0.59) + 0.14)`
"""
function tonemap_aces(pixels::Matrix{NTuple{3, Float64}})
    result = similar(pixels)
    for i in eachindex(pixels)
        r, g, b = pixels[i]
        result[i] = (_aces_channel(r), _aces_channel(g), _aces_channel(b))
    end
    result
end

function _aces_channel(x::Float64)::Float64
    x = max(0.0, x)
    clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0)
end

"""
    tonemap_exposure(pixels::Matrix{NTuple{3, Float64}}, exposure::Float64) -> Matrix{NTuple{3, Float64}}

Exposure tone mapping: `1 - exp(-x * exposure)`.
"""
function tonemap_exposure(pixels::Matrix{NTuple{3, Float64}}, exposure::Float64)
    result = similar(pixels)
    for i in eachindex(pixels)
        r, g, b = pixels[i]
        result[i] = (1.0 - exp(-r * exposure),
                     1.0 - exp(-g * exposure),
                     1.0 - exp(-b * exposure))
    end
    result
end

"""
    auto_exposure(pixels::Matrix{NTuple{3, Float64}}) -> Float64

Estimate a good exposure value based on average luminance (log-average).
"""
function auto_exposure(pixels::Matrix{NTuple{3, Float64}})::Float64
    log_sum = 0.0
    count = 0
    eps = 1e-6
    for i in eachindex(pixels)
        r, g, b = pixels[i]
        luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if luminance > eps
            log_sum += log(luminance + eps)
            count += 1
        end
    end
    count == 0 && return 1.0
    avg_luminance = exp(log_sum / count)
    # Target middle gray (0.18) mapping
    0.18 / max(avg_luminance, eps)
end

# ============================================================================
# EXR output (optional — requires OpenEXR.jl)
# ============================================================================

"""
    write_exr(path::String, pixels::Matrix{NTuple{3, Float64}};
              depth::Union{Matrix{Float64}, Nothing}=nothing)

Write an HDR image to OpenEXR format. Requires OpenEXR.jl to be loaded.
Falls back to PPM if OpenEXR is not available.

Linear light values are preserved (no gamma applied).
"""
function write_exr(path::String, pixels::Matrix{NTuple{3, Float64}};
                   depth::Union{Matrix{Float64}, Nothing}=nothing)
    height, width = size(pixels)

    # Try to use OpenEXR.jl
    if isdefined(Main, :OpenEXR)
        # Convert to Float32 arrays
        r = Matrix{Float32}(undef, height, width)
        g = Matrix{Float32}(undef, height, width)
        b = Matrix{Float32}(undef, height, width)
        for j in 1:width, i in 1:height
            r[i,j] = Float32(pixels[i,j][1])
            g[i,j] = Float32(pixels[i,j][2])
            b[i,j] = Float32(pixels[i,j][3])
        end

        channels = Dict("R" => r, "G" => g, "B" => b)
        if depth !== nothing
            channels["Z"] = Matrix{Float32}(depth)
        end

        Main.OpenEXR.save(path, channels)
    else
        # Fallback: write as PPM with a warning
        @warn "OpenEXR.jl not loaded, falling back to PPM. Add `using OpenEXR` for EXR output."
        write_ppm(replace(path, ".exr" => ".ppm"), pixels)
    end
end

# ============================================================================
# PNG output (optional — requires PNGFiles.jl)
# ============================================================================

"""
    write_png(path::String, pixels::Matrix{NTuple{3, Float64}};
              gamma::Float64=2.2)

Write an 8-bit sRGB PNG image. Requires PNGFiles.jl to be loaded.
Applies gamma correction before quantization.
"""
function write_png(path::String, pixels::Matrix{NTuple{3, Float64}};
                   gamma::Float64=2.2)
    height, width = size(pixels)
    inv_gamma = 1.0 / gamma

    if isdefined(Main, :PNGFiles)
        # Convert to UInt8 RGB array (height × width × 3)
        img = Array{UInt8}(undef, height, width, 3)
        for j in 1:width, i in 1:height
            r, g, b = pixels[i,j]
            img[i,j,1] = round(UInt8, clamp(r^inv_gamma, 0.0, 1.0) * 255)
            img[i,j,2] = round(UInt8, clamp(g^inv_gamma, 0.0, 1.0) * 255)
            img[i,j,3] = round(UInt8, clamp(b^inv_gamma, 0.0, 1.0) * 255)
        end

        Main.PNGFiles.save(path, img)
    else
        # Fallback: apply gamma and write as PPM
        @warn "PNGFiles.jl not loaded, falling back to PPM. Add `using PNGFiles` for PNG output."
        gamma_pixels = similar(pixels)
        for i in eachindex(pixels)
            r, g, b = pixels[i]
            gamma_pixels[i] = (clamp(r, 0.0, 1.0)^inv_gamma,
                               clamp(g, 0.0, 1.0)^inv_gamma,
                               clamp(b, 0.0, 1.0)^inv_gamma)
        end
        write_ppm(replace(path, ".png" => ".ppm"), gamma_pixels)
    end
end
