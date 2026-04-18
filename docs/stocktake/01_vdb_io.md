# VDB I/O Layer — Architectural Stocktake

## 1. File-by-File Purpose and Exports

### Production parser (`src/`)

| File | One-line purpose | Key exports / types |
|------|-----------------|---------------------|
| `VDBConstants.jl` | Shared integer constants for compression flags and version thresholds | `VDB_COMPRESS_NONE/ZIP/ACTIVE_MASK/BLOSC`, `VDB_FILE_VERSION_NODE_MASK_COMPRESSION` (222) |
| `Exceptions.jl` | Typed exception hierarchy for parse and compression errors | `LyrError`, `ParseError`, `InvalidMagicError`, `FormatError`, `UnsupportedVersionError`, `CompressionError`, `ChunkSizeMismatchError`, `CompressionBoundsError`, `DecompressionSizeError`, `ValueCountError` |
| `Binary.jl` | Zero-copy little-endian primitive readers; all `(bytes, pos) → (val, pos)` | `read_le`, `read_u8/u32/u64/i32/i64/f16/f32/f64_le`, `read_bytes`, `read_cstring`, `read_string_with_size`, `_unaligned_load` |
| `BinaryWrite.jl` | Exact write-side inverse of `Binary.jl`; writes to any `IO` | `write_u8!/u32/u64/i32/i64/f16/f32/f64_le!`, `write_bytes!`, `write_cstring!`, `write_string_with_size!`, `write_tile_value!` |
| `Compression.jl` | Codec abstraction wrapping Blosc.jl and CodecZlib.jl | `Codec`, `NoCompression`, `BloscCodec`, `ZipCodec`, `decompress`, `compress`, `read_compressed_bytes` |
| `Masks.jl` | Immutable fixed-size bitmasks with O(1) prefix-sum popcount | `Mask{N,W}`, `LeafMask`, `Internal1Mask`, `Internal2Mask`, `is_on/off`, `count_on/off`, `count_on_before`, `on_indices`, `off_indices`, `read_mask` |
| `Coordinates.jl` | 3D integer coordinates, bounding boxes, and tree-level alignment helpers | `Coord`, `coord`, `BBox`, `contains`, `intersects`, `leaf_origin`, `internal1_origin`, `internal2_origin`, `leaf_offset`, `internal1_child_index`, `internal2_child_index`, `LEAF_DIM/LOG2`, `INTERNAL1_DIM/LOG2`, `INTERNAL2_DIM/LOG2` |
| `ChildOrigins.jl` | Compute child node origins from parent origin + linear child index | `child_origin_internal2`, `child_origin_internal1` |
| `Header.jl` | Magic-number check, version branching, and codec selection for file header | `VDB_MAGIC`, `VDBHeader`, `read_header` |
| `Metadata.jl` | File-level skip and per-grid typed metadata parsing | `skip_file_metadata`, `read_grid_metadata` |
| `GridDescriptor.jl` | Grid name / type / offset descriptor and value-type dispatch | `GridDescriptor`, `read_grid_descriptor`, `parse_value_type` |
| `Transforms.jl` | Index↔world coordinate transforms; reads `UniformScaleMap`, `ScaleMap`, `ScaleTranslateMap` | `AbstractTransform`, `LinearTransform`, `UniformScaleTransform`, `index_to_world`, `world_to_index`, `world_to_index_float`, `voxel_size`, `read_transform` |
| `Values.jl` | `ReadMaskValues` decode algorithm for leaf and internal node values; half-precision support | `read_dense_values`, `read_leaf_values`, `read_tile_value`, `read_active_values`, `_read_value` |
| `TreeRead.jl` | Two-phase tree deserialiser; dispatches v222+ vs pre-v222; produces `RootNode{T}` | `read_tree`, `read_tree_v222`, `read_tree_interleaved`, `I2TopoData{T}`, `I1TopoData{T}`, `I2TopoDataV220{T}`, `LeafTopoWithSelection` |
| `File.jl` | Top-level `parse_vdb`; orchestrates header → metadata → grids; mmap support | `VDBFile`, `parse_vdb` |
| `FileWrite.jl` | Round-trip writer producing v224 files with offset patching | `write_vdb`, `write_vdb_to_buffer`, `write_tree!`, `write_transform!`, `write_header!`, `write_metadata!`, `grid_type_string`, `grid_class_string` |

### TinyVDB oracle (`src/TinyVDB/`)

| File | One-line purpose | Key exports / types |
|------|-----------------|---------------------|
| `TinyVDB.jl` | Module root; re-includes `VDBConstants.jl`; defines isolated exception types | `FormatError`, `UnsupportedVersionError` |
| `Types.jl` | Core structs for the oracle's tree representation | `Coord`, `VDBHeader`, `NodeType` |
| `Masks.jl` | Mutable `NodeMask` backed by `Vector{UInt64}` | `NodeMask`, `is_on`, `set_on!`, `count_on`, `read_mask` |
| `Binary.jl` | Lean LE readers (same signatures, `unsafe_load` instead of memcpy) | `read_u8/u32/i32/u64/i64/f32/f64`, `read_string` |
| `Header.jl` | Raw-byte magic check; stores `data_pos` in header for offset arithmetic | `read_header` |
| `GridDescriptor.jl` | Grid descriptor with name-suffix stripping and half-float detection | `GridDescriptor`, `read_grid_descriptor`, `read_grid_descriptors`, `strip_suffix`, `strip_half_float_suffix` |
| `Compression.jl` | ZIP-only compressed data reader; rejects Blosc explicitly | `read_grid_compression`, `read_compressed_data`, `read_f32_values`, `read_float_values` |
| `Topology.jl` | Two-pass topology reader producing mutable `RootNodeData` / `InternalNodeData` / `LeafNodeData` | `LeafNodeData`, `InternalNodeData`, `RootNodeData`, `read_leaf_topology`, `read_internal_topology`, `read_root_topology`, `skip_mask_values` |
| `Values.jl` | Buffer-pass value reader; fills leaves with full 512-element `Vector{Float32}` | `read_leaf_values`, `read_internal_values`, `read_tree_values` |
| `Parser.jl` | Entry point; produces `TinyVDBFile` / `TinyGrid`; only `Tree_float_5_4_3` grids | `parse_tinyvdb`, `TinyVDBFile`, `TinyGrid`, `read_metadata`, `read_transform`, `read_grid` |

---

## 2. Byte Flow: File to Tree

```
.vdb file
   │
   ├─ [1..8]   magic (4B) + padding (4B)          ← Header.jl:read_header
   ├─ [9..16]  format_version + library versions
   ├─ [17]     has_grid_offsets flag (v212+)
   ├─ (v220-221) global compression byte
   ├─ [..36B]  UUID
   ├─ [v222+]  (no global compression — per-grid instead)
   │
   ├─ File-level metadata                          ← Metadata.jl:skip_file_metadata
   │
   ├─ grid_count (u32)
   └─ For each grid:
         GridDescriptor (name, grid_type, offsets) ← GridDescriptor.jl
         [v222+] compression flags (u32)           ← File.jl
         Per-grid metadata                         ← Metadata.jl:read_grid_metadata
         Transform                                 ← Transforms.jl:read_transform
         buffer_count (u32)
         background value (sizeof T)
         ┌─ Tree topology+values section ──────────── TreeRead.jl:read_tree
         │   Phase 1 (all I2 children):
         │     I2 origin (3×i32)
         │     I2 child_mask (4096B)               ← Masks.jl:read_mask
         │     I2 value_mask (4096B)
         │     [v222+] ReadMaskValues data          ← Values.jl:read_dense_values
         │     For each I1 child:
         │       I1 child_mask (512B) + value_mask
         │       [v222+] ReadMaskValues data
         │       For each leaf: value_mask (64B)
         │   Phase 2 (all leaves, v222+):
         │     per-leaf: value_mask(64B) + metadata byte + values
         └─ → RootNode{T} in memory
```

---

## 3. TinyVDB vs Main Parser

| Dimension | Main Lyr | TinyVDB |
|-----------|----------|---------|
| Value types | `Float32`, `Float64`, `NTuple{3,Float32}`, Int32, Int64, Bool | `Float32` only |
| Compression | Blosc + Zlib + None | Zlib + None (Blosc throws `FormatError`) |
| Mask type | `Mask{N,W}` — immutable `NTuple{W,UInt64}` with prefix sums | `NodeMask` — mutable `Vector{UInt64}`, no prefix sums |
| Node structs | Immutable `LeafNode{T}`, `InternalNode1/2{T}`, `RootNode{T}` | Mutable `LeafNodeData`, `InternalNodeData`, `RootNodeData` |
| Version support | v220+ (two format paths) | v220+ (same paths, no ScaleMap variants missed) |
| Read strategy | Builds typed Julia structs with O(1) mask access directly | Intermediate mutable representation; converted by bridge |
| Tile values | Fully extracted; tiles stored as `Tile{T}` in node tables | v222+ tile values skipped during topology (`skip_mask_values`) |
| Half-precision | Full support in reader and writer | Read-side support (Float16 → Float32 widening) |
| mmap support | Yes (`Mmap.mmap`) | No — always `read(filepath)` |

**Duplicated logic**: Both parsers independently implement: LE primitives, mask reading, header parsing, metadata skipping, transform parsing, the two-phase topology/value loop, `ReadMaskValues` (metadata byte 0–6 decode), and half-precision widening. The only shared code is `VDBConstants.jl` (included by both).

**Test bridge** (`test/TinyVDBBridge.jl`): Converts `TinyVDB.RootNodeData` → `RootNode{Float32}` by walking the mutable tree and constructing immutable Lyr nodes. `NodeMask.words` is lifted to `NTuple` for `Mask{N,W}`. Children are sorted by linear index before conversion so popcount-based table indexing is correct. Used in equivalence tests that parse the same file with both parsers and compare voxel-by-voxel.

---

## 4. Compression Pipelines

### v220–221 (global compression)
Header byte: 0 = none, non-zero = ZIP. `VDB_COMPRESS_ACTIVE_MASK` always set.
No Blosc in these versions. No per-grid flags.

### v222+ (per-grid compression)
4-byte flags word immediately after `GridDescriptor`:
- bit 0 (`0x01`) → Zlib
- bit 1 (`0x02`) → `COMPRESS_ACTIVE_MASK` (sparse active-value storage)
- bit 2 (`0x04`) → Blosc

**Compressed block wire format** (`Compression.jl:read_compressed_bytes`):
```
Int64 chunk_size | data bytes
  chunk_size == 0  → empty block
  chunk_size  < 0  → |chunk_size| raw (uncompressed) bytes
  chunk_size  > 0  → chunk_size compressed bytes → decompress
```
`NoCompression` codec has no size prefix at all — raw bytes only.

**`COMPRESS_ACTIVE_MASK`** (ReadMaskValues): Leaf data may store only active-voxel values. Decoder reads metadata byte (0–6), optional inactive scalars, optional 64-byte selection mask, then expands sparse active values back to full 512 using the value_mask + selection_mask.

**Half-precision**: `value_size=2` threads through `read_leaf_values` and `read_dense_values`; each stored Float16 is widened to `T` on load. The grid type string carries `_HalfFloat` suffix as the flag.

---

## 5. Tech Debt / Smells

1. **Massive duplication between parsers.** Every subsystem is re-implemented: LE readers, mask reader, header, metadata, transforms, ReadMaskValues, half-precision. Only `VDBConstants.jl` is shared. The oracle could be thinner if it shared `Binary.jl` and `Masks.jl` from the production parser.

2. **TinyVDB `Binary.jl` uses `unsafe_load` on unaligned pointers** (`Ptr{UInt32}(pointer(...))`, `Ptr{Float32}(...)` etc.) — undefined behaviour on strict-alignment architectures (ARM). The production `Binary.jl` avoids this correctly with `memcpy` via `_unaligned_load`. The test oracle is only ever run on x86-64, but it is a latent portability bug.

3. **`VDBFile` hard-codes the union type** (`Vector{Union{Grid{Float32}, Grid{Float64}, Grid{NTuple{3, Float32}}}}`). Int32, Int64, and Bool grids are parsed but silently `@warn`-skipped in `File.jl:parse_vdb` (line 109). They can be round-trip written via `write_vdb` (grid type strings exist) but cannot be read back. The union type would need to widen or `VDBFile` should become parametric.

4. **`FileWrite.jl` always uses a placeholder-then-patch strategy** for grid offsets (seek + write + seek-back). For multi-grid files this requires a seekable `IO`. Writing to a non-seekable stream (e.g. network socket) would fail silently or produce corrupted offsets.

5. **`Transforms.jl:read_transform` and `TinyVDB/Parser.jl:read_transform`** share identical offset arithmetic but have separate implementations. A full affine `LinearTransform` (non-diagonal rotation) is rejected at write time with `ArgumentError` (`FileWrite.jl:198`) — no graceful degradation.

6. **`I2TopoDataV220.children`** stores a 5-tuple `(Coord, Internal1Mask, Internal1Mask, Vector{Tuple{Coord,LeafMask}}, Vector{T})` — an anonymous tuple with no named fields (`TreeRead.jl:265`). This is fragile: reordering silently breaks the destructure on line 347.

7. **TinyVDB `GridDescriptor` stores `unique_name` and `grid_name`** but the main `GridDescriptor` only has `name`. The suffix-stripping and disambiguation logic lives only in TinyVDB, meaning the production parser silently ignores grid name disambiguation (possible collision if a file has two grids with the same base name but different suffixes).

8. **Magic number comparison difference**: Main parser reads 4-byte LE u32 (`Header.jl:6 VDB_MAGIC = 0x56444220`); TinyVDB compares 8 raw bytes (`Header.jl:8 VDB_MAGIC_BYTES`). Both are correct but fragile if the padding bytes are ever non-zero in a future format revision.
