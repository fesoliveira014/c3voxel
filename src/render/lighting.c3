module c3voxel::render;

import c3voxel::core;
import c3voxel::gpu;
import c3voxel::voxel;

// std140 layout — see docs/ubo-convention.md. Field order and types must
// match `resources/shaders/lighting.frag.glsl` exactly. `pan_target` packs
// the world-space camera focus (.xyz) and the current zoom (.w) used by
// `common/iso.glsl` to map between screen UV and world XYZ during the
// shadow march (T8).
struct LightingUniforms @packed @align(16) {
    core::Vec4  sun_dir;            // normalized, world space; .w unused
    core::Vec4  sun_color;          // RGB linear; .a = intensity
    core::Vec4  ambient_color;      // RGB linear; .a = intensity
    core::IVec4 resolution;         // { fb_w, fb_h, 0, 0 }
    core::Vec4  pan_target;         // .xyz = pan_target, .w = zoom_scale
    float       time_of_day;        // [0, 1)
    float       shadow_step;        // reserved (fixed step count path used)
    int         shadow_max_steps;   // shadow march iteration count (T8 = 24)
    int         ao_quality_high;    // 0 = low (24 taps), 1 = high (96 taps)
}
$assert(LightingUniforms.sizeof % 16 == 0);

// Owns the deferred lighting shader, its UBO, the 17×1 palette LUT, and the
// final lit-color FBO. `result_fbo.colors[0]` is the RGBA8 texture consumed
// by the present pass. Shadow march (T8) and AO (T9) bolt into the same
// fragment shader + UBO layout — no further C3 surface changes expected.
struct LightingContext {
    gpu::Shader      shader;
    gpu::Buffer      ubo;
    gpu::Texture2D   palette_lut;
    gpu::Framebuffer result_fbo;
    gpu::Pixel       fbo_width;
    gpu::Pixel       fbo_height;
}

fn void? LightingContext.init(&self, Allocator allocator, gpu::Pixel fb_width, gpu::Pixel fb_height)
{
    gpu::ShaderStageSpec[2] specs = {
        { gpu::ShaderStageKind.VERTEX,   "resources/shaders/lighting.vert.glsl" },
        { gpu::ShaderStageKind.FRAGMENT, "resources/shaders/lighting.frag.glsl" },
    };
    self.shader      = gpu::shader_load(allocator, specs[..])!;
    self.ubo         = gpu::buffer_create(LightingUniforms.sizeof, gpu::BufferUsage.DYNAMIC);
    self.palette_lut = create_palette_lut();
    self.fbo_width   = fb_width;
    self.fbo_height  = fb_height;
    self.result_fbo  = framebuffer_create_lit(fb_width, fb_height)!;
}

fn void LightingContext.destroy(&self)
{
    gpu::shader_destroy(self.shader);
    gpu::buffer_destroy(self.ubo);
    gpu::texture2d_destroy(self.palette_lut);
    gpu::framebuffer_destroy(&self.result_fbo);
    self.shader      = gpu::SHADER_INVALID;
    self.ubo         = gpu::BUFFER_INVALID;
    self.palette_lut = gpu::TEXTURE2D_INVALID;
    self.fbo_width   = 0;
    self.fbo_height  = 0;
}

// Rebuild the lit FBO when the window resizes. Mirrors
// DeferredContext.resize so the two stay lock-step.
fn void? LightingContext.resize(&self, gpu::Pixel fb_width, gpu::Pixel fb_height)
{
    if (fb_width == self.fbo_width && fb_height == self.fbo_height) return;
    gpu::framebuffer_destroy(&self.result_fbo);
    self.result_fbo = framebuffer_create_lit(fb_width, fb_height)!;
    self.fbo_width  = fb_width;
    self.fbo_height = fb_height;
}

fn gpu::Texture2D LightingContext.result_texture(&self) @inline => self.result_fbo.colors[0];

// Binds: 0 = gbuffer (RGBA8), 1 = palette LUT (17×1 RGBA8), 32 = UBO.
// Writes to self.result_fbo.colors[0]. No shadow / AO yet (T8/T9).
fn void LightingContext.dispatch(&self, gpu::Commands* cmd, gpu::Texture2D gbuffer_tex, LightingUniforms* uniforms)
{
    gpu::buffer_upload(self.ubo, uniforms, 0, LightingUniforms.sizeof);

    cmd.bind_framebuffer(&self.result_fbo);
    cmd.clear(0.0f, 0.0f, 0.0f, 1.0f);
    cmd.bind_shader(self.shader);
    cmd.bind_texture_2d(0, gbuffer_tex);
    cmd.bind_texture_2d(1, self.palette_lut);
    cmd.bind_ubo(32, self.ubo, 0, LightingUniforms.sizeof);
    cmd.draw_fullscreen_quad();
    cmd.barrier(gpu::BarrierType.FRAMEBUFFER);
}

// 17×1 RGBA8 palette uploaded from voxel::MATERIAL_COLORS_RGBA8.
fn gpu::Texture2D create_palette_lut() @local
{
    gpu::Texture2D tex = gpu::texture2d_create({
        .width  = voxel::MATERIAL_COUNT,
        .height = 1,
        .fmt    = gpu::Format.RGBA8,
        .levels = 1,
    });
    gpu::texture2d_upload(
        tex,
        (void*)&voxel::MATERIAL_COLORS_RGBA8,
        gpu::Format.RGBA8,
        0, 0, 0,
        voxel::MATERIAL_COUNT, 1);
    return tex;
}

fn gpu::Framebuffer? framebuffer_create_lit(gpu::Pixel w, gpu::Pixel h) @local
{
    gpu::Format[1] colors = { gpu::Format.RGBA8 };
    return gpu::framebuffer_create({
        .width     = w,
        .height    = h,
        .colors    = colors[..],
        .depth     = gpu::Format.RGBA8,
        .has_depth = false,
    });
}
