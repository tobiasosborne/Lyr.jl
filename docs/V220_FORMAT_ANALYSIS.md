# OpenVDB v220 File Format Analysis

> **Date**: 2026-01-09
> **Purpose**: Document format differences between v220 and v222+ to fix bunny_cloud.vdb parsing
> **Related Issues**: `path-tracer-t0q`, `path-tracer-rhk`

## Executive Summary

The current Lyr.jl parser assumes v222+ format for all files. Version 220 files (like `bunny_cloud.vdb`) have a **fundamentally different leaf node layout** that includes 13 extra bytes per leaf node in the value section. This causes `BoundsError` when parsing because the position tracking drifts out of sync.

---

## OpenVDB File Format Versions

| Version | Constant Name | Feature Introduced |
|---------|---------------|-------------------|
| 213 | `ROOTNODE_MAP` | Root node as map structure |
| 214 | `INTERNALNODE_COMPRESSION` | Internal node compression |
| 215 | `SIMPLIFIED_GRID_TYPENAME` | Simplified grid type names |
| 216 | `GRID_INSTANCING` | Grid instancing support |
| 217 | `BOOL_LEAF_OPTIMIZATION` | Boolean leaf optimization |
| 218 | `BOOST_UUID` | Boost UUID support |
| 219 | `NO_GRIDMAP` / `NEW_TRANSFORM` | Grid map removal, new transforms |
| **220** | **`SELECTIVE_COMPRESSION`** | **Selective compression introduced** |
| 221 | `FLOAT_FRUSTUM_BBOX` | Float frustum bounding box |
| **222** | **`NODE_MASK_COMPRESSION`** | **Node mask compression (BREAKING CHANGE)** |
| 223 | `BLOSC_COMPRESSION` / `POINT_INDEX_GRID` | Blosc compression, point index grids |
| 224 | `MULTIPASS_IO` | Multi-pass I/O (current version) |

**Critical Boundary**: Version 222 (`NODE_MASK_COMPRESSION`) is the key transition point that changes the binary layout of leaf nodes.

---

## Detailed Format Differences

### 1. Leaf Node Value Section

#### v222+ Format (Current Parser Implementation)
```
+----------------------------------------------------------+
| Metadata Byte (1 byte)                                   |
|   - Indicates compression state for inactive values      |
|   - 7 possible states (NO_MASK_OR_INACTIVE_VALS, etc.)  |
+----------------------------------------------------------+
| [Optional] Inactive Value(s)                             |
|   - Depends on metadata byte                             |
+----------------------------------------------------------+
| [Optional] Selection Mask                                |
|   - For choosing between two inactive values             |
+----------------------------------------------------------+
| Compressed/Raw Active Values                             |
|   - Chunk size (Int64) + data, OR                        |
|   - Raw values if uncompressed                           |
+----------------------------------------------------------+
```

#### v220 Format (What bunny_cloud.vdb Uses)
```
+----------------------------------------------------------+
| Origin Coordinates (12 bytes)                            |
|   - 3 x Int32 (x, y, z)                                  |
|   - REDUNDANT: Also stored in topology section           |
+----------------------------------------------------------+
| Number of Buffers (1 byte)                               |
|   - Int8, always 1 in practice                           |
|   - Legacy field from multi-buffer era                   |
+----------------------------------------------------------+
| Raw Active Values ONLY                                   |
|   - No metadata byte                                     |
|   - No inactive value storage                            |
|   - Just the active voxel values in mask order           |
+----------------------------------------------------------+
```

**Key Difference**: v220 has **13 extra bytes** (12 + 1) at the start of each leaf's value section that v222+ does not have.

### 2. Internal Node Tile Values

#### v222+ Format
```
For each tile (set bit in value_mask):
+--------------------+-------------+
| Tile Value (4/8 B) | Active (1B) |
+--------------------+-------------+
```

#### v220 Format
```
For each tile (set bit in value_mask):
+--------------------+
| Tile Value (4/8 B) |  <-- NO active byte
+--------------------+
```

**Key Difference**: v220 does **not** store the active byte after each tile value.

### 3. Compressed Chunk Size

#### v222+ Format
```
+--------------------------+
| Chunk Size (Int64, 8 B)  |  <-- Signed, negative = uncompressed
+--------------------------+
| Data (abs(size) bytes)   |
+--------------------------+
```

#### v220 Format
```
+--------------------------+
| Chunk Size (Int32, 4 B)  |  <-- Signed, negative = uncompressed
+--------------------------+
| Data (abs(size) bytes)   |
+--------------------------+
```

**Key Difference**: Chunk size is **Int32 (4 bytes)** in v220, **Int64 (8 bytes)** in v222+.

---

## Current Parser Behavior vs Required Behavior

### `read_leaf_values` in `src/Values.jl`

**Current Code (line ~95)**:
```julia
if version < 222
    # v220: Raw active values, no metadata
    active_count = count_on(mask)
    active_values, pos = read_active_values(T, bytes, pos, active_count)
    # ... scatter to full array
end
```

**Required Change**:
```julia
if version < 222
    # v220: Origin + buffer count precede values
    # Skip origin (already have it from topology)
    _, pos = read_i32_le(bytes, pos)  # origin.x
    _, pos = read_i32_le(bytes, pos)  # origin.y
    _, pos = read_i32_le(bytes, pos)  # origin.z
    _, pos = read_u8(bytes, pos)       # num_buffers (always 1)

    # Now read raw active values
    active_count = count_on(mask)
    active_values, pos = read_active_values(T, bytes, pos, active_count)
    # ... scatter to full array
end
```

### `read_internal_tiles` in `src/TreeRead.jl`

**Current Code (line ~70)**:
```julia
function read_internal_tiles(::Type{T}, bytes, pos, mask)
    count = count_on(mask)
    vals = Vector{T}(undef, count)
    for i in 1:count
        vals[i], pos = read_tile_value(T, bytes, pos)
        _, pos = read_u8(bytes, pos)  # skip active_byte  <-- WRONG FOR v220
    end
    (vals, pos)
end
```

**Required Change**:
```julia
function read_internal_tiles(::Type{T}, bytes, pos, mask, version::UInt32)
    count = count_on(mask)
    vals = Vector{T}(undef, count)
    for i in 1:count
        vals[i], pos = read_tile_value(T, bytes, pos)
        if version >= 222
            _, pos = read_u8(bytes, pos)  # active_byte only in v222+
        end
    end
    (vals, pos)
end
```

### `read_compressed_bytes` in `src/Compression.jl`

**Current Code (line ~85)**:
```julia
function read_compressed_bytes(bytes, pos, codec, expected_size)
    chunk_size, pos = read_i64_le(bytes, pos)  # <-- WRONG FOR v220
    # ...
end
```

**Required Change**:
```julia
function read_compressed_bytes(bytes, pos, codec, expected_size, version::UInt32)
    chunk_size = if version < 222
        cs, pos = read_i32_le(bytes, pos)
        Int64(cs)
    else
        cs, pos = read_i64_le(bytes, pos)
        cs
    end
    # ...
end
```

---

## Test File Analysis

### bunny_cloud.vdb

```
Header bytes: 20 42 44 56 00 00 00 00 dc 00 00 00 ...
              " B  D  V"              ^^^^^^^^^^
                                     0x00DC = 220 (little-endian)
```

- **Version**: 220 (`SELECTIVE_COMPRESSION`)
- **Grid Type**: Float density grid (cloud/fog volume)
- **Compression**: Zlib (based on grid metadata)

### torus.vdb (existing test file)

- **Version**: 222 (`NODE_MASK_COMPRESSION`)
- **Status**: Pre-existing test failure (unrelated to v220 issue)

---

## Reference Implementations

### 1. Official OpenVDB (C++)

Repository: https://github.com/AcademySoftwareFoundation/openvdb

Key files:
- `openvdb/io/Compression.h` - Compression format handling
- `openvdb/tree/LeafNode.h` - `readBuffers()` function with version checks
- `openvdb/version.h` - Version constant definitions

### 2. TinyVDBIO (Header-only C++)

Repository: https://github.com/syoyo/tinyvdbio

- Explicitly supports v220-223
- Simpler codebase, easier to understand
- **Recommended** as primary reference for implementation

---

## Implementation Plan

### Phase 1: Core Format Fixes
1. Add `version` parameter to `read_internal_tiles`
2. Add `version` parameter to `read_compressed_bytes`
3. Fix chunk size reading (Int32 for v220, Int64 for v222+)
4. Remove active byte reading for v220 internal tiles

### Phase 2: Leaf Node Fixes
1. Add origin + buffer count skipping for v220 leaf values
2. Ensure topology-phase leaf mask reading is correct for both versions
3. Handle the absence of metadata byte in v220

### Phase 3: Testing
1. Verify bunny_cloud.vdb parses successfully
2. Verify existing v222+ files still work
3. Add explicit version-specific test cases

---

## Open Questions

1. **Topology section differences**: Are there any differences in how topology (masks) are stored between v220 and v222+? The previous agent's changes suggested moving leaf mask reading, but this may have been incorrect.

2. **Compression in v220**: Does v220 use the same compression indicators (negative chunk size = uncompressed)? The JangaFX article suggests a `u8 = 6` indicator for uncompressed data.

3. **Internal node origin**: Do internal nodes also store redundant origin data in v220?

---

## References

1. [OpenVDB version.h (Houdini HDK)](https://www.sidefx.com/docs/hdk/openvdb_2version_8h.html) - Version constants
2. [OpenVDB Compression.h](https://www.openvdb.org/documentation/doxygen/Compression_8h_source.html) - Compression handling
3. [OpenVDB LeafNode.h](https://www.openvdb.org/documentation/doxygen/LeafNode_8h_source.html) - Leaf node I/O
4. [TinyVDBIO](https://github.com/syoyo/tinyvdbio) - Reference implementation for v220-223
5. [JangaFX VDB Deep Dive](https://jangafx.com/insights/vdb-a-deep-dive) - Format documentation
6. [OpenVDB Release Notes](https://academysoftwarefoundation.github.io/openvdb/changes.html) - Version history
