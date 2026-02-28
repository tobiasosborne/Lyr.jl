# CLAUDE.md

## Workflow Orchestration

### 1. Plan Mode Default

- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately -- don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### 2. Subagent Strategy

- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

### 3. Self-Improvement Loop

- After ANY correction from the user: update `docs/lessons.md` with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review `docs/lessons.md` at session start

### 4. Verification Before Done

- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)

- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes -- don't over-engineer
- Challenge your own work before presenting it

### 6. Autonomous Bug Fixing

- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests -- then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

### 7. Demo After Feature Set Completion

When a logical group of features is complete (e.g., all Phase 1 items, or all CSG operations), **create a demo script** in `examples/` that:

- Exercises every new function with realistic, application-near usage
- Prints clear output showing what each operation does (voxel counts, file sizes, timing)
- Renders at least one image showcasing the visual result (volume render of CSG, particles, etc.)
- Saves output images to `showcase/` for the README/portfolio
- Is self-contained: runs with `julia --project examples/demo_name.jl`
- Uses the actual public API (catches bad ergonomics early)

**Why**: Demos are the best integration test. They catch API friction, verify the render pipeline end-to-end, and produce visual proof of work. See `examples/grid_operations_demo.jl` as the template.

**API cheat sheet for rendering** (easy to get wrong):
```julia
cam = Camera((50.0, 40.0, 30.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)  # tuples, not SVec3d
mat = VolumeMaterial(tf_blackbody(); sigma_scale=15.0)  # tf is first positional, rest keyword
nano = build_nanogrid(grid.tree)  # REQUIRED before rendering
vol = VolumeEntry(grid, nano, mat)  # positional: grid, nanogrid, material
scene = Scene(cam, DirectionalLight((1.0, 1.0, 1.0), (1.0, 0.5, 1.0)), vol)  # positional: cam, light(s), vol(s)
img = render_volume_image(scene, 800, 600; spp=32)
write_ppm("output.ppm", img)
```

## Task Management

- **Plan First**: Create beads issues (`bd create`) with clear scope before coding
- **Verify Plan**: Check in before starting implementation
- **Track Progress**: `bd update <id> --status in_progress` when starting, `bd close <id>` when done
- **Explain Changes**: High-level summary at each step
- **Document Results**: Update `HANDOFF.md` with session summary
- **Demo After Completion**: Create demo script exercising all new features (see rule 7 above)
- **Capture Lessons**: Update `docs/lessons.md` after corrections

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Impact minimal code.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.

## Beads (Issue Tracking)

```bash
bd ready                    # What can I work on?
bd show <id>                # Issue details
bd update <id> --status in_progress  # Claim work
bd close <id>               # When complete
bd close <id1> <id2> ...    # Close multiple at once
bd sync                     # Sync with git remote
bd create --title="..." --description="..." --type=task|bug|feature --priority=2
bd dep add <issue> <depends-on>  # Add dependency
bd blocked                  # Show blocked issues
bd stats                    # Project statistics
```

Issues have dependencies. Respect the DAG.
