module c3voxel::world;

import std::core::mem;
import std::core::mem::alloc;
import std::math;

import c3voxel::core;
import c3voxel::core::noise;
import c3voxel::gpu;
import c3voxel::voxel;

// TERRAIN_NOISE_SCALE + the hard-coded fbm2 params below MUST mirror
// `src/world/terrain.c3::generate_heightmap_cpu` so off-block heightmap
// samples (below) agree with the persistent in-block buffer.

const uint  ROAD_BIT             = 0x01u;    // surface pixel is part of any road
const int   MAZE_CELL_PX         = 8;         // 16 cells x 8 px = 128 px footprint
const int   MAZE_MAX_CELLS       = 32;        // max cells per maze axis (supports footprints up to 256 px)
const int   CITY_SPARSITY        = 4;         // one city per CITY_SPARSITY^2 blocks
const int   CITY_DEFAULT_SIZE_PX = 128;       // default city footprint in world pixels
const int   INTER_NUM_TRIES      = 16;        // candidate midpoints per recursion level
const int   INTER_MAX_GEN        = 10;        // hard cap on midpoint recursion depth
const int   WATER_PENALTY        = 64;        // cost units per below-sea pixel
const float WATER_SEA_LEVEL_NORM = 0.25f;     // normalised heightmap h < this counts as water

struct RoadRaster {
    char[]    pixels;              // BLOCK_HEIGHTMAP_PIXELS^2 bytes
    bool      initialized;
    Allocator allocator;
}

fn void RoadRaster.init(&self, Allocator allocator)
{
    if (self.initialized) return;
    usz n = (usz)(BLOCK_HEIGHTMAP_PIXELS * BLOCK_HEIGHTMAP_PIXELS);
    self.allocator   = allocator;
    self.pixels      = alloc::new_array(allocator, char, n);
    self.initialized = true;
    self.clear();
}

fn void RoadRaster.clear(&self)
{
    if (!self.initialized) return;
    for (usz i = 0; i < self.pixels.len; i++) self.pixels[i] = 0;
}

fn void RoadRaster.free(&self)
{
    if (!self.initialized) return;
    if (self.pixels.len != 0) alloc::free(self.allocator, self.pixels.ptr);
    self.pixels      = {};
    self.allocator   = null;
    self.initialized = false;
}

// Positive-modulo hash check: a block (cx, cz) hosts a city iff both
// coords fall on the CITY_SPARSITY-spaced lattice.
fn bool block_has_city(BlockCoord cx, BlockCoord cz)
{
    int ix = (int)cx;
    int iz = (int)cz;
    if (((ix % CITY_SPARSITY) + CITY_SPARSITY) % CITY_SPARSITY != 0) return false;
    if (((iz % CITY_SPARSITY) + CITY_SPARSITY) % CITY_SPARSITY != 0) return false;
    return true;
}

// Returns the city footprint in world pixels. Constant for M7.3; plumbing
// exists so later milestones can drive size from a hash.
fn int city_size_for_block(BlockCoord cx, BlockCoord cz)
{
    return CITY_DEFAULT_SIZE_PX;
}

// Bresenham line drawing with per-pixel bounds clipping. Pixels outside
// [0, pitch) are silently skipped; this lets callers emit segments whose
// endpoints land in neighbour blocks without extra clipping logic.
fn void draw_segment(RoadRaster* r, int x1, int z1, int x2, int z2, char flag_bits) @local
{
    int pitch = BLOCK_HEIGHTMAP_PIXELS;
    int dx =  math::abs(x2 - x1);
    int dz = -math::abs(z2 - z1);
    int sx = x1 < x2 ? 1 : -1;
    int sz = z1 < z2 ? 1 : -1;
    int err = dx + dz;
    int x = x1;
    int z = z1;
    while (true) {
        if (x >= 0 && x < pitch && z >= 0 && z < pitch) {
            r.pixels[z * pitch + x] |= flag_bits;
        }
        if (x == x2 && z == z2) break;
        int e2 = 2 * err;
        if (e2 >= dz) { err += dz; x += sx; }
        if (e2 <= dx) { err += dx; z += sz; }
    }
}

// Heightmap sample in normalised [0, 1] space at block-local pixel (px, pz).
// Inside the block: direct array lookup. Outside: re-derive via fbm2 with the
// same parameters terrain.c3 uses, so both endpoints of a cross-block road
// agree on the cost of off-block pixels. Mirrors the sampling in
// generate_heightmap_cpu; any change there must mirror here.
fn float sample_heightmap_cpu(Block* block, int px, int pz) @local
{
    int pitch = BLOCK_HEIGHTMAP_PIXELS;
    if (px >= 0 && px < pitch && pz >= 0 && pz < pitch) {
        return block.heightmap_cpu[pz * pitch + px];
    }
    int world_x = (int)block.cx * pitch + px;
    int world_z = (int)block.cz * pitch + pz;
    float fx = (float)world_x * TERRAIN_NOISE_SCALE;
    float fz = (float)world_z * TERRAIN_NOISE_SCALE;
    float h = noise::fbm2(fx, fz, 4, 0.5f, 2.0f, 1337u);
    return h * 0.5f + 0.5f;
}

// Iterative stack-based DFS maze generator. Emits road pixels via Bresenham
// segments between cell centres; neighbour choice picks the unvisited cell
// with the smallest |Delta h| tiebreaker and skips cells below sea level.
fn void generate_maze(RoadRaster* r, Block* block, int center_px, int center_pz, int footprint_px, uint seed) @local
{
    int cells = footprint_px / MAZE_CELL_PX;
    if (cells < 2) return;
    if (cells > MAZE_MAX_CELLS) cells = MAZE_MAX_CELLS;

    bool[MAZE_MAX_CELLS * MAZE_MAX_CELLS] visited = {};
    int[MAZE_MAX_CELLS * MAZE_MAX_CELLS]  stack   = {};
    int stack_len = 0;

    int origin_x = center_px - footprint_px / 2;
    int origin_z = center_pz - footprint_pz_from(footprint_px);

    int start_i = cells / 2;
    int start_j = cells / 2;
    visited[start_j * cells + start_i] = true;
    stack[stack_len++] = start_j * cells + start_i;

    int[4] dir_dx = { 1, -1, 0, 0 };
    int[4] dir_dz = { 0, 0, 1, -1 };
    uint local_counter = 0u;

    while (stack_len > 0) {
        int top     = stack[stack_len - 1];
        int curr_i  = top % cells;
        int curr_j  = top / cells;
        int curr_cx = origin_x + curr_i * MAZE_CELL_PX + MAZE_CELL_PX / 2;
        int curr_cz = origin_z + curr_j * MAZE_CELL_PX + MAZE_CELL_PX / 2;
        float curr_h = sample_heightmap_cpu(block, curr_cx, curr_cz);

        // Deterministic randomised neighbour order: hash(seed, cell_index, counter).
        uint ord_h = voxel::voronoi_hash((uint)top, seed, local_counter, 1337u);
        local_counter += 1u;
        int[4] order = { 0, 1, 2, 3 };
        // Fisher-Yates on 4 elements with bits of ord_h supplying each swap index.
        for (int i = 3; i > 0; i--) {
            uint roll = ord_h & 0x3u;
            ord_h >>= 2;
            int j = (int)(roll % (uint)(i + 1));
            int tmp  = order[i];
            order[i] = order[j];
            order[j] = tmp;
        }

        int best_n = -1;
        float best_delta = 1e30f;
        for (int k = 0; k < 4; k++) {
            int d  = order[k];
            int ni = curr_i + dir_dx[d];
            int nj = curr_j + dir_dz[d];
            if (ni < 0 || ni >= cells || nj < 0 || nj >= cells) continue;
            if (visited[nj * cells + ni]) continue;

            int ncx = origin_x + ni * MAZE_CELL_PX + MAZE_CELL_PX / 2;
            int ncz = origin_z + nj * MAZE_CELL_PX + MAZE_CELL_PX / 2;
            float nh = sample_heightmap_cpu(block, ncx, ncz);
            if (nh < WATER_SEA_LEVEL_NORM) continue;

            float delta = (float)math::abs(nh - curr_h);
            if (delta < best_delta) {
                best_delta = delta;
                best_n     = d;
            }
        }

        if (best_n < 0) {
            stack_len--;
            continue;
        }

        int ni = curr_i + dir_dx[best_n];
        int nj = curr_j + dir_dz[best_n];
        int ncx = origin_x + ni * MAZE_CELL_PX + MAZE_CELL_PX / 2;
        int ncz = origin_z + nj * MAZE_CELL_PX + MAZE_CELL_PX / 2;
        draw_segment(r, curr_cx, curr_cz, ncx, ncz, (char)ROAD_BIT);
        visited[nj * cells + ni] = true;
        stack[stack_len++] = nj * cells + ni;
    }
}

// Helper: footprint origin z offset. Kept factored for symmetry with x so
// future non-square footprints can diverge here without touching the caller.
fn int footprint_pz_from(int footprint_px) @local
{
    return footprint_px / 2;
}

// Deterministic [0, 1) stream keyed on (base_seed, counter). Mirrors the
// same (hash, frand) pairing plant_gen uses, but keeps road generation
// independent of the plant counter so the two don't alias.
fn float road_frand(uint base_seed, uint* counter) @local
{
    uint h = voxel::voronoi_hash(base_seed, 0u, 0u, *counter);
    *counter += 1u;
    return voxel::voronoi_frand(h);
}

// Bresenham walk summing |Delta h| between consecutive pixels plus
// WATER_PENALTY per below-sea pixel. O(segment_length) array lookups; used
// by best_path_draw to score candidate midpoints.
fn float weigh_path(Block* block, int x1, int z1, int x2, int z2) @local
{
    int dx =  math::abs(x2 - x1);
    int dz = -math::abs(z2 - z1);
    int sx = x1 < x2 ? 1 : -1;
    int sz = z1 < z2 ? 1 : -1;
    int err = dx + dz;
    int x = x1;
    int z = z1;

    float prev_h = sample_heightmap_cpu(block, x, z);
    float cost = 0.0f;
    if (prev_h < WATER_SEA_LEVEL_NORM) cost += (float)WATER_PENALTY;

    while (!(x == x2 && z == z2)) {
        int e2 = 2 * err;
        if (e2 >= dz) { err += dz; x += sx; }
        if (e2 <= dx) { err += dx; z += sz; }

        float h = sample_heightmap_cpu(block, x, z);
        cost += (float)math::abs(h - prev_h);
        if (h < WATER_SEA_LEVEL_NORM) cost += (float)WATER_PENALTY;
        prev_h = h;
    }
    return cost;
}

// Recursive greedy midpoint displacement. Base case draws a Bresenham
// segment; recursive case picks the lowest-cost of INTER_NUM_TRIES random
// midpoints and recurses on each half. Segments whose endpoints lie outside
// the block are clipped inside draw_segment; this is how cross-block roads
// stop cleanly at the 512-px boundary.
fn void best_path_draw(
    RoadRaster* r, Block* block,
    int x1, int z1, int x2, int z2,
    int gen, uint* counter, uint seed) @local
{
    float dx = (float)(x2 - x1);
    float dz = (float)(z2 - z1);
    float dist = (float)math::sqrt(dx * dx + dz * dz);
    float rad  = dist * 0.5f;

    if (rad < 2.0f || gen > INTER_MAX_GEN) {
        draw_segment(r, x1, z1, x2, z2, (char)ROAD_BIT);
        return;
    }

    int mid_x = (x1 + x2) / 2;
    int mid_z = (z1 + z2) / 2;

    int   best_x     = mid_x;
    int   best_z     = mid_z;
    float best_cost  = 1e30f;

    for (int i = 0; i < INTER_NUM_TRIES; i++) {
        float ox = (road_frand(seed, counter) - 0.5f) * rad;
        float oz = (road_frand(seed, counter) - 0.5f) * rad;
        int cand_x = mid_x + (int)ox;
        int cand_z = mid_z + (int)oz;
        float cost = weigh_path(block, x1, z1, cand_x, cand_z)
                   + weigh_path(block, cand_x, cand_z, x2, z2);
        if (cost < best_cost) {
            best_cost = cost;
            best_x    = cand_x;
            best_z    = cand_z;
        }
    }

    best_path_draw(r, block, x1, z1, best_x, best_z, gen + 1, counter, seed);
    best_path_draw(r, block, best_x, best_z, x2, z2, gen + 1, counter, seed);
}

// Canonical seed for a city-pair edge: key by the lexicographically-smaller
// endpoint so both endpoints (when resident) derive the same seed and trace
// the same line. `axis_tag` distinguishes N/S edges (0) from E/W edges (1).
fn uint canonical_edge_seed(int a_cx, int a_cz, int b_cx, int b_cz, uint axis_tag, uint world_seed) @local
{
    int lo_cx = a_cx < b_cx ? a_cx : b_cx;
    int lo_cz = a_cz < b_cz ? a_cz : b_cz;
    return voxel::voronoi_hash((uint)lo_cx, (uint)lo_cz, world_seed, axis_tag + 1u);
}

// Draws inter-city links for every city-pair edge touching this block. Both
// endpoints run best_path_draw from the canonical "origin" (smaller coord)
// toward the "target" (larger coord) in block-local pixels, using the same
// canonical_edge_seed. Because the algorithm is deterministic given the seed,
// both blocks trace the same integer line; draw_segment clips to this block's
// raster so each side only writes pixels inside its own boundary. Result:
// seamless cross-block roads even when only one side is resident.
//
// Checks all 4 axial neighbours; non-city partners are skipped. Diagonals are
// not connected (M7.3 scope).
fn void generate_inter_city_roads(RoadRaster* r, Block* block, uint world_seed) @local
{
    int self_cx = (int)block.cx;
    int self_cz = (int)block.cz;
    bool self_city = block_has_city(block.cx, block.cz);

    int center_px = BLOCK_HEIGHTMAP_PIXELS / 2;
    int center_pz = BLOCK_HEIGHTMAP_PIXELS / 2;

    int[4] dir_cx = { 0,  0,  CITY_SPARSITY, -CITY_SPARSITY };    // N, S, E, W
    int[4] dir_cz = { CITY_SPARSITY, -CITY_SPARSITY, 0,  0 };
    uint[4] axis  = { 0u, 0u, 1u, 1u };                            // NS, NS, EW, EW

    for (int d = 0; d < 4; d++) {
        int o_cx = self_cx + dir_cx[d];
        int o_cz = self_cz + dir_cz[d];
        if (!block_has_city((BlockCoord)o_cx, (BlockCoord)o_cz)) continue;
        if (!self_city) continue;    // only city blocks originate; partner is city by the check above

        // Canonical origin = smaller-coord endpoint. Canonical target = larger.
        int origin_cx = self_cx < o_cx ? self_cx : o_cx;
        int origin_cz = self_cz < o_cz ? self_cz : o_cz;
        int target_cx = self_cx < o_cx ? o_cx   : self_cx;
        int target_cz = self_cz < o_cz ? o_cz   : self_cz;

        // Translate origin/target city centres into THIS block's local pixels.
        int origin_px = center_px + (origin_cx - self_cx) * BLOCK_HEIGHTMAP_PIXELS;
        int origin_pz = center_pz + (origin_cz - self_cz) * BLOCK_HEIGHTMAP_PIXELS;
        int target_px = center_px + (target_cx - self_cx) * BLOCK_HEIGHTMAP_PIXELS;
        int target_pz = center_pz + (target_cz - self_cz) * BLOCK_HEIGHTMAP_PIXELS;

        uint edge_seed = canonical_edge_seed(self_cx, self_cz, o_cx, o_cz, axis[d], world_seed);
        uint counter = 0u;
        best_path_draw(r, block, origin_px, origin_pz, target_px, target_pz, 0, &counter, edge_seed);
    }
}

// Public entrypoint: regenerates this block's road raster from scratch and
// uploads it to the paired R8UI texture. Called by drain_dirty right after
// generate_heightmap_cpu so heightmap_cpu is primed when the maze /
// midpoint algorithms sample it. The `scratch` allocator is currently
// unused — reserved for future on-demand buffers (e.g. shipping lanes).
fn void generate_roads_for_block(Allocator scratch, Block* block, uint world_seed)
{
    block.road.clear();

    if (block_has_city(block.cx, block.cz)) {
        int footprint = city_size_for_block(block.cx, block.cz);
        int center_px = BLOCK_HEIGHTMAP_PIXELS / 2;
        int center_pz = BLOCK_HEIGHTMAP_PIXELS / 2;
        generate_maze(&block.road, block, center_px, center_pz, footprint, world_seed);
    }

    generate_inter_city_roads(&block.road, block, world_seed);

    gpu::texture2d_upload(
        block.road_texture, block.road.pixels.ptr, gpu::Format.R8UI,
        0, 0, 0, BLOCK_HEIGHTMAP_PIXELS, BLOCK_HEIGHTMAP_PIXELS);
}
