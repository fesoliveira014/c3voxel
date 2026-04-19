module c3voxel::render;

import c3voxel::core;
import c3voxel::gpu;
import c3voxel::world;

const int MAX_COMPOSITE_HOLDERS = 16;

// std140 layout — see docs/ubo-convention.md.
// Promotion path: if a 5th UBO appears, convert to an @std140 macro that
// walks fields and emits per-field offset asserts automatically.
struct CompositeUniforms @packed @align(16) {
    core::Vec4[MAX_COMPOSITE_HOLDERS] screen_min;
    core::Vec4[MAX_COMPOSITE_HOLDERS] screen_max;
    core::IVec4                       screen_size;
    core::IVec4                       alive_bits;
}
$assert(CompositeUniforms.sizeof % 16 == 0);

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

fn void CompositeContext.dispatch(&self, gpu::Commands* cmd, world::GpuPool* pool, world::HolderPool* holders, core::Vec4[] screen_mins, core::Vec4[] screen_maxs, uint alive_mask, gpu::Pixel fb_width, gpu::Pixel fb_height)
{
    CompositeUniforms u;
    for (int i = 0; i < MAX_COMPOSITE_HOLDERS; i++) {
        if (i < (int)screen_mins.len && i < (int)screen_maxs.len) {
            u.screen_min[i] = screen_mins[i];
            u.screen_max[i] = screen_maxs[i];
        } else {
            u.screen_min[i] = { 0.0f, 0.0f, 0.0f, 0.0f };
            u.screen_max[i] = { 0.0f, 0.0f, 0.0f, 0.0f };
        }
    }
    u.screen_size = { (int)fb_width, (int)fb_height, 0, 0 };
    u.alive_bits  = { (int)alive_mask, 0, 0, 0 };
    gpu::buffer_upload(self.ubo, &u, 0, CompositeUniforms.sizeof);

    cmd.bind_shader(self.shader);
    for (int i = 0; i < MAX_COMPOSITE_HOLDERS; i++) {
        if ((alive_mask & ((uint)1 << i)) == 0) {
            cmd.bind_texture_2d((uint)(i * 2 + 0), gpu::TEXTURE2D_INVALID);
            cmd.bind_texture_2d((uint)(i * 2 + 1), gpu::TEXTURE2D_INVALID);
            continue;
        }
        world::Holder* h = holders.get(pool.slots[i].owner);
        if (h == null) continue;
        cmd.bind_texture_2d((uint)(i * 2 + 0), h.fbo_layer0.colors[0]);
        cmd.bind_texture_2d((uint)(i * 2 + 1), h.fbo_layer0.colors[1]);
    }
    cmd.bind_ubo(32, self.ubo, 0, CompositeUniforms.sizeof);
    cmd.draw_fullscreen_quad();
}
