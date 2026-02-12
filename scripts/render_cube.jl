#!/usr/bin/env julia
# render_cube.jl - Parse cube.vdb with TinyVDB, convert, and render to PPM
#
# Usage: julia --project scripts/render_cube.jl [output.ppm] [width] [height]

using Lyr
using Lyr.TinyVDB

function main()
    # Defaults
    cube_path = joinpath(@__DIR__, "..", "test", "fixtures", "samples", "cube.vdb")
    output = length(ARGS) >= 1 ? ARGS[1] : "cube.ppm"
    width  = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 512
    height = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 512

    println("Parsing $cube_path ...")
    tiny = TinyVDB.parse_tinyvdb(cube_path)
    tiny_grid = first(values(tiny.grids))
    println("  Grid: $(tiny_grid.name), voxel_size: $(tiny_grid.voxel_size)")

    println("Converting to Lyr types ...")
    grid = convert_tinyvdb_grid(tiny_grid)
    println("  Leaves: $(leaf_count(grid.tree))")
    println("  Active voxels: $(active_voxel_count(grid.tree))")

    # Camera: 3/4 view looking at origin
    cam_pos = (12.0, 8.0, 12.0)
    target = (0.0, 0.0, 0.0)
    println("  Camera: $cam_pos → $target")

    println("Rendering $(width)x$(height) ...")
    cam = Camera(cam_pos, target, (0.0, 1.0, 0.0), 50.0)
    pixels = render_image(grid, cam, width, height; max_steps=500)

    write_ppm(output, pixels)
    println("Written to $output")
end

main()
