#version 460

// M8 T4: deferred G-buffer build. For each screen pixel, iterate the live
// holder rects; the holder whose per-pixel `height` is highest wins. Output
// is a single RGBA8 packed G-buffer at window resolution:
//
//   .r, .g  = octahedral normal  (pass-through from holder)
//   .b      = height / MAX_WORLD_Y
//   .a      = material_id / 255
//
// `.a == 0` marks sky.
//
// Each of the up-to-16 holders needs three samplers (material, normal,
// height). The sampler bindings are laid out 3-per-holder starting at 0,
// mirroring `dispatch()` in src/render/deferred.c3.

layout(location = 0) in  vec2 v_pixel;
layout(location = 0) out vec4 frag_color;      // packed G-buffer (normal, h, mat)
layout(location = 1) out vec4 col_top_color;   // column-top y / MAX_WORLD_Y in .r

// --- material (R8UI / usampler) — 16 holders × 1 = bindings 0..15 ---
layout(binding =  0) uniform usampler2D h0m;
layout(binding =  1) uniform usampler2D h1m;
layout(binding =  2) uniform usampler2D h2m;
layout(binding =  3) uniform usampler2D h3m;
layout(binding =  4) uniform usampler2D h4m;
layout(binding =  5) uniform usampler2D h5m;
layout(binding =  6) uniform usampler2D h6m;
layout(binding =  7) uniform usampler2D h7m;
layout(binding =  8) uniform usampler2D h8m;
layout(binding =  9) uniform usampler2D h9m;
layout(binding = 10) uniform usampler2D h10m;
layout(binding = 11) uniform usampler2D h11m;
layout(binding = 12) uniform usampler2D h12m;
layout(binding = 13) uniform usampler2D h13m;
layout(binding = 14) uniform usampler2D h14m;
layout(binding = 15) uniform usampler2D h15m;

// --- normal (RG8 / sampler2D) — bindings 16..31 ---
layout(binding = 16) uniform sampler2D h0n;
layout(binding = 17) uniform sampler2D h1n;
layout(binding = 18) uniform sampler2D h2n;
layout(binding = 19) uniform sampler2D h3n;
layout(binding = 20) uniform sampler2D h4n;
layout(binding = 21) uniform sampler2D h5n;
layout(binding = 22) uniform sampler2D h6n;
layout(binding = 23) uniform sampler2D h7n;
layout(binding = 24) uniform sampler2D h8n;
layout(binding = 25) uniform sampler2D h9n;
layout(binding = 26) uniform sampler2D h10n;
layout(binding = 27) uniform sampler2D h11n;
layout(binding = 28) uniform sampler2D h12n;
layout(binding = 29) uniform sampler2D h13n;
layout(binding = 30) uniform sampler2D h14n;
layout(binding = 31) uniform sampler2D h15n;

// --- height (R16F) — bindings 33..48 (UBO sits at 32). ---
layout(binding = 33) uniform sampler2D h0h;
layout(binding = 34) uniform sampler2D h1h;
layout(binding = 35) uniform sampler2D h2h;
layout(binding = 36) uniform sampler2D h3h;
layout(binding = 37) uniform sampler2D h4h;
layout(binding = 38) uniform sampler2D h5h;
layout(binding = 39) uniform sampler2D h6h;
layout(binding = 40) uniform sampler2D h7h;
layout(binding = 41) uniform sampler2D h8h;
layout(binding = 42) uniform sampler2D h9h;
layout(binding = 43) uniform sampler2D h10h;
layout(binding = 44) uniform sampler2D h11h;
layout(binding = 45) uniform sampler2D h12h;
layout(binding = 46) uniform sampler2D h13h;
layout(binding = 47) uniform sampler2D h14h;
layout(binding = 48) uniform sampler2D h15h;

// --- column-top (R16F) — bindings 49..64. ---
layout(binding = 49) uniform sampler2D h0ct;
layout(binding = 50) uniform sampler2D h1ct;
layout(binding = 51) uniform sampler2D h2ct;
layout(binding = 52) uniform sampler2D h3ct;
layout(binding = 53) uniform sampler2D h4ct;
layout(binding = 54) uniform sampler2D h5ct;
layout(binding = 55) uniform sampler2D h6ct;
layout(binding = 56) uniform sampler2D h7ct;
layout(binding = 57) uniform sampler2D h8ct;
layout(binding = 58) uniform sampler2D h9ct;
layout(binding = 59) uniform sampler2D h10ct;
layout(binding = 60) uniform sampler2D h11ct;
layout(binding = 61) uniform sampler2D h12ct;
layout(binding = 62) uniform sampler2D h13ct;
layout(binding = 63) uniform sampler2D h14ct;
layout(binding = 64) uniform sampler2D h15ct;

layout(std140, binding = 32) uniform U {
    vec4  screen_min[16];
    vec4  screen_max[16];
    ivec4 screen_size;
    ivec4 alive_bits;
};

const float MAX_WORLD_Y = 128.0;

uint sample_material(int i, vec2 uv)
{
    if (i == 0)  return texture(h0m,  uv).r;
    if (i == 1)  return texture(h1m,  uv).r;
    if (i == 2)  return texture(h2m,  uv).r;
    if (i == 3)  return texture(h3m,  uv).r;
    if (i == 4)  return texture(h4m,  uv).r;
    if (i == 5)  return texture(h5m,  uv).r;
    if (i == 6)  return texture(h6m,  uv).r;
    if (i == 7)  return texture(h7m,  uv).r;
    if (i == 8)  return texture(h8m,  uv).r;
    if (i == 9)  return texture(h9m,  uv).r;
    if (i == 10) return texture(h10m, uv).r;
    if (i == 11) return texture(h11m, uv).r;
    if (i == 12) return texture(h12m, uv).r;
    if (i == 13) return texture(h13m, uv).r;
    if (i == 14) return texture(h14m, uv).r;
    return texture(h15m, uv).r;
}

vec2 sample_normal(int i, vec2 uv)
{
    if (i == 0)  return texture(h0n,  uv).rg;
    if (i == 1)  return texture(h1n,  uv).rg;
    if (i == 2)  return texture(h2n,  uv).rg;
    if (i == 3)  return texture(h3n,  uv).rg;
    if (i == 4)  return texture(h4n,  uv).rg;
    if (i == 5)  return texture(h5n,  uv).rg;
    if (i == 6)  return texture(h6n,  uv).rg;
    if (i == 7)  return texture(h7n,  uv).rg;
    if (i == 8)  return texture(h8n,  uv).rg;
    if (i == 9)  return texture(h9n,  uv).rg;
    if (i == 10) return texture(h10n, uv).rg;
    if (i == 11) return texture(h11n, uv).rg;
    if (i == 12) return texture(h12n, uv).rg;
    if (i == 13) return texture(h13n, uv).rg;
    if (i == 14) return texture(h14n, uv).rg;
    return texture(h15n, uv).rg;
}

float sample_height(int i, vec2 uv)
{
    if (i == 0)  return texture(h0h,  uv).r;
    if (i == 1)  return texture(h1h,  uv).r;
    if (i == 2)  return texture(h2h,  uv).r;
    if (i == 3)  return texture(h3h,  uv).r;
    if (i == 4)  return texture(h4h,  uv).r;
    if (i == 5)  return texture(h5h,  uv).r;
    if (i == 6)  return texture(h6h,  uv).r;
    if (i == 7)  return texture(h7h,  uv).r;
    if (i == 8)  return texture(h8h,  uv).r;
    if (i == 9)  return texture(h9h,  uv).r;
    if (i == 10) return texture(h10h, uv).r;
    if (i == 11) return texture(h11h, uv).r;
    if (i == 12) return texture(h12h, uv).r;
    if (i == 13) return texture(h13h, uv).r;
    if (i == 14) return texture(h14h, uv).r;
    return texture(h15h, uv).r;
}

float sample_col_top(int i, vec2 uv)
{
    if (i == 0)  return texture(h0ct,  uv).r;
    if (i == 1)  return texture(h1ct,  uv).r;
    if (i == 2)  return texture(h2ct,  uv).r;
    if (i == 3)  return texture(h3ct,  uv).r;
    if (i == 4)  return texture(h4ct,  uv).r;
    if (i == 5)  return texture(h5ct,  uv).r;
    if (i == 6)  return texture(h6ct,  uv).r;
    if (i == 7)  return texture(h7ct,  uv).r;
    if (i == 8)  return texture(h8ct,  uv).r;
    if (i == 9)  return texture(h9ct,  uv).r;
    if (i == 10) return texture(h10ct, uv).r;
    if (i == 11) return texture(h11ct, uv).r;
    if (i == 12) return texture(h12ct, uv).r;
    if (i == 13) return texture(h13ct, uv).r;
    if (i == 14) return texture(h14ct, uv).r;
    return texture(h15ct, uv).r;
}

void main()
{
    float best_h       = -1.0e30;
    float best_col_top = -1.0e30;
    uint  best_mat     = 0u;
    vec2  best_norm    = vec2(0.5, 0.5);
    vec2  p            = v_pixel;
    uint  alive        = uint(alive_bits.x);

    for (int i = 0; i < 16; i++) {
        if ((alive & (1u << i)) == 0u) continue;
        vec2 smin = screen_min[i].xy;
        vec2 smax = screen_max[i].xy;
        if (any(lessThan(p, smin)) || any(greaterThan(p, smax))) continue;
        vec2 uv = (p - smin) / (smax - smin);

        uint m = sample_material(i, uv);
        if (m == 0u) continue;                    // air / sky in that holder
        float h = sample_height(i, uv);
        if (h > best_h) {
            best_h       = h;
            best_mat     = m;
            best_norm    = sample_normal(i, uv);
            best_col_top = sample_col_top(i, uv);
        }
    }

    if (best_h <= -1.0e30) {
        // Sky: lighting discards on .a == 0.
        frag_color    = vec4(0.0);
        col_top_color = vec4(0.0);
        return;
    }

    frag_color = vec4(
        best_norm.x,
        best_norm.y,
        clamp(best_h / MAX_WORLD_Y, 0.0, 1.0),
        float(best_mat) / 255.0);
    // Column-top normalized into R8 — lighting.frag scales back by
    // MAX_WORLD_Y. 256 steps across 128 world units is the same 0.5-unit
    // precision the height channel already uses.
    col_top_color = vec4(clamp(best_col_top / MAX_WORLD_Y, 0.0, 1.0), 0.0, 0.0, 0.0);
}
