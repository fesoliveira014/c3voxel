module c3voxel::world;

import std::core::mem::alloc;

import c3voxel::core;
import c3voxel::core::noise;
import c3voxel::gpu;

const float TERRAIN_NOISE_SCALE = 0.004;

fn void generate_heightmap_cpu(Allocator allocator, Block* block, uint seed)
{
    int n = BLOCK_HEIGHTMAP_PIXELS;
    float[] buf = block.heightmap_cpu;

    for (int z = 0; z < n; z++) {
        for (int x = 0; x < n; x++) {
            float fx = (float)((int)block.cx * n + x) * TERRAIN_NOISE_SCALE;
            float fz = (float)((int)block.cz * n + z) * TERRAIN_NOISE_SCALE;
            float h = noise::fbm2(fx, fz, 4, 0.5, 2.0, seed);
            buf[z * n + x] = h * 0.5 + 0.5;
        }
    }

    gpu::texture2d_upload(block.heightmap, buf.ptr, gpu::Format.R32F, 0, 0, 0, n, n);
    block.heightmap_dirty = false;
}
