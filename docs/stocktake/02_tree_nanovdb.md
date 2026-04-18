# Stocktake: Tree, NanoVDB, Grid, Accessors, Builder, Pruning, Output

## File Purposes

| File | One-line purpose |
|---|---|
| `src/TreeTypes.jl` | Immutable algebraic types for the 4-level VDB tree hierarchy |
| `src/Grid.jl` | Thin wrapper combining a `Tree{T}` with transform and metadata |
| `src/GridBuilder.jl` | Bottom-up construction of a `Grid{T}` from a sparse `Dict{Coord,T}` |
| `src/Accessors.jl` | Tree queries, 3-level node cache, and lazy iterators (leaves, voxels) |
| `src/NanoVDB.jl` | Serialises the pointer tree into a single `Vector{UInt8}` for GPU transfer |
| `src/Pruning.jl` | Collapses uniform leaf nodes into constant-value tiles (lossless compression) |
| `src/Output.jl` | Writes pixel buffers to PPM / PNG / EXR; tone-mapping and denoisers |

---

## Public Exports / Key Types

**TreeTypes.jl**: `GridClass` (enum), `AbstractNode{T}`, `LeafNode{T}`, `Tile{T}`, `InternalNode1{T}`, `InternalNode2{T}`, `RootNode{T}`, `Tree{T}` (alias for `RootNode{T}`)

**Grid.jl**: `Grid{T, Tr}`, `read_grid`

**GridBuilder.jl**: `build_grid`

**Accessors.jl**: `ValueAccessor{T}`, `get_value`, `is_active`, `active_voxel_count`, `leaf_count`, `active_bounding_box`, `leaves`, `active_voxels`, `inactive_voxels`, `all_voxels`, `i1_nodes`, `i2_nodes`, `collect_leaves`, `foreach_leaf`

**NanoVDB.jl**: `NanoGrid{T}`, `NanoLeafView{T}`, `NanoInternalView{T,L}` (`NanoI1View`, `NanoI2View`), `NanoValueAccessor{T}`, `NanoVolumeRayIntersector{T}`, `NanoLeafHit{T}`, `build_nanogrid`, `get_value`, `get_value_trilinear`, `nano_background`, `nano_bbox`, `active_voxel_count`

**Pruning.jl**: `prune`

**Output.jl**: `write_ppm`, `write_png`, `write_exr`, `tonemap_reinhard`, `tonemap_aces`, `tonemap_exposure`, `auto_exposure`, `denoise_nlm`, `denoise_bilateral`

---

## Tree In-Memory Layout

The tree is a 4-level hierarchy, all nodes parametric on value type `T`:

```
RootNode{T}
  background::T
  children::Dict{Coord, InternalNode2{T}}   — root-level I2 children
  tiles::Dict{Coord, Tile{T}}               — root-level constant tiles

  InternalNode2{T}   (32³ = 32 768 slots, aligned to 4096-voxel boundaries)
    origin::Coord
    child_mask::Internal2Mask               — 512 UInt64 words
    value_mask::Internal2Mask
    children::Vector{InternalNode1{T}}      — sparse; indexed by child_mask popcount
    tiles::Vector{Tile{T}}

    InternalNode1{T}   (16³ = 4 096 slots, aligned to 128-voxel boundaries)
      origin::Coord
      child_mask::Internal1Mask             — 64 UInt64 words
      value_mask::Internal1Mask
      children::Vector{LeafNode{T}}         — sparse; indexed by child_mask popcount
      tiles::Vector{Tile{T}}

      LeafNode{T}   (8³ = 512 voxels)
        origin::Coord
        value_mask::LeafMask                — 8 UInt64 words
        values::NTuple{512, T}              — zero-alloc; immutable
```

`Tile{T}` (value, active::Bool) appears at every internal level to represent constant-filled regions. The entire tree is **immutable** — all operations return new trees.

Coordinate addressing: child indices into internal nodes are popcount-compressed. `count_on_before(mask, idx)` gives the 1-based index into the dense `children` or `tiles` vector.

---

## NanoVDB Flat-Buffer Layout

`NanoGrid{T}` wraps a single `Vector{UInt8}`. All inter-node references are `UInt32` byte offsets (1-indexed). `build_nanogrid` uses a two-pass algorithm: inventory pass (collect + size nodes), write pass (single allocation).

```
Byte offset (1-indexed)          Content
──────────────────────────────────────────────────────────────────────
1                                magic     UInt32 0x4E564442 "NVDB"
5                                version   UInt32 1
9                                value_size UInt32 sizeof(T)
13                               background T
13+sizeof(T)                     bbox_min  Coord (12 B)
25+sizeof(T)                     bbox_max  Coord (12 B)
37+sizeof(T)                     root_count UInt32
41+sizeof(T)                     i2_count   UInt32
45+sizeof(T)                     i1_count   UInt32
49+sizeof(T)                     leaf_count UInt32
53+sizeof(T)                     root_pos   UInt32  ← byte position of root table
57+sizeof(T)                     i2_pos     UInt32
61+sizeof(T)                     i1_pos     UInt32
65+sizeof(T)                     leaf_pos   UInt32
──────────────────────────────────────────────────────────────────────
[root_pos]   Root table: sorted by Coord (binary-searchable)
  Per entry (13 + sizeof(T) B):
    +0   origin    Coord (12 B)
    +12  is_child  UInt8
    +13  payload   T  (if tile) or UInt32 i2_byte_offset (if child)

[i2_pos]   I2 nodes (variable size):
  Per node:
    +0    origin     Coord (12 B)
    +12   child_mask 512 × UInt64 (4 096 B) + 512 × UInt32 prefix sums (2 048 B)
    +6156 value_mask 512 × UInt64 + 512 × UInt32 prefix sums
    +12300 child_count UInt32
    +12304 tile_count  UInt32
    +12308 [child_offsets: child_count × UInt32] [tile_values: tile_count × T]

[i1_pos]   I1 nodes (variable size):
  Per node:
    +0    origin     Coord (12 B)
    +12   child_mask 64 × UInt64 (512 B) + 64 × UInt32 prefix sums (256 B)
    +780  value_mask 64 × UInt64 + 64 × UInt32 prefix sums
    +1548 child_count UInt32
    +1552 tile_count  UInt32
    +1556 [child_offsets: child_count × UInt32] [tile_values: tile_count × T]

[leaf_pos]   Leaf nodes (fixed size = 76 + 512×sizeof(T) B):
  Per node:
    +0   origin     Coord (12 B)
    +12  value_mask 8 × UInt64 (64 B)  — NO prefix sums (direct popcount)
    +76  values     512 × T
```

Internal-node masks store precomputed `UInt32` prefix-sum arrays alongside the `UInt64` words. This allows O(1) `count_on_before(mask, idx)` without scanning preceding words — critical for the hot `get_value` path.

---

## Grid vs NanoGrid

`Grid{T}` is the **authoritative source of truth**: parsed from disk, built by `GridBuilder`, mutated by CSG/field ops, and pruned. It owns the pointer-based tree.

`NanoGrid{T}` is a **derived, read-only render artefact**: produced by `build_nanogrid(grid.tree)` immediately before rendering. It is never written back to `Grid`. The renderer (`VolumeHDDA`, ray integrators) operates exclusively on `NanoGrid` through `NanoValueAccessor` and `NanoVolumeRayIntersector`.

Conversion (`build_nanogrid`): inventory pass collects all nodes in BFS order, assigns byte offsets, then a single `Vector{UInt8}` allocation is filled sequentially. Root table is lexicographically sorted for binary search.

---

## Accessor Caching Strategy

### `ValueAccessor{T}` (pointer tree)
Stores three cached node pointers and their origins:
- `leaf::Union{LeafNode{T},Nothing}` + `leaf_origin::Coord`
- `i1::Union{InternalNode1{T},Nothing}` + `i1_origin::Coord`
- `i2::Union{InternalNode2{T},Nothing}` + `i2_origin::Coord`

Lookup checks leaf origin first (O(1) NTuple index), then I1, then I2, falling back to full root hash-map traversal. For spatially coherent access (trilinear interp, ray march), 7 of 8 lookups hit the leaf cache — claimed 5–8× speedup.

### `NanoValueAccessor{T}` (flat buffer)
Mirrors the same 3-level strategy but caches **byte offsets** (`Int`) rather than pointers:
- `leaf_offset::Int` (0 = uncached) + `leaf_origin::Coord`
- `i1_offset::Int` + `i1_origin::Coord`
- `i2_offset::Int` + `i2_origin::Coord`

Trilinear interpolation (`get_value_trilinear`) has a fast path: when all 8 corner voxels lie in the same leaf (true ~70–85% of samples), it reads all 8 values directly from the cached leaf buffer position without any mask checks.

`reset!(acc)` zeroes offsets, allowing accessor reuse between rays.

---

## GridBuilder API

`build_grid(data::Dict{Coord,T}, background::T; name, grid_class, voxel_size) -> Grid{T}`

Bottom-up 4-step construction:
1. Group voxels by `leaf_origin(coord)` → build `LeafNode{T}` (NTuple{512,T} + bitmask)
2. Group leaves by `internal1_origin` → build `InternalNode1{T}` (child_mask only, no tiles)
3. Group I1s by `internal2_origin` → build `InternalNode2{T}` (child_mask only, no tiles)
4. Wrap in `RootNode{T}` → `Grid{T}` with `UniformScaleTransform(voxel_size)`

`_build_mask` constructs masks from 0-based bit-index lists. All vectors are sorted by child index before building masks so popcount-indexing is consistent. `copy_from_dense` (referenced in CLAUDE.md) is not in this file — it lives elsewhere.

---

## Pruning

`prune(grid; tolerance=zero(T)) -> Grid{T}`

Traverses I2 → I1 → Leaf. For each leaf whose `max(values) - min(values) <= tolerance`, replaces it with a `Tile{T}(first_value, any_active)` in the parent I1. New child/tile vectors and masks are rebuilt from scratch with correct popcount ordering. The I2 `child_mask`/`value_mask` are **not** updated (the I2 still thinks it has the same number of I1 children — the compression happens at the I1→Leaf boundary only).

Called explicitly by users; not called automatically during build or NanoVDB conversion. Tolerance defaults to exact equality, useful for SDF constant-background regions.

---

## Output

Three image formats, all from a `Matrix{NTuple{3,T}}` pixel buffer:

- **PPM**: Always available. Binary P6, `write_ppm`. No dependencies.
- **PNG**: Requires `PNGFiles.jl` loaded into the session (`using PNGFiles` before `using Lyr`). `write_png` applies gamma correction (default 2.2). Falls back to PPM with a `@warn` if the module is absent.
- **EXR**: Requires `OpenEXR.jl`. `write_exr` preserves linear light; supports optional depth channel. Same PPM fallback pattern.

Both optional formats are detected at runtime via `_find_loaded_module(name::Symbol)` scanning `Base.loaded_modules` — no static dependency in `Project.toml`.

**Tone mapping**: `tonemap_reinhard` (x/(1+x)), `tonemap_aces` (Narkowicz filmic), `tonemap_exposure` (1−exp(−x·e)), `auto_exposure` (log-average luminance).

**Denoising**: `denoise_nlm` (non-local means, threaded, good for MC noise) and `denoise_bilateral` (edge-stopping, ~400× faster, less effective on MC). Both multithreaded via `Threads.@threads`.

**Smell**: the fallback from `.png`/`.exr` to `.ppm` silently changes the output filename via `replace(path, ".png" => ".ppm")`, which can surprise callers who check for the requested file. No error is raised — only a `@warn`.
