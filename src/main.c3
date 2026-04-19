module c3voxel;

import std::io;
import std::math;

import glfw;

import c3voxel::platform;
import c3voxel::gpu;
import c3voxel::voxel;

const String VS_PATH = "src/shaders/fullscreen.vert.glsl";
const String FS_PATH = "src/shaders/fullscreen.frag.glsl";

const ulong RELOAD_CHECK_INTERVAL = 30;

fn int main(String[] args)
{
    platform::Window win;
    if (catch err = win.init(platform::window_config_default())) {
        io::eprintfn("Failed to open window: %s", err);
        return 1;
    }
    defer win.destroy();

    if (catch err = gpu::gpu_init((gpu::LoadFn)&glfw::getProcAddress)) {
        io::eprintfn("Failed to initialize GPU: %s", err);
        return 1;
    }

    io::printfn("Renderer: %s", gpu::renderer_string());
    io::printfn("OpenGL version: %s", gpu::version_string());

    gpu::Commands cmd;
    cmd.init();
    defer cmd.destroy();

    gpu::ShaderStageSpec[2] fullscreen_specs = {
        { gpu::ShaderStageKind.VERTEX,   VS_PATH },
        { gpu::ShaderStageKind.FRAGMENT, FS_PATH },
    };
    gpu::Shader? fs_loaded = gpu::shader_load(mem, fullscreen_specs[..]);
    if (catch err = fs_loaded) {
        io::eprintfn("Failed to load fullscreen shader: %s", err);
        return 1;
    }
    gpu::Shader fullscreen = fs_loaded;
    defer gpu::shader_destroy(fullscreen);

    voxel::GenerateContext? gen_loaded = voxel::generate_context_create(mem);
    if (catch err = gen_loaded) {
        io::eprintfn("Failed to load generate shader: %s", err);
        return 1;
    }
    voxel::GenerateContext gen = gen_loaded;
    defer voxel::generate_context_destroy(&gen);

    voxel::RayMarchContext? rm_loaded = voxel::raymarch_context_create(mem, win.fb_width, win.fb_height);
    if (catch err = rm_loaded) {
        io::eprintfn("Failed to load raymarch shader: %s", err);
        return 1;
    }
    voxel::RayMarchContext rm = rm_loaded;
    defer voxel::raymarch_context_destroy(&rm);

    voxel::Volume volume = voxel::volume_create();
    defer voxel::volume_destroy(&volume);

    voxel::generate_dispatch(&cmd, &gen, &volume, 0.0);

    platform::FrameClock clock;
    clock.init();

    while (!win.should_close()) {
        clock.tick();

        if (win.key_down(glfw::KEY_ESCAPE)) win.request_close();
        if (clock.frame % RELOAD_CHECK_INTERVAL == 0) {
            gpu::shader_reload_if_changed(fullscreen);
            gpu::shader_reload_if_changed(gen.shader);
            gpu::shader_reload_if_changed(rm.shader);
        }

        voxel::raymarch_context_resize(&rm, win.fb_width, win.fb_height);

        float theta = (float)clock.time * 0.45;
        float radius = 3.0;
        float cx = (float)math::cos(theta);
        float sx = (float)math::sin(theta);
        float[4] cam_pos = { radius * cx, 1.3, radius * sx, 0.0 };

        cmd.begin_frame();
        voxel::raymarch_dispatch(&cmd, &rm, &volume, cam_pos);

        cmd.bind_default_framebuffer();
        cmd.set_viewport(0, 0, win.fb_width, win.fb_height);
        cmd.clear(0.02, 0.02, 0.04, 1.0);
        cmd.bind_shader(fullscreen);
        cmd.bind_texture_2d(0, rm.target);
        cmd.draw_fullscreen_quad();
        cmd.end_frame();

        win.poll();
        win.swap();
    }

    return 0;
}
