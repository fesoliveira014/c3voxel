module c3voxel::voxel;

import c3voxel::gpu;
import c3voxel::world;

struct Volume {
    gpu::Texture3D tex;
}

fn void Volume.init(&self)
{
    self.tex = gpu::texture3d_create({
        .width  = world::VOLUME_PITCH,
        .height = world::VOLUME_PITCH,
        .depth  = world::VOLUME_PITCH,
        .fmt    = gpu::Format.RGBA8,
        .levels = 1,
    });
}

fn void Volume.destroy(&self)
{
    gpu::texture3d_destroy(self.tex);
    self.tex = gpu::TEXTURE3D_INVALID;
}
