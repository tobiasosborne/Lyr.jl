# Bugs & Code Smells Review

## Summary

Systematic line-by-line review of the Lyr.jl codebase (src/ directory) focusing on the GR ray tracer, VDB parser, NanoVDB flat buffer, volume renderer, DDA traversal, and supporting numerical code. The review found 1 critical bug, 5 major bugs, 10 minor bugs, and 5 nits.

---

## Findings

### [SEVERITY: critical] GR thin-disk renderer uses BL radius `x[2]` for Cartesian KS metric

- **Location**: `src/GR/render.jl:82` and `src/GR/render.jl:108`
- **Code**:
  ```julia
  # Line 82 (inside _trace_pixel_thin_with_p0):
  dl = M_val > 0.0 ? adaptive_step(dl_base, x[2], M_val) : dl_base
  # Line 108:
  r = x[2]
  ```
- **Issue**: When using `SchwarzschildKS` (Cartesian coordinates `(t, x, y, z)`), `x[2]` is the Cartesian x-component, NOT the radial coordinate. The adaptive step sizing and all termination checks (`r <= rh * cfg.r_min_factor`, `r >= cfg.r_max`) use this incorrect "radius." This means photons using KS coordinates will have completely wrong termination behavior: they may escape when they should hit the horizon, or vice versa. The volumetric renderer at `render.jl:177` correctly uses `_coord_r(m, x)`, but the thin-disk renderer does not.
- **Fix**: Replace `x[2]` with `_coord_r(m, x)` in `_trace_pixel_thin_with_p0`, similar to how `_trace_pixel_with_p0` does it. Also fix `adaptive_step(dl_base, x[2], M_val)` to use `_coord_r(m, x)`.

---

### [SEVERITY: major] GR thin-disk renderer calls `keplerian_four_velocity(m, r_cross)` for KS metric, but KS requires 3-arg form

- **Location**: `src/GR/render.jl:98`
- **Code**:
  ```julia
  u_emit = keplerian_four_velocity(m, r_cross)
  ```
- **Issue**: For `SchwarzschildKS`, the Keplerian four-velocity function requires 3 arguments: `(m, r, x)` where `x` is the spacetime position vector (needed to compute tangent direction in Cartesian coords). The 2-arg method `keplerian_four_velocity(m::Schwarzschild, r)` only exists for Boyer-Lindquist Schwarzschild. Calling the 2-arg form with a `SchwarzschildKS` metric will hit a `MethodError` at runtime when rendering a thin disk with KS coordinates.
- **Fix**: Thread the current position `x_new` through to this call, and dispatch to the 3-arg method for KS.

---

### [SEVERITY: major] Kerr Boyer-Lindquist tetrad construction uses wrong `SMat4d` layout

- **Location**: `src/GR/camera.jl:116-121`
- **Code**:
  ```julia
  tetrad = SMat4d(
      e0[1], e0[2], e0[3], e0[4],
      e1[1], e1[2], e1[3], e1[4],
      e2[1], e2[2], e2[3], e2[4],
      e3[1], e3[2], e3[3], e3[4]
  )
  ```
- **Issue**: `SMat4d` is `SMatrix{4,4,Float64,16}`, which is column-major. The `SMat4d(a1,...,a16)` constructor fills values column by column: the first 4 values go into column 1, the next 4 into column 2, etc. So this code puts `e0` into column 1, `e1` into column 2, `e2` into column 3, `e3` into column 4. However, compare with the Schwarzschild tetrad at `camera.jl:61-66`:
  ```julia
  tetrad = SMat4d(
      e0[1], e1[1], e2[1], e3[1],
      e0[2], e1[2], e2[2], e3[2],
      ...
  )
  ```
  In the Schwarzschild version, the first 4 values are `e0[1], e1[1], e2[1], e3[1]` which fills column 1 with the row-1 components of all tetrad legs. This makes column `a` contain leg `a` (since `e_a[mu]` in row `mu`, column `a` means `tetrad[mu, a] = e_a^mu`). But the Kerr version puts all of `e0` into column 1, which means `tetrad[:, 1] = e0` -- this is correct ONLY if column = leg. Since the Schwarzschild code has `tetrad[:, 1] = (e0[1], e1[1], e2[1], e3[1])` which is the first ROW of the tetrad matrix, these two conventions are DIFFERENT.

  Looking at `pixel_to_momentum` at line 168: `k_contra = u_vec + nx * e[:, 2] + ny * e[:, 3] + nz * e[:, 4]` -- it accesses column 2,3,4 expecting legs e1, e2, e3. The Schwarzschild layout puts `(e0[1], e1[1], e2[1], e3[1])` in column 1, so `e[:, 2]` = `(e0[2], e1[2], e2[2], e3[2])` = the second components of all legs, NOT a single leg. But `e0 = (1/sqrtf, 0, 0, 0)`, `e1 = (0, sqrtf, 0, 0)`, so `e[:, 2] = (0, sqrtf, 0, 0) = e1`. This works only because Schwarzschild tetrads have all legs with a single nonzero component.

  For Kerr, `e3 = (e3_t, 0, 0, e3_φ)` has two nonzero components. The Kerr layout `e[:, 4] = e3 = (e3_t, 0, 0, e3_φ)` whereas the Schwarzschild layout would give `e[:, 4] = (e0[4], e1[4], e2[4], e3[4]) = (0, 0, 0, e3_φ)` -- missing the `e3_t` component entirely. So there is an inconsistency between the two tetrad conventions. The Schwarzschild KS tetrad (schwarzschild_ks.jl:206-211) uses the same convention as the Kerr BL tetrad. The comment at line 203-205 says "columns = tetrad legs" which matches the Kerr/KS convention.

  The Schwarzschild BL tetrad at camera.jl:61-66 uses the TRANSPOSE convention. This is a **real bug**: the Schwarzschild BL tetrad is transposed relative to what `pixel_to_momentum` expects. It only works by coincidence because all Schwarzschild tetrad legs are axis-aligned (single nonzero component), making the matrix equal to its transpose.

- **Fix**: For consistency and future-proofing, fix the Schwarzschild BL tetrad at `camera.jl:61-66` to use the same convention as Kerr BL and KS:
  ```julia
  tetrad = SMat4d(
      e0[1], e0[2], e0[3], e0[4],
      e1[1], e1[2], e1[3], e1[4],
      e2[1], e2[2], e2[3], e2[4],
      e3[1], e3[2], e3[3], e3[4]
  )
  ```

---

### [SEVERITY: major] Kerr inverse metric `g^{tphi}` sign is wrong

- **Location**: `src/GR/metrics/kerr.jl:129`
- **Code**:
  ```julia
  gtφ = -2.0 * M * a * r * inv_ΣΔ
  ```
- **Issue**: The inverse metric for Kerr in Boyer-Lindquist has `g^{tφ} = -a (2Mr) / (Σ Δ)`. But the standard result from inverting the 2x2 (t,φ) block is:

  The determinant of the (t,φ) block is `g_tt * g_φφ - g_tφ^2`. The inverse gives:
  `g^{tφ} = -g_tφ / det = g_tφ / (Δ sin²θ)` (since det = -Δ sin²θ).

  With `g_tφ = -2Mar sin²θ/Σ`, we get `g^{tφ} = (-2Mar sin²θ/Σ) / (-Δ sin²θ) = 2Mar/(ΣΔ)`.

  The code has `gtφ = -2Mar/(ΣΔ)`, but the correct result is `g^{tφ} = +2Mar/(ΣΔ)` (note: some references use the opposite metric signature convention, but within this codebase the signature is (-,+,+,+)).

  Let me verify by checking the standard reference: for signature (-,+,+,+), the Kerr inverse metric has `g^{tφ} = -2Mar/(ΣΔ)`. Actually, rederiving: with `det_{tφ} = g_tt g_φφ - g_tφ²`, and `g^{tφ} = -g_tφ / det_{tφ}`. We have `det_{tφ} = -(1-2Mr/Σ)(r²+a²)² sin²θ/Σ + Δa²sin⁴θ/Σ - 4M²a²r²sin⁴θ/Σ²`. This simplifies to `-Δ sin²θ`. Then `g^{tφ} = -(-2Mar sin²θ/Σ) / (-Δ sin²θ) = -(2Mar sin²θ)/(Σ Δ sin²θ) = -2Mar/(ΣΔ)`.

  So the sign **is** correct. Withdrawing this finding.

  Actually wait -- I need to double check the `inv_ΣΔ` factor. `inv_ΣΔ = 1/(Σ Δ)`. So `gtφ = -2Mar/(ΣΔ)` which matches the derivation. This is correct after all.

**WITHDRAWN** -- the Kerr inverse metric is correct.

---

### [SEVERITY: major] `checkerboard_sphere` integer truncation before division

- **Location**: `src/GR/matter.jl:214`
- **Code**:
  ```julia
  cj = floor(Int, v * n_checks ÷ 2)
  ```
- **Issue**: Due to Julia operator precedence, `n_checks ÷ 2` is evaluated first (integer division), then `v * (n_checks ÷ 2)`, then `floor(Int, ...)`. For odd `n_checks`, this truncates. For example, with `n_checks=18` (even), `18 ÷ 2 = 9`, so `cj = floor(Int, v * 9)`. The intent is to have `n_checks` checks in the u-direction and `n_checks/2` in the v-direction (since θ covers only half the sphere). This happens to work for even `n_checks`, but for odd values it would lose a check band. However since the default is 18, this is minor.
- **Fix**: Use `cj = floor(Int, v * (n_checks / 2))` to avoid integer truncation.

---

### [SEVERITY: major] `renormalize_null` general fallback may pick wrong root when `p[1] == 0`

- **Location**: `src/GR/integrator.jl:200`
- **Code**:
  ```julia
  pt_new = (sign(p[1]) == sign(pt1)) ? pt1 : pt2
  ```
- **Issue**: `sign(0.0)` returns `0.0` in Julia. If `p[1]` is exactly zero, then `sign(p[1]) == 0.0`. Since neither `sign(pt1)` nor `sign(pt2)` is typically `0.0` (the roots of a quadratic are generically nonzero), neither branch matches, so `pt_new = pt2` always. For a photon on the null cone, `p_t = 0` is physically unrealizable for an observer outside the horizon, but numerical drift could bring it close to zero. In that case the choice of root becomes arbitrary rather than physically motivated.
- **Fix**: Add a fallback: pick the root with larger absolute value, or the one closer to the original `p[1]`, when `p[1] ≈ 0`.

---

### [SEVERITY: major] `_trace_pixel_thin_with_p0` uses BL sky angles for KS coordinates

- **Location**: `src/GR/render.jl:116-121` and `render.jl:129-131`
- **Code**:
  ```julia
  # Line 116 (after r >= cfg.r_max):
  θ, φ = x[3], x[4]
  # ...
  return checkerboard_sphere(θ, φ)

  # Line 129-131 (after max_steps exhausted):
  θ_f, φ_f = x[3], x[4]
  ```
- **Issue**: When using `SchwarzschildKS`, `x = (t, x_cart, y_cart, z_cart)`. The code takes `x[3]` as θ and `x[4]` as φ, but these are the Cartesian y and z components, NOT spherical angles. The volumetric renderer correctly uses `_sky_angles(m, x)` which dispatches to `ks_to_sky_angles` for KS coordinates. The thin-disk renderer bypasses this dispatch and directly reads BL-style angles.
- **Fix**: Use `_sky_angles(m, x)` or `_to_spherical(m, x)` to extract sky angles regardless of metric type.

---

### [SEVERITY: minor] `ROOT_TILE_VOXELS` overflow with `Int` on 32-bit systems

- **Location**: `src/Accessors.jl:187`
- **Code**:
  ```julia
  const ROOT_TILE_VOXELS = 4096^3
  ```
- **Issue**: `4096^3 = 68,719,476,736` which exceeds `typemax(Int32) = 2,147,483,647`. On a 32-bit Julia system (Int = Int32), this would overflow silently. On 64-bit systems this is fine. Technically, `4096` is an `Int` literal, so `4096^3` is `Int` arithmetic. On 64-bit, `Int` is `Int64` and 4096^3 fits. On 32-bit, this silently wraps to a negative number.
- **Fix**: Use `const ROOT_TILE_VOXELS = Int64(4096)^3` to ensure correctness on all platforms.

---

### [SEVERITY: minor] `Schwarzschild` metric `sin2θ` clamp creates a non-smooth metric for ForwardDiff

- **Location**: `src/GR/metrics/schwarzschild.jl:52` and `schwarzschild.jl:68`
- **Code**:
  ```julia
  sin2θ = max(sin(θ)^2, 1e-6)
  ```
- **Issue**: `max(x, 1e-6)` introduces a non-differentiable kink at `sin²θ = 1e-6`. When `metric_inverse_partials` uses ForwardDiff on the generic `metric_inverse` (not the analytic override), this kink makes the derivative incorrect near the poles. For Schwarzschild, the analytic partials override prevents this from being triggered by ForwardDiff, but if someone calls `ForwardDiff.jacobian` on `metric_inverse` directly, they will get wrong derivatives near θ=0 or θ=π.
- **Fix**: Use a smooth regularization like `sin2θ = sin(θ)^2 + 1e-6` (always adds epsilon instead of clamping).

---

### [SEVERITY: minor] `sinθ_safe` in Schwarzschild analytic partials can produce `sign(0)` = 0

- **Location**: `src/GR/metrics/schwarzschild.jl:127`
- **Code**:
  ```julia
  sinθ_safe = max(abs(sinθ), 1e-3) * sign(sinθ + 1e-20)
  ```
- **Issue**: When `sinθ` is exactly 0.0 (θ = 0 or π), `sinθ + 1e-20 = 1e-20`, so `sign(1e-20) = 1.0`. This works correctly. However, if `sinθ` is a very small negative number like `-1e-30`, then `sinθ + 1e-20 ≈ 1e-20 > 0`, so `sign(...)` returns `+1.0`, but the true sign of sinθ is negative. This sign flip near θ = π introduces a discontinuity in the derivative. The effect is limited since geodesics near the poles are regularized by the θ clamp, but it is mathematically incorrect.
- **Fix**: Use `sign(sinθ)` with a fallback: `sinθ_safe = max(abs(sinθ), 1e-3) * (sinθ >= 0.0 ? 1.0 : -1.0)`.

---

### [SEVERITY: minor] `integrate_geodesic` uses `x[2]` as radial coordinate for all metrics

- **Location**: `src/GR/integrator.jl:248`
- **Code**:
  ```julia
  r = x[2]
  ```
- **Issue**: Same as the critical finding for the thin-disk renderer, but in the general `integrate_geodesic` function. For Cartesian KS coordinates, `x[2]` is the x-component, not the radius. This makes the HORIZON and ESCAPED termination checks incorrect for KS. The function does not dispatch on metric type.
- **Fix**: Accept an optional extraction function, or dispatch on metric type to compute `r` correctly. The simplest fix is to add `_coord_r` dispatch (as the volumetric renderer does).

---

### [SEVERITY: minor] NanoGrid trilinear fast path assumes leaf offset layout `64*lx + 8*ly + lz`

- **Location**: `src/NanoVDB.jl:807`
- **Code**:
  ```julia
  c100 = Float64(_buf_load(T, buf, vbase + (base + 64) * szT))
  ```
- **Issue**: The fast-path trilinear interpolation computes neighbor offsets by adding 64 (for +1 in x), 8 (for +1 in y), and 1 (for +1 in z) to the base leaf offset. This is correct only if the leaf layout is `offset = 64*lx + 8*ly + lz`, which matches `leaf_offset(c)` in `Coordinates.jl:114`. However, if the layout ever changes, these hardcoded constants would silently produce wrong results. This is a code smell rather than a current bug, but the magic numbers `64`, `8`, `1`, `72`, `65`, `9`, `73` should reference named constants.
- **Fix**: Define constants `const LEAF_STRIDE_X = 64`, `const LEAF_STRIDE_Y = 8`, `const LEAF_STRIDE_Z = 1` and use them.

---

### [SEVERITY: minor] `dilate` overwrites existing voxel values with background

- **Location**: `src/Morphology.jl:31`
- **Code**:
  ```julia
  haskey(data, nc) || (data[nc] = bg)
  ```
- **Issue**: The iteration order over `active_voxels` is non-deterministic (Dict iteration). If voxel A is active and voxel B (neighbor of A) is also active, B's value gets correctly inserted first. But if B is processed after A, and B was a neighbor of an earlier voxel C, then B might already have been assigned `bg` by C's neighbor expansion. The `haskey` check prevents this. However, there is a subtle issue: the `data` dict is built incrementally. When processing voxel A and adding its neighbor B with `bg`, if B was not yet processed by the outer `active_voxels` loop, B will have value `bg` instead of its true value. This is because `data[c] = v` (line 28) will overwrite the `bg` when B is finally processed. But if B was already inserted with `bg` from being a neighbor, and then processed as an active voxel, `data[c] = v` correctly sets the real value.

  Actually this is fine -- the active voxel loop sets `data[c] = v` unconditionally for every active voxel, so any `bg` written by neighbor expansion will be overwritten. Not a bug.

**WITHDRAWN**

---

### [SEVERITY: minor] `_trace_pixel_thin_with_p0` does not check disk crossing for KS equatorial plane

- **Location**: `src/GR/render.jl:92-104` and `src/GR/matter.jl:134`
- **Code**:
  ```julia
  # check_disk_crossing uses θ_prev = prev.x[3] and θ_curr = curr.x[3]
  θ_prev = prev.x[3]
  θ_curr = curr.x[3]
  equator = π / 2.0
  ```
- **Issue**: For KS Cartesian coordinates, `x[3]` is the y-component, not θ. The disk crossing check compares `x[3]` against `π/2` which has no physical meaning in Cartesian coordinates. For KS, the equatorial plane is defined by `z = 0` (i.e., `x[4] = 0`), not `θ = π/2`. This means thin disk rendering with KS coordinates will never detect correct disk crossings.
- **Fix**: Add a KS-specific `check_disk_crossing` method that checks for `x[4]` sign change (z-coordinate crossing zero) and computes `r_cross` from Cartesian coordinates.

---

### [SEVERITY: minor] `_quad_weights` returns weights that don't sum to 1.0 for `t != 0`

- **Location**: `src/Interpolation.jl:150-155`
- **Code**:
  ```julia
  @inline function _quad_weights(t::T) where {T <: AbstractFloat}
      half = T(0.5)
      (half * (half - t)^2,
       T(0.75) - t * t,
       half * (half + t)^2)
  end
  ```
- **Issue**: These are the standard quadratic B-spline weights. Let's verify: `w(-1) + w(0) + w(1) = 0.5*(0.5-t)^2 + 0.75-t^2 + 0.5*(0.5+t)^2 = 0.5*(0.25 - t + t^2) + 0.75 - t^2 + 0.5*(0.25 + t + t^2) = 0.125 - 0.5t + 0.5t^2 + 0.75 - t^2 + 0.125 + 0.5t + 0.5t^2 = 1.0`. The weights do sum to 1.0. Not a bug.

**WITHDRAWN**

---

### [SEVERITY: minor] `srgb_gamma` handles negative values correctly but caller should clamp first

- **Location**: `src/GR/redshift.jl:209-211`
- **Code**:
  ```julia
  @inline function srgb_gamma(c::Float64)::Float64
      c <= 0.0031308 ? 12.92 * c : 1.055 * c^(1.0/2.4) - 0.055
  end
  ```
- **Issue**: If `c` is negative (which can happen from out-of-gamut XYZ to sRGB conversion), the `c <= 0.0031308` branch applies `12.92 * c`, producing a negative output. The caller `planck_to_rgb` at line 230 applies `max(r_lin, 0.0)` before calling `srgb_gamma`, so this is handled. Not a current bug, but `srgb_gamma` alone is unsafe for negative inputs.
- **Fix**: Clamp inside `srgb_gamma`: `c = max(c, 0.0)` at the top.

---

### [SEVERITY: minor] `verlet_step` applies θ regularization that won't work for KS coordinates

- **Location**: `src/GR/integrator.jl:129-136`
- **Code**:
  ```julia
  θ_new = x_new[3]
  if θ_new < 0.0
      x_new = SVec4d(x_new[1], x_new[2], -θ_new, x_new[4] + π)
      p_half = SVec4d(p_half[1], p_half[2], -p_half[3], p_half[4])
  elseif θ_new > π
      ...
  ```
- **Issue**: This θ-regularization assumes `x[3]` is the polar angle θ (Boyer-Lindquist). For Cartesian KS coordinates, `x[3]` is the y-component. Reflecting it and adding π to `x[4]` corrupts the Cartesian position. The Verlet stepper is not safe for Cartesian coordinate systems without disabling this regularization.
- **Fix**: Only apply θ-regularization for BL-type coordinates. Add a dispatch or a flag: `if isa(m, Schwarzschild) || isa(m, Kerr{BoyerLindquist})`.

---

### [SEVERITY: minor] `NanoGrid` root table overflow if > 8 root entries

- **Location**: `src/VolumeHDDA.jl:212` and `src/VolumeIntegrator.jl:86`
- **Code**:
  ```julia
  const _MAX_ROOTS = 8
  # ...
  n_roots > _MAX_ROOTS && break
  ```
- **Issue**: If a NanoGrid has more than 8 root-level I2 children that intersect a ray, only the first 8 are processed. The remaining are silently dropped. For typical VDB grids this is unlikely (root entries cover 4096^3 voxels each), but for highly fragmented grids spanning large coordinate ranges, this could silently clip the volume.
- **Fix**: Either increase `_MAX_ROOTS` or dynamically fall back to a heap-allocated vector when exceeded.

---

### [SEVERITY: nit] `dot(p, u)` in `redshift_factor` contracts covariant p with contravariant u without metric

- **Location**: `src/GR/redshift.jl:16`
- **Code**:
  ```julia
  dot(p_emit, u_emit) / dot(p_obs, u_obs)
  ```
- **Issue**: The comment says "p is covariant (lower index), u is contravariant (upper index), so the contraction is just `dot(p, u)`." This is correct: `p_μ u^μ = Σ p_μ u^μ` is a coordinate scalar computed by component-wise multiply and sum, which is exactly what `dot` does. No metric needed. Not a bug -- just a comment that might confuse readers unfamiliar with index notation.
- **Fix**: None needed (comment is correct).

---

### [SEVERITY: nit] `Accessors.jl:187` constant `INTERNAL2_TILE_VOXELS = 128^3` is 2,097,152

- **Location**: `src/Accessors.jl:188`
- **Code**:
  ```julia
  const INTERNAL2_TILE_VOXELS = 128^3
  ```
- **Issue**: An I2 tile covers an Internal1-node-sized region. An Internal1 node covers 16x16x16 children, each 8x8x8 = 512 voxels. So an I2 tile should cover `16^3 * 8^3 = 4096 * 512 = 2,097,152 = 128^3`. This is correct. Not a bug.

**WITHDRAWN**

---

### [SEVERITY: nit] Schwarzschild `metric` and `metric_inverse` accept `SVector{4}` (any element type) but return Float64

- **Location**: `src/GR/metrics/schwarzschild.jl:47` and `schwarzschild.jl:63`
- **Code**:
  ```julia
  function metric(s::Schwarzschild{SchwarzschildCoordinates}, x::SVector{4})
  ```
- **Issue**: The signature accepts `SVector{4}` of any element type (including `ForwardDiff.Dual`) which is needed for automatic differentiation. However, `z = zero(r)` and operations like `1/f` will produce `Dual` types when `r` is `Dual`, so the return type will be `SMatrix{4,4,Dual,...}`, not `SMat4d`. This is correct for ForwardDiff to work. The explicit `SMat4d` return type annotation on `metric_inverse_partials` (line 42) could be problematic if someone overrides `metric_inverse` with a function that accepts `Dual` arguments -- but the analytic override for Schwarzschild takes `SVec4d` (Float64 only), so ForwardDiff is never used for Schwarzschild. Correct by design.
- **Fix**: None needed.

---

### [SEVERITY: nit] `_do_step` dispatches on `Symbol` at runtime

- **Location**: `src/GR/integrator.jl:210-213`
- **Code**:
  ```julia
  @inline function _do_step(m::MetricSpace{4}, x::SVec4d, p::SVec4d, dl::Float64,
                             stepper::Symbol)::Tuple{SVec4d, SVec4d}
      stepper === :rk4 ? rk4_step(m, x, p, dl) : verlet_step(m, x, p, dl)
  end
  ```
- **Issue**: Using a `Symbol` for stepper selection prevents the compiler from specializing the call. Julia's compiler cannot specialize on runtime `Symbol` values, so `_do_step` will not be inlined into the caller's compiled code and both `rk4_step` and `verlet_step` branches exist at runtime. For a hot inner loop (geodesic integration), this adds unnecessary overhead.
- **Fix**: Use a type parameter instead of a Symbol: `struct RK4Stepper end; struct VerletStepper end` and dispatch on the type.

---

### [SEVERITY: nit] Unused `patch_area` variable in `denoise_nlm`

- **Location**: `src/Output.jl:117`
- **Code**:
  ```julia
  patch_area = T((2 * patch_radius + 1)^2)
  ```
- **Issue**: `patch_area` is computed but never used. The patch distance normalization on line 149 uses `T(count)` instead.
- **Fix**: Remove the unused variable.

---

### [SEVERITY: nit] `_is_background` for NTuple only checks positive background, not negative

- **Location**: `src/Interpolation.jl:224`
- **Code**:
  ```julia
  _is_background(val::NTuple{N,T}, bg::NTuple{N,T}) where {N, T <: AbstractFloat} = (val == bg)
  ```
- **Issue**: For scalar types, `_is_background` checks both `val == bg` and `val == -bg` (for level sets where the background outside is `+bg` and inside is `-bg`). For vector types (NTuple), only positive background is checked. This means trilinear interpolation for vector grids near the narrow band boundary won't fall back to nearest-neighbor when a corner has value `-bg`. However, for vector grids (e.g., velocity fields), negative background is not a standard convention, so this is unlikely to cause issues in practice.
- **Fix**: Add `|| val == map(-, bg)` if negative-background detection is needed for vector grids. Otherwise, document the intentional difference.

---

### [SEVERITY: nit] `write_ppm` uses text format (P3) which is very slow for large images

- **Location**: `src/Render.jl:254`
- **Code**:
  ```julia
  println(io, "P3")
  ```
- **Issue**: PPM P3 format writes pixel values as ASCII text, which is approximately 5-10x larger and slower to write than binary P6 format. For a 1920x1080 image, P3 produces ~30 MB of text vs ~6 MB for P6.
- **Fix**: Use P6 binary format:
  ```julia
  println(io, "P6\n$width $height\n255")
  for y in 1:height, x in 1:width
      r, g, b = pixels[y, x]
      write(io, UInt8(clamp(round(Int, r*255), 0, 255)))
      write(io, UInt8(clamp(round(Int, g*255), 0, 255)))
      write(io, UInt8(clamp(round(Int, b*255), 0, 255)))
  end
  ```
