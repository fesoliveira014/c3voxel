module c3voxel::voxel;

import c3voxel::core;
import c3voxel::gpu;
import c3voxel::world;

struct RayMarchUniforms @packed @align(16) {
    core::Vec4  camera_pos;
    core::Vec4  camera_forward;
    core::Vec4  camera_right;
    core::Vec4  camera_up;
    core::Vec4  world_min;
    core::Vec4  world_max;
    core::IVec4 resolution;
    core::IVec4 pitches;
    core::IVec4 page_pixels;
    core::IVec4 write_offset;
    float       half_extent_x;
    float       half_extent_y;
    float[2]    _pad;
}

struct View {
    core::Vec4 position;
    core::Vec4 forward;
    core::Vec4 right;
    core::Vec4 up;
    float      half_extent_x;
    float      half_extent_y;
}

struct RayMarchContext {
    gpu::Shader    shader;
    gpu::Buffer    ubo;
    gpu::Texture2D target;
    gpu::Texture2D height_target;
    world::Pixel   target_w;
    world::Pixel   target_h;
}

fn void? RayMarchContext.init(&self, Allocator allocator, world::Pixel w, world::Pixel h)
{
    gpu::ShaderStageSpec[1] specs = {
        { gpu::ShaderStageKind.COMPUTE, "resources/shaders/raymarch.comp.glsl" },
    };
    self.shader        = gpu::shader_load(allocator, specs[..])!;
    self.ubo           = gpu::buffer_create(RayMarchUniforms.sizeof, gpu::BufferUsage.DYNAMIC);
    self.target        = gpu::texture2d_create({ .width = w, .height = h, .fmt = gpu::Format.RGBA8, .levels = 1 });
    self.height_target = gpu::texture2d_create({ .width = w, .height = h, .fmt = gpu::Format.R16F,  .levels = 1 });
    self.target_w      = w;
    self.target_h      = h;
}

fn void RayMarchContext.destroy(&self)
{
    gpu::shader_destroy(self.shader);
    gpu::buffer_destroy(self.ubo);
    gpu::texture2d_destroy(self.target);
    gpu::texture2d_destroy(self.height_target);
    self.shader        = gpu::SHADER_INVALID;
    self.ubo           = gpu::BUFFER_INVALID;
    self.target        = gpu::TEXTURE2D_INVALID;
    self.height_target = gpu::TEXTURE2D_INVALID;
    self.target_w      = 0;
    self.target_h      = 0;
}

fn void RayMarchContext.resize(&self, world::Pixel w, world::Pixel h)
{
    if (w <= 0 || h <= 0) return;
    if (w == self.target_w && h == self.target_h) return;
    gpu::texture2d_destroy(self.target);
    gpu::texture2d_destroy(self.height_target);
    self.target        = gpu::texture2d_create({ .width = w, .height = h, .fmt = gpu::Format.RGBA8, .levels = 1 });
    self.height_target = gpu::texture2d_create({ .width = w, .height = h, .fmt = gpu::Format.R16F,  .levels = 1 });
    self.target_w      = w;
    self.target_h      = h;
}

fn void RayMarchContext.dispatch(&self, gpu::Commands* cmd, Volume* v, DistanceField* df, View view)
{
    core::Vec4 wmin = { -1.0f, -1.0f, -1.0f, 0.0f };
    core::Vec4 wmax = {  1.0f,  1.0f,  1.0f, 0.0f };
    self.dispatch_raw(cmd, v.tex, df, view, wmin, wmax, self.target, self.height_target, self.target_w, self.target_h, { 0, 0 }, { self.target_w, self.target_h });
}

fn void RayMarchContext.dispatch_into(&self, gpu::Commands* cmd, VolumeRing* ring, int slot, DistanceField* df, world::Page* page, gpu::Framebuffer* holder_fbo, core::IVec2 write_offset)
{
    View v = {
        .position      = { (page.world_min.x + page.world_max.x) * 0.5f, page.world_max.y + 1.0f, (page.world_min.z + page.world_max.z) * 0.5f, 0.0f },
        .forward       = { 0.0f, -1.0f, 0.0f, 0.0f },
        .right         = { 1.0f,  0.0f, 0.0f, 0.0f },
        .up            = { 0.0f,  0.0f, 1.0f, 0.0f },
        .half_extent_x = (page.world_max.x - page.world_min.x) * 0.5f,
        .half_extent_y = (page.world_max.z - page.world_min.z) * 0.5f,
    };
    self.dispatch_raw(cmd, ring.slot(slot), df, v, page.world_min, page.world_max, holder_fbo.colors[0], holder_fbo.colors[1], holder_fbo.width, holder_fbo.height, write_offset, { world::PIXELS_PER_PAGE, world::PIXELS_PER_PAGE });
}

fn void RayMarchContext.dispatch_raw(&self, gpu::Commands* cmd, gpu::Texture3D volume, DistanceField* df, View view, core::Vec4 world_min, core::Vec4 world_max, gpu::Texture2D color_out, gpu::Texture2D height_out, world::Pixel out_w, world::Pixel out_h, core::IVec2 write_offset, core::IVec2 page_pixels)
{
    RayMarchUniforms u = {
        .camera_pos     = view.position,
        .camera_forward = view.forward,
        .camera_right   = view.right,
        .camera_up      = view.up,
        .world_min      = world_min,
        .world_max      = world_max,
        .resolution     = { (int)out_w, (int)out_h, 0, 0 },
        .pitches        = { world::VOLUME_PITCH, DF_PITCH, CELL_VOXELS, 0 },
        .page_pixels    = { page_pixels.x, page_pixels.y, 0, 0 },
        .write_offset   = { write_offset.x, write_offset.y, 0, 0 },
        .half_extent_x  = view.half_extent_x,
        .half_extent_y  = view.half_extent_y,
    };
    gpu::buffer_upload(self.ubo, &u, 0, RayMarchUniforms.sizeof);

    cmd.bind_shader(self.shader);
    cmd.bind_texture(0, volume);
    cmd.bind_texture(1, df.sampled());
    cmd.bind_image_2d(2, color_out,  gpu::Access.WRITE_ONLY, gpu::Format.RGBA8);
    cmd.bind_image_2d(3, height_out, gpu::Access.WRITE_ONLY, gpu::Format.R16F);
    cmd.bind_ubo(4, self.ubo, 0, RayMarchUniforms.sizeof);

    int gx = (page_pixels.x + 7) / 8;
    int gy = (page_pixels.y + 7) / 8;
    cmd.dispatch(gx, gy, 1);
    cmd.barrier(gpu::BarrierType.IMAGE_TO_TEXTURE);
}
