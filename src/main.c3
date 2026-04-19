module c3voxel;

import std::io;

import glfw;

import c3voxel::platform;
import c3voxel::gpu;

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

    gpu::ShaderStageSpec[2] specs = {
        { gpu::ShaderStageKind.VERTEX,   VS_PATH },
        { gpu::ShaderStageKind.FRAGMENT, FS_PATH },
    };

    gpu::Shader? loaded = gpu::shader_load(mem, specs[..]);
    if (catch err = loaded) {
        io::eprintfn("Failed to load shader: %s", err);
        return 1;
    }
    gpu::Shader shader = loaded;
    defer gpu::shader_destroy(shader);

    platform::FrameClock clock;
    clock.init();

    while (!win.should_close()) {
        clock.tick();

        if (win.key_down(glfw::KEY_ESCAPE)) win.request_close();
        if (clock.frame % RELOAD_CHECK_INTERVAL == 0) gpu::shader_reload_if_changed(shader);

        cmd.begin_frame();
        cmd.bind_default_framebuffer();
        cmd.set_viewport(0, 0, win.fb_width, win.fb_height);
        cmd.clear(0.05, 0.05, 0.08, 1.0);
        cmd.bind_shader(shader);
        cmd.draw_fullscreen_quad();
        cmd.end_frame();

        win.poll();
        win.swap();
    }

    return 0;
}
