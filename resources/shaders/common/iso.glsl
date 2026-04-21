// Isometric forward/inverse math — GLSL mirror of the C3 code in
// `src/game/camera.c3::world_xz_to_screen` and
// `src/world/visibility.c3::screen_to_world_xz`, extended to carry world-y.
//
// The iso projection is y-up:
//   sx = zoom * ((wx - cx) - (wz - cz))
//   sy = zoom * (T * ((wx - cx) + (wz - cz)) + wy)
// where T = ISO_TILT = 0.2886751.
//
// Callers must define the following macros BEFORE `#include`ing this file:
//   ISO_PAN_TARGET  (vec3)   — world-space pan/target point (camera focus)
//   ISO_ZOOM        (float)  — zoom scale (pixels per world unit on the X axis)
//   ISO_RESOLUTION  (vec2)   — framebuffer resolution in pixels (fb_w, fb_h)
//
// `iso_forward(w)`   → screen UV in [0, 1]
// `iso_inverse(uv,h)`→ world XYZ at the given UV and world-height `h`.
#ifndef C3VOXEL_ISO_GLSL
#define C3VOXEL_ISO_GLSL

const float ISO_TILT_GLSL = 0.2886751;

// World XYZ -> screen UV in [0, 1]. Matches camera.c3::world_xz_to_screen,
// with the half-resolution offset that compute_holder_screen_rect applies
// after the fact so the result is suitable for sampler UVs.
vec2 iso_forward(vec3 w) {
    vec2 c = vec2(ISO_PAN_TARGET.x, ISO_PAN_TARGET.z);
    float sx = ISO_ZOOM * ((w.x - c.x) - (w.z - c.y));
    float sy = ISO_ZOOM * (ISO_TILT_GLSL * ((w.x - c.x) + (w.z - c.y)) + w.y);
    vec2 px = vec2(sx, sy) + ISO_RESOLUTION * 0.5;
    return px / ISO_RESOLUTION;
}

// Inverse of iso_forward with a user-supplied world height: given a UV on
// the G-buffer and the world-y at that pixel, recover world XYZ. Mirrors
// the algebra of screen_to_world_xz but solves for (dx, dz) in the
// height-adjusted plane instead of y=0.
vec3 iso_inverse(vec2 uv, float height) {
    vec2 px = uv * ISO_RESOLUTION - ISO_RESOLUTION * 0.5;
    float sx = px.x / ISO_ZOOM;
    float sy = px.y / ISO_ZOOM;
    // sy = T * (dx + dz) + height  →  dx + dz = (sy - height) / T.
    // sx = dx - dz.
    float sum  = (sy - height) / ISO_TILT_GLSL;
    float diff = sx;
    float dx = 0.5 * (diff + sum);
    float dz = 0.5 * (sum - diff);
    return vec3(ISO_PAN_TARGET.x + dx, height, ISO_PAN_TARGET.z + dz);
}

#endif // C3VOXEL_ISO_GLSL
