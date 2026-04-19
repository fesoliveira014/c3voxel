module c3voxel::voxel;

import c3voxel::gpu;

const int DF_PITCH = 32;

struct DistanceFieldStepUniforms @packed @align(16) {
    int    step;
    int[3] _pad;
}

struct DistanceField {
    gpu::Texture3D tex;
}

struct JumpFloodContext {
    gpu::Shader init_shader;
    gpu::Shader step_shader;
    gpu::Buffer step_ubo;
}

fn void DistanceField.init(&self)
{
    self.tex = gpu::texture3d_create({
        .width  = DF_PITCH,
        .height = DF_PITCH,
        .depth  = DF_PITCH,
        .fmt    = gpu::Format.R8UI,
        .levels = 1,
    });
}

fn void DistanceField.destroy(&self)
{
    gpu::texture3d_destroy(self.tex);
    self.tex = gpu::TEXTURE3D_INVALID;
}

fn void? JumpFloodContext.init(&self, Allocator allocator)
{
    gpu::ShaderStageSpec[1] init_specs = {
        { gpu::ShaderStageKind.COMPUTE, "resources/shaders/distance_field_init.comp.glsl" },
    };
    gpu::ShaderStageSpec[1] step_specs = {
        { gpu::ShaderStageKind.COMPUTE, "resources/shaders/distance_field_step.comp.glsl" },
    };
    self.init_shader = gpu::shader_load(allocator, init_specs[..])!;
    self.step_shader = gpu::shader_load(allocator, step_specs[..])!;
    self.step_ubo    = gpu::buffer_create(DistanceFieldStepUniforms.sizeof, gpu::BufferUsage.DYNAMIC);
}

fn void JumpFloodContext.destroy(&self)
{
    gpu::shader_destroy(self.init_shader);
    gpu::shader_destroy(self.step_shader);
    gpu::buffer_destroy(self.step_ubo);
    self.init_shader = gpu::SHADER_INVALID;
    self.step_shader = gpu::SHADER_INVALID;
    self.step_ubo    = gpu::BUFFER_INVALID;
}

fn void JumpFloodContext.build(&self, gpu::Commands* cmd, Volume* v, DistanceField* df)
{
    cmd.bind_shader(self.init_shader);
    cmd.bind_image(0, v.tex, gpu::Access.READ_ONLY, gpu::Format.RGBA8);
    cmd.bind_image(1, df.tex, gpu::Access.WRITE_ONLY, gpu::Format.R8UI);
    cmd.dispatch(DF_PITCH / 4, DF_PITCH / 4, DF_PITCH / 4);
    cmd.barrier(gpu::BarrierType.SHADER_IMAGE_ACCESS);

    int step = DF_PITCH / 2;
    while (step >= 1) {
        DistanceFieldStepUniforms u = { .step = step };
        gpu::buffer_upload(self.step_ubo, &u, 0, DistanceFieldStepUniforms.sizeof);

        cmd.bind_shader(self.step_shader);
        cmd.bind_image(0, df.tex, gpu::Access.READ_WRITE, gpu::Format.R8UI);
        cmd.bind_ubo(1, self.step_ubo, 0, DistanceFieldStepUniforms.sizeof);
        cmd.dispatch(DF_PITCH / 4, DF_PITCH / 4, DF_PITCH / 4);
        cmd.barrier(gpu::BarrierType.SHADER_IMAGE_ACCESS);
        step /= 2;
    }

    cmd.barrier(gpu::BarrierType.TEXTURE_FETCH);
}
