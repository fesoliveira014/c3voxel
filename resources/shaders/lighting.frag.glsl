#version 460

// M8 T6 + T8: deferred lighting pass with heightfield shadow march.
// Consumes the screen G-buffer built by deferred.frag.glsl:
//   g.r, g.g = octahedral-packed normal
//   g.b      = height / MAX_WORLD_Y
//   g.a      = material_id / 255 (0 == sky → discard)
//
// Output is linear-space RGBA8; present.frag applies gamma.

#include "common/octahedral.glsl"

layout(location = 0) in  vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(binding = 0) uniform sampler2D gbuffer;
layout(binding = 1) uniform sampler2D palette;     // 17×1 RGBA8
layout(binding = 2) uniform sampler2D ao_tex;      // R8 from ao.frag

layout(std140, binding = 32) uniform LightingU {
    vec4  sun_dir;            // .w unused
    vec4  sun_color;          // .a = intensity
    vec4  ambient_color;      // .a = intensity
    ivec4 resolution;         // { fb_w, fb_h, 0, 0 }
    vec4  pan_target;         // .xyz = pan_target world pos; .w = zoom scale
    float time_of_day;
    float shadow_step;        // reserved (fixed step count path)
    int   shadow_max_steps;
    int   ao_quality_high;
};

// iso.glsl consumes these macros; the UBO provides the values.
#define ISO_PAN_TARGET pan_target.xyz
#define ISO_ZOOM       pan_target.w
#define ISO_RESOLUTION vec2(resolution.xy)
#include "common/iso.glsl"

const int   MATERIAL_COUNT = 17;
const float MAX_WORLD_Y    = 128.0;
// 48 world units is a building-height-and-a-half of reach. Paired with
// shadow_max_steps=48 (see LightingUniforms wiring in main.c3) it gives
// one step ≈ one voxel along the sun ray, which is the scale needed to
// catch narrow occluders like wall-thickness slabs (WALL_RAD_M=2.0) and
// tree trunks. 64 @ 24 was ~2.7 world units per step — fine for broad
// terrain hills but skipped over anything slimmer than three voxels.
const float SHADOW_RANGE   = 48.0;

// Heightfield shadow march from the shaded pixel's world pos toward the
// sun. Both world and screen positions are interpolated in lockstep so the
// inner loop never projects; see docs/lighting.md §3 for the reference.
float march_shadow(vec3 w_start, vec2 s_start, vec3 w_end, vec2 s_end)
{
    float total_hits = 0.0;
    float total_rays = 0.0;
    int   n          = shadow_max_steps;
    for (int i = 1; i <= n; i++) {
        float f = float(i) / float(n);
        vec3  w_cur = mix(w_start, w_end, f);
        vec2  s_cur = mix(s_start, s_end, f);
        // Screen-space march falls off the visible G-buffer; anything
        // beyond this is treated as unoccluded.
        if (any(lessThan(s_cur, vec2(0.0))) || any(greaterThan(s_cur, vec2(1.0)))) break;

        vec4  samp   = texture(gbuffer, s_cur);
        float cur_h  = samp.b * MAX_WORLD_Y;
        int   mat_id = int(samp.a * 255.0 + 0.5);
        // Sky (material 0), water (12), and glass (14) pass light through —
        // they don't count as occluders AND they don't consume a ray.
        // Counting them as un-occluded rays at VQ did would dilute the ratio
        // toward zero over long marches, giving near-full-lit for every
        // pixel including those behind walls.
        float opaque  = float(mat_id != 0 && mat_id != 12 && mat_id != 14);
        // +1.0 world-unit bias avoids self-acne at march origin. VQ used
        // +2.0 at a `pixelsPerMeter` > 1 scale; our voxel == 1 world unit
        // so +1.0 is already comfortably above the packed-height step
        // (0.5 world units — RGBA8 `.b * 128`).
        float was_hit = float(cur_h > w_cur.y + 1.0);
        total_hits += was_hit * opaque;
        total_rays += opaque;
    }
    if (total_rays < 1.0) return 1.0;
    float shadow = 1.0 - clamp(total_hits / total_rays, 0.0, 1.0);
    // `smoothstep(0.2, 0.9, shadow)` sharpens the lit-vs-shadow boundary.
    // Before this, a 50% partial-occlusion pixel mapped to 50% lit — the
    // whole scene read as a smooth gradient with no clear "this is in
    // shadow" boundary. The S-curve pins heavily-occluded pixels (≤20%
    // lit rays) to full dark and lightly-occluded (≥90% lit rays) to
    // full light, with a short midrange penumbra. Matches the original
    // M8 drop's dramatic look without the `pow()` curve's harshness.
    return smoothstep(0.2, 0.9, shadow);
}

void main()
{
    vec4 g = texture(gbuffer, v_uv);
    if (g.a == 0.0) discard;                        // sky pixels → present fills

    int  material_id = int(g.a * 255.0 + 0.5);
    material_id      = clamp(material_id, 0, MATERIAL_COUNT - 1);
    vec3 normal      = octahedral_unpack(g.rg);
    float height     = g.b * MAX_WORLD_Y;

    vec3 albedo = texelFetch(palette, ivec2(material_id, 0), 0).rgb;

    // Reconstruct world position from UV + height, then march toward the
    // sun to accumulate occlusion from the G-buffer heightfield.
    vec3  w_start = iso_inverse(v_uv, height);
    vec3  w_end   = w_start + sun_dir.xyz * SHADOW_RANGE;
    vec2  s_end   = iso_forward(w_end);
    float shadow  = march_shadow(w_start, v_uv, w_end, s_end);

    float ao = texture(ao_tex, v_uv).r;

    float n_dot_l  = max(dot(normal, sun_dir.xyz), 0.0);
    vec3  sun_lit  = sun_color.rgb     * sun_color.a     * n_dot_l * shadow;
    vec3  ambient  = ambient_color.rgb * ambient_color.a;

    // AO: raw ratio from ao.frag, blended with a 0.25 floor so corners
    // darken to ~25% of full brightness (clearly visible occlusion)
    // without crushing the whole scene. Applied to BOTH ambient and
    // direct sun — the strict PBR "AO only on indirect" treatment made
    // the effect nearly invisible at noon (sun swamps ambient); this
    // reads as the SSAO term the spec actually wants.
    float ao_mod = 0.25 + 0.75 * ao;
    out_color = vec4(albedo * (ambient + sun_lit) * ao_mod, 1.0);
}
