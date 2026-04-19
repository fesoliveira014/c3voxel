module c3voxel::core;

import std::math;

const float DEG_TO_RAD = (float)math::PI / 180.0;
const float RAD_TO_DEG = 180.0 / (float)math::PI;

fn float deg_to_rad(float d) @inline => d * DEG_TO_RAD;
fn float rad_to_deg(float r) @inline => r * RAD_TO_DEG;
