module c3voxel::voxel;

import c3voxel::core;
import c3voxel::game;
import c3voxel::gpu;
import c3voxel::world;

// std140 layout — see docs/ubo-convention.md.
// Promotion path: if a 5th UBO appears, convert to an @std140 macro that
// walks fields and emits per-field offset asserts automatically.
struct RayMarchUniforms @packed @align(16) {
    core::Vec4    holder_center;             // (cx, 0, cz, 0)
    core::Vec4    iso_bbox;                  // (sx_min, sy_min, sx_max, sy_max)
    core::Vec4[4] page_world_min;
    core::Vec4[4] page_world_max;
    core::IVec4   resolution;                // fbo_w, fbo_h, volume_pitch, 0
    core::IVec4   page_valid_mask;           // bit i: page i resident
    float         iso_tilt;
    float         volume_max_y;
    float         voxel_len;
    float         _pad0;
}
$assert(RayMarchUniforms.sizeof % 16 == 0);

struct RayMarchContext {
    gpu::Shader shader;
    gpu::Buffer ubo;
}

fn void? RayMarchContext.init(&self, Allocator allocator)
{
    gpu::ShaderStageSpec[1] specs = {
        { gpu::ShaderStageKind.COMPUTE, "resources/shaders/raymarch.comp.glsl" },
    };
    self.shader = gpu::shader_load(allocator, specs[..])!;
    self.ubo    = gpu::buffer_create(RayMarchUniforms.sizeof, gpu::BufferUsage.DYNAMIC);
}

fn void RayMarchContext.destroy(&self)
{
    gpu::shader_destroy(self.shader);
    gpu::buffer_destroy(self.ubo);
    self.shader = gpu::SHADER_INVALID;
    self.ubo    = gpu::BUFFER_INVALID;
}

fn void RayMarchContext.dispatch_holder(
    &self,
    gpu::Commands*    cmd,
    gpu::Texture3D[4] page_volumes,
    gpu::Texture3D[4] page_normals,
    world::Holder*    h,
    world::Page*[4]   pages,
    gpu::Framebuffer* holder_fbo,
    core::IVec4       page_valid_mask)
{
    float extent    = (float)world::HOLDER_WORLD_EXTENT;
    float vol_max_y = (float)world::VOLUME_PITCH;
    float tilt      = game::ISO_TILT;
    float cx        = (float)(int)h.hx * extent + extent * 0.5f;
    float cz        = (float)(int)h.hz * extent + extent * 0.5f;

    RayMarchUniforms u = {
        .holder_center   = { cx, 0.0f, cz, 0.0f },
        .iso_bbox        = { -extent, -tilt * extent, extent, tilt * extent + vol_max_y },
        .page_world_min  = {
            pages[0] != null ? pages[0].world_min : (core::Vec4){ 0.0f, 0.0f, 0.0f, 0.0f },
            pages[1] != null ? pages[1].world_min : (core::Vec4){ 0.0f, 0.0f, 0.0f, 0.0f },
            pages[2] != null ? pages[2].world_min : (core::Vec4){ 0.0f, 0.0f, 0.0f, 0.0f },
            pages[3] != null ? pages[3].world_min : (core::Vec4){ 0.0f, 0.0f, 0.0f, 0.0f },
        },
        .page_world_max  = {
            pages[0] != null ? pages[0].world_max : (core::Vec4){ 0.0f, 0.0f, 0.0f, 0.0f },
            pages[1] != null ? pages[1].world_max : (core::Vec4){ 0.0f, 0.0f, 0.0f, 0.0f },
            pages[2] != null ? pages[2].world_max : (core::Vec4){ 0.0f, 0.0f, 0.0f, 0.0f },
            pages[3] != null ? pages[3].world_max : (core::Vec4){ 0.0f, 0.0f, 0.0f, 0.0f },
        },
        .resolution      = { (int)holder_fbo.width, (int)holder_fbo.height, world::VOLUME_PITCH, 0 },
        .page_valid_mask = page_valid_mask,
        .iso_tilt        = tilt,
        .volume_max_y    = vol_max_y,
        .voxel_len       = (float)world::PIXELS_PER_PAGE / (float)world::VOLUME_PITCH,
    };
    gpu::buffer_upload(self.ubo, &u, 0, RayMarchUniforms.sizeof);

    cmd.bind_shader(self.shader);
    // Bindings 0..3: page volume (material + opacity) samplers.
    cmd.bind_texture(0, page_volumes[0]);
    cmd.bind_texture(1, page_volumes[1]);
    cmd.bind_texture(2, page_volumes[2]);
    cmd.bind_texture(3, page_volumes[3]);
    // Bindings 4..6: MRT output images (material_id / normal / height).
    cmd.bind_image_2d(4, holder_fbo.colors[0], gpu::Access.WRITE_ONLY);
    cmd.bind_image_2d(5, holder_fbo.colors[1], gpu::Access.WRITE_ONLY);
    cmd.bind_image_2d(6, holder_fbo.colors[2], gpu::Access.WRITE_ONLY);
    // Binding 7: RayMarchUniforms UBO.
    cmd.bind_ubo(7, self.ubo, 0, RayMarchUniforms.sizeof);
    // Bindings 8..11: aux RG8 normal volumes (octahedral-packed).
    cmd.bind_texture(8,  page_normals[0]);
    cmd.bind_texture(9,  page_normals[1]);
    cmd.bind_texture(10, page_normals[2]);
    cmd.bind_texture(11, page_normals[3]);

    int gx = ((int)holder_fbo.width  + 7) / 8;
    int gy = ((int)holder_fbo.height + 7) / 8;
    cmd.dispatch(gx, gy, 1);
    cmd.barrier(gpu::BarrierType.IMAGE_TO_TEXTURE);
}
