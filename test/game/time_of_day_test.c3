module c3voxel::game::time_of_day_test;

import std::math;
import std::io;

import c3voxel::core;
import c3voxel::game;

const float TOL = 0.01f;

fn bool approx_eq(float a, float b, float tol = TOL) @local
{
    return math::abs(a - b) < tol;
}

// Test 1 — sun direction at the four cardinal times of day. Orbit is
// tilted 30° about world-X so t=0.25/0.75 carry ±0.5 in .z.
fn void sun_direction_cardinals() @test
{
    core::Vec3 d0   = game::sun_direction_for(0.00f);
    core::Vec3 d25  = game::sun_direction_for(0.25f);
    core::Vec3 d50  = game::sun_direction_for(0.50f);
    core::Vec3 d75  = game::sun_direction_for(0.75f);

    if (!approx_eq(d0.x, 1.0f) || !approx_eq(d0.y, 0.0f) || !approx_eq(d0.z, 0.0f)) {
        io::printfn("sun_direction_for(0.00) = (%.4f, %.4f, %.4f); expected ~(1, 0, 0)", d0.x, d0.y, d0.z);
    }
    assert(approx_eq(d0.x, 1.0f));
    assert(approx_eq(d0.y, 0.0f));
    assert(approx_eq(d0.z, 0.0f));

    if (!approx_eq(d25.x, 0.0f) || !approx_eq(d25.y, 0.866f) || !approx_eq(d25.z, 0.5f)) {
        io::printfn("sun_direction_for(0.25) = (%.4f, %.4f, %.4f); expected ~(0, 0.866, 0.5)", d25.x, d25.y, d25.z);
    }
    assert(approx_eq(d25.x, 0.0f));
    assert(approx_eq(d25.y, 0.866f));
    assert(approx_eq(d25.z, 0.5f));

    if (!approx_eq(d50.x, -1.0f) || !approx_eq(d50.y, 0.0f) || !approx_eq(d50.z, 0.0f)) {
        io::printfn("sun_direction_for(0.50) = (%.4f, %.4f, %.4f); expected ~(-1, 0, 0)", d50.x, d50.y, d50.z);
    }
    assert(approx_eq(d50.x, -1.0f));
    assert(approx_eq(d50.y, 0.0f));
    assert(approx_eq(d50.z, 0.0f));

    if (!approx_eq(d75.x, 0.0f) || !approx_eq(d75.y, -0.866f) || !approx_eq(d75.z, -0.5f)) {
        io::printfn("sun_direction_for(0.75) = (%.4f, %.4f, %.4f); expected ~(0, -0.866, -0.5)", d75.x, d75.y, d75.z);
    }
    assert(approx_eq(d75.x, 0.0f));
    assert(approx_eq(d75.y, -0.866f));
    assert(approx_eq(d75.z, -0.5f));
}

// Test 2 — intensity ordering: noon brighter than midnight.
fn void sun_intensity_noon_vs_midnight() @test
{
    core::Vec4 noon     = game::sun_color_for(0.25f);
    core::Vec4 midnight = game::sun_color_for(0.75f);
    if (noon.w <= midnight.w) {
        io::printfn("noon intensity %.4f should exceed midnight %.4f", noon.w, midnight.w);
    }
    assert(noon.w > midnight.w);
}

// Test 3 — moon color is dim but never pitch black.
fn void sun_color_moon_not_black() @test
{
    core::Vec4 c = game::sun_color_for(0.0f);
    float sum = c.x + c.y + c.z;
    if (sum <= 0.0f) {
        io::printfn("sun_color_for(0.0) = (%.4f, %.4f, %.4f, %.4f); RGB sum should be > 0",
                    c.x, c.y, c.z, c.w);
    }
    assert(sum > 0.0f);
}

// Test 4 — TimeOfDay.update is a no-op with auto_advance disabled.
fn void time_of_day_update_respects_auto() @test
{
    game::TimeOfDay tod;
    tod.init();
    tod.auto_advance = false;
    float start = tod.t;
    tod.update((core::Seconds)1.0f);
    assert(approx_eq(tod.t, start));
}

// Test 5 — step(+1) advances t by key_step and disables auto.
fn void time_of_day_step_disables_auto() @test
{
    game::TimeOfDay tod;
    tod.init();
    tod.auto_advance = true;
    float start = tod.t;
    tod.step(+1);
    assert(approx_eq(tod.t, start + game::TIME_KEY_STEP));
    assert(!tod.auto_advance);
}
