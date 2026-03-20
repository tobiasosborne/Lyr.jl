# Segmentation.jl — Connected component analysis on sparse VDB grids
#
# BFS flood fill using 6-connectivity (face neighbors).

"""
    segment_active_voxels(grid::Grid{T}) where T -> (Grid{Int32}, Int)

Label connected components of active voxels using 6-face connectivity.
Returns a label grid (Int32 values: 1, 2, 3, ...) and the component count.

# Example
```julia
labels, n = segment_active_voxels(grid)
println("Found \$n connected components")
```
"""
function segment_active_voxels(grid::Grid{T}) where T
    # Collect all active coords into a set for O(1) membership
    active_set = Set{Coord}()
    for (c, _) in active_voxels(grid.tree)
        push!(active_set, c)
    end

    isempty(active_set) && return (build_grid(Dict{Coord, Int32}(), Int32(0);
        name=grid.name * "_labels", voxel_size=_grid_voxel_size(grid)), 0)

    labels = Dict{Coord, Int32}()
    sizehint!(labels, length(active_set))
    visited = Set{Coord}()
    sizehint!(visited, length(active_set))
    component_id = Int32(0)

    # BFS queue (reused across components)
    queue = Coord[]

    for seed in active_set
        seed in visited && continue

        # New component
        component_id += Int32(1)
        empty!(queue)
        push!(queue, seed)
        push!(visited, seed)
        labels[seed] = component_id

        # BFS
        head = 1
        while head <= length(queue)
            c = queue[head]
            head += 1

            # Check 6 face neighbors
            for off in _FACE_OFFSETS
                nc = c + off
                nc in visited && continue
                nc in active_set || continue
                push!(visited, nc)
                push!(queue, nc)
                labels[nc] = component_id
            end
        end
    end

    label_grid = build_grid(labels, Int32(0);
        name=grid.name * "_labels", voxel_size=_grid_voxel_size(grid))
    (label_grid, Int(component_id))
end
