module c3voxel::world;

import std::collections::list;
import std::math;

import c3voxel::core;
import c3voxel::gpu;

const int POOL_SIZE              = 16;
const int MAX_REGEN_PER_FRAME    = 4;
const int VISIBLE_MARGIN_HOLDERS = 1;
const int FRAME_STARVATION_CAP   = 32;

struct PoolSlot {
    HolderId owner;
    uint     last_touched_frame;
}

struct GpuPool {
    PoolSlot[POOL_SIZE] slots;
    uint                current_frame;
}

struct DirtyEntry {
    HolderId id;
    uint     enqueue_frame;
}

alias DirtyQueue = List {DirtyEntry};

fn void GpuPool.init(&self)
{
    for (int i = 0; i < POOL_SIZE; i++) {
        self.slots[i].owner              = HOLDER_INVALID;
        self.slots[i].last_touched_frame = 0;
    }
    self.current_frame = 0;
}

fn int GpuPool.find_slot(&self, HolderId id)
{
    for (int i = 0; i < POOL_SIZE; i++) {
        if ((uint)self.slots[i].owner == (uint)id && (uint)id != core::HANDLE_INVALID_VALUE) return i;
    }
    return -1;
}

fn int GpuPool.acquire(&self, HolderId for_holder, HolderPool* holders, BlockPool* blocks)
{
    for (int i = 0; i < POOL_SIZE; i++) {
        if ((uint)self.slots[i].owner == core::HANDLE_INVALID_VALUE) {
            self.slots[i].owner              = for_holder;
            self.slots[i].last_touched_frame = self.current_frame;
            return i;
        }
    }

    int evict_idx = 0;
    uint oldest   = self.slots[0].last_touched_frame;
    for (int i = 1; i < POOL_SIZE; i++) {
        uint ts = self.slots[i].last_touched_frame;
        if (ts < oldest) {
            evict_idx = i;
            oldest    = ts;
        } else if (ts == oldest && (uint)self.slots[i].owner < (uint)self.slots[evict_idx].owner) {
            evict_idx = i;
        }
    }
    holders.evict(self.slots[evict_idx].owner, blocks);
    self.slots[evict_idx].owner              = for_holder;
    self.slots[evict_idx].last_touched_frame = self.current_frame;
    return evict_idx;
}

fn void GpuPool.touch(&self, int slot_idx)
{
    if (slot_idx < 0 || slot_idx >= POOL_SIZE) return;
    self.slots[slot_idx].last_touched_frame = self.current_frame;
}

fn HolderId ensure_holder_exists(BlockPool* blocks, HolderPool* holders, PagePool* pages, HolderCoord hx, HolderCoord hz)
{
    HolderId existing = holders.find(hx, hz);
    if ((uint)existing != core::HANDLE_INVALID_VALUE) return existing;

    int hx_i = (int)hx;
    int hz_i = (int)hz;
    int cx = floor_div(hx_i, HOLDERS_PER_BLOCK);
    int cz = floor_div(hz_i, HOLDERS_PER_BLOCK);
    BlockId bid = blocks.get_or_create((BlockCoord)cx, (BlockCoord)cz);
    blocks.retain(bid);

    HolderId? hid_opt = holders.get_or_create(hx, hz, bid);
    if (catch err = hid_opt) {
        blocks.decrement_ref(bid);
        return HOLDER_INVALID;
    }
    HolderId hid = hid_opt;

    Holder* holder = holders.get(hid);
    if (holder == null) return HOLDER_INVALID;

    for (int lz = 0; lz < PAGES_PER_HOLDER; lz++) {
        for (int lx = 0; lx < PAGES_PER_HOLDER; lx++) {
            int ph_slot = lz * PAGES_PER_HOLDER + lx;
            if ((uint)holder.pages[ph_slot] != core::HANDLE_INVALID_VALUE) continue;
            PageCoord px = (PageCoord)(hx_i * PAGES_PER_HOLDER + lx);
            PageCoord pz = (PageCoord)(hz_i * PAGES_PER_HOLDER + lz);
            PageId pid = pages.get_or_create(px, pz);
            Page* page = pages.get(pid);
            float x0 = (float)(int)px * (float)PIXELS_PER_PAGE;
            float z0 = (float)(int)pz * (float)PIXELS_PER_PAGE;
            page.world_min = { x0, 0.0f, z0, 0.0f };
            page.world_max = { x0 + (float)PIXELS_PER_PAGE, (float)VOLUME_PITCH, z0 + (float)PIXELS_PER_PAGE, 0.0f };
            holder.pages[ph_slot] = pid;
        }
    }
    return hid;
}

fn int floor_div(int a, int b) @inline
{
    int q = a / b;
    if ((a ^ b) < 0 && q * b != a) q--;
    return q;
}

fn void streaming_update(GpuPool* pool, BlockPool* blocks, HolderPool* holders, PagePool* pages, DirtyQueue* dirty, core::Vec3 pan_target, float zoom, int fb_w, int fb_h)
{
    pool.current_frame++;
    HolderRect rect = visible_holder_rect(pan_target, zoom, fb_w, fb_h, VISIBLE_MARGIN_HOLDERS);

    float extent_f   = (float)HOLDER_WORLD_EXTENT;
    float max_radius = (float)math::sqrt((double)POOL_SIZE / (double)math::PI) * extent_f * 0.95f;
    float max_rad_sq = max_radius * max_radius;

    for (HolderCoord hz = rect.z0; hz <= rect.z1; hz++) {
        for (HolderCoord hx = rect.x0; hx <= rect.x1; hx++) {
            float cx = (float)(int)hx * extent_f + extent_f * 0.5f;
            float cz = (float)(int)hz * extent_f + extent_f * 0.5f;
            float dx = cx - pan_target.x;
            float dz = cz - pan_target.z;
            if (dx * dx + dz * dz > max_rad_sq) continue;

            HolderId hid = ensure_holder_exists(blocks, holders, pages, hx, hz);
            if ((uint)hid == core::HANDLE_INVALID_VALUE) continue;
            int slot = pool.find_slot(hid);
            if (slot >= 0) {
                pool.touch(slot);
            } else {
                pool.acquire(hid, holders, blocks);
                dirty.push({ hid, pool.current_frame });
            }
        }
    }
}

fn float holder_distance_sq(Holder* h, core::Vec3 pan_target) @inline
{
    float cx = (float)(int)h.hx * (float)HOLDER_WORLD_EXTENT + (float)HOLDER_WORLD_EXTENT * 0.5f;
    float cz = (float)(int)h.hz * (float)HOLDER_WORLD_EXTENT + (float)HOLDER_WORLD_EXTENT * 0.5f;
    float dx = cx - pan_target.x;
    float dz = cz - pan_target.z;
    return dx * dx + dz * dz;
}
