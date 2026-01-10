# OpenVDB File Format Complete Specification

> **Document Version**: 1.0
> **Date**: 2026-01-10
> **Purpose**: Comprehensive specification of the OpenVDB binary file format across versions 220-224
> **Validated Against**: Official OpenVDB C++ source (v11.0, v12.0, v13.0), TinyVDBIO

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [File Format Versions](#2-file-format-versions)
3. [File Structure Overview](#3-file-structure-overview)
4. [Header Format](#4-header-format)
5. [Metadata Format](#5-metadata-format)
6. [Grid Descriptors](#6-grid-descriptors)
7. [Tree Structure](#7-tree-structure)
8. [Node Topology](#8-node-topology)
9. [Node Values](#9-node-values)
10. [Compression](#10-compression)
11. [Version-Specific Differences](#11-version-specific-differences)
12. [Implementation Reference](#12-implementation-reference)

---

## 1. Executive Summary

OpenVDB files use a hierarchical sparse data structure optimized for volumetric data storage. The file format has evolved through several versions, with **version 222 (NODE_MASK_COMPRESSION)** being the critical breaking point that fundamentally changed how leaf node values are stored.

### Critical Version Boundaries

| Version | Significance |
|---------|-------------|
| < 220 | Not supported by modern parsers |
| 220 | `SELECTIVE_COMPRESSION` - Global compression flag in header |
| 222 | `NODE_MASK_COMPRESSION` - **BREAKING CHANGE** - Per-node metadata byte, removed origin/buffer from leaf values |
| 223 | `BLOSC_COMPRESSION` - Added Blosc codec support |
| 224 | `MULTIPASS_IO` - Current version |

---

## 2. File Format Versions

### Complete Version Constant Table

| Value | Constant Name | Feature Description |
|-------|---------------|---------------------|
| 213 | `ROOTNODE_MAP` | Root node stored as map structure |
| 214 | `INTERNALNODE_COMPRESSION` | Internal node compression support |
| 215 | `SIMPLIFIED_GRID_TYPENAME` | Simplified grid type name strings |
| 216 | `GRID_INSTANCING` | Grid instancing support |
| 217 | `BOOL_LEAF_OPTIMIZATION` | Boolean leaf node optimization |
| 218 | `BOOST_UUID` | Boost UUID support |
| 219 | `NO_GRIDMAP` / `NEW_TRANSFORM` | Grid map removal, new transform format |
| **220** | **`SELECTIVE_COMPRESSION`** | **Selective compression introduced** |
| 221 | `FLOAT_FRUSTUM_BBOX` | Float frustum bounding box |
| **222** | **`NODE_MASK_COMPRESSION`** | **Node mask compression (BREAKING)** |
| 223 | `BLOSC_COMPRESSION` / `POINT_INDEX_GRID` | Blosc compression, point index grids |
| 224 | `MULTIPASS_IO` | Multi-pass I/O (current) |

**Source**: [OpenVDB version.h](https://www.sidefx.com/docs/hdk/openvdb_2version_8h.html)

---

## 3. File Structure Overview

```
+==========================================+
|              FILE HEADER                 |
|   Magic (8B) + Version (4B) + Flags      |
+==========================================+
|           FILE METADATA                  |
|   Count + Key-Value Pairs                |
+==========================================+
|          GRID DESCRIPTORS                |
|   Count + [Name, Type, Offsets]...       |
+==========================================+
|            GRID DATA                     |
|   For each grid:                         |
|   +---------------------------------+    |
|   | Grid Metadata                   |    |
|   | Transform                       |    |
|   | Tree Topology (depth-first)     |    |
|   | Tree Values (depth-first)       |    |
|   +---------------------------------+    |
+==========================================+
```

All integers are **Little-Endian**.

---

## 4. Header Format

### Binary Layout

```
Offset   Size    Type      Field
───────────────────────────────────────────
0x00     8       bytes     Magic Number: [0x20, 0x42, 0x44, 0x56, 0x00, 0x00, 0x00, 0x00]
                           (" BDV" + padding)
0x08     4       UInt32    File Format Version (e.g., 220, 222, 224)
0x0C     4       UInt32    Library Major Version (if version >= 211)
0x10     4       UInt32    Library Minor Version (if version >= 211)
0x14     1       UInt8     Has Grid Offsets (if version >= 212)
0x15     1       UInt8     Compression Flag (if 220 <= version < 222)
                           - 0 = None
                           - 1 = ZIP compression enabled
0x16     36      chars     UUID (ASCII, e.g., "550e8400-e29b-41d4-a716-446655440000")
```

### Version-Specific Header Fields

| Field | Version Range | Size | Notes |
|-------|---------------|------|-------|
| Library Version | >= 211 | 8 bytes | Major + Minor as UInt32 |
| Has Grid Offsets | >= 212 | 1 byte | Enables partial file reading |
| Global Compression | 220 <= v < 222 | 1 byte | File-wide compression flag |
| Per-Grid Compression | >= 222 | - | Stored per grid, not in header |

---

## 5. Metadata Format

### String Encoding

```
+------------------+------------------+
| Length (UInt32)  | String Data      |
| 4 bytes          | N bytes (no NUL) |
+------------------+------------------+
```

### Metadata Block

```
+--------------------+
| Entry Count (4B)   |
+--------------------+
| For each entry:    |
|  - Name (string)   |
|  - Type (string)   |
|  - Value (varies)  |
+--------------------+
```

### Common Metadata Types

| Type String | Value Format |
|-------------|--------------|
| `"string"` | Length-prefixed string |
| `"int32"` | 4-byte signed integer |
| `"int64"` | 8-byte signed integer |
| `"float"` | 4-byte IEEE 754 |
| `"double"` | 8-byte IEEE 754 |
| `"vec3i"` | 3 × Int32 |
| `"vec3s"` | 3 × Float32 |
| `"vec3d"` | 3 × Float64 |
| `"bool"` | 1-byte (0 or 1) |

### Required Grid Metadata

| Key | Type | Description |
|-----|------|-------------|
| `class` | string | Grid class: `"level set"`, `"fog volume"`, `"unknown"` |
| `file_compression` | string | Compression codec: `"none"`, `"zip"`, `"blosc"` |
| `is_saved_as_half_float` | bool | Half-precision storage flag |
| `name` | string | Grid name |

---

## 6. Grid Descriptors

### Per-Grid Descriptor

```
+------------------------+
| Unique Name (string)   |  e.g., "density[0]"
+------------------------+
| Grid Type (string)     |  e.g., "Tree_float_5_4_3"
+------------------------+
| Instance Parent (str)  |  Empty if not instanced
+------------------------+
| Grid Position (UInt64) |  Byte offset to grid data
+------------------------+
| Block Position (UInt64)|  Byte offset to block end
+------------------------+
| End Position (UInt64)  |  Byte offset to grid end
+------------------------+
```

### Grid Type String Format

```
Tree_{ValueType}_{Log2Dim1}_{Log2Dim2}_{Log2Dim3}[_{Codec}]
```

Examples:
- `Tree_float_5_4_3` - Standard float grid (32³→16³→8³ nodes)
- `Tree_float_5_4_3_HalfFloat` - Half-precision float grid
- `Tree_vec3s_5_4_3` - Vector3 float grid

---

## 7. Tree Structure

### Standard 5-4-3 Tree Hierarchy

```
                    RootNode
                   /    |    \
            InternalNode2 (5)     ← 32×32×32 children, 4096³ voxels each
           /      |      \
     InternalNode1 (4)          ← 16×16×16 children, 128³ voxels each
    /      |      \
  LeafNode (3)                  ← 8×8×8 voxels = 512 values
```

| Node Level | Log2Dim | Children | Total Voxels Spanned |
|------------|---------|----------|---------------------|
| Root | - | Variable (hash map) | Entire grid |
| Internal2 | 5 | 32³ = 32768 | 4096³ |
| Internal1 | 4 | 16³ = 4096 | 128³ |
| Leaf | 3 | 8³ = 512 | 8³ |

### Bit Index Calculation

For a coordinate `(x, y, z)` within a node:

```
bit_index = z | (y << log2dim) | (x << (log2dim * 2))
```

---

## 8. Node Topology

### Root Node Topology

```
+------------------------+
| Background Value (T)   |  Type-specific size
+------------------------+
| Tile Count (UInt32)    |  Number of root tiles
+------------------------+
| For each tile:         |
|  - Origin (3 × Int32)  |
|  - Value (T)           |
|  - Active (UInt8)      |
+------------------------+
| Child Count (UInt32)   |  Number of root children
+------------------------+
| For each child:        |
|  - Origin (3 × Int32)  |
|  - Child topology...   |  Recursive
+------------------------+
```

### Internal Node Topology

```
+------------------------+
| Child Mask             |  N bits (N = 2^(3*log2dim))
+------------------------+
| Value Mask             |  N bits
+------------------------+
| Tile Values (compressed)|  Via readCompressedValues()
+------------------------+
| For each child (DFS):  |
|  - Child topology...   |  Recursive
+------------------------+
```

**Mask sizes**:
- Internal2 (log2dim=5): 32768 bits = 4096 bytes = 512 UInt64
- Internal1 (log2dim=4): 4096 bits = 512 bytes = 64 UInt64

### Leaf Node Topology

```
+------------------------+
| Value Mask             |  512 bits = 64 bytes = 8 UInt64
+------------------------+
```

The value mask indicates which of the 512 voxels are "active".

---

## 9. Node Values

### Internal Node Values

Internal node tile values are read via `readCompressedValues()` during topology reading. The compression metadata system (see Section 10) handles inactive value reconstruction.

### Leaf Node Values - VERSION CRITICAL

#### v220-221 Format (Pre-NODE_MASK_COMPRESSION)

```
+---------------------------+
| Origin (3 × Int32 = 12B)  |  ← REDUNDANT (also in topology)
+---------------------------+
| Num Buffers (Int8 = 1B)   |  ← Always 1 in practice
+---------------------------+
| Raw Active Values         |  ← count_on(mask) × sizeof(T) bytes
|   (no compression meta)   |
+---------------------------+
```

**Total extra bytes per leaf**: 13 bytes

#### v222+ Format (NODE_MASK_COMPRESSION)

```
+---------------------------+
| Metadata Byte (UInt8)     |  ← Compression indicator (0-6)
+---------------------------+
| [Inactive Value 0]        |  ← Optional, depends on metadata
+---------------------------+
| [Inactive Value 1]        |  ← Optional, depends on metadata
+---------------------------+
| [Selection Mask]          |  ← Optional, 512 bits if metadata 3-5
+---------------------------+
| Compressed Active Values  |  ← Compressed data stream
+---------------------------+
```

### Compression Metadata Codes

| Code | Name | Inactive Val 0 | Inactive Val 1 | Selection Mask | Active Values |
|------|------|----------------|----------------|----------------|---------------|
| 0 | `NO_MASK_OR_INACTIVE_VALS` | - | - | No | Only active (count_on) |
| 1 | `NO_MASK_AND_MINUS_BG` | - | - | No | Only active (count_on) |
| 2 | `NO_MASK_AND_ONE_INACTIVE_VAL` | Read V0 | - | No | Only active (count_on) |
| 3 | `MASK_AND_NO_INACTIVE_VALS` | - | - | **Yes** | Only active (count_on) |
| 4 | `MASK_AND_ONE_INACTIVE_VAL` | Read V0 | - | **Yes** | Only active (count_on) |
| 5 | `MASK_AND_TWO_INACTIVE_VALS` | Read V0 | Read V1 | **Yes** | Only active (count_on) |
| **6** | **`NO_MASK_AND_ALL_VALS`** | - | - | No | **All 512 values** |

**Critical**: When metadata = 6, ALL 512 values are stored (not just active ones).

### Inactive Value Reconstruction

For metadata codes 0-5:
1. Start with background value from grid metadata
2. Apply inactive value overrides based on metadata code
3. Use selection mask (if present) to choose between two values for each inactive voxel

---

## 10. Compression

### Compressed Data Stream Format

**All versions use Int64 (8-byte) chunk sizes**.

```
+---------------------------+
| Chunk Size (Int64)        |  Signed!
|   > 0: Compressed size    |
|   < 0: |size| = raw bytes |
|   = 0: Empty              |
+---------------------------+
| Data (|size| bytes)       |
+---------------------------+
```

### Compression Flags (OR-able)

| Flag | Value | Description |
|------|-------|-------------|
| `COMPRESS_NONE` | 0x0 | No compression |
| `COMPRESS_ZIP` | 0x1 | ZLIB compression |
| `COMPRESS_ACTIVE_MASK` | 0x2 | Store only active values |
| `COMPRESS_BLOSC` | 0x4 | Blosc compression (v223+) |

### Codec Selection

```
If compression & COMPRESS_BLOSC:
    Use Blosc decompression
Else If compression & COMPRESS_ZIP:
    Use ZLIB decompression
Else:
    Read raw data
```

### Sign Convention for Chunk Size

```cpp
Int64 chunk_size;
read(&chunk_size, 8);

if (chunk_size < 0) {
    // Uncompressed: read abs(chunk_size) raw bytes
    read(data, -chunk_size);
} else if (chunk_size > 0) {
    // Compressed: read chunk_size bytes, then decompress
    read(compressed, chunk_size);
    decompress(compressed, data);
} else {
    // Empty chunk
}
```

---

## 11. Version-Specific Differences

### Summary Table

| Feature | v220 | v221 | v222+ |
|---------|------|------|-------|
| Global compression flag in header | Yes | Yes | No (per-grid) |
| Per-grid compression field | No | No | Yes (UInt32) |
| Leaf origin in values | Yes (12B) | Yes (12B) | No |
| Leaf numBuffers in values | Yes (1B) | Yes (1B) | No |
| Metadata byte per leaf | No | No | Yes (1B) |
| Selection mask support | No | No | Yes |
| Blosc compression | No | No | v223+ |

### Leaf Node Value Parsing Algorithm

```julia
function read_leaf_values(bytes, pos, version, mask, background, compression)
    if version < 222
        # v220/v221: Skip origin + numBuffers, read raw active values
        pos += 12  # Skip origin (3 × Int32)
        pos += 1   # Skip numBuffers (Int8)

        active_count = count_on(mask)
        values = read_raw_values(bytes, pos, active_count)
        pos += active_count * sizeof(T)

        # Scatter to full array, inactive = background
        result = fill(background, 512)
        for (i, bit) in enumerate(mask)
            if bit
                result[i] = values[popcount(mask[1:i-1])]
            end
        end
    else
        # v222+: Metadata byte + optional inactive values + compressed active
        metadata, pos = read_u8(bytes, pos)

        inactive0 = background
        inactive1 = -background  # For code 1

        if metadata == 2 || metadata == 4 || metadata == 5
            inactive0, pos = read_value(bytes, pos)
        end
        if metadata == 5
            inactive1, pos = read_value(bytes, pos)
        end

        selection_mask = nothing
        if metadata in [3, 4, 5]
            selection_mask, pos = read_mask(bytes, pos, 512)
        end

        if metadata == 6
            # All 512 values stored
            values, pos = read_compressed_values(bytes, pos, 512, compression)
        else
            # Only active values stored
            active_count = count_on(mask)
            active_values, pos = read_compressed_values(bytes, pos, active_count, compression)

            # Reconstruct full array
            result = Vector{T}(undef, 512)
            active_idx = 1
            for i in 1:512
                if is_on(mask, i)
                    result[i] = active_values[active_idx]
                    active_idx += 1
                else
                    # Inactive value selection
                    if selection_mask !== nothing && is_on(selection_mask, i)
                        result[i] = inactive1
                    else
                        result[i] = inactive0
                    end
                end
            end
        end
    end
    return (result, pos)
end
```

### Header Parsing Algorithm

```julia
function read_header(bytes)
    pos = 1

    # Magic number
    magic = bytes[pos:pos+7]
    @assert magic == [0x20, 0x42, 0x44, 0x56, 0x00, 0x00, 0x00, 0x00]
    pos += 8

    # File version
    file_version, pos = read_u32_le(bytes, pos)

    # Library version (v211+)
    if file_version >= 211
        major_version, pos = read_u32_le(bytes, pos)
        minor_version, pos = read_u32_le(bytes, pos)
    end

    # Grid offsets flag (v212+)
    if file_version >= 212
        has_grid_offsets, pos = read_u8(bytes, pos)
    end

    # Global compression (v220-v221 only)
    if file_version >= 220 && file_version < 222
        global_compression, pos = read_u8(bytes, pos)
    end

    # UUID (36 ASCII chars)
    uuid = String(bytes[pos:pos+35])
    pos += 36

    return (file_version, pos)
end
```

---

## 12. Implementation Reference

### Official OpenVDB C++ Sources

| File | Purpose | Key Functions |
|------|---------|---------------|
| `openvdb/io/Compression.h` | Compression enums & templates | `readCompressedValues()` |
| `openvdb/io/Compression.cc` | Compression codecs | `zipFromStream()`, `bloscFromStream()` |
| `openvdb/tree/LeafNode.h` | Leaf node I/O | `readTopology()`, `readBuffers()` |
| `openvdb/tree/InternalNode.h` | Internal node I/O | `readTopology()`, `readBuffers()` |
| `openvdb/tree/RootNode.h` | Root node I/O | `readTopology()`, `readBuffers()` |
| `openvdb/version.h` | Version constants | `OPENVDB_FILE_VERSION_*` |

### TinyVDBIO Reference

Single-header C++ implementation supporting v220-224:
- Repository: https://github.com/syoyo/tinyvdbio
- Key file: `tinyvdbio.h`

### Key Version Check in OpenVDB LeafNode.h (v11.0)

```cpp
int8_t numBuffers = 1;
if (io::getFormatVersion(is) < OPENVDB_FILE_VERSION_NODE_MASK_COMPRESSION) {
    // Read in the origin.
    is.read(reinterpret_cast<char*>(&mOrigin), sizeof(Coord::ValueType) * 3);
    // Read in the number of buffers, which should now always be one.
    is.read(reinterpret_cast<char*>(&numBuffers), sizeof(int8_t));
}
```

**Note**: This code was removed in OpenVDB v13.0 when support for pre-v222 files was dropped.

---

## References

1. [OpenVDB Official Documentation](https://www.openvdb.org/documentation/doxygen/)
2. [OpenVDB GitHub Repository](https://github.com/AcademySoftwareFoundation/openvdb)
3. [TinyVDBIO](https://github.com/syoyo/tinyvdbio)
4. [JangaFX VDB Deep Dive](https://jangafx.com/insights/vdb-a-deep-dive)
5. [SideFX HDK OpenVDB Headers](https://www.sidefx.com/docs/hdk/openvdb_2version_8h.html)
6. [OpenVDB Release Notes](https://academysoftwarefoundation.github.io/openvdb/changes.html)

---

## Document History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-10 | Initial comprehensive specification |
