module c3voxel::core;

import std::math;
import std::math::vector;

alias Vec3  = float[<3>];
alias Vec4  = float[<4>];
alias IVec2 = int[<2>];
alias IVec3 = int[<3>];
alias IVec4 = int[<4>];

typedef Seconds = inline float;
typedef Radians = inline float;
typedef Degrees = inline float;

const float DEG_TO_RAD = (float)math::PI / 180.0;
const float RAD_TO_DEG = 180.0 / (float)math::PI;

fn Radians deg_to_rad(Degrees d) @inline => (Radians)((float)d * DEG_TO_RAD);
fn Degrees rad_to_deg(Radians r) @inline => (Degrees)((float)r * RAD_TO_DEG);
