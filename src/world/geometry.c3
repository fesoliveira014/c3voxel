module c3voxel::world;

import std::collections::list;

import c3voxel::core;
import c3voxel::voxel;

alias GeomEntryList = List {voxel::GeomEntry};
alias TreeEntryList = List {voxel::TreeEntry};
alias LineEntryList = List {voxel::LineEntry};

struct PageGeometry {
    GeomEntryList        geom;
    TreeEntryList        tree;
    LineEntryList        line;
    voxel::VoronoiParams voronoi;
    bool                 initialized;
}

fn void PageGeometry.init(&self, Allocator allocator)
{
    if (self.initialized) return;
    self.geom.init(allocator, 16);
    self.tree.init(allocator, 0);
    self.line.init(allocator, 0);
    self.initialized = true;
}

fn void PageGeometry.clear(&self)
{
    if (!self.initialized) return;
    self.geom.clear();
    self.tree.clear();
    self.line.clear();
}

fn void PageGeometry.free(&self)
{
    if (!self.initialized) return;
    self.geom.free();
    self.tree.free();
    self.line.free();
    self.initialized = false;
}

// M7.1 smoke test: 3x3 grid of superellipsoid "boxes" centered on the page
// XZ plane at the page surface. Reserved GeomEntry fields are zeroed.
const voxel::Material[9] SMOKE_MATERIALS = {
    voxel::Material.STONE,
    voxel::Material.BRICK,
    voxel::Material.PLASTER,
    voxel::Material.WOOD,
    voxel::Material.SHINGLE,
    voxel::Material.MORTAR,
    voxel::Material.DIRT,
    voxel::Material.GRASS,
    voxel::Material.SAND,
};

fn void geometry_generate_smoke_test(PageGeometry* out, Page* page)
{
    out.clear();
    out.voronoi = voxel::voronoi_for_page(page);

    core::Vec3 pmin = { page.world_min.x, page.world_min.y, page.world_min.z };
    core::Vec3 pmax = { page.world_max.x, page.world_max.y, page.world_max.z };
    core::Vec3 size = { pmax.x - pmin.x, pmax.y - pmin.y, pmax.z - pmin.z };
    core::Vec3 cell = { size.x / 3.0f, size.y / 3.0f, size.z / 3.0f };
    // Smoke test: boxes span the full Y range of the page so they're always
    // visible regardless of heightmap. Real post-M7.4 consumers will use
    // terrain-aware placement.
    float half_extent = cell.x * 0.25f;       // narrow enough that 9 boxes read as a grid
    float surface_y   = pmin.y + size.y * 0.5f;
    float box_half_y  = size.y * 0.5f;         // full height — overwrites terrain where inside

    for (int iz = 0; iz < 3; iz++) {
        for (int ix = 0; ix < 3; ix++) {
            int i = iz * 3 + ix;
            float cx = pmin.x + (ix + 0.5f) * cell.x;
            float cz = pmin.z + (iz + 0.5f) * cell.z;
            float cy = surface_y;

            core::Vec4 bmin = { cx - half_extent, cy - box_half_y, cz - half_extent, 0.0f };
            core::Vec4 bmax = { cx + half_extent, cy + box_half_y, cz + half_extent, 0.0f };

            voxel::GeomEntry e = {
                .vis_min      = bmin,
                .vis_max      = bmax,
                .bounds_min   = bmin,
                .bounds_max   = bmax,
                .corner_dis   = { 0.0f, 0.0f, 0.0f, 0.0f },
                .power_vals   = { 6.0f, 6.0f, 0.0f, 0.0f },      // near-cube
                .power_vals_2 = { 0.0f, 0.0f, 0.0f, 0.0f },
                .thick_vals   = { 0.0f, 0.0f, 0.0f, 0.0f },
                .center_point = { cx, cy, cz, 0.0f },
                .mat          = { .material_id = (float)SMOKE_MATERIALS[i].ordinal, .normal_id = 0.0f, .modifier = 0.0f, ._pad = 0.0f },
            };
            out.geom.push(e);
        }
    }
}
