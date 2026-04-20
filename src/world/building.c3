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
