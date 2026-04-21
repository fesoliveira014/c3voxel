module c3voxel::world;

import std::math;

import c3voxel::core;

const int HOLDER_WORLD_EXTENT = PIXELS_PER_PAGE * PAGES_PER_HOLDER;

const float ISO_TILT = 0.2886751f;

struct HolderRect {
    HolderCoord x0;
    HolderCoord z0;
    HolderCoord x1;
    HolderCoord z1;
}

fn core::Vec3 screen_to_world_xz(core::Vec3 pan_target, float zoom, float screen_x, float screen_y) @inline
{
    float s = screen_x / zoom;
    float t = screen_y / zoom;
    float u = t / ISO_TILT;
    float wx = (u + s) * 0.5f;
    float wz = (u - s) * 0.5f;
    return { pan_target.x + wx, 0.0f, pan_target.z + wz };
}

// Full inverse with a user-supplied world height. Mirrors the GLSL
// `iso_inverse(uv, height)` in `resources/shaders/common/iso.glsl`: takes a
// UV on the framebuffer and the world-y at that pixel and recovers the
// world XYZ. Used for the shadow-march roundtrip unit test (M8 T8).
fn core::Vec3 screen_to_world_xyz(core::Vec3 pan_target, float zoom, float uv_x, float uv_y, float height, int fb_w, int fb_h) @inline
{
    float half_w = (float)fb_w * 0.5f;
    float half_h = (float)fb_h * 0.5f;
    float px_x = uv_x * (float)fb_w - half_w;
    float px_y = uv_y * (float)fb_h - half_h;
    float sx = px_x / zoom;
    float sy = px_y / zoom;
    // sy = T * (dx + dz) + height  →  dx + dz = (sy - height) / T.
    // sx = dx - dz.
    float sum  = (sy - height) / ISO_TILT;
    float diff = sx;
    float dx = 0.5f * (diff + sum);
    float dz = 0.5f * (sum - diff);
    return { pan_target.x + dx, height, pan_target.z + dz };
}

fn HolderRect visible_holder_rect(core::Vec3 pan_target, float zoom, int fb_w, int fb_h, int margin)
{
    float half_w = (float)fb_w * 0.5f;
    float half_h = (float)fb_h * 0.5f;

    core::Vec3 c0 = screen_to_world_xz(pan_target, zoom, -half_w, -half_h);
    core::Vec3 c1 = screen_to_world_xz(pan_target, zoom,  half_w, -half_h);
    core::Vec3 c2 = screen_to_world_xz(pan_target, zoom, -half_w,  half_h);
    core::Vec3 c3 = screen_to_world_xz(pan_target, zoom,  half_w,  half_h);

    float min_x = c0.x;
    float max_x = c0.x;
    float min_z = c0.z;
    float max_z = c0.z;
    if (c1.x < min_x) min_x = c1.x; if (c1.x > max_x) max_x = c1.x;
    if (c2.x < min_x) min_x = c2.x; if (c2.x > max_x) max_x = c2.x;
    if (c3.x < min_x) min_x = c3.x; if (c3.x > max_x) max_x = c3.x;
    if (c1.z < min_z) min_z = c1.z; if (c1.z > max_z) max_z = c1.z;
    if (c2.z < min_z) min_z = c2.z; if (c2.z > max_z) max_z = c2.z;
    if (c3.z < min_z) min_z = c3.z; if (c3.z > max_z) max_z = c3.z;

    int holder_extent = HOLDER_WORLD_EXTENT;
    float extent_f    = (float)holder_extent;
    int x0 = (int)math::floor(min_x / extent_f) - margin;
    int z0 = (int)math::floor(min_z / extent_f) - margin;
    int x1 = (int)math::floor((max_x - 0.001f) / extent_f) + margin;
    int z1 = (int)math::floor((max_z - 0.001f) / extent_f) + margin;
    if (x1 < x0) x1 = x0;
    if (z1 < z0) z1 = z0;
    return { (HolderCoord)x0, (HolderCoord)z0, (HolderCoord)x1, (HolderCoord)z1 };
}

fn int holder_rect_count(HolderRect r) @inline
    => ((int)r.x1 - (int)r.x0 + 1) * ((int)r.z1 - (int)r.z0 + 1);
