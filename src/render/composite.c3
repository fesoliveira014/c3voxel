module c3voxel::render;

import c3voxel::core;
import c3voxel::gpu;
import c3voxel::world;

const int MAX_COMPOSITE_HOLDERS = 4;

struct CompositeUniforms @packed @align(16) {
    core::Vec4[MAX_COMPOSITE_HOLDERS] screen_min;
    core::Vec4[MAX_COMPOSITE_HOLDERS] screen_max;
    core::IVec4                       screen_size;
    core::IVec4                       active_count;
}

struct CompositeContext {
    gpu::Shader shader;
    gpu::Buffer ubo;
}

fn void? CompositeContext.init(&self, Allocator allocator)
{
    gpu::ShaderStageSpec[2] specs = {
        { gpu::ShaderStageKind.VERTEX,   "resources/shaders/composite.vert.glsl" },
        { gpu::ShaderStageKind.FRAGMENT, "resources/shaders/composite.frag.glsl" },
    };
    self.shader = gpu::shader_load(allocator, specs[..])!;
    self.ubo    = gpu::buffer_create(CompositeUniforms.sizeof, gpu::BufferUsage.DYNAMIC);
}

fn void CompositeContext.destroy(&self)
{
    gpu::shader_destroy(self.shader);
    gpu::buffer_destroy(self.ubo);
    self.shader = gpu::SHADER_INVALID;
    self.ubo    = gpu::BUFFER_INVALID;
}

fn void CompositeContext.dispatch(&self, gpu::Commands* cmd, world::Holder*[] holders, core::Vec4[] screen_min, core::Vec4[] screen_max, world::Pixel fb_width, world::Pixel fb_height)
{
    int n = (int)holders.len;
    if (n > MAX_COMPOSITE_HOLDERS) n = MAX_COMPOSITE_HOLDERS;

    CompositeUniforms u;
    for (int i = 0; i < MAX_COMPOSITE_HOLDERS; i++) {
        if (i < n) {
            u.screen_min[i] = screen_min[i];
            u.screen_max[i] = screen_max[i];
        } else {
            u.screen_min[i] = { 0.0, 0.0, 0.0, 0.0 };
            u.screen_max[i] = { 0.0, 0.0, 0.0, 0.0 };
        }
    }
    u.screen_size  = { (int)fb_width, (int)fb_height, 0, 0 };
    u.active_count = { n, 0, 0, 0 };
    gpu::buffer_upload(self.ubo, &u, 0, CompositeUniforms.sizeof);

    cmd.bind_shader(self.shader);
    for (int i = 0; i < n; i++) {
        cmd.bind_texture_2d((uint)(i * 2 + 0), holders[i].fbo_layer0.colors[0]);
        cmd.bind_texture_2d((uint)(i * 2 + 1), holders[i].fbo_layer0.colors[1]);
    }
    cmd.bind_ubo(8, self.ubo, 0, CompositeUniforms.sizeof);
    cmd.draw_fullscreen_quad();
}
