module c3voxel::core::iso_roundtrip_test;

import std::math;
import std::io;

import c3voxel::core;
import c3voxel::game;
import c3voxel::world;

// Tolerance for `iso_forward ∘ iso_inverse` roundtrip; the spec requires
// < 0.01 world units. Single-precision floats through the iso tilt are
// clean enough that we pass with room to spare.
const float TOL = 0.01f;

// Mirrors the GLSL `iso_forward(w) → UV in [0,1]`:
//   px = (zoom * (dx - dz), zoom * (T * (dx + dz) + wy))
//   uv = (px + 0.5 * fb_res) / fb_res
// C3's `game::world_xz_to_screen` returns the centered screen coordinate
// (half_res offset not yet applied); we apply it here to produce a UV
// comparable to the shader output.
fn core::Vec3 world_xyz_to_uv(
    core::Vec3 pan, float zoom,
    float wx, float wy, float wz,
    int fb_w, int fb_h) @local
{
    core::Vec3 s = game::world_xz_to_screen(pan, zoom, wx, wy, wz);
    float half_w = (float)fb_w * 0.5f;
    float half_h = (float)fb_h * 0.5f;
    return {
        (s.x + half_w) / (float)fb_w,
        (s.y + half_h) / (float)fb_h,
        0.0f,
    };
}

// Deterministic small LCG — avoids pulling in std::random for a 100-sample
// test. Constants from Numerical Recipes.
fn uint lcg_next(uint state) @local @inline => state * 1664525u + 1013904223u;
fn float lcg_frac(uint* state) @local @inline
{
    *state = lcg_next(*state);
    return (float)(*state >> 8) * (1.0f / 16777216.0f);
}
fn float lcg_range(uint* state, float lo, float hi) @local @inline
    => lo + (hi - lo) * lcg_frac(state);

// Test 1 — roundtrip 100 random world points through forward+inverse.
// Each sample is a random world XYZ with an independently random height
// fed back into `iso_inverse`; should match the original within TOL.
fn void iso_forward_inverse_roundtrip() @test
{
    const int FB_W = 1920;
    const int FB_H = 1080;

    uint rng = 0xC0FFEEu;
    int failures = 0;
    float max_err = 0.0f;

    for (int i = 0; i < 100; i++) {
        core::Vec3 pan = {
            lcg_range(&rng, -128.0f, 128.0f),
            0.0f,
            lcg_range(&rng, -128.0f, 128.0f),
        };
        float zoom = lcg_range(&rng, 0.5f, 8.0f);
        float wx   = pan.x + lcg_range(&rng, -64.0f, 64.0f);
        float wy   = lcg_range(&rng,  0.0f,  128.0f);
        float wz   = pan.z + lcg_range(&rng, -64.0f, 64.0f);

        core::Vec3 uv  = world_xyz_to_uv(pan, zoom, wx, wy, wz, FB_W, FB_H);
        core::Vec3 rec = world::screen_to_world_xyz(pan, zoom, uv.x, uv.y, wy, FB_W, FB_H);

        float dx = rec.x - wx;
        float dy = rec.y - wy;
        float dz = rec.z - wz;
        float err = math::sqrt(dx*dx + dy*dy + dz*dz);
        if (err > max_err) max_err = err;
        if (err >= TOL) {
            if (failures < 5) {
                io::printfn("roundtrip fail #%d: in=(%.3f, %.3f, %.3f) pan=(%.3f, _, %.3f) zoom=%.3f out=(%.3f, %.3f, %.3f) err=%.5f",
                    i, wx, wy, wz, pan.x, pan.z, zoom, rec.x, rec.y, rec.z, err);
            }
            failures++;
        }
    }
    if (failures > 0) io::printfn("iso roundtrip: %d / 100 over TOL=%.4f; max_err=%.5f", failures, TOL, max_err);
    assert(failures == 0);
}
