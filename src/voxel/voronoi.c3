module c3voxel::voxel;

import c3voxel::core;
import c3voxel::world;

const int VORONOI_SEEDS_PER_PAGE = 27;   // 3×3×3 grid

// std140 layout — see docs/ubo-convention.md.
// Promotion path: if a 6th UBO appears, convert to an @std140 macro that
// walks fields and emits per-field offset asserts automatically.
struct VoronoiParams @packed @align(16) {
    core::Vec4[VORONOI_SEEDS_PER_PAGE] seeds;   // xyz = world pos; w = seed id
}
$assert(VoronoiParams.sizeof % 16 == 0);

// xorshift-style 32-bit hash seeded from (page coord, cell index).
fn uint voronoi_hash(uint x, uint y, uint z, uint cell) @local
{
    uint h = x * 0x9E3779B1u;
    h ^= (h >> 16) ^ (y * 0x85EBCA77u);
    h ^= (h >> 13) ^ (z * 0xC2B2AE3Du);
    h ^= (h >> 16) ^ (cell * 0x27D4EB2Fu);
    h ^= (h >> 15);
    return h;
}

// [0, 1) float from a uint hash.
fn float voronoi_frand(uint h) @local
{
    // 24-bit mantissa region, divided by 2^24
    return (float)(h & 0x00FFFFFFu) / (float)(1u << 24);
}

// Deterministic 27 seeds for a page. Cell centers lie at (1/6, 1/2, 5/6)
// fractions along each axis of the page AABB; each center is perturbed by
// ±0.4 of its cell's extent.
fn VoronoiParams voronoi_for_page(world::Page* page)
{
    VoronoiParams out;
    core::Vec3 pmin = { page.world_min.x, page.world_min.y, page.world_min.z };
    core::Vec3 pmax = { page.world_max.x, page.world_max.y, page.world_max.z };
    core::Vec3 size = { pmax.x - pmin.x, pmax.y - pmin.y, pmax.z - pmin.z };
    core::Vec3 cell = { size.x / 3.0f, size.y / 3.0f, size.z / 3.0f };
    core::Vec3 perturb = { cell.x * 0.4f, cell.y * 0.4f, cell.z * 0.4f };

    // Coordinate hash seed: derive from integer page coords directly — avoids
    // float-precision collisions that could occur at large world offsets
    // (>2^23) if we truncated world_min.x back to int.
    uint px = (uint)(int)page.px;
    uint py = 0u;
    uint pz = (uint)(int)page.pz;

    int idx = 0;
    for (int cz = 0; cz < 3; cz++) {
        for (int cy = 0; cy < 3; cy++) {
            for (int cx = 0; cx < 3; cx++) {
                uint h0 = voronoi_hash(px, py, pz, (uint)(idx * 3 + 0));
                uint h1 = voronoi_hash(px, py, pz, (uint)(idx * 3 + 1));
                uint h2 = voronoi_hash(px, py, pz, (uint)(idx * 3 + 2));
                float ox = (voronoi_frand(h0) * 2.0f - 1.0f) * perturb.x;
                float oy = (voronoi_frand(h1) * 2.0f - 1.0f) * perturb.y;
                float oz = (voronoi_frand(h2) * 2.0f - 1.0f) * perturb.z;
                float cx_f = pmin.x + (cx + 0.5f) * cell.x + ox;
                float cy_f = pmin.y + (cy + 0.5f) * cell.y + oy;
                float cz_f = pmin.z + (cz + 0.5f) * cell.z + oz;
                uint id_h = voronoi_hash(px, py, pz, (uint)(idx + 1000u));
                out.seeds[idx] = { cx_f, cy_f, cz_f, (float)(id_h & 0xFFFFu) };
                idx++;
            }
        }
    }
    return out;
}
