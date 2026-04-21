module c3voxel::render;

import c3voxel::core;
import c3voxel::gpu;

// std140 layout — see docs/ubo-convention.md. The `.zw` of `resolution`
// carry `MAX_WORLD_Y` (shader normalizes height by this) and a spare lane
// for a future dithering `time` seed (ssao.md §6 follow-up).
struct AoUniforms @packed @align(16) {
    core::Vec4 resolution;     // { fb_w, fb_h, max_world_y, 0 }
}
$assert(AoUniforms.sizeof % 16 == 0);

// Owns the SSAO shader + UBO + single-channel R8 result FBO. The result
// texture is sampled by the lighting pass at binding 2; the deferred
// G-buffer is sampled at binding 0 here (same layout as the other
// screen-space passes).
struct AoContext {
    gpu::Shader      shader;
    gpu::Buffer      ubo;
    gpu::Framebuffer result_fbo;
    gpu::Pixel       fbo_width;
    gpu::Pixel       fbo_height;
}

fn void? AoContext.init(&self, Allocator allocator, gpu::Pixel fb_width, gpu::Pixel fb_height)
{
    gpu::ShaderStageSpec[2] specs = {
        { gpu::ShaderStageKind.VERTEX,   "resources/shaders/ao.vert.glsl" },
        { gpu::ShaderStageKind.FRAGMENT, "resources/shaders/ao.frag.glsl" },
    };
    self.shader     = gpu::shader_load(allocator, specs[..])!;
    self.ubo        = gpu::buffer_create(AoUniforms.sizeof, gpu::BufferUsage.DYNAMIC);
    self.fbo_width  = fb_width;
    self.fbo_height = fb_height;
    self.result_fbo = framebuffer_create_ao(fb_width, fb_height)!;
}

fn void AoContext.destroy(&self)
{
    gpu::shader_destroy(self.shader);
    gpu::buffer_destroy(self.ubo);
    gpu::framebuffer_destroy(&self.result_fbo);
    self.shader     = gpu::SHADER_INVALID;
    self.ubo        = gpu::BUFFER_INVALID;
    self.fbo_width  = 0;
    self.fbo_height = 0;
}

// Rebuild the R8 target on window resize — mirrors DeferredContext.resize
// and LightingContext.resize so the chain's FBO sizes stay lock-step.
fn void? AoContext.resize(&self, gpu::Pixel fb_width, gpu::Pixel fb_height)
{
    if (fb_width == self.fbo_width && fb_height == self.fbo_height) return;
    gpu::framebuffer_destroy(&self.result_fbo);
    self.result_fbo = framebuffer_create_ao(fb_width, fb_height)!;
    self.fbo_width  = fb_width;
    self.fbo_height = fb_height;
}

fn gpu::Texture2D AoContext.result_texture(&self) @inline => self.result_fbo.colors[0];

// Binds: 0 = gbuffer (RGBA8), 1 = UBO. Writes R8 AO to self.result_fbo.
// MAX_WORLD_Y is the same constant the deferred / lighting passes use
// (128.0); pipe it through the UBO so the shader never hardcodes world
// scale.
fn void AoContext.dispatch(&self, gpu::Commands* cmd, gpu::Texture2D gbuffer_tex, gpu::Pixel fb_width, gpu::Pixel fb_height)
{
    AoUniforms u = {
        .resolution = { (float)fb_width, (float)fb_height, 128.0f, 0.0f },
    };
    gpu::buffer_upload(self.ubo, &u, 0, AoUniforms.sizeof);

    cmd.bind_framebuffer(&self.result_fbo);
    cmd.clear(1.0f, 0.0f, 0.0f, 0.0f);          // sky / untouched → fully lit
    cmd.bind_shader(self.shader);
    cmd.bind_texture_2d(0, gbuffer_tex);
    cmd.bind_ubo(1, self.ubo, 0, AoUniforms.sizeof);
    cmd.draw_fullscreen_quad();
    cmd.barrier(gpu::BarrierType.FRAMEBUFFER);
}

fn gpu::Framebuffer? framebuffer_create_ao(gpu::Pixel w, gpu::Pixel h) @local
{
    gpu::Format[1] colors = { gpu::Format.R8 };
    return gpu::framebuffer_create({
        .width     = w,
        .height    = h,
        .colors    = colors[..],
        .depth     = gpu::Format.R8,
        .has_depth = false,
    });
}
