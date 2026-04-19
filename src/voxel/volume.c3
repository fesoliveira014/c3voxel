module c3voxel::voxel;

import c3voxel::gpu;
import c3voxel::world;

const int VOLUME_RING_SIZE = 4;

struct Volume {
    gpu::Texture3D tex;
}

struct VolumeRing {
    gpu::Texture3D[VOLUME_RING_SIZE] volumes;
    int                              current;
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

fn void VolumeRing.init(&self)
{
    for (int i = 0; i < VOLUME_RING_SIZE; i++) {
        self.volumes[i] = gpu::texture3d_create({
            .width  = world::VOLUME_PITCH,
            .height = world::VOLUME_PITCH,
            .depth  = world::VOLUME_PITCH,
            .fmt    = gpu::Format.RGBA8,
            .levels = 1,
        });
    }
    self.current = 0;
}

fn void VolumeRing.destroy(&self)
{
    for (int i = 0; i < VOLUME_RING_SIZE; i++) {
        gpu::texture3d_destroy(self.volumes[i]);
        self.volumes[i] = gpu::TEXTURE3D_INVALID;
    }
    self.current = 0;
}

fn int VolumeRing.next(&self)
{
    int idx = self.current;
    self.current = (self.current + 1) % VOLUME_RING_SIZE;
    return idx;
}

fn gpu::Texture3D VolumeRing.slot(&self, int i) @inline => self.volumes[i];
