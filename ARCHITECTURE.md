# Voxel Engine Architecture — C3 + OpenGL 4.6

A reproduction of the VoxelQuest isometric rendering pipeline, modernized for OpenGL 4.6 and implemented in C3. Architected for a future migration to Vulkan without committing speculative abstraction cost now.

---

## Design Principles

1. **Keep the CPU side skinny.** The engine is fundamentally a GPU program. C3 code decides what to render, manages memory pools, and issues dispatches. All voxel data lives on the GPU.
2. **No hidden allocations.** Every subsystem takes an `Allocator` explicitly. Per-frame scratch uses `tmem` and `@pool`. Long-lived state uses module-owned arenas.
3. **Data-oriented, not OO.** Entities, holders, pages are flat struct arrays indexed by handles. Pointer chasing only where it genuinely helps.
4. **Errors where errors happen.** File I/O and shader compilation return C3 optionals. Hot paths (draw loop) are infallible.
5. **One problem per module.** No god-singleton. Each module owns one thing.
6. **API-agnostic pipeline code.** Modules outside `gpu/` never touch GL handles or call GL functions. The pipeline is expressed in terms of opaque resource handles and command-recording operations. This is the single discipline that makes a future Vulkan migration a bounded backend swap.

---

## Module Layout

```
vq/
├── project.json
├── src/
│   ├── main.c3                  // entry, frame loop
│   ├── core/
│   │   ├── math.c3              // vec/mat/aabb/bezier wrappers
│   │   ├── pool.c3              // arena allocator
│   │   └── hash.c3              // int3 → handle hash
│   ├── platform/
│   │   ├── window.c3            // GLFW: context, input, resize
│   │   └── time.c3              // frame timing
│   ├── gpu/                     // ← only module that touches the GPU API
│   │   ├── gl.c3                // raw glad-generated bindings (@local)
│   │   ├── resource.c3          // opaque handle types (Texture, Buffer, etc.)
│   │   ├── buffer.c3            // buffer creation/upload
│   │   ├── texture.c3           // texture creation/upload
│   │   ├── framebuffer.c3       // FBO + MRT
│   │   ├── shader.c3            // SPIR-V load, hot-reload
│   │   └── cmd.c3               // command recording (dispatch, draw, barrier, pass)
│   ├── world/
│   │   ├── coords.c3            // pixel/unit/page/holder/block math
│   │   ├── block.c3             // low-res terrain + holder grid
│   │   ├── holder.c3            // group of pages, owns pool slot
│   │   ├── page.c3              // single voxel volume tile
│   │   ├── geometry.c3          // procedural shape descriptions
│   │   └── streaming.c3         // LRU pool, view-driven paging
│   ├── voxel/
│   │   ├── volume.c3            // 3D volume ring buffer
│   │   ├── generate.c3          // GenerateVolume pass
│   │   ├── distance_field.c3    // jump-flood DF builder
│   │   ├── raymarch.c3          // RenderVolume pass
│   │   └── composite.c3         // Blit + Combine passes
│   ├── render/
│   │   ├── frame.c3             // frame graph
│   │   ├── deferred.c3          // G-buffer layout
│   │   ├── lighting.c3          // shadows, AO, material LUT
│   │   ├── radiosity.c3         // SS indirect bounce
│   │   ├── fog.c3               // atmospheric fog
│   │   └── present.c3           // tonemap + swap
│   ├── game/
│   │   ├── camera.c3            // isometric camera
│   │   ├── entity.c3            // skeletal volume gen
│   │   └── input.c3             // keybinds, edit controls
│   └── shaders/                 // GLSL → SPIR-V at build time
│       ├── common/
│       ├── generate.comp
│       ├── distance_field.comp
│       ├── raymarch.comp
│       ├── lighting.frag
│       ├── radiosity.frag
│       ├── fog.frag
│       └── present.frag
└── assets/
```

**Compute vs fragment split:** `generate`, `distance_field`, and `raymarch` are compute shaders (flexible output formats, work distribution). Everything in `render/` is fragment-shader based — hardware blending, MRT, and driver-optimized paths matter more for post-processing than compute flexibility does.

**The firewall:** Only `gpu/` imports `gl.c3`. Every other module sees the GPU through opaque handles and command-recording functions. No `glXxx` calls appear outside `gpu/`. When/if we add a Vulkan backend, we add a second set of files inside `gpu/` and swap at compile time — everything else is unchanged.

---

## Identifiers & Coordinates

Handles are generational (24-bit index, 8-bit generation) so pool slots can be safely evicted and reclaimed without dangling references:

```c3
module vq::core;

typedef Handle = inline uint;
macro uint Handle.index(Handle h) => (uint)h & 0x00FF_FFFF;
macro uint Handle.gen(Handle h)   => ((uint)h >> 24) & 0xFF;

const Handle HANDLE_INVALID = (Handle)0xFFFF_FFFF;
```

`BlockId`, `HolderId`, `PageId`, `GeometryId` are distinct typedefs over `Handle`. The same approach applies to GPU resource handles in the `gpu::` module — `Texture3D`, `Buffer`, `Shader` are opaque typedefs, not exposed GL integers.

Coordinate units are distinct types to eliminate unit confusion:

```c3
module vq::world::coords;

typedef WorldPixel  = inline int;
typedef Meter       = inline float;
typedef PageCoord   = inline int;
typedef HolderCoord = inline int;
typedef BlockCoord  = inline int;

const int PIXELS_PER_PAGE   = 128;
const int PAGES_PER_HOLDER  = 2;
const int HOLDERS_PER_BLOCK = 8;
const int VOLUME_PITCH      = 128;
```

---

## Spatial Hierarchy

`GameBlock → GameHolder → GamePage` with flat pools indexed by handles:

```c3
module vq::world::block;

struct Block {
    BlockCoord cx, cy;
    HolderId[HOLDERS_PER_BLOCK * HOLDERS_PER_BLOCK * HOLDERS_PER_BLOCK] holders;
    gpu::Texture3D terrain_volume;   // low-res heightmap-derived volume
    bool terrain_dirty;
}

struct BlockPool {
    Block[] storage;
    core::Hash{Ivec3, int} lookup;   // (cx, cy, 0) → storage index
    Allocator allocator;
}

fn BlockId BlockPool.get_or_create(&self, BlockCoord cx, BlockCoord cy);
fn Block*  BlockPool.get(&self, BlockId id);
fn void    BlockPool.evict(&self, BlockId id);
```

Every lookup is O(1) — either direct array index or single hash probe.

---

## GPU Pool (The Hot Path)

LRU cache of per-holder output framebuffers. Furthest-from-camera holders are evicted when a new holder needs a slot:

```c3
module vq::world::streaming;

struct PoolSlot {
    HolderId owner;                  // HANDLE_INVALID if free
    uint last_touched_frame;
    gpu::Framebuffer fbo_layer0;     // opaque: height+material, normal+AO
    gpu::Framebuffer fbo_layer1;     // transparent (water, glass)
}

struct GpuPool {
    PoolSlot[] slots;                // fixed size at init
    usz[] lru_order;
    uint current_frame;
}

fn uint GpuPool.acquire(&self, HolderId for_holder);
fn void GpuPool.touch(&self, uint slot_index);
```

`acquire` is infallible — eviction always succeeds.

---

## The `gpu/` Module

This is the boundary between our engine and the GPU API. Getting this right is the single most important thing for future migration flexibility.

### Opaque Resource Handles

```c3
module vq::gpu;

// All public types are opaque from outside gpu/.
// Internally in GL backend, each wraps a uint.
typedef Texture2D   = inline uint @private;
typedef Texture3D   = inline uint @private;
typedef Buffer      = inline uint @private;
typedef Framebuffer = inline struct { uint fbo_id; uint[4] attachments; int width, height; } @private;
typedef Shader      = inline uint @private;

enum Access : char {
    READ_ONLY,
    WRITE_ONLY,
    READ_WRITE,
}

enum Format : char {
    RGBA8, RGBA16F, RGBA32F,
    R8, R16F, R32F,
    DEPTH24_STENCIL8,
}

enum BarrierType : char {
    SHADER_IMAGE_ACCESS,   // compute → anything reading images
    FRAMEBUFFER,           // fragment → anything reading FB
    STORAGE_BUFFER,        // compute → compute via SSBO
    ALL,                   // catch-all
}
```

### Command Recording

All draw/dispatch/barrier operations go through a command interface. In the GL backend these execute immediately. In a future Vulkan backend they'd record into a command buffer:

```c3
module vq::gpu::cmd;

// Opaque context — a dummy in GL, a VkCommandBuffer in Vulkan.
typedef Commands = inline uint @private;

fn void Commands.begin_frame(&self);
fn void Commands.end_frame(&self);

fn void Commands.bind_shader(&self, Shader s);
fn void Commands.bind_texture(&self, uint binding, Texture3D t);
fn void Commands.bind_image(&self, uint binding, Texture3D t, Access access);
fn void Commands.bind_ubo(&self, uint binding, Buffer b, usz offset, usz size);
fn void Commands.bind_ssbo(&self, uint binding, Buffer b);
fn void Commands.bind_framebuffer(&self, Framebuffer* fb);

fn void Commands.dispatch(&self, int gx, int gy, int gz);
fn void Commands.draw_fullscreen_quad(&self);

fn void Commands.barrier(&self, BarrierType type);

// Push-constant-sized data goes through a dedicated small UBO.
// In Vulkan this would use vkCmdPushConstants directly.
fn void Commands.set_push_constants(&self, void* data, usz size);
```

### Why this matters

In GL, `Commands.dispatch(32,32,32)` directly calls `glDispatchCompute`. In a hypothetical Vulkan backend, it calls `vkCmdDispatch`. The call site in `voxel::generate` doesn't know which.

Call sites from outside `gpu/` look identical regardless of backend:

```c3
cmd.bind_shader(ctx.generate_shader);
cmd.bind_image(0, volume, WRITE_ONLY);
cmd.bind_texture(1, terrain_ref);
cmd.bind_ssbo(2, geom_buffer);
cmd.bind_ubo(3, uniforms_buffer, 0, $sizeof(GenerateUniforms));
cmd.dispatch(32, 32, 32);
cmd.barrier(SHADER_IMAGE_ACCESS);
```

This is not a full RHI abstraction — no render graph compilation, no resource state tracking, no async queue management. It's a thin pass-through that happens to have Vulkan-compatible shape. The cost is ~300 LOC over using GL directly. The payoff is that migration later touches only the `gpu/` internals, not the 10,000+ LOC of pipeline logic.

### Shader Conventions

All shaders are written to compile to SPIR-V and follow strict binding conventions. GL 4.6 supports SPIR-V ingest via `ARB_gl_spirv`, so we compile once with `glslc` and load the same binary in both GL and (eventually) Vulkan.

Rules:

- **Every resource has an explicit layout binding.** No `glGetUniformLocation`, no reflection-based lookup.
  ```glsl
  layout(binding = 0, rgba8)  uniform image3D     volume_out;
  layout(binding = 1)         uniform sampler3D   terrain_ref;
  layout(std430, binding = 2) buffer  GeomBuffer  { GeomParam geom[]; };
  layout(std140, binding = 3) uniform Uniforms    { vec3 world_min; vec3 world_max; int num_geom; };
  ```
- **Uniform data lives in UBOs with std140 layout.** No loose `uniform float` at module scope. Loose uniforms don't exist in Vulkan.
- **Small per-dispatch data uses a dedicated small UBO** that could later become push constants. Things like `curLayer`, `frameNumber`, `tiltAmount` go here.
- **Shader hot-reload recompiles GLSL→SPIR-V** via a subprocess call to `glslc`, then loads the new SPIR-V binary. Same path works for both backends.

### What stays GL-specific (behind the firewall)

Things that don't port cleanly to Vulkan and live only inside `gpu/`:

- `glBindTexture` unit state (Vulkan has explicit descriptor sets)
- `glUniform*` calls (Vulkan has no loose uniforms)
- Framebuffer completeness states (Vulkan has render pass objects)
- `glMemoryBarrier` bitmasks (Vulkan uses `VkPipelineStageFlags` + access masks)

None of this leaks outside `gpu/`. When we migrate, we replace this implementation, not its callers.

---

## Voxel Pipeline

Four stages per dirty page: generate → distance-field → raymarch → write to holder.

### Volume Ring Buffer

Only 4 volume textures exist in flight, recycled round-robin:

```c3
module vq::voxel::volume;

const int VOLUME_RING_SIZE = 4;

struct VolumeRing {
    gpu::Texture3D[VOLUME_RING_SIZE] volumes;      // RGBA8, 128³ = 8 MB each
    gpu::Texture3D[VOLUME_RING_SIZE] dist_fields;  // R8,    32³ = 32 KB each
    int current;
}

fn int VolumeRing.next(&self) {
    int idx = self.current;
    self.current = (self.current + 1) % VOLUME_RING_SIZE;
    return idx;
}
```

**Why ring buffer instead of persistent volumes:** A 128³ RGBA8 volume is 8 MB. Persistent volumes for even 128 holders would be 1 GB. The 2D sprite output (stored in the GpuPool) captures everything needed from an isometric view. Ring-cycling volumes is the right trade.

### Volume Generation

One compute dispatch per page. Procedural geometry parameters go to an SSBO:

```c3
struct GeomParam @packed @align(16) {
    float[4] params;    // type, subtype, extras
    float[4] p0, p1, p2;
    float[4] vis_min, vis_max;
    float[4] thick;
    float[4] mat;       // material_id, normal_id, modifier
}
$assert $sizeof(GeomParam) == 128;

struct GenerateUniforms @packed @align(16) {
    float[4] world_min;       // .w unused, padded for std140
    float[4] world_max;
    int      num_geom;
    int      buffer_mode;     // 0 = oversized, 1 = exact
    int      _pad[2];
}

fn void GenerateContext.dispatch(
    &self,
    gpu::Commands* cmd,
    volume::VolumeRing* ring,
    int ring_slot,
    page::PageDesc* desc,
    GeomParam[] geom
) {
    self.geom_ssbo.upload_slice(geom);

    GenerateUniforms u = {
        .world_min = { desc.world_min.x, desc.world_min.y, desc.world_min.z, 0 },
        .world_max = { desc.world_max.x, desc.world_max.y, desc.world_max.z, 0 },
        .num_geom = (int)geom.len,
        .buffer_mode = (int)self.settings.buffer_mode,
    };
    self.uniforms_ubo.upload(&u, $sizeof(GenerateUniforms));

    cmd.bind_shader(self.shader);
    cmd.bind_image(0, ring.volumes[ring_slot], gpu::WRITE_ONLY);
    cmd.bind_texture(1, self.terrain_ref);
    cmd.bind_ssbo(2, self.geom_ssbo);
    cmd.bind_ubo(3, self.uniforms_ubo, 0, $sizeof(GenerateUniforms));
    cmd.dispatch(32, 32, 32);
    cmd.barrier(gpu::SHADER_IMAGE_ACCESS);
}
```

GLSL (compiled to SPIR-V):

```glsl
#version 460
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(binding = 0, rgba8) uniform restrict writeonly image3D volume;
layout(binding = 1) uniform sampler3D terrain_ref;
layout(std430, binding = 2) readonly buffer GeomBuffer { GeomParam geom[]; };
layout(std140, binding = 3) uniform U { vec4 world_min; vec4 world_max; int num_geom; int buffer_mode; };

void main() {
    ivec3 voxel = ivec3(gl_GlobalInvocationID);
    vec3 uvw = (vec3(voxel) + 0.5) / vec3(128.0);
    vec3 world_pos = mix(world_min.xyz, world_max.xyz, uvw);
    // ... terrain + geometry evaluation, imageStore(volume, voxel, result) ...
}
```

### Distance Field

Our acceleration structure. After generation, jump-flood fills a 32³ R8 distance field where each texel stores conservative distance (in 4-voxel cells) to the nearest solid. Ray march uses this to skip empty space.

**Format choice (32³ R8, 32 KB/volume, 128 KB for entire ring):**
- Fits entirely in GPU L2 cache — repeated sampling across neighboring rays is free.
- Conservative encoding never over-steps into solids.
- Build cost: ~0.1 ms per page (5 jump-flood passes of log₂(32)).
- Reduces ray sample counts from ~40 to ~8 on typical scenes.

```c3
struct JumpFloodContext {
    gpu::Shader init_shader;
    gpu::Shader step_shader;
    gpu::Buffer step_ubo;       // single int for step size
}

fn void JumpFloodContext.build(
    &self,
    gpu::Commands* cmd,
    gpu::Texture3D volume_in,
    gpu::Texture3D dist_out
) {
    // Seed pass: 0 if solid, 255 if empty
    cmd.bind_shader(self.init_shader);
    cmd.bind_image(0, volume_in, gpu::READ_ONLY);
    cmd.bind_image(1, dist_out, gpu::WRITE_ONLY);
    cmd.dispatch(8, 8, 8);
    cmd.barrier(gpu::SHADER_IMAGE_ACCESS);

    // Propagate in log₂(32) = 5 passes with halving step sizes
    int step = 16;
    while (step >= 1) {
        self.step_ubo.upload(&step, $sizeof(int));
        cmd.bind_shader(self.step_shader);
        cmd.bind_image(0, dist_out, gpu::READ_WRITE);
        cmd.bind_ubo(1, self.step_ubo, 0, $sizeof(int));
        cmd.dispatch(8, 8, 8);
        cmd.barrier(gpu::SHADER_IMAGE_ACCESS);
        step /= 2;
    }
}
```

### Ray March

Compute shader, one thread per output pixel. Derives ray entry/exit analytically per pixel — no front-face/back-face FBO pre-pass.

```c3
fn void RayMarchContext.dispatch(
    &self,
    gpu::Commands* cmd,
    volume::VolumeRing* ring,
    int ring_slot,
    gpu::Framebuffer* target,
    page::PageDesc* desc,
    CameraState* cam
) {
    RayMarchUniforms u = {
        .world_min_vis = desc.world_min_vis,
        .world_max_vis = desc.world_max_vis,
        .view_proj_iso = cam.view_proj_iso,
        .tilt = cam.tilt,
    };
    self.uniforms_ubo.upload(&u, $sizeof(RayMarchUniforms));

    cmd.bind_shader(self.shader);
    cmd.bind_texture(0, ring.volumes[ring_slot]);
    cmd.bind_texture(1, ring.dist_fields[ring_slot]);
    cmd.bind_image(2, target.attachments[0], gpu::WRITE_ONLY);
    cmd.bind_image(3, target.attachments[1], gpu::WRITE_ONLY);
    cmd.bind_ubo(4, self.uniforms_ubo, 0, $sizeof(RayMarchUniforms));

    cmd.dispatch(target.width / 8, target.height / 8, 1);
    cmd.barrier(gpu::SHADER_IMAGE_ACCESS);
}
```

GLSL inner loop with DF acceleration:

```glsl
float t = 0.0;
for (int i = 0; i < MAX_STEPS; i++) {
    vec3 pos = entry + t * (exit - entry);
    float d = texelFetch(dist_field, ivec3(pos * 32.0), 0).r * 4.0;
    if (d < 1.0) {
        vec4 v = texelFetch(volume, ivec3(pos * 128.0), 0);
        if (v.a > 0.0 && v.r == current_layer) { /* HIT */ break; }
        t += 1.0 / ray_voxel_length;
    } else {
        t += d / ray_voxel_length;
    }
    if (t >= 1.0) discard;
}
```

### Boundary Buffer A/B Toggle

Normal estimation at page boundaries needs voxels from neighboring pages. Two modes, switchable with `F3`:

| Mode | Strategy | Effective res | Geometry eval |
|------|----------|---------------|---------------|
| **A** (VQ-style) | Generate 1.25× larger region, border covers neighborhood sampling | ~102³ (48.8% border) | 1.95× |
| **B** (exact fit) | Generate exactly the visible region, sample neighbor output FBOs via bindless | 128³ full | 1.00× |

Mode A is simple and self-contained. Mode B requires `ARB_bindless_texture` in GL, maps to Vulkan's descriptor indexing natively. Toggle is ~100 LOC total.

---

## Frame Graph

Each frame runs a fixed sequence of passes. For every pass we document its reads and writes explicitly — this is what makes Vulkan barriers derivable mechanically later, and also makes the code clearer now.

```c3
module vq::render::frame;

// Pass dependency annotation. In GL this drives glMemoryBarrier.
// In Vulkan it will drive vkCmdPipelineBarrier with precise stage/access masks.
enum Stage : char { COMPUTE, GRAPHICS }

fn void render_frame(FrameCtx* fc) {
    gpu::Commands* cmd = &fc.cmd;
    cmd.begin_frame();

    // ========= PASS 1: Streaming update (CPU) =========
    // Writes: world.dirty_holders list
    // Reads:  camera state, world hierarchy
    streaming::update(fc.world, &fc.camera);

    // ========= PASS 2: Regenerate dirty holders (COMPUTE) =========
    // For each dirty holder, up to MAX_REGEN_PER_FRAME:
    //   Writes: volume_ring[slot], dist_field_ring[slot], holder.fbo_layer0
    //   Reads:  terrain_volume, geom SSBO, uniforms UBO
    //   Barriers: image → image (between generate, JFA, and raymarch)
    voxel::process_dirty_holders(cmd, fc, MAX_REGEN_PER_FRAME);

    // ========= PASS 3: Composite holders into screen-space layers (GRAPHICS) =========
    // Writes: pagesFBO, waterFBO
    // Reads:  every holder.fbo_layer{0,1} in view
    // Barriers: SHADER_IMAGE_ACCESS (compute writes of holder FBOs → fragment reads)
    voxel::composite_holders(cmd, fc);

    // ========= PASS 4: World-space G-buffer (GRAPHICS) =========
    // Writes: worldSpaceFBO (4 MRT)
    // Reads:  pagesFBO (height/material channels)
    render::build_worldspace_gbuffer(cmd, fc);

    // ========= PASS 5-7: Deferred lighting chain (GRAPHICS) =========
    // lighting:  reads worldSpaceFBO, writes resultFBO
    // radiosity: reads resultFBO + worldSpaceFBO, writes resultFBO (ping-pong)
    // fog:       reads resultFBO + worldSpaceFBO, writes resultFBO
    // Barriers: FRAMEBUFFER between each
    render::lighting_pass(cmd, fc);
    render::radiosity_pass(cmd, fc);
    render::fog_pass(cmd, fc);

    // ========= PASS 8: Transparency blend (GRAPHICS) =========
    // Writes: resultFBO (alpha blend)
    // Reads:  waterFBO, resultFBO
    render::composite_transparent(cmd, fc);

    // ========= PASS 9: Present (GRAPHICS) =========
    // Writes: swapchain image
    // Reads:  resultFBO
    render::present(cmd, fc);

    cmd.end_frame();
}
```

### Regeneration Budget

```c3
const int MAX_REGEN_PER_FRAME = 4;

fn void voxel::process_dirty_holders(gpu::Commands* cmd, FrameCtx* fc, int budget) {
    fc.world.dirty_holders.sort_by_distance(&fc.camera.position);
    int done = 0;
    while (!fc.world.dirty_holders.is_empty() && done < budget) {
        regenerate_holder(cmd, fc, fc.world.dirty_holders.pop_front());
        done++;
    }
}

fn void voxel::regenerate_holder(gpu::Commands* cmd, FrameCtx* fc, HolderId hid) {
    Holder* holder = fc.world.holders.get(hid);
    uint slot = fc.gpu_pool.acquire(hid);
    PoolSlot* pslot = &fc.gpu_pool.slots[slot];

    for (int i = 0; i < holder.page_count; i++) {
        Page* page = fc.world.pages.get(holder.pages[i]);
        int ring_slot = fc.volume_ring.next();

        @pool() {
            GeomParam[] geom = gather_geometry_for_page(page, tmem);
            fc.resources.generate.dispatch(cmd, fc.volume_ring, ring_slot, &page.desc, geom);
        };

        fc.resources.jfa.build(
            cmd,
            fc.volume_ring.volumes[ring_slot],
            fc.volume_ring.dist_fields[ring_slot]
        );

        fc.resources.raymarch.dispatch(
            cmd, fc.volume_ring, ring_slot,
            &pslot.fbo_layer0,
            &page.desc, &fc.camera
        );
    }

    fc.gpu_pool.touch(slot);
}
```

The budget prevents stalls on mass-invalidation. Newly-visible holders display their stale sprite for 1–3 frames before updating — visually imperceptible.

---

## Memory Budget

VRAM targets at 128-holder pool size:

| Resource | Format | Count | Total |
|----------|--------|-------|-------|
| Volume ring (3D) | RGBA8, 128³ | 4 | 32 MB |
| Distance field ring (3D) | R8, 32³ | 4 | 128 KB |
| Holder output FBO (opaque) | RGBA8 × 2 MRT, 512² | 128 | 256 MB |
| Holder output FBO (transparent) | RGBA8 × 2 MRT, 512² | 128 | 256 MB |
| Screen G-buffer | RGBA16F × 4 MRT, 1080p | 1 | 32 MB |
| Lighting accumulation | RGBA16F, 1080p | 2 | 16 MB |
| Terrain heightmap volumes | R8, 64³ | ~16 | 4 MB |
| **Total (approximate)** | | | **~600 MB** |

Well within reasonable budget for a modern GPU.

---

## Memory Allocation Strategy

Three allocator tiers:

| Tier | Allocator | Use |
|------|-----------|-----|
| Engine lifetime | `mem` heap | Shaders, textures, FBOs, pool storage. One-time init, freed at shutdown. |
| Per-frame scratch | `tmem` + `@pool` | Visibility lists, geometry gather, sort scratch. Auto-freed at scope exit. |
| Long-lived resizable | `ArenaAllocator` | Block/holder/page pool backing. Grows with streaming; reset on long-distance travel. |

```c3
struct ArenaAllocator {
    Allocator backing;
    char[] block;
    usz used;
}

fn Allocator ArenaAllocator.as_allocator(&self);
fn void ArenaAllocator.reset(&self);
fn void ArenaAllocator.destroy(&self);
```

### Vulkan-friendly GPU allocation discipline

Even in the GL backend, we manage GPU resources with Vulkan-compatible patterns:

- **Allocate all long-lived GPU resources at init.** Pool storage, ring textures, UBO/SSBO buffers, output FBOs. No per-frame GPU allocations in the hot path.
- **No per-frame GPU buffer recreation.** Uniform data is uploaded into persistent UBOs via `glBufferSubData`, not by creating new buffers. In Vulkan this becomes persistent mapped memory or dedicated staging.
- **No orphaning tricks.** Techniques like `glBufferData(NULL)` to implicitly double-buffer don't port. If we need double-buffered UBOs, we allocate two and index explicitly.

These rules are easy to follow from day one and cost nothing. Violating them is what makes migrations painful.

---

## Error Handling

The rule: fallible operations outside the hot loop use optionals; operations inside the hot loop don't.

| Operation | Style | Rationale |
|-----------|-------|-----------|
| Shader compile | `fn Shader? load(...)` | Dev hot-reload must not crash |
| File I/O | `fn String? read(...)` | Standard `io::FILE_NOT_FOUND` etc. |
| GL context init | `fn bool init_gl()` | One-time, crash is fine |
| Frame render | `fn void render_frame(...)` | Infallible; asserts in dev |
| Pool acquire | `fn uint acquire(...)` | Eviction always succeeds |
| Handle deref | `fn T* get(Handle)` returns `null` | Caller checks |

---

## Build Order

Each milestone produces something visible:

| # | Milestone | Scope |
|---|-----------|-------|
| 1 | Platform + GL context + SPIR-V shader loader | Blank window with hot-reloadable fullscreen-quad shader (~600 LOC) |
| 2 | `gpu/` command interface | Thin command recording layer, tested with a triangle (~400 LOC) |
| 3 | Single-volume prototype | One hardcoded 128³ volume, compute-filled, ray-marched to screen (~600 LOC) |
| 4 | Jump-flood distance field | Acceleration structure + measurement (~200 LOC) |
| 5 | Isometric projection | World-to-screen math (~150 LOC) |
| 6 | Multi-page hierarchy + pool | 4×4×1 grid of pages with procedural terrain (~800 LOC) |
| 7 | Procedural geometry | Superellipsoids, Bézier trees, materials (~500 GLSL, ~100 C3) |
| 8 | Deferred lighting | Palette LUT, screen-space shadows, AO, day/night (~400 GLSL, ~200 C3) |
| 9 | Boundary buffer A/B toggle | Mode B (bindless neighbors) + runtime switch (~100 LOC) |
| 10 | Everything else | Radiosity, fog, entities, editing, GUI |

---

## Migration Path

If and when Vulkan becomes worth the cost (async compute stalls, macOS support requirement, mobile port, etc.), here's what the migration touches:

### Fully replaced (~2000-3000 LOC)

- `gpu/gl.c3` → new `gpu/vk.c3` with raw Vulkan bindings via the existing C3 Vulkan libraries
- `gpu/resource.c3` → new backing for the opaque handles (Vulkan resources + allocator state)
- `gpu/buffer.c3`, `gpu/texture.c3`, `gpu/framebuffer.c3`, `gpu/shader.c3`, `gpu/cmd.c3` → new implementations
- Added: `gpu/swapchain.c3`, `gpu/memory.c3` (VMA or homegrown), `gpu/sync.c3` (semaphores/fences), `gpu/descriptor.c3` (descriptor pools/sets)
- Platform: window creation switches from `glfwCreateWindow` with GL hints to Vulkan surface creation

### Unchanged

- Everything in `world/`, `voxel/`, `render/`, `game/`, `core/`
- The frame graph structure and pass ordering
- All GLSL shaders (they already compile to SPIR-V)
- Memory model, handle types, coordinate system
- Allocation strategy

### Potentially restructured (~500 LOC)

- `render/frame.c3` might grow to support async compute — splitting compute-queue passes from graphics-queue passes with explicit semaphores between them
- `gpu/cmd.c3` might expose separate `compute_commands` and `graphics_commands` objects

### Estimated effort

Roughly 4-6 weeks of focused work for a single developer familiar with Vulkan, assuming the GL engine is stable and tested. The majority of that time is Vulkan boilerplate — swapchain, descriptors, memory, sync. The pipeline logic is already API-agnostic.

---

## Explicitly Out of Scope

Inherited complexity from VoxelQuest we skip:

- The `Singleton` god-object — each subsystem owns its own state
- Flat-2D-as-3D texture encoding — use real `GL_TEXTURE_3D`
- `TCShader` front/back face FBOs — compute shaders derive entry/exit analytically
- Custom `$` and `@param@` shader preprocessor — use `#include` and UBOs
- `glBegin(GL_QUADS)` immediate mode — VAO/VBO everywhere
- WebSocket remote editor (Poco) — not worth the complexity
- JSON-based GUI system — use Dear ImGui if needed
- Multiple engine iterations in one codebase — just the isometric pipeline, done well

Speculative abstraction we explicitly don't build:

- **No full RHI abstraction.** The `gpu/cmd.c3` interface is thin pass-through, not a general-purpose render graph compiler. We don't model resource state tracking, transient resources, pass scheduling, or barrier inference. When migrating to Vulkan, we add what Vulkan specifically needs (descriptor sets, render passes) without genericizing over both APIs.
- **No backend selection at runtime.** The backend is chosen at compile time via a build flag. No dynamic dispatch through function pointers, no "RHI interface" vtable.
- **No multi-frame-in-flight during Phase 1.** Single-frame synchronization only. Triple buffering and fence management can come later if needed.