module c3voxel::platform;

import glfw;

struct FrameClock {
    double last;
    double dt;
    double time;
    ulong  frame;
}

fn void FrameClock.init(&self)
{
    glfw::setTime(0.0);
    self.last  = 0.0;
    self.dt    = 0.0;
    self.time  = 0.0;
    self.frame = 0;
}

fn double FrameClock.tick(&self)
{
    double now = glfw::getTime();
    self.dt    = now - self.last;
    self.last  = now;
    self.time  = now;
    self.frame++;
    return self.dt;
}

fn double now() @inline => glfw::getTime();
