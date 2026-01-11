#!/usr/bin/env julia
#
# render_vdb.jl - Render VDB level sets to PPM images
#
# Usage:
#   julia --project scripts/render_vdb.jl <input.vdb> <output.ppm> [options]
#
# Options:
#   --width=N       Image width (default: 800)
#   --height=N      Image height (default: 600)
#   --fov=N         Field of view in degrees (default: 60)
#   --distance=N    Camera distance multiplier (default: 2.0)
#   --steps=N       Max sphere tracing steps (default: 200)
#
# Example:
#   julia --project scripts/render_vdb.jl test/fixtures/samples/torus.vdb torus.ppm --width=1024

using Lyr

function parse_args()
    args = ARGS

    if length(args) < 2
        println(stderr, "Usage: julia --project scripts/render_vdb.jl <input.vdb> <output.ppm> [options]")
        println(stderr, "")
        println(stderr, "Options:")
        println(stderr, "  --width=N       Image width (default: 800)")
        println(stderr, "  --height=N      Image height (default: 600)")
        println(stderr, "  --fov=N         Field of view in degrees (default: 60)")
        println(stderr, "  --distance=N    Camera distance multiplier (default: 2.0)")
        println(stderr, "  --steps=N       Max sphere tracing steps (default: 200)")
        exit(1)
    end

    input_path = args[1]
    output_path = args[2]

    # Default options
    width = 800
    height = 600
    fov = 60.0
    distance_mult = 2.0
    max_steps = 200

    # Parse options
    for arg in args[3:end]
        if startswith(arg, "--width=")
            width = parse(Int, arg[9:end])
        elseif startswith(arg, "--height=")
            height = parse(Int, arg[10:end])
        elseif startswith(arg, "--fov=")
            fov = parse(Float64, arg[7:end])
        elseif startswith(arg, "--distance=")
            distance_mult = parse(Float64, arg[12:end])
        elseif startswith(arg, "--steps=")
            max_steps = parse(Int, arg[9:end])
        else
            println(stderr, "Unknown option: $arg")
            exit(1)
        end
    end

    (input_path, output_path, width, height, fov, distance_mult, max_steps)
end

function main()
    input_path, output_path, width, height, fov, distance_mult, max_steps = parse_args()

    # Parse VDB file
    println("Parsing $input_path...")
    vdb = parse_vdb(input_path)

    if isempty(vdb.grids)
        println(stderr, "Error: No grids found in VDB file")
        exit(1)
    end

    grid = vdb.grids[1]
    println("Grid: $(vdb.grid_descriptors[1].unique_name)")
    println("  Class: $(grid.grid_class)")
    println("  Leaves: $(leaf_count(grid.tree))")
    println("  Active voxels: $(active_voxel_count(grid.tree))")

    # Get bounding box
    bbox = active_bounding_box(grid.tree)
    if bbox === nothing
        println(stderr, "Error: Grid has no active voxels")
        exit(1)
    end

    # Compute world-space bounds and center
    world_min = index_to_world(grid.transform, bbox.min)
    world_max = index_to_world(grid.transform, bbox.max)

    center = (
        (world_min[1] + world_max[1]) / 2,
        (world_min[2] + world_max[2]) / 2,
        (world_min[3] + world_max[3]) / 2
    )

    # Compute camera distance based on object size
    extent = max(
        world_max[1] - world_min[1],
        world_max[2] - world_min[2],
        world_max[3] - world_min[3]
    )
    camera_dist = extent * distance_mult

    # Position camera looking at center from a diagonal
    camera_pos = (
        center[1] + camera_dist * 0.7,
        center[2] + camera_dist * 0.5,
        center[3] + camera_dist * 0.7
    )

    println("Camera:")
    println("  Position: $camera_pos")
    println("  Target: $center")
    println("  FOV: $fov")

    # Create camera
    cam = Camera(camera_pos, center, (0.0, 1.0, 0.0), fov)

    # Render
    println("Rendering $(width)x$(height) image...")
    t0 = time()
    pixels = render_image(grid, cam, width, height; max_steps=max_steps)
    elapsed = time() - t0

    println("  Time: $(round(elapsed, digits=2))s")
    println("  Rays/sec: $(round(width * height / elapsed, digits=0))")

    # Write output
    println("Writing $output_path...")
    write_ppm(output_path, pixels)

    println("Done!")
end

main()
