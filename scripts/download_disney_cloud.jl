# download_disney_cloud.jl — Download Disney Cloud VDB
#
# Downloads wdas_cloud_sixteenth.vdb (~1.6MB) to test/fixtures/disney/
# Uses Downloads.jl (Julia stdlib, no extra deps).
#
# Usage: julia --project scripts/download_disney_cloud.jl

using Downloads

const DEST_DIR = joinpath(@__DIR__, "..", "test", "fixtures", "disney")
const DEST_FILE = joinpath(DEST_DIR, "wdas_cloud_sixteenth.vdb")

# Try multiple URLs in case primary is down
const URLS = [
    "https://artifacts.aswf.io/io/aswf/openvdb/models/wdas_cloud_sixteenth.vdb/1.0.0/wdas_cloud_sixteenth.vdb-1.0.0.vdb",
    "https://www.openvdb.org/download/wdas_cloud_sixteenth.vdb",
]

if isfile(DEST_FILE)
    println("Already exists: $DEST_FILE ($(filesize(DEST_FILE)) bytes)")
else
    mkpath(DEST_DIR)
    downloaded = false
    for url in URLS
        println("Trying: $url")
        try
            Downloads.download(url, DEST_FILE)
            println("Downloaded: $(filesize(DEST_FILE)) bytes → $DEST_FILE")
            downloaded = true
            break
        catch e
            println("  Failed: $e")
            isfile(DEST_FILE) && rm(DEST_FILE; force=true)
        end
    end
    if !downloaded
        println("ERROR: Could not download Disney Cloud from any URL.")
        println("Please download manually and place at: $DEST_FILE")
        exit(1)
    end
end

# Verify with Lyr
println("\nVerifying parse...")
using Lyr
file = parse_vdb(DEST_FILE)
println("Grids: $(length(file.grids))")
for g in file.grids
    println("  $(g.name): $(active_voxel_count(g.tree)) active voxels")
end
println("Disney Cloud ready for benchmarks.")
