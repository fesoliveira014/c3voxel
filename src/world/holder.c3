module c3voxel::world;

import std::collections::list;

import c3voxel::core;
import c3voxel::gpu;

typedef HolderId = inline core::Handle;

const HolderId HOLDER_INVALID = (HolderId)core::HANDLE_INVALID_VALUE;

const int HOLDER_FBO_SIZE = PIXELS_PER_PAGE * PAGES_PER_HOLDER;

struct Holder {
    HolderCoord      hx;
    HolderCoord      hz;
    BlockId          block_id;
    PageId[PAGES_PER_HOLDER * PAGES_PER_HOLDER] pages;
    gpu::Framebuffer fbo_layer0;
}

struct HolderSlot {
    Holder holder;
    char   generation;
    bool   alive;
}

alias HolderSlotList = List {HolderSlot};

struct HolderPool {
    HolderSlotList    storage;
    core::Ivec3IntMap lookup;
    Allocator         allocator;
}

fn void HolderPool.init(&self, Allocator allocator, usz capacity = 16)
{
    self.allocator = allocator;
    self.storage.init(allocator, capacity);
    self.lookup.init(allocator, (uint)capacity);
}

fn void HolderPool.destroy(&self)
{
    for (usz i = 0; i < self.storage.len(); i++) {
        HolderSlot* slot = &self.storage[i];
        if (slot.alive) gpu::framebuffer_destroy(&slot.holder.fbo_layer0);
    }
    self.storage.free();
    self.lookup.free();
    self.allocator = null;
}

fn HolderId HolderPool.find(&self, HolderCoord hx, HolderCoord hz)
{
    core::IVec3 key = { (int)hx, 0, (int)hz };
    if (try found = self.lookup.get(key)) {
        usz idx = (usz)found;
        return (HolderId)core::handle_pack((uint)idx, (uint)self.storage[idx].generation);
    }
    return HOLDER_INVALID;
}

// Allocates a new holder. Caller is responsible for retaining the
// parent block (call `BlockPool.retain(block_id)` once per new
// holder). Use `find()` first if you only want lookup without the
// alloc side-effect.
fn HolderId? HolderPool.get_or_create(&self, HolderCoord hx, HolderCoord hz, BlockId block_id)
{
    core::IVec3 key = { (int)hx, 0, (int)hz };
    if (try found = self.lookup.get(key)) {
        usz idx = (usz)found;
        return (HolderId)core::handle_pack((uint)idx, (uint)self.storage[idx].generation);
    }

    gpu::Format[2] color_fmts = { gpu::Format.RGBA8, gpu::Format.R16F };
    gpu::Framebuffer fbo = gpu::framebuffer_create({
        .width    = HOLDER_FBO_SIZE,
        .height   = HOLDER_FBO_SIZE,
        .colors   = color_fmts[..],
        .depth    = gpu::Format.RGBA8,
        .has_depth = false,
    })!;

    usz idx       = self.storage.len();
    char next_gen = 0;
    for (usz i = 0; i < self.storage.len(); i++) {
        if (!self.storage[i].alive) {
            idx      = i;
            next_gen = self.storage[i].generation;
            break;
        }
    }
    HolderSlot slot = {
        .holder     = { .hx = hx, .hz = hz, .block_id = block_id, .pages = {}, .fbo_layer0 = fbo },
        .generation = next_gen,
        .alive      = true,
    };
    for (int i = 0; i < PAGES_PER_HOLDER * PAGES_PER_HOLDER; i++) slot.holder.pages[i] = PAGE_INVALID;
    if (idx == self.storage.len()) {
        self.storage.push(slot);
    } else {
        self.storage[idx] = slot;
    }
    self.lookup.set(key, (int)idx);
    return (HolderId)core::handle_pack((uint)idx, (uint)next_gen);
}

fn void HolderPool.evict(&self, HolderId id, BlockPool* blocks)
{
    uint h = (uint)id;
    if (h == core::HANDLE_INVALID_VALUE) return;
    uint idx = core::handle_index(h);
    uint gen = core::handle_gen(h);
    if (idx >= self.storage.len()) return;
    HolderSlot* slot = &self.storage[idx];
    if (!slot.alive) return;
    if ((uint)slot.generation != gen) return;

    BlockId parent_block = slot.holder.block_id;
    gpu::framebuffer_destroy(&slot.holder.fbo_layer0);
    core::IVec3 key = { (int)slot.holder.hx, 0, (int)slot.holder.hz };
    (void)self.lookup.remove(key);
    slot.alive = false;
    slot.generation++;

    blocks.decrement_ref(parent_block);
}

fn Holder* HolderPool.get(&self, HolderId id)
{
    uint h = (uint)id;
    if (h == core::HANDLE_INVALID_VALUE) return null;
    uint idx = core::handle_index(h);
    uint gen = core::handle_gen(h);
    if (idx >= self.storage.len()) return null;
    HolderSlot* slot = &self.storage[idx];
    if (!slot.alive) return null;
    if ((uint)slot.generation != gen) return null;
    return &slot.holder;
}
