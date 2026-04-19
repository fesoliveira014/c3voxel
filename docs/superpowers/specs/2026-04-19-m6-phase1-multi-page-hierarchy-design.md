# M6 Phase 1 — Static 4×4 Multi-Page Hierarchy

Design document for the first of two M6 phases. Phase 1 lands the full
`Block → Holder → Page` hierarchy, the per-holder sprite cache, and
procedural heightmap terrain. It produces a static, visually complete
terrain grid. Phase 2 (separate spec) wires the streaming system —
`GpuPool`, LRU, dirty queue, camera-driven `update()`.

Milestone reference: `docs/ARCHITECTURE.md` §Multi-page hierarchy,
§GPU Pool, §Voxel Pipeline, §Memory Budget; `docs/high-level-spec.md`
§Milestone 6.

---

## 1. Goals & non-goals

**Goals**

- Replace the single-volume prototype with a 4×4×1 grid of pages
  arranged as 1 Block → 4 Holders → 16 Pages.
- Each Holder owns a single RGBA8 + R16F MRT sprite FBO. All four of
  its pages ray-march into sub-rectangles of that FBO.
- Per-frame cost is a single composite pass that samples the 4 holder
  sprites, picks the max-height fragment per pixel, writes to the
  default framebuffer.
- Recognizable terrain with height-based color bands
  (grass/dirt/stone).
- Hot-reload still works for every shader touched.
- All structural scaffolding (pools, generational handles, arena,
  hash, volume ring) is in place so Phase 2 is purely additive
  streaming logic.

**Non-goals**

- No streaming, no LRU, no eviction, no dirty queue.
- No pan or zoom (iso view locked to a single camera).
- No transparency layer (`fbo_layer1`).
- No lighting, shadows, AO, or materials beyond height-band color.
- No per-frame ray-march re-runs (generate-once-at-startup).

---

## 2. Design decisions (locked during brainstorm)

| # | Question | Decision |
|---|----------|----------|
| 1 | Hierarchy depth | **Full** — Block + Holder + Page exactly as arch; trivial cases but Phase 2 is additive. |
| 2 | Rendering flow | **Per-holder sprite cache** (arch-native). Raymarch once at startup per holder; per-frame composite pass only. |
| 3 | Heightmap source | **CPU-generated per-Block, uploaded as R32F 2D texture.** Future move to GPU compute pass is filed as a todo. |
| 4 | Sprite format + composite | **MRT: RGBA8 color + R16F height.** Composite fragment picks max-height per pixel → order-independent. Matches arch `fbo_layer0`. |
| 5 | Core primitives | **Thin aliases over C3 stdlib** — `alias Hash{K, V} = HashMap{K, V}` and `alias Arena = ArenaAllocator`. Keeps arch naming, offloads implementation. |
| 6 | Noise function | **Perlin / simplex** (reference implementation provided separately). |

Each locked decision stands until a subsequent spec revision explicitly
overrides it.

---

## 3. Module layout

### Core (new)

```
src/core/hash.c3        alias Hash{K, V} = std::collections::map::HashMap{K, V};
src/core/pool.c3        alias Arena = std::core::mem::allocators::ArenaAllocator;
```

### World (new)

```
src/world/terrain.c3    CPU Perlin/simplex heightmap generator
src/world/block.c3      Block, BlockPool, BlockId
src/world/holder.c3     Holder, HolderPool, HolderId
src/world/page.c3       Page, PagePool, PageId
```

Existing `src/world/coords.c3` is extended with an `IVec3` key alias
(or reuses `core::IVec3`) for the pool hash lookups. The currently
unused `WorldPixel` / `Meter` / `PageCoord` / `HolderCoord` /
`BlockCoord` typedefs become load-bearing and are threaded through all
pool APIs.

### Voxel (extended)

```
src/voxel/volume.c3          Volume → VolumeRing (fixed 4 slots, round-robin)
src/voxel/generate.c3        + block-heightmap sampler binding; per-page world bounds
src/voxel/raymarch.c3        MRT writes (color + height); target a caller-supplied FBO slice
```

### Render (new)

```
src/render/composite.c3                              CompositeContext
resources/shaders/composite.vert.glsl                fullscreen triangle, emit uv
resources/shaders/composite.frag.glsl                sample N holder sprites, max-height compose
```

### Shaders (extended)

```
resources/shaders/generate.comp.glsl    + sampler2D heightmap, page world bounds
resources/shaders/raymarch.comp.glsl    + MRT outputs, sub-rect write offset
```

### Orchestration (rewritten)

```
src/main.c3   generate-all-at-startup; composite-per-frame
```

---

## 4. Handles

```c3
module c3voxel::world;

import c3voxel::core;

typedef BlockId  = inline core::Handle;
typedef HolderId = inline core::Handle;
typedef PageId   = inline core::Handle;

const BlockId  BLOCK_INVALID  = (BlockId)core::HANDLE_INVALID_VALUE;
const HolderId HOLDER_INVALID = (HolderId)core::HANDLE_INVALID_VALUE;
const PageId   PAGE_INVALID   = (PageId)core::HANDLE_INVALID_VALUE;
```

Generations bump on eviction. Phase 1 never evicts, but the handle
machinery is in place so Phase 2's LRU can rely on it.

---

## 5. Data shapes

```c3
module c3voxel::world;

import c3voxel::gpu;

struct Block {
    BlockCoord     cx, cz;
    HolderId[HOLDERS_PER_BLOCK * HOLDERS_PER_BLOCK] holders;
    gpu::Texture2D heightmap;      // R32F, dimension = PIXELS_PER_PAGE * PAGES_PER_HOLDER * HOLDERS_PER_BLOCK
    bool           heightmap_dirty;
}

struct Holder {
    HolderCoord      hx, hz;
    PageId[PAGES_PER_HOLDER * PAGES_PER_HOLDER] pages;
    gpu::Framebuffer fbo_layer0;   // RGBA8 color + R16F height MRT, 512²
}

struct Page {
    PageCoord        px, pz;
    Vec4             world_min;
    Vec4             world_max;
}

struct BlockPool {
    Block[]   storage;
    Hash{IVec3, int} lookup;       // (cx, 0, cz) → storage index
    Allocator allocator;
}

struct HolderPool {
    Holder[]  storage;
    Hash{IVec3, int} lookup;       // (hx, 0, hz) → storage index
    Allocator allocator;
}

struct PagePool {
    Page[]    storage;
    Hash{IVec3, int} lookup;       // (px, 0, pz) → storage index
    Allocator allocator;
}
```

Pool entry points:

```c3
fn BlockId  BlockPool.get_or_create(&self, BlockCoord cx, BlockCoord cz);
fn Block*   BlockPool.get(&self, BlockId id);
fn HolderId HolderPool.get_or_create(&self, HolderCoord hx, HolderCoord hz);
fn Holder*  HolderPool.get(&self, HolderId id);
fn PageId   PagePool.get_or_create(&self, PageCoord px, PageCoord pz);
fn Page*    PagePool.get(&self, PageId id);
```

Each `get` validates generation; a stale handle returns `null`.

---

## 6. Startup pipeline

```
// 1. world setup
BlockPool.get_or_create(0, 0)             → 1 block
terrain::generate_heightmap_cpu(block)    → CPU buffer of floats
gpu::texture2d_upload(block.heightmap, ...)

// 2. hierarchy allocation
for each holder in block (4 of 64 slots used):
    HolderPool.get_or_create(hx, hz)
    gpu::framebuffer_create({
        .width = 512, .height = 512,
        .colors = { RGBA8, R16F },
        .has_depth = false,
    }) → holder.fbo_layer0
    for each page in holder (4 of 4 slots used):
        PagePool.get_or_create(px, pz)
        compute page.world_min / world_max from (px, pz)

// 3. generate + raymarch per page
for each page (16 total):
    slot = volume_ring.next()
    gen.dispatch(cmd, volume_ring, slot, page, block.heightmap)
    jfa.build(cmd, volume_ring.volume(slot), df_ring[slot])
    rm.dispatch_into(cmd, volume_ring, slot, df_ring[slot], page, holder.fbo_layer0)
```

`rm.dispatch_into` computes the sub-rectangle of the holder FBO
corresponding to the page's `(px, pz)` offset within the holder
(`PAGES_PER_HOLDER = 2` → 4 sub-rects each 256²). The raymarch
compute shader writes pixels starting at that offset.

VolumeRing recycles 4 volume textures across 16 raymarches. After
startup, all volumes can either be retained (useful for Phase 2
regeneration on dirty) or freed. Phase 1 retains them to avoid
re-allocation churn when Phase 2 lands.

---

## 7. Per-frame pipeline

```c3
while (!win.should_close()) {
    clock.tick();
    if (...reload checks...) { ... }

    cmd.begin_frame();
    cmd.bind_default_framebuffer();
    cmd.set_viewport(0, 0, win.fb_width, win.fb_height);
    cmd.clear(0.02, 0.02, 0.04, 1.0);

    composite.dispatch(&cmd, &holder_pool, &cam);

    cmd.end_frame();
    win.poll(); win.swap();
}
```

`composite.dispatch` binds up to 4 holder sprite textures (color
+ height) plus the camera UBO and issues a single fullscreen triangle.
The fragment shader computes the iso-projected uv for each holder's
screen rectangle, samples both layers, picks the fragment with the
largest height value, and writes the resulting color.

Phase 1 doesn't need a composite camera UBO more elaborate than the
existing one — iso math already lives in `game::camera_isometric`.
Compositor receives a precomputed list of `{ holder_tex_color,
holder_tex_height, screen_rect_min, screen_rect_max, world_depth }`
quads; the fragment derives uv per-holder via inverse iso transform.

---

## 8. Shader contracts

### generate.comp.glsl (extended)

```glsl
layout(binding = 0, rgba8) uniform restrict writeonly image3D volume;
layout(binding = 1)        uniform sampler2D heightmap;         // R32F

layout(std140, binding = 2) uniform U {
    vec4 world_min;       // page AABB
    vec4 world_max;
    vec4 block_origin;    // heightmap 0,0 in world XZ
    vec4 block_extent;    // heightmap covers this XZ span
    float time;
};
```

Per-voxel: sample `heightmap` at `world_pos.xz`, compare to
`world_pos.y`. Below height ⇒ solid. Color banded:
`< 0.25h` stone, `< 0.7h` dirt, `≥ 0.7h` grass. (Exact thresholds TBD
in implementation.)

### raymarch.comp.glsl (extended)

```glsl
layout(binding = 0) uniform sampler3D  volume;
layout(binding = 1) uniform usampler3D dist_field;
layout(binding = 2, rgba8) uniform restrict writeonly image2D color_out;
layout(binding = 3, r16f)  uniform restrict writeonly image2D height_out;

layout(std140, binding = 4) uniform U {
    vec4 camera_pos, camera_forward, camera_right, camera_up;
    vec4 world_min, world_max;
    ivec4 resolution;       // x,y = sprite size
    ivec4 write_offset;     // x,y = destination pixel offset within color/height_out
    ivec4 pitches;
    float half_extent_x, half_extent_y;
};
```

`color_out` and `height_out` are the *holder's* attachments. Each page
writes into a `PAGES_PER_HOLDER × PAGES_PER_HOLDER` sub-rect starting
at `write_offset`. Height stored is the hit's world-space y (linear
depth for compositor).

### composite.frag.glsl (new)

```glsl
layout(binding = 0) uniform sampler2D holder0_color;
layout(binding = 1) uniform sampler2D holder0_height;
layout(binding = 2) uniform sampler2D holder1_color;
layout(binding = 3) uniform sampler2D holder1_height;
// ... up to holder3

layout(std140, binding = 8) uniform U {
    vec4 screen_min[4];      // iso rect in screen pixels
    vec4 screen_max[4];
    ivec4 screen_size;       // framebuffer w,h
};

in  vec2 v_frag;             // framebuffer pixel
out vec4 frag_color;

void main() {
    float best_h = -1e30;
    vec4  best_c = vec4(0.02, 0.02, 0.04, 1.0);
    for (int i = 0; i < 4; i++) {
        vec2 p = v_frag;
        if (any(lessThan(p, screen_min[i].xy)) || any(greaterThan(p, screen_max[i].xy))) continue;
        vec2 uv = (p - screen_min[i].xy) / (screen_max[i].xy - screen_min[i].xy);
        float h = texture(holder_height[i], uv).r;
        if (h > best_h) {
            best_h = h;
            best_c = texture(holder_color[i], uv);
        }
    }
    if (best_h <= -1e30) discard;
    frag_color = best_c;
}
```

(Actual indirection via a sampler array or bindless handles per c3c
support — detail nailed during implementation.)

---

## 9. Heightmap (CPU)

`terrain::generate_heightmap_cpu(block) -> float[]` returns a
`block_w × block_w` R32F buffer where
`block_w = PIXELS_PER_PAGE * PAGES_PER_HOLDER * HOLDERS_PER_BLOCK` (for
a 1-block world, but we use only the first `4 * PIXELS_PER_PAGE = 512`
pixels in each axis). The noise input is seeded from `(cx, cz)` so
repeated runs produce identical output.

Implementation details land when the user's reference implementation
drops into `docs/`.

---

## 10. Memory budget

| Resource | Format | Count | Size each | Total |
|----------|--------|-------|-----------|-------|
| Block heightmap | R32F 512² | 1 | 1.0 MB | 1 MB |
| Holder FBO layer0 (color) | RGBA8 512² | 4 | 1.0 MB | 4 MB |
| Holder FBO layer0 (height) | R16F 512² | 4 | 512 KB | 2 MB |
| VolumeRing | RGBA8 128³ | 4 | 8 MB | 32 MB |
| DF ring | R8UI 32³ × 2 ping-pong | 8 | 32 KB | 256 KB |
| **Total** | | | | **~40 MB** |

Comfortably within the arch's 600 MB aggregate budget.

---

## 11. Testing

**Automated:**

- `c3c build linux` clean, zero warnings.
- `c3c compile-test` under `test/**` — unit tests for
  `PagePool.get_or_create` generation-invalidation on destroy, for
  `core::Hash` lookup correctness, for `VolumeRing.next` round-robin.

**Manual smoke:**

- Window opens, terrain visible, 16 pages stitched with no seams.
- Height bands distinguishable (grass/dirt/stone).
- Editing any of `{terrain.c3 CPU noise, generate.comp, raymarch.comp,
  composite.frag}` on disk and saving triggers the change within the
  reload interval.
- No `GL_KHR_debug` errors logged.
- Frame time < 16 ms at 1080p on the RTX 4090 dev target.

---

## 12. File-level change summary

| File | New | Modified |
|------|-----|----------|
| `src/core/hash.c3` | ✓ | |
| `src/core/pool.c3` | ✓ | |
| `src/world/terrain.c3` | ✓ | |
| `src/world/block.c3` | ✓ | |
| `src/world/holder.c3` | ✓ | |
| `src/world/page.c3` | ✓ | |
| `src/world/coords.c3` | | extend |
| `src/voxel/volume.c3` | | VolumeRing |
| `src/voxel/generate.c3` | | heightmap sampler |
| `src/voxel/raymarch.c3` | | MRT + write_offset |
| `src/render/composite.c3` | ✓ | |
| `resources/shaders/composite.{vert,frag}.glsl` | ✓ | |
| `resources/shaders/generate.comp.glsl` | | heightmap + per-page bounds |
| `resources/shaders/raymarch.comp.glsl` | | MRT + sub-rect writes |
| `src/main.c3` | | rework |

---

## 13. Todos filed alongside this spec

- `todo-N`: move Block heightmap generation from CPU to GPU compute
  pass (decision C → A). Defer until Phase 2 or later lands.
- `todo-N`: camera pan/zoom UI + input bindings. Required by Phase 2
  to exercise streaming; may be filed as a Phase 2 task rather than a
  standalone todo.
- `todo-N`: expand the holder MRT to include normal + material ID
  once M8 lighting needs them (arch's two-MRT `fbo_layer0`).

Exact todo numbers assigned after the spec is committed; the current
`task-counters.json` counter is `todo = 11`.

---

## 14. Out of scope (handed to Phase 2)

- `world::streaming` module, `GpuPool` with LRU.
- `Holder` eviction / reuse.
- Per-frame dirty queue with regen budget.
- Camera-driven `update(camera_pos)` that determines visibility and
  populates the dirty queue.
- `fbo_layer1` (transparent layer).
- Handle-reuse correctness under eviction (the generation machinery is
  there, but Phase 1 never exercises it).

---

## 15. Risks / open questions

- **Sub-rect raymarch uniforms.** The raymarch compute shader already
  reads its `resolution` and `pitches` from a UBO. Adding
  `write_offset` is mechanical but must respect std140 alignment
  (needs to land as `ivec4` to avoid padding surprises).
- **Heightmap sampling in generate.** World-to-heightmap UV
  derivation happens per-voxel-column, not per-voxel. Phase 1 can
  recompute per-voxel for simplicity; if profiling shows it to be
  cheap enough (it should) no further work.
- **Composite pass sampler indirection.** GLSL doesn't allow dynamic
  sampler indexing cleanly without `ARB_bindless_texture`. For
  Phase 1 with exactly 4 holders we can hard-code the 4 sampler
  uniforms and unroll the loop. Generalising to N holders is Phase 2's
  `world::streaming` concern.
- **VolumeRing retention.** Retaining the 4 volume textures past
  startup for Phase 2's regen use costs 32 MB. Cheap. If tight on
  VRAM later, freeing after startup and re-allocating on first regen
  is a trivial adjustment.
