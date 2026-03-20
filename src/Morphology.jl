# Morphology.jl — Morphological dilation and erosion on VDB grids
#
# dilate: expand active region by activating face neighbors
# erode: contract active region by deactivating boundary voxels

"The 6 face-neighbor offsets in 3D (positive and negative along each axis)."
const _FACE_OFFSETS = (
    Coord(Int32(1),  Int32(0),  Int32(0)),
    Coord(Int32(-1), Int32(0),  Int32(0)),
    Coord(Int32(0),  Int32(1),  Int32(0)),
    Coord(Int32(0),  Int32(-1), Int32(0)),
    Coord(Int32(0),  Int32(0),  Int32(1)),
    Coord(Int32(0),  Int32(0),  Int32(-1)),
)

"""
    dilate(grid::Grid{T}; iterations=1) -> Grid{T}

Expand the active region by activating face neighbors of active voxels.
New voxels receive the background value. For level sets, this widens
the narrow band outward. Each iteration grows by one voxel layer.
"""
function dilate(grid::Grid{T}; iterations::Int=1) where T
    current = grid
    bg = grid.tree.background
    for _ in 1:iterations
        data = Dict{Coord, T}()
        for (c, v) in active_voxels(current.tree)
            data[c] = v
            for off in _FACE_OFFSETS
                nc = c + off
                haskey(data, nc) || (data[nc] = bg)
            end
        end
        current = build_grid(data, bg; name=current.name,
                             grid_class=current.grid_class,
                             voxel_size=_grid_voxel_size(current))
    end
    current
end

"""
    erode(grid::Grid{T}; iterations=1) -> Grid{T}

Contract the active region by removing voxels that touch any inactive
face neighbor. For level sets, this narrows the band inward.
Each iteration peels one voxel layer.
"""
function erode(grid::Grid{T}; iterations::Int=1) where T
    current = grid
    for _ in 1:iterations
        acc = ValueAccessor(current.tree)
        data = Dict{Coord, T}()
        for (c, v) in active_voxels(current.tree)
            interior = true
            for off in _FACE_OFFSETS
                if !is_active(acc, c + off)
                    interior = false
                    break
                end
            end
            interior && (data[c] = v)
        end
        current = build_grid(data, current.tree.background; name=current.name,
                             grid_class=current.grid_class,
                             voxel_size=_grid_voxel_size(current))
    end
    current
end
