#version 460

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag_color;

void main()
{
    frag_color = vec4(v_uv, 0.25 + 0.5 * v_uv.x, 1.0);
}
