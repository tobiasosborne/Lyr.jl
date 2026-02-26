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
- `voxel_size::Float64`: Uniform voxel size from transform
- `grid_class::String`: Grid class from metadata (e.g. "level set", "fog volume")
"""
struct TinyGrid
    name::String
    root::RootNodeData
    voxel_size::Float64
    grid_class::String
    translation::NTuple{3, Float64}
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
    read_metadata(bytes::Vector{UInt8}, pos::Int) -> Tuple{Dict{String,String}, Int}

Read grid metadata, collecting string-typed entries into a dictionary.

Returns (metadata_dict, new_pos). Non-string metadata types are skipped over.
"""
function read_metadata(bytes::Vector{UInt8}, pos::Int)::Tuple{Dict{String,String}, Int}
    metadata = Dict{String,String}()

    # Read count
    count, pos = read_i32(bytes, pos)

    for _ in 1:count
        # name string
        name, pos = read_string(bytes, pos)

        # type string
        type_name, pos = read_string(bytes, pos)

        # value - depends on type
        # Note: All typed values (except string) have a 4-byte size prefix per C++ reference
        if type_name == "string"
            value, pos = read_string(bytes, pos)
            metadata[name] = value
        elseif type_name == "bool"
            _, pos = read_u32(bytes, pos)  # size prefix (u32 per VDB spec)
            _, pos = read_u8(bytes, pos)
        elseif type_name == "float"
            _, pos = read_u32(bytes, pos)  # size prefix
            _, pos = read_f32(bytes, pos)
        elseif type_name == "double"
            _, pos = read_u32(bytes, pos)  # size prefix
            _, pos = read_f64(bytes, pos)
        elseif type_name == "int32"
            _, pos = read_u32(bytes, pos)  # size prefix
            _, pos = read_i32(bytes, pos)
        elseif type_name == "int64"
            _, pos = read_u32(bytes, pos)  # size prefix
            _, pos = read_i64(bytes, pos)
        elseif type_name == "vec3i"
            _, pos = read_u32(bytes, pos)  # size prefix
            _, pos = read_i32(bytes, pos)
            _, pos = read_i32(bytes, pos)
            _, pos = read_i32(bytes, pos)
        elseif type_name == "vec3d"
            _, pos = read_u32(bytes, pos)  # size prefix
            _, pos = read_f64(bytes, pos)
            _, pos = read_f64(bytes, pos)
            _, pos = read_f64(bytes, pos)
        else
            # Unknown type - read size and skip
            size, pos = read_u32(bytes, pos)
            pos += Int(size)
        end
    end

    return (metadata, pos)
end

# =============================================================================
# Transform Reading (skip over for TinyVDB)
# =============================================================================

"""
    read_transform(bytes::Vector{UInt8}, pos::Int) -> Tuple{Float64, NTuple{3,Float64}, Int}

Read grid transform and extract the voxel size and translation.

Returns (voxel_size, translation, new_pos).

Per tinyvdbio.h ReadTransform (lines 2620-2669):
UniformScaleMap reads 5 Vec3d = 15 doubles = 120 bytes:
  - scale_values (3 doubles) ← voxel_size is scale_values[1]
  - voxel_size (3 doubles)
  - scale_values_inverse (3 doubles)
  - inv_scale_squared (3 doubles)
  - inv_twice_scale (3 doubles)
"""
function read_transform(bytes::Vector{UInt8}, pos::Int)::Tuple{Float64, NTuple{3, Float64}, Int}
    # Read transform type string
    transform_type, pos = read_string(bytes, pos)

    if transform_type in ("UniformScaleMap", "ScaleMap")
        # 5 Vec3d = 15 doubles = 120 bytes
        # First double is scale_x (= voxel size for uniform scale)
        scale_x, pos = read_f64(bytes, pos)
        for _ in 2:15
            _, pos = read_f64(bytes, pos)
        end
        return (scale_x, (0.0, 0.0, 0.0), pos)
    elseif transform_type in ("UniformScaleTranslateMap", "ScaleTranslateMap")
        # Translation Vec3d (3 doubles = 24 bytes) THEN 5 Vec3d (15 doubles = 120 bytes)
        # Total: 18 doubles = 144 bytes
        # OpenVDB ScaleTranslateMap::write() emits translation first, then ScaleMap data
        tx, pos = read_f64(bytes, pos)
        ty, pos = read_f64(bytes, pos)
        tz, pos = read_f64(bytes, pos)
        scale_x, pos = read_f64(bytes, pos)
        for _ in 2:15
            _, pos = read_f64(bytes, pos)
        end
        return (scale_x, (tx, ty, tz), pos)
    else
        throw(FormatError("Unsupported transform type: $transform_type"))
    end
end

# =============================================================================
# Grid Reading
# =============================================================================

"""
    read_grid(bytes::Vector{UInt8}, gd::GridDescriptor, header::VDBHeader) -> TinyGrid

Read a single grid from bytes using its descriptor and file header.

Seeks to grid_pos, reads compression, metadata, transform, topology, and values.
"""
function read_grid(bytes::Vector{UInt8}, gd::GridDescriptor, header::VDBHeader)::TinyGrid
    file_version = header.file_version

    # Start at grid_pos (1-indexed for Julia)
    pos = Int(gd.grid_pos) + 1

    # Determine value element size: 2 for half precision, 4 for full
    value_size = gd.half_precision ? 2 : 4

    # Read per-grid compression (v222+ reads from stream; v220 uses header flag)
    compression_flags, pos = read_grid_compression(bytes, pos, file_version;
                                                    is_compressed=header.is_compressed)

    # Read metadata and extract grid class
    metadata, pos = read_metadata(bytes, pos)
    grid_class = get(metadata, "class", "unknown")

    # Read transform (capture voxel size and translation)
    voxel_size, translation, pos = read_transform(bytes, pos)

    # Read buffer_count (TreeBase) - must be 1
    buffer_count, pos = read_u32(bytes, pos)
    if buffer_count != 1
        @warn "Multi-buffer trees are not supported, found buffer_count=$buffer_count"
    end

    # Read tree topology
    root, pos = read_root_topology(bytes, pos;
                                   file_version=file_version,
                                   compression_flags=compression_flags,
                                   value_size=value_size)

    # Read tree values
    root, pos = read_tree_values(bytes, pos, root, file_version, compression_flags;
                                value_size=value_size)

    return TinyGrid(gd.grid_name, root, voxel_size, grid_class, translation)
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
        throw(UnsupportedVersionError(header.file_version, UInt32(220)))
    end

    # Read and skip file-level metadata
    _, pos = read_metadata(bytes, pos)

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

        grid = read_grid(bytes, gd, header)
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
        throw(UnsupportedVersionError(header.file_version, UInt32(220)))
    end

    # Read and skip file-level metadata
    _, pos = read_metadata(bytes, pos)

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

        grid = read_grid(bytes, gd, header)
        grids[name] = grid
    end

    return TinyVDBFile(header, grids)
end
