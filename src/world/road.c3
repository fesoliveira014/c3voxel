module c3voxel::world;

import std::core::mem;
import std::core::mem::alloc;

import c3voxel::core;

const uint  ROAD_BIT             = 0x01u;    // surface pixel is part of any road
const int   MAZE_CELL_PX         = 8;         // 16 cells x 8 px = 128 px footprint
const int   CITY_SPARSITY        = 4;         // one city per CITY_SPARSITY^2 blocks
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
