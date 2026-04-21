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
layout(binding = 3) uniform sampler2D col_top_tex; // R8 col_top / MAX_WORLD_Y

layout(std140, binding = 32) uniform LightingU {
    vec4  sun_dir;            // .w unused
    vec4  sun_color;          // .a = intensity
    vec4  ambient_color;      // .a = intensity
    ivec4 resolution;         // { fb_w, fb_h, 0, 0 }
    vec4  pan_target;         // .xyz = pan_target world pos; .w = zoom scale
    float time_of_day;
    int   debug_mode;         // 0 = normal, 1 = col_top grayscale
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
        int   mat_id = int(samp.a * 255.0 + 0.5);
        float opaque = float(mat_id != 0 && mat_id != 12 && mat_id != 14);
        // Column-top height at this screen pixel — highest opaque voxel
        // in the world column the view ray hits. Using first-hit height
        // (samp.b) here under-occludes wall faces because the face
        // entry-y rises at the same rate as the sun ray, keeping the
        // comparison perpetually a touch above w_cur.y.
        float cur_ct  = texture(col_top_tex, s_cur).r * MAX_WORLD_Y;
        float was_hit = float(cur_ct > w_cur.y + 0.25);
        total_hits += was_hit * opaque;
        total_rays += opaque;
    }
    if (total_rays < 1.0) return 1.0;
    float shadow = 1.0 - clamp(total_hits / total_rays, 0.0, 1.0);
    // Gentle sharpening. The earlier `smoothstep(0.2, 0.9, shadow)` had
    // a lower threshold above the algorithm's actual hit-rate range —
    // clearly-shadowed pixels top out around 25% occlusion (thin wall
    // slabs, short march windows inside occluders), giving shadow≈0.75
    // which smoothstep rounded back to fully lit. `pow(shadow, 3.0)`
    // keeps the same "dark when occluded, bright otherwise" S-curve
    // without demanding unreachable hit rates: shadow=0.83 → ~0.58
    // (40% dim), 0.5 → ~0.125 (near-full dark), 0.2 → 0.008 (black).
    return clamp(pow(shadow, 3.0), 0.0, 1.0);
}

void main()
{
    vec4 g = texture(gbuffer, v_uv);
    if (g.a == 0.0) discard;                        // sky pixels → present fills

    // Debug mode 1: render col_top (R8, scaled by MAX_WORLD_Y) as
    // grayscale. Lets us visually inspect whether col_top is correct
    // for building walls vs tree canopies vs terrain. A solid mid-gray
    // on every pixel of a building footprint means col_top ≈ roof_y
    // (working). Dark patches mean col_top ≈ first-hit y (scan broken
    // for those columns).
    if (debug_mode == 1) {
        float ct = texture(col_top_tex, v_uv).r;
        out_color = vec4(ct, ct, ct, 1.0);
        return;
    }

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
