#version 460

// M8 T6: deferred lighting pass (no shadow march, no AO — those land in
// T8/T9). Consumes the screen G-buffer built by deferred.frag.glsl:
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

layout(std140, binding = 32) uniform LightingU {
    vec4  sun_dir;            // .w unused
    vec4  sun_color;          // .a = intensity
    vec4  ambient_color;      // .a = intensity
    ivec4 resolution;         // { fb_w, fb_h, 0, 0 }
    float time_of_day;
    float shadow_step;
    int   shadow_max_steps;
    int   ao_quality_high;
};

const int MATERIAL_COUNT = 17;

void main()
{
    vec4 g = texture(gbuffer, v_uv);
    if (g.a == 0.0) discard;                        // sky pixels → present fills

    int  material_id = int(g.a * 255.0 + 0.5);
    material_id      = clamp(material_id, 0, MATERIAL_COUNT - 1);
    vec3 normal      = octahedral_unpack(g.rg);

    vec3 albedo = texelFetch(palette, ivec2(material_id, 0), 0).rgb;

    // T8/T9 fill these in. Hardcoded 1.0 means "no occlusion / fully visible".
    float shadow = 1.0;
    float ao     = 1.0;

    // Temporary composite per M8 plan T6: simple Lambertian with ambient.
    // T10 swaps in the smoothstep-gated composite from spec §7.
    float n_dot_l = max(dot(normal, sun_dir.xyz), 0.0);
    vec3  lit     = albedo * (ambient_color.rgb * ambient_color.a
                            + sun_color.rgb * sun_color.a * n_dot_l * shadow) * ao;

    out_color = vec4(lit, 1.0);
}
