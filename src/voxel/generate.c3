module c3voxel::voxel;

import c3voxel::gpu;

faultdef GENERATE_SHADER_FAILED;

struct GenerateUniforms @packed @align(16) {
    float[4] world_min;
    float[4] world_max;
    float    time;
    float[3] _pad;
}

struct GenerateContext {
    gpu::Shader shader;
    gpu::Buffer ubo;
}

fn GenerateContext? generate_context_create(Allocator allocator)
{
    gpu::ShaderStageSpec[1] specs = {
        { gpu::ShaderStageKind.COMPUTE, "src/shaders/generate.comp.glsl" },
    };
    gpu::Shader? sh = gpu::shader_load(allocator, specs[..]);
    if (catch err = sh) return err~;

    gpu::Buffer ubo = gpu::buffer_create(GenerateUniforms.sizeof, gpu::BufferUsage.DYNAMIC);
    return { .shader = sh, .ubo = ubo };
}

fn void generate_context_destroy(GenerateContext* ctx)
{
    gpu::shader_destroy(ctx.shader);
    gpu::buffer_destroy(ctx.ubo);
    ctx.shader = gpu::SHADER_INVALID;
    ctx.ubo    = gpu::BUFFER_INVALID;
}

fn void generate_dispatch(gpu::Commands* cmd, GenerateContext* ctx, Volume* v, float time)
{
    GenerateUniforms u = {
        .world_min = { -1.0, -1.0, -1.0, 0.0 },
        .world_max = {  1.0,  1.0,  1.0, 0.0 },
        .time      = time,
    };
    gpu::buffer_upload(ctx.ubo, &u, 0, GenerateUniforms.sizeof);

    cmd.bind_shader(ctx.shader);
    cmd.bind_image(0, v.tex, gpu::Access.WRITE_ONLY, gpu::Format.RGBA8);
    cmd.bind_ubo(1, ctx.ubo, 0, GenerateUniforms.sizeof);
    cmd.dispatch(VOLUME_PITCH / 4, VOLUME_PITCH / 4, VOLUME_PITCH / 4);
    cmd.barrier(gpu::BarrierType.SHADER_IMAGE_ACCESS);
}
