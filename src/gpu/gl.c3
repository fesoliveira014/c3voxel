module c3voxel::gpu;

import std::io;

import opengl;
import opengl::gl;

alias LoadFn = fn void*(char*);

fn void? gpu_init(LoadFn load)
{
    opengl::init((GLLoadFn)load)!;
    load_missing((GLLoadFn)load);
}

fn void load_missing(GLLoadFn load) @local
{
    if (gl::specializeShader == null) gl::specializeShader = (PFNglSpecializeShaderPROC)(void*)load((ZString)"glSpecializeShader");
    if (gl::specializeShaderARB == null) gl::specializeShaderARB = (PFNglSpecializeShaderARBPROC)(void*)load((ZString)"glSpecializeShaderARB");
}

fn ZString renderer_string() @inline => (ZString)gl::getString((GLenum)gl::GL_RENDERER);
fn ZString version_string()  @inline => (ZString)gl::getString((GLenum)gl::GL_VERSION);
