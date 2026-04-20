module c3voxel::gpu;

import opengl::gl;

import c3voxel::core;

const usz MAX_TEXTURES = 256;

struct TextureSlot @local {
    uint   gl_id;       // 0 = free (slot 0 is also the reserved invalid slot)
    Format fmt;
    Pixel  width;
    Pixel  height;
    Pixel  depth;        // 1 for 2D
    int    levels;
    bool   is_3d;
    char   generation;
}

TextureSlot[MAX_TEXTURES] texture_slots @local;

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

fn usz alloc_slot() @local
{
    // Slot 0 reserved for invalid handle; start from 1.
    for (usz i = 1; i < MAX_TEXTURES; i++) {
        if (texture_slots[i].gl_id == 0) return i;
    }
    return MAX_TEXTURES;
}

fn uint texture_gl_id_2d(Texture2D t)
{
    uint h = (uint)t;
    uint idx = core::handle_index(h);
    if (idx == 0 || idx >= MAX_TEXTURES) return 0;
    TextureSlot* slot = &texture_slots[idx];
    if ((uint)slot.generation != core::handle_gen(h)) return 0;
    return slot.gl_id;
}

fn uint texture_gl_id_3d(Texture3D t)
{
    uint h = (uint)t;
    uint idx = core::handle_index(h);
    if (idx == 0 || idx >= MAX_TEXTURES) return 0;
    TextureSlot* slot = &texture_slots[idx];
    if ((uint)slot.generation != core::handle_gen(h)) return 0;
    return slot.gl_id;
}

fn Format texture_format_2d(Texture2D t)
{
    uint h = (uint)t;
    uint idx = core::handle_index(h);
    if (idx == 0 || idx >= MAX_TEXTURES) return Format.RGBA8;
    return texture_slots[idx].fmt;
}

fn Format texture_format_3d(Texture3D t)
{
    uint h = (uint)t;
    uint idx = core::handle_index(h);
    if (idx == 0 || idx >= MAX_TEXTURES) return Format.R8UI;
    return texture_slots[idx].fmt;
}

fn Texture2D texture2d_create(Texture2DDesc desc)
{
    usz idx = alloc_slot();
    if (idx == MAX_TEXTURES) return TEXTURE2D_INVALID;

    int levels = desc.levels < 1 ? 1 : desc.levels;

    uint id;
    gl::createTextures((GLenum)gl::GL_TEXTURE_2D, 1, &id);
    gl::textureStorage2D(id, levels, format_to_gl(desc.fmt), desc.width, desc.height);

    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_MIN_FILTER, (int)gl::GL_NEAREST);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_MAG_FILTER, (int)gl::GL_NEAREST);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_WRAP_S,     (int)gl::GL_CLAMP_TO_EDGE);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_WRAP_T,     (int)gl::GL_CLAMP_TO_EDGE);

    TextureSlot* slot = &texture_slots[idx];
    slot.gl_id   = id;
    slot.fmt     = desc.fmt;
    slot.width   = desc.width;
    slot.height  = desc.height;
    slot.depth   = 1;
    slot.levels  = levels;
    slot.is_3d   = false;

    return (Texture2D)core::handle_pack((uint)idx, (uint)slot.generation);
}

fn void texture2d_upload(Texture2D t, void* pixels, Format src_fmt, int level = 0, Pixel x = 0, Pixel y = 0, Pixel w = 0, Pixel h = 0)
{
    uint id = texture_gl_id_2d(t);
    if (id == 0) return;
    gl::textureSubImage2D(
        id, level, x, y, w, h,
        format_channel(src_fmt),
        format_pixel_type(src_fmt),
        pixels);
}

fn void texture2d_destroy(Texture2D t)
{
    uint h = (uint)t;
    uint idx = core::handle_index(h);
    if (idx == 0 || idx >= MAX_TEXTURES) return;
    TextureSlot* slot = &texture_slots[idx];
    if ((uint)slot.generation != core::handle_gen(h)) return;
    if (slot.gl_id != 0) gl::deleteTextures(1, &slot.gl_id);
    slot.gl_id = 0;
    slot.generation++;
}

fn Texture3D texture3d_create(Texture3DDesc desc)
{
    usz idx = alloc_slot();
    if (idx == MAX_TEXTURES) return TEXTURE3D_INVALID;

    int levels = desc.levels < 1 ? 1 : desc.levels;
    int filter = (desc.fmt == Format.R8UI || desc.fmt == Format.R16UI) ? (int)gl::GL_NEAREST : (int)gl::GL_LINEAR;

    uint id;
    gl::createTextures((GLenum)gl::GL_TEXTURE_3D, 1, &id);
    gl::textureStorage3D(id, levels, format_to_gl(desc.fmt), desc.width, desc.height, desc.depth);

    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_MIN_FILTER, filter);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_MAG_FILTER, filter);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_WRAP_S,     (int)gl::GL_CLAMP_TO_EDGE);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_WRAP_T,     (int)gl::GL_CLAMP_TO_EDGE);
    gl::textureParameteri(id, (GLenum)gl::GL_TEXTURE_WRAP_R,     (int)gl::GL_CLAMP_TO_EDGE);

    TextureSlot* slot = &texture_slots[idx];
    slot.gl_id   = id;
    slot.fmt     = desc.fmt;
    slot.width   = desc.width;
    slot.height  = desc.height;
    slot.depth   = desc.depth;
    slot.levels  = levels;
    slot.is_3d   = true;

    return (Texture3D)core::handle_pack((uint)idx, (uint)slot.generation);
}

fn void texture3d_destroy(Texture3D t)
{
    uint h = (uint)t;
    uint idx = core::handle_index(h);
    if (idx == 0 || idx >= MAX_TEXTURES) return;
    TextureSlot* slot = &texture_slots[idx];
    if ((uint)slot.generation != core::handle_gen(h)) return;
    if (slot.gl_id != 0) gl::deleteTextures(1, &slot.gl_id);
    slot.gl_id = 0;
    slot.generation++;
}
