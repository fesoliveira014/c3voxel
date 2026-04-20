module c3voxel::world;

import std::core::mem::alloc;

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
