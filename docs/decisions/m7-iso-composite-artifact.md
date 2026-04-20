# Iso Composite — Far-Holder Terrain Compression

**Observed:** M7.3 visual verification (2026-04-19).
**Status:** Open; deferred to M9 via oversampled holder volumes.

## What's happening

At any pan position, the holder containing the pan focus renders terrain
correctly — hills, trees, depth, all visible. Holders at greater distance
along the iso-forward direction (`hx + hz` larger than pan's holder) render
as a flat banded surface: horizontal stripes, no visible relief, almost
"reflective" look.

Screenshot: reference `vq-test-2.png` (user archive). Near-holder shows
a maze town with proper terrain around it; far-holders to the left, right,
and below of the town appear stretched and lose 3D look.

## Why

Per-holder FBO design from M6.5: each holder raymarches into a 1024×1024
FBO that encodes its own 256×256 world-units covered by its own
256×128×256 volume, using holder-local iso origin. Composite samples each
FBO onto a screen rect computed via `compute_holder_screen_rect` in
`main.c3`.

The iso_bbox that raymarch encodes is **identical** across all holders
(same extent, same volume height). But each holder's screen rect is
placed at a different iso offset based on `(holder_center - pan_target)`.
Holders far along the iso-forward axis end up with screen rects that
extend further DOWN. Within those rects, the holder's 128-tall volume
gets mapped through the same 275-unit iso-sy span → visually compressed
relief vs the near holder that's rendering the same volume into the same
275-unit span at the same screen scale.

The rendering is mathematically self-consistent per holder. The failure
mode is that adjacent holders' FBOs don't reveal a continuous terrain
across the boundary — each FBO shows ONLY its own 256-unit patch, with
the "side face" of adjacent patches missing.

## Proper fixes (post-M7.4)

1. **Oversampled volumes** — each holder raymarches a ~1.25× wider region
   that overlaps neighbors, so the terrain near the holder edge contains
   voxels from the adjacent block. VQ's "buffer A" mode. Scheduled for M9.
2. **Single screen-space raymarch** — drop the per-holder FBO composite
   and raymarch directly into the backbuffer from the camera. Rays sample
   the PageGeometry SSBOs of whichever block they hit. Ties into M10's
   perspective camera sub-milestone.
3. **Projected ortho with depth sort** — standard graphics ortho projection
   matrix. Would break the sprite-cache architecture for M6.5, much larger
   rearchitecture.

## M7.3 impact

None blocking. The artifact is visible but doesn't change correctness of
road generation or rendering. Buildings (M7.4) will live at the pan focus
holder where terrain renders correctly.
