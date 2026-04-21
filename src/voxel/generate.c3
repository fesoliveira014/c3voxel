module c3voxel::voxel;

import c3voxel::core;
import c3voxel::gpu;
import c3voxel::world;

// std140 layout — see docs/ubo-convention.md.
// Promotion path: if a 6th UBO appears, convert to an @std140 macro that
// walks fields and emits per-field offset asserts automatically.
struct GenerateUniforms @packed @align(16) {
    core::Vec4    world_min;
    core::Vec4    world_max;
    core::Vec4    block_origin;
    core::Vec4    block_extent;
    core::Seconds time;
    float[3]      _pad;
    core::IVec4   entry_counts;    // x=num_geom, y=num_tree, z=num_line, w=reserved
}
$assert(GenerateUniforms.sizeof % 16 == 0);

const gpu::ByteSize GEOM_SSBO_BYTES    = MAX_ENTRIES_PER_PAGE * (gpu::ByteSize)GeomEntry.sizeof;
const gpu::ByteSize TREE_SSBO_BYTES    = MAX_ENTRIES_PER_PAGE * (gpu::ByteSize)TreeEntry.sizeof;
const gpu::ByteSize LINE_SSBO_BYTES    = MAX_ENTRIES_PER_PAGE * (gpu::ByteSize)LineEntry.sizeof;

struct GenerateContext {
    gpu::Shader shader;
    gpu::Shader normal_shader;
    gpu::Buffer ubo;
    gpu::Buffer geom_ssbo;
    gpu::Buffer tree_ssbo;
    gpu::Buffer line_ssbo;
    gpu::Buffer voronoi_ubo;
}

fn void? GenerateContext.init(&self, Allocator allocator)
{
    gpu::ShaderStageSpec[1] specs = {
        { gpu::ShaderStageKind.COMPUTE, "resources/shaders/generate.comp.glsl" },
    };
    gpu::ShaderStageSpec[1] normal_specs = {
        { gpu::ShaderStageKind.COMPUTE, "resources/shaders/generate_normal.comp.glsl" },
    };
    self.shader        = gpu::shader_load(allocator, specs[..])!;
    self.normal_shader = gpu::shader_load(allocator, normal_specs[..])!;
    self.ubo           = gpu::buffer_create(GenerateUniforms.sizeof, gpu::BufferUsage.DYNAMIC);
    self.geom_ssbo     = gpu::buffer_create(GEOM_SSBO_BYTES, gpu::BufferUsage.DYNAMIC);
    self.tree_ssbo     = gpu::buffer_create(TREE_SSBO_BYTES, gpu::BufferUsage.DYNAMIC);
    self.line_ssbo     = gpu::buffer_create(LINE_SSBO_BYTES, gpu::BufferUsage.DYNAMIC);
    self.voronoi_ubo   = gpu::buffer_create(VoronoiParams.sizeof, gpu::BufferUsage.DYNAMIC);
}

fn void GenerateContext.destroy(&self)
{
    gpu::shader_destroy(self.shader);
    gpu::shader_destroy(self.normal_shader);
    gpu::buffer_destroy(self.ubo);
    gpu::buffer_destroy(self.geom_ssbo);
    gpu::buffer_destroy(self.tree_ssbo);
    gpu::buffer_destroy(self.line_ssbo);
    gpu::buffer_destroy(self.voronoi_ubo);
    self.shader        = gpu::SHADER_INVALID;
    self.normal_shader = gpu::SHADER_INVALID;
    self.ubo           = gpu::BUFFER_INVALID;
    self.geom_ssbo     = gpu::BUFFER_INVALID;
    self.tree_ssbo     = gpu::BUFFER_INVALID;
    self.line_ssbo     = gpu::BUFFER_INVALID;
    self.voronoi_ubo   = gpu::BUFFER_INVALID;
}

fn void GenerateContext.dispatch_page(&self, gpu::Commands* cmd, VolumeRing* ring, int slot, world::Page* page, gpu::Texture2D block_heightmap, gpu::Texture2D block_road, gpu::Texture2D block_interior, core::Vec4 block_origin, core::Vec4 block_extent, core::Seconds time)
{
    world::PageGeometry* geom = &page.geometry;

    int n_geom = (int)geom.geom.len();
    int n_tree = (int)geom.tree.len();
    int n_line = (int)geom.line.len();
    if (n_geom > MAX_ENTRIES_PER_PAGE) n_geom = MAX_ENTRIES_PER_PAGE;
    if (n_tree > MAX_ENTRIES_PER_PAGE) n_tree = MAX_ENTRIES_PER_PAGE;
    if (n_line > MAX_ENTRIES_PER_PAGE) n_line = MAX_ENTRIES_PER_PAGE;

    if (n_geom > 0) gpu::buffer_upload(self.geom_ssbo, geom.geom.entries, 0, (gpu::ByteSize)(n_geom * GeomEntry.sizeof));
    if (n_tree > 0) gpu::buffer_upload(self.tree_ssbo, geom.tree.entries, 0, (gpu::ByteSize)(n_tree * TreeEntry.sizeof));
    if (n_line > 0) gpu::buffer_upload(self.line_ssbo, geom.line.entries, 0, (gpu::ByteSize)(n_line * LineEntry.sizeof));
    gpu::buffer_upload(self.voronoi_ubo, &geom.voronoi, 0, VoronoiParams.sizeof);

    GenerateUniforms u = {
        .world_min    = page.world_min,
        .world_max    = page.world_max,
        .block_origin = block_origin,
        .block_extent = block_extent,
        .time         = time,
        .entry_counts = { n_geom, n_tree, n_line, 0 },
    };
    gpu::buffer_upload(self.ubo, &u, 0, GenerateUniforms.sizeof);

    cmd.bind_shader(self.shader);
    cmd.bind_image(0, ring.slot(slot), gpu::Access.WRITE_ONLY);
    cmd.bind_texture_2d(1, block_heightmap);
    cmd.bind_ubo(2, self.ubo, 0, GenerateUniforms.sizeof);
    cmd.bind_ssbo(3, self.geom_ssbo);
    cmd.bind_ssbo(4, self.tree_ssbo);
    cmd.bind_ssbo(5, self.line_ssbo);
    cmd.bind_ubo(6, self.voronoi_ubo, 0, VoronoiParams.sizeof);
    cmd.bind_texture_2d(7, block_road);
    cmd.bind_texture_2d(8, block_interior);
    cmd.dispatch(world::VOLUME_PITCH / 4, world::VOLUME_PITCH / 4, world::VOLUME_PITCH / 4);
    cmd.barrier(gpu::BarrierType.SHADER_IMAGE_ACCESS);

    // M8 T2: derive per-voxel surface normals by central-differencing the
    // opacity channel of the main volume, then writing octahedral-packed
    // normals into the aux RG8 ring slot. Same dispatch dimensions as the
    // main generate; barrier below makes the packed normals available to
    // the raymarch stage's sampler fetches.
    cmd.bind_shader(self.normal_shader);
    cmd.bind_image(0, ring.slot(slot),        gpu::Access.READ_ONLY);
    cmd.bind_image(1, ring.normal_slot(slot), gpu::Access.WRITE_ONLY);
    cmd.dispatch(world::VOLUME_PITCH / 4, world::VOLUME_PITCH / 4, world::VOLUME_PITCH / 4);
    cmd.barrier(gpu::BarrierType.IMAGE_TO_TEXTURE);
}

