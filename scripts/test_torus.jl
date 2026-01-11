#!/usr/bin/env julia
using Lyr

function main()
    path = "test/fixtures/samples/torus.vdb"
    println("Testing torus.vdb...")

    vdb = parse_vdb(path)
    grid = first(values(vdb.grids))
    bg = grid.tree.background

    # Sample active voxels
    active_vals = Float32[]
    count = 0
    for (coord, val) in Lyr.active_voxels(grid.tree)
        push!(active_vals, val)
        count += 1
        count >= 500 && break
    end

    nan_ct = sum(isnan, active_vals)
    bg_ct = sum(v -> v == bg, active_vals)
    valid_ct = length(active_vals) - nan_ct - bg_ct

    println("Sampled: $(length(active_vals)) active voxels")
    println("NaN: $nan_ct ($(round(100*nan_ct/length(active_vals), digits=1))%)")
    println("Background: $bg_ct ($(round(100*bg_ct/length(active_vals), digits=1))%)")
    println("Valid SDF: $valid_ct ($(round(100*valid_ct/length(active_vals), digits=1))%)")

    valid = filter(v -> !isnan(v) && v != bg, active_vals)
    if !isempty(valid)
        println("Value range: $(minimum(valid)) to $(maximum(valid))")
    end
end

main()
