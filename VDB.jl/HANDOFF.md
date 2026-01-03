# VDB.jl Handoff Document

## Latest Session (2026-01-03 Session 7) - v220 Support & bunny_cloud.vdb Progress

**Status**: Fixed metadata parsing and root alignment for `bunny_cloud.vdb` (v220). Parsing now reaches Leaf Values.

### Commits
- `fix`: v220 support (metadata, bg_active, internal tiles)

### Issues Resolved
1. **path-tracer-8ct**: `bunny_cloud.vdb` BoundsError in metadata parsing
   - **FIXED**: Implemented greedy metadata parsing to handle uncounted entries (like `is_local_space`) and non-prefixed keys in v220.

### Issues Created
1. **path-tracer-rhk** [P1] `bunny_cloud.vdb` parsing fails in Leaf Values (Uncompressed chunk size mismatch)
   - Parsing now fails deep in the tree reading Leaf Values.
   - Likely cause: Alignment issue or incorrect Leaf Value compression assumption for v220.
2. **path-tracer-tka** [P2] Refactor File.jl into smaller modular units
   - Split `File.jl` into `Header.jl`, `Metadata.jl`, `Transform.jl`, etc.

### Key Technical Findings (v220 vs v222)
1. **Grid Metadata**:
   - Keys are NOT size-prefixed (raw ASCII).
   - `metadata_count` may exclude "standard" metadata (class, name, stats, etc.), so parsing must be greedy.
2. **Root Node**:
   - Does **NOT** have `background_active` byte (unlike v222 Fog Volumes).
3. **Internal Node Tiles**:
   - Appear to be **Uncompressed** in v220 (or use implicit background for empty masks).
   - Currently using `NoCompression` for tiles if v<222.

### Current State
- `smoke.vdb` (v222): **PASS** (5/5 tests).
- `torus.vdb` (v222): **FAIL** (Uncompressed chunk size mismatch: expected 232, got 1).
- `bunny_cloud.vdb` (v220): **FAIL** (Uncompressed chunk size mismatch: expected 32, got 1107885508333142016).

### Next Steps
1. **Debug `bunny_cloud.vdb` Leaf Values**:
   - Investigate why `read_leaf_values` (ZipCodec) reads garbage chunk size.
   - Verify if Internal Tiles consume 0, 1, or more bytes in v220.
2. **Debug `torus.vdb`**:
   - Error: `expected 232, got 1`. Chunk size 1 is weird for a compressed stream or raw chunk.
3. **Refactor `File.jl`**:
   - Break down the massive `File.jl` to improve maintainability.
