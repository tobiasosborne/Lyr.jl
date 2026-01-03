# VDB File Format Specification

**Status**: Verified against OpenVDB v12.0 source code.
**Authoritative Source**: `openvdb/io/Compression.cc`, `openvdb/tree/LeafNode.h`.

## 1. File Structure

A VDB file is a sequential binary stream containing:
1.  **Header**
2.  **File Metadata**
3.  **Grid Descriptors**
4.  **Grid Data** (Topology & Values)

All integers are **Little-Endian**.

## 2. Low-Level Primitives

### Compressed Data Streams
OpenVDB uses a uniform wrapper for compressed data chunks (ZLIB or BLOSC).
Every compressed chunk is prefixed by an **signed 64-bit integer** (`int64_t`) indicating its size.

| Size Value (`N`) | Meaning | Action |
|------------------|---------|--------|
| `N < 0` | **Uncompressed** | Read `abs(N)` bytes directly as raw data. |
| `N > 0` | **Compressed** | Read `N` bytes, then decompress (Inflate/Blosc). |
| `N = 0` | **Empty** | No data. |

*Note: This applies to `io::readData` when compression flags are active.*

## 3. Leaf Node Value Compression
Leaf nodes (typically 8x8x8 voxels) store their values in a highly optimized format. This data is read *after* the tree topology (masks) has been reconstructed.

### Format Layout
1.  **Compression Metadata** (`uint8_t`)
    -   Indicates how inactive values and background values are stored.
    -   Values: 0-6 (see table below).
2.  **Inactive Values** (Optional, 0-2 values)
    -   Stored as raw type `T` (e.g., `float`).
    -   Presence depends on Metadata.
3.  **Selection Mask** (Optional)
    -   Bitmask (`uint64_t` or 64 bytes) selecting between two inactive values.
    -   Present only if Metadata is 3, 4, or 5.
4.  **Active Values** (Variable size)
    -   Stored as a **Compressed Data Stream** (see above).
    -   Contains only the *active* voxels (where `value_mask` is ON).
    -   **Crucial**: If Metadata is 6 (`NO_MASK_AND_ALL_VALS`), *all* 512 values are stored here (active + inactive). Otherwise, only `count_on(value_mask)` values are stored.

### Compression Metadata Codes
| Code | Enum | Description | Inactive Val 0 | Inactive Val 1 | Selection Mask |
|------|------|-------------|----------------|----------------|----------------|
| 0 | `NO_MASK_OR_INACTIVE_VALS` | Inactive = Background | - | - | No |
| 1 | `NO_MASK_AND_MINUS_BG` | Inactive = -Background | - | - | No |
| 2 | `NO_MASK_AND_ONE_INACTIVE_VAL` | Inactive = V0 | Read V0 | - | No |
| 3 | `MASK_AND_NO_INACTIVE_VALS` | Mask selects -Bg / +Bg | - | - | **Yes** |
| 4 | `MASK_AND_ONE_INACTIVE_VAL` | Mask selects Bg / V0 | Read V0 | - | **Yes** |
| 5 | `MASK_AND_TWO_INACTIVE_VALS` | Mask selects V0 / V1 | Read V0 | Read V1 | **Yes** |
| 6 | `NO_MASK_AND_ALL_VALS` | All values stored in buffer | - | - | No |

## 4. Gap Analysis: OpenVDB vs VDB.jl

The following discrepancies have been identified between the specification and the current `VDB.jl` implementation:

| Feature | OpenVDB Spec | VDB.jl Implementation | Severity |
|---------|--------------|-----------------------|----------|
| **Compressed Size** | `Int64` (Signed). Negative = Uncompressed. | `UInt64` (Unsigned). No negative check? | **Critical** |
| **Inactive Values** | Read based on Metadata 0-6. | Implemented, but needs verification against specific codes (e.g. Code 2 reads 1 value). | High |
| **Active Count** | If Meta=6, count=512. Else count=`popcount(mask)`. | Logic appears to exist but relies on correct Metadata parsing. | Medium |

### Specific Bug in `torus.vdb`
The error `InexactError: convert(Int64, ...)` when reading `torus.vdb` is likely caused by:
1.  Reading the Size Prefix as `UInt64`.
2.  If the size is negative (uncompressed active values), it is interpreted as a huge positive number.
3.  Or, previous parsing of Inactive Values (Metadata 0-5) was incorrect, misaligning the stream so the "Size Prefix" read is actually garbage data.

## 5. Implementation Reference (C++)
*   **Leaf Reading**: `openvdb/tree/LeafNode.h` -> `readBuffers`
*   **Compression Logic**: `openvdb/io/Compression.h` -> `readCompressedValues`
*   **Stream IO**: `openvdb/io/Compression.cc` -> `bloscFromStream` / `unzipFromStream`