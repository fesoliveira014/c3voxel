module c3voxel::voxel;

import c3voxel::gpu;

struct RayMarchUniforms @packed @align(16) {
    float[4] camera_pos;
    float[4] world_min;
    float[4] world_max;
    int[4]   resolution;
    float    fov_scale;
    float[3] _pad;
}

struct RayMarchContext {
    gpu::Shader    shader;
    gpu::Buffer    ubo;
    gpu::Texture2D target;
    int            target_w;
    int            target_h;
}

fn void? RayMarchContext.init(&self, Allocator allocator, int w, int h)
{
    gpu::ShaderStageSpec[1] specs = {
        { gpu::ShaderStageKind.COMPUTE, "resources/shaders/raymarch.comp.glsl" },
    };
    self.shader   = gpu::shader_load(allocator, specs[..])!;
    self.ubo      = gpu::buffer_create(RayMarchUniforms.sizeof, gpu::BufferUsage.DYNAMIC);
    self.target   = gpu::texture2d_create({
        .width  = w,
        .height = h,
        .fmt    = gpu::Format.RGBA8,
        .levels = 1,
    });
    self.target_w = w;
    self.target_h = h;
}

fn void RayMarchContext.destroy(&self)
{
    gpu::shader_destroy(self.shader);
    gpu::buffer_destroy(self.ubo);
    gpu::texture2d_destroy(self.target);
    self.shader   = gpu::SHADER_INVALID;
    self.ubo      = gpu::BUFFER_INVALID;
    self.target   = gpu::TEXTURE2D_INVALID;
    self.target_w = 0;
    self.target_h = 0;
}

fn void RayMarchContext.resize(&self, int w, int h)
{
    if (w <= 0 || h <= 0) return;
    if (w == self.target_w && h == self.target_h) return;
    gpu::texture2d_destroy(self.target);
    self.target = gpu::texture2d_create({
        .width  = w,
        .height = h,
        .fmt    = gpu::Format.RGBA8,
        .levels = 1,
    });
    self.target_w = w;
    self.target_h = h;
}

fn void RayMarchContext.dispatch(&self, gpu::Commands* cmd, Volume* v, float[4] camera_pos)
{
    RayMarchUniforms u = {
        .camera_pos = camera_pos,
        .world_min  = { -1.0, -1.0, -1.0, 0.0 },
        .world_max  = {  1.0,  1.0,  1.0, 0.0 },
        .resolution = { self.target_w, self.target_h, 0, 0 },
        .fov_scale  = 0.8,
    };
    gpu::buffer_upload(self.ubo, &u, 0, RayMarchUniforms.sizeof);

    cmd.bind_shader(self.shader);
    cmd.bind_texture(0, v.tex);
    cmd.bind_image_2d(1, self.target, gpu::Access.WRITE_ONLY, gpu::Format.RGBA8);
    cmd.bind_ubo(2, self.ubo, 0, RayMarchUniforms.sizeof);

    int gx = (self.target_w + 7) / 8;
    int gy = (self.target_h + 7) / 8;
    cmd.dispatch(gx, gy, 1);
    cmd.barrier(gpu::BarrierType.TEXTURE_FETCH);
}
