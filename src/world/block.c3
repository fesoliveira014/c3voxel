module c3voxel::world;

import std::collections::list;

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
        if (slot.alive) gpu::texture2d_destroy(slot.block.heightmap);
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
            .cx               = cx,
            .cz               = cz,
            .holders          = {},
            .heightmap        = hm,
            .heightmap_dirty  = true,
            .holder_ref_count = 0,
        },
        .generation = next_gen,
        .alive      = true,
    };
    for (int i = 0; i < HOLDERS_PER_BLOCK * HOLDERS_PER_BLOCK; i++) slot.block.holders[i] = HOLDER_INVALID;
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
        slot.alive           = false;
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
