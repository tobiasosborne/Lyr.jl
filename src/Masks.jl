# Masks.jl — Immutable fixed-size bitmask types with prefix-sum acceleration

"""
    Mask{N,W}

An immutable fixed-size bitmask with N bits.
Stored as a tuple of W UInt64 words where W = cld(N, 64).
Includes a prefix-sum of popcounts for O(1) `count_on_before`.
`prefix[k]` = total number of on-bits in words 1 through k.
"""
struct Mask{N,W}
    words::NTuple{W, UInt64}
    prefix::NTuple{W, UInt32}
end

"""Compute prefix-sum of popcounts from words tuple."""
@inline function _compute_prefix(words::NTuple{W, UInt64}) where W
    ntuple(Val(W)) do i
        s = UInt32(0)
        for j in 1:i
            s += UInt32(count_ones(words[j]))
        end
        s
    end
end

"""Construct a Mask from words, computing prefix sums automatically."""
@inline function Mask{N,W}(words::NTuple{W, UInt64}) where {N,W}
    Mask{N,W}(words, _compute_prefix(words))
end

"Compute the number of UInt64 words needed for N bits."
@inline nwords(::Val{N}) where N = cld(N, 64)

"""Type alias for 512-bit leaf node value mask (8x8x8 voxels, 8 UInt64 words)."""
const LeafMask = Mask{512, 8}

"""Type alias for 4096-bit Internal1 node mask (16x16x16 children, 64 UInt64 words)."""
const Internal1Mask = Mask{4096, 64}

"""Type alias for 32768-bit Internal2 node mask (32x32x32 children, 512 UInt64 words)."""
const Internal2Mask = Mask{32768, 512}

function Base.show(io::IO, m::Mask{N,W}) where {N,W}
    print(io, "Mask{", N, "}(", count_on(m), "/", N, " on)")
end

"""
    Base.length(m::Mask{N,W}) -> Int

Return the number of bits in the mask (N).
"""
Base.length(::Mask{N,W}) where {N,W} = N

"""
    Mask{N,W}()

Construct a mask with all bits off (zeros).
"""
function Mask{N,W}() where {N,W}
    Mask{N,W}(ntuple(_ -> UInt64(0), W))
end

"""
    Mask{N,W}(::Val{:ones})

Construct a mask with all bits on (ones).
"""
function Mask{N,W}(::Val{:ones}) where {N,W}
    # Handle the last word which may have fewer than 64 valid bits
    remainder = N % 64
    if remainder == 0
        Mask{N,W}(ntuple(_ -> ~UInt64(0), W))
    else
        last_mask = (UInt64(1) << remainder) - 1
        Mask{N,W}(ntuple(i -> i < W ? ~UInt64(0) : last_mask, W))
    end
end

"""
    is_on(m::Mask{N,W}, i::Int) -> Bool

Check if bit at index `i` (0-indexed) is on.
"""
function is_on(m::Mask{N,W}, i::Int)::Bool where {N,W}
    @boundscheck 0 <= i < N || throw(BoundsError(m, i))
    word_idx = (i >> 6) + 1  # Divide by 64, 1-indexed
    bit_idx = i & 63         # Mod 64
    @inbounds (m.words[word_idx] >> bit_idx) & 1 == 1
end

"""
    is_off(m::Mask{N,W}, i::Int) -> Bool

Check if bit at index `i` (0-indexed) is off.
"""
is_off(m::Mask{N,W}, i::Int) where {N,W} = !is_on(m, i)

"""
    is_empty(m::Mask{N,W}) -> Bool

Check if all bits are off.
"""
function is_empty(m::Mask{N,W})::Bool where {N,W}
    all(w -> w == 0, m.words)
end

"""
    is_full(m::Mask{N,W}) -> Bool

Check if all N bits are on.
"""
function is_full(m::Mask{N,W})::Bool where {N,W}
    remainder = N % 64

    # Check all but last word
    for i in 1:(W - 1)
        m.words[i] == ~UInt64(0) || return false
    end

    # Check last word
    if remainder == 0
        m.words[W] == ~UInt64(0)
    else
        expected = (UInt64(1) << remainder) - 1
        m.words[W] == expected
    end
end

"""
    count_on(m::Mask{N,W}) -> Int

Count the number of bits that are on. O(1) via prefix sum.
"""
function count_on(m::Mask{N,W})::Int where {N,W}
    @inbounds Int(m.prefix[W])
end

"""
    count_off(m::Mask{N,W}) -> Int

Count the number of bits that are off.
"""
count_off(m::Mask{N,W}) where {N,W} = N - count_on(m)

"""
    count_on_before(m::Mask{N,W}, i::Int) -> Int

Count the number of bits that are on in positions 0 to i-1 (exclusive of i).
O(1) via prefix-sum lookup + one masked popcount.

For VDB tree traversal, when bit `i` is set in the child_mask, the table index
is `count_on_before(child_mask, i)`.
"""
function count_on_before(m::Mask{N,W}, i::Int)::Int where {N,W}
    @boundscheck 0 <= i < N || throw(BoundsError(m, i))

    i == 0 && return 0

    # Which word contains bit i (0-indexed word)
    word_idx = i >> 6
    bit_in_word = i & 63

    # O(1) prefix sum for all complete words before word_idx
    @inbounds count = word_idx > 0 ? Int(m.prefix[word_idx]) : 0

    # Add popcount of bits 0 to bit_in_word-1 in the target word
    if bit_in_word > 0
        @inbounds begin
            word = m.words[word_idx + 1]  # 1-indexed
            mask = (UInt64(1) << bit_in_word) - 1
            count += count_ones(word & mask)
        end
    end

    count
end

"""
    OnIndicesIterator{N,W}

Iterator over indices of on bits in a mask.
"""
struct OnIndicesIterator{N,W}
    mask::Mask{N,W}
end

"""
    on_indices(m::Mask{N,W})

Return an iterator over all indices (0-indexed) where bits are on.
Iteration order is ascending.
"""
on_indices(m::Mask{N,W}) where {N,W} = OnIndicesIterator{N,W}(m)

Base.IteratorSize(::Type{OnIndicesIterator{N,W}}) where {N,W} = Base.HasLength()
Base.length(it::OnIndicesIterator) = count_on(it.mask)
Base.eltype(::Type{OnIndicesIterator{N,W}}) where {N,W} = Int

function Base.iterate(it::OnIndicesIterator{N,W}, state=nothing) where {N,W}
    # State: (word_idx, remaining_bits) where remaining_bits has processed bits cleared
    if state === nothing
        # Initialize: find first word with set bits
        word_idx = 1
        @inbounds while word_idx <= W && it.mask.words[word_idx] == 0
            word_idx += 1
        end
        word_idx > W && return nothing
        @inbounds remaining = it.mask.words[word_idx]
    else
        word_idx, remaining = state
    end

    # Use CTZ to find next set bit - O(1) jump to next set bit
    @inbounds while true
        if remaining != 0
            tz = trailing_zeros(remaining)
            idx = (word_idx - 1) * 64 + tz
            if idx < N
                # Clear this bit and return
                remaining &= remaining - 1  # Clear lowest set bit
                return (idx, (word_idx, remaining))
            else
                return nothing  # Past valid range
            end
        end

        # Move to next word with set bits
        word_idx += 1
        while word_idx <= W && it.mask.words[word_idx] == 0
            word_idx += 1
        end
        word_idx > W && return nothing
        remaining = it.mask.words[word_idx]
    end
end

"""
    OffIndicesIterator{N,W}

Iterator over indices of off bits in a mask.
"""
struct OffIndicesIterator{N,W}
    mask::Mask{N,W}
end

"""
    off_indices(m::Mask{N,W})

Return an iterator over all indices (0-indexed) where bits are off.
Iteration order is ascending.
"""
off_indices(m::Mask{N,W}) where {N,W} = OffIndicesIterator{N,W}(m)

Base.IteratorSize(::Type{OffIndicesIterator{N,W}}) where {N,W} = Base.SizeUnknown()
Base.eltype(::Type{OffIndicesIterator{N,W}}) where {N,W} = Int

function Base.iterate(it::OffIndicesIterator{N,W}, state=nothing) where {N,W}
    # Same CTZ technique as OnIndicesIterator, but on ~word (complement bits)
    if state === nothing
        word_idx = 1
        @inbounds remaining = ~it.mask.words[1]
    else
        word_idx, remaining = state
    end

    @inbounds while true
        if remaining != 0
            tz = trailing_zeros(remaining)
            idx = (word_idx - 1) * 64 + tz
            if idx < N
                remaining &= remaining - 1  # Clear lowest set bit
                return (idx, (word_idx, remaining))
            else
                return nothing  # Past valid range
            end
        end

        word_idx += 1
        word_idx > W && return nothing
        remaining = ~it.mask.words[word_idx]
    end
end

"""
    read_mask(::Type{Mask{N,W}}, bytes::Vector{UInt8}, pos::Int) -> Tuple{Mask{N,W}, Int}

Parse a mask from bytes. Masks are stored as consecutive 64-bit words in little-endian.
"""
function read_mask(::Type{Mask{N,W}}, bytes::Vector{UInt8}, pos::Int)::Tuple{Mask{N,W}, Int} where {N,W}
    # A mask requires exactly W * 8 bytes; truncated data means a corrupt file
    @boundscheck checkbounds(bytes, pos:pos + W * 8 - 1)
    p = pos
    words = ntuple(Val(W)) do i
        GC.@preserve bytes begin
            @inbounds val = _unaligned_load(UInt64, pointer(bytes, p + (i - 1) * 8))
        end
        ltoh(val)
    end
    pos += W * 8

    (Mask{N,W}(words), pos)
end
