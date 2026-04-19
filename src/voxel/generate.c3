module c3voxel::voxel;

import c3voxel::gpu;

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

fn void? GenerateContext.init(&self, Allocator allocator)
{
    gpu::ShaderStageSpec[1] specs = {
        { gpu::ShaderStageKind.COMPUTE, "src/shaders/generate.comp.glsl" },
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

fn void GenerateContext.dispatch(&self, gpu::Commands* cmd, Volume* v, float time)
{
    GenerateUniforms u = {
        .world_min = { -1.0, -1.0, -1.0, 0.0 },
        .world_max = {  1.0,  1.0,  1.0, 0.0 },
        .time      = time,
    };
    gpu::buffer_upload(self.ubo, &u, 0, GenerateUniforms.sizeof);

    cmd.bind_shader(self.shader);
    cmd.bind_image(0, v.tex, gpu::Access.WRITE_ONLY, gpu::Format.RGBA8);
    cmd.bind_ubo(1, self.ubo, 0, GenerateUniforms.sizeof);
    cmd.dispatch(VOLUME_PITCH / 4, VOLUME_PITCH / 4, VOLUME_PITCH / 4);
    cmd.barrier(gpu::BarrierType.TEXTURE_FETCH);
}
