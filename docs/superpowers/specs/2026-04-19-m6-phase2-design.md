# M6 Phase 2 — Streaming + Iso Composite

Design document for the second of two M6 phases. Phase 2 lands:

1. The arch's `GpuPool` with LRU eviction + dirty-holder queue.
2. Camera pan/zoom input driving a `streaming::update()` pass that
   adds / evicts holders as the camera moves.
3. Replacement of Phase 1's top-down per-page raymarch shortcut with
   the arch-faithful iso sprite cache — each holder renders once from
   the fixed iso camera, composite blits sprites at their iso-projected
   screen positions.

Milestone reference: `docs/ARCHITECTURE.md` §GPU Pool (§the hot path),
§Regeneration Budget; `docs/high-level-spec.md` §Milestone 6 "Done
when".

Phase 1 design: `docs/superpowers/specs/2026-04-19-m6-phase1-multi-page-hierarchy-design.md`.

---

## 1. Goals & non-goals

**Goals**

- Camera pans (mouse drag) and zooms (scroll) over an unbounded
  procedural terrain world.
- A 16-slot `GpuPool` holds the in-view holders. Panning evicts
  holders whose last-touched frame is oldest; the newly visible
  holders regenerate under a 4-per-frame budget.
- Iso-projected sprite cache: each holder raymarches once from a
  fixed iso camera into a 512² MRT FBO. The composite pass blits up
  to 16 sprites at their iso-projected screen positions every frame
  (cheap; no re-raymarch on pan).
- Handles correctly invalidate: `HolderPool.evict` bumps the
  generation; `get(old_id)` returns `null`.
- No memory growth under sustained panning; no frame-time spikes
  during fast pans.

**Non-goals**

- `fbo_layer1` (transparent layer) — M10.
- Bindless sampler indexing in composite — M9.
- GPU-driven heightmap generation (still `todo-2`).
- Multi-layer worlds (underground/sky) — M10.
- Async generation threads — Phase 2 runs everything on the main
  thread.
- Retro-fixing Phase 1's per-page top-down raymarch: Phase 2 replaces
  it wholesale rather than trying to keep it alive alongside iso.

---

## 2. Locked decisions (from brainstorm)

| # | Question | Decision |
|---|----------|----------|
| 1 | Scope | Streaming + iso fix combined. |
| 2 | World extent, pool size | Unbounded world; 16-holder pool. |
| 3 | Iso storage | Per-holder iso-projected sprite (fixed iso camera per raymarch). |
| 4 | Startup policy | Full on-demand streaming; no sync warm-up. |
| 5 | Visibility shape | World-aligned XZ rectangle around the view frustum + 1-holder margin. |
| 6 | Eviction policy | LRU by `last_touched_frame`; ties broken by `HolderId` order. |
| 7 | Regen budget | 4 holders/frame (`MAX_REGEN_PER_FRAME`). Dirty queue sorted by distance from camera target before draining. |
| 8 | Block auto-create | Lazy. First holder that needs a block calls `BlockPool.get_or_create` + CPU-generates heightmap synchronously. Accepts a one-frame stall. |
| 9 | Input | Left-mouse drag = pan; scroll wheel = zoom (three discrete steps: 0.5×, 1×, 2×); ESC = close. |
| 10 | Camera | `CameraState` gains `Vec3 pan_target` + `float zoom_scale`; `camera_isometric(…)` reads them. |

---

## 3. Module layout

```
src/world/streaming.c3               NEW — GpuPool + dirty queue + update/drain
src/world/visibility.c3              NEW — visible-rect helpers
src/platform/input.c3                NEW — mouse state aggregator
src/platform/window.c3               EXT — mouse move/button/scroll callbacks
src/game/camera.c3                   EXT — pan_target, zoom_scale; camera_isometric reads both
src/voxel/raymarch.c3                EXT — holder-sprite dispatch (iso camera + full-FBO writes)
src/render/composite.c3              EXT — 16 sprite slots, per-pool-slot iso-projected screen rects
resources/shaders/raymarch.comp.glsl EXT — iso basis from UBO; writes into the whole FBO (no sub-rect)
resources/shaders/composite.frag.glsl EXT — 16 sampler pairs, max-height compose
src/main.c3                          REWORK — drop startup loop; per-frame pipeline
src/world/holder.c3                  EXT — evict() bumps generation, releases FBO, returns to pool
src/world/block.c3                   EXT — on-demand heightmap upload trigger
```

---

## 4. `GpuPool` + dirty queue

```c3
module c3voxel::world;

const int POOL_SIZE            = 16;
const int MAX_REGEN_PER_FRAME  = 4;
const int VISIBLE_MARGIN_HOLDERS = 1;

struct PoolSlot {
    HolderId owner;                    // HOLDER_INVALID if free
    uint     last_touched_frame;
}

struct GpuPool {
    PoolSlot[POOL_SIZE] slots;
    uint                current_frame;
}

alias DirtyQueue = List{HolderId};

fn void GpuPool.init(&self);
fn int  GpuPool.acquire(&self, HolderId for_holder, HolderPool* holders);   // returns slot index; infallible
fn void GpuPool.touch(&self, int slot_idx);
fn int  GpuPool.find_slot(&self, HolderId id) @inline;                      // returns -1 if not present
```

`acquire`:

1. Walk `slots`; if any is free, use it.
2. Otherwise pick the LRU slot (min `last_touched_frame`; tiebreak
   on lower slot index). Invalidate the old owner via
   `HolderPool.evict(old_owner)`: bumps generation, destroys
   FBO, zeroes slot.
3. Allocate a fresh `Framebuffer` for the new holder, assign
   slot ownership, set `last_touched_frame = current_frame`.
4. Push the holder's `HolderId` onto the caller-supplied
   `DirtyQueue` (first-time regen).

`touch(slot_idx)` just updates `last_touched_frame` so the holder
stays hot during re-visits.

---

## 5. Streaming update

```c3
fn void streaming::update(
    GpuPool*    pool,
    BlockPool*  blocks,
    HolderPool* holders,
    PagePool*   pages,
    DirtyQueue* dirty,
    CameraState* cam
) {
    pool.current_frame++;

    HolderRect rect = visibility::visible_holder_rect(cam);
    for each (hx, hz) in rect:
        HolderId hid = ensure_holder_exists(blocks, holders, pages, hx, hz);
        int slot = pool.find_slot(hid);
        if (slot >= 0) {
            pool.touch(slot);
        } else {
            pool.acquire(hid, holders);
            dirty.push(hid);
        }
}
```

`ensure_holder_exists`:

- Compute `BlockCoord (cx, cz)` from `(hx, hz)`. Call
  `BlockPool.get_or_create`.
- If the returned block is dirty (heightmap_dirty), run
  `terrain::generate_heightmap_cpu` synchronously. Amortized over
  time because blocks are large.
- Call `HolderPool.get_or_create(hx, hz)` → new `HolderId` (freshly
  allocated FBO inside).
- Ensure its four `Page` children exist in `PagePool`.

---

## 6. Dirty drain (per-frame regen)

```c3
fn void streaming::drain_dirty(
    Commands* cmd,
    GenerateContext* gen,
    JumpFloodContext* jfa,
    RayMarchContext* rm,
    VolumeRing* ring,
    DistanceField* df,
    BlockPool*  blocks,
    HolderPool* holders,
    PagePool*   pages,
    GpuPool*    pool,
    CameraState* cam,
    int budget
) {
    dirty.sort_by_distance(cam.pan_target);
    int done = 0;
    while (done < budget && !dirty.is_empty()) {
        HolderId hid = dirty.pop_front();
        Holder* h = holders.get(hid);
        if (h == null) continue;      // evicted before its turn

        Block* block = blocks.get(block_of(h));   // heightmap already guaranteed fresh

        for each page of h:
            int slot = ring.next();
            gen.dispatch_page(cmd, ring, slot, page, block.heightmap, block_origin, block_extent, cam.time);
            Volume tmp = { .tex = ring.slot(slot) };
            jfa.build(cmd, &tmp, df);
            rm.dispatch_holder_page(cmd, ring, slot, df, page, &h.fbo_layer0, iso_view_for(h, cam.zoom_scale));

        done++;
    }
}
```

`iso_view_for(holder, zoom)` builds a `View` with:

- `position` = centered above the holder's world AABB in iso
  projection space, offset so the ortho frustum covers the holder.
- `forward / right / up` = the global iso basis (computed once per
  frame from `cam.zoom_scale`, not per holder).
- `half_extent_x / half_extent_y` = the holder's iso screen
  footprint (fixed size regardless of world position).

The sub-rect `write_offset` of Phase 1 disappears: each holder's
sprite fills the whole 512² FBO. Pages within a holder contribute by
writing to different regions of the same sprite based on their
iso-projected XZ within the holder.

---

## 7. Iso raymarch

The arch's iso projection (`docs/ARCHITECTURE.md` §Isometric Projection)
maps world to screen via

```
screen.x = world.x - world.z
screen.y = -tilt * (world.x + world.z) - world.y
```

with `tilt = sin(35.264°) / 2` by default. For the raymarch:

- Each sprite pixel's ray origin is derived by back-projecting the
  pixel's screen coordinate through the ortho iso projection to a
  point on the holder's near plane.
- Ray direction is the *iso forward* vector, constant across all
  pixels and all holders. Only the origin changes.
- Ray enters and exits the page volume via the usual slab test.

One raymarch dispatch per `(holder, page)` pair. Four per holder.
Four pages share the same iso basis but different world AABBs.

The `write_offset` in `RayMarchUniforms` still exists but now it's
the iso-projected pixel offset of this page within the holder sprite,
not the `PIXELS_PER_PAGE`-aligned grid of Phase 1.

---

## 8. Composite

Unchanged shape but:

- Up to 16 sprite pairs instead of 4. GLSL binding slots 0..31 for
  color+height; slot 32 for the UBO. Unrolled loop over 16
  (acceptable in c3c 0.7.11; simplifies Phase 2).
- Per-slot `screen_min / screen_max / world_anchor / alive_bit` in
  UBO. `alive_bit` skips empty slots in the loop.
- Depth resolution via max-height survives — but height is now in
  iso screen-space Y, not voxel Y. Update shader accordingly.

### Pseudocode (composite.frag.glsl)

```glsl
// ... 16 × (sampler2D color, sampler2D height) ...
layout(std140, binding = 32) uniform U {
    vec4  screen_min[16];
    vec4  screen_max[16];
    ivec4 screen_size;
    ivec4 alive_bits;   // bitmask: which of the 16 slots are live this frame
};
void main() {
    float best_h = -1e30;
    vec4  best_c = vec4(0.0);
    for (int i = 0; i < 16; i++) {
        if ((alive_bits.x & (1 << i)) == 0) continue;
        // rect test, sample, max-height compare — identical to Phase 1
    }
    if (best_h <= -1e30) discard;
    frag_color = best_c;
}
```

---

## 9. Input

`src/platform/input.c3` collects per-frame mouse state:

```c3
struct MouseState {
    double x, y;
    double dx, dy;          // frame delta (0 unless left-drag)
    bool   left_down;
    int    scroll_steps;    // signed net since last poll
}

fn void input::poll(MouseState* m, Window* win);
```

`Window.init` already registers key + fb-size callbacks. Add cursor
position, mouse button, and scroll callbacks that write into the
`MouseState` owned by `main`.

Pan delta maps: `pan_world_dx = -mouse.dx * PAN_SENSITIVITY *
cam.zoom_scale`. Zoom step: `cam.zoom_step(mouse.scroll_steps)`
snaps to the nearest level in `{ 0.5, 1.0, 2.0 }`.

---

## 10. Camera

```c3
struct CameraState {
    // ...existing basis fields...
    core::Vec3 pan_target;        // world XZ (y = 0)
    float      zoom_scale;        // 0.5 / 1.0 / 2.0
}

fn CameraState camera_isometric(
    core::Vec3 pan_target,
    float      zoom_scale,
    float      aspect,
    core::Degrees azimuth_deg = ISO_AZIMUTH_DEG
);
```

`camera_isometric` now reads `pan_target` + `zoom_scale` every frame
to rebuild the basis; unchanged interpretation of the other fields.

---

## 11. Per-frame pipeline

```c3
while (!win.should_close()) {
    clock.tick();
    input::poll(&mouse, &win);
    apply_pan_zoom(&cam, &mouse);

    streaming::update(&pool, &blocks, &holders, &pages, &dirty, &cam);
    streaming::drain_dirty(&cmd, &gen, &jfa, &rm, &ring, &df,
                           &blocks, &holders, &pages, &pool, &cam,
                           MAX_REGEN_PER_FRAME);

    cmd.begin_frame();
    cmd.bind_default_framebuffer();
    cmd.set_viewport(0, 0, win.fb_width, win.fb_height);
    cmd.clear(0.02, 0.02, 0.04, 1.0);
    composite::dispatch(&cmd, &pool, &holders, &cam, win.fb_width, win.fb_height);
    cmd.end_frame();

    win.poll();
    win.swap();
}
```

---

## 12. Memory budget

| Resource | Count | Size each | Total |
|----------|-------|-----------|-------|
| Holder sprite FBO (RGBA8+R16F 512²) | 16 | 1.5 MB | 24 MB |
| Block heightmap cache | ~9 active (3×3 blocks cached) | 1 MB | 9 MB |
| VolumeRing (RGBA8 128³) | 4 | 8 MB | 32 MB |
| DF ring (R8UI 32³ × 2) | 8 | 32 KB | 256 KB |
| Composite UBO | 1 | ~2 KB | 2 KB |
| Dirty queue + pool state | 1 | < 4 KB | 4 KB |
| **Total** | | | **~65 MB** |

---

## 13. Testing / done-when

- `c3c build linux` clean; zero warnings.
- Launch: terrain appears within ~1 s (budget fills the initial
  view).
- Mouse drag pans; new holders pop into view. No holders ever
  flicker or revert.
- Scroll wheel cycles zoom levels 0.5× / 1× / 2× with correct scale.
- 30-second random-walk pan: frame time stays < 16 ms throughout.
- Eviction: after panning far, the pool contains 16 holders near
  the new camera position; a reference to an old holder's
  `HolderId` returns `null` from `holders.get(...)`.
- Memory leak check: `glGet` queries for active texture / buffer /
  FBO counts are stable across a 5-minute pan session.
- No `GL_KHR_debug` errors logged in debug output.

---

## 14. Risks

- **Tilt overhang vs FBO size.** 512² with 256-voxel-wide holder
  gives ~40% margin. If sprites clip at edges under 0.5× zoom,
  either bump FBO or adjust `iso_view_for` margins. Flag for a
  follow-up visual check.
- **Pool exhaustion under aggressive zoom-out.** At 0.5× zoom the
  visible rect grows to 2× in each axis; visible holder count can
  exceed 16. First mitigation: cap zoom-out at a level the pool
  can handle. Second mitigation: bump `POOL_SIZE` (memory budget
  scales linearly).
- **Zoom change invalidates all sprites.** Switching zoom marks
  every pool slot dirty — 16 regens at 4/frame = 4-frame visible
  rebuild. Acceptable; user sees a "wave" across the screen.
- **Block heightmap CPU stall.** When a pan crosses a Block
  boundary (every ~PIXELS_PER_PAGE × PAGES_PER_HOLDER ×
  ACTIVE_HOLDERS_PER_AXIS = 512 world pixels) we burn one frame
  regenerating the new block's heightmap. Flagged for todo-2
  (the GPU-heightmap pass resolves it).
- **Stale Block references.** Blocks stay alive as long as any of
  their holders live in the pool. Evictions reference-count
  through `HolderPool.evict` which (should) decrement the block's
  ref count and destroy it at zero. Implement or defer to "blocks
  leak" + "memory grows slowly" note + todo.

---

## 15. Out of scope (handed forward)

- Transparent layer (`fbo_layer1`) — M10.
- Bindless texture array indexing in the composite — M9.
- GPU heightmap generation — todo-2.
- Multi-layer worlds — M10.
- Async generation threads — later.
- Persistent state across frames (e.g. dirty queue of *pages* for
  per-page regeneration) — Phase 2 regenerates holders wholesale.
