# VDBConstants.jl — Shared VDB format constants and version thresholds
#
# Used by both main Lyr parser and TinyVDB test oracle.
# Magic number constants are NOT shared because the parsers validate
# them differently (u32 vs raw byte comparison).

"""Compression flag: no compression."""
const VDB_COMPRESS_NONE        = UInt32(0x00)

"""Compression flag: Zlib/Zip compression."""
const VDB_COMPRESS_ZIP         = UInt32(0x01)

"""Compression flag: sparse active-mask value storage."""
const VDB_COMPRESS_ACTIVE_MASK = UInt32(0x02)

"""Compression flag: Blosc compression."""
const VDB_COMPRESS_BLOSC       = UInt32(0x04)

"""File format version where node mask compression was introduced (v222)."""
const VDB_FILE_VERSION_NODE_MASK_COMPRESSION = UInt32(222)
