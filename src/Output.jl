# Output.jl - Image output formats and tone mapping
#
# Supports EXR (via OpenEXR.jl), PNG (via PNGFiles.jl), and PPM.
# Tone mapping operators: Reinhard, ACES, exposure.

"""Find a loaded package by name, searching all loaded modules (not just Main)."""
function _find_loaded_module(name::Symbol)
    for (key, mod) in Base.loaded_modules
        if key.name == String(name)
            return mod
        end
    end
    return nothing
end

# ============================================================================
# Tone mapping operators
# ============================================================================

"""
    tonemap_reinhard(pixels::Matrix{NTuple{3, T}}) -> Matrix{NTuple{3, T}}

Reinhard tone mapping: `x / (1 + x)`. Maps HDR values to [0, 1].
"""
function tonemap_reinhard(pixels::Matrix{NTuple{3, T}}) where T <: AbstractFloat
    result = similar(pixels)
    for i in eachindex(pixels)
        r, g, b = pixels[i]
        result[i] = (r / (one(T) + r), g / (one(T) + g), b / (one(T) + b))
    end
    result
end

"""
    tonemap_aces(pixels::Matrix{NTuple{3, T}}) -> Matrix{NTuple{3, T}}

ACES filmic tone mapping curve (Krzysztof Narkowicz approximation).
`f(x) = (x*(2.51x + 0.03)) / (x*(2.43x + 0.59) + 0.14)`
"""
function tonemap_aces(pixels::Matrix{NTuple{3, T}}) where T <: AbstractFloat
    result = similar(pixels)
    for i in eachindex(pixels)
        r, g, b = pixels[i]
        result[i] = (_aces_channel(r), _aces_channel(g), _aces_channel(b))
    end
    result
end

function _aces_channel(x::T) where T <: AbstractFloat
    x = max(zero(T), x)
    clamp((x * (T(2.51) * x + T(0.03))) / (x * (T(2.43) * x + T(0.59)) + T(0.14)), zero(T), one(T))
end

"""
    tonemap_exposure(pixels::Matrix{NTuple{3, T}}, exposure) -> Matrix{NTuple{3, T}}

Exposure tone mapping: `1 - exp(-x * exposure)`.
"""
function tonemap_exposure(pixels::Matrix{NTuple{3, T}}, exposure::Real) where T <: AbstractFloat
    result = similar(pixels)
    e = T(exposure)
    for i in eachindex(pixels)
        r, g, b = pixels[i]
        result[i] = (one(T) - exp(-r * e),
                     one(T) - exp(-g * e),
                     one(T) - exp(-b * e))
    end
    result
end

"""
    auto_exposure(pixels::Matrix{NTuple{3, T}}) -> Float64

Estimate a good exposure value based on average luminance (log-average).
"""
function auto_exposure(pixels::Matrix{NTuple{3, T}})::Float64 where T <: AbstractFloat
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
# Denoising filters for Monte Carlo noise
# ============================================================================

"""
    denoise_nlm(pixels::Matrix{NTuple{3, T}};
                search_radius=7, patch_radius=3, h=T(0.1)) -> Matrix{NTuple{3, T}}

Non-local means denoiser. Compares patches across a search window and averages
pixels weighted by patch similarity. Excellent for Monte Carlo noise where
the noise is spatially uncorrelated.

- `search_radius`: half-size of the search window (default 7 → 15×15)
- `patch_radius`:  half-size of comparison patches (default 3 → 7×7)
- `h`:             filtering strength (larger = smoother)
"""
function denoise_nlm(pixels::Matrix{NTuple{3, T}};
                     search_radius::Int=7,
                     patch_radius::Int=3,
                     h::T=T(0.1)) where T <: AbstractFloat
    height, width = size(pixels)
    result = similar(pixels)
    inv_h2 = one(T) / (h * h)

    Threads.@threads for j in 1:width
      for i in 1:height
        sum_r = zero(T)
        sum_g = zero(T)
        sum_b = zero(T)
        sum_w = zero(T)

        # Search window bounds
        sj_lo = max(1, j - search_radius)
        sj_hi = min(width, j + search_radius)
        si_lo = max(1, i - search_radius)
        si_hi = min(height, i + search_radius)

        for sj in sj_lo:sj_hi, si in si_lo:si_hi
            # Compute L2 patch distance
            dist2 = zero(T)
            count = 0
            for dj in -patch_radius:patch_radius, di in -patch_radius:patch_radius
                pi = i + di; pj = j + dj
                qi = si + di; qj = sj + dj
                if 1 <= pi <= height && 1 <= pj <= width &&
                   1 <= qi <= height && 1 <= qj <= width
                    pr, pg, pb = pixels[pi, pj]
                    qr, qg, qb = pixels[qi, qj]
                    dr = pr - qr; dg = pg - qg; db = pb - qb
                    dist2 += dr*dr + dg*dg + db*db
                    count += 1
                end
            end
            # Normalize by patch area
            d2_norm = count > 0 ? dist2 / T(count) : zero(T)
            w = exp(-d2_norm * inv_h2)

            sr, sg, sb = pixels[si, sj]
            sum_r += w * sr
            sum_g += w * sg
            sum_b += w * sb
            sum_w += w
        end

        inv_w = one(T) / sum_w
        result[i, j] = (sum_r * inv_w, sum_g * inv_w, sum_b * inv_w)
      end
    end
    result
end

"""
    denoise_bilateral(pixels::Matrix{NTuple{3, T}};
                      spatial_sigma=T(2.0), range_sigma=T(0.1),
                      radius=0) -> Matrix{NTuple{3, T}}

Edge-stopping bilateral filter. Much faster than NLM (~400×) but less effective
on Monte Carlo noise. Preserves edges where color changes sharply.

- `spatial_sigma`: std-dev of the spatial Gaussian
- `range_sigma`:   std-dev of the color-difference Gaussian
- `radius`:        filter radius (0 = auto: `ceil(2 * spatial_sigma)`)
"""
function denoise_bilateral(pixels::Matrix{NTuple{3, T}};
                           spatial_sigma::T=T(2.0),
                           range_sigma::T=T(0.1),
                           radius::Int=0) where T <: AbstractFloat
    height, width = size(pixels)
    result = similar(pixels)

    r = radius > 0 ? radius : ceil(Int, T(2) * spatial_sigma)
    inv_spatial2 = one(T) / (T(2) * spatial_sigma * spatial_sigma)
    inv_range2 = one(T) / (T(2) * range_sigma * range_sigma)

    Threads.@threads for j in 1:width
      for i in 1:height
        cr, cg, cb = pixels[i, j]
        sum_r = zero(T)
        sum_g = zero(T)
        sum_b = zero(T)
        sum_w = zero(T)

        ni_lo = max(1, i - r)
        ni_hi = min(height, i + r)
        nj_lo = max(1, j - r)
        nj_hi = min(width, j + r)

        for nj in nj_lo:nj_hi, ni in ni_lo:ni_hi
            di = T(ni - i); dj = T(nj - j)
            spatial_w = exp(-(di*di + dj*dj) * inv_spatial2)

            nr, ng, nb = pixels[ni, nj]
            dr = nr - cr; dg = ng - cg; db = nb - cb
            range_w = exp(-(dr*dr + dg*dg + db*db) * inv_range2)

            w = spatial_w * range_w
            sum_r += w * nr
            sum_g += w * ng
            sum_b += w * nb
            sum_w += w
        end

        inv_w = one(T) / sum_w
        result[i, j] = (sum_r * inv_w, sum_g * inv_w, sum_b * inv_w)
      end
    end
    result
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
function write_exr(path::String, pixels::Matrix{NTuple{3, T}};
                   depth::Union{Matrix{<:AbstractFloat}, Nothing}=nothing) where T <: AbstractFloat
    height, width = size(pixels)

    # Try to use OpenEXR.jl
    exr_mod = _find_loaded_module(:OpenEXR)
    if exr_mod !== nothing
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

        exr_mod.save(path, channels)
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
function write_png(path::String, pixels::Matrix{NTuple{3, T}};
                   gamma::Float64=2.2) where T <: AbstractFloat
    height, width = size(pixels)
    inv_gamma = 1.0 / gamma

    png_mod = _find_loaded_module(:PNGFiles)
    if png_mod !== nothing
        # Convert to UInt8 RGB array (height × width × 3)
        img = Array{UInt8}(undef, height, width, 3)
        for j in 1:width, i in 1:height
            r, g, b = pixels[i,j]
            img[i,j,1] = round(UInt8, clamp(r^inv_gamma, 0.0, 1.0) * 255)
            img[i,j,2] = round(UInt8, clamp(g^inv_gamma, 0.0, 1.0) * 255)
            img[i,j,3] = round(UInt8, clamp(b^inv_gamma, 0.0, 1.0) * 255)
        end

        png_mod.save(path, img)
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
