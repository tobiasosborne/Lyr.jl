# Lyr.jl — Product Requirements Document

## Status: 85% Complete. Do NOT start from scratch.

**Date:** 2026-02-12
**Scope:** TinyVDB parser — minimal, correct VDB file reader

---

## 1. Executive Summary

Lyr.jl is a pure Julia OpenVDB file format parser. The project has two implementations:

| Implementation | LOC | Status |
|---|---|---|
| **Main (src/*.jl)** | ~2,800 | Functional but has offset bugs on real files |
| **TinyVDB (src/TinyVDB/*.jl)** | ~1,400 | 247 unit tests pass; crashes on real VDB files |

The main implementation works for synthetic data but fails on real VDB files due to an architectural flaw (seeks to `block_offset` instead of reading sequentially). TinyVDB was created to fix this by following the C++ reference's sequential reading approach.

**TinyVDB is the path forward.** It has one critical bug: `read_leaf_values` in `Values.jl` does not read `inactiveVal0`, `inactiveVal1`, or `selection_mask` after `per_node_flag`, and does not reconstruct the full 512-value buffer from compressed active-only data. This causes stream position corruption when parsing real VDB files.

Fixing this bug (~40 lines of code) unblocks the entire project.

---

## 2. Architecture

### 2.1 Module Structure (TinyVDB)

```
src/TinyVDB/
├── TinyVDB.jl        ✅ Module root (includes + exports)
├── Binary.jl         ✅ Primitives: u8, u32, i32, i64, f32, f64, string
├── Types.jl          ✅ Coord, VDBHeader, NodeType enum
├── Mask.jl           ✅ NodeMask: is_on, set_on!, count_on, read_mask
├── Header.jl         ✅ read_header, VDB_MAGIC
├── GridDescriptor.jl ✅ read_grid_descriptor, read_grid_descriptors
├── Compression.jl    ✅ read_compressed_data, read_f32_values
├── Topology.jl       ✅ read_root/internal/leaf_topology, skip_mask_values
├── Values.jl         🐛 read_leaf_values (THE BUG), read_tree_values
└── Parser.jl         ✅ read_metadata, read_transform, parse_tinyvdb
```

### 2.2 Reading Flow

```
parse_tinyvdb(filepath)
  ├── read(filepath) → bytes
  ├── read_header(bytes, 1) → (header, pos)
  ├── read_metadata(bytes, pos) → pos          # file-level metadata
  ├── read_grid_descriptors(bytes, pos) → (descriptors, pos)
  └── for each descriptor:
      └── read_grid(bytes, gd, file_version) → TinyGrid
          ├── seek to gd.grid_pos
          ├── read_grid_compression → compression_flags
          ├── read_metadata (skip)
          ├── read_transform (skip)
          ├── read_i32 → buffer_count (must be 1)
          ├── read_root_topology    ──┐
          │   ├── background, tiles   │ Phase 1: Topology
          │   └── read_internal_topology (recursive)
          │       ├── child_mask, value_mask
          │       ├── skip_mask_values ← (correctly skips inactive vals)
          │       └── read_leaf_topology
          │           └── value_mask  ─┘
          └── read_tree_values      ──┐
              └── read_internal_values │ Phase 2: Values
                  └── read_leaf_values ← 🐛 THE BUG
                      └── (broken)   ─┘
```

### 2.3 VDB Tree Hierarchy

```
RootNode (hash map)
  └── InternalNode2 (32³ = 32768 slots, log2dim=5)
       └── InternalNode1 (16³ = 4096 slots, log2dim=4)
            └── LeafNode (8³ = 512 voxels, log2dim=3)
```

---

## 3. The Bug

### 3.1 Location

`src/TinyVDB/Values.jl`, function `read_leaf_values` (lines 55-86).

### 3.2 Root Cause

The current implementation mirrors the **buggy** `ReadBuffer` function from `reference/tinyvdbio.h` (line 2352), which itself is incomplete. The **correct** algorithm is `ReadMaskValues` (line 2017), used for internal node tile values.

The C++ `ReadBuffer` for leaf nodes:
1. Skips value_mask (already read in topology)
2. Reads per_node_flag
3. Computes read_count
4. **Calls `ReadValues` (thin wrapper)** — does NOT read inactive values or selection_mask

The C++ `ReadMaskValues` (the correct algorithm):
1. Reads per_node_flag
2. **Reads inactiveVal0** (conditional on flag)
3. **Reads inactiveVal1** (conditional on flag)
4. **Reads selection_mask** (conditional on flag)
5. Computes read_count
6. Reads compressed data into temp buffer
7. **Reconstructs full N-value buffer** using value_mask + selection_mask + inactive values

### 3.3 What's Missing in Julia

The current `read_leaf_values`:
```julia
# ❌ Current (broken)
function read_leaf_values(bytes, pos, leaf, file_version, compression_flags)
    pos += 64                                    # skip value_mask
    per_node_flag, pos = read_u8(bytes, pos)     # read flag
    # MISSING: read inactiveVal0
    # MISSING: read inactiveVal1
    # MISSING: read selection_mask
    read_count = mask_compressed ? count_on(leaf.value_mask) : 512
    values, pos = read_f32_values(bytes, pos, read_count, compression_flags)
    leaf.values = values                         # WRONG: only active values, not full 512
    return (leaf, pos)
end
```

### 3.4 The Correct Algorithm

Per `ReadMaskValues` in `reference/tinyvdbio.h` (lines 2017-2127):

```
read_leaf_values(bytes, pos, leaf, file_version, compression_flags, background):
  1. Skip value_mask (64 bytes)
  2. Read per_node_flag (1 byte)
  3. Initialize inactive values from flag:
     - flag 0: inactiveVal0 = +background
     - flag 1: inactiveVal0 = -background
     - flag 2: read inactiveVal0 (4 bytes), inactiveVal1 = background
     - flag 3: inactiveVal0 = -background, inactiveVal1 = +background, read selection_mask
     - flag 4: read inactiveVal0, inactiveVal1 = background, read selection_mask
     - flag 5: read inactiveVal0, read inactiveVal1, read selection_mask
     - flag 6: no mask compression, all 512 values stored
  4. Compute read_count:
     - If mask_compressed AND flag != 6: read_count = count_on(value_mask)
     - Else: read_count = 512
  5. Read read_count compressed Float32 values → temp_values
  6. Reconstruct full 512-value buffer:
     - If mask_compressed AND read_count != 512:
       For each index 0..511:
         - If value_mask.isOn(i): copy next from temp_values (active voxel)
         - Else if selection_mask.isOn(i): write inactiveVal1
         - Else: write inactiveVal0
     - Else: values = temp_values (all 512 present)
  7. Return (leaf with full 512 values, new_pos)
```

### 3.5 Impact

Without this fix:
- Stream position after each leaf is wrong (missing bytes for inactive values + selection mask)
- Position error compounds over thousands of leaf nodes
- Eventually causes `BoundsError` crash (observed at Compression.jl:112 on cube.vdb)
- Even if it didn't crash, leaf values would be wrong (only active values, not full 512)

### 3.6 Note: `skip_mask_values` Already Correct

The Topology.jl function `skip_mask_values` (lines 132-177) already correctly handles all 7 per_node_flag cases for internal node tile values. The leaf value reader just needs to follow the same pattern with actual value reconstruction instead of skipping.

---

## 4. Additional Issues (Minor)

### 4.1 Missing `background` Parameter

`read_leaf_values` needs the `background` value to reconstruct inactive voxels (flags 0, 1, 3). Currently the function signature doesn't include it. The background is available from `RootNodeData.background` and needs to be threaded through `read_tree_values` → `read_internal_values` → `read_leaf_values`.

### 4.2 Duplicate Constants

`Topology.jl` and `Values.jl` both define the same `NO_MASK_*` / `MASK_AND_*` constants. The second `include` will cause a redefinition warning. Move constants to one location (Compression.jl or a shared Constants.jl).

### 4.3 `num_tiles` / `num_children` Type

`Topology.jl:267-268` reads these as `read_i32` (signed). The C++ uses `int32_t` which is signed, so this is actually correct. No change needed.

### 4.4 `Manifest.toml` Stale Reference

`Manifest.toml` references `VDB` as the package name instead of `Lyr`. This causes no runtime issues but is confusing.

### 4.5 Debug Dependencies in Runtime

`Debugger` and `Infiltrator` are in `[deps]` instead of `[extras]` in `Project.toml`.

### 4.6 Untracked Debug Scripts

12 untracked files in `scripts/` and root directory from previous debugging sessions. Should be `.gitignore`d or deleted.

---

## 5. Test Coverage

### 5.1 Current (247 tests passing)

| Component | Tests | Coverage |
|---|---|---|
| Binary primitives | 61 | Complete |
| NodeMask | 55 | Complete |
| Data structures | 22 | Complete |
| Header parsing | 14 | Complete |
| Grid descriptor | 29 | Complete |
| Compression | 16 | Complete |
| Topology | 29 | Good (unit-level, no real file) |
| Values | 15 | **Insufficient** (no mask compression cases) |
| Parser | 6 | Structure only (no real file) |

### 5.2 Missing Tests

1. **read_leaf_values with mask compression** — flags 0-5 with inactive value reconstruction
2. **End-to-end parse on cube.vdb** — the real file test that currently crashes
3. **Value correctness validation** — compare parsed values against known-good output

---

## 6. Implementation Plan

### Phase 1: Fix the Bug (Priority: CRITICAL)

**Task 1.1: Move constants to single location**
- Move `NO_MASK_*` / `MASK_AND_*` constants from both `Topology.jl` and `Values.jl` to `Compression.jl`
- Remove duplicates

**Task 1.2: Add `background` parameter threading**
- Add `background::Float32` parameter to `read_leaf_values`, `read_internal_values`, `read_tree_values`
- Pass `root.background` from `read_grid` through the call chain

**Task 1.3: Write failing tests for mask compression**
- Test each per_node_flag value (0-6) with synthetic data
- Test inactive value reconstruction produces correct 512-value buffer

**Task 1.4: Implement correct `read_leaf_values`**
- Follow `ReadMaskValues` algorithm (Section 3.4 above)
- Read inactiveVal0, inactiveVal1, selection_mask based on per_node_flag
- Reconstruct full 512-value buffer

**Task 1.5: End-to-end test on cube.vdb**
- Parse cube.vdb successfully without crash
- Verify grid structure (correct number of root children, internal nodes, leaves)
- Verify value ranges are plausible for a signed distance field

### Phase 2: Validation & Polish

**Task 2.1: Cross-validate with C++ reference output**
- Use `vdb_print` or write a small C++ program to dump cube.vdb values
- Compare Julia output against C++ output byte-for-byte

**Task 2.2: Clean up project**
- Remove/gitignore debug scripts
- Fix Manifest.toml package name
- Move debug deps to extras

**Task 2.3: Update CLAUDE.md beads status table**

### Phase 3: Main Implementation (Future)

Once TinyVDB parses correctly, backport the sequential reading approach to the main Lyr module, or promote TinyVDB to be the main parser.

---

## 7. Test Fixture

**Use `cube.vdb` only** (3.7MB). It is:
- v222 format
- Float32 level set (signed distance field)
- Small enough to parse quickly
- Uses `UniformScaleMap` transform
- Has `Tree_float_5_4_3` grid type

Path: `test/fixtures/samples/cube.vdb`

---

## 8. Decision: TinyVDB vs Main

**Recommendation: Promote TinyVDB as the sole parser.**

Rationale:
- TinyVDB's sequential reading is architecturally correct (matches C++ reference)
- Main implementation's offset-seeking approach is fundamentally fragile
- TinyVDB is 1,400 LOC vs main's 2,800 LOC — simpler is better
- All 247 tests pass on TinyVDB; main has 3 errors
- The main module's higher-level features (Accessors, Interpolation, Ray, Render) can be layered on top of TinyVDB's data structures

Once TinyVDB parses real files correctly, the main implementation can be deprecated and its useful higher-level code adapted to work with TinyVDB's types.
