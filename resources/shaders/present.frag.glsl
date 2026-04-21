#version 460

// M8 T6: gamma-correct the linear lighting result onto the default
// framebuffer. No tonemap yet — that's M10.

layout(location = 0) in  vec2 v_uv;
layout(location = 0) out vec4 frag_color;

layout(binding = 0) uniform sampler2D lit_tex;

const float GAMMA_INV = 1.0 / 2.2;

void main()
{
    vec3 lin = texture(lit_tex, v_uv).rgb;
    frag_color = vec4(pow(lin, vec3(GAMMA_INV)), 1.0);
}
