# VolumeHDDA.jl — Span-merging hierarchical DDA for volume rendering
#
# Mirrors OpenVDB's VolumeHDDA (openvdb/math/DDA.h): merges adjacent active
# nodes into continuous TimeSpan intervals. The integrator never sees leaf
# boundaries, eliminating seam artifacts at 8-voxel tile edges.

"""
    TimeSpan

A merged interval `[t0, t1)` along a ray where the VDB tree has active data.
May span multiple adjacent leaves and tiles.
"""
struct TimeSpan
    t0::Float64
    t1::Float64
end

"""
    NanoVolumeHDDA{T}

Span-merging iterator over a NanoGrid. Yields `TimeSpan` structs representing
merged active regions along a ray in front-to-back order.

Adjacent active leaves and tiles are coalesced — the integrator receives
intervals that may cover many leaves with no internal boundaries.

```julia
for span in NanoVolumeHDDA(nanogrid, ray)
    # integrate density from span.t0 to span.t1
end
```
"""
struct NanoVolumeHDDA{T}
    grid::NanoGrid{T}
    ray::Ray
end

Base.IteratorSize(::Type{<:NanoVolumeHDDA}) = Base.SizeUnknown()
Base.eltype(::Type{NanoVolumeHDDA{T}}) where T = TimeSpan

"""
    HDDAState{T}

Mutable state for the `NanoVolumeHDDA` iterator. Tracks position at root,
I2, and I1 levels of the NanoGrid hierarchy, plus the current merged span.
A `span_t0 < 0` indicates no open span.
"""
mutable struct HDDAState{T}
    roots::Vector{Tuple{Float64, Int}}   # pre-sorted (tmin, i2_byte_offset)
    root_idx::Int
    i2_ndda::Union{NodeDDA, Nothing}
    i2_off::Int
    i2_t_entry::Float64                  # entry time of current I2 cell
    i1_ndda::Union{NodeDDA, Nothing}
    i1_off::Int
    i1_t_entry::Float64                  # entry time of current I1 cell
    span_t0::Float64                     # -1.0 = no open span
end

function Base.iterate(hdda::NanoVolumeHDDA{T}) where T
    ray = hdda.ray
    buf = hdda.grid.buffer
    root_pos = _nano_root_pos(hdda.grid)
    root_count = nano_root_count(hdda.grid)
    entry_sz = _root_entry_size(T)

    roots = Tuple{Float64, Int}[]

    for i in 0:(root_count - 1)
        ep = root_pos + i * entry_sz
        is_child = _buf_load(UInt8, buf, ep + 12)
        is_child == 0x01 || continue
        i2_off = Int(_buf_load(UInt32, buf, ep + 13))
        origin = _buf_load_coord(buf, i2_off)
        aabb = AABB(
            SVec3d(Float64(origin.x), Float64(origin.y), Float64(origin.z)),
            SVec3d(Float64(origin.x) + 4096.0, Float64(origin.y) + 4096.0,
                   Float64(origin.z) + 4096.0)
        )
        hit = intersect_bbox(ray, aabb)
        hit !== nothing && push!(roots, (hit[1], i2_off))
    end

    sort!(roots, by=first)
    isempty(roots) && return nothing

    state = HDDAState{T}(roots, 0, nothing, 0, 0.0, nothing, 0, 0.0, -1.0)
    _hdda_advance(buf, ray, state)
end

function Base.iterate(hdda::NanoVolumeHDDA{T}, state::HDDAState{T}) where T
    _hdda_advance(hdda.grid.buffer, hdda.ray, state)
end

# ── Core state machine ──────────────────────────────────────────────────────

function _hdda_advance(buf::Vector{UInt8}, ray::Ray,
                       s::HDDAState{T})::Union{Tuple{TimeSpan, HDDAState{T}}, Nothing} where T
    while true
        # ── Phase 1: DDA through I1 cells (stride 8) ────────────────────
        while s.i1_ndda !== nothing && node_dda_inside(s.i1_ndda)
            ndda = s.i1_ndda
            cidx = node_dda_child_index(ndda)

            has_child = _buf_mask_is_on(buf, s.i1_off + _I1_CMASK_OFF, cidx)
            has_tile  = !has_child && _buf_mask_is_on(buf, s.i1_off + _I1_VMASK_OFF, cidx)

            if has_child || has_tile
                # Active cell — start or extend span
                if s.span_t0 < 0.0
                    s.span_t0 = s.i1_t_entry
                end
            elseif s.span_t0 >= 0.0
                # Inactive cell with open span — close and yield
                span = TimeSpan(s.span_t0, s.i1_t_entry)
                s.span_t0 = -1.0
                s.i1_t_entry = node_dda_cell_time(ndda)
                dda_step!(ndda.state)
                return (span, s)
            end

            s.i1_t_entry = node_dda_cell_time(ndda)
            dda_step!(ndda.state)
        end
        s.i1_ndda = nothing

        # ── Phase 2: DDA through I2 cells (stride 128) ──────────────────
        found_i1 = false
        while s.i2_ndda !== nothing && node_dda_inside(s.i2_ndda)
            ndda = s.i2_ndda
            cidx = node_dda_child_index(ndda)

            has_child = _buf_mask_is_on(buf, s.i2_off + _I2_CMASK_OFF, cidx)

            if has_child
                # I1 node exists — descend
                tidx = _buf_count_on_before(buf, s.i2_off + _I2_CMASK_OFF,
                                            s.i2_off + _I2_CPREFIX_OFF, cidx)
                i1_off = Int(_buf_load(UInt32, buf, s.i2_off + _I2_DATA_OFF + tidx * 4))
                origin = _buf_load_coord(buf, i1_off)
                aabb = AABB(
                    SVec3d(Float64(origin.x), Float64(origin.y), Float64(origin.z)),
                    SVec3d(Float64(origin.x) + 128.0, Float64(origin.y) + 128.0,
                           Float64(origin.z) + 128.0)
                )
                hit = intersect_bbox(ray, aabb)

                if hit !== nothing
                    tmin, _ = hit
                    # If span is open, the I1 node continues it (no gap).
                    # If span is closed, I1 will start a new one in Phase 1.
                    s.i1_ndda = node_dda_init(ray, tmin, origin, Int32(16), Int32(8))
                    s.i1_off = i1_off
                    s.i1_t_entry = tmin
                    s.i2_t_entry = node_dda_cell_time(ndda)
                    dda_step!(ndda.state)
                    found_i1 = true
                    break
                else
                    # Ray misses this I1 AABB — treat as inactive gap
                    if s.span_t0 >= 0.0
                        span = TimeSpan(s.span_t0, s.i2_t_entry)
                        s.span_t0 = -1.0
                        s.i2_t_entry = node_dda_cell_time(ndda)
                        dda_step!(ndda.state)
                        return (span, s)
                    end
                end
            else
                has_tile = _buf_mask_is_on(buf, s.i2_off + _I2_VMASK_OFF, cidx)
                if has_tile
                    # Active I2 tile — start or extend span
                    if s.span_t0 < 0.0
                        s.span_t0 = s.i2_t_entry
                    end
                elseif s.span_t0 >= 0.0
                    # Inactive — close span
                    span = TimeSpan(s.span_t0, s.i2_t_entry)
                    s.span_t0 = -1.0
                    s.i2_t_entry = node_dda_cell_time(ndda)
                    dda_step!(ndda.state)
                    return (span, s)
                end
            end

            s.i2_t_entry = node_dda_cell_time(ndda)
            dda_step!(ndda.state)
        end

        found_i1 && continue   # back to Phase 1

        # I2 exhausted — close any open span at node boundary
        if s.span_t0 >= 0.0
            span = TimeSpan(s.span_t0, s.i2_t_entry)
            s.span_t0 = -1.0
            s.i2_ndda = nothing
            return (span, s)
        end
        s.i2_ndda = nothing

        # ── Phase 3: next root entry ────────────────────────────────────
        s.root_idx += 1
        s.root_idx > length(s.roots) && return nothing

        tmin, i2_off = s.roots[s.root_idx]
        origin = _buf_load_coord(buf, i2_off)
        s.i2_ndda = node_dda_init(ray, tmin, origin, Int32(32), Int32(128))
        s.i2_off = i2_off
        s.i2_t_entry = tmin
    end
end

# ── Zero-allocation callback-based HDDA ──────────────────────────────────────
#
# The iterator protocol forces HDDAState to be heap-allocated (it escapes the
# iterate function). This callback version keeps ALL state on the stack.
# Call f(t0::Float64, t1::Float64)::Bool for each span. Return false to stop.

const _MAX_ROOTS = 8

"""
    foreach_hdda_span(f, nanogrid::NanoGrid{T}, ray::Ray) where T

Iterate over merged active spans along a ray through a NanoGrid, calling
`f(t0, t1)` for each span. Return `false` from `f` to stop early.

Zero heap allocations — all state lives on the stack. Use this instead of
`NanoVolumeHDDA` in performance-critical render loops.
"""
@inline function foreach_hdda_span(f, nanogrid::NanoGrid{T}, ray::Ray) where T
    buf = nanogrid.buffer
    root_pos = _nano_root_pos(nanogrid)
    root_count = nano_root_count(nanogrid)
    entry_sz = _root_entry_size(T)

    # Collect root hits into stack-allocated buffer
    root_tmins = MVector{_MAX_ROOTS, Float64}(ntuple(_ -> 0.0, Val(_MAX_ROOTS)))
    root_offs  = MVector{_MAX_ROOTS, Int}(ntuple(_ -> 0, Val(_MAX_ROOTS)))
    n_roots = 0

    @inbounds for i in 0:(root_count - 1)
        ep = root_pos + i * entry_sz
        is_child = _buf_load(UInt8, buf, ep + 12)
        is_child == 0x01 || continue
        i2_off = Int(_buf_load(UInt32, buf, ep + 13))
        origin = _buf_load_coord(buf, i2_off)
        aabb = AABB(
            SVec3d(Float64(origin.x), Float64(origin.y), Float64(origin.z)),
            SVec3d(Float64(origin.x) + 4096.0, Float64(origin.y) + 4096.0,
                   Float64(origin.z) + 4096.0)
        )
        hit = intersect_bbox(ray, aabb)
        if hit !== nothing
            n_roots += 1
            n_roots > _MAX_ROOTS && break
            root_tmins[n_roots] = hit[1]
            root_offs[n_roots] = i2_off
        end
    end

    n_roots == 0 && return nothing

    # Insertion sort (n_roots is tiny, typically 1)
    @inbounds for i in 2:n_roots
        kt = root_tmins[i]
        ko = root_offs[i]
        j = i - 1
        while j >= 1 && root_tmins[j] > kt
            root_tmins[j + 1] = root_tmins[j]
            root_offs[j + 1] = root_offs[j]
            j -= 1
        end
        root_tmins[j + 1] = kt
        root_offs[j + 1] = ko
    end

    # State machine — all local variables
    span_t0 = -1.0

    @inbounds for ri in 1:n_roots
        i2_off = root_offs[ri]
        origin = _buf_load_coord(buf, i2_off)
        i2_ndda = node_dda_init(ray, root_tmins[ri], origin, Int32(32), Int32(128))
        i2_t_entry = root_tmins[ri]

        while node_dda_inside(i2_ndda)
            cidx = node_dda_child_index(i2_ndda)
            has_child = _buf_mask_is_on(buf, i2_off + _I2_CMASK_OFF, cidx)

            if has_child
                # I1 node exists — descend
                tidx = _buf_count_on_before(buf, i2_off + _I2_CMASK_OFF,
                                            i2_off + _I2_CPREFIX_OFF, cidx)
                i1_off = Int(_buf_load(UInt32, buf, i2_off + _I2_DATA_OFF + tidx * 4))
                i1_origin = _buf_load_coord(buf, i1_off)
                i1_aabb = AABB(
                    SVec3d(Float64(i1_origin.x), Float64(i1_origin.y), Float64(i1_origin.z)),
                    SVec3d(Float64(i1_origin.x) + 128.0, Float64(i1_origin.y) + 128.0,
                           Float64(i1_origin.z) + 128.0)
                )
                hit = intersect_bbox(ray, i1_aabb)

                if hit !== nothing
                    tmin, _ = hit
                    i1_ndda = node_dda_init(ray, tmin, i1_origin, Int32(16), Int32(8))
                    i1_t_entry = tmin

                    # Phase 1: DDA through I1 cells (stride 8)
                    while node_dda_inside(i1_ndda)
                        i1_cidx = node_dda_child_index(i1_ndda)
                        i1_has_child = _buf_mask_is_on(buf, i1_off + _I1_CMASK_OFF, i1_cidx)
                        i1_has_tile  = !i1_has_child && _buf_mask_is_on(buf, i1_off + _I1_VMASK_OFF, i1_cidx)

                        if i1_has_child || i1_has_tile
                            if span_t0 < 0.0
                                span_t0 = i1_t_entry
                            end
                        elseif span_t0 >= 0.0
                            # Inactive cell with open span — yield
                            f(span_t0, i1_t_entry) || return nothing
                            span_t0 = -1.0
                        end

                        i1_t_entry = node_dda_cell_time(i1_ndda)
                        dda_step!(i1_ndda.state)
                    end

                    i2_t_entry = node_dda_cell_time(i2_ndda)
                    dda_step!(i2_ndda.state)
                    continue  # back to I2 loop
                else
                    # Ray misses I1 AABB — gap
                    if span_t0 >= 0.0
                        f(span_t0, i2_t_entry) || return nothing
                        span_t0 = -1.0
                    end
                end
            else
                has_tile = _buf_mask_is_on(buf, i2_off + _I2_VMASK_OFF, cidx)
                if has_tile
                    if span_t0 < 0.0
                        span_t0 = i2_t_entry
                    end
                elseif span_t0 >= 0.0
                    f(span_t0, i2_t_entry) || return nothing
                    span_t0 = -1.0
                end
            end

            i2_t_entry = node_dda_cell_time(i2_ndda)
            dda_step!(i2_ndda.state)
        end

        # I2 exhausted — close any open span
        if span_t0 >= 0.0
            f(span_t0, i2_t_entry) || return nothing
            span_t0 = -1.0
        end
    end

    nothing
end
