#version 460

out gl_PerVertex { vec4 gl_Position; };

layout(location = 0) out vec2 v_pixel;

layout(std140, binding = 32) uniform U {
    vec4  screen_min[16];
    vec4  screen_max[16];
    ivec4 screen_size;
    ivec4 alive_bits;
};

void main()
{
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    v_pixel = p * vec2(screen_size.xy);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
