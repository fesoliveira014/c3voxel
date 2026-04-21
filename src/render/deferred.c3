module c3voxel::render;

import c3voxel::core;
import c3voxel::gpu;
import c3voxel::world;

// Up to MAX_DEFERRED_HOLDERS live holder rects contribute to any one pixel.
// Matches the alive_mask width the streaming layer produces.
const int MAX_DEFERRED_HOLDERS = 16;

// std140 layout — see docs/ubo-convention.md. Mirrors the per-holder screen
// rect arrays the old composite uploaded; kept at the same binding (32) so
// the vertex shader and fragment shader can share the UBO without rebinding.
struct DeferredUniforms @packed @align(16) {
    core::Vec4[MAX_DEFERRED_HOLDERS] screen_min;
    core::Vec4[MAX_DEFERRED_HOLDERS] screen_max;
    core::IVec4                      screen_size;
    core::IVec4                      alive_bits;
}
$assert(DeferredUniforms.sizeof % 16 == 0);

// Owns the shader, the per-frame UBO, and the screen G-buffer FBO. The FBO
// carries one RGBA8 color attachment at window resolution; all four channels
// are packed with G-buffer data per the M8 design:
//   .r, .g  = octahedral normal
//   .b      = height / MAX_WORLD_Y
//   .a      = material_id / 255 (0 == sky)
struct DeferredContext {
    gpu::Shader      shader;
    gpu::Buffer      ubo;
    gpu::Framebuffer fbo;
    gpu::Pixel       fbo_width;
    gpu::Pixel       fbo_height;
}

fn void? DeferredContext.init(&self, Allocator allocator, gpu::Pixel fb_width, gpu::Pixel fb_height)
{
    gpu::ShaderStageSpec[2] specs = {
        { gpu::ShaderStageKind.VERTEX,   "resources/shaders/deferred.vert.glsl" },
        { gpu::ShaderStageKind.FRAGMENT, "resources/shaders/deferred.frag.glsl" },
    };
    self.shader     = gpu::shader_load(allocator, specs[..])!;
    self.ubo        = gpu::buffer_create(DeferredUniforms.sizeof, gpu::BufferUsage.DYNAMIC);
    self.fbo_width  = fb_width;
    self.fbo_height = fb_height;
    self.fbo        = framebuffer_create_gbuffer(fb_width, fb_height)!;
}

fn void DeferredContext.destroy(&self)
{
    gpu::shader_destroy(self.shader);
    gpu::buffer_destroy(self.ubo);
    gpu::framebuffer_destroy(&self.fbo);
    self.shader     = gpu::SHADER_INVALID;
    self.ubo        = gpu::BUFFER_INVALID;
    self.fbo_width  = 0;
    self.fbo_height = 0;
}

// Rebuilds the G-buffer FBO when the window resizes.
fn void? DeferredContext.resize(&self, gpu::Pixel fb_width, gpu::Pixel fb_height)
{
    if (fb_width == self.fbo_width && fb_height == self.fbo_height) return;
    gpu::framebuffer_destroy(&self.fbo);
    self.fbo        = framebuffer_create_gbuffer(fb_width, fb_height)!;
    self.fbo_width  = fb_width;
    self.fbo_height = fb_height;
}

fn gpu::Texture2D DeferredContext.gbuffer_texture(&self) @inline => self.fbo.colors[0];
fn gpu::Texture2D DeferredContext.col_top_texture(&self) @inline => self.fbo.colors[1];

fn void DeferredContext.dispatch(&self, gpu::Commands* cmd, world::GpuPool* pool, world::HolderPool* holders, core::Vec4[] screen_mins, core::Vec4[] screen_maxs, uint alive_mask, gpu::Pixel fb_width, gpu::Pixel fb_height)
{
    // Populate UBO with the per-holder screen rects that main.c3 already
    // computes each frame; unused slots get zeroed so the shader's
    // alive_bits test is the sole gate.
    DeferredUniforms u;
    for (int i = 0; i < MAX_DEFERRED_HOLDERS; i++) {
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
    gpu::buffer_upload(self.ubo, &u, 0, DeferredUniforms.sizeof);

    cmd.bind_framebuffer(&self.fbo);
    cmd.clear(0.0f, 0.0f, 0.0f, 0.0f);
    cmd.bind_shader(self.shader);

    // Binding layout (must mirror deferred.frag.glsl):
    //   0..15  holder material  (R8UI / usampler)
    //   16..31 holder normal    (RG8)
    //   32     UBO
    //   33..48 holder height    (R16F)
    //   49..64 holder col_top   (R16F) — shadow-march threshold
    for (int i = 0; i < MAX_DEFERRED_HOLDERS; i++) {
        gpu::Texture2D mat_tex    = gpu::TEXTURE2D_INVALID;
        gpu::Texture2D normal_tex = gpu::TEXTURE2D_INVALID;
        gpu::Texture2D height_tex = gpu::TEXTURE2D_INVALID;
        gpu::Texture2D coltop_tex = gpu::TEXTURE2D_INVALID;
        if ((alive_mask & ((uint)1 << i)) != 0) {
            world::Holder* h = holders.get(pool.slots[i].owner);
            if (h != null) {
                mat_tex    = h.fbo_layer0.colors[0];
                normal_tex = h.fbo_layer0.colors[1];
                height_tex = h.fbo_layer0.colors[2];
                coltop_tex = h.fbo_layer0.colors[3];
            }
        }
        cmd.bind_texture_2d((uint)(i +  0), mat_tex);
        cmd.bind_texture_2d((uint)(i + 16), normal_tex);
        cmd.bind_texture_2d((uint)(i + 33), height_tex);
        cmd.bind_texture_2d((uint)(i + 49), coltop_tex);
    }
    cmd.bind_ubo(32, self.ubo, 0, DeferredUniforms.sizeof);
    cmd.draw_fullscreen_quad();
    cmd.barrier(gpu::BarrierType.FRAMEBUFFER);
}

fn gpu::Framebuffer? framebuffer_create_gbuffer(gpu::Pixel w, gpu::Pixel h)
{
    // Two attachments: the packed RGBA8 G-buffer + an R8 column-top
    // channel. `col_top / MAX_WORLD_Y` in `.r` — 256 steps over 128
    // world units = same 0.5-unit precision as the height channel.
    gpu::Format[2] colors = { gpu::Format.RGBA8, gpu::Format.R8 };
    return gpu::framebuffer_create({
        .width     = w,
        .height    = h,
        .colors    = colors[..],
        .depth     = gpu::Format.RGBA8,
        .has_depth = false,
    });
}
