# ext/LyrCUDAExt.jl — CUDA backend for Lyr.jl
#
# Loaded automatically by Julia's Pkg system when both Lyr and CUDA are
# available. Sets the GPU backend to CUDABackend() and adds a dispatch
# method for gpu_info with CUDA device details.

module LyrCUDAExt

using Lyr
using CUDA

# Add dispatch method for CUDABackend (extends, not overwrites)
function Lyr._gpu_info(::CUDABackend)
    try
        dev = CUDA.device()
        return "GPU backend: CUDA ($(CUDA.name(dev)))"
    catch e
        return "GPU backend: CUDA (device query failed: $e)"
    end
end

function __init__()
    if CUDA.functional()
        Lyr._GPU_BACKEND[] = CUDABackend()
        try
            dev = CUDA.device()
            @info "Lyr CUDA extension loaded" device=CUDA.name(dev)
        catch
            @info "Lyr CUDA extension loaded (device query failed)"
        end
    else
        @warn "Lyr CUDA extension: CUDA.jl loaded but no functional GPU detected. Using CPU fallback."
    end
end

end # module LyrCUDAExt
