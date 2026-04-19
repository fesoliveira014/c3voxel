module c3voxel::gpu;

import opengl::gl;

fn void Commands.init(&self)
{
    gl::genVertexArrays(1, &self.empty_vao);
}

fn void Commands.destroy(&self)
{
    if (self.empty_vao != 0) {
        gl::deleteVertexArrays(1, &self.empty_vao);
        self.empty_vao = 0;
    }
}

fn void Commands.begin_frame(&self) @inline {}

fn void Commands.end_frame(&self) @inline {}

fn void Commands.set_viewport(&self, Pixel x, Pixel y, Pixel w, Pixel h) @inline
{
    gl::viewport(x, y, w, h);
}

fn void Commands.clear(&self, float r, float g, float b, float a) @inline
{
    gl::clearColor(r, g, b, a);
    gl::clear((GLbitfield)(gl::GL_COLOR_BUFFER_BIT | gl::GL_DEPTH_BUFFER_BIT));
}

fn void Commands.bind_default_framebuffer(&self) @inline
{
    gl::bindFramebuffer((GLenum)gl::GL_FRAMEBUFFER, 0);
}

fn void Commands.bind_shader(&self, Shader s) @inline
{
    gl::useProgram(shader_program(s));
}

fn void Commands.bind_texture_2d(&self, Binding binding, Texture2D t) @inline
{
    gl::bindTextureUnit(binding, (uint)t);
}

fn void Commands.bind_texture(&self, Binding binding, Texture3D t) @inline
{
    gl::bindTextureUnit(binding, (uint)t);
}

fn void Commands.bind_image(&self, Binding binding, Texture3D t, Access access, Format fmt) @inline
{
    gl::bindImageTexture(binding, (uint)t, 0, gl::GL_TRUE, 0, access_to_gl(access), format_to_gl(fmt));
}

fn void Commands.bind_image_2d(&self, Binding binding, Texture2D t, Access access, Format fmt) @inline
{
    gl::bindImageTexture(binding, (uint)t, 0, gl::GL_FALSE, 0, access_to_gl(access), format_to_gl(fmt));
}

fn void Commands.bind_ubo(&self, Binding binding, Buffer b, ByteOffset offset, ByteSize size) @inline
{
    gl::bindBufferRange((GLenum)gl::GL_UNIFORM_BUFFER, binding, (uint)b, (isz)offset, (isz)size);
}

fn void Commands.bind_ssbo(&self, Binding binding, Buffer b) @inline
{
    gl::bindBufferBase((GLenum)gl::GL_SHADER_STORAGE_BUFFER, binding, (uint)b);
}

fn void Commands.bind_framebuffer(&self, Framebuffer* fb) @inline
{
    if (fb == null) {
        gl::bindFramebuffer((GLenum)gl::GL_FRAMEBUFFER, 0);
        return;
    }
    gl::bindFramebuffer((GLenum)gl::GL_FRAMEBUFFER, fb.fbo_id);
    gl::viewport(0, 0, fb.width, fb.height);
}

fn void Commands.dispatch(&self, int gx, int gy, int gz) @inline
{
    gl::dispatchCompute((uint)gx, (uint)gy, (uint)gz);
}

fn void Commands.draw_fullscreen_quad(&self) @inline
{
    gl::bindVertexArray(self.empty_vao);
    gl::drawArrays((GLenum)gl::GL_TRIANGLES, 0, 3);
}

fn void Commands.barrier(&self, BarrierType type) @inline
{
    gl::memoryBarrier(barrier_to_gl(type));
}

fn void Commands.set_push_constants(&self, void* data, ByteSize size)
{
    // Reserved: lines up with Vulkan's vkCmdPushConstants. GL 4.6 backend
    // will route to a dedicated small UBO once a caller needs per-dispatch
    // scalars beyond what the bind_ubo UBOs carry.
}
