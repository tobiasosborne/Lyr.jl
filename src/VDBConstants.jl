# VDBConstants.jl - Shared VDB format constants
#
# Used by both main Lyr parser and TinyVDB test oracle.
# Magic number constants are NOT shared because the parsers validate
# them differently (u32 vs raw byte comparison).

# Compression flags (bitfield values from the OpenVDB file format spec)
const VDB_COMPRESS_NONE        = UInt32(0x00)
const VDB_COMPRESS_ZIP         = UInt32(0x01)
const VDB_COMPRESS_ACTIVE_MASK = UInt32(0x02)
const VDB_COMPRESS_BLOSC       = UInt32(0x04)

# File format version threshold
const VDB_FILE_VERSION_NODE_MASK_COMPRESSION = UInt32(222)
