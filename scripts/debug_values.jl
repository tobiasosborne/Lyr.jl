#!/usr/bin/env julia
# Debug script to trace values section format

using Lyr

path = "test/fixtures/samples/sphere.vdb"
bytes = read(path)

# Use Lyr's parse but also manually trace
vdb = parse_vdb(path)
grid = first(values(vdb.grids))

println("=== File Info ===")
println("Version: $(vdb.header.format_version)")
println("Grid: $(grid.name)")
println("Grid class: $(grid.grid_class)")
println("Background: $(grid.tree.background)")

# Get leaves and check first leaf's value pattern
leaves = collect(Lyr.leaves(grid.tree))
leaf = leaves[1]
bg = grid.tree.background

println("\n=== First Leaf Analysis ===")
println("Origin: $(leaf.origin)")
println("Active count: $(Lyr.count_on(leaf.value_mask))")

# Count value types
nan_count = sum(isnan, leaf.values)
bg_count = sum(v -> v == bg, leaf.values)
neg_bg_count = sum(v -> v == -bg, leaf.values)
other_count = 512 - nan_count - bg_count - neg_bg_count

println("\nValue breakdown:")
println("  NaN: $nan_count")
println("  Background ($bg): $bg_count")
println("  -Background ($(-bg)): $neg_bg_count")
println("  Other: $other_count")

# Check if "other" values look like SDFs
other_vals = filter(v -> !isnan(v) && v != bg && v != -bg, collect(leaf.values))
if !isempty(other_vals)
    println("\nOther value range: $(minimum(other_vals)) to $(maximum(other_vals))")
    println("Sample other values: $(other_vals[1:min(10, length(other_vals))])")
end

# Check active vs inactive patterns
active_bg = 0
active_neg_bg = 0
active_other = 0
inactive_bg = 0
inactive_neg_bg = 0
inactive_other = 0

for i in 0:511
    v = leaf.values[i+1]
    is_active = Lyr.is_on(leaf.value_mask, i)

    if v == bg
        is_active ? (active_bg += 1) : (inactive_bg += 1)
    elseif v == -bg
        is_active ? (active_neg_bg += 1) : (inactive_neg_bg += 1)
    else
        is_active ? (active_other += 1) : (inactive_other += 1)
    end
end

println("\n=== Active vs Inactive ===")
println("Active voxels:")
println("  Background: $active_bg")
println("  -Background: $active_neg_bg")
println("  Other: $active_other")
println("\nInactive voxels:")
println("  Background: $inactive_bg")
println("  -Background: $inactive_neg_bg")
println("  Other: $inactive_other")
