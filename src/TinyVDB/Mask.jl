# Mask.jl - NodeMask implementation for TinyVDB

"""
    NodeMask

A bitmask for VDB tree nodes. Stores `2^(3*log2dim)` bits in 64-bit words.

- LOG2DIM=3: Leaf nodes (8x8x8 = 512 bits, 8 words)
- LOG2DIM=4: Internal1 nodes (16x16x16 = 4096 bits, 64 words)
- LOG2DIM=5: Internal2 nodes (32x32x32 = 32768 bits, 512 words)

Bit indexing is 0-based to match the C++ reference (tinyvdbio.h).
"""
mutable struct NodeMask
    log2dim::Int32
    words::Vector{UInt64}
end

"""
    NodeMask(log2dim::Int32) -> NodeMask

Create a new NodeMask with all bits set to off (zero).

# Arguments
- `log2dim`: Log2 of the node dimension (3 for leaf, 4 for internal1, 5 for internal2)

# Returns
A new NodeMask with the appropriate number of zero-initialized words.
"""
function NodeMask(log2dim::Int32)
    # SIZE = 1 << (3 * log2dim)
    # WORD_COUNT = SIZE >> 6 = SIZE / 64
    word_count = (1 << (3 * log2dim)) >> 6
    NodeMask(log2dim, zeros(UInt64, word_count))
end

"""
    is_on(mask::NodeMask, n::Int) -> Bool

Check if bit `n` is set (1) in the mask. Bit indexing is 0-based.

# Arguments
- `mask`: The NodeMask to check
- `n`: Bit index (0-based, like C++)

# Returns
`true` if bit n is on, `false` otherwise.
"""
function is_on(mask::NodeMask, n::Int)::Bool
    # Word index (0-based in C++, but Julia arrays are 1-indexed)
    word_idx = (n >> 6) + 1  # n / 64, +1 for Julia indexing
    # Bit position within the word
    bit_pos = n & 63  # n % 64
    @inbounds (mask.words[word_idx] & (UInt64(1) << bit_pos)) != 0
end

"""
    set_on!(mask::NodeMask, n::Int) -> Nothing

Set bit `n` to on (1) in the mask. Bit indexing is 0-based.

# Arguments
- `mask`: The NodeMask to modify
- `n`: Bit index (0-based, like C++)
"""
function set_on!(mask::NodeMask, n::Int)::Nothing
    word_idx = (n >> 6) + 1
    bit_pos = n & 63
    @inbounds mask.words[word_idx] |= (UInt64(1) << bit_pos)
    nothing
end

"""
    count_on(mask::NodeMask) -> Int

Count the number of bits that are on (1) in the mask.

Uses Julia's built-in `count_ones` for efficient popcount.
"""
function count_on(mask::NodeMask)::Int
    total = 0
    @inbounds for word in mask.words
        total += count_ones(word)
    end
    total
end

"""
    read_mask(bytes::Vector{UInt8}, pos::Int, log2dim::Int32) -> Tuple{NodeMask, Int}

Read a NodeMask from bytes starting at position `pos`.

The mask is stored as an array of little-endian 64-bit words.

# Arguments
- `bytes`: Source byte array
- `pos`: Starting position (1-indexed)
- `log2dim`: Log2 of the node dimension

# Returns
Tuple of (NodeMask, next_position)
"""
function read_mask(bytes::Vector{UInt8}, pos::Int, log2dim::Int32)::Tuple{NodeMask, Int}
    word_count = (1 << (3 * log2dim)) >> 6
    words = Vector{UInt64}(undef, word_count)

    # Bounds check before reading
    bytes_needed = word_count * 8
    if pos + bytes_needed - 1 > length(bytes)
        error("read_mask: bounds error at pos=$pos, need $bytes_needed bytes, have $(length(bytes) - pos + 1)")
    end

    for i in 1:word_count
        word, pos = read_u64(bytes, pos)
        words[i] = word
    end

    (NodeMask(log2dim, words), pos)
end
