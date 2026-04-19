module c3voxel::gpu;

import opengl::gl;

enum BufferUsage : char {
    STATIC,
    DYNAMIC,
}

fn Buffer buffer_create(usz size, BufferUsage usage, void* initial = null)
{
    uint id;
    gl::createBuffers(1, &id);

    GLbitfield flags = 0;
    if (usage == BufferUsage.DYNAMIC) flags = (GLbitfield)gl::GL_DYNAMIC_STORAGE_BIT;

    gl::namedBufferStorage(id, (isz)size, initial, flags);
    return (Buffer)id;
}

fn void buffer_upload(Buffer b, void* data, usz offset, usz size)
{
    gl::namedBufferSubData((uint)b, (iptr)offset, (isz)size, data);
}

fn void buffer_destroy(Buffer b)
{
    uint id = (uint)b;
    if (id != 0) gl::deleteBuffers(1, &id);
}
