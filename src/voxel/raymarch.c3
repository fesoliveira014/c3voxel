module c3voxel::voxel;

import c3voxel::gpu;

struct RayMarchUniforms @packed @align(16) {
    float[4] camera_pos;
    float[4] camera_forward;
    float[4] camera_right;
    float[4] camera_up;
    float[4] world_min;
    float[4] world_max;
    int[4]   resolution;
    int[4]   pitches;
    float    half_extent_x;
    float    half_extent_y;
    float[2] _pad;
}

struct View {
    float[4] position;
    float[4] forward;
    float[4] right;
    float[4] up;
    float    half_extent_x;
    float    half_extent_y;
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

fn void RayMarchContext.dispatch(&self, gpu::Commands* cmd, Volume* v, DistanceField* df, View view)
{
    RayMarchUniforms u = {
        .camera_pos     = view.position,
        .camera_forward = view.forward,
        .camera_right   = view.right,
        .camera_up      = view.up,
        .world_min      = { -1.0, -1.0, -1.0, 0.0 },
        .world_max      = {  1.0,  1.0,  1.0, 0.0 },
        .resolution     = { self.target_w, self.target_h, 0, 0 },
        .pitches        = { VOLUME_PITCH, DF_PITCH, 4, 0 },
        .half_extent_x  = view.half_extent_x,
        .half_extent_y  = view.half_extent_y,
    };
    gpu::buffer_upload(self.ubo, &u, 0, RayMarchUniforms.sizeof);

    cmd.bind_shader(self.shader);
    cmd.bind_texture(0, v.tex);
    cmd.bind_texture(1, df.sampled());
    cmd.bind_image_2d(2, self.target, gpu::Access.WRITE_ONLY, gpu::Format.RGBA8);
    cmd.bind_ubo(3, self.ubo, 0, RayMarchUniforms.sizeof);

    int gx = (self.target_w + 7) / 8;
    int gy = (self.target_h + 7) / 8;
    cmd.dispatch(gx, gy, 1);
    cmd.barrier(gpu::BarrierType.IMAGE_TO_TEXTURE);
}
