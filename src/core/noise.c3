module c3voxel::core::noise;

import std::math;

const float F2 = 0.36602540378443865f;
const float G2 = 0.21132486540518713f;

const float[<3>][12] GRAD2 = {
    { 1, 1, 0}, {-1, 1, 0}, { 1,-1, 0}, {-1,-1, 0},
    { 1, 0, 1}, {-1, 0, 1}, { 1, 0,-1}, {-1, 0,-1},
    { 0, 1, 1}, { 0,-1, 1}, { 0, 1,-1}, { 0,-1,-1},
};

fn uint hash_lattice(int ix, int iz, uint seed) @local
{
    uint h = seed;
    h ^= (uint)ix * 0x9E3779B9u;
    h  = (h << 13) | (h >> 19);
    h ^= (uint)iz * 0x85EBCA6Bu;
    h  = (h << 17) | (h >> 15);
    h ^= h >> 13;
    h *= 0xC2B2AE35u;
    h ^= h >> 16;
    return h;
}

fn float grad2_dot(int ix, int iz, float dx, float dz, uint seed) @local
{
    uint g = hash_lattice(ix, iz, seed) % 12;
    float[<3>] gv = GRAD2[g];
    return gv.x * dx + gv.y * dz;
}

fn float simplex2(float x, float z, uint seed)
{
    float s = (x + z) * F2;
    int   i = (int)math::floor(x + s);
    int   j = (int)math::floor(z + s);

    float t  = (float)(i + j) * G2;
    float x0 = x - ((float)i - t);
    float z0 = z - ((float)j - t);

    int i1 = x0 > z0 ? 1 : 0;
    int j1 = x0 > z0 ? 0 : 1;

    float x1 = x0 - (float)i1 + G2;
    float z1 = z0 - (float)j1 + G2;
    float x2 = x0 - 1.0f + 2.0f * G2;
    float z2 = z0 - 1.0f + 2.0f * G2;

    float n0 = 0;
    float n1 = 0;
    float n2 = 0;

    float t0 = 0.5f - x0 * x0 - z0 * z0;
    if (t0 > 0) {
        t0 *= t0;
        n0  = t0 * t0 * grad2_dot(i, j, x0, z0, seed);
    }
    float t1 = 0.5f - x1 * x1 - z1 * z1;
    if (t1 > 0) {
        t1 *= t1;
        n1  = t1 * t1 * grad2_dot(i + i1, j + j1, x1, z1, seed);
    }
    float t2 = 0.5f - x2 * x2 - z2 * z2;
    if (t2 > 0) {
        t2 *= t2;
        n2  = t2 * t2 * grad2_dot(i + 1, j + 1, x2, z2, seed);
    }

    return 70.0f * (n0 + n1 + n2);
}

fn float fbm2(float x, float z, int octaves = 4, float persistence = 0.5f, float lacunarity = 2.0f, uint seed = 0)
{
    float total         = 0;
    float frequency     = 1.0f;
    float amplitude     = 1.0f;
    float max_amplitude = 0;
    for (int i = 0; i < octaves; i++) {
        total         += simplex2(x * frequency, z * frequency, seed + (uint)i) * amplitude;
        max_amplitude += amplitude;
        frequency     *= lacunarity;
        amplitude     *= persistence;
    }
    return total / max_amplitude;
}

fn float simplex3(float x, float y, float z, uint seed)
{
    unreachable("simplex3 not implemented in M6 Phase 1 — see docs/noise-reference.md");
}

fn float simplex4(float x, float y, float z, float w, uint seed)
{
    unreachable("simplex4 not implemented in M6 Phase 1 — see docs/noise-reference.md");
}

fn float perlin2(float x, float z, uint seed)
{
    unreachable("perlin2 not implemented in M6 Phase 1 — simplex preferred, see docs/noise-reference.md");
}

fn float perlin3(float x, float y, float z, uint seed)
{
    unreachable("perlin3 not implemented in M6 Phase 1 — see docs/noise-reference.md");
}

fn float perlin4(float x, float y, float z, float w, uint seed)
{
    unreachable("perlin4 not implemented in M6 Phase 1 — see docs/noise-reference.md");
}

fn float fbm3(float x, float y, float z, int octaves, float persistence, float lacunarity, uint seed)
{
    unreachable("fbm3 not implemented in M6 Phase 1 — see docs/noise-reference.md");
}

fn float fbm4(float x, float y, float z, float w, int octaves, float persistence, float lacunarity, uint seed)
{
    unreachable("fbm4 not implemented in M6 Phase 1 — see docs/noise-reference.md");
}
