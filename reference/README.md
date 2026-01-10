# OpenVDB C++ Reference Implementation

This folder contains key C++ source files from the official OpenVDB implementation
for reference when implementing the VDB parser.

## Files

| File | Source | Description |
|------|--------|-------------|
| `tinyvdbio.h` | [TinyVDBIO](https://github.com/syoyo/tinyvdbio) | Header-only VDB parser, supports v220-224 |
| `Compression.h` | OpenVDB master | Compression enums, metadata codes, templates |
| `Compression.cc` | OpenVDB master | ZLIB/Blosc codec implementations |
| `LeafNode.h` | OpenVDB master | Leaf node topology & value I/O |
| `InternalNode.h` | OpenVDB master | Internal node topology & value I/O |
| `RootNode.h` | OpenVDB master | Root node I/O |
| `io.h` | OpenVDB master | Stream I/O utilities |

## Key Code Locations

### Version Check for v220 vs v222+ (from OpenVDB v11.0 LeafNode.h)

```cpp
// In readBuffers():
int8_t numBuffers = 1;
if (io::getFormatVersion(is) < OPENVDB_FILE_VERSION_NODE_MASK_COMPRESSION) {
    // v220/v221: Read origin and buffer count
    is.read(reinterpret_cast<char*>(&mOrigin), sizeof(Coord::ValueType) * 3);
    is.read(reinterpret_cast<char*>(&numBuffers), sizeof(int8_t));
}
```

### Compression Metadata Codes (from Compression.h)

```cpp
enum {
    NO_MASK_OR_INACTIVE_VALS = 0,
    NO_MASK_AND_MINUS_BG = 1,
    NO_MASK_AND_ONE_INACTIVE_VAL = 2,
    MASK_AND_NO_INACTIVE_VALS = 3,
    MASK_AND_ONE_INACTIVE_VAL = 4,
    MASK_AND_TWO_INACTIVE_VALS = 5,
    NO_MASK_AND_ALL_VALS = 6
};
```

### Chunk Size (from Compression.cc)

```cpp
// Always Int64 (8 bytes), sign indicates compression state
Int64 numZippedBytes{0};
is.read(reinterpret_cast<char*>(&numZippedBytes), 8);
// Negative = uncompressed (abs value = size)
// Positive = compressed
```

## License

OpenVDB is licensed under the Mozilla Public License 2.0.
TinyVDBIO is licensed under the Mozilla Public License 2.0.

These files are included for reference purposes only.
