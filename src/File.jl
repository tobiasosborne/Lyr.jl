# File.jl - Top-level VDB file parsing
# Components: Header.jl, Metadata.jl, GridDescriptor.jl

"""
    VDBFile

A parsed VDB file containing header and grids.

# Fields
- `header::VDBHeader` - File header
- `grids::Vector` - Parsed grids (Grid{Float32}, Grid{Float64}, or Grid{NTuple{3, Float32}})
"""
struct VDBFile
    header::VDBHeader
    grids::Vector{Union{Grid{Float32}, Grid{Float64}, Grid{NTuple{3, Float32}}}}
end

"""
    parse_vdb(bytes::Vector{UInt8}) -> VDBFile

Parse a complete VDB file from bytes.
"""
function parse_vdb(bytes::Vector{UInt8})::VDBFile
    pos = 1

    # Read header
    header, pos = read_header(bytes, pos)

    # Read file-level metadata
    if header.format_version >= 222
        # Version 222+: No count prefix, use heuristic detection
        while is_metadata_entry(bytes, pos)
            _, pos = read_string_with_size(bytes, pos)  # key
            type_name, pos = read_string_with_size(bytes, pos)  # type
            pos = skip_metadata_value_heuristic(bytes, pos, type_name)  # value
        end
    else
        # Version 220-221: Has count prefix and size-prefixed values
        pos = read_file_metadata_v220(bytes, pos)
    end

    # Read grid count
    grid_count, pos = read_u32_le(bytes, pos)

    # Read grid descriptors
    descriptors = Vector{GridDescriptor}(undef, grid_count)
    for i in 1:grid_count
        descriptors[i], pos = read_grid_descriptor(bytes, pos, header.has_grid_offsets)
    end

    # Parse each grid - collect into temporary vector then filter
    grids_temp = Union{Grid{Float32}, Grid{Float64}, Grid{NTuple{3, Float32}}}[]

    for i in 1:grid_count
        desc = descriptors[i]

        # Skip instanced grids for now
        if !isempty(desc.instance_parent)
            continue
        end

        # Seek to grid data if byte offsets are present
        if header.has_grid_offsets && desc.byte_offset > 0
            pos = Int(desc.byte_offset) + 1  # byte_offset is 0-indexed, pos is 1-indexed
        end

        # Determine value type
        T = parse_value_type(desc.grid_type)

        # Read per-grid metadata (includes "class" entry)
        grid_metadata, pos = read_grid_metadata(bytes, pos)

        # Extract grid class from metadata
        grid_class_str = get(grid_metadata, "class", "unknown")
        grid_class = parse_grid_class(grid_class_str)

        # Grid start position (1-indexed) for calculating values section
        grid_start_pos = if header.has_grid_offsets && desc.byte_offset > 0
            Int(desc.byte_offset) + 1
        else
            pos  # Use current position if no offsets
        end

        # Parse the grid
        if T == Float32
            grid, pos = read_grid(Float32, bytes, pos, header.compression, desc.name, grid_class, header.format_version, grid_start_pos, desc.block_offset)
            push!(grids_temp, grid)
        elseif T == Float64
            grid, pos = read_grid(Float64, bytes, pos, header.compression, desc.name, grid_class, header.format_version, grid_start_pos, desc.block_offset)
            push!(grids_temp, grid)
        elseif T == NTuple{3, Float32}
            grid, pos = read_grid(NTuple{3, Float32}, bytes, pos, header.compression, desc.name, grid_class, header.format_version, grid_start_pos, desc.block_offset)
            push!(grids_temp, grid)
        end
    end

    VDBFile(header, grids_temp)
end

"""
    parse_vdb(path::String) -> VDBFile

Parse a VDB file from a file path.
"""
function parse_vdb(path::String)::VDBFile
    bytes = read(path)
    parse_vdb(bytes)
end
