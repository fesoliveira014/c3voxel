// Octahedral unit-vector packing — Cigolle, Donow, Evangelakos, Mara,
// McGuire & Meyer, "A Survey of Efficient Representations for Independent
// Unit Vectors", JCGT 2014. 8 bits per channel is enough for shading
// (max ~2° angular error).
//
// Both functions round-trip unit vectors through a [0, 1]^2 square so the
// packed value stores naturally in an RG8 texture.
#ifndef C3VOXEL_OCTAHEDRAL_GLSL
#define C3VOXEL_OCTAHEDRAL_GLSL

vec2 octahedral_sign_not_zero(vec2 v) {
    return vec2(
        v.x >= 0.0 ? 1.0 : -1.0,
        v.y >= 0.0 ? 1.0 : -1.0);
}

// Unit vector -> [0,1]^2. Assumes length(n) > 0; the caller should guard
// zero-length inputs with a fallback normal.
vec2 octahedral_pack(vec3 n)
{
    n /= (abs(n.x) + abs(n.y) + abs(n.z));
    vec2 p = n.xy;
    if (n.z < 0.0) {
        p = (1.0 - abs(p.yx)) * octahedral_sign_not_zero(p);
    }
    // [-1, 1]^2 -> [0, 1]^2. Reverse in unpack.
    return p * 0.5 + 0.5;
}

// [0,1]^2 -> unit vector. Always returns a normalized result.
vec3 octahedral_unpack(vec2 e)
{
    vec2 p = e * 2.0 - 1.0;
    vec3 n = vec3(p.x, p.y, 1.0 - abs(p.x) - abs(p.y));
    if (n.z < 0.0) {
        n.xy = (1.0 - abs(n.yx)) * octahedral_sign_not_zero(n.xy);
    }
    return normalize(n);
}

#endif // C3VOXEL_OCTAHEDRAL_GLSL
