#version 460

// M8 T9: VoxelQuest-style height-based SSAO (docs/ssao.md §3 / §7).
//
// For each screen pixel:
//   1. Unpack the surface normal (octahedral) and height (from the G-buffer).
//   2. Fire I_MAX × (J_MAX-2) samples in a nested angular × radius loop.
//   3. Project each sample to a screen offset, read the G-buffer there,
//      and compare the world-space height at the sample position to the
//      world-space height stored at the offset pixel. A lower stored
//      height means "open space", i.e. an unoccluded sample.
//   4. `pow(…, 6)` on the ratio sharpens the contrast so lit surfaces stay
//      bright and corners darken fast (ssao.md §3 step 7).
//
// Output is R8; 1.0 = fully lit, lower values = more occluded.

#include "common/octahedral.glsl"

layout(location = 0) in  vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(binding = 0) uniform sampler2D gbuffer;

layout(std140, binding = 1) uniform U {
    vec4 resolution;     // .xy = fb size, .z = MAX_WORLD_Y, .w unused
};

// Low tier per spec: 8 angular samples × 3 effective radii = 24 taps.
const int   I_MAX = 8;
const int   J_MAX = 5;
const float PI    = 3.14159265;

void main()
{
    vec4 base = texture(gbuffer, v_uv);
    // Sky pixels have no surface to occlude; preserve "fully lit".
    if (base.a == 0.0) {
        out_color = vec4(1.0, 0.0, 0.0, 0.0);
        return;
    }

    // Decode octahedral normal, then apply the ssao.md `*2.0` tuning so
    // the sample origin bias reaches just past the surface.
    vec3 n = octahedral_unpack(base.rg);
    n *= 2.0;

    float tot_hits = 0.0;
    float tot_rays = 0.0;

    // Loop runs j = 2, 3, 4 — three effective radii (4, 8, 16 world units).
    for (int j = 2; j < J_MAX; j++) {
        float r_tier    = exp2(float(j));
        float hit_power = (float(J_MAX) - r_tier) / float(J_MAX);

        for (int i = 0; i < I_MAX; i++) {
            float fi    = float(i) * PI / float(I_MAX);
            float theta = fi * 0.5;
            float phi   = fi * 2.0;
            float rad   = r_tier * fi / PI;

            float dx = rad * cos(phi + r_tier) * sin(theta);
            float dy = rad * sin(phi + r_tier) * sin(theta);
            float dz = rad * cos(theta);

            // Iso projection's linearity lets us add the vertical offset
            // `(dz + n.z)` directly into the screen-y the same way VQ did.
            vec2 tc_xy = vec2(dx + n.x, (dy - n.y) + (dz + n.z)) / resolution.xy;
            // base.b is already height / MAX_WORLD_Y (our G-buffer layout);
            // the +dz/255 offset is a small normalized bump above the
            // surface so the comparison is "does something rise higher".
            float tc_z = clamp(base.b + (dz + n.z) / 255.0, 0.0, 1.0);

            vec4 samp = texture(gbuffer, v_uv + tc_xy);
            if (samp.b < tc_z) tot_hits += hit_power;
            tot_rays += hit_power;
        }
    }

    float ao = clamp(tot_hits / max(tot_rays, 1e-4), 0.0, 1.0);
    // Raw ratio only — lighting.frag applies its own floor-and-scale
    // (`0.25 + 0.75 * ao`). VQ's `pow(ao, 6.0)` was paired with a
    // mix(dark, lit) composite that used AO on the dark branch alone;
    // our simpler composite multiplies the whole lit expression by AO,
    // so an additional exponent just crushes the full image.
    out_color = vec4(ao, 0.0, 0.0, 0.0);
}
