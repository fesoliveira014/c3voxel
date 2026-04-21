# Lighting and Shadows in VoxelQuest — Explained in C3/GLSL Terms

The lighting pipeline lives in `src/glsl/PreLightingShader.c` (and a companion `LightingShader` that applies the results in a later pass). It runs after the G-buffer is built and the AO pass has computed occlusion. Like the AO, the lighting is screen-space and exploits the world-position G-buffer channel rather than doing any world-to-view math.

The structure is what matters: a fixed **day/night driven sun/moon**, up to 16 **dynamic point lights**, per-light **screen-space ray-marched shadows**, and a final composite that mixes light colour, shadow strength, light "flooding" (how much color leaks into shadow), and AO. No shadow maps, no cascades, no PCF. Just ray marches against the G-buffer height channel.

---

## 1. Inputs: What the Shader Reads

The lighting pass consumes five textures, all of which are at screen resolution:

| Texture | Contents |
|---------|----------|
| `Texture0` | Normal (rg) + Height (b) + Material ID (a). Same as AO input. |
| `Texture1` | Base color from palette lookup, pre-lit. |
| `Texture3` | **World-space position** (xyz) — this is the critical one for shadow marching. |
| `Texture4` (and beyond) | Reserved for AO output, radiosity, etc. |
| `lightArr` uniform array | Per-light parameters, packed as 4 `vec4`s per light. |

`Texture3` is what makes the shadow algorithm straightforward. Every G-buffer pixel knows its exact world-XYZ, so marching from pixel to light source in world coordinates is a direct linear interpolation.

---

## 2. The Light Data Layout

On the CPU, VoxelQuest packs each light into 14 consecutive floats (`FLOATS_PER_LIGHT = 14`). Three `vec4`s on the GPU side (`VECS_PER_LIGHT = 4`), indexed as:

```glsl
// Packed as 4 vec4s per light in lightArr[], indexed by baseInd = k * 4:
lightArr[baseInd + 0] = (world_x, world_y, world_z, radius)  // lightPosWS
lightArr[baseInd + 1] = (screen_x, screen_y, _, _)           // lightPosSS
lightArr[baseInd + 2] = (color_r, color_g, color_b, intensity)
lightArr[baseInd + 3] = (colorization, flooding, _, _)
```

Key properties:

- **Light 0 is special.** It's the sun/moon and always present. Its radius is absurdly large (`4096 * pixelsPerMeter`), effectively infinite, and its color is overridden per-frame based on `timeOfDay`.
- **Lights 1+ are dynamic point lights.** Radius ~16 meters. Position and color set per-frame by game code.
- **Both world-space and screen-space positions are precomputed.** Lets the shader trace either in world (for distance tests) or screen (for G-buffer sampling) without any projection math.
- **`colorization`** controls how much this light's hue bleeds into shadowed areas (lanterns give a warm wash; the sun does not).
- **`flooding`** controls how much the light affects geometry regardless of shadow (same concept — lanterns flood the nearby space with color even when the direct ray is blocked).

---

## 3. The Shadow Ray March

This is the heart of the system. For each light, for each pixel, march from the pixel's world position toward the light, sampling the G-buffer along the way:

```glsl
// wStartPos, sStartPos: world+screen position of this pixel
// wEndPos, sEndPos:     world+screen position of the light
// Both computed once before the inner loop.

totHits = 0.0;
hitCount = 0.0;

for (i = 0; i < iNumSteps; i++) {
    float flerp = float(i) / fNumSteps;

    vec3 wCurPos = mix(wStartPos, wEndPos, flerp);  // world-space interpolate
    vec2 sCurPos = mix(sStartPos, sEndPos, flerp);  // screen-space interpolate

    // Sample the G-buffer's height channel at this screen position
    float curHeight = texture2D(Texture3, sCurPos).z;

    // Sample material ID to filter out water/glass
    vec4 samp = texture2D(Texture0, sCurPos);

    // Occlusion test: does world have something TALLER than the ray at this point?
    float wasHit = float(curHeight > wCurPos.z + 2.0);  // +2.0 is a bias

    // Water and glass don't cast shadows
    float waterMod = float(
        ((samp.a < TEX_WATER) || (samp.a > TEX_GLASS))
        && (!isGeom(samp.a))
    );

    totHits  += wasHit * waterMod;
    hitCount += waterMod;
}

float resComp = mix(1.0, 0.0, clamp(totHits / hitCount, 0.0, 1.0));
resComp = clamp(pow(resComp, 2.0), 0.0, 1.0);
```

The algorithm:

1. Walk from pixel to light along a straight line, both in world and screen space simultaneously.
2. At each step, query **the world-Z of whatever is visible at that screen position** (from G-buffer height).
3. If that Z is greater than the ray's current Z, **something is blocking the ray** (taller terrain, a building, etc.).
4. Count hits. Apply `pow(resComp, 2.0)` to make light-to-shadow transitions crisper.
5. Water and glass materials are explicitly excluded — they let light through.

Because `wCurPos` and `sCurPos` are updated in lockstep, the algorithm never needs to compute screen-space from world-space (or vice versa) during the march. Both are just `mix()` calls from pre-known endpoints. This is the same trick that lets the AO shader work without a projection matrix.

### Why `iNumSteps`?

A constant defining the shadow march resolution. Typical values: 16, 32, 64. Higher is smoother shadows but proportionally more expensive. VQ exposes this via the `[` and `]` keys for runtime tuning:

> `[ and ]: decrease/increase detail (shadow steps, AO steps, radiosity steps)`

So users can tune it per their hardware. In our port this becomes a per-quality-setting uniform rather than a keybind.

### Why `wCurPos.z + 2.0`?

The `+2.0` is a bias. Without it, a pixel would immediately self-occlude because at `flerp=0`, `wCurPos.z == baseHeight == curHeight` (we're at the surface we're shading). The bias is equivalent to a shadow map's depth bias — it pushes the ray a couple units above the surface so self-shadowing doesn't happen. Too small and you get acne; too large and you get Peter Panning. 2.0 pixels is tuned for VQ's scale.

---

## 4. The Day/Night Cycle

The sun/moon is really just light index 0 with time-varying parameters:

```glsl
vec3 getGlobLightCol() {
    vec3 glCol = vec3(0.0);
    float timeLerp;

    if (timeOfDay < 0.5) {        // moon phase
        timeLerp = timeOfDay * 2.0;
        glCol = mix(
            vec3(lightColRNight, lightColGNight, lightColBNight),  // deep blue
            vec3(1.0, 0.8, 0.7),                                   // dawn gold
            timeLerp
        );
    } else {                      // sun phase
        timeLerp = (timeOfDay - 0.5) * 2.0;
        glCol = mix(
            vec3(1.0, 0.8, 0.7),  // morning gold
            vec3(1.0),            // midday white
            timeLerp
        );
    }
    return glCol;
}
```

Three color stops: midnight blue → dawn/dusk gold → midday white, with linear interpolation between. The same curve drives fog color (see `getFogColor`).

Other per-light parameters scale similarly:

```glsl
if (k == 0) {   // global (sun/moon) light
    curLightColor    = globDayColor;
    lightIntensity   = mix(lightIntensityNight,   1.0, timeOfDay);
    lightColorization= mix(lightColorizationNight,0.0, timeOfDay);
    lightFlooding    = mix(lightFloodingNight,    0.0, timeOfDay);
}
```

Night has reduced intensity, slight cold colorization (shadows appear slightly blue-tinted), and some flooding (ambient bleed regardless of shadow). Day has full intensity, no colorization, no flooding — daytime shadows are crisper and more directional.

The `@lightIntensityNight@` etc. are template placeholders from VQ's custom shader preprocessor — at compile time they get substituted with numeric constants. In our port, these become regular `uniform` values passed from CPU, giving us a runtime-tunable knob without recompiling the shader.

---

## 5. Putting It All Together

The full lighting composition per-pixel:

```glsl
for (int k = 0; k < lightCount; k++) {
    int baseInd = k * VECS_PER_LIGHT;
    vec4 lightPosWS = lightArr[baseInd + 0];

    // Distance culling — far lights don't contribute
    if (distance(worldPosition, lightPosWS.xyz) > lightPosWS.w) continue;

    // ... unpack light parameters ...

    // Shadow ray march (as in §3) → resComp ∈ [0,1], 0=shadowed 1=lit
    // Diffuse term
    float frontLight = clamp(dot(myVec, lightVec), 0.0, 1.0);

    // Distance falloff
    float lightDis = 1.0 - clamp(
        distance(worldPosition, lightPosWS.xyz) / lightPosWS.w, 0.0, 1.0);

    // Accumulate
    totLightColor     += curLightColor * frontLight * resComp * lightIntensity;
    totLightDis       += lightDis;
    totColorization   += lightColorization * resComp;
    totLightIntensity += lightIntensity;
    // ... flooding contribution, etc ...
}

// Final composite mixes base color, accumulated light, AO, and colorization
resColor = mix(
    baseColor * newAO,                                     // unlit, AO-darkened
    clamp(totLightColor, 0.0, 1.0) * lightRes,             // fully lit
    smoothstep(threshold, 1.0, dot(totLightColor, 1/3))
);
```

(The actual composite is more elaborate; I've simplified here to show the shape.)

The interesting structural choice: **light contributions accumulate linearly**, then the final mix between "dark" and "lit" versions of the pixel uses a `smoothstep` based on how bright the accumulated light is. This means shadowed areas don't go fully black — they retain the base color modulated by AO — while fully-lit areas get the saturated colored lighting.

---

## 6. Implementation in Our Stack

### `render::lighting` module

```c3
module vq::render::lighting;
import vq::gpu;

const int MAX_LIGHTS = 16;
const int SHADOW_STEPS_DEFAULT = 32;

struct Light @align(16) {
    float[4] pos_ws;        // world xyz, radius in w
    float[4] pos_ss;        // screen xy (z, w unused)
    float[4] color;         // rgb + intensity in w
    float[4] params;        // colorization in x, flooding in y
}

struct LightingUniforms @align(16) {
    float[4] camera_pos;
    float    time_of_day;       // 0..1
    int      light_count;
    int      shadow_steps;
    float    pixels_per_meter;

    float[4] sun_color_night;   // replaces @lightColRNight@ etc.
    float    sun_intensity_night;
    float    sun_colorization_night;
    float    sun_flooding_night;
    float    _pad;
}

struct LightingContext {
    gpu::Shader shader;
    gpu::Buffer lights_ubo;     // std140, MAX_LIGHTS * $sizeof(Light)
    gpu::Buffer uniforms_ubo;
}

fn void LightingContext.dispatch(
    &self,
    gpu::Commands* cmd,
    gpu::Texture2D gbuffer_normal_height_mat,  // from raymarch MRT
    gpu::Texture2D gbuffer_color,              // from palette pass
    gpu::Texture2D gbuffer_worldpos,           // from raymarch MRT
    gpu::Texture2D ao_texture,                 // from ao pass
    gpu::Framebuffer* target,
    Light[] lights,
    LightingUniforms* u
) {
    // Upload light array (up to MAX_LIGHTS)
    usz count = min(lights.len, MAX_LIGHTS);
    self.lights_ubo.upload_slice_range(lights[:count]);
    self.uniforms_ubo.upload(u, $sizeof(LightingUniforms));

    cmd.bind_framebuffer(target);
    cmd.bind_shader(self.shader);
    cmd.bind_texture(0, gbuffer_normal_height_mat);
    cmd.bind_texture(1, gbuffer_color);
    cmd.bind_texture(2, ao_texture);
    cmd.bind_texture(3, gbuffer_worldpos);
    cmd.bind_ubo(4, self.uniforms_ubo, 0, $sizeof(LightingUniforms));
    cmd.bind_ubo(5, self.lights_ubo, 0, MAX_LIGHTS * $sizeof(Light));
    cmd.draw_fullscreen_quad();
    cmd.barrier(gpu::FRAMEBUFFER);
}
```

### `shaders/lighting.frag`

```glsl
#version 460

layout(binding = 0) uniform sampler2D gb_normal_height_mat;  // rg=normal, b=height, a=matID
layout(binding = 1) uniform sampler2D gb_color;              // pre-lit base color
layout(binding = 2) uniform sampler2D ao_tex;                // AO in .a
layout(binding = 3) uniform sampler2D gb_worldpos;           // xyz=world pos

struct Light {
    vec4 pos_ws;
    vec4 pos_ss;
    vec4 color;
    vec4 params;
};

layout(std140, binding = 4) uniform U {
    vec4  camera_pos;
    float time_of_day;
    int   light_count;
    int   shadow_steps;
    float pixels_per_meter;

    vec4  sun_color_night;
    float sun_intensity_night;
    float sun_colorization_night;
    float sun_flooding_night;
    float _pad;
};

layout(std140, binding = 5) uniform L {
    Light lights[16];
};

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

const float TEX_WATER = 32.0;
const float TEX_GLASS = 35.0;

vec3 sun_color(float t) {
    if (t < 0.5) {
        return mix(sun_color_night.rgb, vec3(1.0, 0.8, 0.7), t * 2.0);
    }
    return mix(vec3(1.0, 0.8, 0.7), vec3(1.0), (t - 0.5) * 2.0);
}

float shadow_march(vec3 w_start, vec2 s_start, vec3 w_end, vec2 s_end) {
    float total_hits  = 0.0;
    float hit_count   = 0.0;
    int   num_steps   = shadow_steps;

    for (int i = 0; i < num_steps; i++) {
        float flerp = float(i) / float(num_steps);
        vec3 w_cur = mix(w_start, w_end, flerp);
        vec2 s_cur = mix(s_start, s_end, flerp);

        float cur_height = texture(gb_worldpos, s_cur).z;
        vec4  samp       = texture(gb_normal_height_mat, s_cur);

        float was_hit   = float(cur_height > w_cur.z + 2.0);
        float water_mod = float(
            (samp.a < TEX_WATER || samp.a > TEX_GLASS)
        );
        total_hits += was_hit * water_mod;
        hit_count  += water_mod;
    }

    float shadow = mix(1.0, 0.0, clamp(total_hits / max(hit_count, 1.0), 0.0, 1.0));
    return clamp(pow(shadow, 2.0), 0.0, 1.0);
}

void main() {
    vec4 gbuf = texture(gb_normal_height_mat, v_uv);
    vec4 base = texture(gb_color, v_uv);
    vec4 wpos = texture(gb_worldpos, v_uv);
    float ao  = texture(ao_tex, v_uv).a;

    // Reconstruct normal
    vec3 n;
    n.xy = (gbuf.rg - 0.5) * 2.0;
    n.z  = sqrt(max(1.0 - dot(n.xy, n.xy), 0.0));

    vec3 light_accum = vec3(0.0);

    for (int k = 0; k < light_count; k++) {
        Light L = lights[k];

        // Radius cull
        if (distance(wpos.xyz, L.pos_ws.xyz) > L.pos_ws.w) continue;

        // Per-light color (sun is special)
        vec3 lcol = L.color.rgb;
        float intensity = L.color.w;
        if (k == 0) {
            lcol = sun_color(time_of_day);
            intensity = mix(sun_intensity_night, 1.0, time_of_day);
        }

        vec3 light_vec  = normalize(L.pos_ws.xyz - wpos.xyz);
        float front     = clamp(dot(n, light_vec), 0.0, 1.0);

        float shadow = shadow_march(
            wpos.xyz, v_uv,
            L.pos_ws.xyz, L.pos_ss.xy
        );

        float atten = 1.0 - clamp(
            distance(wpos.xyz, L.pos_ws.xyz) / L.pos_ws.w, 0.0, 1.0
        );

        light_accum += lcol * front * shadow * atten * intensity;
    }

    // Final composite: lerp between AO-darkened base and fully-lit color
    vec3 lit_color   = base.rgb * clamp(light_accum, 0.0, 1.0);
    vec3 dark_color  = base.rgb * ao;
    float light_strength = clamp(dot(light_accum, vec3(1.0/3.0)), 0.0, 1.0);

    out_color = vec4(mix(dark_color, lit_color, light_strength), base.a);
}
```

I've dropped some of VQ's more baroque features in this first-pass port — the `colorization`, `flooding`, and HSV manipulation stages. Those add about 30 LOC and can be layered back on after the basic shadow+falloff+AO pipeline is verified to work correctly. The key structural elements (per-light radius cull, screen-space shadow ray march, day/night sun color, AO composite) are all here.

---

## 7. Where This Pass Sits in Our Frame Graph

```
PASS 4: Build worldspace G-buffer (writes: normal, height, material, worldpos)
PASS 5: AO                         (reads: G-buffer → AO texture)
PASS 6: Lighting                   (reads: G-buffer + AO + light array → lit color)
PASS 7: Radiosity                  (reads: lit color → bounce accumulation)
PASS 8: Fog                        (reads: lit color + worldpos → fogged color)
```

The AO pass must come before lighting, since lighting uses the AO value in its composite. Radiosity and fog come after lighting and read its output.

The light array is uploaded once per frame at the start of pass 6; for VQ's 16-light maximum, that's 16 × 64 bytes = 1 KB of UBO data. Trivial bandwidth.

---

## 8. What This Approach Gets Right

**No shadow maps.** The single biggest simplification. Shadow maps require separate render passes per light, per shadow-cascade, each with its own framebuffer, depth comparison, bias tuning, and filtering strategy. Screen-space shadow ray marching against the G-buffer height channel is one loop per light, one framebuffer, zero aux data.

**Dynamic lights are free architecturally.** Adding a lantern or a fireball doesn't require spawning shadow-caster infrastructure — just push a new entry into the light array. 16 is the current cap but it's essentially arbitrary; the cost is linear in light count.

**Works with the G-buffer we already have.** No new buffers, no redundant data — reuses the world-position and height channels that the raymarch pass wrote anyway.

**Day/night is a single scalar.** `timeOfDay ∈ [0, 1]` drives everything (sun color, sun position, ambient intensity, fog color, colorization amounts). Makes it easy to expose as a single slider to the player or the game state.

---

## 9. What This Approach Gets Wrong

**Screen-space shadow rays miss off-screen occluders.** If a building just outside the current view would cast a shadow into the visible area, VQ can't represent that — the ray march sampling the G-buffer finds no occluder because the building isn't in the G-buffer at all. Visible as shadows that "disappear" when you pan the camera.

**Shadow resolution matches screen resolution.** A shadow cast across a large distance gets sampled at G-buffer sparsity, which means long shadows can look coarse. 64 march steps from camera-near to camera-far covers many world-units per step.

**No penumbra.** Shadow edges are effectively hard. The `pow(resComp, 2.0)` introduces a slight softening but not true soft-shadow falloff. Compare PCSS or variance shadow maps which give physically-plausible soft edges.

**Shadow ray marching scales O(lights × pixels × steps).** At 16 lights, 1080p, and 32 shadow steps, that's ~1 billion G-buffer texture reads per frame for shadows alone. Cacheable but not cheap. Point-light radius culling helps — most pixels only interact with 1-2 lights plus the sun — but the worst case is brutal.

**The `+2.0` shadow bias is world-scale-dependent.** If we change `pixelsPerMeter`, that bias needs to change or shadows break. Better to express it as a function of the world-scale, e.g. `0.05 * pixels_per_meter`.

---

## 10. If We Want To Do Better

Like with AO, the VQ approach is fine for a first implementation. Possible improvements in rough priority order:

- **Shadow caching.** Many pixels in a frame take the same shadow path (adjacent pixels march through similar G-buffer regions). A spatiotemporally-blurred shadow buffer, computed once per light at reduced resolution and upsampled, would reduce the march count significantly.
- **Signed distance field shadows.** If the scene's voxel volume is available (it is — see the volume ring), we can march in world-space against the 3D SDF instead of the 2D G-buffer. Captures off-screen occluders, handles penumbra well (distance field gives softness for free). Substantially better quality at similar cost. Would require keeping the DF ring alive longer than we currently do.
- **Ray-traced shadows.** On RTX hardware, `rayQueryEXT` against a BLAS of the voxel world gives ground-truth shadows with arbitrary softness via stochastic sampling. Overkill for MVP but trivial to add later if we're already on Vulkan.
- **Cascaded shadow maps for the sun.** Traditional but effective; handles off-screen occluders natively for directional lights. The sun is special (parallel rays, infinite distance), so it's the one light that would benefit most from a dedicated shadow map. Mixed with screen-space shadows for dynamic lights, this is a common hybrid in modern engines.

**For MVP: port VQ's shader verbatim.** The single-pass shadow march is small, self-contained, and produces recognizable output.

**For polish: evaluate SDF shadows first.** They'd integrate well with our existing DF acceleration structure and would fix the biggest visual weakness (screen-space off-screen miss). Budget 1-2 weeks if it becomes a bottleneck.

---

## 11. References

1. **Ritschel, T., Grosch, T., Seidel, H.-P. (2009).** "Approximating Dynamic Global Illumination in Image Space." *I3D 2009.* Foundational paper for screen-space lighting techniques including shadow ray marching. <https://people.mpi-inf.mpg.de/~ritschel/Papers/SSDO.pdf>.
2. **Fernando, R., ed. (2004).** *GPU Gems 2*, Chapter 17: "Efficient Soft-Edged Shadows Using Pixel Shader Branching." Background on shadow-softening techniques, relevant if we want to move beyond hard edges.
3. **Ørntoft, M. (2013).** "Screen Space Shadows." Blog post with technical details on the general approach VQ uses. Useful supplementary reading.
4. **VoxelQuest source**: `src/glsl/PreLightingShader.c` (shadow march + light accumulation), `src/cpp/f00380_gameworld.hpp` (lightArr packing, lines ~520 onward), `src/glsl/LightingShader.c` (final composite, if present in your source tree).
