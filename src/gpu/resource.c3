module c3voxel::gpu;

import opengl::gl;

typedef Texture2D = inline uint;
typedef Texture3D = inline uint;
typedef Buffer    = inline uint;

const Texture2D TEXTURE2D_INVALID = (Texture2D)0;
const Texture3D TEXTURE3D_INVALID = (Texture3D)0;
const Buffer    BUFFER_INVALID    = (Buffer)0;

const usz MAX_FBO_ATTACHMENTS = 4;

struct Framebuffer {
    uint        fbo_id;
    Texture2D[MAX_FBO_ATTACHMENTS] attachments;
    int         width;
    int         height;
}

struct Commands {
    uint empty_vao;
}

enum Access : char {
    READ_ONLY,
    WRITE_ONLY,
    READ_WRITE,
}

enum Format : char {
    RGBA8,
    RGBA16F,
    RGBA32F,
    R8,
    R16F,
    R32F,
    DEPTH24_STENCIL8,
}

enum BarrierType : char {
    SHADER_IMAGE_ACCESS,
    FRAMEBUFFER_BARRIER,
    STORAGE_BUFFER,
    ALL,
}

fn GLenum access_to_gl(Access a)
{
    switch (a) {
        case Access.READ_ONLY:  return gl::GL_READ_ONLY;
        case Access.WRITE_ONLY: return gl::GL_WRITE_ONLY;
        case Access.READ_WRITE: return gl::GL_READ_WRITE;
    }
}

fn GLenum format_to_gl(Format f)
{
    switch (f) {
        case Format.RGBA8:            return gl::GL_RGBA8;
        case Format.RGBA16F:          return gl::GL_RGBA16F;
        case Format.RGBA32F:          return gl::GL_RGBA32F;
        case Format.R8:               return gl::GL_R8;
        case Format.R16F:             return gl::GL_R16F;
        case Format.R32F:             return gl::GL_R32F;
        case Format.DEPTH24_STENCIL8: return gl::GL_DEPTH24_STENCIL8;
    }
}

fn GLbitfield barrier_to_gl(BarrierType b)
{
    switch (b) {
        case BarrierType.SHADER_IMAGE_ACCESS: return gl::GL_SHADER_IMAGE_ACCESS_BARRIER_BIT;
        case BarrierType.FRAMEBUFFER_BARRIER: return gl::GL_FRAMEBUFFER_BARRIER_BIT;
        case BarrierType.STORAGE_BUFFER:      return gl::GL_SHADER_STORAGE_BARRIER_BIT;
        case BarrierType.ALL:                 return gl::GL_ALL_BARRIER_BITS;
    }
}
