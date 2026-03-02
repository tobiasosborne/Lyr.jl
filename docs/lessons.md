# Lyr.jl — Lessons Learned

## Session Crash Recovery (2026-03-02)

**Problem**: Claude Code sessions crash, losing valuable research and plans.

**Recovery technique**:
1. Session transcripts are stored as JSONL files in `~/.claude/projects/<project-hash>/`
2. Subagent transcripts are in `<session-id>/subagents/agent-*.jsonl`
3. Most recent sessions: `ls -lt ~/.claude/projects/<hash>/*.jsonl | head -5`
4. Extract assistant text blocks with `json.loads()` → filter by `type == 'assistant'` → `message.content[].text`
5. Extract subagent prompts from `tool_use` blocks with `input.prompt` field
6. Subagent final results are the last substantial `assistant` text block in their JSONL

**Prevention**:
- Save research to files early (don't keep it only in context)
- For multi-step research, write intermediate results to `docs/` or memory files
- Create beads issues with detailed descriptions so the plan survives crashes
- If a plan is valuable, write it to a file BEFORE starting implementation

## Benchmark VDB Research Sources (2026-03-02)

**Key resources identified for volumetric renderer validation**:
- OpenVDB official models: `https://artifacts.aswf.io/io/aswf/openvdb/models/<name>.vdb/1.0.0/`
- Disney Cloud: `disneyanimation.com/resources/clouds/` (CC-BY-SA 3.0)
- PBRT-v4 scenes: `github.com/mmp/pbrt-v4-scenes` (with reference renders)
- Shadeops volumes: `github.com/shadeops/pbrt-v4-volumes` (8+ scenes with reference PNGs)
- Analytical benchmarks: Beer-Lambert, white furnace, Chandrasekhar H-functions

**Key papers**:
- Sun et al. 2005 — single-scatter analytical solution
- Fong et al. 2017 — Production Volume Rendering (SIGGRAPH course)
- Novák et al. 2018 — Monte Carlo Methods for Volumetric Light Transport (survey)
- Kutz et al. 2017 — Spectral and Decomposition Tracking
- Miller et al. 2019 — null-scattering formulation (PBRT-v4 basis)

## Ground Truth Test Framework Implementation (2026-03-02)

**Architecture decisions**:
- `test/test_ground_truth.jl` — 825 tests across 4 tiers
- Inline `_mean`/`_std` helpers instead of `using Statistics` (not in test deps)
- Constant TF `_TF_OPAQUE_WHITE` decouples TF lookup from extinction math for analytical tests
- N=17 voxels gives clean path_length=16 through center (AABB spans [0,16])
- N=33 for statistical tests where boundary effects matter more

**Pitfalls discovered**:
- `Statistics.jl` is NOT in Lyr.jl test dependencies — use inline helpers
- `PhaseFunction` type is NOT exported — must `import Lyr: PhaseFunction`
- `dot`, `norm` from LinearAlgebra needed when running standalone (runtests.jl imports via other paths)
- Trilinear interpolation at grid boundaries reduces effective density by ~1 voxel on each side
- For `delta_tracking_step` with density=d and sigma_maj=S: escape prob = exp(-d*S*path) but boundary ramp makes measured rate ~5-10% higher for small boxes
- Single-scatter renderer doesn't separate albedo well at low SPP — use multi-scatter for albedo tests
- Higher extinction doesn't always mean darker center — surface scattering increases, making direction of brightness change ambiguous
- `tf_smoke()` at density=1.0 gives BLACK color (r=0,g=0,b=0,a=1) — use custom TF for emission tests
- Phase function divides by 4π ≈ 12.6 — light intensity needs ~10-15x to be visible

**White furnace test insight**:
- With `emission_scale=0`, `light_intensity=(0,0,0)`, `albedo=1.0`: throughput stays exactly 1.0
- Background added at full weight regardless of scattering → pixels == background EXACTLY (atol=1e-10)
- This is variance-free (no Monte Carlo noise) because the only contribution is deterministic background

## Cross-Renderer Comparison (2026-03-02)

**Mitsuba 3 as ground truth oracle**:
- Install: `uv venv .mitsuba-env && .mitsuba-env/bin/python3 -m pip install mitsuba numpy`
- Python API: `mi.set_variant('scalar_rgb')`, `mi.load_dict({...})`, `mi.render(scene)`
- Output: numpy float32 arrays — save as raw binary with 12-byte header (H,W,C as uint32)
- `scalar_rgb` variant = one-ray-at-a-time, simplest, good for ground truth

**Parameter mapping pitfalls**:
- Mitsuba `direction` in `directional` emitter = light TRAVEL direction (toward scene)
- Lyr `DirectionalLight(dir, ...)` = direction TOWARD the light (away from scene)
- Must negate: Mitsuba `(0,0,-1)` → Lyr `(0,0,1)`
- Mitsuba `homogeneous` medium = zero spatial lookups, constant sigma_t everywhere
- Lyr fog sphere = VDB tree with density=1.0 voxels + trilinear interpolation — 10-50x slower

**Performance lesson**:
- 256×256 × 512 spp through VDB = minutes, not seconds
- Mitsuba `homogeneous` does same in 5 seconds (no tree traversal)
- **Must add HomogeneousMedium fast path** or drop to 64×64 for tests
- Never promise "fast" without profiling the actual code path

**Transfer function insight**:
- Lyr's TF is visualization (maps density→color), not physics
- For cross-renderer comparison: constant white TF `(1,1,1,1)`, `emission_scale=1.0`
- This reduces Lyr's rendering equation to standard radiative transfer
- Lyr is a SUPERSET of Mitsuba (can do everything Mitsuba does + visualization coloring)
