#version 460

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(binding = 0, rgba8) uniform restrict writeonly image3D volume;
layout(binding = 1)        uniform sampler2D heightmap;

layout(std140, binding = 2) uniform U {
    vec4  world_min;
    vec4  world_max;
    vec4  block_origin;
    vec4  block_extent;
    float time;
};

const float VOLUME_PITCH = 128.0;
const float MAX_HEIGHT   = 128.0;

void main()
{
    ivec3 voxel = ivec3(gl_GlobalInvocationID);
    vec3  uvw   = (vec3(voxel) + 0.5) / vec3(VOLUME_PITCH);
    vec3  world = mix(world_min.xyz, world_max.xyz, uvw);

    vec2  hm_uv = (world.xz - block_origin.xz) / block_extent.xz;
    float h01   = texture(heightmap, hm_uv).r;
    float h_w   = h01 * MAX_HEIGHT;

    vec4 result = vec4(0.0);
    if (world.y <= h_w) {
        vec3 col;
        if (h01 < 0.30) {
            col = vec3(0.45, 0.45, 0.48);
        } else if (h01 < 0.70) {
            col = vec3(0.55, 0.40, 0.25);
        } else {
            col = vec3(0.30, 0.60, 0.25);
        }
        float shade = clamp(1.0 - (h_w - world.y) / MAX_HEIGHT, 0.4, 1.0);
        result = vec4(col * shade, 1.0);
    }
    imageStore(volume, voxel, result);
}
