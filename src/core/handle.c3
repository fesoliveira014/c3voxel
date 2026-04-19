module c3voxel::core;

const uint HANDLE_INDEX_MASK    = 0x00FF_FFFF;
const uint HANDLE_GEN_MASK      = 0xFF;
const uint HANDLE_INVALID_VALUE = 0xFFFF_FFFF;

macro uint handle_index(uint h) => h & HANDLE_INDEX_MASK;
macro uint handle_gen(uint h)   => (h >> 24) & HANDLE_GEN_MASK;

macro uint handle_pack(uint idx, uint gen)
    => ((gen & HANDLE_GEN_MASK) << 24) | (idx & HANDLE_INDEX_MASK);
