# Masks.jl - Immutable fixed-size bitmask types

"""
    Mask{N}

An immutable fixed-size bitmask with N bits.
Stored as a tuple of UInt64 words.
"""
struct Mask{N}
    words::NTuple{cld(N, 64), UInt64}
end

# Type aliases for VDB node masks
const LeafMask = Mask{512}         # 8x8x8 = 512 voxels
const Internal1Mask = Mask{4096}   # 16x16x16 = 4096 children
const Internal2Mask = Mask{32768}  # 32x32x32 = 32768 children

"""
    Mask{N}()

Construct a mask with all bits off (zeros).
"""
function Mask{N}() where N
    nwords = cld(N, 64)
    Mask{N}(ntuple(_ -> UInt64(0), nwords))
end

"""
    Mask{N}(::Val{:ones})

Construct a mask with all bits on (ones).
"""
function Mask{N}(::Val{:ones}) where N
    nwords = cld(N, 64)
    # Handle the last word which may have fewer than 64 valid bits
    remainder = N % 64
    if remainder == 0
        Mask{N}(ntuple(_ -> ~UInt64(0), nwords))
    else
        last_mask = (UInt64(1) << remainder) - 1
        Mask{N}(ntuple(i -> i < nwords ? ~UInt64(0) : last_mask, nwords))
    end
end

"""
    is_on(m::Mask{N}, i::Int) -> Bool

Check if bit at index `i` (0-indexed) is on.
"""
function is_on(m::Mask{N}, i::Int)::Bool where N
    @boundscheck 0 <= i < N || throw(BoundsError(m, i))
    word_idx = (i >> 6) + 1  # Divide by 64, 1-indexed
    bit_idx = i & 63         # Mod 64
    @inbounds (m.words[word_idx] >> bit_idx) & 1 == 1
end

"""
    is_off(m::Mask{N}, i::Int) -> Bool

Check if bit at index `i` (0-indexed) is off.
"""
is_off(m::Mask{N}, i::Int) where N = !is_on(m, i)

"""
    is_empty(m::Mask{N}) -> Bool

Check if all bits are off.
"""
function is_empty(m::Mask{N})::Bool where N
    all(w -> w == 0, m.words)
end

"""
    is_full(m::Mask{N}) -> Bool

Check if all N bits are on.
"""
function is_full(m::Mask{N})::Bool where N
    nwords = cld(N, 64)
    remainder = N % 64

    # Check all but last word
    for i in 1:(nwords - 1)
        m.words[i] == ~UInt64(0) || return false
    end

    # Check last word
    if remainder == 0
        m.words[nwords] == ~UInt64(0)
    else
        expected = (UInt64(1) << remainder) - 1
        m.words[nwords] == expected
    end
end

"""
    count_on(m::Mask{N}) -> Int

Count the number of bits that are on.
"""
function count_on(m::Mask{N})::Int where N
    sum(count_ones, m.words)
end

"""
    count_off(m::Mask{N}) -> Int

Count the number of bits that are off.
"""
count_off(m::Mask{N}) where N = N - count_on(m)

"""
    OnIndicesIterator{N}

Iterator over indices of on bits in a mask.
"""
struct OnIndicesIterator{N}
    mask::Mask{N}
end

"""
    on_indices(m::Mask{N})

Return an iterator over all indices (0-indexed) where bits are on.
Iteration order is ascending.
"""
on_indices(m::Mask{N}) where N = OnIndicesIterator{N}(m)

Base.IteratorSize(::Type{OnIndicesIterator{N}}) where N = Base.SizeUnknown()
Base.eltype(::Type{OnIndicesIterator{N}}) where N = Int

function Base.iterate(it::OnIndicesIterator{N}, state=(1, 0)) where N
    word_idx, bit_offset = state
    nwords = cld(N, 64)

    while word_idx <= nwords
        word = it.mask.words[word_idx]
        # Skip already-checked bits
        word >>= bit_offset

        while word != 0 && bit_offset < 64
            if word & 1 == 1
                idx = (word_idx - 1) * 64 + bit_offset
                if idx < N
                    return (idx, (word_idx, bit_offset + 1))
                end
            end
            word >>= 1
            bit_offset += 1
        end

        word_idx += 1
        bit_offset = 0
    end

    nothing
end

"""
    OffIndicesIterator{N}

Iterator over indices of off bits in a mask.
"""
struct OffIndicesIterator{N}
    mask::Mask{N}
end

"""
    off_indices(m::Mask{N})

Return an iterator over all indices (0-indexed) where bits are off.
Iteration order is ascending.
"""
off_indices(m::Mask{N}) where N = OffIndicesIterator{N}(m)

Base.IteratorSize(::Type{OffIndicesIterator{N}}) where N = Base.SizeUnknown()
Base.eltype(::Type{OffIndicesIterator{N}}) where N = Int

function Base.iterate(it::OffIndicesIterator{N}, state=0) where N
    i = state
    while i < N
        if is_off(it.mask, i)
            return (i, i + 1)
        end
        i += 1
    end
    nothing
end

"""
    read_mask(::Type{Mask{N}}, bytes::Vector{UInt8}, pos::Int) -> Tuple{Mask{N}, Int}

Parse a mask from bytes. Masks are stored as consecutive 64-bit words in little-endian.
"""
function read_mask(::Type{Mask{N}}, bytes::Vector{UInt8}, pos::Int)::Tuple{Mask{N}, Int} where N
    nwords = cld(N, 64)
    words = Vector{UInt64}(undef, nwords)

    for i in 1:nwords
        words[i], pos = read_u64_le(bytes, pos)
    end

    (Mask{N}(NTuple{nwords, UInt64}(words)), pos)
end
