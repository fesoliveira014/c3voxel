# M8 — Deferred Lighting Chain

**Status:** design approved 2026-04-20
**Scope estimate:** ~400 GLSL, ~200 C3 (per `docs/high-level-spec.md` §M8)
**Dependencies:** M7.4 complete (the village with buildings, trees, roads, materials).
**Follow-ups (noted, not scoped):** M9 (bindless neighbour DF), adaptive shadow DF (options C1/C2), M10 (moon, radiosity, fog, water, tonemap upgrade, GTAO).

---

## 1. Goal

Turn the flat material IDs from M7 into a properly lit scene: palette-based coloring, screen-space heightfield shadows via a short-range ray-march, VQ-style multi-radius height-sampling AO, and a day/night cycle driven by `time_of_day`.

Acceptance criteria (from the high-level spec, unchanged):

1. The M7 village renders with a moving sun producing directional shading.
2. Shadows cast correctly from buildings and trees.
3. AO visibly darkens corners and concavities.
4. No visible seams between page boundaries in the lit image.

---

## 2. Pass graph

Before M8, today's chain is:

```
generate.comp → jump_flood.comp → raymarch.comp → composite.frag → swap
                [per-holder, regen]                [screen]         [default FBO]
```

M8 replaces the tail of this chain with a deferred sequence. `generate` and `jump_flood` stay as today; `raymarch` changes its output format; everything from composite onward is new or rewritten.

```
[per-holder regen, when dirty]
  generate.comp         writes 3D volume: .rgb = packed normal (octahedral),
                                          .b    = material_id / 255
                                          .a    = opacity
  generate_normal.comp  second dispatch: central-difference gradient over
                                          volume .a, writes back into .rg
                                          (octahedral-packed) via ping-pong
                                          through an RG8 aux ring texture
  jump_flood.comp       distance field, unchanged
  raymarch.comp         holder FBO (3 MRTs):
                          colors[0] R8UI  material_id
                          colors[1] RG8   octahedral normal
                          colors[2] R16F  height (world units)

[per frame, screen-space]
  composite.frag        screen G-buffer: single RGBA8 at fb_w × fb_h
                          .rg   octahedral normal
                          .b    height / MAX_WORLD_Y
                          .a    material_id / 255
                        max-height winner across the ≤16 live holder rects
  ao.frag               R8 AO texture (VQ-verbatim, docs/ssao.md)
                          low tier: 24 taps/pixel (8 angular × 3 radii)
                          high tier: 96 taps/pixel (toggle via F4)
  lighting.frag         final RGBA8 lit color:
                          albedo   = palette[material_id]
                          diffuse  = sun_color * max(N·L, 0) * march_shadow()
                          lit      = albedo * (ambient + diffuse) * ao
  present.frag          gamma-only blit to the default framebuffer
```

Sky pixels (where the G-buffer .a is zero) discard through the chain and are filled by `present.frag` with a constant sky color (neutral dark grey for M8; real sky can land in M10 alongside fog).

---

## 3. Module layout

Follows the existing `src/render/composite.c3` pattern: one module per pass, each owns one shader + one FBO, exposes `init(Allocator)`, `destroy()`, `dispatch(cmd, …)`. Firewall preserved — no GL calls outside `gpu/`.

### New modules

| File | Responsibility |
|------|----------------|
| `src/render/deferred.c3` | Owns the screen G-buffer FBO. Evolves today's `composite.c3` — keeps the per-holder-rect max-height selection, changes output format. |
| `src/render/ao.c3` | Owns the R8 AO FBO. Dispatches `ao.frag` low or high tier based on a bool uniform/flag; reads the G-buffer. |
| `src/render/lighting.c3` | Owns the final lit-color FBO, the `LightingUniforms` UBO, and the palette LUT (Texture2D 17×1 RGBA8). Dispatches `lighting.frag`. |
| `src/render/present.c3` | Minimal gamma pass → default framebuffer. |
| `src/game/time_of_day.c3` | Pure state: `time_of_day`, `auto_advance`, key-step size. Exposes `sun_direction_for(t)` and `sun_color_for(t)` as pure functions. |

### Changed modules

| File | Change |
|------|--------|
| `resources/shaders/generate.comp.glsl` | Volume output format changes from baked RGB color to packed `(normal.rg = 0, material_id/255, opacity)`. `material_color()` switch removed. |
| `resources/shaders/generate_normal.comp.glsl` (new) | Second compute dispatch: 6-tap central difference on `.a` of the volume, octahedral-pack, write back into `.rg`. |
| `src/voxel/generate.c3` | Adds the normal-pass dispatch after the main generate dispatch, before jump-flood. Needs one RG8 aux volume per ring slot for the ping-pong. |
| `src/voxel/raymarch.c3` + `resources/shaders/raymarch.comp.glsl` | Holder FBO grows from 2 MRTs to 3; shader output changes from `(color, height)` to `(material_id, octahedral_normal, height)`. |
| `src/world/holder.c3` | Holder FBO allocates three color attachments with the new formats. |
| `src/render/composite.c3` | Deleted — logic moved into `render/deferred.c3` with the format change. |
| `src/main.c3` | Frame loop inserts the new pass sequence; key handling for `[`, `]`, `P` (time), `F4` (AO tier). |
| `src/voxel/material.c3` | Adds `MATERIAL_COLORS[17]` constant array used to upload the palette LUT at init. Existing `MATERIAL_DEBUG_PALETTE` is repurposed. |

### Shader helpers

`resources/shaders/common/iso.glsl` (new, `#include`d): `iso_forward(world_xyz) → vec2 uv`, `iso_inverse(uv, height) → vec3 world_xyz`. Mirrors the C3 math in `src/game/camera.c3::world_xz_to_screen` and `src/world/visibility.c3::screen_to_world_xz`, using the y-up sy convention (see the `iso_sy_y_up_convention` memory).

`resources/shaders/common/octahedral.glsl` (new, `#include`d): `vec2 octahedral_pack(vec3 n)`, `vec3 octahedral_unpack(vec2 oct)`. Standard octahedral encoding from Cigolle et al. 2014 — 8 bits/axis is sufficient for shading; tested up to ~2° angular error.

---

## 4. Data formats

### Holder FBO (per holder, 512² or whatever `HOLDER_FBO_SIZE` is today)

```
colors[0]  R8UI    material_id             (exact integer; no color packing)
colors[1]  RG8     octahedral normal       (8 bits per channel, 2° max angular error)
colors[2]  R16F    height in world units   (kept wide for the composite max-test)
```

Raymarch on miss (ray escapes volume without an opaque hit): writes `material_id = 0`, `normal = (0.5, 0.5)` (octahedral pack of `+z`), `height = -1e30`.

Material `0` is reserved as `NULL`/air and is what the composite looks for when deciding a pixel is sky.

### Screen G-buffer (single RGBA8, fb_w × fb_h — full window resolution)

Packed to one texture for ssao.md cache-friendliness:

```
.r, .g   octahedral normal
.b       height / MAX_WORLD_Y    (MAX_WORLD_Y = 128; 256 levels, ~0.5-unit precision)
.a       material_id / 255        (17 materials fit comfortably)
```

Sky pixels written as `(0, 0, 0, 0)`; `.a == 0` ⇒ discard in lighting.

Rationale for one texture instead of three MRTs at screen scale: the AO pass samples 24–96 points per pixel, all needing normal + height in the same fetch. One RGBA8 fetch per sample beats two fetches (normal, height).

### AO target (R8, fb_w × fb_h)

Single channel, `1.0` = fully lit, `~0.4` = fully occluded (`pow(ao_raw, 6)` per ssao.md keeps contrast).

### Palette LUT (`gpu::Texture2D`, 17×1 RGBA8)

Uploaded once at init from a `MATERIAL_COLORS[17]` constant. Sampled by lighting via `texelFetch(palette, ivec2(material_id, 0), 0)`. Replaces the big `if`-chain in `material_color()`.

---

## 5. Uniform layouts (std140, follows `docs/ubo-convention.md`)

### `LightingUniforms`

```c3
struct LightingUniforms @packed @align(16) {
    core::Vec4  sun_dir;           // normalized, world space; .w unused
    core::Vec4  sun_color;          // RGB, linear; .a = intensity multiplier
    core::Vec4  ambient_color;      // RGB, linear; .a = intensity
    core::IVec4 resolution;         // fb_w, fb_h, 0, 0
    float       time_of_day;        // [0, 1)
    float       shadow_step;         // world units per shadow march step (= 1.0)
    int         shadow_max_steps;   // = 24
    int         ao_quality_high;    // bool; 0 = low (24 taps), 1 = high (96 taps)
}
$assert(LightingUniforms.sizeof % 16 == 0);
```

### `AoUniforms`

```c3
struct AoUniforms @packed @align(16) {
    core::Vec4 resolution;          // fb_w, fb_h, max_world_y, 0
}
$assert(AoUniforms.sizeof % 16 == 0);
```

### `PresentUniforms`

No UBO needed — present is a pure gamma pass; if a dim-knob lands later it can be added via a small UBO at that point.

---

## 6. Shadow marcher

Inline inside `lighting.frag`. Approach matches `docs/lighting.md` §3: precompute world and screen endpoints per pixel-per-light, then interpolate both in lockstep so the inner loop never projects.

```glsl
// Per-pixel, computed once per light before this function:
//   w_start = iso_inverse(v_uv, height)     // this pixel's world pos
//   s_start = v_uv
//   w_end   = w_start + light_dir * SHADOW_RANGE   // SHADOW_RANGE = 64.0
//   s_end   = iso_forward(w_end)

float march_shadow(vec3 w_start, vec2 s_start, vec3 w_end, vec2 s_end) {
    float total_hits = 0.0;
    float hit_count  = 0.0;
    for (int i = 1; i <= shadow_max_steps; i++) {   // start at 1 to skip self
        float f = float(i) / float(shadow_max_steps);
        vec3  w_cur = mix(w_start, w_end, f);
        vec2  s_cur = mix(s_start, s_end, f);
        if (any(lessThan(s_cur, vec2(0.0))) || any(greaterThan(s_cur, vec2(1.0)))) break;

        vec4  samp   = texture(gbuffer, s_cur);
        float cur_h  = samp.b * MAX_WORLD_Y;
        int   mat_id = int(samp.a * 255.0 + 0.5);

        // +2.0 world-unit bias prevents self-acne (lighting.md §3).
        float was_hit = float(cur_h > w_cur.y + 2.0);
        // Water (12) and glass (14) let light through; air (0) is empty sky.
        float opaque  = float(mat_id != 0 && mat_id != 12 && mat_id != 14);
        total_hits += was_hit * opaque;
        hit_count  += opaque;
    }
    if (hit_count < 1.0) return 1.0;
    float shadow = 1.0 - clamp(total_hits / hit_count, 0.0, 1.0);
    return clamp(pow(shadow, 2.0), 0.0, 1.0);
}
```

Parameters for M8:
- `SHADOW_MAX_STEPS = 24`. One building footprint worth of range at 24 steps × ~2.67 units/step.
- `SHADOW_RANGE = 64.0` world units — end of the march at `w_start + dir * 64`.
- `+2.0` world-unit bias on the height threshold (VQ-tuned in lighting.md §3).
- Water (id 12), glass (id 14), and air (id 0) pass through — they don't cast shadows.
- Loop breaks when the projected sample leaves `[0, 1]` UV.

Below-horizon direction (`light_dir.y < 0`): the march is still performed; since the world's height is ≥ `w_start.y` behind the shader, `was_hit` accumulates and the pixel returns fully shadowed. That's what we want for the night side without a separate code path.

Out of scope for M8 (noted in §13):
- Adaptive step size via DF (options C1/C2).
- Soft-shadow cone sampling.
- Multiple dynamic point lights.
- Runtime shadow-step quality toggle.

---

## 7. Lighting fragment

Composite formula from `docs/lighting.md` §5: lerp between an AO-darkened base color and a fully lit color using a `smoothstep` keyed on how bright the direct light contribution is. This keeps shadowed regions from going black and gives a smoother transition than `albedo * (ambient + diffuse) * ao`.

```glsl
void main() {
    vec4 g = texture(gbuffer, v_uv);
    if (g.a == 0.0) discard;

    int   material_id = int(g.a * 255.0 + 0.5);
    material_id       = clamp(material_id, 0, MATERIAL_COUNT - 1);
    vec3  normal      = octahedral_unpack(g.rg);
    float height      = g.b * MAX_WORLD_Y;
    vec3  w_start     = iso_inverse(v_uv, height);

    vec3  albedo = texelFetch(palette, ivec2(material_id, 0), 0).rgb;
    float ao     = texture(ao_tex, v_uv).r;

    // Sun/moon — one directional light with time-blended color + direction.
    vec3  l_dir  = sun_dir.xyz;
    vec3  l_col  = sun_color.rgb * sun_color.a;   // .a = intensity

    float n_dot_l = max(dot(normal, l_dir), 0.0);

    // Precompute shadow-march endpoints.
    vec3 w_end = w_start + l_dir * SHADOW_RANGE;
    vec2 s_end = iso_forward(w_end);
    float shadow = march_shadow(w_start, v_uv, w_end, s_end);

    vec3 light_contrib = l_col * n_dot_l * shadow;

    // Final composite (lighting.md §5).
    vec3  dark_color = albedo * (ambient_color.rgb * ambient_color.a) * ao;
    vec3  lit_color  = albedo * (light_contrib + ambient_color.rgb * ambient_color.a);
    float strength   = smoothstep(0.05, 0.6, dot(light_contrib, vec3(1.0 / 3.0)));

    out_color = vec4(mix(dark_color, lit_color, strength), 1.0);
}
```

Linear-space throughout; `present.frag` applies `pow(., 1/2.2)`.

---

## 8. SSAO pass

Implementation follows `docs/ssao.md` verbatim — 1:1 port of VQ's `aoShader.c` into GL 4.6 core / SPIR-V-compatible GLSL, with explicit binding layouts and a UBO in place of loose uniforms. Both tiers (`ao.frag` with `I_MAX = 8`, `ao_high.frag` with `I_MAX = 32`) compile from the same template with a preprocessor define.

Standalone pass (recommended in ssao.md §8) — writes R8 AO, read by `lighting.frag`. Toggle tier with `F4`.

---

## 9. Time-of-day

`src/game/time_of_day.c3`:

```c3
struct TimeOfDay {
    float     t;                // [0, 1); 0 = dawn east, 0.25 = noon, 0.5 = dusk west, 0.75 = night
    bool      auto_advance;     // starts true
    core::Seconds day_length;    // default 60s
    float     key_step;          // default 1.0 / 32.0 (~11° per tap)
}

fn void TimeOfDay.update(&self, core::Seconds dt) {
    if (!self.auto_advance) return;
    self.t += (float)(dt / self.day_length);
    self.t = math::fmod(self.t, 1.0f);
    if (self.t < 0.0f) self.t += 1.0f;
}

fn void TimeOfDay.step(&self, int dir)         // dir ∈ {-1, +1}, called on key press
fn void TimeOfDay.toggle_auto(&self)

fn core::Vec3 sun_direction_for(float t) @inline
fn core::Vec3 sun_color_for(float t)  @inline
```

### `sun_direction_for(t)`

Sun arcs in the world-XY plane (east→west, rising in Y at noon):

```
angle = t * 2π
dir   = normalize((cos(angle), sin(angle), 0))
```

`t = 0` → horizon east. `t = 0.25` → overhead. `t = 0.5` → horizon west. `t = 0.75` → moon overhead from beneath (`dir.y = -1`); see note in §6 for how the march handles this case — it returns fully shadowed, and the moonlight-blue `sun_color` in combination with the `dark_color` branch keeps night visible but dim.

### `sun_color_for(t)`

Matches `docs/lighting.md` §4: single directional light whose color shifts continuously through the day. Half-day = moon (dim blue), other half = sun (gold→white).

```
t in [0.00, 0.50)  (night → dawn): lerp(moon_night_blue, dawn_gold, t * 2)
t in [0.50, 1.00)  (morning → midday → dusk): lerp(dawn_gold, noon_white, (t - 0.5) * 2)
```

Stops:
- `moon_night_blue = (0.10, 0.12, 0.30) * 0.25` — dim cool fill so night isn't pitch black.
- `dawn_gold       = (1.00, 0.72, 0.40)` — at t=0.5 (horizon crossing).
- `noon_white      = (1.00, 0.98, 0.92)`.

Intensity is encoded in the `.a` of the `sun_color` uniform: night ≈ 0.15, day ≈ 1.0, lerp through dawn/dusk. The AO-darkened `dark_color` branch of the composite covers the "effectively shadowed" look when intensity is low.

No transcendentals per-frame — lerp between baked stops.

### Input

Handled in `main.c3` once per frame from `platform::input_poll` output:

- `[` → `time_of_day.step(-1)` and disable auto
- `]` → `time_of_day.step(+1)` and disable auto
- `P` → `time_of_day.toggle_auto()`
- `F4` → flip `lighting.ao_high_quality`

---

## 10. Edge cases

| Case | Handling |
|------|----------|
| Empty / air pixels | G-buffer `.a = 0`; lighting discards; present fills with constant sky color `vec3(0.10, 0.12, 0.16)`. |
| Page-boundary normals | Volume gradient central-difference clamps off-volume samples to the edge voxel (zero gradient contribution). Produces a mild flatten, never a discontinuity. |
| Shadow march leaves screen | Break out of loop; remainder of march is treated as unoccluded. |
| Sun below horizon | `march_shadow` returns 0; lighting falls back to `ambient_color`, which has a ~0.05 RGB floor so night isn't jet black. |
| Shadow self-acne | `step * 0.5` origin bias + `+0.5` height threshold. If artifacts remain on flat ground, `shadow_step` is tunable at the UBO level without a rebuild. |
| AO on near-horizontal surfaces | Known VQ limitation (ssao.md §6). Accept as-is. |
| Material_id overflow | Clamp with `min(material_id, MATERIAL_COUNT - 1)` defensively; shouldn't happen but costs nothing. |
| `time_of_day` wrap-around | `fmod` to `[0, 1)`; negative key step wraps to `0.99x` region. |

---

## 11. Testing

Unit-testable in C3 (add under `test/game/time_of_day_test.c3` and `test/core/iso_roundtrip_test.c3`):

- `sun_direction_for(t)` at `t ∈ {0, 0.25, 0.5, 0.75}` — east horizon, zenith, west horizon, below-horizon. Each ±1° of the documented direction.
- `sun_color_for(t)` monotonic brightness through noon, drops to black below horizon.
- `iso_forward ∘ iso_inverse` roundtrip for 100 random `(world_xyz_on_surface, t)` samples — should return within 0.01 world units. (Mirror the GLSL formulae in C3 and cross-check against `src/game/camera.c3::world_xz_to_screen`.)
- `octahedral_pack ∘ octahedral_unpack` roundtrip for 100 random unit vectors — angular error < 3°.

No automated GPU tests; shadow/AO correctness is a pattern-recognition judgement call, verified by the acceptance screenshots.

**Visual acceptance (manual, compare before/after screenshots):**

1. **Lit village, moving sun** — screenshot at `t = 0.2` and `t = 0.4`; shadow directions should differ.
2. **Building and tree shadows** — walls cast shadows on neighbouring ground; trees cast shadows on walls.
3. **AO at corners** — wall-ground corners noticeably darker than wall mid-heights.
4. **No page-boundary seams** — pan until a page boundary is centred on flat ground far from any building; no visible line.

---

## 12. Memory budget

Additions beyond today:

| Resource | Format | Count | Size |
|----------|--------|-------|------|
| Holder FBO: material | R8UI 512² | 128 | 32 MB |
| Holder FBO: normal | RG8 512² | 128 | 64 MB |
| Holder FBO: height (already exists as R16F) | — | 128 | unchanged |
| Holder FBO: color (RGBA8) — deleted | — | −128 | −128 MB |
| Volume ring: aux normal RG8 128³ | RG8 | 4 | 16 MB |
| Screen G-buffer | RGBA8 1080p | 1 | 8 MB |
| AO target | R8 1080p | 1 | 2 MB |
| Lit target | RGBA8 1080p | 1 | 8 MB |
| Palette LUT | RGBA8 17×1 | 1 | ≪ 1 KB |
| Net change | | | **~ +2 MB** |

Deleting the baked-color MRT from the holder FBO almost exactly offsets the new material+normal MRTs — the deferred pipeline is virtually free on VRAM.

---

## 13. Explicit follow-ups

Noted here so they don't get lost when the plan is written:

- **Adaptive shadow stepping** — option C1 (2D screen-space JFA on G-buffer height) or C2 (3D volume-DF traversal). C1 is the next polish step after M8; C2 waits on M9's bindless DF access. Both give cheaper long-range shadows.
- **Moon / second directional light** — M10 alongside radiosity and fog.
- **GTAO / HBAO upgrade** — M10 quality pass. VQ-style AO is MVP.
- **Radiosity** — M10, `shaders/radiosity.frag` as described in `docs/high-level-spec.md` §M10.
- **Proper tonemap** — M10 (ACES or Reinhard). M8 is gamma-only.
- **Sky model** — M10 with fog. M8 uses a constant sky color.
- **2D LUT palette (material × time_of_day)** — trivial follow-up; 17×16 texture, 1D-to-2D is a uniform-only change.
- **Hot-reload key for palette texture** — convenience, not acceptance.
