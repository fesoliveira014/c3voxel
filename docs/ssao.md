# SSAO in VoxelQuest — Explained in C3/GLSL Terms

VoxelQuest's AO isn't the classical SSAO from Crytek [1] that most engines use. It's a screen-space **volume sampling** AO that exploits the fact that VQ's G-buffer stores world-space height, not view-space depth. The shader at `src/www/shaders/aoShader.c` (low-quality, 40 samples) and `aoHighShader.c` (high-quality, 160 samples) are nearly identical — just the outer sample count differs.

This document walks through what that shader actually does, why it's structured the way it is, and how to reimplement it in our C3/GLSL stack.

---

## 1. The Input: What's in the G-Buffer

VoxelQuest's `Texture0` (which the AO shader reads) packs four pieces of information per pixel:

- `.r, .g` — surface normal, encoded as xy with z reconstructed (sphere-map style)
- `.b` — height in world units, normalized by `MaxLayers` (encoded as `height / 255`)
- `.a` — material ID or alpha

Critically, `.b` is a **world-space Z coordinate**, not a view-space depth. This is what makes the AO approach work — we can directly compare heights between pixels without any projection-matrix gymnastics.

The raymarch pass wrote that `.b` channel as the top-of-surface Z in world units. So "the height at pixel (x, y)" is literally "what's the world-Z of the topmost voxel visible at that screen position."

---

## 2. The Core Idea

For each screen pixel:

1. Read its surface normal and height from the G-buffer.
2. Fire a small army of sample rays into the upper hemisphere above the surface (oriented by the normal).
3. For each sample, look up the G-buffer at the screen location the sample would project to, and check: **does the world contain something higher than the sample's world-Z at that position?**
4. Count hits. More hits = more occluded = darker.

It's the same fundamental algorithm as classical SSAO — sample the neighborhood, count occluders — with two differences:

- **Uses height channel, not depth.** Compares world-space heights rather than unprojecting depth buffers to view-space points.
- **Multi-radius weighted sampling.** Rather than sampling at one fixed radius, it samples at several (4, 8, 16, 32 units) and weights them by "how close" — closer-radius samples count more.

The multi-radius approach is what makes it work across different scales without tuning: small cracks darken from the near rays, larger ambient occlusion (under an archway, say) darkens from the far rays.

---

## 3. The Shader Line-by-Line

Here's the inner loop from `aoShader.c` with C3-style comments explaining what each piece does:

```glsl
// Step 1: Unpack surface normal from G-buffer
vec4 baseval = texture2D(u_Texture0, v_TexCoords);
vec3 offsetNorm;
offsetNorm.rg = (baseval.rg - 0.5) * 2.0;       // unpack [0,1] → [-1,1]
offsetNorm.b  = sqrt(1.0 - (norm.r² + norm.g²));  // reconstruct z
offsetNorm *= 2.0;                              // scale — see §4 below

// Step 2: Nested sample loop
// Outer j: radius tier (2, 3, 4, possibly more)
// Inner i: angular positions around a hemisphere
for (int j = 2; j < jMax; j++) {
    float fjt = pow(2.0, float(j));          // radius = 4, 8, 16, 32 units
    float hitPower = (jMax - fjt) / jMax;    // smaller radii weighted higher

    for (int i = 0; i < iMax; i++) {
        float fit = float(i) * pi / iMax;

        // Generate spherical coordinates
        float theta = fit / 2.0;     // inclination
        float phi   = 2.0 * fit;     // azimuth

        float rad = fjt * fit / pi;  // effective sample radius

        // Convert to Cartesian offset
        float fi = rad * cos(phi + fjt) * sin(theta);
        float fj = rad * sin(phi + fjt) * sin(theta);
        float fk = rad * cos(theta);

        // Step 3: Project sample into screen space
        // Note: fk (vertical) is added to the y-offset because this is iso —
        // moving up in world-Z moves up on screen.
        vec3 tc;
        tc.x = (fi + offsetNorm.x) / u_Resolution.x;
        tc.y = ((fj - offsetNorm.y) + (fk + offsetNorm.z)) / u_Resolution.y;

        // Step 4: Expected world-Z at that sample
        tc.z = clamp(baseval.b + (fk + offsetNorm.z) / 255.0, 0.0, u_MaxLayers);

        // Step 5: Sample the G-buffer at the offset position
        vec4 samp = texture2D(u_Texture0, v_TexCoords + tc.xy);

        // Step 6: Occlusion test
        // If the height at the sample location is LESS than our expected height,
        // then nothing is blocking — we're in open space above something.
        // If the world-height there is GREATER than our expected height, something
        // is blocking the sample point → occlusion.
        if (samp.b < tc.z) {
            totHits += hitPower;
        }
        totRays += hitPower;
    }
}

// Step 7: Final AO value with sharp falloff
float resVal = clamp(totHits / totRays, 0.0, 1.0);
resVal = pow(resVal, 6.0);  // sharpen contrast — low AO stays bright, high AO gets dark fast

gl_FragColor = vec4(baseval.rgb, resVal);
```

The one thing that reads as surprising on first encounter: `if (samp.b < tc.z) totHits++;` The logic is "this sample point is **unoccluded** if the world's height at that location is below where we're sampling." So the count accumulates unoccluded samples. Then `totHits / totRays` gives the unoccluded fraction, but — wait, it's then used directly as the AO darkening value. Reading more carefully, the meaning is inverted: `pow(resVal, 6.0)` is applied, then the value is stored as `.a` which the downstream lighting shader treats as "amount of sky visibility." So more unoccluded samples = more sky = less darkening. The naming in the shader is confusingly backwards from the final meaning.

---

## 4. The Two Quality Tiers

The difference between `aoShader.c` and `aoHighShader.c` is a single constant:

| Tier | `iMax` (angular samples) | `jMax` (radii) | Total samples |
|------|--------------------------|----------------|---------------|
| Low  | 8                        | 5              | 3 × 8 = 24    |
| High | 32                       | 5              | 3 × 32 = 96   |

(The outer loop starts at `j = 2`, so 3 radii are actually evaluated, not 5.)

24 samples is clearly acceptable visual quality for the low tier; 96 is for screenshots and demo mode. Cost scales linearly with sample count, and the per-sample cost is dominated by the `texture2D` lookup, which is a cache-friendly access into the G-buffer texture that's already bound.

---

## 5. What This Approach Gets Right

Three properties that make it a good fit for VQ specifically:

**Works with the existing G-buffer.** No new depth buffer, no view-space position reconstruction, no normal buffer — it all comes from one `Texture0` read per sample. This is unusually cheap compared to traditional SSAO which needs normal, depth, and often a random-rotation texture.

**Isometric-aware.** The screen-space sample offsets already account for the fact that vertical world-Z manifests as vertical screen movement. A view-space SSAO would need to reconstruct a view matrix; this one just uses the iso projection's built-in linearity.

**Multi-scale via nested loops.** Classical SSAO uses a single radius (tunable) and produces either tight dark creases OR broad soft occlusion but not both. The multi-radius weighted approach here gets both, for free, with cost proportional to the number of radii.

---

## 6. What It Gets Wrong

Being honest about the weaknesses:

**Self-occlusion artifacts** — because the height comparison doesn't account for the surface normal beyond orienting the sample hemisphere, nearly-horizontal surfaces report high AO even in open space. You can see this in VQ on the tops of tall buildings if you look carefully.

**No random rotation / dithering** — classical SSAO jitters sample directions per-pixel to break up the geometric sampling pattern and then blurs the result. VQ doesn't. The pattern can be visible as faint circular or radial banding on large flat surfaces under certain camera angles.

**Samples in screen space, not world space** — means zoom level affects AO strength. Zoomed far in, the 32-unit radius covers more pixels, producing more AO. Zoomed far out, the same 32-unit radius covers fewer pixels. The shader compensates by using a fixed Z step (`fk / 255.0`) but the XY sampling still inherits resolution dependence.

**The spherical coordinate formulas are weird** — look at `theta = fit / 2.0; phi = 2.0 * fit`. Both are driven by the same index `i`, which means samples don't cover the hemisphere uniformly — they spiral around it. This gives interesting but uneven coverage. A uniformly-distributed Hammersley or Halton sequence would be better.

The `offsetNorm *= 2.0` line is also unexplained in the code — it scales the normal before it's used as a sample-origin offset. Probably tuned by eye to get the visual result the author wanted; not a principled constant.

---

## 7. Implementation in Our Stack

A faithful C3/GLSL port would look like this:

### `render::ao` module

```c3
module vq::render::ao;
import vq::gpu;

struct AoContext {
    gpu::Shader shader_low;
    gpu::Shader shader_high;
    gpu::Buffer uniforms_ubo;
}

struct AoUniforms @align(16) {
    float[2] resolution;   // output width, height
    float    max_layers;   // world Z ceiling (normalization factor)
    float    time;         // unused in AO, kept for future dithering
}

fn void AoContext.init(&self) {
    self.shader_low  = gpu::shader_load_frag("shaders/ao.frag")!!;
    self.shader_high = gpu::shader_load_frag("shaders/ao_high.frag")!!;
    self.uniforms_ubo = gpu::buffer_create_ubo($sizeof(AoUniforms));
}

fn void AoContext.dispatch(
    &self,
    gpu::Commands* cmd,
    gpu::Texture2D gbuffer,        // RGBA8: xy=normal, z=height, w=material
    gpu::Framebuffer* target,      // writes ao into .a of color0
    bool high_quality
) {
    AoUniforms u = {
        .resolution = { (float)target.width, (float)target.height },
        .max_layers = 64.0,  // tuneable; matches MaxLayers in VQ
        .time = 0.0,
    };
    self.uniforms_ubo.upload(&u, $sizeof(AoUniforms));

    cmd.bind_framebuffer(target);
    cmd.bind_shader(high_quality ? self.shader_high : self.shader_low);
    cmd.bind_texture(0, gbuffer);
    cmd.bind_ubo(1, self.uniforms_ubo, 0, $sizeof(AoUniforms));
    cmd.draw_fullscreen_quad();
    cmd.barrier(gpu::FRAMEBUFFER);
}
```

### `shaders/ao.frag`

The port to GL 4.6 core / SPIR-V-compatible GLSL:

```glsl
#version 460

layout(binding = 0) uniform sampler2D gbuffer;

layout(std140, binding = 1) uniform U {
    vec2  resolution;
    float max_layers;
    float time;
};

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

const int   I_MAX = 8;   // angular samples (32 for high)
const int   J_MAX = 5;   // radius tiers (loop runs j = 2..J_MAX-1)
const float PI    = 3.14159265;

void main() {
    vec4 base = texture(gbuffer, v_uv);

    // Unpack surface normal
    vec3 n;
    n.xy = (base.rg - 0.5) * 2.0;
    n.z  = sqrt(max(1.0 - dot(n.xy, n.xy), 0.0));
    n   *= 2.0;

    float tot_hits = 0.0;
    float tot_rays = 0.0;

    for (int j = 2; j < J_MAX; j++) {
        float r_tier    = exp2(float(j));              // 4, 8, 16, 32
        float hit_power = (float(J_MAX) - r_tier) / float(J_MAX);

        for (int i = 0; i < I_MAX; i++) {
            float fi = float(i) * PI / float(I_MAX);

            float theta = fi * 0.5;
            float phi   = fi * 2.0;
            float rad   = r_tier * fi / PI;

            float dx = rad * cos(phi + r_tier) * sin(theta);
            float dy = rad * sin(phi + r_tier) * sin(theta);
            float dz = rad * cos(theta);

            vec2  tc_xy = vec2(dx + n.x, (dy - n.y) + (dz + n.z)) / resolution;
            float tc_z  = clamp(base.b + (dz + n.z) / 255.0, 0.0, max_layers);

            vec4 samp = texture(gbuffer, v_uv + tc_xy);
            if (samp.b < tc_z) tot_hits += hit_power;
            tot_rays += hit_power;
        }
    }

    float ao = clamp(tot_hits / tot_rays, 0.0, 1.0);
    ao = pow(ao, 6.0);

    // Preserve everything else, write AO into alpha
    out_color = vec4(base.rgb, ao);
}
```

Nearly line-for-line translation from VQ's GLSL 1.20 to GLSL 4.60 core. The only meaningful change is the explicit binding layouts and the UBO instead of loose uniforms. (These are required by our shader conventions for future Vulkan compatibility — see the architecture doc §6.3 on shader rules.)

---

## 8. Where the AO Pass Sits in Our Frame Graph

Per the architecture:

```
PASS 4: Build worldspace G-buffer (writes: normal, height, material)
PASS 5: Lighting (reads G-buffer; input to radiosity)
PASS 6: Radiosity
PASS 7: Fog
```

AO can be computed either:

- **As a standalone pass between 4 and 5**, writing to a dedicated R8 AO texture that the lighting shader samples.
- **Inside the lighting pass itself**, with the AO loop inlined into `lighting.frag`. Cheaper (avoids a round-trip through a texture) but less amenable to hot-reload tuning.

I'd recommend the standalone pass for the first implementation — makes it easier to A/B compare AO variants (VQ-style vs GTAO vs HBAO) later without touching the lighting pass. The cost is one extra framebuffer read per pixel during lighting, which on modern GPUs is effectively free.

```c3
// render::frame::render_frame
render::ao::dispatch(cmd, &fc.res.ao_ctx, gbuffer, &fc.ao_target, high_quality);
render::lighting::dispatch(cmd, fc, gbuffer, &fc.ao_target, &fc.result_target);
```

---

## 9. If We Want To Do Better

The VQ approach is fine. It's simple, fast, and looks good enough. But if we want modernization:

- **GTAO** (Ground-Truth Ambient Occlusion, Jiménez 2016 [2]) is the state of the art as of the mid-2010s. Physically motivated, gives temporally stable results, single pass with denoise. Would work well with our G-buffer.
- **HBAO+** is cheaper than GTAO with slightly worse quality. Frequently used in games.
- **XeGTAO** (Intel, 2022) is an open-source reference implementation that drops right into any engine with a normal+depth G-buffer [3].

The VQ approach's key asset — that it works off world-height rather than view-depth — is worth preserving in any replacement. Height-based AO has specific advantages for voxel/iso scenes that view-space approaches don't replicate. A hybrid (GTAO machinery, but comparing heights instead of depths) would probably be the best-of-both-worlds.

**For MVP: port VQ's shader verbatim.** It's small, well-scoped, and produces recognizable output.
**For polish: evaluate GTAO.** Budget one week if it becomes the bottleneck for visual quality.

---

## 10. References

1. **Mittring, M. (2007).** "Finding Next Gen: CryEngine 2." *SIGGRAPH Course Notes.* The original SSAO paper from Crytek, used in Crysis. <https://www.mittring.com/SIGGRAPH2007.pdf>.
2. **Jiménez, J., Wu, X.-C., Pesce, A., and Jarabo, A. (2016).** "Practical Realtime Strategies for Accurate Indirect Occlusion." *SIGGRAPH Course Notes.* Introduces GTAO. <https://www.activision.com/cdn/research/Practical_Real_Time_Strategies_for_Accurate_Indirect_Occlusion_NEW%20VERSION_COLOR.pdf>.
3. **Intel XeGTAO reference implementation.** <https://github.com/GameTechDev/XeGTAO>. Well-commented reference code, permissively licensed.
4. **VoxelQuest source**: `src/www/shaders/aoShader.c` (low), `aoHighShader.c` (high).