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

const uint WORLD_SEED = 1337u;

fn void geometry_generate_page(PageGeometry* out, Page* page, Block* block, PlantNodeList* scratch_nodes)
{
    out.clear();
    out.voronoi = voxel::voronoi_for_page(page);

    // M7.2: trees — skip footprint tiles of buildings (block != null case).
    plant_generate_page(out, page, block, WORLD_SEED, scratch_nodes);

    // M7.4: buildings (walls, doors, windows, lanterns).
    if (block != null) {
        building_emit_to_page(out, block, page);
    }
}
