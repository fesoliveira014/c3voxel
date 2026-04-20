module c3voxel::world;

import std::core::mem::alloc;

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
const float WALL_RAD_M           = 0.5f;
const int BUILDING_NEW_SEA_LEV   = 2;

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

// Lifecycle. `init` returns void? so Block allocation can unwind on OOM.
fn void? building_data_init(Block* block, Allocator allocator)
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
                            }
                        default:
                            break;
                    }
                }
            }
        }
    }
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
