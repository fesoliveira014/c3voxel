#version 460

// M8 T6: trivial fullscreen triangle for the deferred lighting pass.
// Same gl_VertexID trick as deferred.vert.glsl — passes screen-space UVs
// in [0, 1] to the fragment shader.

out gl_PerVertex { vec4 gl_Position; };

layout(location = 0) out vec2 v_uv;

void main()
{
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    v_uv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
