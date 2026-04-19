# Milestone Implementation Plan

A high-level breakdown of each milestone from the architecture document. Each entry describes the work required, the files produced, the dependencies assumed from prior milestones, and the "done when" criterion that signals readiness for the next milestone.

The intent is that each section can be expanded into a full specification — acceptance tests, API contracts, shader I/O layouts — without reshuffling the overall plan.

---

## Milestone 1 — Platform + GL Context + SPIR-V Shader Loader

**Goal:** A window opens, displays a single fullscreen quad running a fragment shader loaded from disk, and reloads that shader when the file changes.

**Scope (~600 LOC):**

This milestone is foundational plumbing. We don't render anything voxel-related; we just prove the entire toolchain works end-to-end. By the end, changes to a `.frag` file on disk should be reflected in the running window within a second of saving.

**What gets built:**

- `platform::window` — GLFW wrapper for context creation, window management, input polling, resize events. Creates an OpenGL 4.6 core-profile context with debug output enabled. Handles the swap/poll loop.
- `platform::time` — frame timing: wall clock, `dt`, FPS counter. Trivial but needed everywhere.
- `gpu::gl` — glad-generated raw bindings, marked `@local` to keep the rest of the codebase from accidentally importing them.
- `gpu::shader` (first pass) — GLSL→SPIR-V compilation via subprocess call to `glslc`, SPIR-V loading via `ARB_gl_spirv`, hot-reload via filesystem polling. Returns a `Shader?` for failed compiles. Uniform cache stub (we don't need it yet, but we establish the interface).
- `gpu::buffer` (stub) — just enough to create a single fullscreen-quad VBO. Full buffer API comes later.
- `main.c3` — window loop: poll events, check for shader reload, clear, draw fullscreen quad, swap.
- One test shader: `shaders/hello.frag` that does `gl_FragColor = vec4(uv.x, uv.y, sin(time), 1.0);` so we can eyeball that uniforms and time are flowing.

**Dependencies:** None. This is the start.

**Done when:**
- Window opens at 1280×720, stays responsive (handles close, Esc key, resize).
- The hello shader renders a visible animated gradient.
- Editing `hello.frag` and saving causes the running window to pick up the change within ~1 second, with no crash on syntax errors (just logged and retry).
- A broken shader keeps the previous version running; recovery is automatic on next save.

**Out of scope for this milestone:** Compute shaders, SSBOs, 3D textures, render-to-texture. Those come with milestone 3.

---

## Milestone 2 — The `gpu::Commands` Command Recording Layer

**Goal:** Every draw/dispatch/barrier call from outside `gpu/` goes through the `Commands` interface. Tested end-to-end by drawing a single rotating triangle.

**Scope (~400 LOC):**

The command interface is the Vulkan-portability firewall. Getting it right here, before any heavy pipeline logic exists, is important because changing it later would touch every call site.

**What gets built:**

- `gpu::resource` — opaque handle types for `Texture2D`, `Texture3D`, `Buffer`, `Framebuffer`, `Shader`. All `@private` typedefs over `uint` in the GL backend.
- `gpu::cmd` — the `Commands` struct plus its methods: `begin_frame`, `end_frame`, `bind_shader`, `bind_texture`, `bind_image`, `bind_ubo`, `bind_ssbo`, `bind_framebuffer`, `dispatch`, `draw_fullscreen_quad`, `barrier`, `set_push_constants`. In the GL backend each is a thin wrapper around the corresponding GL call.
- `gpu::buffer` — full VBO/UBO/SSBO creation, upload, destroy. `upload_slice(T[])` helper for structured uploads.
- `gpu::framebuffer` — FBO creation with attachments, the `draw_fullscreen_quad` helper (binds the singleton quad VAO, issues a non-indexed 6-vertex draw).
- A triangle test: create VBO with 3 vertices, hard-coded shader, spin it with a time uniform fed through a UBO. No direct GL calls from test code.

**Dependencies:** Milestone 1 (window, shader loader).

**Done when:**
- The rotating triangle renders correctly.
- Grepping the codebase outside `gpu/` for `glXxx` returns zero hits.
- `gpu::cmd` calls all produce identical behavior to equivalent direct GL calls (verified by occasionally rewriting a test in raw GL and diffing).
- Buffer creation, resize, and destroy don't leak (checked with `glGet*` queries on object counts).

**Out of scope:** Multiple frames in flight, persistent mapping tricks, async buffer updates. Simple synchronous operations only.

---

## Milestone 3 — Single-Volume Prototype

**Goal:** One hardcoded 128³ voxel volume, filled by a compute shader, ray-marched to a 2D output texture, displayed on screen. No streaming, no hierarchy — just prove the core pipeline works.

**Scope (~600 LOC):**

This is the first voxel-related milestone and the highest-risk one. Everything after this iterates on and scales the pattern established here. The prototype doesn't need to look good — it needs to prove the ray march produces correct output for a known input.

**What gets built:**

- `gpu::texture` — full 3D texture creation via `glCreateTextures(GL_TEXTURE_3D)`, `glTextureStorage3D`, `imageStore` / `imageLoad` binding. Also 2D for the output.
- `shaders/test_generate.comp` — fills a 128³ volume with a simple procedural shape (sphere, torus, or Menger sponge — something unambiguous).
- `shaders/test_raymarch.comp` — ray-marches the volume with fixed 1-voxel steps. Outputs height + material to a 2D image. Hardcoded camera from a fixed angle.
- `shaders/present.frag` — fragment shader that reads the 2D output and draws it full-screen with some simple shading (dot product with a hardcoded light) just to confirm the height/normal output is sensible.
- `main.c3` orchestration: create the volume and output textures once, run generate once, ray-march once, then loop presenting the result.

**Dependencies:** Milestones 1-2.

**Done when:**
- A recognizable procedural shape (sphere, torus) appears on screen, clearly shaded by the fragment pass.
- Changing the shape in the generate shader, saving, and seeing the new shape appear proves the hot-reload path works for compute shaders too.
- Profiling shows generate takes <5 ms, ray march takes <10 ms at 1080p for a dense shape.

**Out of scope:** Correct normals (will be refined later), materials (just solid color for now), transparency, anti-aliasing. This is a functional test, not a beauty contest.

---

## Milestone 4 — Jump-Flood Distance Field

**Goal:** Add a 32³ distance field as an acceleration structure and measure the ray-march speedup.

**Scope (~200 LOC):**

Short but important. The JFA is mechanically simple (two small compute shaders run in a loop), but we want solid before/after numbers because the DF format choice (32³ vs 128³) was justified by cache behavior, and we should confirm that analysis empirically.

**What gets built:**

- `shaders/df_init.comp` — reads the 128³ volume, writes 0 to `dist_field` where voxel is solid, 255 where empty. Resolution 32³ (one DF texel per 4³ voxel region; conservative).
- `shaders/df_step.comp` — JFA propagation step with a uniform `step` parameter. Reads `dist_field`, writes `dist_field` (in-place is safe if we're careful with the update pattern).
- `voxel::distance_field` — C3 side: the 5-pass loop with halving step sizes (16, 8, 4, 2, 1).
- Update `test_raymarch.comp` to sample `dist_field` and skip empty space in jumps. Keep a `#define USE_DF 1/0` to A/B compare.
- Profiling instrumentation: GPU timer queries around the ray march pass, reporting median time over 60 frames.

**Dependencies:** Milestone 3.

**Done when:**
- With `USE_DF 1`, ray-march time drops by 3-5× on a terrain-like scene compared to `USE_DF 0`.
- JFA build time is <0.5 ms for a 32³ DF on mid-range hardware.
- Output image is pixel-identical between DF and non-DF paths (the DF should only change how fast we get there, not what we get).

**Out of scope:** Hierarchical DF, finer resolutions. Stay at 32³ unless profiling shows a pathology.

---

## Milestone 5 — Isometric Projection

**Goal:** Wire up the world-to-screen transformation so the volume renders at the correct screen position for a given world position, matching VoxelQuest's isometric look.

**Scope (~150 LOC):**

Small milestone but visually important — it's the first time things "look like the game." The math is well-understood; most of the work is plumbing the camera state through to the right shaders.

**What gets built:**

- `core::math` additions: `mat4` construction helpers for the specific isometric projection VQ uses: `screen.x = world.x - world.y; screen.y = -itilt*x - itilt*y + tilt*2*z`.
- `game::camera` — `CameraState` struct with `position`, `zoom`, `tilt`, `view_proj_iso` matrix. Input wiring for pan and zoom.
- Update the ray-march compute shader to take `view_proj_iso` and a `tilt` uniform, and derive ray entry/exit by intersecting the camera ray with the volume AABB (slab method).
- Update `main.c3` to compute the output texture size based on the volume's projected screen footprint rather than fixed 1080p.

**Dependencies:** Milestone 4.

**Done when:**
- Mouse drag pans the camera, scroll wheel zooms. Both feel responsive.
- The test volume renders with the expected isometric projection — vertical walls look vertical, horizontal surfaces slope at the isometric angle.
- Zooming in shows no aliasing artifacts at voxel boundaries beyond what's expected from nearest-neighbor voxels.

**Out of scope:** Multiple volumes, LoD, smooth zoom (discrete zoom steps are fine). The camera still shows just one hardcoded volume.

---

## Milestone 6 — Multi-Page Hierarchy + Pool

**Goal:** Replace the single hardcoded volume with a 4×4×1 grid of procedurally-generated pages streaming through the GPU pool. Camera movement evicts and regenerates as needed.

**Scope (~800 LOC):**

This is the biggest single milestone — the scaffolding for all future streaming work. It's where the data-oriented design of the world module pays off. Prior milestones had everything living in a single ad-hoc struct; this one establishes the production structure.

**What gets built:**

- `core::pool` — generational handles (`Handle`, `HANDLE_INVALID`), the `ArenaAllocator` implementation.
- `core::hash` — hash table for `Ivec3` → index lookups, used to find blocks by coordinate.
- `world::coords` — all the coordinate type distinctions (`WorldPixel`, `PageCoord`, `HolderCoord`, `BlockCoord`) and conversion functions.
- `world::block`, `world::holder`, `world::page` — the three-tier hierarchy, each as a flat pool with hash lookup.
- `world::streaming` — the `GpuPool` with LRU tracking, `acquire`/`release`/`touch` methods. `update()` function that takes a camera position and figures out which holders should be visible/cached/evicted.
- `voxel::volume` — the `VolumeRing` with 4 slots, round-robin `next()`.
- Simple procedural terrain in the generate shader: heightmap-based terrain using a hardcoded noise function, colored by height (grass/dirt/stone bands).
- Dirty holder queue: track which holders need regeneration, process them in the main loop with the per-frame budget.

**Dependencies:** Milestone 5.

**Done when:**
- A 4×4 grid of terrain pages renders correctly with no visible seams between them.
- Panning the camera moves the visible grid: new holders stream in, old ones evict gracefully.
- No memory leaks observed over a 5-minute panning session.
- Profile shows regeneration spreading across frames according to the budget — no big frame-time spikes during fast pans.
- Handles correctly invalidate: acquiring a slot, triggering its eviction, then trying to use the old handle fails cleanly (returns `null` from `get()`).

**Out of scope:** Multiple layers (underground/surface/sky), terrain blending between pages, procedural geometry beyond heightmap. Just bare terrain.

---

## Milestone 7 — Procedural Geometry

**Goal:** Port the VoxelQuest procedural generation algorithms: superellipsoids for buildings, Bézier branches for trees, materials via `paramArr`.

**Scope (~500 LOC GLSL, ~100 LOC C3):**

The work here is mostly shader-side — the bulk of the procedural geometry logic from VoxelQuest translates directly. The C3 side just needs to gather geometry descriptions per page and upload them.

**What gets built:**

- `world::geometry` — CPU-side procedural generation. Ports the relevant parts of `f00352_gameblock.hpp` and `f00341_gameplant.hpp`: building layout (phased generation on the node grid), tree generation (recursive L-system with `PlantRules`).
- `voxel::generate` (full version) — the `GeomParam` SSBO layout (16-aligned, size-asserted at compile time), upload helpers.
- `shaders/generate.comp` (full version) — ports `GenerateVolume.c` logic: iterate `paramArr` entries, find closest match per voxel, evaluate superellipsoid/Bézier. Includes the material ID system (`TEX_STONE`, `TEX_WOOD`, `TEX_BRICK`, etc.) and voronoi seed lookup.
- CPU-side voronoi seed generation: 27 perturbed points per page, deterministic from page coordinate.
- Support for the three entry layouts (`E_GP_*` for buildings, `E_TP_*` for trees, `E_AP_*` for lines/lanterns).

**Dependencies:** Milestone 6, plus the procedural generation reference document.

**Done when:**
- A small village with 5-10 buildings renders correctly: walls, roofs, windows, doorways all recognizable.
- Trees with trunks and leaf spheres render with natural branching.
- Material IDs are correctly carried through to the output FBO (verifiable by colorizing by material in the present shader).
- Editing a building's parameters in code and rebuilding shows the change without needing to restart.

**Out of scope:** Lighting of these materials, shadows, reflections, any per-material visual treatment beyond a flat color. Material IDs are just tags at this point.

---

## Milestone 8 — Deferred Lighting

**Goal:** Turn the flat material IDs into a properly lit scene — palette-based coloring, screen-space shadows via ray-march, AO, day/night cycle.

**Scope (~400 LOC GLSL, ~200 LOC C3):**

This is where "renders the scene" becomes "looks like a game." The deferred architecture we built into the frame graph already accommodates this — we just need to populate the passes.

**What gets built:**

- `render::deferred` — G-buffer setup: 4 MRTs at 1080p storing height, normal+AO, material ID, worldspace position.
- `render::lighting` — the palette LUT (a small 2D texture indexed by `material_id, lighting_parameter`) plus the screen-space shadow pass that ray-marches from each G-buffer pixel toward the sun.
- `shaders/lighting.frag` — fragment shader that reads the G-buffer, looks up palette colors, applies sun shadows, applies basic AO.
- Sun/moon direction controlled by a global `time_of_day` parameter; smooth day/night transitions.
- Screen-space AO using the depth channel of the G-buffer. Simple horizon-based AO is sufficient.

**Dependencies:** Milestone 7.

**Done when:**
- The village from milestone 7 looks properly lit with a moving sun.
- Shadows cast correctly from buildings and trees.
- AO visibly darkens corners and concavities.
- No visible seams between page boundaries in the lit image (this tests that the G-buffer is consistent across pages — if not, we have a problem to debug before moving on).

**Out of scope:** Radiosity (milestone 10), fog (milestone 10), water reflections, transparent surfaces.

---

## Milestone 9 — Boundary Buffer A/B Toggle

**Goal:** Implement Mode B (exact-fit with bindless neighbor sampling) alongside the existing Mode A (oversized buffer), with an F3 runtime toggle between them.

**Scope (~100 LOC):**

Small but high-value. This is the only milestone that introduces a genuinely novel architectural choice (bindless textures for the neighbor lookup), so getting it working and having it feel solid matters before everything else is built on it.

**What gets built:**

- Bindless texture support in `gpu::texture` — `make_resident`, `make_non_resident` methods that return a `uvec2` handle usable in shaders.
- `world::streaming` update: maintain a "neighbor table" that maps each cached holder to its 27 neighbors (3×3×3 around it), update when slots change.
- Neighbor table SSBO uploaded to the raymarch shader.
- Shader changes in `generate.comp` and `raymarch.comp`: add `uniform int buffer_mode`, branch between oversized sampling and bindless neighbor sampling at normal-estimation time.
- `game::input` — F3 key handler: flip the mode flag, mark all holders dirty.
- On-screen debug indicator (small HUD text) showing current mode.

**Dependencies:** Milestone 8, plus a GPU that supports `GL_ARB_bindless_texture`.

**Done when:**
- F3 toggles cleanly between modes, with a visible regeneration taking ~1-2 seconds.
- Mode A and Mode B both produce visually correct output.
- The toggle allows direct visual comparison — ideally side-by-side captures of the same scene in both modes for comparison.
- No crashes from acquiring/releasing bindless handles under streaming pressure (verified by running a camera-stress test).

**Out of scope:** Per-material mode selection (logical future extension), Mode B-specific shader optimizations, fallback for non-bindless hardware. Assume `ARB_bindless_texture` is present.

---

## Milestone 10 — Everything Else

**Goal:** Fill out the rest of the rendering features and engine capabilities to reach demo-quality: radiosity, fog, entities, editing, minimal GUI.

**Scope (~2000 LOC, stretched across multiple sub-tasks):**

This is deliberately a catch-all for remaining features. Unlike the previous milestones, this one is a queue of independent sub-milestones rather than one monolithic step. Each sub-milestone should produce a visible, testable improvement. At this point the engine is feature-complete enough that decisions are less architectural and more about "what adds the most value next."

**Sub-milestones, roughly in priority order:**

- **Radiosity.** `shaders/radiosity.frag` — a screen-space single-bounce indirect lighting pass. Samples nearby G-buffer pixels, aggregates color bleeding, ping-pongs for convergence. This is the pass that gives colored bounce light under awnings and inside rooms.
- **Atmospheric fog.** `shaders/fog.frag` — distance-based fog with height falloff. Cheap but dramatically changes scene mood. Ties into the day/night cycle for color variation.
- **Transparency layer.** Separate blend of the waterFBO layer on top of the lit result. Includes ripple effects on water (sampling displacement noise) and alpha blending for glass materials.
- **Entities and characters.** `game::entity` — per-entity procedural volume generation (skeletal volumes from L-system-like rules, similar to trees but for humanoids/creatures). Entities render into their own small volumes and are composited separately from the terrain.
- **Editing interface.** Click-to-dig, click-to-place. Modifies the CPU-side parameter lists for affected pages, marks them dirty. The streaming system handles the rest automatically.
- **Dear ImGui integration.** Minimal debug/stats HUD: frame time, memory usage, pool occupancy, camera state, toggle switches for debug visualizations (show normals, show material IDs, show DF, etc.).
- **Audio.** Optional. Basic positional audio via something like OpenAL-soft — footsteps, ambient environmental sound.

**Dependencies:** Milestone 9 and all prior.

**Done when:** The engine is complete enough to record a 2-3 minute demo video showcasing a walkthrough of a procedurally generated town with day/night transition, player interaction, and all visual effects enabled at stable 60 FPS on mid-range hardware.

---

## Cross-Cutting Concerns

A few topics that don't belong to any single milestone but need attention throughout:

**Profiling.** Starting with milestone 3, every render pass should be wrapped in GPU timer queries. A rolling 60-frame median is kept per-pass for the HUD. This catches regressions immediately — if milestone 7 makes the ray march 30% slower, we see it the frame we introduce it, not three milestones later.

**Validation layers.** `GL_KHR_debug` output should be enabled and logged to console throughout. Invalid GL usage should be visible immediately. When we eventually migrate to Vulkan, this transfers directly to the validation layer.

**Shader reflection.** Starting in milestone 2, we should parse SPIR-V to validate that C3-side bind points match shader-side bind points. Easy to get wrong manually; cheap to validate.

**Testing.** Unit tests for pure logic (pool management, coordinate conversions, hash tables). Integration tests for things that cross the CPU/GPU boundary are harder but worth it — a smoke test that runs a single frame of the full pipeline and compares output against a reference image catches a lot of regressions.

**Documentation.** Each milestone should produce or update a section of a living design document with what was learned during implementation. The specification we started with is a plan, not a record — what actually gets built will differ in detail, and capturing those differences is what lets future contributors understand the system.

---

## Budget Estimates

Rough calendar estimates, assuming one developer working on this full-time, moderate C3/GLSL proficiency:

| Milestone | Weeks | Running total |
|-----------|-------|---------------|
| 1  | 1 | 1 |
| 2  | 1 | 2 |
| 3  | 2 | 4 |
| 4  | 0.5 | 4.5 |
| 5  | 0.5 | 5 |
| 6  | 3 | 8 |
| 7  | 3 | 11 |
| 8  | 2 | 13 |
| 9  | 1 | 14 |
| 10 | 6+ | 20+ |

The running total to a viable demo is roughly 5 months. The first 14 weeks produce a "here's the architecture working" state; milestone 10 is where the engine gets polished into something shippable, and that has no natural endpoint.

Part-time development multiplies by 2-3× depending on the rhythm.