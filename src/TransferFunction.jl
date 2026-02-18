# TransferFunction.jl - Transfer functions mapping density to RGBA color

"""
    ControlPoint

Control point mapping a density value to an RGBA color.

# Fields
- `density::Float64` - Density value at this control point
- `color::NTuple{4, Float64}` - (R, G, B, A) color, each channel in [0, 1]
"""
struct ControlPoint
    density::Float64
    color::NTuple{4, Float64}  # (R, G, B, A)
end

"""
    TransferFunction

Piecewise-linear transfer function with sorted control points.

Maps scalar density values to RGBA colors via linear interpolation between
adjacent control points. Points are kept sorted by density.

# Fields
- `points::Vector{ControlPoint}` - Control points sorted by ascending density
"""
struct TransferFunction
    points::Vector{ControlPoint}

    function TransferFunction(points::Vector{ControlPoint})
        isempty(points) && throw(ArgumentError("TransferFunction requires at least one control point"))
        sorted = sort(points; by=p -> p.density)
        new(sorted)
    end
end

"""
    evaluate(tf::TransferFunction, density::Float64) -> NTuple{4, Float64}

Evaluate the transfer function at a given density value.

Uses piecewise linear interpolation between control points. Values below the
first control point return the first color; values above the last return the
last color.
"""
function evaluate(tf::TransferFunction, density::Float64)::NTuple{4, Float64}
    pts = tf.points
    n = length(pts)

    # Below first point: clamp to first color
    density <= pts[1].density && return pts[1].color

    # Above last point: clamp to last color
    density >= pts[n].density && return pts[n].color

    # Binary search for the enclosing interval
    lo = 1
    hi = n
    while hi - lo > 1
        mid = (lo + hi) >> 1
        if pts[mid].density <= density
            lo = mid
        else
            hi = mid
        end
    end

    # Linear interpolation between pts[lo] and pts[hi]
    d0 = pts[lo].density
    d1 = pts[hi].density
    t = (density - d0) / (d1 - d0)

    c0 = pts[lo].color
    c1 = pts[hi].color

    (c0[1] + t * (c1[1] - c0[1]),
     c0[2] + t * (c1[2] - c0[2]),
     c0[3] + t * (c1[3] - c0[3]),
     c0[4] + t * (c1[4] - c0[4]))
end

# ============================================================================
# Preset transfer functions
# ============================================================================

"""
    tf_blackbody() -> TransferFunction

Blackbody / fire transfer function: black -> red -> orange -> yellow -> white.

Suitable for rendering fire, explosions, and hot gas simulations.
"""
function tf_blackbody()::TransferFunction
    TransferFunction([
        ControlPoint(0.0, (0.0, 0.0, 0.0, 0.0)),
        ControlPoint(0.2, (0.5, 0.0, 0.0, 0.3)),
        ControlPoint(0.4, (0.9, 0.2, 0.0, 0.6)),
        ControlPoint(0.6, (1.0, 0.6, 0.0, 0.8)),
        ControlPoint(0.8, (1.0, 0.9, 0.4, 0.9)),
        ControlPoint(1.0, (1.0, 1.0, 1.0, 1.0)),
    ])
end

"""
    tf_cool_warm() -> TransferFunction

Diverging cool-warm transfer function: blue -> white -> red.

Suitable for scientific visualization of signed data (e.g., temperature
anomalies, pressure differences).
"""
function tf_cool_warm()::TransferFunction
    TransferFunction([
        ControlPoint(0.0, (0.2, 0.2, 0.8, 1.0)),
        ControlPoint(0.5, (1.0, 1.0, 1.0, 1.0)),
        ControlPoint(1.0, (0.8, 0.2, 0.2, 1.0)),
    ])
end

"""
    tf_smoke() -> TransferFunction

Smoke / gray absorption transfer function: transparent -> gray -> black.

Suitable for rendering smoke, dust, and absorbing media where density
increases opacity and darkens color.
"""
function tf_smoke()::TransferFunction
    TransferFunction([
        ControlPoint(0.0, (0.9, 0.9, 0.9, 0.0)),
        ControlPoint(0.3, (0.6, 0.6, 0.6, 0.3)),
        ControlPoint(0.7, (0.3, 0.3, 0.3, 0.7)),
        ControlPoint(1.0, (0.0, 0.0, 0.0, 1.0)),
    ])
end

"""
    tf_viridis() -> TransferFunction

Viridis-inspired perceptually uniform transfer function:
dark purple -> blue -> green -> yellow.

Suitable for general-purpose scientific visualization with good perceptual
uniformity and colorblind accessibility.
"""
function tf_viridis()::TransferFunction
    TransferFunction([
        ControlPoint(0.0, (0.267, 0.004, 0.329, 0.0)),
        ControlPoint(0.25, (0.282, 0.141, 0.458, 0.4)),
        ControlPoint(0.5, (0.127, 0.566, 0.551, 0.7)),
        ControlPoint(0.75, (0.544, 0.773, 0.247, 0.9)),
        ControlPoint(1.0, (0.993, 0.906, 0.144, 1.0)),
    ])
end
