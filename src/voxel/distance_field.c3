module c3voxel::voxel;

import c3voxel::gpu;

const int DF_PITCH    = 32;
const int CELL_VOXELS = 4;

struct DistanceFieldStepUniforms @packed @align(16) {
    int    step;
    int    df_pitch;
    int[2] _pad;
}

struct DistanceField {
    gpu::Texture3D[2] tex;
    int               current;
}

struct JumpFloodContext {
    gpu::Shader init_shader;
    gpu::Shader step_shader;
    gpu::Buffer step_ubo;
}

fn void DistanceField.init(&self)
{
    for (int i = 0; i < 2; i++) {
        self.tex[i] = gpu::texture3d_create({
            .width  = DF_PITCH,
            .height = DF_PITCH,
            .depth  = DF_PITCH,
            .fmt    = gpu::Format.R8UI,
            .levels = 1,
        });
    }
    self.current = 0;
}

fn void DistanceField.destroy(&self)
{
    for (int i = 0; i < 2; i++) {
        gpu::texture3d_destroy(self.tex[i]);
        self.tex[i] = gpu::TEXTURE3D_INVALID;
    }
    self.current = 0;
}

fn gpu::Texture3D DistanceField.sampled(&self) @inline => self.tex[self.current];

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
    cmd.bind_image(1, df.tex[0], gpu::Access.WRITE_ONLY, gpu::Format.R8UI);
    cmd.dispatch(DF_PITCH / 4, DF_PITCH / 4, DF_PITCH / 4);
    cmd.barrier(gpu::BarrierType.SHADER_IMAGE_ACCESS);

    int read_idx = 0;
    int step     = DF_PITCH / 2;
    while (step >= 1) {
        int write_idx = 1 - read_idx;

        DistanceFieldStepUniforms u = { .step = step, .df_pitch = DF_PITCH };
        gpu::buffer_upload(self.step_ubo, &u, 0, DistanceFieldStepUniforms.sizeof);

        cmd.bind_shader(self.step_shader);
        cmd.bind_image(0, df.tex[read_idx],  gpu::Access.READ_ONLY,  gpu::Format.R8UI);
        cmd.bind_image(1, df.tex[write_idx], gpu::Access.WRITE_ONLY, gpu::Format.R8UI);
        cmd.bind_ubo(2, self.step_ubo, 0, DistanceFieldStepUniforms.sizeof);
        cmd.dispatch(DF_PITCH / 4, DF_PITCH / 4, DF_PITCH / 4);
        cmd.barrier(gpu::BarrierType.SHADER_IMAGE_ACCESS);

        read_idx = write_idx;
        step    /= 2;
    }

    df.current = read_idx;
    cmd.barrier(gpu::BarrierType.IMAGE_TO_TEXTURE);
}
