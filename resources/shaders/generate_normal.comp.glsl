#version 460

// M8 T2: volume normal pass. Reads the main volume's opacity (.a), computes
// a 6-tap central-difference gradient pointing from solid into air, normalizes,
// and writes the octahedral-packed result into an RG8 aux volume. The aux
// volume is sampled alongside the main volume by the raymarch stage to pick
// up per-surface normals for deferred shading.

#include "common/octahedral.glsl"

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(binding = 0, rgba8) uniform restrict readonly  image3D volume_src;
layout(binding = 1, rg8)   uniform restrict writeonly image3D normal_out;

float fetch_opacity(ivec3 p, ivec3 vmax)
{
    // Clamp off-volume samples to 0 so edge voxels see empty neighbours rather
    // than wrapping — this gives zero gradient contribution and, after
    // normalization, a clean (0, 1, 0) fallback.
    if (any(lessThan(p, ivec3(0))) || any(greaterThanEqual(p, vmax))) return 0.0;
    return imageLoad(volume_src, p).a;
}

void main()
{
    ivec3 voxel = ivec3(gl_GlobalInvocationID);
    ivec3 vmax  = imageSize(volume_src);
    if (any(greaterThanEqual(voxel, vmax))) return;

    float ax_neg = fetch_opacity(voxel + ivec3(-1,  0,  0), vmax);
    float ax_pos = fetch_opacity(voxel + ivec3( 1,  0,  0), vmax);
    float ay_neg = fetch_opacity(voxel + ivec3( 0, -1,  0), vmax);
    float ay_pos = fetch_opacity(voxel + ivec3( 0,  1,  0), vmax);
    float az_neg = fetch_opacity(voxel + ivec3( 0,  0, -1), vmax);
    float az_pos = fetch_opacity(voxel + ivec3( 0,  0,  1), vmax);

    // Gradient points from solid towards air. A fully interior voxel has all
    // six neighbours opaque and hence a zero gradient; the length guard below
    // catches that case.
    vec3 grad = vec3(ax_neg - ax_pos, ay_neg - ay_pos, az_neg - az_pos);
    float len = length(grad);
    vec3 n = (len < 1e-6) ? vec3(0.0, 1.0, 0.0) : grad / len;

    vec2 packed = octahedral_pack(n);
    imageStore(normal_out, voxel, vec4(packed, 0.0, 0.0));
}
