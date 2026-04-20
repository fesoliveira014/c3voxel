module c3voxel::world;

import std::collections::list;
import std::core::mem::alloc;

import c3voxel::core;
import c3voxel::gpu;

typedef BlockId = inline core::Handle;

const BlockId BLOCK_INVALID = (BlockId)core::HANDLE_INVALID_VALUE;

const int BLOCK_HEIGHTMAP_PIXELS = PIXELS_PER_PAGE * PAGES_PER_HOLDER * ACTIVE_HOLDERS_PER_AXIS;

struct Block {
    BlockCoord     cx;
    BlockCoord     cz;
    HolderId[HOLDERS_PER_BLOCK * HOLDERS_PER_BLOCK] holders;
    gpu::Texture2D heightmap;
    float[]        heightmap_cpu;    // persistent CPU copy, BLOCK_HEIGHTMAP_PIXELS² floats
    RoadRaster     road;
    gpu::Texture2D road_texture;     // R8UI, same dims as heightmap
    BuildingNode[] building_data;    // BUILDING_GRID_X * _Z * _Y; owned
    MapNode[]      map_data;          // BUILDING_GRID_X * _Z; owned
    bool           buildings_dirty;
    gpu::Texture2D building_interior_tex;
    bool           heightmap_dirty;
    int            holder_ref_count;
}

struct BlockSlot {
    Block block;
    char  generation;
    bool  alive;
}

alias BlockSlotList = List {BlockSlot};

struct BlockPool {
    BlockSlotList     storage;
    core::Ivec3IntMap lookup;
    Allocator         allocator;
}

fn void BlockPool.init(&self, Allocator allocator, usz capacity = 4)
{
    self.allocator = allocator;
    self.storage.init(allocator, capacity);
    self.lookup.init(allocator, (uint)capacity);
}

fn void BlockPool.destroy(&self)
{
    for (usz i = 0; i < self.storage.len(); i++) {
        BlockSlot* slot = &self.storage[i];
        if (slot.alive) {
            gpu::texture2d_destroy(slot.block.heightmap);
            gpu::texture2d_destroy(slot.block.road_texture);
            gpu::texture2d_destroy(slot.block.building_interior_tex);
            slot.block.building_interior_tex = gpu::TEXTURE2D_INVALID;
            if (slot.block.heightmap_cpu.len != 0) alloc::free(self.allocator, slot.block.heightmap_cpu.ptr);
            slot.block.road.free();
            building_data_free(&slot.block, self.allocator);
        }
    }
    self.storage.free();
    self.lookup.free();
    self.allocator = null;
}

// Look up or lazily create a block. Does NOT bump holder_ref_count —
// ref management is the caller's job (see `retain` / `decrement_ref`).
fn BlockId BlockPool.get_or_create(&self, BlockCoord cx, BlockCoord cz)
{
    core::IVec3 key = { (int)cx, 0, (int)cz };
    if (try found = self.lookup.get(key)) {
        usz idx = (usz)found;
        return (BlockId)core::handle_pack((uint)idx, (uint)self.storage[idx].generation);
    }

    gpu::Texture2D hm = gpu::texture2d_create({
        .width  = BLOCK_HEIGHTMAP_PIXELS,
        .height = BLOCK_HEIGHTMAP_PIXELS,
        .fmt    = gpu::Format.R32F,
        .levels = 1,
    });

    gpu::Texture2D road_tex = gpu::texture2d_create({
        .width  = BLOCK_HEIGHTMAP_PIXELS,
        .height = BLOCK_HEIGHTMAP_PIXELS,
        .fmt    = gpu::Format.R8UI,
        .levels = 1,
    });

    gpu::Texture2D building_tex = gpu::texture2d_create({
        .width  = BLOCK_HEIGHTMAP_PIXELS,
        .height = BLOCK_HEIGHTMAP_PIXELS,
        .fmt    = gpu::Format.R16UI,
        .levels = 1,
    });

    float[] hm_cpu = alloc::new_array(self.allocator, float, (usz)(BLOCK_HEIGHTMAP_PIXELS * BLOCK_HEIGHTMAP_PIXELS));

    usz idx        = self.storage.len();
    char next_gen  = 0;
    for (usz i = 0; i < self.storage.len(); i++) {
        if (!self.storage[i].alive) {
            idx      = i;
            next_gen = self.storage[i].generation;
            break;
        }
    }
    BlockSlot slot = {
        .block = {
            .cx                    = cx,
            .cz                    = cz,
            .holders               = {},
            .heightmap             = hm,
            .heightmap_cpu         = hm_cpu,
            .road                  = {},
            .road_texture          = road_tex,
            .building_data         = {},
            .map_data              = {},
            .buildings_dirty       = true,
            .building_interior_tex = building_tex,
            .heightmap_dirty       = true,
            .holder_ref_count      = 0,
        },
        .generation = next_gen,
        .alive      = true,
    };
    for (int i = 0; i < HOLDERS_PER_BLOCK * HOLDERS_PER_BLOCK; i++) slot.block.holders[i] = HOLDER_INVALID;
    slot.block.road.init(self.allocator);
    if (catch building_data_init(&slot.block, self.allocator)) {
        // Unwind: release anything we've allocated before wiring the slot up.
        if (hm_cpu.len != 0) alloc::free(self.allocator, hm_cpu.ptr);
        gpu::texture2d_destroy(hm);
        gpu::texture2d_destroy(road_tex);
        gpu::texture2d_destroy(building_tex);
        slot.block.road.free();
        building_data_free(&slot.block, self.allocator);
        return BLOCK_INVALID;
    }
    if (idx == self.storage.len()) {
        self.storage.push(slot);
    } else {
        self.storage[idx] = slot;
    }
    self.lookup.set(key, (int)idx);
    return (BlockId)core::handle_pack((uint)idx, (uint)next_gen);
}

fn void BlockPool.retain(&self, BlockId id)
{
    uint h = (uint)id;
    if (h == core::HANDLE_INVALID_VALUE) return;
    uint idx = core::handle_index(h);
    uint gen = core::handle_gen(h);
    if (idx >= self.storage.len()) return;
    BlockSlot* slot = &self.storage[idx];
    if (!slot.alive) return;
    if ((uint)slot.generation != gen) return;
    slot.block.holder_ref_count++;
}

fn void BlockPool.decrement_ref(&self, BlockId id)
{
    uint h = (uint)id;
    if (h == core::HANDLE_INVALID_VALUE) return;
    uint idx = core::handle_index(h);
    uint gen = core::handle_gen(h);
    if (idx >= self.storage.len()) return;
    BlockSlot* slot = &self.storage[idx];
    if (!slot.alive) return;
    if ((uint)slot.generation != gen) return;
    if (slot.block.holder_ref_count <= 0) return;
    slot.block.holder_ref_count--;
    if (slot.block.holder_ref_count == 0) {
        gpu::texture2d_destroy(slot.block.heightmap);
        slot.block.heightmap = gpu::TEXTURE2D_INVALID;
        gpu::texture2d_destroy(slot.block.road_texture);
        slot.block.road_texture = gpu::TEXTURE2D_INVALID;
        gpu::texture2d_destroy(slot.block.building_interior_tex);
        slot.block.building_interior_tex = gpu::TEXTURE2D_INVALID;
        if (slot.block.heightmap_cpu.len != 0) {
            alloc::free(self.allocator, slot.block.heightmap_cpu.ptr);
            slot.block.heightmap_cpu = {};
        }
        slot.block.road.free();
        building_data_free(&slot.block, self.allocator);
        slot.alive = false;
        slot.generation++;
        core::IVec3 key = { (int)slot.block.cx, 0, (int)slot.block.cz };
        (void)self.lookup.remove(key);
    }
}

fn Block* BlockPool.get(&self, BlockId id)
{
    uint h = (uint)id;
    if (h == core::HANDLE_INVALID_VALUE) return null;
    uint idx = core::handle_index(h);
    uint gen = core::handle_gen(h);
    if (idx >= self.storage.len()) return null;
    BlockSlot* slot = &self.storage[idx];
    if (!slot.alive) return null;
    if ((uint)slot.generation != gen) return null;
    return &slot.block;
}
