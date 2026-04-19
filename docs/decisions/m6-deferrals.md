---
title: M6 deferred items — top-down raymarch, pool clamp, page-granularity
thread_id: decision/m6-deferrals
logged_at: 2026-04-19
commits: ["8705a24", "f14c226", "dd837a0", "593cba1"]
---

## Context

M6 (Phase 1 + Phase 2) ships with three deliberate deviations from the
authoritative spec
(`docs/superpowers/specs/2026-04-19-m6-phase2-design.md`). Each is
tracked as a todo; this ADR captures the reasoning so the milestone
can be honestly closed.

## Decisions

### D1 — Top-down raymarch kept; true-iso rewrite deferred (todo-12)

Spec §2-addendum.1 and §7 require the raymarch compute shader to
derive per-pixel ray origins through the inverse iso map and walk
along `iso_forward` into the volume. The actual implementation in
`resources/shaders/raymarch.comp.glsl` and
`src/voxel/raymarch.c3:dispatch_into` retains Phase 1's top-down
per-page shortcut — each holder sprite holds a plan-view render of
its 4 pages arranged in a 2×2 grid, with `write_offset` selecting the
sub-rect.

**Why deferred:** the iso rewrite is ~150 LOC of shader + UBO
refactor with no way to validate correctness except by visual
inspection. The remaining time budget favoured finishing streaming
end-to-end; the visual mismatch (sprites are top-down but positioned
at iso-projected screen rects) is documented rather than hidden.

**Consequence:** neighbouring holders will not align along the iso
diagonal. Zoom-change has no visual effect on sprite content
(top-down is zoom-invariant). Acceptable for the streaming demo; fix
lands when todo-12 is scheduled.

### D2 — Visibility clamped to a radius instead of the view frustum (todo-13)

Spec §5 + §2-addendum.5 expect `visible_holder_rect` to map 1-to-1
onto the iso screen rect. At default zoom + 1280×720 window, the
true visible rect contains ~100 holders vs `POOL_SIZE = 16` — a 6×
over-subscription that thrashes the pool if left unchecked.

**Decision:** `streaming_update`
(`src/world/streaming.c3:128-146`) skips any holder whose centre
exceeds `sqrt(POOL_SIZE / π) * HOLDER_WORLD_EXTENT * 0.95` world
units from the pan target. This yields a circular terrain patch
that fits the pool exactly. Holders outside the circle are simply
not in the visible set.

**Why deferred:** the "proper" fix is a larger `POOL_SIZE`, dynamic
pool growth, or `sampler2DArray` composites — all incompatible with
Phase 2's fixed 16-sampler shader. Tracking as todo-13 until the
composite shader supports variable slot counts or the pool grows.

**Consequence:** at zoom 0.5× the visible screen extends well beyond
the clamp radius; the corners of the framebuffer show clear-colour
rather than terrain. User sees a "porthole" into the world.

### D3 — Dirty entries are holder-granular, not page-granular (todo-14)

`DirtyEntry { HolderId id; uint enqueue_frame; }` at
`src/world/streaming.c3:20-23`. `drain_dirty` always regenerates all
4 pages of the popped holder. Correct for Phase 2 since every dirty
event is "full holder freshly acquired"; insufficient if future
features introduce partial updates (per-page edits, sparse
re-gens).

**Why deferred:** no current caller produces per-page dirties. Adding
a `pages_dirty: uint` bitmask to `DirtyEntry` is ~10 LOC but
unnecessary until the need arises.

**Consequence:** when M10 editing lands, this struct must be
extended or the dirty queue will regen 4 pages when 1 is enough.

## Consequences (meta)

- M6 acceptance criteria in the spec §13 pass at the code level
  with these deferrals; §13 bullets that depend on the iso raymarch
  (seam-free composite) are explicitly noted as deferred.
- The spec's §2-addendum.8 memory budget is stale; actual high-water
  is ~65 MB (down from the 79 MB projection) because
  `HOLDER_FBO_SIZE = 256` was retained alongside the top-down
  shortcut. Superseded only when todo-12 bumps the FBO.
- Phase 2 runs at 60 fps on the RTX 4090 / D3D12 passthrough target,
  pool stays at 16 with dirty=0 in steady state; no leaks or GL
  errors observed over the review timeframe.

## References

- Phase 1 spec: `docs/superpowers/specs/2026-04-19-m6-phase1-multi-page-hierarchy-design.md`
- Phase 2 spec: `docs/superpowers/specs/2026-04-19-m6-phase2-design.md`
- Phase 2 plan: `docs/superpowers/plans/2026-04-19-m6-phase2-plan.md`
- Bridge todo ids: `c3voxel/todo-12`, `c3voxel/todo-13`, `c3voxel/todo-14`
