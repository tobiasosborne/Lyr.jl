using VDB

bytes = read("test/fixtures/samples/bunny_cloud.vdb")

# Position 176 is start of potential grid metadata
pos = 176

function read_u32_le(b, p)
    reinterpret(UInt32, b[p:p+3])[1], p+4
end

function read_u8(b, p)
    b[p], p+1
end

tree_version, pos = read_u32_le(bytes, pos)
metadata_count, pos = read_u32_le(bytes, pos)

println("tree_version: $tree_version")
println("metadata_count: $metadata_count")
println("pos after counts: $pos")

# Now let's look at the raw bytes and try to understand the format
@show bytes[pos:min(pos+50, end)]

# Try to parse as null-terminated strings
# Position 184 should be start of first key
# Let's look for null bytes
found_null = findfirst(x -> x == 0, bytes[pos:pos+50])
println("First null byte offset from pos: $found_null")

# Look for next few bytes
for i in 0:40
    b = bytes[pos + i]
    ch = if b >= 32 && b <= 126
        Char(b)
    else
        '?'
    end
    println("  pos+$i: $(bytes[pos+i]) ('$ch')")
end
