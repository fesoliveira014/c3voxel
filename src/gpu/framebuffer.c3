module c3voxel::gpu;

import opengl::gl;

faultdef FRAMEBUFFER_INCOMPLETE, FRAMEBUFFER_TOO_MANY_COLORS;

struct FramebufferDesc {
    Pixel    width;
    Pixel    height;
    Format[] colors;
    Format   depth;
    bool     has_depth;
}

fn Framebuffer? framebuffer_create(FramebufferDesc desc)
{
    if (desc.colors.len > MAX_FBO_ATTACHMENTS) return FRAMEBUFFER_TOO_MANY_COLORS~;

    Framebuffer fb;
    fb.width       = desc.width;
    fb.height      = desc.height;
    fb.color_count = (int)desc.colors.len;
    fb.has_depth   = desc.has_depth;

    gl::createFramebuffers(1, &fb.fbo_id);

    GLenum[MAX_FBO_ATTACHMENTS] draw_bufs;
    for (int i = 0; i < fb.color_count; i++) {
        fb.colors[i] = texture2d_create({
            .width  = desc.width,
            .height = desc.height,
            .fmt    = desc.colors[i],
            .levels = 1,
        });
        GLenum attach = (GLenum)((int)gl::GL_COLOR_ATTACHMENT0 + i);
        gl::namedFramebufferTexture(fb.fbo_id, attach, texture_gl_id_2d(fb.colors[i]), 0);
        draw_bufs[i] = attach;
    }
    if (fb.color_count > 0) {
        gl::namedFramebufferDrawBuffers(fb.fbo_id, fb.color_count, &draw_bufs);
    }

    if (desc.has_depth) {
        fb.depth = texture2d_create({
            .width  = desc.width,
            .height = desc.height,
            .fmt    = desc.depth,
            .levels = 1,
        });
        gl::namedFramebufferTexture(fb.fbo_id, (GLenum)gl::GL_DEPTH_ATTACHMENT, texture_gl_id_2d(fb.depth), 0);
    }

    GLenum status = gl::checkNamedFramebufferStatus(fb.fbo_id, (GLenum)gl::GL_FRAMEBUFFER);
    if ((uint)status != gl::GL_FRAMEBUFFER_COMPLETE) {
        framebuffer_destroy(&fb);
        return FRAMEBUFFER_INCOMPLETE~;
    }
    return fb;
}

fn void framebuffer_destroy(Framebuffer* fb)
{
    for (int i = 0; i < fb.color_count; i++) texture2d_destroy(fb.colors[i]);
    fb.color_count = 0;
    if (fb.has_depth) {
        texture2d_destroy(fb.depth);
        fb.has_depth = false;
    }
    if (fb.fbo_id != 0) {
        gl::deleteFramebuffers(1, &fb.fbo_id);
        fb.fbo_id = 0;
    }
}
