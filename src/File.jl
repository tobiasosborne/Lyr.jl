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

function Base.show(io::IO, vdb::VDBFile)
    ng = length(vdb.grids)
    print(io, "VDBFile(v", vdb.header.format_version, ", ", ng, " grid", ng == 1 ? "" : "s")
    for g in vdb.grids
        print(io, ", \"", g.name, "\"")
    end
    print(io, ")")
end

"""
    parse_vdb(bytes::Vector{UInt8}) -> VDBFile

Parse a complete VDB file from bytes.
"""
function parse_vdb(bytes::Vector{UInt8})::VDBFile
    pos = 1

    # Read header
    header, pos = read_header(bytes, pos)

    # Read file-level metadata (same format for all versions: count + size-prefixed entries)
    pos = skip_file_metadata(bytes, pos)

    # Read grid count
    grid_count, pos = read_u32_le(bytes, pos)

    # Parse each grid — descriptors are interleaved with grid data in the file,
    # so we read each descriptor then its grid (or seek to end_offset to skip).
    grids_temp = Union{Grid{Float32}, Grid{Float64}, Grid{NTuple{3, Float32}}}[]

    for i in 1:grid_count
        # Read this grid's descriptor (immediately precedes its data)
        desc, pos = read_grid_descriptor(bytes, pos, header.has_grid_offsets)

        # Skip instanced grids
        if !isempty(desc.instance_parent)
            if header.has_grid_offsets && desc.end_offset > 0
                pos = Int(desc.end_offset) + 1
            end
            continue
        end

        # For v222+, read per-grid compression flags (4 bytes)
        # Flags: 0x1=ZIP, 0x2=ACTIVE_MASK, 0x4=BLOSC
        grid_codec, grid_mask_compressed = if header.format_version >= VDB_FILE_VERSION_NODE_MASK_COMPRESSION
            compression_flags, pos = read_u32_le(bytes, pos)
            codec = if (compression_flags & VDB_COMPRESS_BLOSC) != 0
                BloscCodec()
            elseif (compression_flags & VDB_COMPRESS_ZIP) != 0
                ZipCodec()
            else
                NoCompression()
            end
            mask_compressed = (compression_flags & VDB_COMPRESS_ACTIVE_MASK) != 0
            (codec, mask_compressed)
        else
            (header.compression, header.active_mask_compression)
        end

        # Determine value type and half-precision flag
        T = parse_value_type(desc.grid_type)

        # Skip unsupported grid types (e.g. PointDataIndex32)
        if T === nothing
            if header.has_grid_offsets && desc.end_offset > 0
                pos = Int(desc.end_offset) + 1
            end
            continue
        end

        half_precision = endswith(desc.grid_type, "_HalfFloat")
        # Half-precision stores each component as Float16 (2 bytes)
        n_components = T <: NTuple ? length(T.parameters) : 1
        value_size = half_precision ? 2 * n_components : sizeof(T)

        # Read per-grid metadata (includes "class" entry)
        grid_metadata, pos = read_grid_metadata(bytes, pos)

        # Extract grid class from metadata
        grid_class_str = get(grid_metadata, "class", "unknown")
        grid_class = parse_grid_class(grid_class_str)

        # Parse the grid
        if T == Float32
            grid, pos = read_grid(Float32, bytes, pos, grid_codec, grid_mask_compressed, desc.name, grid_class, header.format_version; value_size)
            push!(grids_temp, grid)
        elseif T == Float64
            grid, pos = read_grid(Float64, bytes, pos, grid_codec, grid_mask_compressed, desc.name, grid_class, header.format_version; value_size)
            push!(grids_temp, grid)
        elseif T == NTuple{3, Float32}
            grid, pos = read_grid(NTuple{3, Float32}, bytes, pos, grid_codec, grid_mask_compressed, desc.name, grid_class, header.format_version; value_size)
            push!(grids_temp, grid)
        else
            @warn "Skipping grid '$(desc.name)' with unsupported value type: $T"
        end

        # Seek to end_offset for next grid descriptor (robust for multi-grid files)
        if header.has_grid_offsets && desc.end_offset > 0
            pos = Int(desc.end_offset) + 1
        end
    end

    VDBFile(header, grids_temp)
end

using Mmap

"""
    parse_vdb(path::String; mmap::Bool=false) -> VDBFile

Parse a VDB file from a file path.

When `mmap=true`, the file is memory-mapped instead of loaded into memory,
which avoids copying for large VDB files. Default is `false` for safety
(mmap'd memory invalidates if the file is modified during parse).
"""
function parse_vdb(path::String; mmap::Bool=false)::VDBFile
    bytes = if mmap
        Mmap.mmap(path)
    else
        read(path)
    end
    parse_vdb(bytes)
end
