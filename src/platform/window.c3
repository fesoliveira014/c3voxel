module c3voxel::platform;

import std::io;

import glfw;

faultdef WINDOW_INIT_FAILED, WINDOW_CREATE_FAILED;

struct WindowConfig {
    int     width;
    int     height;
    ZString title;
    int     gl_major;
    int     gl_minor;
    bool    vsync;
    bool    debug_context;
}

fn WindowConfig window_config_default() @inline
{
    return {
        .width         = 1280,
        .height        = 720,
        .title         = (ZString)"c3voxel",
        .gl_major      = 4,
        .gl_minor      = 6,
        .vsync         = true,
        .debug_context = false,
    };
}

struct Window {
    glfw::GlfwWindow* handle;
    int  fb_width;
    int  fb_height;
    bool resized;
    bool[glfw::KEY_LAST + 1] keys;
}

fn void? Window.init(&self, WindowConfig cfg)
{
    glfw::setErrorCallback(&error_cb);

    if (glfw::init() == glfw::FALSE) return WINDOW_INIT_FAILED~;

    glfw::windowHint(glfw::CLIENT_API, glfw::OPENGL_API);
    glfw::windowHint(glfw::CONTEXT_VERSION_MAJOR, cfg.gl_major);
    glfw::windowHint(glfw::CONTEXT_VERSION_MINOR, cfg.gl_minor);
    glfw::windowHint(glfw::OPENGL_PROFILE, glfw::OPENGL_CORE_PROFILE);
    glfw::windowHint(glfw::RESIZABLE, glfw::TRUE);
    if (cfg.debug_context) glfw::windowHint(glfw::OPENGL_DEBUG_CONTEXT, glfw::TRUE);

    glfw::GlfwWindow* handle = glfw::createWindow(cfg.width, cfg.height, cfg.title, null, null);
    if (handle == null) {
        glfw::terminate();
        return WINDOW_CREATE_FAILED~;
    }

    self.handle    = handle;
    self.fb_width  = cfg.width;
    self.fb_height = cfg.height;
    self.resized   = false;
    for (int i = 0; i <= glfw::KEY_LAST; i++) self.keys[i] = false;

    glfw::makeContextCurrent(handle);
    glfw::swapInterval(cfg.vsync ? 1 : 0);
    glfw::getFramebufferSize(handle, &self.fb_width, &self.fb_height);

    glfw::setWindowUserPointer(handle, self);
    glfw::setFramebufferSizeCallback(handle, &fb_size_cb);
    glfw::setKeyCallback(handle, &key_cb);
}

fn void Window.destroy(&self)
{
    if (self.handle != null) {
        glfw::destroyWindow(self.handle);
        self.handle = null;
    }
    glfw::terminate();
}

fn bool Window.should_close(&self) @inline => glfw::windowShouldClose(self.handle) != 0;

fn void Window.request_close(&self) @inline
{
    glfw::setWindowShouldClose(self.handle, glfw::TRUE);
}

fn void Window.poll(&self)
{
    self.resized = false;
    glfw::pollEvents();
}

fn void Window.swap(&self) @inline
{
    glfw::swapBuffers(self.handle);
}

fn bool Window.key_down(&self, int key) @inline
{
    if (key < 0 || key > glfw::KEY_LAST) return false;
    return self.keys[key];
}

fn void fb_size_cb(glfw::GlfwWindow* win, int w, int h) @private
{
    Window* self = (Window*)glfw::getWindowUserPointer(win);
    if (self == null) return;
    self.fb_width  = w;
    self.fb_height = h;
    self.resized   = true;
}

fn void key_cb(glfw::GlfwWindow* win, int key, int scancode, int action, int mods) @private
{
    Window* self = (Window*)glfw::getWindowUserPointer(win);
    if (self == null) return;
    if (key < 0 || key > glfw::KEY_LAST) return;
    if (action == (int)glfw::PRESS || action == (int)glfw::REPEAT) {
        self.keys[key] = true;
    } else if (action == (int)glfw::RELEASE) {
        self.keys[key] = false;
    }
}

fn void error_cb(int code, ZString description) @private
{
    io::eprintfn("[glfw] error %d: %s", code, description);
}
