module c3voxel::voxel;

import c3voxel::core;
import c3voxel::gpu;
import c3voxel::world;

// std140 layout — see docs/ubo-convention.md.
// Promotion path: if a 5th UBO appears, convert to an @std140 macro that
// walks fields and emits per-field offset asserts automatically.
struct GenerateUniforms @packed @align(16) {
    core::Vec4    world_min;
    core::Vec4    world_max;
    core::Vec4    block_origin;
    core::Vec4    block_extent;
    core::Seconds time;
    float[3]      _pad;
}
$assert(GenerateUniforms.sizeof % 16 == 0);

struct GenerateContext {
    gpu::Shader shader;
    gpu::Buffer ubo;
}

fn void? GenerateContext.init(&self, Allocator allocator)
{
    gpu::ShaderStageSpec[1] specs = {
        { gpu::ShaderStageKind.COMPUTE, "resources/shaders/generate.comp.glsl" },
    };
    self.shader = gpu::shader_load(allocator, specs[..])!;
    self.ubo    = gpu::buffer_create(GenerateUniforms.sizeof, gpu::BufferUsage.DYNAMIC);
}

fn void GenerateContext.destroy(&self)
{
    gpu::shader_destroy(self.shader);
    gpu::buffer_destroy(self.ubo);
    self.shader = gpu::SHADER_INVALID;
    self.ubo    = gpu::BUFFER_INVALID;
}

fn void GenerateContext.dispatch_page(&self, gpu::Commands* cmd, VolumeRing* ring, int slot, world::Page* page, gpu::Texture2D block_heightmap, core::Vec4 block_origin, core::Vec4 block_extent, core::Seconds time)
{
    GenerateUniforms u = {
        .world_min    = page.world_min,
        .world_max    = page.world_max,
        .block_origin = block_origin,
        .block_extent = block_extent,
        .time         = time,
    };
    gpu::buffer_upload(self.ubo, &u, 0, GenerateUniforms.sizeof);

    cmd.bind_shader(self.shader);
    cmd.bind_image(0, ring.slot(slot), gpu::Access.WRITE_ONLY);
    cmd.bind_texture_2d(1, block_heightmap);
    cmd.bind_ubo(2, self.ubo, 0, GenerateUniforms.sizeof);
    cmd.dispatch(world::VOLUME_PITCH / 4, world::VOLUME_PITCH / 4, world::VOLUME_PITCH / 4);
    cmd.barrier(gpu::BarrierType.IMAGE_TO_TEXTURE);
}

