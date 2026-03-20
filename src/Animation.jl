# Animation.jl — Time-evolving field animation rendering pipeline
#
# Renders TimeEvolution fields frame-by-frame, combining voxelization,
# volume rendering, and MP4 stitching into a single pipeline.
# No new rendering logic — uses render_volume_image, Scene, VolumeEntry.

# ============================================================================
# Camera Modes
# ============================================================================

"""
    CameraMode

Abstract type for animation camera behaviors.
See: [`FixedCamera`](@ref), [`OrbitCamera`](@ref), [`FollowCamera`](@ref).
"""
abstract type CameraMode end

"""
    FixedCamera(position, target; up=(0,1,0), fov=40.0)

Static camera that does not move between frames.
"""
struct FixedCamera <: CameraMode
    position::NTuple{3,Float64}
    target::NTuple{3,Float64}
    up::NTuple{3,Float64}
    fov::Float64
end

FixedCamera(position::NTuple{3,Float64}, target::NTuple{3,Float64};
            up::NTuple{3,Float64}=(0.0, 1.0, 0.0), fov::Float64=40.0) =
    FixedCamera(position, target, up, fov)

"""
    OrbitCamera(center, distance; elevation=30.0, fov=40.0, revolutions=1.0)

Camera that orbits around `center` over the animation duration.
Completes `revolutions` full rotations (default: 1 full revolution).
"""
struct OrbitCamera <: CameraMode
    center::NTuple{3,Float64}
    distance::Float64
    elevation::Float64
    fov::Float64
    revolutions::Float64
end

OrbitCamera(center::NTuple{3,Float64}, distance::Float64;
            elevation::Float64=30.0, fov::Float64=40.0,
            revolutions::Float64=1.0) =
    OrbitCamera(center, distance, elevation, fov, revolutions)

"""
    FollowCamera(center_fn, distance; elevation=30.0, fov=40.0)

Camera that tracks a moving target. `center_fn(t) → NTuple{3,Float64}` returns
the look-at point at time `t`.
"""
struct FollowCamera{F} <: CameraMode
    center_fn::F
    distance::Float64
    elevation::Float64
    fov::Float64
end

FollowCamera(center_fn, distance::Float64;
             elevation::Float64=30.0, fov::Float64=40.0) =
    FollowCamera(center_fn, distance, elevation, fov)

"""
    FunctionCamera(camera_fn)

Fully custom camera via a function `camera_fn(t::Float64) → Camera`.
Use this when none of the built-in modes fit (e.g., camera pinned on a
moving object while looking at another).

# Example
```julia
cam = FunctionCamera(t -> Camera((0.0, 5.0, t), (0.0, 0.0, -t), (0.0, 1.0, 0.0), 40.0))
```
"""
struct FunctionCamera{F} <: CameraMode
    camera_fn::F
end

"""
    camera_at_frame(mode, frame, nframes, t) → Camera

Resolve the camera for a specific animation frame.
"""
function camera_at_frame(mode::FixedCamera, frame::Int, nframes::Int, t::Float64)
    Camera(mode.position, mode.target, mode.up, mode.fov)
end

function camera_at_frame(mode::OrbitCamera, frame::Int, nframes::Int, t::Float64)
    azimuth = 360.0 * mode.revolutions * (frame - 1) / max(nframes, 1)
    camera_orbit(mode.center, mode.distance;
                 azimuth=azimuth, elevation=mode.elevation, fov=mode.fov)
end

function camera_at_frame(mode::FollowCamera, frame::Int, nframes::Int, t::Float64)
    target = mode.center_fn(t)
    camera_orbit(target, mode.distance;
                 azimuth=45.0, elevation=mode.elevation, fov=mode.fov)
end

function camera_at_frame(mode::FunctionCamera, frame::Int, nframes::Int, t::Float64)
    mode.camera_fn(t)
end

# ============================================================================
# Transfer Function Presets (quantum visualization)
# ============================================================================

"""
    tf_electron() → TransferFunction

Blue-white transfer function optimized for electron probability density |ψ|².
"""
function tf_electron()::TransferFunction
    TransferFunction([
        ControlPoint(0.0, (0.0, 0.0, 0.1, 0.0)),
        ControlPoint(0.15, (0.1, 0.2, 0.6, 0.3)),
        ControlPoint(0.4, (0.3, 0.5, 0.9, 0.6)),
        ControlPoint(0.7, (0.6, 0.8, 1.0, 0.85)),
        ControlPoint(1.0, (1.0, 1.0, 1.0, 1.0)),
    ])
end

"""
    tf_photon() → TransferFunction

Red-orange transfer function for electromagnetic field energy density.
"""
function tf_photon()::TransferFunction
    TransferFunction([
        ControlPoint(0.0, (0.1, 0.0, 0.0, 0.0)),
        ControlPoint(0.2, (0.6, 0.1, 0.0, 0.3)),
        ControlPoint(0.5, (0.9, 0.3, 0.0, 0.6)),
        ControlPoint(0.8, (1.0, 0.6, 0.1, 0.85)),
        ControlPoint(1.0, (1.0, 0.9, 0.4, 1.0)),
    ])
end

"""
    tf_excited() → TransferFunction

Purple-magenta transfer function for excited electronic states.
"""
function tf_excited()::TransferFunction
    TransferFunction([
        ControlPoint(0.0, (0.05, 0.0, 0.1, 0.0)),
        ControlPoint(0.2, (0.3, 0.0, 0.4, 0.3)),
        ControlPoint(0.5, (0.6, 0.1, 0.7, 0.6)),
        ControlPoint(0.8, (0.9, 0.3, 0.9, 0.85)),
        ControlPoint(1.0, (1.0, 0.6, 1.0, 1.0)),
    ])
end

# ============================================================================
# Animation Renderer
# ============================================================================

"""
    render_animation(fields, materials, camera_mode; t_range, nframes, ...) → String

Render a time-evolving animation from one or more `TimeEvolution` fields.

Each field is voxelized at each time step, combined into a multi-volume `Scene`,
rendered, and written as a frame. After all frames, stitches to MP4 via ffmpeg.

Returns the output file path.

# Arguments
- `fields` — `TimeEvolution` or `Vector{TimeEvolution}` (multi-field)
- `materials` — `VolumeMaterial` or `Vector{VolumeMaterial}` (one per field)
- `camera_mode` — `FixedCamera`, `OrbitCamera`, or `FollowCamera`

# Keyword arguments
- `t_range` — `(t_start, t_end)` time range
- `nframes` — number of frames to render
- `fps=30` — frames per second for output video
- `width=512, height=512` — frame dimensions
- `spp=4` — samples per pixel
- `lights` — vector of lights (default: studio lighting)
- `output_dir` — directory for intermediate frames (default: temp dir)
- `output="animation.mp4"` — output video path
- `voxel_size=NaN` — voxel size (default: auto from field scale)
"""
function render_animation(fields::Vector{<:TimeEvolution},
                          materials::Vector{VolumeMaterial},
                          camera_mode::CameraMode;
                          t_range::Tuple{Float64,Float64},
                          nframes::Int,
                          fps::Int=30,
                          width::Int=512, height::Int=512,
                          spp::Int=4,
                          lights::Vector{<:AbstractLight}=light_studio(),
                          output_dir::String=mktempdir(),
                          output::String="animation.mp4",
                          voxel_size::Float64=NaN)
    length(fields) == length(materials) ||
        throw(ArgumentError("fields and materials must have the same length"))
    nframes ≥ 1 || throw(ArgumentError("nframes must be ≥ 1"))

    mkpath(output_dir)
    vs = isnan(voxel_size) ? characteristic_scale(fields[1]) / 5.0 : voxel_size
    dt = nframes > 1 ? (t_range[2] - t_range[1]) / (nframes - 1) : 0.0
    t_start = time()

    for frame in 1:nframes
        t = t_range[1] + (frame - 1) * dt
        cam = camera_at_frame(camera_mode, frame, nframes, t)
        cam_idx = _camera_to_index_space(cam, vs)

        # Voxelize all fields at time t
        entries = VolumeEntry[]
        total_voxels = 0
        for (f, mat) in zip(fields, materials)
            grid = voxelize(f; t=t, voxel_size=vs)
            nv = active_voxel_count(grid.tree)
            total_voxels += nv
            if nv > 0
                nano = build_nanogrid(grid.tree)
                push!(entries, VolumeEntry(grid, nano, mat))
            end
        end

        # Render
        if isempty(entries)
            img = fill((0.0, 0.0, 0.0), height, width)
        else
            scene = Scene(cam_idx, lights, entries)
            img = render_volume_image(scene, width, height; spp=spp)
        end

        frame_path = joinpath(output_dir, "frame_$(lpad(frame, 4, '0')).ppm")
        write_ppm(frame_path, img)

        elapsed = time() - t_start
        fps_actual = frame / elapsed
        eta = Int(round((nframes - frame) / max(fps_actual, 0.01)))
        println("  $(lpad(frame, 3))/$(nframes) | t=$(round(t, digits=2)) | " *
                "voxels=$(total_voxels) | $(round(fps_actual, digits=2)) fps | ETA $(eta)s")
    end

    stitch_to_mp4(output_dir, output; fps=fps)
    return output
end

# Single-field convenience
function render_animation(field::TimeEvolution, material::VolumeMaterial,
                          camera_mode::CameraMode; kwargs...)
    render_animation([field], [material], camera_mode; kwargs...)
end

# ============================================================================
# MP4 Stitching
# ============================================================================

"""
    stitch_to_mp4(frame_dir, output; fps=30, pattern="frame_%04d.ppm") → Bool

Stitch PPM frames into an MP4 video using ffmpeg.
Returns `true` on success, `false` if ffmpeg is not available.
"""
function stitch_to_mp4(frame_dir::String, output::String;
                       fps::Int=30, pattern::String="frame_%04d.ppm")
    ffmpeg = Sys.which("ffmpeg")
    if ffmpeg === nothing
        @warn "ffmpeg not found — frames saved in $frame_dir but no video created"
        return false
    end

    input_pattern = joinpath(frame_dir, pattern)
    cmd = `$(ffmpeg) -y -framerate $(fps) -i $(input_pattern)
           -c:v libx264 -pix_fmt yuv420p -crf 18 $(output)`
    try
        run(pipeline(cmd; stdout=devnull, stderr=devnull))
        println("Animation saved → $output")
        return true
    catch e
        @warn "ffmpeg failed: $e — frames saved in $frame_dir"
        return false
    end
end
