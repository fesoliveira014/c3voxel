#version 460

layout(location = 0) in  vec2 v_pixel;
layout(location = 0) out vec4 frag_color;

layout(binding = 0) uniform sampler2D holder0_color;
layout(binding = 1) uniform sampler2D holder0_height;
layout(binding = 2) uniform sampler2D holder1_color;
layout(binding = 3) uniform sampler2D holder1_height;
layout(binding = 4) uniform sampler2D holder2_color;
layout(binding = 5) uniform sampler2D holder2_height;
layout(binding = 6) uniform sampler2D holder3_color;
layout(binding = 7) uniform sampler2D holder3_height;

layout(std140, binding = 8) uniform U {
    vec4  screen_min[4];
    vec4  screen_max[4];
    ivec4 screen_size;
    ivec4 active_count;
};

void main()
{
    float best_h = -1e30;
    vec4  best_c = vec4(0.0);
    vec2  p      = v_pixel;
    int   n      = active_count.x;

    for (int i = 0; i < 4; i++) {
        if (i >= n) break;
        vec2 smin = screen_min[i].xy;
        vec2 smax = screen_max[i].xy;
        if (any(lessThan(p, smin)) || any(greaterThan(p, smax))) continue;
        vec2 uv = (p - smin) / (smax - smin);

        float h;
        vec4  c;
        if (i == 0)      { c = texture(holder0_color, uv); h = texture(holder0_height, uv).r; }
        else if (i == 1) { c = texture(holder1_color, uv); h = texture(holder1_height, uv).r; }
        else if (i == 2) { c = texture(holder2_color, uv); h = texture(holder2_height, uv).r; }
        else             { c = texture(holder3_color, uv); h = texture(holder3_height, uv).r; }

        if (c.a > 0.001 && h > best_h) {
            best_h = h;
            best_c = c;
        }
    }

    if (best_h <= -1e30) discard;
    frag_color = best_c;
}
