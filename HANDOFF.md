# Lyr.jl Handoff Document

---

## Latest Session (2026-02-12) - Full Code Review + Values.jl Fix

**Status**: 🟡 IN PROGRESS - Values.jl rewritten, unit tests pass, cube.vdb still BoundsError

### Summary

Conducted full-scale code review with 9 parallel subagents (8 Sonnet + 1 Opus). Created comprehensive PRD at `PRD.md`. Then implemented the critical fix to `read_leaf_values` in `src/TinyVDB/Values.jl`.

### Key Finding

All 9 agents converged on the same diagnosis: **one function** (`read_leaf_values`) was the root cause. It was missing reads for `inactiveVal0`, `inactiveVal1`, and `selection_mask` after `per_node_flag`, and did not reconstruct the full 512-value buffer from compressed active-only data.

The Julia code was mirroring the **buggy** `ReadBuffer` from `reference/tinyvdbio.h` (line 2352). The **correct** algorithm is `ReadMaskValues` (line 2017).

### Changes Made

1. **`src/TinyVDB/Values.jl`** - Complete rewrite:
   - Removed duplicate constant definitions (now only in Topology.jl)
   - Added `background::Float32` parameter to `read_leaf_values` and `read_internal_values`
   - `read_tree_values` extracts background from `root.background`
   - Implemented full ReadMaskValues algorithm:
     - Reads `inactiveVal0` (conditional on flags 2, 4, 5)
     - Reads `inactiveVal1` (conditional on flag 5)
     - Reads `selection_mask` (conditional on flags 3, 4, 5)
     - Reconstructs full 512-value buffer with inactive value fill

2. **`test/test_tinyvdb.jl`** - Added tests:
   - Flag 0: inactive = +background (2 active values, verify inactive fill)
   - Flag 1: inactive = -background
   - Flag 2: one inactive val read from stream
   - Flag 3: selection mask with bg/-bg
   - Flag 5: two inactive vals + selection mask
   - End-to-end: cube.vdb integration test (currently failing)

3. **`PRD.md`** - Created comprehensive Product Requirements Document

### Test Results

```
Unit tests:  266 pass, 0 fail (up from 247)
  - All original tests still pass
  - 5 new mask compression tests pass
  - 1 new end-to-end test added (cube.vdb - still errors)
```

### Remaining Issue: cube.vdb BoundsError

The cube.vdb integration test still crashes with:
```
BoundsError: attempt to access 3862089-element Vector{UInt8} at index [3861793:3863072]
```

The crash happens at `Compression.jl:112` inside `read_leaf_values`. The Values.jl fix is correct (all synthetic unit tests pass), which means the stream position is **already wrong** when entering the last leaf nodes. The bug is likely in one of:

1. **`skip_mask_values` in Topology.jl** - May be skipping wrong number of bytes during internal node topology reading (this is the most likely cause since it mirrors the same ReadMaskValues algorithm)
2. **Some other upstream position error** - Could be in metadata, transform, or grid descriptor reading

### Next Steps (Priority Order)

1. **Debug the stream position drift** - Add position logging to trace where `pos` diverges from expected values during cube.vdb parsing. Compare against a C++ reference parse.
2. **Verify `skip_mask_values` in Topology.jl** - Compare byte-for-byte against the `ReadMaskValues` seek path in tinyvdbio.h (the `seek=true` code path)
3. **Consider dumping reference positions** - Write a small C++ program using tinyvdbio.h that prints stream positions at each node to compare against Julia

### Architecture Decision

**TinyVDB is the path forward.** The main Lyr implementation's offset-seeking approach is fundamentally fragile. Once TinyVDB parses correctly, promote it as the primary parser and layer Accessors/Interpolation/Ray/Render on top.

### Files Modified This Session

| File | Change |
|------|--------|
| `src/TinyVDB/Values.jl` | Complete rewrite with ReadMaskValues algorithm |
| `test/test_tinyvdb.jl` | +5 mask compression tests, +1 cube.vdb integration test |
| `PRD.md` | New - comprehensive project requirements document |

---

## Previous Session (2026-01-11) - TinyVDB Audit Progress

**Status**: 2/10 audits complete, Parser.jl fixed

### Fixes Applied

1. **Parser.jl `read_transform`** - Fixed case and byte count (120B not 12)
2. **Parser.jl `read_metadata`** - Added size prefixes
3. **Parser.jl `read_grid`** - Added buffer_count read

### Audit Issues Status

| Issue ID | File | Status |
|----------|------|--------|
| path-tracer-g73 | Binary.jl | ✅ CLOSED (PASS) |
| path-tracer-o0y | Parser.jl | ✅ CLOSED (4 bugs fixed) |
| path-tracer-2yl | Topology.jl | open (Int32/Int64 mismatch was fixed, but skip_mask_values may have position bugs) |
| path-tracer-31s | Values.jl | ✅ REWRITTEN this session |
| path-tracer-btf | Compression.jl | open (appears correct per review) |
| path-tracer-z0t | GridDescriptor.jl | open (appears correct per review) |
| path-tracer-dwx | Header.jl | open (minor: VDB_MAGIC constant wrong, unused) |
| path-tracer-5vr | Mask.jl | open (appears correct per review) |
| path-tracer-kck | Types.jl | open (appears correct per review) |
| path-tracer-3jb | TinyVDB.jl | open (module wrapper, fine) |
