#version 460

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(binding = 0, r8ui) uniform restrict readonly  uimage3D src;
layout(binding = 1, r8ui) uniform restrict writeonly uimage3D dst;

layout(std140, binding = 2) uniform U {
    int step;
    int df_pitch;
};

void main()
{
    ivec3 p = ivec3(gl_GlobalInvocationID);
    if (any(greaterThanEqual(p, ivec3(df_pitch)))) return;

    uint best = imageLoad(src, p).r;

    for (int dz = -1; dz <= 1; dz++)
    for (int dy = -1; dy <= 1; dy++)
    for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0 && dz == 0) continue;
        ivec3 q = p + ivec3(dx, dy, dz) * step;
        if (any(lessThan(q, ivec3(0))) || any(greaterThanEqual(q, ivec3(df_pitch)))) continue;
        uint qd = imageLoad(src, q).r;
        uint candidate = min(qd + uint(step), 255u);
        if (candidate < best) best = candidate;
    }

    imageStore(dst, p, uvec4(best, 0u, 0u, 0u));
}
