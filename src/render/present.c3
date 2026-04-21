module c3voxel::render;

import c3voxel::gpu;

// Owns the gamma-present shader. Draws the linear lighting result onto the
// default framebuffer with `pow(., 1/2.2)` applied. No UBO — if a dim knob
// or tonemap operator lands later, wire a small one at that point.
struct PresentContext {
    gpu::Shader shader;
}

fn void? PresentContext.init(&self, Allocator allocator)
{
    gpu::ShaderStageSpec[2] specs = {
        { gpu::ShaderStageKind.VERTEX,   "resources/shaders/present.vert.glsl" },
        { gpu::ShaderStageKind.FRAGMENT, "resources/shaders/present.frag.glsl" },
    };
    self.shader = gpu::shader_load(allocator, specs[..])!;
}

fn void PresentContext.destroy(&self)
{
    gpu::shader_destroy(self.shader);
    self.shader = gpu::SHADER_INVALID;
}

fn void PresentContext.dispatch(&self, gpu::Commands* cmd, gpu::Texture2D lit_tex, gpu::Pixel fb_width, gpu::Pixel fb_height)
{
    cmd.bind_default_framebuffer();
    cmd.set_viewport(0, 0, fb_width, fb_height);
    cmd.clear(0.10f, 0.12f, 0.16f, 1.0f);           // sky fill for discarded pixels
    cmd.bind_shader(self.shader);
    cmd.bind_texture_2d(0, lit_tex);
    cmd.draw_fullscreen_quad();
}
