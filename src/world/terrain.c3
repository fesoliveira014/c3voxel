module c3voxel::world;

import std::core::mem::alloc;

import c3voxel::core;
import c3voxel::core::noise;
import c3voxel::gpu;

const float TERRAIN_NOISE_SCALE = 0.004;

// Flat-terrain h01. Surface world-y = FLAT_TERRAIN_H01 * MAX_HEIGHT (128).
// 0.25 → y=32 puts the ground above WATER_LEVEL_Y=16 (so trees still
// qualify) and below the volume top (y=128), leaving ~96 voxels of air
// for walls, trees, and compositing headroom.
const float FLAT_TERRAIN_H01 = 0.25;

fn void generate_heightmap_cpu(Allocator allocator, Block* block, uint seed)
{
    int n = BLOCK_HEIGHTMAP_PIXELS;
    float[] buf = block.heightmap_cpu;

    for (int z = 0; z < n; z++) {
        for (int x = 0; x < n; x++) {
            buf[z * n + x] = FLAT_TERRAIN_H01;
        }
    }

    gpu::texture2d_upload(block.heightmap, buf.ptr, gpu::Format.R32F, 0, 0, 0, n, n);
    block.heightmap_dirty = false;
}
