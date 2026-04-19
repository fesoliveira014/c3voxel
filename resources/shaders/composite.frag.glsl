#version 460

layout(location = 0) in  vec2 v_pixel;
layout(location = 0) out vec4 frag_color;

layout(binding =  0) uniform sampler2D h0c;
layout(binding =  1) uniform sampler2D h0h;
layout(binding =  2) uniform sampler2D h1c;
layout(binding =  3) uniform sampler2D h1h;
layout(binding =  4) uniform sampler2D h2c;
layout(binding =  5) uniform sampler2D h2h;
layout(binding =  6) uniform sampler2D h3c;
layout(binding =  7) uniform sampler2D h3h;
layout(binding =  8) uniform sampler2D h4c;
layout(binding =  9) uniform sampler2D h4h;
layout(binding = 10) uniform sampler2D h5c;
layout(binding = 11) uniform sampler2D h5h;
layout(binding = 12) uniform sampler2D h6c;
layout(binding = 13) uniform sampler2D h6h;
layout(binding = 14) uniform sampler2D h7c;
layout(binding = 15) uniform sampler2D h7h;
layout(binding = 16) uniform sampler2D h8c;
layout(binding = 17) uniform sampler2D h8h;
layout(binding = 18) uniform sampler2D h9c;
layout(binding = 19) uniform sampler2D h9h;
layout(binding = 20) uniform sampler2D h10c;
layout(binding = 21) uniform sampler2D h10h;
layout(binding = 22) uniform sampler2D h11c;
layout(binding = 23) uniform sampler2D h11h;
layout(binding = 24) uniform sampler2D h12c;
layout(binding = 25) uniform sampler2D h12h;
layout(binding = 26) uniform sampler2D h13c;
layout(binding = 27) uniform sampler2D h13h;
layout(binding = 28) uniform sampler2D h14c;
layout(binding = 29) uniform sampler2D h14h;
layout(binding = 30) uniform sampler2D h15c;
layout(binding = 31) uniform sampler2D h15h;

layout(std140, binding = 32) uniform U {
    vec4  screen_min[16];
    vec4  screen_max[16];
    ivec4 screen_size;
    ivec4 alive_bits;
};

vec4 sample_color(int i, vec2 uv)
{
    if (i == 0)  return texture(h0c,  uv);
    if (i == 1)  return texture(h1c,  uv);
    if (i == 2)  return texture(h2c,  uv);
    if (i == 3)  return texture(h3c,  uv);
    if (i == 4)  return texture(h4c,  uv);
    if (i == 5)  return texture(h5c,  uv);
    if (i == 6)  return texture(h6c,  uv);
    if (i == 7)  return texture(h7c,  uv);
    if (i == 8)  return texture(h8c,  uv);
    if (i == 9)  return texture(h9c,  uv);
    if (i == 10) return texture(h10c, uv);
    if (i == 11) return texture(h11c, uv);
    if (i == 12) return texture(h12c, uv);
    if (i == 13) return texture(h13c, uv);
    if (i == 14) return texture(h14c, uv);
    return texture(h15c, uv);
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

void main()
{
    float best_h = -1e30;
    vec4  best_c = vec4(0.0);
    vec2  p      = v_pixel;
    uint  alive  = uint(alive_bits.x);

    for (int i = 0; i < 16; i++) {
        if ((alive & (1u << i)) == 0u) continue;
        vec2 smin = screen_min[i].xy;
        vec2 smax = screen_max[i].xy;
        if (any(lessThan(p, smin)) || any(greaterThan(p, smax))) continue;
        vec2 uv = (p - smin) / (smax - smin);
        vec4 c = sample_color(i, uv);
        if (c.a < 0.001) continue;
        float h = sample_height(i, uv);
        if (h > best_h) {
            best_h = h;
            best_c = c;
        }
    }

    if (best_h <= -1e30) discard;
    frag_color = best_c;
}
