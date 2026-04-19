module c3voxel;

import std::io;

import opengl;
import opengl::gl;
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

    GLLoadFn load = (GLLoadFn)&glfw::getProcAddress;
    if (catch err = opengl::init(load)) {
        io::eprintfn("Failed to initialize OpenGL: %s", err);
        return 1;
    }
    gpu::gl_load_missing(load);

    io::printfn("Renderer: %s", (ZString)gl::getString(gl::GL_RENDERER));
    io::printfn("OpenGL version: %s", (ZString)gl::getString(gl::GL_VERSION));

    uint empty_vao;
    gl::genVertexArrays(1, &empty_vao);
    defer gl::deleteVertexArrays(1, &empty_vao);

    gpu::ShaderStageSpec[2] specs = {
        { gl::GL_VERTEX_SHADER,   "vert", VS_PATH },
        { gl::GL_FRAGMENT_SHADER, "frag", FS_PATH },
    };

    gpu::Shader shader;
    if (catch err = shader.init(mem, specs[..])) {
        io::eprintfn("Failed to load shader: %s", err);
        return 1;
    }
    defer shader.destroy();

    platform::FrameClock clock;
    clock.init();

    while (!win.should_close()) {
        clock.tick();

        if (win.key_down(glfw::KEY_ESCAPE)) win.request_close();
        if (clock.frame % RELOAD_CHECK_INTERVAL == 0) shader.reload_if_changed();

        gl::viewport(0, 0, win.fb_width, win.fb_height);
        gl::clearColor(0.05, 0.05, 0.08, 1.0);
        gl::clear(gl::GL_COLOR_BUFFER_BIT | gl::GL_DEPTH_BUFFER_BIT);

        shader.bind();
        gl::bindVertexArray(empty_vao);
        gl::drawArrays(gl::GL_TRIANGLES, 0, 3);

        win.poll();
        win.swap();
    }

    return 0;
}
