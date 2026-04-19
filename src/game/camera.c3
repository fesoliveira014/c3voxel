module c3voxel::game;

import std::math;

import c3voxel::core;
import c3voxel::voxel;

const core::Degrees ISO_ELEVATION_DEG = 35.264;
const core::Degrees ISO_AZIMUTH_DEG   = 45.0;

struct CameraState {
    core::Vec4 position;
    core::Vec4 forward;
    core::Vec4 right;
    core::Vec4 up;
    float      half_extent_x;
    float      half_extent_y;
    float      near_plane;
    float      far_plane;
    core::Vec3 pan_target;
    float      zoom_scale;
}

fn voxel::View CameraState.to_view(&self) @inline
{
    return {
        .position      = self.position,
        .forward       = self.forward,
        .right         = self.right,
        .up            = self.up,
        .half_extent_x = self.half_extent_x,
        .half_extent_y = self.half_extent_y,
    };
}

fn CameraState camera_isometric(core::Vec3 target, float zoom, float aspect, core::Degrees azimuth = ISO_AZIMUTH_DEG)
{
    float elev = (float)core::deg_to_rad(ISO_ELEVATION_DEG);
    float azim = (float)core::deg_to_rad(azimuth);

    core::Vec3 forward = {
        -(float)math::cos(elev) * (float)math::sin(azim),
        -(float)math::sin(elev),
        -(float)math::cos(elev) * (float)math::cos(azim),
    };
    core::Vec3 world_up = { 0.0, 1.0, 0.0 };
    core::Vec3 right    = forward.cross(world_up).normalize();
    core::Vec3 up       = right.cross(forward);

    float distance = 4.0 * zoom;
    core::Vec3 pos = target - forward * distance;

    return {
        .position      = { pos.x,     pos.y,     pos.z,     0.0 },
        .forward       = { forward.x, forward.y, forward.z, 0.0 },
        .right         = { right.x,   right.y,   right.z,   0.0 },
        .up            = { up.x,      up.y,      up.z,      0.0 },
        .half_extent_x = zoom * aspect,
        .half_extent_y = zoom,
        .near_plane    = 0.1,
        .far_plane     = distance * 2.0,
        .pan_target    = { target.x, target.y, target.z },
        .zoom_scale    = zoom,
    };
}

const float ISO_TILT = 0.2886751f;

fn core::Vec3 world_xz_to_screen(core::Vec3 pan_target, float zoom, float world_x, float world_y, float world_z) @inline
{
    float sx = zoom * ((world_x - pan_target.x) - (world_z - pan_target.z));
    float sy = zoom * (-ISO_TILT * ((world_x - pan_target.x) + (world_z - pan_target.z)) - world_y);
    return { sx, sy, 0.0f };
}
