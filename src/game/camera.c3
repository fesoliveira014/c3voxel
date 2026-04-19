module c3voxel::game;

import std::math;

import c3voxel::core;
import c3voxel::voxel;

const float ISO_ELEVATION_DEG = 35.264;
const float ISO_AZIMUTH_DEG   = 45.0;

struct CameraState {
    float[4] position;
    float[4] forward;
    float[4] right;
    float[4] up;
    float    half_extent_x;
    float    half_extent_y;
    float    near_plane;
    float    far_plane;
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

fn CameraState camera_isometric(float[4] target, float zoom, float aspect, float azimuth_deg = ISO_AZIMUTH_DEG)
{
    float elev = core::deg_to_rad(ISO_ELEVATION_DEG);
    float azim = core::deg_to_rad(azimuth_deg);

    float[<3>] forward = {
        -(float)math::cos(elev) * (float)math::sin(azim),
        -(float)math::sin(elev),
        -(float)math::cos(elev) * (float)math::cos(azim),
    };
    float[<3>] world_up = { 0.0, 1.0, 0.0 };
    float[<3>] right    = forward.cross(world_up).normalize();
    float[<3>] up       = right.cross(forward);

    float distance = 4.0 * zoom;
    float[<3>] target_v = { target[0], target[1], target[2] };
    float[<3>] pos_v    = target_v - forward * distance;

    return {
        .position      = { pos_v.x,   pos_v.y,   pos_v.z,   0.0 },
        .forward       = { forward.x, forward.y, forward.z, 0.0 },
        .right         = { right.x,   right.y,   right.z,   0.0 },
        .up            = { up.x,      up.y,      up.z,      0.0 },
        .half_extent_x = zoom * aspect,
        .half_extent_y = zoom,
        .near_plane    = 0.1,
        .far_plane     = distance * 2.0,
    };
}
