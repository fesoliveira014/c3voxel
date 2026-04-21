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
// Range sized so building shadows cast their full geometric length
// across the ground at low sun angles. Buildings are ~28 world units
// tall; at 45° sun the shadow should reach ~28 units from the footprint
// edge. Our march rises 1:1 with its horizontal reach at that angle, so
// by the time the march got within reach of the building from a far
// pixel, w_cur.y already exceeded the roof height — no hit. 96 gives
// the march enough horizontal extent to still be below the roof when
// it crosses the building footprint. Paired with shadow_max_steps=64
// in main.c3 the per-step resolution stays at 1.5 world units,
// preserving narrow-occluder detection.
const float SHADOW_RANGE   = 96.0;

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
        // Sky (0), water (12), and glass (14) pass light through.
        float opaque  = float(mat_id != 0 && mat_id != 12 && mat_id != 14);
        // Tall-geometry materials — walls, roofs, trunks, brick, mortar,
        // earth. The heightfield test `cur_h > w_cur.y + 1` fails for
        // these: the G-buffer stores the iso ray's first-hit y, which for
        // a visible wall face is a surface *midway up* the wall (not the
        // column max), so march_y quickly exceeds it even when the full
        // column extends higher. Counting any sample whose material is
        // in this set as an occluder is a coarse column-max proxy that
        // produces visible wall and trunk shadows. Terrain materials
        // (DIRT/STONE/GRASS) fall through to the heightfield path.
        bool is_tall_mat = (mat_id == 6)   // MORTAR
                        || (mat_id == 7)   // WOOD (tree trunks, doors)
                        || (mat_id == 8)   // BRICK
                        || (mat_id == 9)   // SHINGLE (roofs)
                        || (mat_id == 10)  // PLASTER (walls)
                        || (mat_id == 15); // EARTH
        float hf_hit  = float(cur_h > w_cur.y + 1.0);
        float mat_hit = float(is_tall_mat);
        float was_hit = max(hf_hit, mat_hit);
        total_hits += was_hit * opaque;
        total_rays += opaque;
    }
    if (total_rays < 1.0) return 1.0;
    float shadow = 1.0 - clamp(total_hits / total_rays, 0.0, 1.0);
    // `pow(shadow, 8.0)` — amplified falloff so narrow occluders read.
    // Tree trunks (~2.5 voxels) only flip 2-3 samples of the 64-sample
    // march, landing shadow at 0.95-0.97 raw. Building walls (thin
    // slabs) similarly under-register. pow(·,4) left these at 80%+ lit;
    // pow(·,8) maps them into the 50-70% lit band where the darkening
    // is visible:
    //   shadow=0.98 → 0.85  (~15% dark)
    //   shadow=0.95 → 0.66  (~34% dark)
    //   shadow=0.90 → 0.43  (~57% dark)
    //   shadow=0.80 → 0.17  (~83% dark)
    return pow(shadow, 8.0);
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
