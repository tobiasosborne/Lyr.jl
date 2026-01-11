# Parser.jl - Entry point for TinyVDB parser
#
# This module ties together all parsing components to provide a simple API
# for reading VDB files.
#
# Main function: parse_tinyvdb(filepath) -> TinyVDBFile

# =============================================================================
# Data Structures
# =============================================================================

"""
    TinyGrid

A parsed VDB grid with its tree structure.

# Fields
- `name::String`: Grid name
- `root::RootNodeData`: Root of the tree containing all voxel data
"""
struct TinyGrid
    name::String
    root::RootNodeData
end

"""
    TinyVDBFile

A parsed VDB file containing header and grids.

# Fields
- `header::VDBHeader`: File header with version and metadata
- `grids::Dict{String, TinyGrid}`: Dictionary of grids by name
"""
struct TinyVDBFile
    header::VDBHeader
    grids::Dict{String, TinyGrid}
end

# =============================================================================
# Metadata Reading (skip over for TinyVDB)
# =============================================================================

"""
    read_metadata(bytes::Vector{UInt8}, pos::Int) -> Int

Read and skip over grid metadata.

Returns the new position after all metadata.
"""
function read_metadata(bytes::Vector{UInt8}, pos::Int)::Int
    # Read count
    count, pos = read_i32(bytes, pos)

    for _ in 1:count
        # name string
        _, pos = read_string(bytes, pos)

        # type string
        type_name, pos = read_string(bytes, pos)

        # value - depends on type
        # Note: All typed values (except string) have a 4-byte size prefix per C++ reference
        if type_name == "string"
            _, pos = read_string(bytes, pos)
        elseif type_name == "bool"
            _, pos = read_i32(bytes, pos)  # size prefix
            _, pos = read_u8(bytes, pos)
        elseif type_name == "float"
            _, pos = read_i32(bytes, pos)  # size prefix
            _, pos = read_f32(bytes, pos)
        elseif type_name == "double"
            _, pos = read_i32(bytes, pos)  # size prefix
            _, pos = read_f64(bytes, pos)
        elseif type_name == "int32"
            _, pos = read_i32(bytes, pos)  # size prefix
            _, pos = read_i32(bytes, pos)
        elseif type_name == "int64"
            _, pos = read_i32(bytes, pos)  # size prefix
            _, pos = read_i64(bytes, pos)
        elseif type_name == "vec3i"
            _, pos = read_i32(bytes, pos)  # size prefix
            _, pos = read_i32(bytes, pos)
            _, pos = read_i32(bytes, pos)
            _, pos = read_i32(bytes, pos)
        elseif type_name == "vec3d"
            _, pos = read_i32(bytes, pos)  # size prefix
            _, pos = read_f64(bytes, pos)
            _, pos = read_f64(bytes, pos)
            _, pos = read_f64(bytes, pos)
        else
            # Unknown type - read size and skip
            size, pos = read_i32(bytes, pos)
            pos += size
        end
    end

    return pos
end

# =============================================================================
# Transform Reading (skip over for TinyVDB)
# =============================================================================

"""
    read_transform(bytes::Vector{UInt8}, pos::Int) -> Int

Read and skip over grid transform.

TinyVDB doesn't process transforms, just skips over them.
Returns the new position after the transform data.
"""
function read_transform(bytes::Vector{UInt8}, pos::Int)::Int
    # Read transform type string
    transform_type, pos = read_string(bytes, pos)

    # Based on type, skip the appropriate amount of data
    if transform_type == "linear" || transform_type == "uniformScaleMap" ||
       transform_type == "scaleMap" || transform_type == "translationMap"
        # 4x4 matrix = 16 doubles = 128 bytes
        # But actually VDB stores transforms as a simpler format...
        # Let's read the actual format: just the matrix elements

        # For a linear transform: read 12 doubles (3x4 matrix)
        for _ in 1:12
            _, pos = read_f64(bytes, pos)
        end
    elseif transform_type == "uniformScaleTranslateMap"
        # scale (double) + translation (3 doubles) = 4 doubles
        for _ in 1:4
            _, pos = read_f64(bytes, pos)
        end
    elseif transform_type == "scaleTranslateMap"
        # scale (3 doubles) + translation (3 doubles) = 6 doubles
        for _ in 1:6
            _, pos = read_f64(bytes, pos)
        end
    else
        # Unknown transform type - try to continue with linear format
        for _ in 1:12
            _, pos = read_f64(bytes, pos)
        end
    end

    return pos
end

# =============================================================================
# Grid Reading
# =============================================================================

"""
    read_grid(bytes::Vector{UInt8}, gd::GridDescriptor, file_version::UInt32) -> TinyGrid

Read a single grid from bytes using its descriptor.

Seeks to grid_pos, reads compression, metadata, transform, topology, and values.
"""
function read_grid(bytes::Vector{UInt8}, gd::GridDescriptor, file_version::UInt32)::TinyGrid
    # Start at grid_pos (1-indexed for Julia)
    pos = Int(gd.grid_pos) + 1

    # Read per-grid compression (v222+)
    compression_flags, pos = read_grid_compression(bytes, pos, file_version)

    # Read metadata (skip over for TinyVDB)
    pos = read_metadata(bytes, pos)

    # Read transform (skip over for TinyVDB)
    pos = read_transform(bytes, pos)

    # Read buffer_count (TreeBase) - must be 1
    buffer_count, pos = read_i32(bytes, pos)
    if buffer_count != 1
        @warn "Multi-buffer trees are not supported, found buffer_count=$buffer_count"
    end

    # Read tree topology
    root, pos = read_root_topology(bytes, pos;
                                   file_version=file_version,
                                   compression_flags=compression_flags)

    # Read tree values
    root, pos = read_tree_values(bytes, pos, root, file_version, compression_flags)

    return TinyGrid(gd.grid_name, root)
end

# =============================================================================
# Main Entry Point
# =============================================================================

"""
    parse_tinyvdb(filepath::String) -> TinyVDBFile

Parse a VDB file and return a TinyVDBFile structure.

Only supports:
- v222 format
- Float32 grids (Tree_float_5_4_3)
- Zlib and no compression

# Example
```julia
vdb = parse_tinyvdb("cube.vdb")
for (name, grid) in vdb.grids
    println("Grid: \$name, background: \$(grid.root.background)")
end
```
"""
function parse_tinyvdb(filepath::String)::TinyVDBFile
    # Read entire file
    bytes = read(filepath)

    # Parse header
    header, pos = read_header(bytes, 1)

    # Check version
    if header.file_version < 220
        error("Unsupported VDB version: $(header.file_version). TinyVDB requires version 220+")
    end

    # Read and skip file-level metadata
    pos = read_metadata(bytes, pos)

    # Read grid descriptors
    descriptors, pos = read_grid_descriptors(bytes, pos)

    # Read each grid
    grids = Dict{String, TinyGrid}()
    for (name, gd) in descriptors
        # Only support Tree_float_5_4_3
        if gd.grid_type != "Tree_float_5_4_3"
            @warn "Skipping unsupported grid type: $(gd.grid_type) for grid: $name"
            continue
        end

        grid = read_grid(bytes, gd, header.file_version)
        grids[name] = grid
    end

    return TinyVDBFile(header, grids)
end

"""
    parse_tinyvdb(bytes::Vector{UInt8}) -> TinyVDBFile

Parse a VDB file from a byte array.
"""
function parse_tinyvdb(bytes::Vector{UInt8})::TinyVDBFile
    # Parse header
    header, pos = read_header(bytes, 1)

    # Check version
    if header.file_version < 220
        error("Unsupported VDB version: $(header.file_version). TinyVDB requires version 220+")
    end

    # Read and skip file-level metadata
    pos = read_metadata(bytes, pos)

    # Read grid descriptors
    descriptors, pos = read_grid_descriptors(bytes, pos)

    # Read each grid
    grids = Dict{String, TinyGrid}()
    for (name, gd) in descriptors
        # Only support Tree_float_5_4_3
        if gd.grid_type != "Tree_float_5_4_3"
            @warn "Skipping unsupported grid type: $(gd.grid_type) for grid: $name"
            continue
        end

        grid = read_grid(bytes, gd, header.file_version)
        grids[name] = grid
    end

    return TinyVDBFile(header, grids)
end
