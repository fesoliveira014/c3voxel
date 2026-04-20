module c3voxel::world;

import std::core::mem::alloc;

import c3voxel::core;
import c3voxel::gpu;
import c3voxel::voxel;

const int BUILDING_TILE_PX       = 8;
const int BUILDING_GRID_X        = BLOCK_HEIGHTMAP_PIXELS / BUILDING_TILE_PX;   // 64
const int BUILDING_GRID_Z        = BUILDING_GRID_X;
const int BUILDING_GRID_Y        = 16;
const int BUILDING_NODE_DIRS     = 6;
const int BUILDING_NODE_LAYERS   = 2;
const int BUILDING_NODE_CONS     = BUILDING_NODE_DIRS * BUILDING_NODE_LAYERS;   // 12
const int BUILDING_HEIGHT_ITERS  = 16;
const int BLOCK_SIZE_IN_LOTS     = 8;
const int LOT_PX                 = BLOCK_SIZE_IN_LOTS * BUILDING_TILE_PX;       // 64
// 1.0 world units (was 0.5) so wall half-extent exceeds the voxel centre
// offset. With half_x = 0.5 the only two voxels inside the wall's AABB were
// pegged at d.x = 1.0 in the shader's superellipsoid test, and with p = 6
// the equation d.x^6 + d.y^6 + d.z^6 <= 1 always failed (d.x = 1 leaves no
// room for d.y/d.z). Walls rendered as literally zero voxels. At 1.0, voxel
// centres land at d.x = 0.5 (inside), giving solid two-voxel-thick walls.
const float WALL_RAD_M           = 1.0f;
const int BUILDING_NEW_SEA_LEV   = 2;
const int BUILDING_WALL_HEIGHT   = 3;    // tile-Y levels a wall extrudes above ground

enum ConType : char {
    NONE,
    ROAD,
    MAINHALL,
    WING,
    FOUNDATION,
    DOORWAY,
    WINDOWFRAME,
    LANTERN,
}
const int CON_TYPE_COUNT = 8;

enum ConClass : char {
    CTC_NONE,
    CTC_ROAD,
    CTC_WING,
    CTC_LIGHT,
}

const ConClass[CON_TYPE_COUNT] CON_TYPE_CLASSES = {
    ConClass.CTC_NONE,
    ConClass.CTC_ROAD,
    ConClass.CTC_WING,
    ConClass.CTC_WING,
    ConClass.CTC_WING,
    ConClass.CTC_WING,
    ConClass.CTC_WING,
    ConClass.CTC_LIGHT,
};

bitstruct ConFlags : uint {
    bool inside      : 0;
    bool wing_beg    : 1;
    bool wing_end    : 2;
}

struct BuildingCon @packed {
    ConType  con_type;
    char[3]  _pad;
    ConFlags flags;
    float    wing_mult;
    float    wall_rad_m;
    int      height_delta;
    int      direction;
}
$assert(BuildingCon.sizeof == 24);

struct BuildingNode @packed {
    BuildingCon[BUILDING_NODE_CONS] con;
    int    maze_index;
    int    id;
    int    visited;
    float  power_u;
    float  power_v;
    bool   near_terrain;
    bool   near_air;
    char[2] _pad;
}
$assert(BuildingNode.sizeof == 312);

struct MapNode @packed {
    float      adjusted_height;
    ConType[4] connection_props;
}
$assert(MapNode.sizeof == 8);

// Lifecycle. alloc::new_array panics on OOM (unwraps internally); a void
// return reflects reality. If recoverable OOM becomes a requirement (e.g.
// for memory-constrained embedded targets), switch to alloc::new_array_try.
fn void building_data_init(Block* block, Allocator allocator)
{
    usz n_nodes = (usz)(BUILDING_GRID_X * BUILDING_GRID_Z * BUILDING_GRID_Y);
    usz n_map   = (usz)(BUILDING_GRID_X * BUILDING_GRID_Z);
    block.building_data = alloc::new_array(allocator, BuildingNode, n_nodes);
    block.map_data      = alloc::new_array(allocator, MapNode, n_map);
    // alloc::new_array zero-initialises.
}

fn void building_data_free(Block* block, Allocator allocator)
{
    if (block.building_data.len != 0) {
        alloc::free(allocator, block.building_data.ptr);
        block.building_data = {};
    }
    if (block.map_data.len != 0) {
        alloc::free(allocator, block.map_data.ptr);
        block.map_data = {};
    }
}

fn void building_data_clear(Block* block)
{
    for (usz i = 0; i < block.building_data.len; i++) block.building_data[i] = {};
    for (usz i = 0; i < block.map_data.len; i++)      block.map_data[i]      = {};
}

// Phase 1: populate map_data from block.road.pixels + block.heightmap_cpu.
// Road tiles get all four connection_props tagged ROAD and adjusted_height
// clamped to 0 (roads don't drive building height). Non-road tiles seed
// adjusted_height from heightmap_cpu, rescaled from world units to tile
// units so subsequent phases can reason in tile-Y.
fn void build_map_data(Block* block)
{
    int pitch    = BLOCK_HEIGHTMAP_PIXELS;
    int hm_pitch = pitch;
    for (int j = 0; j < BUILDING_GRID_Z; j++) {
        for (int i = 0; i < BUILDING_GRID_X; i++) {
            int cx_px = i * BUILDING_TILE_PX + BUILDING_TILE_PX / 2;
            int cz_px = j * BUILDING_TILE_PX + BUILDING_TILE_PX / 2;
            MapNode* m = &block.map_data[j * BUILDING_GRID_X + i];
            char road_bit = block.road.pixels[cz_px * pitch + cx_px] & (char)ROAD_BIT;
            if (road_bit != 0) {
                m.connection_props[0] = ConType.ROAD;
                m.connection_props[1] = ConType.ROAD;
                m.connection_props[2] = ConType.ROAD;
                m.connection_props[3] = ConType.ROAD;
                m.adjusted_height = 0.0f;
            } else {
                float h01 = block.heightmap_cpu[cz_px * hm_pitch + cx_px];
                // MAX_HEIGHT is 128 world units; tile height units = world/TILE_PX.
                m.adjusted_height = h01 * 128.0f / (float)BUILDING_TILE_PX;
                m.connection_props[0] = ConType.NONE;
                m.connection_props[1] = ConType.NONE;
                m.connection_props[2] = ConType.NONE;
                m.connection_props[3] = ConType.NONE;
            }
        }
    }
}

// Flat index into the 3D building_data grid (x-major, then z, then y).
// Callers clamp to grid bounds; this helper does no bounds checking.
fn int node_index(int i, int j, int k)
{
    return k * BUILDING_GRID_X * BUILDING_GRID_Z + j * BUILDING_GRID_X + i;
}

// Wires a connection between two adjacent (or vertically offset) tile nodes
// by writing reciprocal BuildingCon entries into each endpoint's `con` slot.
// Base direction is derived from the endpoint delta (+X=0, -X=1, +Y=2, -Y=3,
// +Z=4, -Z=5); the return-facing slot at ep2 is the XOR-1 partner. Out-of-
// bounds endpoints are silently dropped so phase walkers don't need to
// pre-clip against the grid edge.
fn void connect_nodes(
    Block* block,
    int i1, int j1, int k1,
    int i2, int j2, int k2,
    int dest_k,
    ConType con_type,
    int direction,
    int height_delta,
    int axis_layer,
    float wall_rad_m,
    ConFlags flags)
{
    int base_dir;
    int dx = i2 - i1;
    int dy = k2 - k1;
    int dz = j2 - j1;
    if (dx == 1 && dy == 0 && dz == 0) {
        base_dir = 0;
    } else if (dx == -1 && dy == 0 && dz == 0) {
        base_dir = 1;
    } else if (dx == 0 && dy == 1 && dz == 0) {
        base_dir = 2;
    } else if (dx == 0 && dy == -1 && dz == 0) {
        base_dir = 3;
    } else if (dx == 0 && dy == 0 && dz == 1) {
        base_dir = 4;
    } else if (dx == 0 && dy == 0 && dz == -1) {
        base_dir = 5;
    } else {
        return;
    }

    if (i1 < 0 || i1 >= BUILDING_GRID_X || j1 < 0 || j1 >= BUILDING_GRID_Z || k1 < 0 || k1 >= BUILDING_GRID_Y) return;
    if (i2 < 0 || i2 >= BUILDING_GRID_X || j2 < 0 || j2 >= BUILDING_GRID_Z || k2 < 0 || k2 >= BUILDING_GRID_Y) return;

    int ep1_slot = axis_layer * BUILDING_NODE_DIRS + base_dir;
    int ep2_slot = axis_layer * BUILDING_NODE_DIRS + (base_dir ^ 1);

    BuildingCon* c1 = &block.building_data[node_index(i1, j1, k1)].con[ep1_slot];
    BuildingCon* c2 = &block.building_data[node_index(i2, j2, k2)].con[ep2_slot];

    c1.con_type     = con_type;
    c1.flags        = flags;
    c1.wing_mult    = 1.0f;
    c1.wall_rad_m   = wall_rad_m;
    c1.height_delta = height_delta;
    c1.direction    = direction;

    c2.con_type     = con_type;
    c2.flags        = flags;
    c2.wing_mult    = 1.0f;
    c2.wall_rad_m   = wall_rad_m;
    c2.height_delta = height_delta;
    c2.direction    = -direction;
}

// Phase 2: walk the 8×8 lot grid, hash a per-lot seed for building count and
// per-building footprint/position, then stamp MAINHALL (centre) + WING (rest)
// into map_data.connection_props. The 7×7 interior lot is bounded by the
// surrounding road ring at tiles (lot_i*8, lot_j*8) etc.
fn void select_buildings(Block* block, uint world_seed)
{
    int num_lots = BUILDING_GRID_X / BLOCK_SIZE_IN_LOTS;
    for (int lot_j = 0; lot_j < num_lots; lot_j++) {
        for (int lot_i = 0; lot_i < num_lots; lot_i++) {
            int ox = lot_i * BLOCK_SIZE_IN_LOTS + 1;
            int oz = lot_j * BLOCK_SIZE_IN_LOTS + 1;
            int lw = BLOCK_SIZE_IN_LOTS - 1;   // 7
            int lh = BLOCK_SIZE_IN_LOTS - 1;

            uint lot_seed = voxel::voronoi_hash(
                (uint)(int)block.cx, (uint)(int)block.cz,
                world_seed, (uint)(lot_i * 11 + lot_j * 13));
            int num_buildings = 1 + (int)((lot_seed >> 0) & 0x3u);

            for (int b = 0; b < num_buildings; b++) {
                uint b_seed = voxel::voronoi_hash(lot_seed, 0u, 0u, (uint)b);
                int foot_w = 2 + (int)((b_seed >> 0) & 0x1u);
                int foot_h = 2 + (int)((b_seed >> 8) & 0x1u);
                if (lw - foot_w - 1 <= 0 || lh - foot_h - 1 <= 0) continue;
                int pos_i = ox + 1 + (int)((b_seed >> 16) % (uint)(lw - foot_w));
                int pos_j = oz + 1 + (int)((b_seed >> 24) % (uint)(lh - foot_h));

                // Footprint must not overlap anything already tagged.
                bool blocked = false;
                for (int jj = pos_j; jj < pos_j + foot_h && !blocked; jj++) {
                    for (int ii = pos_i; ii < pos_i + foot_w && !blocked; ii++) {
                        if (ii < 0 || ii >= BUILDING_GRID_X || jj < 0 || jj >= BUILDING_GRID_Z) { blocked = true; break; }
                        MapNode* m = &block.map_data[jj * BUILDING_GRID_X + ii];
                        for (int d = 0; d < 4; d++) {
                            if (m.connection_props[d] != ConType.NONE) { blocked = true; break; }
                        }
                    }
                }
                if (blocked) continue;

                int centre_i = pos_i + foot_w / 2;
                int centre_j = pos_j + foot_h / 2;
                for (int jj = pos_j; jj < pos_j + foot_h; jj++) {
                    for (int ii = pos_i; ii < pos_i + foot_w; ii++) {
                        MapNode* m = &block.map_data[jj * BUILDING_GRID_X + ii];
                        ConType kind = (ii == centre_i && jj == centre_j) ? ConType.MAINHALL : ConType.WING;
                        m.connection_props[0] = kind;
                        m.connection_props[1] = kind;
                        m.connection_props[2] = kind;
                        m.connection_props[3] = kind;
                    }
                }
            }
        }
    }
}

// Phase 4: seed FOUNDATION connections where tile adjusted_height matches
// the vertical layer k. Only tiles tagged as ROAD/MAINHALL/WING participate;
// foundations wire axis_layer=0 so later phases can reason about load-bearing
// supports separately from the axis_layer=1 superstructure.
fn void phase_roads_and_buildings(Block* block)
{
    int[4] dir_x = { 1, -1, 0, 0 };
    int[4] dir_z = { 0, 0, 1, -1 };
    ConFlags empty_flags = {};
    for (int k = 0; k < BUILDING_GRID_Y; k++) {
        for (int j = 0; j < BUILDING_GRID_Z; j++) {
            for (int i = 0; i < BUILDING_GRID_X; i++) {
                MapNode* cur = &block.map_data[j * BUILDING_GRID_X + i];
                int test_val = (int)cur.adjusted_height;
                for (int m = 0; m < 4; m++) {
                    ConType cur_bt = cur.connection_props[m];
                    int ni = i + dir_x[m];
                    int nj = j + dir_z[m];
                    if (ni < 0 || ni >= BUILDING_GRID_X || nj < 0 || nj >= BUILDING_GRID_Z) continue;
                    int test_val_2 = (int)block.map_data[nj * BUILDING_GRID_X + ni].adjusted_height;
                    switch (cur_bt) {
                        case ConType.ROAD:
                        case ConType.MAINHALL:
                        case ConType.WING:
                            if (test_val == k + 1) {
                                connect_nodes(
                                    block,
                                    i, j, k,
                                    ni, nj, k + (test_val_2 - test_val),
                                    k + (test_val_2 - test_val),
                                    ConType.FOUNDATION,
                                    -1,
                                    test_val_2 - test_val,
                                    0,
                                    WALL_RAD_M + 1.0f,
                                    empty_flags);

                                // Superstructure: extrude wall framework
                                // upward for WING/MAINHALL tiles. Layer=1,
                                // WING cons that later phases upgrade to
                                // DOORWAY/WINDOWFRAME/LANTERN.
                                if (cur_bt == ConType.WING || cur_bt == ConType.MAINHALL) {
                                    for (int kk = k + 1; kk < k + 1 + BUILDING_WALL_HEIGHT && kk < BUILDING_GRID_Y; kk++) {
                                        if (ni < 0 || ni >= BUILDING_GRID_X || nj < 0 || nj >= BUILDING_GRID_Z) continue;
                                        connect_nodes(
                                            block,
                                            i, j, kk,
                                            ni, nj, kk,
                                            kk,
                                            cur_bt,    // preserves WING vs MAINHALL for DOORS phase
                                            1,
                                            0,
                                            1,         // axis_layer=1 (superstructure)
                                            WALL_RAD_M,
                                            empty_flags);
                                    }
                                }
                            }
                        default:
                            break;
                    }
                }
            }
        }
    }
}

// Phase 5: scan WING runs along X (base_dir 0) and Z (base_dir 4), tagging
// the run's endpoints with wing_beg / wing_end and fading wing_mult along
// the run so centre tiles taper. The axis_layer=1 (superstructure) slot for
// the matching base_dir receives the multiplier on every BuildingCon in
// the vertical column at that tile — this drives shader-side wall silhouettes.
fn void phase_wing_tips(Block* block)
{
    // axis_dir 0 = run along +X. Each row j walks i=0..GRID_X, grouping
    // consecutive non-NONE WING tiles (connection_props[0]==WING).
    for (int j = 0; j < BUILDING_GRID_Z; j++) {
        int i = 0;
        while (i < BUILDING_GRID_X) {
            if (block.map_data[j * BUILDING_GRID_X + i].connection_props[0] != ConType.WING) {
                i++;
                continue;
            }
            int run_start = i;
            while (i < BUILDING_GRID_X &&
                   block.map_data[j * BUILDING_GRID_X + i].connection_props[0] == ConType.WING) {
                i++;
            }
            int n = i - run_start;
            if (n < 2) continue;

            float half = (float)(n - 1) * 0.5f;
            for (int s = 0; s < n; s++) {
                int ti = run_start + s;
                float wing_mult = 1.0f;
                if (n > 1) {
                    float d = (float)s - half;
                    if (d < 0.0f) d = -d;
                    wing_mult = 0.6f + 0.4f * (1.0f - d / half);
                }
                for (int k = 0; k < BUILDING_GRID_Y; k++) {
                    int slot0 = 1 * BUILDING_NODE_DIRS + 0;   // axis_layer=1, +X
                    int slot1 = 1 * BUILDING_NODE_DIRS + 1;   // axis_layer=1, -X
                    BuildingCon* c0 = &block.building_data[node_index(ti, j, k)].con[slot0];
                    BuildingCon* c1 = &block.building_data[node_index(ti, j, k)].con[slot1];
                    c0.wing_mult = wing_mult;
                    c1.wing_mult = wing_mult;
                    if (s == 0)       c1.flags.wing_beg = true;
                    if (s == n - 1)   c0.flags.wing_end = true;
                }
            }
        }
    }

    // axis_dir 2 = run along +Z. connection_props[2] is the +Z face tag.
    for (int i = 0; i < BUILDING_GRID_X; i++) {
        int j = 0;
        while (j < BUILDING_GRID_Z) {
            if (block.map_data[j * BUILDING_GRID_X + i].connection_props[2] != ConType.WING) {
                j++;
                continue;
            }
            int run_start = j;
            while (j < BUILDING_GRID_Z &&
                   block.map_data[j * BUILDING_GRID_X + i].connection_props[2] == ConType.WING) {
                j++;
            }
            int n = j - run_start;
            if (n < 2) continue;

            float half = (float)(n - 1) * 0.5f;
            for (int s = 0; s < n; s++) {
                int tj = run_start + s;
                float wing_mult = 1.0f;
                if (n > 1) {
                    float d = (float)s - half;
                    if (d < 0.0f) d = -d;
                    wing_mult = 0.6f + 0.4f * (1.0f - d / half);
                }
                for (int k = 0; k < BUILDING_GRID_Y; k++) {
                    int slot4 = 1 * BUILDING_NODE_DIRS + 4;   // axis_layer=1, +Z
                    int slot5 = 1 * BUILDING_NODE_DIRS + 5;   // axis_layer=1, -Z
                    BuildingCon* c4 = &block.building_data[node_index(i, tj, k)].con[slot4];
                    BuildingCon* c5 = &block.building_data[node_index(i, tj, k)].con[slot5];
                    c4.wing_mult = wing_mult;
                    c5.wing_mult = wing_mult;
                    if (s == 0)       c5.flags.wing_beg = true;
                    if (s == n - 1)   c4.flags.wing_end = true;
                }
            }
        }
    }
}

// Phase 6: scan every axis_layer=1 horizontal connection. If its con_type is
// WING and the facing neighbour's mapData tag is ROAD-classed, upgrade to
// DOORWAY. Otherwise leave it as WINDOWFRAME (marker) and attach a LANTERN
// pointing -Y from the same tile so downstream geometry can emit a lantern
// at the interior face. LANTERN fidelity is intentionally rough for M7.4;
// the M8 plan refines placement.
fn void phase_doors(Block* block)
{
    int[4] dir_x      = { 1, -1, 0, 0 };
    int[4] dir_z      = { 0,  0, 1, -1 };
    // CANONICAL base_dir encoding: +X=0, -X=1, +Y=2, -Y=3, +Z=4, -Z=5.
    // phase_doors iterates horizontal directions (m=0..3 in "NSEW" order)
    // which must be translated to the canonical slot indices. Earlier drafts
    // used `m` directly as the base_dir offset — this wrote +Z and -Z into
    // the +Y and -Y vertical slots, which emission never reads.
    int[4] base_dir_m = { 0, 1, 4, 5 };
    ConFlags empty_flags  = {};
    ConFlags inside_flags = { .inside = true };

    for (int k = 0; k < BUILDING_GRID_Y; k++) {
        for (int j = 0; j < BUILDING_GRID_Z; j++) {
            for (int i = 0; i < BUILDING_GRID_X; i++) {
                for (int m = 0; m < 4; m++) {
                    int base_dir = base_dir_m[m];
                    int slot = 1 * BUILDING_NODE_DIRS + base_dir;
                    BuildingCon cur = block.building_data[node_index(i, j, k)].con[slot];
                    if (cur.con_type != ConType.WING) continue;

                    int ni = i + dir_x[m];
                    int nj = j + dir_z[m];
                    if (ni < 0 || ni >= BUILDING_GRID_X || nj < 0 || nj >= BUILDING_GRID_Z) continue;

                    // Neighbour tile's map_data — roads get all 4
                    // connection_props[*] = ROAD in build_map_data, so the
                    // slot index doesn't matter for this check.
                    ConType nbr_bt = block.map_data[nj * BUILDING_GRID_X + ni].connection_props[0];
                    bool nbr_is_road = nbr_bt == ConType.ROAD;

                    ConType new_bt = nbr_is_road ? ConType.DOORWAY : ConType.WINDOWFRAME;
                    int cur_dir = (m % 2 == 0) ? 1 : -1;

                    // Use connect_nodes so both endpoints mirror. Lantern-
                    // hosting is signalled by the `inside` flag on the
                    // WINDOWFRAME connection itself (building_emit_to_page
                    // reads the flag and emits the lantern LineEntry).
                    ConFlags upgrade_flags = (!nbr_is_road && cur_dir == 1) ? inside_flags : empty_flags;
                    connect_nodes(
                        block,
                        i, j, k,
                        ni, nj, k,
                        k,
                        new_bt,
                        cur_dir,
                        0,
                        1,          // axis_layer = 1 (superstructure)
                        WALL_RAD_M,
                        upgrade_flags);
                }
            }
        }
    }
}

// Phase 7: build the 512×512 R16UI interior-occupancy mask from this block's
// building_data and upload it to `building_interior_tex`. Each pixel's
// ushort is a bitmask over 16 Y-layers; bit Y is set when that tile's
// footprint contains interior voxels at that Y. For M7.4 the wall height
// is a flat 3 Y-levels above the tile's adjusted_height.
//
// Memory: 512×512×2 = 512 KiB — allocated via the scratch allocator to keep
// the stack small.
fn void phase_fill_terrain(Block* block, Allocator scratch)
{
    const int PITCH = BLOCK_HEIGHTMAP_PIXELS;
    usz n_pixels = (usz)(PITCH * PITCH);
    ushort[] mask = alloc::new_array(scratch, ushort, n_pixels);
    defer if (mask.len != 0) alloc::free(scratch, mask.ptr);

    for (int j = 0; j < BUILDING_GRID_Z; j++) {
        for (int i = 0; i < BUILDING_GRID_X; i++) {
            // Find the highest k where this tile has a building connection.
            // Walk top-down and stop at the first hit.
            int hit_k = -1;
            for (int k = BUILDING_GRID_Y - 1; k >= 0; k--) {
                BuildingNode* n = &block.building_data[node_index(i, j, k)];
                bool is_building = false;
                for (int s = 0; s < BUILDING_NODE_CONS; s++) {
                    ConType t = n.con[s].con_type;
                    if (t == ConType.WING || t == ConType.WINDOWFRAME ||
                        t == ConType.DOORWAY || t == ConType.MAINHALL) {
                        is_building = true;
                        break;
                    }
                }
                if (is_building) { hit_k = k; break; }
            }
            if (hit_k < 0) continue;

            int adjusted_h = (int)block.map_data[j * BUILDING_GRID_X + i].adjusted_height;
            int y_lo = adjusted_h + 1;
            int y_hi = adjusted_h + BUILDING_WALL_HEIGHT;
            if (y_lo < 0) y_lo = 0;
            if (y_hi > 15) y_hi = 15;
            if (y_lo > y_hi) continue;
            ushort bits = 0;
            for (int y = y_lo; y <= y_hi; y++) bits |= (ushort)(1u << (uint)y);

            int px0 = i * BUILDING_TILE_PX;
            int pz0 = j * BUILDING_TILE_PX;
            for (int pz = pz0; pz < pz0 + BUILDING_TILE_PX; pz++) {
                for (int px = px0; px < px0 + BUILDING_TILE_PX; px++) {
                    mask[pz * PITCH + px] |= bits;
                }
            }
        }
    }

    gpu::texture2d_upload(
        block.building_interior_tex, mask.ptr, gpu::Format.R16UI,
        0, 0, 0, PITCH, PITCH);
}

// Phase 3: clamp neighbour height deltas to 1 tile and floor to the new sea
// level. Iterative because a single pass can leave cascading deltas; loop
// exits early once a pass makes no changes.
fn void smooth_heights(Block* block)
{
    int[4] dir_x = { 1, -1,  0,  0 };
    int[4] dir_z = { 0,  0,  1, -1 };
    for (int pass = 0; pass < BUILDING_HEIGHT_ITERS; pass++) {
        bool changed = false;
        for (int j = 0; j < BUILDING_GRID_Z; j++) {
            for (int i = 0; i < BUILDING_GRID_X; i++) {
                MapNode* m = &block.map_data[j * BUILDING_GRID_X + i];
                float p = m.adjusted_height;
                for (int d = 0; d < 4; d++) {
                    int ni = i + dir_x[d];
                    int nj = j + dir_z[d];
                    if (ni < 0 || ni >= BUILDING_GRID_X || nj < 0 || nj >= BUILDING_GRID_Z) continue;
                    float nh = block.map_data[nj * BUILDING_GRID_X + ni].adjusted_height;
                    if (nh > p) p = nh;
                }
                if (p - m.adjusted_height > 1.0f) {
                    m.adjusted_height = p - 1.0f;
                    changed = true;
                }
                if ((float)BUILDING_NEW_SEA_LEV > m.adjusted_height) {
                    m.adjusted_height = (float)BUILDING_NEW_SEA_LEV;
                    changed = true;
                }
            }
        }
        if (!changed) break;
    }
}

// Public entrypoint: wires all M7.4 phases together. Called by drain_dirty
// immediately after generate_roads_for_block so map_data can be derived
// from block.road.pixels + block.heightmap_cpu in phase 1. The phase order
// is load-bearing — selection depends on map_data seeded by phase 1; roads
// / wing tips / doors all read the connection_props set up by phase 2.
fn void buildings_generate_for_block(Block* block, Allocator scratch, uint world_seed)
{
    if (!block.buildings_dirty) return;
    building_data_clear(block);
    build_map_data(block);
    select_buildings(block, world_seed);
    smooth_heights(block);
    phase_roads_and_buildings(block);
    phase_wing_tips(block);
    phase_doors(block);
    phase_fill_terrain(block, scratch);
    block.buildings_dirty = false;
}

// Emit a block's buildings into a page's PageGeometry lists. Walks the 3D
// node grid for tiles whose world position falls inside `page.world_min..max`.
// For each non-NONE horizontal connection (base_dir 0 = +X, 4 = +Z only — the
// +axis halves to avoid double-emitting shared walls), write a GeomEntry
// sized as a wall segment at the shared tile edge.
//
// LANTERN connections emit a LineEntry. Walls at the top Y level (k+1 >=
// adjusted_height + wall_height) use SHINGLE material (flat roofs, per spec).
fn void building_emit_to_page(PageGeometry* out, Block* block, Page* page)
{
    if (block.building_data.len == 0) return;
    if (block.map_data.len == 0) return;

    float block_origin_x = (float)(int)block.cx * (float)BLOCK_HEIGHTMAP_PIXELS;
    float block_origin_z = (float)(int)block.cz * (float)BLOCK_HEIGHTMAP_PIXELS;

    // Page bounds in block-local tile coords. Clamp to grid so we don't index OOB.
    float page_local_x0 = page.world_min.x - block_origin_x;
    float page_local_z0 = page.world_min.z - block_origin_z;
    float page_local_x1 = page.world_max.x - block_origin_x;
    float page_local_z1 = page.world_max.z - block_origin_z;
    int tile_i0 = (int)(page_local_x0 / (float)BUILDING_TILE_PX);
    int tile_j0 = (int)(page_local_z0 / (float)BUILDING_TILE_PX);
    int tile_i1 = (int)((page_local_x1 + (float)BUILDING_TILE_PX - 1.0f) / (float)BUILDING_TILE_PX);
    int tile_j1 = (int)((page_local_z1 + (float)BUILDING_TILE_PX - 1.0f) / (float)BUILDING_TILE_PX);
    if (tile_i0 < 0) tile_i0 = 0;
    if (tile_j0 < 0) tile_j0 = 0;
    if (tile_i1 > BUILDING_GRID_X) tile_i1 = BUILDING_GRID_X;
    if (tile_j1 > BUILDING_GRID_Z) tile_j1 = BUILDING_GRID_Z;

    float tile_px_f = (float)BUILDING_TILE_PX;
    float wall_rad  = WALL_RAD_M;

    for (int j = tile_j0; j < tile_j1; j++) {
        for (int i = tile_i0; i < tile_i1; i++) {
            MapNode map_here = block.map_data[j * BUILDING_GRID_X + i];
            int base_height = (int)map_here.adjusted_height;

            for (int k = 0; k < BUILDING_GRID_Y; k++) {
                int node_idx = k * BUILDING_GRID_X * BUILDING_GRID_Z
                             + j * BUILDING_GRID_X + i;
                BuildingNode node = block.building_data[node_idx];

                for (int axis_layer = 0; axis_layer < BUILDING_NODE_LAYERS; axis_layer++) {
                    // +X (base_dir 0) and +Z (base_dir 4) only — avoids double emit.
                    int[2] base_dirs = { 0, 4 };
                    for (int bd_sel = 0; bd_sel < 2; bd_sel++) {
                        int base_dir = base_dirs[bd_sel];
                        int slot = axis_layer * BUILDING_NODE_DIRS + base_dir;
                        BuildingCon con = node.con[slot];
                        if (con.con_type == ConType.NONE) continue;
                        if (con.con_type == ConType.ROAD) continue;   // roads rendered via road_raster

                        int dx = base_dir == 0 ? 1 : 0;
                        int dz = base_dir == 4 ? 1 : 0;

                        // Wall position: midpoint of edge between (i, j) and neighbour.
                        float cx = block_origin_x + ((float)i + (float)dx * 0.5f + 0.5f) * tile_px_f;
                        float cz = block_origin_z + ((float)j + (float)dz * 0.5f + 0.5f) * tile_px_f;
                        float cy = ((float)k + 0.5f) * tile_px_f;

                        // Half-extents: thin along perpendicular axis, full tile along parallel.
                        float mult = con.wing_mult > 0.01f ? con.wing_mult : 1.0f;
                        float half_x = dx == 1 ? wall_rad : tile_px_f * 0.5f * mult;
                        float half_z = dz == 1 ? wall_rad : tile_px_f * 0.5f * mult;
                        float half_y = tile_px_f * 0.5f;

                        core::Vec4 bmin = { cx - half_x, cy - half_y, cz - half_z, 0.0f };
                        core::Vec4 bmax = { cx + half_x, cy + half_y, cz + half_z, 0.0f };

                        // Material: by con_type, plus SHINGLE override at top.
                        voxel::Material mat = voxel::Material.PLASTER;
                        switch (con.con_type) {
                            case ConType.FOUNDATION:   mat = voxel::Material.STONE;
                            case ConType.DOORWAY:      mat = voxel::Material.WOOD;
                            case ConType.WINDOWFRAME:  mat = voxel::Material.GLASS;
                            case ConType.MAINHALL:
                            case ConType.WING:         mat = voxel::Material.PLASTER;
                            case ConType.LANTERN:      continue;   // emitted below as LineEntry
                            default:                   mat = voxel::Material.PLASTER;
                        }
                        // Top-level tile: use SHINGLE at the single top wall level.
                        int roof_k = base_height + BUILDING_WALL_HEIGHT;
                        if (k == roof_k && mat == voxel::Material.PLASTER) {
                            mat = voxel::Material.SHINGLE;
                        }

                        voxel::GeomEntry e = {
                            .vis_min      = bmin,
                            .vis_max      = bmax,
                            .bounds_min   = bmin,
                            .bounds_max   = bmax,
                            .corner_dis   = { 0.0f, 0.0f, 0.0f, 0.0f },
                            .power_vals   = { 6.0f, 6.0f, 0.0f, 0.0f },
                            .power_vals_2 = { 0.0f, 0.0f, 0.0f, 0.0f },
                            .thick_vals   = { 0.0f, 0.0f, 0.0f, 0.0f },
                            .center_point = { cx, cy, cz, 0.0f },
                            .mat          = {
                                .material_id = (float)mat.ordinal,
                                .normal_id = 0.0f,
                                .modifier = 0.0f,
                                ._pad = 0.0f,
                            },
                        };
                        out.geom.push(e);

                        // Lantern: only on WINDOWFRAME connections whose
                        // `inside` flag is set (phase_doors marks only the
                        // +X/+Z side of each pair). One lantern per window,
                        // positioned slightly on the interior side of the
                        // wall midpoint.
                        if (con.con_type == ConType.WINDOWFRAME && con.flags.inside) {
                            float interior_off_x = dx == 1 ? -2.0f : 0.0f;
                            float interior_off_z = dz == 1 ? -2.0f : 0.0f;
                            float lx = cx + interior_off_x;
                            float lz = cz + interior_off_z;
                            float ly = cy;
                            core::Vec4 origin_v  = { lx, ly, lz, 0.0f };
                            core::Vec4 tangent_v = { 0.0f, 1.0f, 0.0f, 0.0f };
                            core::Vec4 lmin = { lx - 1.0f, ly - 1.0f, lz - 1.0f, 0.0f };
                            core::Vec4 lmax = { lx + 1.0f, ly + 1.0f, lz + 1.0f, 0.0f };
                            voxel::LineEntry l = {
                                .vis_min      = lmin,
                                .vis_max      = lmax,
                                .origin       = origin_v,
                                .tangent      = tangent_v,
                                .bitangent    = { 1.0f, 0.0f, 0.0f, 0.0f },
                                .normal       = { 0.0f, 0.0f, 1.0f, 0.0f },
                                .rad0         = { 0.3f, 0.0f, 0.0f, 0.0f },
                                .rad1         = { 0.5f, 0.0f, 0.0f, 0.0f },
                                .center_point = origin_v,
                                .mat          = {
                                    .material_id = (float)voxel::Material.METAL.ordinal,
                                    .normal_id = 0.0f,
                                    .modifier = 0.0f,
                                    ._pad = 0.0f,
                                },
                            };
                            out.line.push(l);
                        }
                    }
                }
            }
        }
    }
}
