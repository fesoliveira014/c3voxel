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

    const int CHECKER_SIZE = 16;
    gpu::Texture2D checker = gpu::texture2d_create({
        .width  = CHECKER_SIZE,
        .height = CHECKER_SIZE,
        .fmt    = gpu::Format.RGBA8,
        .levels = 1,
    });
    defer gpu::texture2d_destroy(checker);

    char[CHECKER_SIZE * CHECKER_SIZE * 4] pixels;
    for (int y = 0; y < CHECKER_SIZE; y++) {
        for (int x = 0; x < CHECKER_SIZE; x++) {
            int i = (y * CHECKER_SIZE + x) * 4;
            bool light = (((x >> 1) ^ (y >> 1)) & 1) != 0;
            pixels[i + 0] = light ? (char)0xc0 : (char)0x30;
            pixels[i + 1] = light ? (char)0xc0 : (char)0x30;
            pixels[i + 2] = light ? (char)0xf0 : (char)0x50;
            pixels[i + 3] = (char)0xff;
        }
    }
    gpu::texture2d_upload(checker, &pixels, gpu::Format.RGBA8, 0, 0, 0, CHECKER_SIZE, CHECKER_SIZE);

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
        cmd.bind_texture_2d(0, checker);
        cmd.draw_fullscreen_quad();
        cmd.end_frame();

        win.poll();
        win.swap();
    }

    return 0;
}
