module c3voxel::game;

import std::math;

import c3voxel::core;

// Default day length (one full cycle) and per-tap key step. `key_step` is
// 1/32 so `[`/`]` move the sun in ~11° increments (≈ 1 hour of a
// compressed day).
const core::Seconds DAY_LENGTH_DEFAULT = (core::Seconds)60.0f;
const float         TIME_KEY_STEP      = 1.0f / 32.0f;

// Pure state for the M8 sun. `t` wraps in [0, 1) and is shaped so
// t=0    → sun on east horizon
// t=0.25 → sun overhead  (start-up default — nice lit-village opening)
// t=0.5  → sun on west horizon
// t=0.75 → below horizon (night, sun_color returns the moon stops)
struct TimeOfDay {
    float         t;
    bool          auto_advance;
    core::Seconds day_length;
    float         key_step;
}

fn void TimeOfDay.init(&self)
{
    self.t            = 0.25f;
    self.auto_advance = true;
    self.day_length   = DAY_LENGTH_DEFAULT;
    self.key_step     = TIME_KEY_STEP;
}

// Advances `t` when auto-advance is on. No-op for manual stepping.
fn void TimeOfDay.update(&self, core::Seconds dt)
{
    if (!self.auto_advance) return;
    if ((float)self.day_length <= 0.0f) return;
    self.t += (float)dt / (float)self.day_length;
    self.t = wrap01(self.t);
}

// Manual step: ±key_step, and disables auto-advance so the user can hold a
// specific time. Call repeatedly on key repeat for continuous stepping.
fn void TimeOfDay.step(&self, int dir)
{
    float d = (float)dir * self.key_step;
    self.t = wrap01(self.t + d);
    self.auto_advance = false;
}

fn void TimeOfDay.toggle_auto(&self) @inline
{
    self.auto_advance = !self.auto_advance;
}

// --- Pure helpers, unit-testable -----------------------------------------

// Sun arcs in the world XY plane (east→up→west→down):
//   t=0    → (+1, 0, 0)   east horizon
//   t=0.25 → ( 0,+1, 0)   overhead
//   t=0.5  → (-1, 0, 0)   west horizon
//   t=0.75 → ( 0,-1, 0)   below horizon
fn core::Vec3 sun_direction_for(float t) @inline
{
    float angle = t * 2.0f * (float)math::PI;
    return { (float)math::cos(angle), (float)math::sin(angle), 0.0f };
}

// Sun/moon color with an intensity in `.a`. Piecewise linear between four
// stops — no transcendentals beyond the direction sin/cos. `t=0.25` is
// overhead (brightest) and `t=0.75` is below horizon (dimmest moonlight):
//
//   t ∈ [0.00, 0.25) rise:   lerp(dawn_gold,  noon_white, t*4)
//   t ∈ [0.25, 0.50) fall:   lerp(noon_white, dawn_gold,  (t-.25)*4)
//   t ∈ [0.50, 0.75) dusk:   lerp(dawn_gold,  moon_blue,  (t-.5)*4)
//   t ∈ [0.75, 1.00) rise:   lerp(moon_blue,  dawn_gold,  (t-.75)*4)
//
// Intensity mirrors the color schedule so night is 0.15, horizon 0.40 and
// noon 1.00. No cache-busting transcendentals beyond the wrap.
fn core::Vec4 sun_color_for(float t)
{
    const core::Vec3 MOON_BLUE  = { 0.025f, 0.030f, 0.075f }; // (0.10,0.12,0.30)*0.25
    const core::Vec3 DAWN_GOLD  = { 1.00f,  0.72f,  0.40f  };
    const core::Vec3 NOON_WHITE = { 1.00f,  0.98f,  0.92f  };
    const float      I_NIGHT   = 0.15f;
    const float      I_HORIZON = 0.40f;
    const float      I_NOON    = 1.00f;

    float tw = wrap01(t);
    core::Vec3 rgb;
    float      intensity;
    if (tw < 0.25f) {
        float f   = tw * 4.0f;
        rgb       = lerp_vec3(DAWN_GOLD, NOON_WHITE, f);
        intensity = lerp_scalar(I_HORIZON, I_NOON, f);
    } else if (tw < 0.5f) {
        float f   = (tw - 0.25f) * 4.0f;
        rgb       = lerp_vec3(NOON_WHITE, DAWN_GOLD, f);
        intensity = lerp_scalar(I_NOON, I_HORIZON, f);
    } else if (tw < 0.75f) {
        float f   = (tw - 0.5f) * 4.0f;
        rgb       = lerp_vec3(DAWN_GOLD, MOON_BLUE, f);
        intensity = lerp_scalar(I_HORIZON, I_NIGHT, f);
    } else {
        float f   = (tw - 0.75f) * 4.0f;
        rgb       = lerp_vec3(MOON_BLUE, DAWN_GOLD, f);
        intensity = lerp_scalar(I_NIGHT, I_HORIZON, f);
    }
    return { rgb.x, rgb.y, rgb.z, intensity };
}

// Dim neutral sky-fill: cooler+dimmer at night, warmer+brighter at day.
// Lerp on sun elevation so pre-dawn and dusk blend smoothly.
//   night (e <= 0): (0.18, 0.20, 0.24) @ 0.35
//   day   (e >= 1): (0.45, 0.48, 0.52) @ 0.55
fn core::Vec4 ambient_color_for(float t)
{
    const core::Vec3 AMB_NIGHT = { 0.18f, 0.20f, 0.24f };
    const core::Vec3 AMB_DAY   = { 0.45f, 0.48f, 0.52f };
    const float      I_NIGHT   = 0.35f;
    const float      I_DAY     = 0.55f;

    float elevation = (float)math::sin(wrap01(t) * 2.0f * (float)math::PI);
    float f = elevation * 0.5f + 0.5f;
    if (f < 0.0f) f = 0.0f;
    if (f > 1.0f) f = 1.0f;

    core::Vec3 rgb = lerp_vec3(AMB_NIGHT, AMB_DAY, f);
    float      intensity = lerp_scalar(I_NIGHT, I_DAY, f);
    return { rgb.x, rgb.y, rgb.z, intensity };
}

// --- Internal helpers ----------------------------------------------------

fn float wrap01(float v) @local
{
    float w = v - (float)math::floor(v);
    if (w < 0.0f) w += 1.0f;
    if (w >= 1.0f) w -= 1.0f;
    return w;
}

fn float lerp_scalar(float a, float b, float f) @local @inline
{
    return a + (b - a) * f;
}

fn core::Vec3 lerp_vec3(core::Vec3 a, core::Vec3 b, float f) @local @inline
{
    return {
        a.x + (b.x - a.x) * f,
        a.y + (b.y - a.y) * f,
        a.z + (b.z - a.z) * f,
    };
}
