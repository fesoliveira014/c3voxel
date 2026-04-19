#version 460

layout(local_size_x = 8, local_size_y = 8) in;

layout(binding = 0)         uniform sampler3D  volume;
layout(binding = 1)         uniform usampler3D dist_field;
layout(binding = 2, rgba8)  uniform restrict writeonly image2D color_out;
layout(binding = 3, r16f)   uniform restrict writeonly image2D height_out;

layout(std140, binding = 4) uniform U {
    vec4  camera_pos;
    vec4  camera_forward;
    vec4  camera_right;
    vec4  camera_up;
    vec4  world_min;
    vec4  world_max;
    ivec4 resolution;
    ivec4 pitches;
    ivec4 page_pixels;
    ivec4 write_offset;
    float half_extent_x;
    float half_extent_y;
};

const int MAX_STEPS = 256;

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
    ivec2 local_pix = ivec2(gl_GlobalInvocationID.xy);
    if (local_pix.x >= page_pixels.x || local_pix.y >= page_pixels.y) return;

    vec2 ndc    = (vec2(local_pix) + 0.5) / vec2(page_pixels.xy) * 2.0 - 1.0;
    float aspect = float(page_pixels.x) / float(page_pixels.y);

    vec3 ro = camera_pos.xyz
            + ndc.x * half_extent_x * camera_right.xyz
            + ndc.y * half_extent_y * camera_up.xyz;
    vec3 rd = camera_forward.xyz;

    int   volume_pitch = pitches.x;
    int   df_pitch     = pitches.y;
    int   cell_voxels  = pitches.z;

    vec4  color  = vec4(0.0);
    float height = -1.0e30;

    vec3  size      = world_max.xyz - world_min.xyz;
    float voxel_len = size.x / float(volume_pitch);

    vec2 t = aabb_intersect(ro, rd, world_min.xyz, world_max.xyz);
    ivec2 out_pix = local_pix + write_offset.xy;

    if (t.y > max(t.x, 0.0)) {
        float t_cur = max(t.x, 0.0);
        float t_end = t.y;

        for (int i = 0; i < MAX_STEPS; i++) {
            if (t_cur >= t_end) break;
            vec3  p   = ro + t_cur * rd;
            vec3  uvw = (p - world_min.xyz) / size;

            uint d_cells = texelFetch(dist_field, ivec3(uvw * float(df_pitch)), 0).r;
            if (d_cells <= 1u) {
                vec4 v = texture(volume, uvw);
                if (v.a > 0.5) {
                    color  = vec4(v.rgb, 1.0);
                    height = p.y;
                    break;
                }
                t_cur += voxel_len;
            } else {
                t_cur += float(d_cells - 1u) * float(cell_voxels) * voxel_len;
            }
        }
    }

    imageStore(color_out,  out_pix, color);
    imageStore(height_out, out_pix, vec4(height, 0.0, 0.0, 0.0));
}
