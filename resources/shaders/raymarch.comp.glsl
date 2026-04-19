#version 460

layout(local_size_x = 8, local_size_y = 8) in;

layout(binding = 0) uniform sampler3D volume;
layout(binding = 1, rgba8) uniform restrict writeonly image2D target;

layout(std140, binding = 2) uniform U {
    vec4  camera_pos;
    vec4  world_min;
    vec4  world_max;
    ivec4 resolution;
    float fov_scale;
};

const int MAX_STEPS = 192;

vec2 aabb_intersect(vec3 ro, vec3 rd, vec3 bmin, vec3 bmax)
{
    vec3 inv = 1.0 / rd;
    vec3 t0  = (bmin - ro) * inv;
    vec3 t1  = (bmax - ro) * inv;
    vec3 tmn = min(t0, t1);
    vec3 tmx = max(t0, t1);
    float tn = max(max(tmn.x, tmn.y), tmn.z);
    float tf = min(min(tmx.x, tmx.y), tmx.z);
    return vec2(tn, tf);
}

void main()
{
    ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
    if (pix.x >= resolution.x || pix.y >= resolution.y) return;

    vec2 ndc = (vec2(pix) + 0.5) / vec2(resolution.xy) * 2.0 - 1.0;
    float aspect = float(resolution.x) / float(resolution.y);

    vec3 ro      = camera_pos.xyz;
    vec3 forward = normalize(-camera_pos.xyz);
    vec3 world_up = abs(forward.y) > 0.99 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
    vec3 right   = normalize(cross(forward, world_up));
    vec3 up      = cross(right, forward);
    vec3 rd      = normalize(forward
                           + ndc.x * aspect * fov_scale * right
                           + ndc.y * fov_scale * up);

    vec4 result = vec4(0.03, 0.03, 0.05, 1.0);

    vec2 t = aabb_intersect(ro, rd, world_min.xyz, world_max.xyz);
    if (t.y > max(t.x, 0.0)) {
        float t_start = max(t.x, 0.0);
        float t_end   = t.y;
        float step    = (t_end - t_start) / float(MAX_STEPS);

        for (int i = 0; i < MAX_STEPS; i++) {
            float ti = t_start + (float(i) + 0.5) * step;
            vec3 p   = ro + ti * rd;
            vec3 uvw = (p - world_min.xyz) / (world_max.xyz - world_min.xyz);
            vec4 v   = texture(volume, uvw);
            if (v.a > 0.5) {
                result = vec4(v.rgb, 1.0);
                break;
            }
        }
    }

    imageStore(target, pix, result);
}
