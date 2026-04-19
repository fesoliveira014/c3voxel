module c3voxel::voxel;

import c3voxel::gpu;

faultdef RAYMARCH_SHADER_FAILED;

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

fn RayMarchContext? raymarch_context_create(Allocator allocator, int w, int h)
{
    gpu::ShaderStageSpec[1] specs = {
        { gpu::ShaderStageKind.COMPUTE, "src/shaders/raymarch.comp.glsl" },
    };
    gpu::Shader? sh = gpu::shader_load(allocator, specs[..]);
    if (catch err = sh) return err~;

    gpu::Buffer ubo = gpu::buffer_create(RayMarchUniforms.sizeof, gpu::BufferUsage.DYNAMIC);

    gpu::Texture2D target = gpu::texture2d_create({
        .width  = w,
        .height = h,
        .fmt    = gpu::Format.RGBA8,
        .levels = 1,
    });

    return { .shader = sh, .ubo = ubo, .target = target, .target_w = w, .target_h = h };
}

fn void raymarch_context_destroy(RayMarchContext* ctx)
{
    gpu::shader_destroy(ctx.shader);
    gpu::buffer_destroy(ctx.ubo);
    gpu::texture2d_destroy(ctx.target);
    ctx.shader   = gpu::SHADER_INVALID;
    ctx.ubo      = gpu::BUFFER_INVALID;
    ctx.target   = gpu::TEXTURE2D_INVALID;
    ctx.target_w = 0;
    ctx.target_h = 0;
}

fn void raymarch_context_resize(RayMarchContext* ctx, int w, int h)
{
    if (w == ctx.target_w && h == ctx.target_h) return;
    gpu::texture2d_destroy(ctx.target);
    ctx.target = gpu::texture2d_create({
        .width  = w,
        .height = h,
        .fmt    = gpu::Format.RGBA8,
        .levels = 1,
    });
    ctx.target_w = w;
    ctx.target_h = h;
}

fn void raymarch_dispatch(gpu::Commands* cmd, RayMarchContext* ctx, Volume* v, float[4] camera_pos)
{
    RayMarchUniforms u = {
        .camera_pos = camera_pos,
        .world_min  = { -1.0, -1.0, -1.0, 0.0 },
        .world_max  = {  1.0,  1.0,  1.0, 0.0 },
        .resolution = { ctx.target_w, ctx.target_h, 0, 0 },
        .fov_scale  = 0.8,
    };
    gpu::buffer_upload(ctx.ubo, &u, 0, RayMarchUniforms.sizeof);

    cmd.bind_shader(ctx.shader);
    cmd.bind_texture(0, v.tex);
    cmd.bind_image_2d(1, ctx.target, gpu::Access.WRITE_ONLY, gpu::Format.RGBA8);
    cmd.bind_ubo(2, ctx.ubo, 0, RayMarchUniforms.sizeof);

    int gx = (ctx.target_w + 7) / 8;
    int gy = (ctx.target_h + 7) / 8;
    cmd.dispatch(gx, gy, 1);
    cmd.barrier(gpu::BarrierType.SHADER_IMAGE_ACCESS);
}
