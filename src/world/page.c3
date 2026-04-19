module c3voxel::world;

import std::collections::list;

import c3voxel::core;

typedef PageId = inline core::Handle;

const PageId PAGE_INVALID = (PageId)core::HANDLE_INVALID_VALUE;

struct Page {
    PageCoord  px;
    PageCoord  pz;
    core::Vec4 world_min;
    core::Vec4 world_max;
}

struct PageSlot {
    Page  page;
    char  generation;
    bool  alive;
}

alias PageSlotList = List {PageSlot};

struct PagePool {
    PageSlotList        storage;
    core::Ivec3IntMap   lookup;
    Allocator           allocator;
}

fn void PagePool.init(&self, Allocator allocator, usz capacity = 64)
{
    self.allocator = allocator;
    self.storage.init(allocator, capacity);
    self.lookup.init(allocator, (uint)capacity);
}

fn void PagePool.destroy(&self)
{
    self.storage.free();
    self.lookup.free();
    self.allocator = null;
}

fn PageId PagePool.get_or_create(&self, PageCoord px, PageCoord pz)
{
    core::IVec3 key = { (int)px, 0, (int)pz };
    if (try found = self.lookup.get(key)) {
        usz idx = (usz)found;
        return (PageId)core::handle_pack((uint)idx, (uint)self.storage[idx].generation);
    }

    usz idx = self.storage.len();
    PageSlot slot = {
        .page       = { .px = px, .pz = pz, .world_min = {0,0,0,0}, .world_max = {0,0,0,0} },
        .generation = 0,
        .alive      = true,
    };
    self.storage.push(slot);
    self.lookup.set(key, (int)idx);
    return (PageId)core::handle_pack((uint)idx, 0);
}

fn Page* PagePool.get(&self, PageId id)
{
    uint h = (uint)id;
    if (h == core::HANDLE_INVALID_VALUE) return null;
    uint idx = core::handle_index(h);
    uint gen = core::handle_gen(h);
    if (idx >= self.storage.len()) return null;
    PageSlot* slot = &self.storage[idx];
    if (!slot.alive) return null;
    if ((uint)slot.generation != gen) return null;
    return &slot.page;
}
