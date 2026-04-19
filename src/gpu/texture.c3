module c3voxel::gpu;

import opengl::gl;

struct Texture2DDesc {
    Pixel  width;
    Pixel  height;
    Format fmt;
    int    levels;
}

struct Texture3DDesc {
    Pixel  width;
    Pixel  height;
    Pixel  depth;
    Format fmt;
    int    levels;
}

fn Texture2D texture2d_create(Texture2DDesc desc)
{
    int levels = desc.levels < 1 ? 1 : desc.levels;

    uint id;
    gl::createTextures((GLenum)gl::GL_TEXTURE_2D, 1, &id);
    gl::textureStorage2D(id, levels, format_to_gl(desc.fmt), desc.width, desc.height);

    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_MIN_FILTER, (int)gl::GL_NEAREST);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_MAG_FILTER, (int)gl::GL_NEAREST);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_WRAP_S,     (int)gl::GL_CLAMP_TO_EDGE);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_WRAP_T,     (int)gl::GL_CLAMP_TO_EDGE);

    return (Texture2D)id;
}

fn void texture2d_upload(Texture2D t, void* pixels, Format src_fmt, int level = 0, Pixel x = 0, Pixel y = 0, Pixel w = 0, Pixel h = 0)
{
    gl::textureSubImage2D(
        (uint)t, level, x, y, w, h,
        format_channel(src_fmt),
        format_pixel_type(src_fmt),
        pixels);
}

fn void texture2d_destroy(Texture2D t)
{
    uint id = (uint)t;
    if (id != 0) gl::deleteTextures(1, &id);
}

fn Texture3D texture3d_create(Texture3DDesc desc)
{
    int levels = desc.levels < 1 ? 1 : desc.levels;
    int filter = (desc.fmt == Format.R8UI) ? (int)gl::GL_NEAREST : (int)gl::GL_LINEAR;

    uint id;
    gl::createTextures((GLenum)gl::GL_TEXTURE_3D, 1, &id);
    gl::textureStorage3D(id, levels, format_to_gl(desc.fmt), desc.width, desc.height, desc.depth);

    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_MIN_FILTER, filter);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_MAG_FILTER, filter);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_WRAP_S,     (int)gl::GL_CLAMP_TO_EDGE);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_WRAP_T,     (int)gl::GL_CLAMP_TO_EDGE);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_WRAP_R,     (int)gl::GL_CLAMP_TO_EDGE);

    return (Texture3D)id;
}

fn void texture3d_destroy(Texture3D t)
{
    uint id = (uint)t;
    if (id != 0) gl::deleteTextures(1, &id);
}
