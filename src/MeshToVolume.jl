# MeshToVolume.jl — Triangle mesh to narrow-band signed distance field
#
# Converts closed triangle meshes to VDB level set grids via per-triangle
# narrow-band voxelization with angle-weighted pseudonormal sign determination
# (Baerentzen & Aanes 2005).

# Voronoi region codes for closest-point classification
const _VERT_A  = 0
const _VERT_B  = 1
const _VERT_C  = 2
const _EDGE_AB = 3
const _EDGE_BC = 4
const _EDGE_CA = 5
const _FACE    = 6

# ── Closest point on triangle (Ericson, "Real-Time Collision Detection" §5.1.5) ──

"""
    _closest_point_on_triangle(p, a, b, c) → (closest::SVec3d, feature::Int)

Compute the closest point on triangle (a, b, c) to point p using the
7-region Voronoi method. Returns the closest point and a feature code
indicating which geometric feature (vertex, edge, or face) contains it.
"""
@inline function _closest_point_on_triangle(p::SVec3d, a::SVec3d, b::SVec3d, c::SVec3d)
    ab = b - a;  ac = c - a;  ap = p - a

    d1 = dot(ab, ap);  d2 = dot(ac, ap)
    (d1 <= 0.0 && d2 <= 0.0) && return (a, _VERT_A)

    bp = p - b
    d3 = dot(ab, bp);  d4 = dot(ac, bp)
    (d3 >= 0.0 && d4 <= d3) && return (b, _VERT_B)

    vc = d1 * d4 - d3 * d2
    if vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0
        v = d1 / (d1 - d3)
        return (a + v * ab, _EDGE_AB)
    end

    cp = p - c
    d5 = dot(ab, cp);  d6 = dot(ac, cp)
    (d6 >= 0.0 && d5 <= d6) && return (c, _VERT_C)

    vb = d5 * d2 - d1 * d6
    if vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0
        w = d2 / (d2 - d6)
        return (a + w * ac, _EDGE_CA)
    end

    va = d3 * d6 - d5 * d4
    if va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0
        w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        return (b + w * (c - b), _EDGE_BC)
    end

    # Inside face
    denom = 1.0 / (va + vb + vc)
    v = vb * denom
    w = vc * denom
    return (a + v * ab + w * ac, _FACE)
end

# ── Mesh topology precomputation ──

"""
Precompute per-face normals, angle-weighted vertex pseudonormals, and
per-edge pseudonormals for sign determination.
"""
function _precompute_topology(verts::Vector{SVec3d}, faces::AbstractVector)
    nf = length(faces)
    nv = length(verts)

    face_normals   = Vector{SVec3d}(undef, nf)
    vertex_normals = fill(SVec3d(0.0, 0.0, 0.0), nv)
    edge_normals   = Dict{Tuple{Int,Int}, SVec3d}()
    sizehint!(edge_normals, 3 * nf ÷ 2)

    for fi in 1:nf
        i, j, k = faces[fi][1], faces[fi][2], faces[fi][3]
        a, b, c = verts[i], verts[j], verts[k]

        n = cross(b - a, c - a)
        n_len = norm(n)
        if n_len < 1e-12
            face_normals[fi] = SVec3d(0.0, 0.0, 0.0)
            continue
        end
        n = n / n_len
        face_normals[fi] = n

        # Angle at each vertex (clamped acos for robustness)
        ab = b - a;  ab_len = norm(ab)
        ac = c - a;  ac_len = norm(ac)
        bc = c - b;  bc_len = norm(bc)

        if ab_len > 1e-12 && ac_len > 1e-12
            vertex_normals[i] += acos(clamp(dot(ab, ac) / (ab_len * ac_len), -1.0, 1.0)) * n
        end
        if ab_len > 1e-12 && bc_len > 1e-12
            vertex_normals[j] += acos(clamp(dot(b - a, b - c) / (ab_len * bc_len), -1.0, 1.0)) * n
        end
        if ac_len > 1e-12 && bc_len > 1e-12
            vertex_normals[k] += acos(clamp(dot(c - a, c - b) / (ac_len * bc_len), -1.0, 1.0)) * n
        end

        # Edge pseudonormals: sum face normals of adjacent faces
        for (vi, vj) in ((i, j), (j, k), (k, i))
            key = vi < vj ? (vi, vj) : (vj, vi)
            edge_normals[key] = get(edge_normals, key, SVec3d(0.0, 0.0, 0.0)) + n
        end
    end

    # Normalize vertex pseudonormals
    for vi in 1:nv
        n_len = norm(vertex_normals[vi])
        if n_len > 1e-12
            vertex_normals[vi] = vertex_normals[vi] / n_len
        end
    end

    return face_normals, vertex_normals, edge_normals
end

# ── Pseudonormal lookup ──

@inline function _get_pseudonormal(feature::Int, tri_idx::Int,
                                    faces::AbstractVector,
                                    face_normals::Vector{SVec3d},
                                    vertex_normals::Vector{SVec3d},
                                    edge_normals::Dict{Tuple{Int,Int}, SVec3d})
    f = faces[tri_idx]
    feature == _FACE   && return face_normals[tri_idx]
    feature == _VERT_A && return vertex_normals[f[1]]
    feature == _VERT_B && return vertex_normals[f[2]]
    feature == _VERT_C && return vertex_normals[f[3]]

    # Edge cases: lookup by sorted vertex pair
    if feature == _EDGE_AB
        vi, vj = f[1], f[2]
    elseif feature == _EDGE_BC
        vi, vj = f[2], f[3]
    else # _EDGE_CA
        vi, vj = f[3], f[1]
    end
    key = vi < vj ? (vi, vj) : (vj, vi)
    return edge_normals[key]
end

# ── Main entry point ──

"""
    mesh_to_level_set(vertices, faces; voxel_size=1.0, half_width=3.0) → Grid{Float32}

Convert a closed triangle mesh to a narrow-band signed distance field.

Each triangle contributes SDF values to voxels within its narrow-band
bounding box. The sign is determined by angle-weighted pseudonormals,
which give exact inside/outside classification for manifold meshes.

# Arguments
- `vertices`: vector of (x, y, z) vertex positions in world space
- `faces`: vector of (i, j, k) 1-indexed triangle vertex indices
- `voxel_size`: world-space voxel edge length (default: 1.0)
- `half_width`: narrow band half-width in voxels (default: 3.0)
- `name`: grid name (default: "mesh_sdf")

# Returns
`Grid{Float32}` with `GRID_LEVEL_SET`. Negative = inside, positive = outside.
Background = `half_width * voxel_size`.

Requires a closed, consistently-oriented (manifold) mesh for correct sign.

# Example
```julia
verts = [(-1.0,-1.0,-1.0), (1.0,-1.0,-1.0), (1.0,1.0,-1.0), (-1.0,1.0,-1.0),
         (-1.0,-1.0, 1.0), (1.0,-1.0, 1.0), (1.0,1.0, 1.0), (-1.0,1.0, 1.0)]
faces = [(1,3,2),(1,4,3),(5,6,7),(5,7,8),(1,2,6),(1,6,5),
         (3,4,8),(3,8,7),(1,5,8),(1,8,4),(2,3,7),(2,7,6)]
grid = mesh_to_level_set(verts, faces; voxel_size=0.5)
```
"""
function mesh_to_level_set(vertices::AbstractVector, faces::AbstractVector;
                           voxel_size::Float64=1.0,
                           half_width::Float64=3.0,
                           name::String="mesh_sdf")
    inv_vs = 1.0 / voxel_size
    band = half_width * voxel_size
    bg = Float32(band)

    isempty(faces) && return build_grid(Dict{Coord, Float32}(), bg;
                                        name=name, grid_class=GRID_LEVEL_SET,
                                        voxel_size=voxel_size)

    # Type-stable vertex array (one-time copy)
    verts = SVec3d[SVec3d(v[1], v[2], v[3]) for v in vertices]

    face_normals, vertex_normals, edge_normals = _precompute_topology(verts, faces)

    # Thread-parallel per-triangle voxelization
    nt = Threads.maxthreadid()
    local_dicts = [Dict{Coord, Float32}() for _ in 1:nt]

    Threads.@threads for fi in 1:length(faces)
        f = faces[fi]
        a, b, c = verts[f[1]], verts[f[2]], verts[f[3]]

        # Skip degenerate triangles
        face_normals[fi] == SVec3d(0.0, 0.0, 0.0) && continue

        # Triangle AABB expanded by narrow band, converted to index range
        lo_x = min(a[1], b[1], c[1]) - band
        lo_y = min(a[2], b[2], c[2]) - band
        lo_z = min(a[3], b[3], c[3]) - band
        hi_x = max(a[1], b[1], c[1]) + band
        hi_y = max(a[2], b[2], c[2]) + band
        hi_z = max(a[3], b[3], c[3]) + band

        imin = floor(Int32, lo_x * inv_vs)
        jmin = floor(Int32, lo_y * inv_vs)
        kmin = floor(Int32, lo_z * inv_vs)
        imax = ceil(Int32, hi_x * inv_vs)
        jmax = ceil(Int32, hi_y * inv_vs)
        kmax = ceil(Int32, hi_z * inv_vs)

        d = local_dicts[Threads.threadid()]

        for iz in kmin:kmax, iy in jmin:jmax, ix in imin:imax
            p = SVec3d(Float64(ix) * voxel_size,
                       Float64(iy) * voxel_size,
                       Float64(iz) * voxel_size)

            closest, feature = _closest_point_on_triangle(p, a, b, c)
            diff = p - closest
            dist = norm(diff)

            dist > band && continue

            # Sign from pseudonormal of the closest feature
            pn = _get_pseudonormal(feature, fi, faces, face_normals,
                                   vertex_normals, edge_normals)
            sign_val = dot(diff, pn) >= 0.0 ? 1.0 : -1.0
            sdf = Float32(sign_val * dist)

            # Closest-wins: keep the value from whichever triangle is nearest
            coord_ijk = Coord(ix, iy, iz)
            existing = get(d, coord_ijk, bg)
            if abs(sdf) < abs(existing)
                d[coord_ijk] = sdf
            end
        end
    end

    # Merge thread-local dicts: closest-wins
    result = local_dicts[1]
    for i in 2:nt
        for (c, v) in local_dicts[i]
            existing = get(result, c, bg)
            if abs(v) < abs(existing)
                result[c] = v
            end
        end
    end

    build_grid(result, bg; name=name, grid_class=GRID_LEVEL_SET,
               voxel_size=voxel_size)
end
