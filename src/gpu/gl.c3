module c3voxel::gpu;

import opengl::gl;

fn void gl_load_missing(GLLoadFn load)
{
    if (gl::specializeShader == null) gl::specializeShader = (PFNglSpecializeShaderPROC)(void*)load((ZString)"glSpecializeShader");
    if (gl::specializeShaderARB == null) gl::specializeShaderARB = (PFNglSpecializeShaderARBPROC)(void*)load((ZString)"glSpecializeShaderARB");
}
