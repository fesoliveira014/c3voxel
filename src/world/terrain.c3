module c3voxel::world;

import std::core::mem::alloc;

import c3voxel::core;
import c3voxel::core::noise;
import c3voxel::gpu;

const float TERRAIN_NOISE_SCALE = 0.004;

// Also the flat value used when `--flat-terrain` (or `-f`) is passed on
// the command line. Picked so the resulting surface sits above
// WATER_LEVEL_Y=16 but below the volume top (y=128). Doubles as the
// fallback for out-of-block samples where no fbm2 source exists.
const float FLAT_TERRAIN_H01 = 0.25;

// Module-level flag flipped by `terrain_set_flat(bool)` once at startup
// from main()'s arg parsing. Both generate_heightmap_cpu and
// terrain_h01_at consult it so the CPU heightmap, cross-page tree
// placement, and road out-of-bounds sampling all agree on the surface
// model. Read-only in the draw loop (no races). snake_case because the
// C3 compiler flags SCREAMING_SNAKE_CASE on a `var` as a missing
// `const`.
bool flat_terrain_enabled = false;

fn void terrain_set_flat(bool enabled)
{
    flat_terrain_enabled = enabled;
}

// Deterministic h01 at any world (wx, wz). Matches the fbm2 formula
// used in generate_heightmap_cpu so callers that only have world
// coordinates (cross-page trees, off-block road samples) see the same
// surface height the block's CPU heightmap would have produced.
// Short-circuits to FLAT_TERRAIN_H01 when `--flat-terrain` is active.
fn float terrain_h01_at(float wx, float wz, uint seed) @inline
{
    if (flat_terrain_enabled) return FLAT_TERRAIN_H01;
    float fx = wx * TERRAIN_NOISE_SCALE;
    float fz = wz * TERRAIN_NOISE_SCALE;
    float h  = noise::fbm2(fx, fz, 4, 0.5f, 2.0f, seed);
    return h * 0.5f + 0.5f;
}

fn void generate_heightmap_cpu(Allocator allocator, Block* block, uint seed)
{
    int n = BLOCK_HEIGHTMAP_PIXELS;
    float[] buf = block.heightmap_cpu;

    for (int z = 0; z < n; z++) {
        for (int x = 0; x < n; x++) {
            float wx = (float)((int)block.cx * n + x);
            float wz = (float)((int)block.cz * n + z);
            buf[z * n + x] = terrain_h01_at(wx, wz, seed);
        }
    }

    gpu::texture2d_upload(block.heightmap, buf.ptr, gpu::Format.R32F, 0, 0, 0, n, n);
    block.heightmap_dirty = false;
}
