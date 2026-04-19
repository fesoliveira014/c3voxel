#version 460

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(binding = 0, rgba8) uniform restrict readonly  image3D  volume;
layout(binding = 1, r8ui)  uniform restrict writeonly uimage3D dist;

void main()
{
    ivec3 cell = ivec3(gl_GlobalInvocationID);
    ivec3 base = cell * 4;

    uint solid = 0u;
    for (int z = 0; z < 4 && solid == 0u; z++)
    for (int y = 0; y < 4 && solid == 0u; y++)
    for (int x = 0; x < 4 && solid == 0u; x++) {
        if (imageLoad(volume, base + ivec3(x, y, z)).a > 0.5) solid = 1u;
    }

    imageStore(dist, cell, uvec4(solid == 1u ? 0u : 255u, 0u, 0u, 0u));
}
