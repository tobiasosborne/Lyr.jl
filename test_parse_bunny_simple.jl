using VDB

try
    vdb = parse_vdb("test/fixtures/samples/bunny_cloud.vdb")
    println("SUCCESS! Parsed bunny_cloud.vdb")
    println("Grids: $(length(vdb.grids))")
    for grid in vdb.grids
        println("  - $(grid.name)")
    end
catch e
    println("ERROR: $e")
    @show stacktrace(catch_backtrace())
end
