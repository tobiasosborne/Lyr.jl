#!/usr/bin/env julia
# Render the Utah teapot at 512x512

using Lyr
using Lyr.TinyVDB: TinyVDB

path = joinpath(@__DIR__, "..", "test", "fixtures", "samples", "utahteapot.vdb")
println("Parsing $path...")
tiny = TinyVDB.parse_tinyvdb(path)
grid = convert_tinyvdb_grid(tiny.grids["ls_utahteapot"])

# Find bounding box to place camera intelligently
bbox = active_bounding_box(grid.tree)
wmin = index_to_world(grid.transform, bbox.min)
wmax = index_to_world(grid.transform, bbox.max)
center = ((wmin[1]+wmax[1])/2, (wmin[2]+wmax[2])/2, (wmin[3]+wmax[3])/2)
extent = max(wmax[1]-wmin[1], wmax[2]-wmin[2], wmax[3]-wmin[3])
println("World bounds: $wmin → $wmax  center=$center  extent=$extent")

# Classic 3/4 view, pulled back to 2x extent
dist = extent * 1.8
cam = Camera(
    (center[1] + dist*0.6, center[2] + dist*0.4, center[3] + dist*0.6),
    center,
    (0.0, 1.0, 0.0),
    40.0
)

println("Rendering 1024x1024 (this may take a few minutes)...")
pixels = render_image(grid, cam, 1024, 1024; max_steps=500)

ppm_path = joinpath(@__DIR__, "..", "teapot.ppm")
write_ppm(ppm_path, pixels)
println("Wrote $ppm_path")

# Count hits
bg = (0.1, 0.1, 0.15)
hits = count(p -> p != bg, pixels)
println("Pixels hitting teapot: $hits / $(1024*1024)")
