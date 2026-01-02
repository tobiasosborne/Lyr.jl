# VDB.jl Implementation Plan

You are implementing a pure Julia parser for OpenVDB files. This is a greenfield project requiring extreme correctness and elegance.
You are a godlike level 99 archmage programmer with Donald Knuthian powers!

## Project Setup

Create a Julia package structure:

```
VDB.jl/
+-- src/
¦   +-- VDB.jl           # Main module, exports
¦   +-- Binary.jl        # Step 1
¦   +-- Masks.jl         # Step 2
¦   +-- Coordinates.jl   # Step 3
¦   +-- Compression.jl   # Step 4
¦   +-- TreeTypes.jl     # Step 5
¦   +-- Topology.jl      # Step 6
¦   +-- Values.jl        # Step 7
¦   +-- Transforms.jl    # Step 8
¦   +-- Grid.jl          # Step 9
¦   +-- File.jl          # Step 10
¦   +-- Accessors.jl     # Step 11
¦   +-- Interpolation.jl # Step 12
¦   +-- Ray.jl           # Step 13
+-- test/
¦   +-- runtests.jl
¦   +-- test_binary.jl
¦   +-- test_masks.jl
¦   +-- test_coordinates.jl
¦   +-- test_compression.jl
¦   +-- test_tree_types.jl
¦   +-- test_topology.jl
¦   +-- test_values.jl
¦   +-- test_transforms.jl
¦   +-- test_grid.jl
¦   +-- test_file.jl
¦   +-- test_accessors.jl
¦   +-- test_interpolation.jl
¦   +-- test_ray.jl
¦   +-- test_integration.jl
¦   +-- test_properties.jl
+-- Project.toml
+-- README.md
```

## Design Principles

1. **Pure functions**: All parsing functions have signature `(bytes::Vector{UInt8}, pos::Int) ? (result, new_pos::Int)`. No mutation, no side effects.

2. **Immutable data**: All structs are immutable. Use `NTuple` over `Vector` where size is known.

3. **Type safety**: Parameterise by value type. Make illegal states unrepresentable.

4. **Explicit errors**: Return `Union{T, ParseError}` or throw typed exceptions with context.

5. **No stringly-typed dispatch**: Codecs, grid types, etc. are Julia types.

## Implementation Steps

Execute these in order. Each step must have complete tests before proceeding.

---

### Step 1: Binary Primitives (`src/Binary.jl`, `test/test_binary.jl`)

Pure functions for reading primitive types from byte vectors.

```julia
# Signatures
read_u8(bytes::Vector{UInt8}, pos::Int) ? Tuple{UInt8, Int}
read_u32_le(bytes::Vector{UInt8}, pos::Int) ? Tuple{UInt32, Int}
read_u64_le(bytes::Vector{UInt8}, pos::Int) ? Tuple{UInt64, Int}
read_i32_le(bytes::Vector{UInt8}, pos::Int) ? Tuple{Int32, Int}
read_i64_le(bytes::Vector{UInt8}, pos::Int) ? Tuple{Int64, Int}
read_f32_le(bytes::Vector{UInt8}, pos::Int) ? Tuple{Float32, Int}
read_f64_le(bytes::Vector{UInt8}, pos::Int) ? Tuple{Float64, Int}
read_bytes(bytes::Vector{UInt8}, pos::Int, n::Int) ? Tuple{Vector{UInt8}, Int}
read_cstring(bytes::Vector{UInt8}, pos::Int) ? Tuple{String, Int}
read_string_with_size(bytes::Vector{UInt8}, pos::Int) ? Tuple{String, Int}
```

**Tests required**:
- Known byte patterns for each type (endianness verification)
- Boundary: pos=1, pos=length(bytes)-sizeof(T)+1
- Error on insufficient bytes
- Empty string, max-length string
- Null bytes within string data

---

### Step 2: Bitmasks (`src/Masks.jl`, `test/test_masks.jl`)

Immutable fixed-size bitmask types.

```julia
struct Mask{N}
    words::NTuple{cld(N, 64), UInt64}
end

# Constructors
Mask{N}() ? Mask{N}  # all zeros
Mask{N}(::Val{:ones}) ? Mask{N}  # all ones

# Predicates
is_on(m::Mask{N}, i::Int) ? Bool
is_off(m::Mask{N}, i::Int) ? Bool
is_empty(m::Mask{N}) ? Bool
is_full(m::Mask{N}) ? Bool

# Counts
count_on(m::Mask{N}) ? Int
count_off(m::Mask{N}) ? Int

# Iteration
on_indices(m::Mask{N}) ? iterator
off_indices(m::Mask{N}) ? iterator

# Parsing
read_mask(::Type{Mask{N}}, bytes, pos) ? Tuple{Mask{N}, Int}

# Type aliases
const LeafMask = Mask{512}
const Internal1Mask = Mask{4096}
const Internal2Mask = Mask{32768}
```

**Tests required**:
- All zeros: count_on=0, is_empty=true
- All ones: count_on=N, is_full=true
- Single bit at positions 0, 1, 63, 64, 65, N-1
- Word boundaries: bit 63?64, 127?128
- Iteration order is ascending
- count_on == length(collect(on_indices(m)))
- Round-trip: read what you write

---

### Step 3: Coordinates (`src/Coordinates.jl`, `test/test_coordinates.jl`)

Coordinate types and tree navigation.

```julia
const Coord = NTuple{3, Int32}

# Construction
coord(x, y, z) ? Coord

# Arithmetic (pure)
Base.:+(a::Coord, b::Coord) ? Coord
Base.:-(a::Coord, b::Coord) ? Coord
Base.min(a::Coord, b::Coord) ? Coord
Base.max(a::Coord, b::Coord) ? Coord

# Tree navigation  which node contains this coord
leaf_origin(c::Coord) ? Coord          # round down to 8
internal1_origin(c::Coord) ? Coord     # round down to 128 (8*16)
internal2_origin(c::Coord) ? Coord     # round down to 4096 (8*16*32)

# Offsets within node  linear index
leaf_offset(c::Coord) ? Int            # 0-511
internal1_child_index(c::Coord) ? Int  # 0-4095
internal2_child_index(c::Coord) ? Int  # 0-32767

# Bounding box
struct BBox
    min::Coord
    max::Coord
end

contains(bb::BBox, c::Coord) ? Bool
intersects(a::BBox, b::BBox) ? Bool
union(a::BBox, b::BBox) ? BBox
volume(bb::BBox) ? Int64
```

**Tests required**:
- Origin of (0,0,0) is (0,0,0) for all levels
- Origin of (7,7,7) is (0,0,0) for leaf
- Origin of (8,0,0) is (8,0,0) for leaf
- Negative coordinates: (-1,-1,-1) ? (-8,-8,-8) for leaf
- Int32 extremes
- Offset indexing matches expected 3D?1D mapping
- BBox operations

---

### Step 4: Compression (`src/Compression.jl`, `test/test_compression.jl`)

Codec abstraction.

```julia
abstract type Codec end
struct NoCompression <: Codec end
struct BloscCodec <: Codec end
struct ZipCodec <: Codec end

decompress(::NoCompression, bytes::Vector{UInt8}) ? Vector{UInt8}
decompress(::BloscCodec, bytes::Vector{UInt8}) ? Vector{UInt8}
decompress(::ZipCodec, bytes::Vector{UInt8}) ? Vector{UInt8}

# Size-prefixed compressed block
read_compressed_bytes(bytes, pos, codec::Codec, expected_size::Int) ? Tuple{Vector{UInt8}, Int}
```

**Dependency**: Add `CodecBlosc` and `CodecZlib` to Project.toml.

**Tests required**:
- NoCompression is identity
- Blosc round-trip with known data
- Zlib round-trip with known data
- Empty data
- Incompressible data
- Corrupt data ? error

---

### Step 5: Tree Types (`src/TreeTypes.jl`, `test/test_tree_types.jl`)

Immutable algebraic data types for tree structure.

```julia
abstract type AbstractNode{T} end

struct LeafNode{T} <: AbstractNode{T}
    origin::Coord
    value_mask::LeafMask
    values::NTuple{512, T}
end

struct Tile{T}
    value::T
    active::Bool
end

struct InternalNode1{T} <: AbstractNode{T}
    origin::Coord
    child_mask::Internal1Mask
    value_mask::Internal1Mask
    table::Vector{Union{LeafNode{T}, Tile{T}}}
end

struct InternalNode2{T} <: AbstractNode{T}
    origin::Coord
    child_mask::Internal2Mask
    value_mask::Internal2Mask
    table::Vector{Union{InternalNode1{T}, Tile{T}}}
end

struct RootNode{T} <: AbstractNode{T}
    background::T
    table::Dict{Coord, Union{InternalNode2{T}, Tile{T}}}
end

const Tree{T} = RootNode{T}
```

**Tests required**:
- Type stability checks
- Construction with consistent mask/table lengths

---

### Step 6: Topology Parsing (`src/Topology.jl`, `test/test_topology.jl`)

Parse tree structure without values.

```julia
# Intermediate topology types (before values are loaded)
struct LeafTopology
    origin::Coord
    value_mask::LeafMask
end

struct Internal1Topology
    origin::Coord
    child_mask::Internal1Mask
    value_mask::Internal1Mask
    children::Vector{Union{LeafTopology, Nothing}}
end

struct Internal2Topology
    origin::Coord
    child_mask::Internal2Mask
    value_mask::Internal2Mask
    children::Vector{Union{Internal1Topology, Nothing}}
end

struct RootTopology
    background_active::Bool
    tile_count::UInt32
    child_count::UInt32
    entries::Vector{Tuple{Coord, Bool, Union{Internal2Topology, Nothing}}}
end

read_leaf_topology(bytes, pos) ? Tuple{LeafTopology, Int}
read_internal1_topology(bytes, pos, child_count) ? Tuple{Internal1Topology, Int}
read_internal2_topology(bytes, pos, child_count) ? Tuple{Internal2Topology, Int}
read_root_topology(bytes, pos) ? Tuple{RootTopology, Int}
```

**Tests required**:
- Empty root (no children, no tiles)
- Root with single tile
- Root with single child containing single leaf
- Full depth path
- Multiple children at each level

---

### Step 7: Value Parsing (`src/Values.jl`, `test/test_values.jl`)

Parse values and combine with topology.

```julia
read_leaf_values(::Type{T}, bytes, pos, codec, mask::LeafMask) ? Tuple{NTuple{512,T}, Int}
read_tile_value(::Type{T}, bytes, pos) ? Tuple{T, Int}

# Materialize full tree from topology + values
materialize_leaf(::Type{T}, topo::LeafTopology, values) ? LeafNode{T}
materialize_internal1(::Type{T}, topo::Internal1Topology, bytes, pos, codec) ? Tuple{InternalNode1{T}, Int}
materialize_internal2(::Type{T}, topo::Internal2Topology, bytes, pos, codec) ? Tuple{InternalNode2{T}, Int}
materialize_tree(::Type{T}, topo::RootTopology, bytes, pos, codec) ? Tuple{Tree{T}, Int}
```

**Tests required**:
- Float32, Float64, Vec3f value types
- Compressed vs uncompressed
- Sparse leaf (few active voxels)
- Dense leaf (all active)

---

### Step 8: Transforms (`src/Transforms.jl`, `test/test_transforms.jl`)

Coordinate transforms.

```julia
abstract type AbstractTransform end

struct LinearTransform <: AbstractTransform
    mat::NTuple{9, Float64}   # 3x3 rotation/scale
    trans::NTuple{3, Float64} # translation
end

struct UniformScaleTransform <: AbstractTransform
    scale::Float64
end

index_to_world(t::AbstractTransform, ijk::Coord) ? NTuple{3, Float64}
world_to_index(t::AbstractTransform, xyz::NTuple{3, Float64}) ? Coord
world_to_index_float(t::AbstractTransform, xyz::NTuple{3, Float64}) ? NTuple{3, Float64}
voxel_size(t::AbstractTransform) ? NTuple{3, Float64}

read_transform(bytes, pos) ? Tuple{AbstractTransform, Int}
```

**Tests required**:
- Identity
- Uniform scale
- Round-trip index?world?index

---

### Step 9: Grid (`src/Grid.jl`, `test/test_grid.jl`)

Grid wrapper.

```julia
@enum GridClass begin
    GRID_LEVEL_SET
    GRID_FOG_VOLUME
    GRID_STAGGERED
    GRID_UNKNOWN
end

struct Grid{T}
    name::String
    grid_class::GridClass
    transform::AbstractTransform
    tree::Tree{T}
end

read_grid(::Type{T}, bytes, pos, codec) ? Tuple{Grid{T}, Int}
```

---

### Step 10: File Parsing (`src/File.jl`, `test/test_file.jl`)

Top-level entry point.

```julia
struct VDBHeader
    format_version::UInt32
    library_major::UInt32
    library_minor::UInt32
    has_grid_offsets::Bool
    compression::Codec
    uuid::NTuple{16, UInt8}
end

struct GridDescriptor
    name::String
    grid_type::String
    instance_parent::String
    byte_offset::Int64
    block_offset::Int64
    end_offset::Int64
end

struct VDBFile
    header::VDBHeader
    grids::Vector{Grid}
end

const VDB_MAGIC = 0x56444220

read_header(bytes, pos) ? Tuple{VDBHeader, Int}
read_grid_descriptor(bytes, pos, has_offsets) ? Tuple{GridDescriptor, Int}
parse_vdb(bytes::Vector{UInt8}) ? VDBFile
parse_vdb(path::String) ? VDBFile
```

**Tests required**:
- Invalid magic ? error
- Unsupported version ? error
- Official sample files parse without error

---

### Step 11: Accessors (`src/Accessors.jl`, `test/test_accessors.jl`)

Tree queries.

```julia
get_value(tree::Tree{T}, c::Coord) ? T
is_active(tree::Tree{T}, c::Coord) ? Bool
active_voxel_count(tree::Tree{T}) ? Int
leaf_count(tree::Tree{T}) ? Int
active_bounding_box(tree::Tree{T}) ? Union{BBox, Nothing}

# Iteration
active_voxels(tree::Tree{T}) ? iterator of (Coord, T)
leaves(tree::Tree{T}) ? iterator of LeafNode{T}
```

**Tests required**:
- Query background (no nodes)
- Query tile value
- Query leaf value
- Query inactive voxel in leaf
- Counts match iteration

---

### Step 12: Interpolation (`src/Interpolation.jl`, `test/test_interpolation.jl`)

Sampling.

```julia
sample_nearest(tree::Tree{T}, ijk::NTuple{3,Float64}) ? T
sample_trilinear(tree::Tree{T}, ijk::NTuple{3,Float64}) ? T
sample_world(grid::Grid{T}, xyz::NTuple{3,Float64}; method=:trilinear) ? T

gradient(tree::Tree{T}, c::Coord) ? NTuple{3, T}
```

**Tests required**:
- At voxel center = voxel value
- At face center = mean of 2
- At edge center = mean of 4
- At corner = mean of 8
- Crosses leaf boundary

---

### Step 13: Ray Utilities (`src/Ray.jl`, `test/test_ray.jl`)

For volume rendering.

```julia
struct Ray
    origin::NTuple{3, Float64}
    direction::NTuple{3, Float64}
    inv_dir::NTuple{3, Float64}
end

Ray(origin, direction) ? Ray

intersect_bbox(ray::Ray, bbox::BBox) ? Union{Tuple{Float64, Float64}, Nothing}

# Yields (t_enter, t_exit, leaf) for each leaf the ray passes through
intersect_leaves(ray::Ray, tree::Tree{T}) ? iterator
```

**Tests required**:
- Miss
- Graze corner
- Through center
- Negative direction
- Axis-aligned ray

---

### Step 14: Integration Tests (`test/test_integration.jl`)

Download official samples from https://artifacts.aswf.io/io/aswf/openvdb/models/ and test.

```julia
# For each sample file:
# 1. Parse successfully
# 2. Compare grid names against expected
# 3. Compare active_voxel_count against reference
# 4. Compare bounding box against reference
# 5. Sample 100 random coords, verify against precomputed reference values
```

---

### Step 15: Property Tests (`test/test_properties.jl`)

Using PropCheck.jl or similar.

```julia
# Mask properties
@property ?m::Mask{N}: count_on(m) == length(collect(on_indices(m)))
@property ?m::Mask{N}, i: is_on(m,i) ? is_off(m,i)

# Coordinate properties
@property ?c::Coord: leaf_origin(c) + offset_to_coord(leaf_offset(c)) == c  # modulo leaf

# Tree properties
@property ?tree, c: is_active(tree,c) || get_value(tree,c) == tree.background || enclosing_tile_exists

# Interpolation
@property ?tree, c::Coord: sample_trilinear(tree, Float64.(c))  get_value(tree, c)
```

---

## Test Fixtures

Create `test/fixtures/` with:
- Hand-crafted minimal VDB files (hex dumps with comments)
- Reference values JSON for sample files
- Malformed files for error testing

## Verification Strategy

After each step:
1. Run `] test`  all tests pass
2. Check type stability: `@code_warntype` on key functions
3. No allocations in hot paths: `@allocated`

## Sample Files

Download from:
- https://artifacts.aswf.io/io/aswf/openvdb/models/bunny_cloud.vdb/1.0.0/bunny_cloud.vdb-1.0.0.zip
- https://artifacts.aswf.io/io/aswf/openvdb/models/smoke1.vdb/1.0.0/smoke1.vdb-1.0.0.zip
- https://artifacts.aswf.io/io/aswf/openvdb/models/torus.vdb/1.0.0/torus.vdb-1.0.0.zip

## Notes

- VDB format is little-endian throughout
- Positions are 1-indexed (Julia convention)
- File format reference: OpenVDB source `openvdb/io/File.cc`, `Archive.cc`
- Tree structure reference: `openvdb/tree/Tree.h`, `InternalNode.h`, `LeafNode.h`