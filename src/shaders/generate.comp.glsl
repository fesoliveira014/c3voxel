#version 460

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(binding = 0, rgba8) uniform restrict writeonly image3D volume;

layout(std140, binding = 1) uniform U {
    vec4  world_min;
    vec4  world_max;
    float time;
};

const float VOLUME_PITCH = 128.0;

float hash31(vec3 p)
{
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

void main()
{
    ivec3 voxel = ivec3(gl_GlobalInvocationID);
    vec3 uvw    = (vec3(voxel) + 0.5) / vec3(VOLUME_PITCH);
    vec3 world  = mix(world_min.xyz, world_max.xyz, uvw);

    float r_outer = 0.72;
    float r_inner = 0.48;
    float d       = length(world);

    float carve = hash31(world * 3.1 + vec3(time * 0.2));
    bool  solid = d < r_outer && (d > r_inner || carve > 0.45);

    vec4 result = vec4(0.0);
    if (solid) {
        vec3 col = 0.5 + 0.5 * normalize(world + vec3(0.001));
        float shade = clamp(1.0 - (d - r_inner) / (r_outer - r_inner), 0.35, 1.0);
        result = vec4(col * shade, 1.0);
    }

    imageStore(volume, voxel, result);
}
