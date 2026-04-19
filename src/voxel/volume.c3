module c3voxel::voxel;

import c3voxel::gpu;

const int VOLUME_PITCH = 128;

struct Volume {
    gpu::Texture3D tex;
}

fn void Volume.init(&self)
{
    self.tex = gpu::texture3d_create({
        .width  = VOLUME_PITCH,
        .height = VOLUME_PITCH,
        .depth  = VOLUME_PITCH,
        .fmt    = gpu::Format.RGBA8,
        .levels = 1,
    });
}

fn void Volume.destroy(&self)
{
    gpu::texture3d_destroy(self.tex);
    self.tex = gpu::TEXTURE3D_INVALID;
}
