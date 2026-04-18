# CLAUDE.md — Lyr.jl

## What is this?
Lyr.jl is an agent-native physics visualization platform: a pure-Julia OpenVDB parser, a production volume renderer (CPU + CUDA GPU via `ext/LyrCUDAExt.jl`), a general-relativistic ray tracer (`Lyr.GR`), and the **Field Protocol** — the universal interface between continuous physics and grid-based rendering. No GUI. Natural-language and code-driven only.

See `VISION.md`, `PRD.md`, `PRD-GR.md` for product direction.
See `docs/stocktake/INDEX.md` for the **full architectural map** (every src file, every subsystem, bottlenecks, smells).
See `docs/api_reference.md` for exhaustive signatures.
See `docs/lessons.md` for crash recovery and implementation pitfalls.

---

## THE TWO LAWS (non-negotiable, read first, every session)

**LAW 1 — RED-GREEN TDD.** Every non-trivial change starts with a *failing* test. No code before a red bar. The loop is: write a test that captures the intent → run the suite → confirm it fails for the right reason → write the minimum code to make it green → refactor. No exceptions for "obvious" changes; obvious changes are where tests find surprises. Bug fixes start with a `@test_broken` that reproduces the bug before the fix.

**LAW 2 — GROUND TRUTH BEFORE CODE.** Before writing any physics, rendering, or format-parsing code, open and read the ground-truth source: the paper, the OpenVDB spec, the WebGL volume-rendering reference, the GR monograph. Ground truth = (a) a local copy of the source, (b) a specific equation or section reference. Never code from memory. Never code from an LLM's recollection of a paper. If the source is not locally available, acquire it first (`refs/papers/`, OpenVDB GitHub mirror, etc.) — do not proceed without it. Cite the source in code:
```julia
# Ref: refs/papers/Museth2013-VDB.pdf, §4.2
# "A leaf node is an 8³ array of voxels..."
```

---

## THE RULES (numbered, follow to the letter)

0. **LAWS 1 & 2 APPLY.** Red-green TDD. Ground truth before code.
1. **PHYSICS IS GROUND TRUTH.** Not pinned numbers. Not golden images (they lie). Not previous test outputs. Analytic benchmarks (Beer-Lambert, white-furnace, HG moments, Schwarzschild ISCO, NT disk flux) are the oracle.
2. **SKEPTICISM.** Verify every subagent report twice. Verify previous-session claims against current source. Verify your own assumptions against a REPL check.
3. **ALL BUGS ARE DEEP.** No bandaids. No "temporary fixes". Root-cause every failure. `fjo9` (Float32 DDA nudge below ULP) was 3.5× dimmer output from a one-token bug that survived three subagent static-analysis passes — assume every bug is that deep.
4. **TIERED WORKFLOW.** Scale effort to change size:
   - **Trivial** (<5 LOC, typo/rename/comment): direct fix, 1 failing test, no subagents.
   - **Small** (<30 LOC, one function): 1 research subagent + TDD + 1 reviewer.
   - **Core** (new type / new algorithm / >30 LOC / cross-module): **3 research subagents + TDD + 1 reviewer**. Proposers must not see each other's output. Orchestrator picks the best design or synthesizes.
5. **GET FEEDBACK FAST.** Never code 500 lines before running the suite. Every ~50 lines: `julia --project test/test_<relevant>.jl` on the targeted file. Full suite only in background or at the end.
6. **FAIL FAST, FAIL LOUD.** Assertions, not silent returns. `error("clear message with values: $x")`, not `return nothing`. Crashes with context beat quiet corruption.
7. **LITERATE CODING.** Every non-trivial function has a docstring: WHAT it does, WHY it exists, WHICH equation it implements (Law 2). Comments explain intent (the *why*), not mechanics. The code already shows *what*.
8. **JULIA IDIOMATIC.** Parametric types over tagged unions. Multiple dispatch over `isa`-cascades. Concrete unions over `Any`. Named constructors as plain functions, not wrapper structs. ScopedValues for implicit context, never globals. `@inline` only where profiled. See `docs/api_reference.md` and report `04_gpu_rendering.md` for GPU-specific idioms (`@inline` on large kernels HURTS).
9. **NO PARALLEL JULIA AGENTS.** Julia precompilation cache corrupts under concurrent load. Read-only research/reading subagents **can** run in parallel (they do not invoke `julia`). Anything that runs `julia` — tests, REPL checks, compilation — serial only.
10. **RESEARCH IDIOMS FIRST.** Before a new subsystem: 15 minutes in `docs/stocktake/`, `docs/api_reference.md`, `docs/lessons.md`. Before a new file type or format: read the spec.
11. **LOC LIMIT.** New source files target ~200 lines. Legacy files over the limit are refactor candidates; don't grow them further without a split plan.
12. **DEMAND ELEGANCE (balanced).** On non-trivial changes, pause: "is there a more elegant way?" If the answer is yes and the cost is reasonable, take it. Skip this for obvious fixes.
13. **DEMO AFTER FEATURE-SET COMPLETION.** Every logical feature group ends with a script in `examples/` that exercises the public API end-to-end, writes a visual result to `showcase/`, and runs clean under `julia --project`. See `examples/grid_operations_demo.jl` as the template. Demos catch API friction that tests miss.
14. **SESSION CLOSE PROTOCOL** (mandatory):
    1. `git status` — see what changed
    2. `git add <files>` — stage
    3. `git commit -m "..."` — descriptive
    4. `git push` — push to remote
    5. `bd dolt push` — push beads to Dolt
    6. Update `HANDOFF.md` if the session completed a meaningful chunk
    7. Capture lessons in `docs/lessons.md` if any corrections landed
    Work is NOT complete until `git push` succeeds.
15. **REPEAT RULES.** Reread this file at session start and after any context compression.

---

## THE FIELD PROTOCOL PRINCIPLE

**The Field Protocol is the architecture. If a physics module bypasses it, the architecture is incomplete.**

All new physics modules (QFT, fluids, elasticity, quantum dynamics) MUST implement `AbstractContinuousField` or `AbstractDiscreteField` with the four required methods: `evaluate`, `domain`, `field_eltype`, `characteristic_scale`. Hand-rolled render paths that skip `voxelize`/`visualize` are reference implementations for cross-validation, not substitutes. Every reference implementation must eventually have a Field-Protocol-native counterpart that reproduces the same result. See `docs/stocktake/06_field_protocol.md`.

---

## Build & test

```bash
# Targeted (fast, preferred during dev)
julia --project test/test_<subsystem>.jl

# Full suite (background only, ~18 min on WSL2 with -t 2)
julia --project -t 2 -e 'using Pkg; Pkg.test()'

# NEVER use -t auto for Pkg.test() on WSL2 — 59GB+ RAM can kill WSL.
```

---

## Cheat sheets

### Rendering (easy to get wrong)
```julia
cam = Camera((50.0, 40.0, 30.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)  # tuples, not SVec3d
mat = VolumeMaterial(tf_blackbody(); sigma_scale=15.0)  # tf is first positional
nano = build_nanogrid(grid.tree)  # REQUIRED before rendering
vol = VolumeEntry(grid, nano, mat)
scene = Scene(cam, DirectionalLight((1.0, 1.0, 1.0), (1.0, 0.5, 1.0)), vol)
img = render_volume_image(scene, 800, 600; spp=32)
write_ppm("output.ppm", img)
```

### Grid building
```julia
sphere = create_level_set_sphere(center=(0.0,0.0,0.0), radius=10.0)
box    = create_level_set_box(min_corner=(-5.0,-5.0,-5.0), max_corner=(5.0,5.0,5.0))

grid = particles_to_sdf(positions, radii; voxel_size=0.5)
grid = mesh_to_level_set(vertices, faces; voxel_size=0.5)  # closed manifold mesh
grid = build_grid(Dict(coord(0,0,0) => 1.0f0), 0.0f0; name="density")
grid = copy_from_dense(array3d, 0.0f0)

csg_union(a, b)         # min(sdf_a, sdf_b)
csg_intersection(a, b)  # max(sdf_a, sdf_b)
csg_difference(a, b)    # max(sdf_a, -sdf_b)
```

### Field Protocol (the architecture)
```julia
field = ScalarField3D((x,y,z) -> exp(-(x^2+y^2+z^2)/50),
                      BoxDomain(SVec3d(-10,-10,-10), SVec3d(10,10,10)), 5.0)
img = visualize(field)  # one-call: voxelize → render
grid = voxelize(field)  # just voxelize
```

### Key gotchas
- Camera takes tuples, not SVec3d
- `build_nanogrid(grid.tree)` required before rendering
- Level sets: negative = inside, positive = outside
- All grid ops return new grids (immutable trees)
- `write_png` requires `using PNGFiles` before `using Lyr`
- `BoxDomain` uses `SVec3d` (world space) ≠ `BBox` uses Int32 Coord (index space)
- `1e-5f0` is NOT valid Julia — use `Float32(1e-5)`
- Float32 absolute epsilons are a trap — always use relative (see lesson `fjo9`)

---

## Issue tracking: Beads

```bash
bd ready                         # find available work
bd show <id>                     # details
bd update <id> --status in_progress   # claim
bd close <id>                    # complete
bd close <id1> <id2> ...         # batch close
bd create --title="..." --description="..." --type=task|bug|feature --priority=2
bd dep add <issue> <depends-on>  # issue depends on depends-on
bd blocked                       # dependency view
bd stats                         # project health
bd remember "<insight>"          # persistent cross-session memory
bd memories <keyword>            # search memories
```

Rules:
- Every non-trivial change starts with a bead. File the bead BEFORE writing the failing test.
- Do NOT use TodoWrite, TaskCreate, or markdown TODOs.
- Respect dependencies. `bd blocked` before picking up work.
- Session end: `bd dolt push` is part of the close protocol.

---

## Julia Idiom Cheatsheet

### DO
```julia
# Parametric types for dispatch
struct VolumeEntry{G<:Grid, N<:NanoGrid, M<:AbstractMaterial}
    grid::G; nanogrid::N; material::M
end

# Multiple dispatch, not isa cascades
evaluate(f::ScalarField3D, x, y, z) = f.fn(x, y, z)
evaluate(f::VectorField3D, x, y, z) = f.fn(x, y, z)

# Concrete small Unions for type stability
const PhaseFunction = Union{IsotropicPhase, HenyeyGreensteinPhase}

# NTuple for zero-alloc small fixed-size data
struct LeafNode{T}; values::NTuple{512, T}; end

# @fastmath / @inbounds on profiled hot paths only
# const for compile-time globals
```

### DO NOT
```julia
# ✗ isa checks instead of dispatch
if m isa IsotropicPhase ... elseif m isa HenyeyGreensteinPhase ... end

# ✗ Any-typed fields
struct BadVolume; material::Any; end

# ✗ Type-in-function-name (Java style)
evaluate_scalar_field(f, x, y, z)   # ✗ → evaluate(f::ScalarField3D, x, y, z)

# ✗ Mutable globals
CURRENT_SCENE = nothing             # ✗ → const CURRENT_SCENE = ScopedValue(nothing)

# ✗ @inline on large GPU kernels — register spilling halves throughput
@inline function delta_tracking_hdda_kernel!(...)  # ✗
```

---

## GPU-specific lessons (from `fjo9` and prior sessions)

1. **Float32 absolute epsilons are a trap.** `tmin + 1e-6f0` is a no-op when `tmin > 8` (ULP exceeds 1e-6). Use `max(abs(tmin)*1e-5, 1e-5)`.
2. **`reinterpret(T, @view buf[...])`** is NOT GPU-safe — creates a ReinterpretArray. Use scalar byte-by-byte reads + scalar `reinterpret(Float32, ::UInt32)` (register bitcast).
3. **CUDA scalar indexing** of `CuArray` is disallowed — `Array(device_buf)` before pixel access.
4. **CUDA `val, loff = f(...)` vs `_, loff = f(...)`** produce different codegen that can trigger MISALIGNED_ADDRESS. Do not "optimize" the discard.
5. **WSL2 + CUDA** works via GPU passthrough but is memory-fragile. Always `-t 2`, never `Pkg.test()` with all threads.
6. **CUDA in `[weakdeps]`** alone doesn't allow `using CUDA` in the package's own env during dev — must also be in `[deps]`.

---

## Session Close Protocol — MANDATORY

Before saying "done":

```bash
[ ] git status                 # what changed?
[ ] git add <specific files>   # stage (never -A)
[ ] git commit -m "..."        # descriptive
[ ] git push                   # to remote
[ ] bd dolt push               # beads to Dolt
[ ] HANDOFF.md updated?        # if meaningful chunk closed
[ ] docs/lessons.md updated?   # if corrections landed
```

Work is NOT complete until `git push` succeeds. If push fails, resolve and retry. Never leave work stranded locally.
