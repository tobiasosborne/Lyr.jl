using VDB

function test_heuristic()
    bytes = read("test/fixtures/samples/bunny_cloud.vdb")
    pos = 184  # Start of metadata keys (after metadata_count)

    function read_u32_le(b, p)
        reinterpret(UInt32, b[p:p+3])[1], p+4
    end

    for key_len in 1:min(64, length(bytes) - pos)
        potential_key = String(bytes[pos:pos+key_len-1])
        test_pos = pos + key_len
        
        println("Trying key_len=$key_len: potential_key='$potential_key'")
        
        if test_pos + 3 <= length(bytes)
            type_size, _ = read_u32_le(bytes, test_pos)
            println("  type_size=$type_size at test_pos=$test_pos")
            
            if type_size >= 3 && type_size <= 30 && test_pos + 4 + type_size <= length(bytes)
                valid_ascii = true
                type_str = ""
                for j in 0:type_size-1
                    b = bytes[test_pos + 4 + j]
                    ch = if b >= 32 && b <= 126
                        Char(b)
                    else
                        '?'
                    end
                    type_str *= ch
                    if !(b >= 32 && b <= 126)
                        valid_ascii = false
                    end
                end
                
                println("  type_str='$type_str', valid_ascii=$valid_ascii")
                
                if valid_ascii
                    println("  MATCH! key='$potential_key', type='$type_str'")
                    return
                end
            end
        end
    end
    
    println("NO MATCH FOUND")
end

test_heuristic()
